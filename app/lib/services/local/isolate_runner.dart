// 恒牙（hengya）· 后台 isolate 执行基建（P1-3 性能审计：流水线 Isolate 化）
// ============================================================================
//
// 职责：把端上长任务（建库 extract/ingest、拆卡六步流水线）spawn 到
// worker isolate 执行，主 isolate 只收「进度事件 + 结果」——PDF/PPTX 抽取、
// sqlite-vec 检索、LLM 调用不再卡 UI/ANR。现有消费方：
//   - pipeline_runner.dart（拆卡六步；PipelineRunner 装配）
//   - corpus_build_job.dart（建库 job；App 内建库接线节点的公共契约）
//
// ── 跨 isolate 语义结论（实测+源码核实，2026-09-06，改动前必读）──
//
// ① sqlite3 原生句柄绝不跨 isolate（核心约束）：
//    - package:sqlite3 的 Database 持有 native 指针——不可 SendPort.send；
//      跨 isolate 只传**路径**，worker 内自行 open（hengya.db 用 Db.open /
//      corpus.db 用 tryOpenCorpusDb——WAL、foreign_keys、synchronous 均为
//      **连接级** PRAGMA，每个新连接自动重放）。
//    - package:sqlite3/open.dart 的 open.overrideForAll 是**每 isolate 独立
//      全局**，不随 Isolate.spawn 复制 → Windows 测试宿主的 test/sqlite3.dll
//      必须在 worker 内重放：[IsolateRunner.start] 自动探测
//      [detectSqlite3LibPath] 并随 boot 下发，worker 包装器派发 job 前重放。
//      Android 生产探测为 null → package:sqlite3 默认按名加载
//      libsqlite3.so（sqlite3_flutter_libs 打包）。
//    - 双连接并发写（主 isolate UI 写 + worker 流水线写，WAL）实测：
//      busy_timeout 编译默认 = 0 → 写锁碰撞**立即**抛 SqliteException(5)
//      （test/sqlite3.dll 探针 2026-09-06：1ms 内失败、无等待）。缓解 =
//      写侧端口短退避重试（pipeline_runner.dart LocalDbPort._busyRetry）；
//      最终兜底仍是「失败留补跑」（契约 9）语义，不引入数据损坏。
//
// ② pdfium（FPDF_InitLibrary 进程级语义，实测结论）：
//    - FPDF_InitLibrary 初始化的是**进程级** pdfium 状态，而 PdfiumLib 是
//      per-isolate 单例（_inited 每 isolate 独立）→ 每个 worker isolate
//      首用 PDF 抽取都会再次调用 FPDF_InitLibrary。
//    - 对随仓二进制（bblanchon chromium/8035）实测（2026-09-06，win-x64
//      pdfium.dll 探针）：同进程第二次 FPDF_InitLibrary 无异常，随后
//      FPDF_LoadDocument/FPDF_GetPageCount 正常（19 页正确读出）；
//      DynamicLibrary.open 二次打开同一 .dll/.so 由 OS 加载器引用计数
//      返回同一映射。结论：worker 内首用自然加载**安全**——无需主
//      isolate 预热、无需跨 isolate 传句柄、无需改 pdfium_ffi.dart。
//
// ③ Flutter 平台通道（rootBundle/MethodChannel）仅主 isolate 可用 →
//    job 所需资产（如提示词模板）由主 isolate 先读好、随 args 传入。
//
// ── wire 协议（全部普通 Map，规避跨 isolate 对象类别坑）──
// worker → 主（单一 report 端口，FIFO 保序；结果经 Isolate.exit 送达）：
//   {'kind':'ready','cmdPort':SendPort}
//   {'kind':'progress','stage','message','counts'?}
//   {'kind':'result','ok':true,'result':Object?}
//   {'kind':'result','ok':false,'cancelled':bool,'message','stackTrace'?}
// 主 → worker（ready 回传的 cmd 端口）：
//   {'kind':'cancel'}        best-effort：置位，job 在自己的检查点自终
// 安全网（Isolate.spawn 的 onError/onExit 具名参数，spawn 时原子挂接）：
//   [错误描述, 堆栈描述]（List 长度 2）= worker 未捕获错误
//   null                      = worker 已退出但没送 result（硬崩/被杀）
//
// 纯 Dart（dart:isolate + dart:io + package:sqlite3/open），不 import
// Flutter——lib/tool 任意层可用（与 corpus/ 抽取链同纪律）。
import 'dart:async';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/open.dart' as sqlite_open;

