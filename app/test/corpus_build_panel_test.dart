// 恒牙（hengya）· App 内建库接线 · 设置页建库面板 widget 测试
// ============================================================================
//
// testWidgets 假异步纪律全套：
//   - setUp/tearDown 100% 同步（任何 await 永挂）；boot() 放用例体首行；
//   - 用例体内目录/文件操作全 Sync 变体（createTempSync / deleteSync /
//     writeAsBytesSync）；
//   - **真实 isolate 绝不在 testWidgets 内触发**——建库 job 经
//     LocalBackend.corpusBuildJobOverride 注入假实现（假 Stream +
//     Completer，纯微任务链，pump 可驱动；真 spawn 在用例体内 await 必死锁）；
//   - TopToast v3 时序：断在场先 pump() 一帧再 pump(~500ms)；
//   - SharedPreferences.setMockInitialValues({})（设置页 initState 读提醒配置）。
//
// 覆盖面：
//   1. 待处理清单渲染 + 确认对话框内容 + 取消不触发任何 job
//   2. mock 进度流：运行视图（阶段/当前文件/计数）→ 完成摘要 → 待处理清零
//      + 父级语料状态行刷新（pending 清零走真实 manifest 比对逻辑）
//   3. 单飞守卫交互：运行中重复触发 → triggered=false + 不二次启动
//   4. 失败可重试：done 抛 IsolateJobException → 错误视图 + 重试走通
import 'dart:async';
import 'dart:convert' as convert;
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/pages/settings_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/corpus_build_job.dart'
    show CorpusBuildResult;
