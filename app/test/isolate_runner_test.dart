// 恒牙（hengya）· P1-3 isolate 基建 + 建库 job + 拆卡 job 冒烟测试
// ============================================================================
//
// 纪律：本文件全部是 **plain test()**（非 testWidgets）——假异步下 await
// 真实 isolate 消息必死锁（仓库测试纪律），真实 IO/await 允许（同
// pipeline_runner_test）。Windows 宿主 sqlite3.dll：主 isolate 显式
// override 同款基建；**worker isolate 的 override 由 IsolateRunner.start
// 自动探测 test/sqlite3.dll 随 boot 下发**（isolate_runner.dart 文件头 ①
// ——overrideForAll 不随 Isolate.spawn 复制）。
//
// 覆盖面（P1-3 验收）：
//   1. 基建：进度事件（首订阅缓冲补发）+ 结果回传 + 单飞释放后可再启动
//   2. 单飞守卫：运行中重复 start → StateError
//   3. best-effort 取消：cancel → 检查点终止 → IsolateCancelledException
//   4. 异常回传：IsolateJobException（message + 堆栈文本）
//   5. 建库 job（drill 零网络）：真实树（oms pptx + exam pdf——pdf 顺带
//      验证 pdfium 在 worker isolate 首用自然加载）→ corpus.db 契约 +
//      离线检索冒烟 + 进度阶段协议断言
//   6. 拆卡 job 真实链：PipelineRunner.consumeForceRun（无 override）→
//      spawn worker → worker 内自开 hengya.db/corpus → 空收件箱零出卡 +
//      last_run.json 落盘 + 标志删除 + 进度转发
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/local/corpus/extract_all.dart'
    show CorpusEmbedMode;
import 'package:hengya/services/local/corpus/search_engine.dart'
    show corpusSearch, kVec0Table;
import 'package:hengya/services/local/corpus_build_job.dart';
import 'package:hengya/services/local/isolate_runner.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

// —— 源文件（CWD=app/；与 extract_all_build_test 同源）——
const srcOmsPptx =
    '../content/ppt_raw/oms/(2.1.2)--第二章口腔颌面外科基本操作与基础知识 (1).pptx';
const srcExamPdf =
    '../content/ppt_raw/exam/试卷与模拟题/2023年口腔助理医师试题（网友回忆版）.pdf';

// ------------------------------------------- 测试专用 worker 入口（顶层）----

/// 发 3 条进度后返回结果。
void _echoWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    for (var i = 1; i <= 3; i++) {
      ctx.emit(IsolateProgressEvent(stage: 'echo', message: '进度 $i/3'));
    }
    return <String, Object?>{'value': 42};
  });
}

/// 抛错回传。
void _boomWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    ctx.emit(const IsolateProgressEvent(stage: 'boom', message: '即将失败'));
    throw StateError('boom-测试错误');
  });
}