// ------------------------------------------------------------- 进度 ----

/// 后台 job 进度事件（worker → 主 isolate，按发生顺序送达）。
///
/// [stage]/[message] 面向人读（可直接进日志行/UI）；[counts] 面向结构化
/// 消费（键由各 job 定义并文档化，见 corpus_build_job.dart 进度协议）。
/// job 侧纪律：**任何字段不得携带 key 等敏感值**。
class IsolateProgressEvent {
  const IsolateProgressEvent({
    required this.stage,
    required this.message,
    this.counts,
  });

  /// 阶段名（job 自定义：建库 'start'/'extract'/'ingest'/'done'；拆卡
  /// 'catchup'）。
  final String stage;

  /// 人读消息（中文，可直接展示）。
  final String message;

  /// 可选结构化计数。
  final Map<String, Object?>? counts;

  Map<String, Object?> toWire() => {
        'kind': 'progress',
        'stage': stage,
        'message': message,
        'counts': counts,
      };

  /// wire Map → 事件（主 isolate 侧解码）。
  static IsolateProgressEvent fromWire(Object? m) {
    final w = m as Map;
    final rawCounts = w['counts'];
    return IsolateProgressEvent(
      stage: '${w['stage']}',
      message: '${w['message']}',
      counts: rawCounts is Map ? Map<String, Object?>.from(rawCounts) : null,
    );
  }
}

// ------------------------------------------------------------- 异常 ----

/// job 在 worker 内抛错回传主 isolate 的包装。
///
/// 原始异常**不跨 isolate**（异常对象可能携带不可发送状态）——只回传
/// [message] 与 [stackTrace] 文本。
class IsolateJobException implements Exception {
  IsolateJobException(this.jobId, this.message, [this.stackTrace]);

  final String jobId;

  /// worker 侧错误文本（'$e'）。
  final String message;

  /// worker 侧堆栈文本（best-effort，可能为 null）。
  final String? stackTrace;

  @override
  String toString() =>
      '后台任务 $jobId 失败：$message${stackTrace == null ? '' : '\n$stackTrace'}';
}

/// best-effort 取消生效（worker 在检查点终止）后 [IsolateJobHandle.done]
/// 的收尾异常——job 未完成，语义 =「没有结果」。
class IsolateCancelledException implements Exception {
  const IsolateCancelledException(this.jobId);

  final String jobId;

  @override
  String toString() => '后台任务 $jobId 已取消（best-effort）';
}

/// worker 内部取消信号（job 经 [IsolateWorkerContext.checkCancelled] 触发，
/// 由 [isolateWorkerRun] 统一转成 cancelled 收尾——不外泄）。
class _IsolateCancelSignal implements Exception {
  const _IsolateCancelSignal();
}

// ------------------------------------------------------------- boot ----

/// worker 启动消息（[Isolate.spawn] 的 message 参数；字段全部可跨 isolate）。
class IsolateWorkerBoot {
  IsolateWorkerBoot({
    required this.jobId,
    required this.report,
    required this.args,
    this.sqlite3LibPath,
  });

  /// 单飞 jobId（与 [IsolateRunner.start] 的 jobId 一致）。
  final String jobId;

  /// 事件出口：ready/progress/result 全走此端口（结果经 Isolate.exit 送达）。
  final SendPort report;

  /// job 参数（[IsolateRunner.start] 的 args 原样送达）。
  final Object? args;

  /// 非 null → worker 派发 job 前重放 sqlite3 原生库 override（文件头 ①）。
  final String? sqlite3LibPath;
}

// ----------------------------------------------------------- 上下文 ----