import 'package:hengya/services/local/isolate_runner.dart'
    show IsolateJobException, IsolateProgressEvent;
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
        () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_build_panel_');
  });

  tearDown(() {
    LocalBackend.corpusBuildJobOverride = null;
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    // 不 await：resetForTest 同步前缀已清建库运行态（微任务链自完成）
    LocalBackend.instance.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> boot() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    debugBackendMode = BackendMode.local;
    ApiClient.instance.resetSubjectCaches();
    // 设置页 initState：DailyReminder.loadSettings 走 SharedPreferences（内存 mock）
    SharedPreferences.setMockInitialValues({});
  }

  /// incoming 直写两个假课件（后缀在建库树扫描白名单内即可——待处理清单
  /// 只看目录与 manifest，不验魔数；真实验证链归 route 测试）
  void seedPending() {
    Directory('${tmp.path}/corpus/incoming/oms').createSync(recursive: true);
    File('${tmp.path}/corpus/incoming/oms/外科基本操作.pptx')
        .writeAsBytesSync(List.filled(64, 0x50));
    File('${tmp.path}/corpus/incoming/oms/讲义补篇.pdf')
        .writeAsBytesSync(List.filled(48, 0x25));
  }

  /// 写建库 manifest（假 job 的等价副作用——「待处理清零」的真实机制：
  /// incoming 文件全部被 manifest 以 size/mtime 覆盖）。
  void writeManifest() {
    final files = <String, Object?>{};
    for (final name in const ['外科基本操作.pptx', '讲义补篇.pdf']) {
      final f = File('${tmp.path}/corpus/incoming/oms/$name');
      files['oms/$name'] = {
        'size': f.lengthSync(),
        'mtime': f.lastModifiedSync().millisecondsSinceEpoch ~/ 1000,
        'md5': 'fake-md5-$name',
        'subject': 'oms',
        'ppt_id': 'fake-deck',
        'chunk_ids': <String>['oms:fake-deck:p1'],
      };
    }
    File('${tmp.path}/corpus/extract_manifest.json').writeAsStringSync(
      convert.jsonEncode({'version': 1, 'files': files}),
    );
  }

  /// 打开设置页并等首屏异步加载落地（同 ui_button_sweep 的 settle 姿势）。
  /// 视口调高到 800×2600：ListView 惰性构建——默认 600 高度下「知识库」
  /// 区（含建库面板）整个在折叠线以下不构建。
  Future<void> openSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('待处理清单渲染 + 确认取消：不触发任何 job', (tester) async {
    await boot();
    seedPending();
    var started = 0;
    LocalBackend.corpusBuildJobOverride = (req) {
      started++;
      final c = Completer<CorpusBuildResult>();
      return (
        progress: const Stream<IsolateProgressEvent>.empty(),
        done: c.future,
      );
    };

    await openSettings(tester);

    // 面板：待处理 2 个文件 + 清单两行 + 开始建库可用
    expect(find.text('待处理 2 个文件'), findsOneWidget);
    expect(find.textContaining('外科基本操作.pptx'), findsOneWidget);
    expect(find.textContaining('讲义补篇.pdf'), findsOneWidget);
    expect(find.text('开始建库'), findsOneWidget);

    // 确认对话框 → 取消 → 不触发
    await tester.tap(find.text('开始建库'));
    await tester.pump();
    expect(find.text('开始建库？'), findsOneWidget);
    expect(find.textContaining('将把 2 个待处理课件抽取入库'), findsOneWidget);
    expect(find.textContaining('离线词面'), findsOneWidget); // 无 key → 模式名
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('开始建库？'), findsNothing);
    expect(find.text('待处理 2 个文件'), findsOneWidget); // 仍在待处理视图
    expect(started, 0); // 未触发任何 job
  });

  testWidgets(
      '教材树待处理：「·教材」角标清单 + 确认框「课件/教材」措辞（两树并存）',
      (tester) async {
    await boot();
    // 真科目：清单课程名链（local = db subjects 表经 /subjects 目录缓存）
    await LocalBackend.instance
        .post('/subjects', {'name': '口腔颌面外科学', 'id': 'oms'});
    // 两棵树并存（上传「类型：教材」落盘的等价形态）：课件树 + 教材树
    Directory('${tmp.path}/corpus/incoming/oms').createSync(recursive: true);
    File('${tmp.path}/corpus/incoming/oms/外科基本操作.pptx')
        .writeAsBytesSync(List.filled(64, 0x50));
    Directory('${tmp.path}/corpus/incoming/oms-textbook')
        .createSync(recursive: true);
    File('${tmp.path}/corpus/incoming/oms-textbook/皮肤性病学.pdf')
        .writeAsBytesSync(List.filled(48, 0x25));
    var started = 0;
    LocalBackend.corpusBuildJobOverride = (req) {
      started++;
      final c = Completer<CorpusBuildResult>();
      return (
        progress: const Stream<IsolateProgressEvent>.empty(),
        done: c.future,
      );
    };

    await openSettings(tester);

    // 两树并入同一待处理清单：课件行 + 教材行（subject = 首层目录名）
    expect(find.text('待处理 2 个文件'), findsOneWidget);
    expect(find.textContaining('口腔颌面外科学（oms） / 外科基本操作.pptx'),
        findsOneWidget,
        reason: '课件树行：课程名（短码）原样');
    expect(find.textContaining('口腔颌面外科学（oms·教材） / 皮肤性病学.pdf'),
        findsOneWidget,
        reason: '教材树行：剥 -textbook 尾缀查课程名 +「·教材」角标');

    // 确认框：教材在场 → 「课件/教材」措辞（纯课件树维持原文案，
    // 由既有用例「将把 2 个待处理课件抽取入库」锚定不回归）
    await tester.tap(find.text('开始建库'));
    await tester.pump();
    expect(find.text('开始建库？'), findsOneWidget);
    expect(find.textContaining('将把 2 个待处理课件/教材抽取入库'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('开始建库？'), findsNothing);
    expect(started, 0);
  });

  testWidgets('mock 进度流：运行视图 → 完成摘要 → 待处理清零 + 父级语料行刷新',
      (tester) async {
    await boot();
    seedPending();
    final events = StreamController<IsolateProgressEvent>.broadcast();
    addTearDown(events.close);
    final done = Completer<CorpusBuildResult>();
    var started = 0;
    LocalBackend.corpusBuildJobOverride = (req) {
      started++;
      return (progress: events.stream, done: done.future);
    };

    await openSettings(tester);
    expect(find.text('待处理 2 个文件'), findsOneWidget);

    // 触发（面板按钮 → 确认 → 立即开始；全程微任务链，pump 可驱动）
    await tester.tap(find.text('开始建库'));
    await tester.pump();
    await tester.tap(find.text('立即开始'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(started, 1);

    // 运行视图（触发帧 + GET 运行态驱动）
    expect(find.textContaining('正在建库'), findsOneWidget);
    expect(find.text('后台运行中，可离开本页稍后回来查看'), findsOneWidget);
    expect(find.text('开始建库'), findsNothing); // 运行中无可点的开始入口

    // 进度帧驱动（唯一路径 = 状态流；GET 不会给出这个消息文本）
    events.add(const IsolateProgressEvent(
        stage: 'extract', message: '已抽取：oms / 外科基本操作.pptx（12 chunks）'));
    await tester.pump();
    expect(
        find.textContaining('抽取课件 · 已抽取：oms / 外科基本操作.pptx（12 chunks）'),
        findsOneWidget);

    // counts 帧（ExtractAllStats toJson 契约键 → 友好计数行）
    events.add(const IsolateProgressEvent(
        stage: 'extract',
        message: '抽取完成：12 chunks（changed=1 unchanged=0 removed=0）',
        counts: {'chunks': 12, 'changed': 1, 'unchanged': 0, 'removed': 0}));
    await tester.pump();
    expect(find.textContaining('chunks 12 · 新抽 1'), findsOneWidget);

    // 收尾：写 manifest（待处理清零的真实机制）→ done 完成 → 完成摘要
    writeManifest();
    done.complete(CorpusBuildResult(
      extract: const {
        'decks_total': 1,
        'changed': 1,
        'unchanged': 0,
        'removed': 0,
        'chunks': 12,
        'skipped_big': <String>[],
        'errors': <String>[],
        'by_subject': <String, Object?>{'oms': 1},
      },
      ingest: const {
        'rows': 12,
        'bad_lines': 0,
        'mode': 'drill',
        'model': 'local-charhash-1024-v1',
        'dim': 1024,
        'embedded': 12,
        'resumed': 0,
        'pending': 0,
        'batches': 1,
        'pruned_stale': 0,
        'pruned_absent': 0,
      },
      notes: const [],
      elapsedS: 1.5,
      inputPath: 'x',
      corpusDbPath: 'y',
    ));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('上次建库完成'), findsOneWidget);
    expect(find.textContaining('抽取 12 块 · 嵌入 12 · 1.5s'), findsOneWidget);
    expect(find.textContaining('入库 12 行 · 模式 drill'), findsOneWidget);
    expect(find.textContaining('语料已可检索（拆卡流水线与知识库共用）'), findsOneWidget);

    // 待处理清零（manifest 比对真实生效）+ 父级语料状态行刷新
    expect(find.textContaining('暂无待处理文件'), findsOneWidget);
    expect(find.textContaining('当前 0 个'), findsOneWidget);

    // 成功气泡在场（TopToast v3：先 pump 一帧再 pump ~500ms）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('建库完成：12 块语料已可检索'), findsOneWidget);
  });

  testWidgets('单飞守卫交互：运行中重复触发 → 进行中状态 + 不二次启动', (tester) async {
    await boot();
    seedPending();
    final events = StreamController<IsolateProgressEvent>.broadcast();
    addTearDown(events.close);
    final done = Completer<CorpusBuildResult>();
    var started = 0;
    LocalBackend.corpusBuildJobOverride = (req) {
      started++;
      return (progress: events.stream, done: done.future);
    };

    await openSettings(tester);
    await tester.tap(find.text('开始建库'));
    await tester.pump();
    await tester.tap(find.text('立即开始'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(started, 1);
    expect(find.textContaining('正在建库'), findsOneWidget);

    // 运行中再次触发（直接走 API——运行视图没有可点的开始入口）
    final res = await ApiClient.instance.triggerCorpusBuild();
    expect(res.triggered, false);
    expect(res.running, true);
    expect(res.note, contains('进行中'));
    expect(started, 1); // 假 job 未被二次调用
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // 仍在运行视图（无异常无死按钮）
    expect(find.textContaining('正在建库'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 收尾（避免跨用例残留挂起 Future）
    events.add(const IsolateProgressEvent(stage: 'done', message: '建库完成'));
    done.complete(const CorpusBuildResult(
      extract: null,
      ingest: null,
      notes: [],
      elapsedS: 0,
      inputPath: 'x',
      corpusDbPath: 'y',
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('失败可重试：done 抛 IsolateJobException → 错误视图 + 重试走通',
      (tester) async {
    await boot();
    seedPending();
    final events = StreamController<IsolateProgressEvent>.broadcast();
    addTearDown(events.close);
    final completers = <Completer<CorpusBuildResult>>[];
    var started = 0;
    LocalBackend.corpusBuildJobOverride = (req) {
      started++;
      final c = Completer<CorpusBuildResult>();
      completers.add(c);
      return (progress: events.stream, done: c.future);
    };

    await openSettings(tester);
    await tester.tap(find.text('开始建库'));
    await tester.pump();
    await tester.tap(find.text('立即开始'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(started, 1);

    // 失败收尾（IsolateJobException → message 进错误视图；堆栈不进 UI）
    completers.first.completeError(
        IsolateJobException('corpus-build', '抽取失败：演示错误'));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
expect(find.textContaining('上次建库失败：抽取失败：演示错误'), findsOneWidget);
    expect(find.textContaining('失败可重试'), findsOneWidget);
    // 待处理未清（无 manifest）→ 续跑按钮仍可用（失败态 label = 继续建库）
    expect(find.text('待处理 2 个文件'), findsOneWidget);
    expect(find.text('继续建库'), findsOneWidget);
    final btn = find
        .ancestor(of: find.text('继续建库'), matching: find.byType(FilledButton))
        .evaluate()
        .single;
    expect((btn.widget as FilledButton).onPressed, isNotNull);

    // 重试走通（第二轮触发）
    await tester.tap(find.text('继续建库'));
    await tester.pump();
    await tester.tap(find.text('立即开始'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(started, 2);
    expect(find.textContaining('正在建库'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  // ---------------- #3（2026-09-07）：语料变更信号 → 面板不退出重进即变蓝 ----------------

  testWidgets('#3 语料变更信号：incoming 落盘 → 刷新语料状态 → 面板变蓝（不退出重进）',
      (tester) async {
    await boot();
    await openSettings(tester);

    // 初始态：无待处理 → 清单空态 + 按钮灰
    expect(find.text('暂无待处理文件——上传课件后即可在本机构建语料'), findsOneWidget);
    expect(
        (find
                .ancestor(
                    of: find.text('开始建库'),
                    matching: find.byType(FilledButton))
                .evaluate()
                .single
                .widget as FilledButton)
            .onPressed,
        isNull,
        reason: '待处理为空 → 开始建库置灰（用户观察到的灰态）');

    // 上传等价落盘：incoming 直写一个课件（与 App 上传同终态——目录 + 文件）
    Directory('${tmp.path}/corpus/incoming/oms').createSync(recursive: true);
    File('${tmp.path}/corpus/incoming/oms/新课件.pptx')
        .writeAsBytesSync(List.filled(64, 0x50));

    // 「刷新语料状态」→ _refreshCorpus → _corpusRev 信号 +1 → 面板 _onRevChanged
    // 重拉（与生产上传成功回调 _pickAndUpload 走同一信号通路——文件选择器是
    // 平台通道测试宿主不可达，故以刷新按钮驱动同款信号；上传成功回调自增
    // 信号为生产代码，真机复查项见节点交接文档）
    await tester.ensureVisible(find.byTooltip('刷新语料状态'));
    await tester.tap(find.byTooltip('刷新语料状态'));
    for (var i = 0; i < 14 && !tester.any(find.text('待处理 1 个文件')); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('待处理 1 个文件'), findsOneWidget,
        reason: '#3：语料信号触发面板重拉——无需退出重进即见新清单');
    expect(
        (find
                .ancestor(
                    of: find.text('开始建库'),
                    matching: find.byType(FilledButton))
                .evaluate()
                .single
                .widget as FilledButton)
            .onPressed,
        isNotNull,
        reason: '#3：面板刷新后「开始建库」立即变蓝（不退出重进）');
    expect(tester.takeException(), isNull);
  });
}