/// 循环发进度 + 取消检查点（单飞/取消测试用）。
void _loopWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    var i = 0;
    while (true) {
      ctx.checkCancelled();
      ctx.emit(IsolateProgressEvent(stage: 'loop', message: 'tick ${i++}'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_isolate_test_');
  });

  tearDown(() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.pipelineKick = null;
    PipelineRunner.instance.runOnceOverride = null;
    PipelineRunner.instance.lastResult = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // 目录已不存在/被占用——系统临时目录兜底清理
    }
  });

  test('基建冒烟：进度事件顺序 + 结果回传 + 完结后可再启动', () async {
    expect(IsolateRunner.instance.isRunning('echo-test'), isFalse);
    final handle = await IsolateRunner.instance.start<Map<String, Object?>>(
      jobId: 'echo-test',
      workerEntry: _echoWorkerEntry,
    );
    expect(IsolateRunner.instance.isRunning('echo-test'), isTrue);
    final events = <IsolateProgressEvent>[];
    final sub = handle.progress.listen(events.add);
    final result = await handle.done;
    // done 与流事件送达存在微任务差——等待 drain 后再断言
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await sub.cancel();

    expect(result['value'], 42);
    expect(events.map((e) => e.message).toList(),
        ['进度 1/3', '进度 2/3', '进度 3/3']);
    expect(events.every((e) => e.stage == 'echo'), isTrue);
    expect(IsolateRunner.instance.isRunning('echo-test'), isFalse);

    // 完结后同 jobId 可再启动（运行位已释放）
    final handle2 = await IsolateRunner.instance.start<Map<String, Object?>>(
      jobId: 'echo-test',
      workerEntry: _echoWorkerEntry,
    );
    expect(await handle2.done, isNotNull);
    expect(IsolateRunner.instance.isRunning('echo-test'), isFalse);
  });

  test('单飞守卫：运行中重复 start 抛 StateError', () async {
    final handle = await IsolateRunner.instance.start<Object?>(
      jobId: 'single-flight-test',
      workerEntry: _loopWorkerEntry,
    );
    expect(
        () => IsolateRunner.instance.start<Object?>(
              jobId: 'single-flight-test',
              workerEntry: _loopWorkerEntry,
            ),
        throwsStateError);
    expect(IsolateRunner.instance.isRunning('single-flight-test'), isTrue);
    handle.cancel();
    await expectLater(handle.done, throwsA(isA<IsolateCancelledException>()));
    expect(IsolateRunner.instance.isRunning('single-flight-test'), isFalse);
  });

  test('best-effort 取消：cancel → 检查点终止 + IsolateCancelledException',
      () async {
    final handle = await IsolateRunner.instance.start<Object?>(
      jobId: 'cancel-test',
      workerEntry: _loopWorkerEntry,
    );
    final events = <IsolateProgressEvent>[];
    final sub = handle.progress.listen(events.add);
    await handle.progress.first; // 等首个 tick（首订阅缓冲保证可见）
    handle.cancel();
    await expectLater(handle.done, throwsA(isA<IsolateCancelledException>()));
    expect(handle.cancelSent, isTrue);
    final n = events.length;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(events.length, n); // worker 已终：不再产生新事件
    await sub.cancel();
  });

  test('异常回传：done 以 IsolateJobException 收尾（message + 堆栈文本）',
      () async {
    final handle = await IsolateRunner.instance.start<Object?>(
      jobId: 'boom-test',
      workerEntry: _boomWorkerEntry,
    );
    await expectLater(
        handle.done,
        throwsA(isA<IsolateJobException>()
            .having((e) => e.message, 'message', contains('boom-测试错误'))
            .having((e) => e.stackTrace, 'stackTrace', isNotNull)));
    expect(IsolateRunner.instance.isRunning('boom-test'), isFalse);
  });

  test('建库 job（drill 零网络）：worker 真实建库 → 检索冒烟 + 进度阶段协议',
      () async {
    if (!File(srcOmsPptx).existsSync() || !File(srcExamPdf).existsSync()) {
      // skip-guard：公开仓库不含 content/（课程语料，版权原因），本用例仅私有工作区生效
      // ignore: avoid_print
      print('SKIP: 私有语料缺失（$srcOmsPptx / $srcExamPdf）');
      return;
    }
    // 临时树：oms pptx + exam pdf（pdf 顺带验证 pdfium worker 内首用加载）
    final tree = '${tmp.path}/tree';
    Directory('$tree/oms').createSync(recursive: true);
    Directory('$tree/exam').createSync(recursive: true);
    File(srcOmsPptx).copySync('$tree/oms/${_pyName(srcOmsPptx)}');
    File(srcExamPdf).copySync('$tree/exam/${_pyName(srcExamPdf)}');
    final dbPath = '${tmp.path}/corpus/corpus.db';

    final events = <IsolateProgressEvent>[];
    final handle = await runCorpusBuild(CorpusBuildRequest(
      inputPath: tree,
      corpusDbPath: dbPath,
      mode: CorpusEmbedMode.drill,
    ));
    final sub = handle.progress.listen(events.add);
    final result = await handle.done;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await sub.cancel();

    // 进度协议：start/extract/ingest/done 阶段齐备（0 chunks 才缺 ingest）
    final stages = events.map((e) => e.stage).toSet();
    expect(stages, containsAll(['start', 'extract', 'ingest', 'done']));
    final extractDone =
        events.lastWhere((e) => e.stage == 'extract' && e.counts != null);
    expect((extractDone.counts!['chunks'] as num?)?.toInt(), 111);

    // 结果（ExtractAllStats/IngestStats toJson 契约键）
    expect(result.chunks, 111);
    expect(result.extract?['errors'] as List, isEmpty);
    expect((result.ingest?['rows'] as num?)?.toInt(), 111);
    expect((result.ingest?['embedded'] as num?)?.toInt(), 111);
    expect((result.ingest?['vec0'] as Map)['ok'], isTrue);
    expect(result.elapsedS, greaterThan(0));
    expect(result.corpusDbPath, dbPath);
    expect(result.notes, isEmpty);

    // key 纪律：全部事件文本不含 key 片段（drill 无 key，本断言为协议守卫）
    for (final e in events) {
      expect(e.message.contains('sk-'), isFalse);
    }

    // corpus.db 落盘（worker 产物）→ 主 isolate 只读验证 + 离线检索冒烟
    expect(File(dbPath).existsSync(), isTrue);
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      final n = db.select('SELECT count(*) FROM chunks').first.columnAt(0)
          as int;
      expect(n, 111);
      expect(_count(db, kVec0Table), 111); // float32 镜像表
      // 动态取查询词（首 chunk 的 6 连汉字）→ 词面 + 伪向量检索冒烟
      final text =
          '${db.select('SELECT text FROM chunks LIMIT 1').first.columnAt(0)}';
      final m = RegExp(r'[\u4e00-\u9fff]{6}').firstMatch(text)!;
      final res =
          await corpusSearch(db, m[0]!, k: 5, offline: true, rerank: false);
      expect((res['results'] as List), isNotEmpty, reason: '离线检索零命中');
    } finally {
      db.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('拆卡 job 真实链：consumeForceRun → worker 自开连接 → 零出卡 + 标志删除',
      () async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    Directory('${tmp.path}/corpus').createSync(recursive: true);
    File(PipelineRunner.markerPath(tmp.path)).writeAsStringSync('queued');

    final events = <IsolateProgressEvent>[];
    final sub = PipelineRunner.instance.progress.listen(events.add);
    try {
      await PipelineRunner.instance.consumeForceRun();
    } finally {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await sub.cancel();
    }

    // 标志删除（rc==0 同义）+ 结果与存档
    expect(File(PipelineRunner.markerPath(tmp.path)).existsSync(), isFalse);
    expect(PipelineRunner.instance.lastResult, isNotNull);
    final result = PipelineRunner.instance.lastResult!;
    final counts = result['counts'] as Map<String, Object?>;
    expect(counts['inbox'], 0); // 空收件箱 → 零出卡零导入
    expect(counts['keywordsProcessed'], 0);
    expect(((result['steps'] as Map)['health'] as Map)['ok'], true);
    expect(File('${tmp.path}/corpus/last_run.json').existsSync(), true);

    // 进度转发（PipelineRunner.progress ← worker catchup 协议）
    final catchupMsgs =
        events.where((e) => e.stage == 'catchup').map((e) => e.message).toList();
    expect(catchupMsgs.first, contains('开始'));
    expect(catchupMsgs.last, contains('完成'));

    // worker 运行位已释放
    expect(IsolateRunner.instance.isRunning(pipelineCatchupJobId), isFalse);
  }, timeout: const Timeout(Duration(minutes: 5)));
}

// ------------------------------------------------------------ helpers ----

String _pyName(String path) =>
    path.split(Platform.pathSeparator).last.split('/').last;

int _count(Database db, String table) {
  try {
    return db.select('SELECT count(*) FROM "$table"').first.columnAt(0) as int;
  } catch (_) {
    return -1; // 表不存在
  }
}