/// worker 侧 job 执行上下文。
class IsolateWorkerContext {
  IsolateWorkerContext._(this._report);

  final SendPort _report;
  bool _cancelled = false;

  /// 主 isolate 是否已请求取消。
  ///
  /// job 应在自己的检查点轮询（或调 [checkCancelled]）——**best-effort**：
  /// 取消只在检查点生效（典型检查点 = 每条进度回调/每个文件/每批嵌入）。
  bool get cancelRequested => _cancelled;

  /// 取消检查点：已请求取消 → 抛内部信号（[isolateWorkerRun] 统一转成
  /// cancelled 收尾）。长循环/逐文件/逐批处调用。
  void checkCancelled() {
    if (_cancelled) {
      throw const _IsolateCancelSignal();
    }
  }

  /// 发进度事件到主 isolate（FIFO 送达；消息务必不含敏感值）。
  void emit(IsolateProgressEvent event) => _report.send(event.toWire());
}

// ----------------------------------------------------- worker 包装器 ----

/// worker entry 公共包装器——所有 job 的 worker 入口（**顶层或静态函数**，
/// isolate 消息不能携带闭包）都用它包住 job 体，统一处理：sqlite3 override
/// 重放（文件头 ①）/ ready 握手 / 取消信号 / 异常与结果回传 / isolate 收尾。
///
/// ```dart
/// void myJobWorkerEntry(IsolateWorkerBoot boot) {
///   isolateWorkerRun(boot, (ctx) async {
///     final req = boot.args! as MyRequest;   // job 参数
///     ...长任务；ctx.emit(...) 报进度；周期 ctx.checkCancelled()...
///     return myResult;                       // 可跨 isolate 的返回值
///   });
/// }
/// ```
///
/// 收尾协议：job 体正常返回 → [IsolateJobHandle.done] 完成；
/// [checkCancelled] 生效 → done 以 [IsolateCancelledException] 收尾；任何
/// 其他异常 → done 以 [IsolateJobException] 收尾。job 体内游离（未 await）
/// 的异步错误会让 worker 以错误终止（Isolate.spawn errorsAreFatal）→
/// 主侧安全网转 [IsolateJobException]——job 体应 await 全部关键异步。
void isolateWorkerRun(
  IsolateWorkerBoot boot,
  FutureOr<Object?> Function(IsolateWorkerContext ctx) body,
) {
  final lib = boot.sqlite3LibPath;
  if (lib != null) {
    // 文件头 ①：overrideForAll 不随 isolate 复制 → worker 内重放
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(lib));
  }
  unawaited(_workerRun(boot, body));
}

Future<void> _workerRun(
  IsolateWorkerBoot boot,
  FutureOr<Object?> Function(IsolateWorkerContext ctx) body,
) async {
  final ctx = IsolateWorkerContext._(boot.report);
  final cmd = ReceivePort();
  cmd.listen((m) {
    if (m is Map && m['kind'] == 'cancel') {
      ctx._cancelled = true; // best-effort：置位，job 在检查点自终
    }
  });
  boot.report.send({'kind': 'ready', 'cmdPort': cmd.sendPort});
  try {
    final result = await body(ctx);
    cmd.close();
    Isolate.exit(boot.report, {'kind': 'result', 'ok': true, 'result': result});
  } on _IsolateCancelSignal {
    cmd.close();
    Isolate.exit(boot.report,
        {'kind': 'result', 'ok': false, 'cancelled': true});
  } catch (e, st) {
    cmd.close();
    Isolate.exit(boot.report, {
      'kind': 'result',
      'ok': false,
      'cancelled': false,
      'message': '$e',
      'stackTrace': '$st',
    });
  }
}

// --------------------------------------------------------------- 句柄 ----

/// 运行中后台 job 的句柄。
class IsolateJobHandle<R> {
  IsolateJobHandle._(this.jobId, this._port, this._onDone);

  /// 单飞 jobId（start 时传入）。
  final String jobId;

  final ReceivePort _port;
  final void Function(String jobId) _onDone;

  final Completer<R> _done = Completer<R>();
  final List<IsolateProgressEvent> _buffer = [];
  SendPort? _workerCmd;
  bool _cancelQueued = false;
  bool _cancelSent = false;
  bool _closed = false;

  /// 首订阅前的事件缓冲上限（超出丢最旧——无人订阅的长 job 不吃内存）。
  static const int _bufferCap = 512;

  late final StreamController<IsolateProgressEvent> _ctrl =
      StreamController<IsolateProgressEvent>.broadcast(onListen: () {
    // 首订阅：按序补发缓冲（start() 返回到首个 listen 之间到达的事件）
    final replay = List<IsolateProgressEvent>.from(_buffer);
    _buffer.clear();
    for (final e in replay) {
      _ctrl.add(e);
    }
  });

  /// 进度事件流（broadcast）。**首订阅前缓冲**：start() 返回到首个 listen
  /// 之间到达的事件在首个订阅时按序补发（上限 [_bufferCap]）；之后的
  /// 订阅只收实时事件。
  Stream<IsolateProgressEvent> get progress => _ctrl.stream;

  /// job 结果：
  /// - 完成 = job 返回值（跨 isolate 拷贝）；
  /// - 取消 = [IsolateCancelledException]；
  /// - 失败 / worker 崩溃 = [IsolateJobException]。
  Future<R> get done => _done.future;

  /// 是否已向 worker 发出取消请求（ready 前调用则待握手后即发）。
  bool get cancelSent => _cancelSent;

  /// best-effort 取消：向 worker 置取消位，worker 在**下一个检查点**自行
  /// 终止（见 [IsolateWorkerContext.checkCancelled]）；已收尾的 job 无效。
  void cancel() {
    if (_closed || _cancelSent) {
      return;
    }
    final cmd = _workerCmd;
    if (cmd == null) {
      _cancelQueued = true; // ready 未回——握手后立即补发
      return;
    }
    _cancelSent = true;
    cmd.send({'kind': 'cancel'});
  }

  // ---- 主 isolate 内部接线（IsolateRunner.start 调用）----

  void _receive(Object? m) {
    if (_closed) {
      return;
    }
    if (m is Map) {
      final kind = m['kind'];
      if (kind == 'ready') {
        _workerCmd = m['cmdPort'] as SendPort;
        if (_cancelQueued) {
          _cancelQueued = false;
          cancel();
        }
      } else if (kind == 'progress') {
        final e = IsolateProgressEvent.fromWire(m);
        if (_ctrl.hasListener) {
          _ctrl.add(e);
        } else {
          if (_buffer.length >= _bufferCap) {
            _buffer.removeAt(0);
          }
          _buffer.add(e);
        }
      } else if (kind == 'result') {
        _close();
        if (m['ok'] == true) {
          try {
            _done.complete(m['result'] as R);
          } catch (e, st) {
            _done.completeError(IsolateJobException(
                jobId, 'worker 结果类型与期望不符：$e', '$st'));
          }
        } else if (m['cancelled'] == true) {
          _done.completeError(IsolateCancelledException(jobId));
        } else {
          _done.completeError(IsolateJobException(
              jobId, '${m['message']}', '${m['stackTrace']}'));
        }
      }
    } else if (m is List && m.length == 2) {
      // Isolate.spawn onError 载荷：[错误描述, 堆栈描述]（worker 未捕获错误）
      _close();
      _done.completeError(IsolateJobException(jobId, '${m[0]}', '${m[1]}'));
    } else if (m == null) {
      // Isolate.spawn onExit 载荷：worker 已退出但没送 result（硬崩/被杀）
      _close();
      _done.completeError(
          IsolateJobException(jobId, 'worker isolate 意外退出（无结果回传）'));
    }
  }

  /// spawn 失败时收尾（不抛 start——经 done 收尾）。
  void _fail(Object error) {
    if (_closed) {
      return;
    }
    _close();
    _done.completeError(error);
  }

  void _close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _onDone(jobId);
    _port.close();
    unawaited(_ctrl.close());
  }
}

// ------------------------------------------------------------- runner ----

/// 后台 isolate 执行器（单例）。
///
/// - **单飞守卫**：同 [jobId] 运行中再 [start] → StateError（调用方决定
///   「已在运行」的 UI 语义）；查询面 [isRunning]/[runningJobIds]。
/// - [start] 本身不因 worker 失败抛错——失败经 [IsolateJobHandle.done]
///   以 [IsolateJobException] 收尾（单飞冲突的 StateError 除外）。
class IsolateRunner {
  IsolateRunner._();

  /// 全局单例（与 PipelineRunner/DataManager 同款装配面）。
  static final IsolateRunner instance = IsolateRunner._();

  /// 运行位图（值仅作占位——R 泛型擦除后不可安全复用句柄类型）。
  final Map<String, Object> _active = {};

  /// [jobId] 是否在运行。
  bool isRunning(String jobId) => _active.containsKey(jobId);

  /// 运行中的 jobId 只读快照（UI 状态行/诊断用）。
  List<String> get runningJobIds => List.unmodifiable(_active.keys);

  /// spawn 一个后台 job。
  ///
  /// - [jobId]：单飞键（同 jobId 并发守卫）。
  /// - [workerEntry]：**顶层或静态函数**（isolate 消息不能携带闭包），须用
  ///   [isolateWorkerRun] 包装 job 体（典型实现见 corpus_build_job.dart /
  ///   pipeline_runner.dart）。
  /// - [args]：job 参数（原样进 [IsolateWorkerBoot.args]；字段须全部可跨
  ///   isolate——普通类/Map/List/基本类型，**绝不含 sqlite3 句柄**）。
  /// - [sqlite3LibPath]：缺省自动探测 [detectSqlite3LibPath]。
  ///
  /// 返回句柄：[IsolateJobHandle.progress] 进度流 +
  /// [IsolateJobHandle.done] 结果 + [IsolateJobHandle.cancel] best-effort
  /// 取消。
  Future<IsolateJobHandle<R>> start<R>({
    required String jobId,
    required void Function(IsolateWorkerBoot boot) workerEntry,
    Object? args,
    String? sqlite3LibPath,
  }) {
    // 单飞：同步段先占坑——两个连续 start 不可能都通过
    if (_active.containsKey(jobId)) {
      throw StateError('后台任务 $jobId 已在运行（单飞守卫）');
    }
    final port = ReceivePort();
    final handle = IsolateJobHandle<R>._(
        jobId, port, (id) => _active.remove(id));
    port.listen(handle._receive);
    _active[jobId] = handle;
    final boot = IsolateWorkerBoot(
      jobId: jobId,
      report: port.sendPort,
      args: args,
      sqlite3LibPath: sqlite3LibPath ?? detectSqlite3LibPath(),
    );
    return Isolate.spawn(workerEntry, boot,
            debugName: 'hengya-$jobId',
            onError: port.sendPort,
            onExit: port.sendPort)
        .then(
      (_) => handle,
      onError: (Object e, StackTrace st) {
        // spawn 失败（入口非法/系统资源不足）：经 done 收尾，不抛 start
        handle._fail(IsolateJobException(
            jobId, 'worker isolate 启动失败：$e', '$st'));
        return handle;
      },
    );
  }
}

/// Windows 测试/CLI 宿主（cwd=app/）的 sqlite3 原生库探测：test/sqlite3.dll
/// 存在 → 绝对路径（随 boot 下发 worker 重放 override，文件头 ①）；其余
/// 环境（Android 生产等）→ null = package:sqlite3 默认按名加载。显式传参
/// （start 的 sqlite3LibPath）可覆盖（测试隔离用）。
String? detectSqlite3LibPath() {
  if (!Platform.isWindows) {
    return null;
  }
  final f = File('test/sqlite3.dll');
  try {
    if (f.existsSync()) {
      return f.absolute.path;
    }
  } catch (_) {
    // 探测失败按「无测试宿主夹具」处理 → worker 走默认加载
  }
  return null;
}
