// 恒牙（hengya）· #13 统计页「卡生成队列」面板 + #4 待处理清单课程名 测试
// ============================================================================
//
// 覆盖面：
//   1. 统计页空态：无 last_run.json、无运行 → 面板在位 + 引导文案
//   2. 非 local 模式：整面板不渲染（流水线为端上 local-first 链路）
//   3. last_run.json 兜底：真实生产源 + 真实文件 → 终态快照全要素渲染
//      （上次运行徽标 / 触发来源 scheduled=定时 22:55 / 分组计数 / 回炉条目 /
//       重造完成数 / 汇总行）
//   4. 实时流（fake 源）：启动过渡态 → 队列帧分组计数与条目 + 触发来源 +
//      事件人读文案 → 失败帧 → 完成切换终态
//   5. 完成事件先于运行位释放：短轮询等收口后切终态（_awaitTerminal 轮询路径）
//   6. rev 刷新信号：自增 → 面板重读快照（统计页 pull-to-refresh 接线）
//   7. #4 待处理清单：「课程名（短码）」逐字断言 + 未收录科目回退裸短码
//   8. #16 终态学习记录摘要行：推进 N 章 / 未推进显示首因 note / 无条目不渲染
//
// testWidgets 假异步纪律（同 corpus_build_panel_test）：
//   - setUp/tearDown 100% 同步；boot() 放用例体首行；
//   - 目录/文件操作全 Sync 变体；真实 isolate 绝不触发（fake 源纯微任务链）；
//   - PipelineRunner 单例 lastProgress/lastResult 每用例重置（#13 handoff 注 5）；
//   - 固定 pump（不 pumpAndSettle）；页面加载用锚点等待循环。
import 'dart:async';
import 'dart:convert' as convert;
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/pages/settings_page.dart';
import 'package:hengya/pages/stats_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/isolate_runner.dart'
    show IsolateProgressEvent;
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/pipeline_runner.dart'
    show
        kPipelineTriggerManual,
        kPipelineTriggerScheduled,
        kPipelineTriggerStartup,
        PipelineRunner;
import 'package:hengya/widgets/pipeline_queue_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
      () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_queue_panel_');
  });

  tearDown(() {
    // #13：PipelineRunner 单例缓存跨用例重置（lastProgress 新轮置 null 语义
    // 由生产代码持有；测试间必须显式归零，防上一帧泄漏进下一用例）。
    PipelineRunner.instance
      ..runOnceOverride = null
      ..lastProgress = null
      ..lastResult = null
      ..lastRunAt = null;
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    // 不 await：resetForTest 同步前缀已清运行态（微任务链自完成）
    LocalBackend.instance.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 用例体首行调用（体内事件循环由 pump 驱动，await 安全）
  Future<void> boot() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    debugBackendMode = BackendMode.local;
    ApiClient.instance.resetSubjectCaches();
    // 设置页 initState：DailyReminder.loadSettings 走 SharedPreferences（内存 mock）
    SharedPreferences.setMockInitialValues({});
  }

  /// 统计页加载锚点等待：streak 卡 + 热力图标题出现 = 五路拉取收口
  Future<void> openStats(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: StatsPage()));
    for (var i = 0; i < 14 && !tester.any(find.text('打卡热力图')); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(tester.any(find.text('打卡热力图')), isTrue, reason: '统计页应完成加载');
  }

  /// 设置页加载锚点等待（知识库区在折叠线以下——视口拉高到 2600）
  Future<void> openSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    for (var i = 0; i < 14 && !tester.any(find.text('开始建库')); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(tester.any(find.text('开始建库')), isTrue, reason: '设置页建库面板应完成加载');
  }

  // ---------------- 契约 fixture（#13 handoff 事件 Map / last_run.json 形态） ----

  Map<String, Object?> kwItem(
    int seq,
    String keyword, {
    String subjectId = 'endo',
  }) => {
    'seq': seq,
    'inboxId': 11 + seq,
    'keyword': keyword,
    'subjectId': subjectId,
  };

  Map<String, Object?> queueSnapshot({
    int total = 10,
    int runningCount = 0,
    int waitingCount = 0,
    int doneCount = 0,
    int failedCount = 0,
    int concurrency = 3,
    int imported = 0,
    int consumed = 0,
    List<Map<String, Object?>> running = const [],
    List<Map<String, Object?>> waiting = const [],
    List<Map<String, Object?>> done = const [],
    List<Map<String, Object?>> failed = const [],
    List<Map<String, Object?>> reworkItems = const [],
  }) => <String, Object?>{
    'total': total,
    'concurrency': concurrency,
    'runningCount': runningCount,
    'waitingCount': waitingCount,
    'doneCount': doneCount,
    'failedCount': failedCount,
    'imported': imported,
    'consumed': consumed,
    'running': running,
    'waiting': waiting,
    'done': done,
    'failed': failed,
    'rework': <String, Object?>{
      'total': reworkItems.length,
      'items': reworkItems,
    },
  };

  IsolateProgressEvent queueEvent(
    Map<String, Object?> queue, {
    String trigger = kPipelineTriggerManual,
    String message = '',
    String type = 'kw_start',
  }) => IsolateProgressEvent(
    stage: 'catchup',
    message: message,
    counts: <String, Object?>{
      'type': type,
      'ts': '2026-09-07T01:17:12.345Z',
      'trigger': trigger,
      'message': message,
      'queue': queue,
    },
  );

  /// last_run.json 终态存档（meta + counts + queue——键集与 runCatchup 结果同构，
  /// 面板只消费 meta.trigger/concurrency/elapsedSec + queue 块 + counts.reworkDone）
  Map<String, Object?> lastRunArchive({
    String trigger = kPipelineTriggerScheduled,
    int concurrency = 3,
    double elapsedSec = 73.4,
    String generatedAt = '2026-09-07T01:20:30',
    int reworkDone = 0,
    Map<String, Object?>? queue,
  }) => <String, Object?>{
    'meta': <String, Object?>{
      'date': '2026-09-07',
      'mode': 'catchup',
      'dryRun': false,
      'generatedAt': generatedAt,
      'trigger': trigger,
      'concurrency': concurrency,
      'startedAt': '2026-09-07T01:19:16',
      'elapsedSec': elapsedSec,
    },
    'counts': <String, Object?>{
      'inbox': 11,
      'keywordsProcessed': 10,
      'reworkDone': reworkDone,
    },
    'queue':
        queue ??
        queueSnapshot(
          total: 10,
          doneCount: 10,
          imported: 12,
          consumed: 10,
          reworkItems: [
            <String, Object?>{
              'queueId': 5,
              'cardId': 'endo-orig-001',
              'subjectId': 'endo',
              'front': '扁平苔藓的临床表现',
              'reason': '答案太啰嗦',
              'note': '',
            },
          ],
        ),
  };

  // ---------------- 测试注入 fake 源（生产源 = PipelineRunner + last_run.json） ----

  Future<void> pumpCard(
    WidgetTester tester,
    PipelineQueueSource src, {
    ValueNotifier<int>? rev,
  }) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [PipelineQueueCard(source: src, rev: rev)],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  // ------------------------------------------------------------ 用例 ----

  testWidgets('统计页空态：无存档 → 面板在位 + 引导文案', (tester) async {
    await boot();
    await openStats(tester);

    expect(find.text('卡生成队列'), findsOneWidget);
    expect(
      find.text(
        '暂无队列数据——收件箱存入关键词、设置页「强制开始拆卡 / 改卡」'
        '触发后，这里实时展示生成进度',
      ),
      findsOneWidget,
      reason: '无 last_run.json、无运行 → 空态引导文案',
    );
    expect(find.text('上次运行'), findsNothing);
    expect(find.text('生成中'), findsNothing);
  });

  testWidgets('非 local 模式：队列面板不渲染', (tester) async {
    debugBackendMode = BackendMode.demo;
    await openStats(tester);
    expect(
      find.text('卡生成队列'),
      findsNothing,
      reason: 'demo/remote 无端上流水线数据面，面板不出现',
    );
  });

  testWidgets('last_run.json 兜底：终态快照全要素渲染（真实生产源 + 真实文件）', (tester) async {
    await boot();
    // 冷启动语义：只写 last_run.json，无运行、无事件——面板必须靠文件兜底
    Directory('${tmp.path}/corpus').createSync(recursive: true);
    File('${tmp.path}/corpus/last_run.json').writeAsStringSync(
      convert.jsonEncode(
        lastRunArchive(trigger: kPipelineTriggerScheduled, reworkDone: 1),
      ),
    );

    await openStats(tester);

    expect(find.text('卡生成队列'), findsOneWidget);
    expect(find.text('上次运行'), findsOneWidget);
    expect(find.text('生成中'), findsNothing);
    // 信息行：时间 · 触发来源（scheduled → 定时 22:55）· 用时 · 并发
    expect(
      find.text('9月7日 01:20 · 定时 22:55 · 用时 73.4 秒 · 并发 3'),
      findsOneWidget,
      reason: '触发来源 scheduled 必须显示「定时 22:55」',
    );
    // 四分组计数
    expect(find.text('正在生成 0'), findsOneWidget);
    expect(find.text('待生成 0'), findsOneWidget);
    expect(find.text('失败 0'), findsOneWidget);
    expect(
      find.text('回炉 1 · 重造完成 1'),
      findsOneWidget,
      reason: '终态回炉组 = 队列条目数 + counts.reworkDone',
    );
    // 回炉条目（front + reason）
    expect(find.text('· 扁平苔藓的临床表现（答案太啰嗦）'), findsOneWidget);
    // 汇总行
    expect(find.text('已生成 10/10 · 入库 12 张 · 消费 10 条'), findsOneWidget);
  });

  testWidgets('实时流：队列帧分组计数与条目 + 触发来源 + 失败帧 + 完成切换终态', (tester) async {
    final fake = FakeQueueSource();
    await pumpCard(tester, fake);

    // ① worker 启动包裹事件（counts=null）：运行中过渡态
    fake.running = true;
    fake.emit(
      const IsolateProgressEvent(
        stage: 'catchup',
        message: '拆卡流水线开始（后台 isolate 执行）',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('已触发流水线，正在准备队列数据…'), findsOneWidget);
    expect(find.text('生成中'), findsOneWidget);

    // ② 首个队列帧（start 事件，全量快照）：3 在跑 / 4 待生成 / 3 已成
    fake.emit(
      queueEvent(
        queueSnapshot(
          total: 10,
          runningCount: 3,
          waitingCount: 4,
          doneCount: 3,
          concurrency: 3,
          imported: 3,
          consumed: 3,
          running: [
            {...kwItem(0, '皮沟皮嵴'), 'startedAt': '2026-09-07T01:17:30'},
            {...kwItem(1, '白斑'), 'startedAt': '2026-09-07T01:17:31'},
            {...kwItem(2, '扁平苔藓'), 'startedAt': '2026-09-07T01:17:32'},
          ],
          waiting: [
            kwItem(3, '过敏性紫癜'),
            kwItem(4, '天疱疮'),
            kwItem(5, '大疱性类天疱疮'),
            kwItem(6, '玫瑰糠疹'),
          ],
          done: [
            {...kwItem(7, '皮肤性病学定义'), 'status': 'ok', 'cards': 1},
            {...kwItem(8, '表皮'), 'status': 'ok', 'cards': 2},
            {...kwItem(9, '真皮'), 'status': 'ok', 'cards': 1},
          ],
          reworkItems: [
            {
              'queueId': 5,
              'cardId': 'endo-orig-001',
              'subjectId': 'endo',
              'front': '扁平苔藓的临床表现',
              'reason': '答案太啰嗦',
              'note': '',
            },
          ],
        ),
        trigger: kPipelineTriggerManual,
        type: 'start',
        message: '开始生成 4/10：过敏性紫癜',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('触发：手动触发 · 并发 3 · 共 10 条关键词'),
      findsOneWidget,
      reason: 'live 信息行含触发来源（manual → 手动触发）',
    );
    expect(find.text('正在生成 3'), findsOneWidget);
    expect(find.text('· 皮沟皮嵴'), findsOneWidget);
    expect(find.text('· 白斑'), findsOneWidget);
    expect(find.text('· 扁平苔藓'), findsOneWidget);
    expect(find.text('待生成 4'), findsOneWidget);
    expect(find.text('· 过敏性紫癜'), findsOneWidget);
    expect(find.text('失败 0'), findsOneWidget);
    expect(find.text('回炉 1'), findsOneWidget);
    expect(find.text('已生成 3/10 · 入库 3 张'), findsOneWidget);
    expect(
      find.byType(LinearProgressIndicator),
      findsOneWidget,
      reason: 'live 帧显示进度条',
    );
    expect(find.text('开始生成 4/10：过敏性紫癜'), findsOneWidget, reason: '最近事件的人读文案行');
    expect(find.text('生成中'), findsOneWidget);

    // ③ 失败帧（kw_done failed）：失败分组计数与条目（关键词 + 错误摘要）
    fake.emit(
      queueEvent(
        queueSnapshot(
          total: 10,
          runningCount: 2,
          waitingCount: 2,
          doneCount: 3,
          failedCount: 1,
          imported: 3,
          consumed: 3,
          running: [
            {...kwItem(1, '白斑'), 'startedAt': '2026-09-07T01:17:31'},
            {...kwItem(2, '扁平苔藓'), 'startedAt': '2026-09-07T01:17:32'},
          ],
          waiting: [kwItem(5, '大疱性类天疱疮'), kwItem(6, '玫瑰糠疹')],
          failed: [
            {
              ...kwItem(4, '天疱疮'),
              'status': 'failed',
              'error': 'LLM 未配置（settings llm.* 缺 baseUrl/apiKey/model）',
            },
          ],
        ),
        type: 'kw_done',
        message: '生成失败 5/10：天疱疮（LLM 未配置）',
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('失败 1'), findsOneWidget);
    expect(
      find.text('· 天疱疮：LLM 未配置（settings llm.* 缺 baseUrl/apiKey/model）'),
      findsOneWidget,
      reason: '失败条目 = 关键词：错误摘要',
    );

    // ④ 完成包裹事件（counts 含 cardsTotal）+ 运行位已释放 → 终态切换
    fake.running = false;
    fake.snapshot = lastRunArchive(
      trigger: kPipelineTriggerManual,
      reworkDone: 1,
      elapsedSec: 52.1,
      queue: queueSnapshot(
        total: 10,
        doneCount: 9,
        failedCount: 1,
        imported: 11,
        consumed: 9,
        failed: [
          {...kwItem(4, '天疱疮'), 'status': 'failed', 'error': 'LLM 未配置'},
        ],
      ),
    );
    fake.emit(
      const IsolateProgressEvent(
        stage: 'catchup',
        message: '拆卡流水线完成：收件箱 11、关键词 10、出卡 12、导入 11',
        counts: {
          'inbox': 11,
          'keywordsProcessed': 10,
          'compassAdvances': 2,
          'reworkDone': 1,
          'cardsTotal': 12,
        },
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('上次运行'), findsOneWidget);
    expect(find.text('生成中'), findsNothing, reason: '完成后实时指示必须停');
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('已生成 9/10 · 入库 11 张 · 消费 9 条'), findsOneWidget);
    expect(find.textContaining('手动触发'), findsOneWidget);
    expect(find.text('回炉 0 · 重造完成 1'), findsOneWidget);
  });

  testWidgets('完成事件先于运行位释放：短轮询等收口后切终态', (tester) async {
    final fake = FakeQueueSource();
    // 面板中途订阅语义：broadcast 流无监听期间事件即弃——首帧经
    // lastEvent（= 生产链 lastProgress）在 initState _refresh 取到。
    fake.running = true;
    fake.lastEvent = queueEvent(
      queueSnapshot(
        total: 3,
        runningCount: 1,
        waitingCount: 2,
        running: [
          {...kwItem(0, '皮沟皮嵴'), 'startedAt': '2026-09-07T01:17:30'},
        ],
        waiting: [kwItem(1, '白斑'), kwItem(2, '扁平苔藓')],
      ),
      message: '开始生成 2/3：白斑',
    );
    await pumpCard(tester, fake);
    expect(find.text('生成中'), findsOneWidget);
    expect(
      find.text('正在生成 1'),
      findsOneWidget,
      reason: '中途订阅者经 lastEvent 拿到当前队列快照',
    );
    expect(find.text('· 皮沟皮嵴'), findsOneWidget);

    // 完成包裹事件到达时 running 仍为 true（真实链路：完成事件先于
    // handle.done → persist → running=false）——面板须轮询等待
    fake.emit(
      const IsolateProgressEvent(
        stage: 'catchup',
        message: '拆卡流水线完成：收件箱 3、关键词 3、出卡 4、导入 4',
        counts: {
          'inbox': 3,
          'keywordsProcessed': 3,
          'compassAdvances': 0,
          'reworkDone': 0,
          'cardsTotal': 4,
        },
      ),
    );
    await tester.pump();
    // 轮询期间仍显示 live 帧（未切换）
    expect(find.text('生成中'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('生成中'), findsOneWidget, reason: '运行位未释放前不切终态');

    // 运行位释放 + 存档就位 → 下一拍收口切终态
    fake.running = false;
    fake.snapshot = lastRunArchive(
      trigger: kPipelineTriggerStartup,
      elapsedSec: 21.0,
      queue: queueSnapshot(total: 3, doneCount: 3, imported: 4, consumed: 3),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(find.text('上次运行'), findsOneWidget);
    expect(find.text('生成中'), findsNothing);
    expect(
      find.textContaining('启动补跑'),
      findsOneWidget,
      reason: 'startup 触发来源标签',
    );
    expect(find.text('已生成 3/3 · 入库 4 张 · 消费 3 条'), findsOneWidget);
  });

  testWidgets('rev 刷新信号：自增 → 面板重读快照', (tester) async {
    final fake = FakeQueueSource();
    fake.snapshot = lastRunArchive(
      trigger: kPipelineTriggerScheduled,
      queue: queueSnapshot(
        total: 10,
        doneCount: 10,
        imported: 12,
        consumed: 10,
      ),
    );
    final rev = ValueNotifier<int>(0);
    addTearDown(rev.dispose);
    await pumpCard(tester, fake, rev: rev);
    expect(find.text('已生成 10/10 · 入库 12 张 · 消费 10 条'), findsOneWidget);

    // 存档更新（新的一轮跑完）+ rev 自增（统计页 _load / pull-to-refresh）→ 重读
    fake.snapshot = lastRunArchive(
      trigger: kPipelineTriggerManual,
      elapsedSec: 8.0,
      generatedAt: '2026-09-07T09:41:00',
      queue: queueSnapshot(total: 2, doneCount: 2, imported: 5, consumed: 2),
    );
    rev.value++;
    await tester.pump();
    await tester.pump();

    expect(
      find.text('已生成 2/2 · 入库 5 张 · 消费 2 条'),
      findsOneWidget,
      reason: 'rev 自增后面板重读新存档（2 关键词轮）',
    );
  });

  testWidgets('#4 待处理清单：课程名（短码）逐字 + 未收录科目回退裸短码', (tester) async {
    await boot();
    // 短码 ucbth7fd 的课程「皮肤性病学」入库（#4 样例）；未收录科目 zzz999
    // 走裸短码回退。createSubject 后清缓存——设置页必须靠 #4 预热链
    // （fetchSubjectCatalog → subjectNames）拿到课程名。
    await ApiClient.instance.createSubject(name: '皮肤性病学', id: 'ucbth7fd');
    ApiClient.instance.resetSubjectCaches();

    Directory(
      '${tmp.path}/corpus/incoming/ucbth7fd',
    ).createSync(recursive: true);
    File(
      '${tmp.path}/corpus/incoming/ucbth7fd/皮肤性病学讲义.pptx',
    ).writeAsBytesSync(List.filled(100000, 0x50));
    Directory('${tmp.path}/corpus/incoming/zzz999').createSync(recursive: true);
    File(
      '${tmp.path}/corpus/incoming/zzz999/未知来源课件.pdf',
    ).writeAsBytesSync(List.filled(100000, 0x25));

    await openSettings(tester);

    expect(find.text('待处理 2 个文件'), findsOneWidget);
    // #4 逐字断言：课程名（短码） / 文件名（98 KB）
    expect(
      find.text('皮肤性病学（ucbth7fd） / 皮肤性病学讲义.pptx（98 KB）'),
      findsOneWidget,
      reason: '短码必须替换为「课程名（短码）」',
    );
    expect(
      find.text('zzz999 / 未知来源课件.pdf（98 KB）'),
      findsOneWidget,
      reason: '未收录科目回退裸短码（不出现「zzz999（zzz999）」复读）',
    );
  });

  testWidgets('#16 终态学习记录摘要：推进 N 章 / 首因 note / 无条目不渲染', (tester) async {
    final fake = FakeQueueSource();

    /// counts.studyLog + steps.studyLog 注入器（其余键沿用 lastRunArchive 基形）
    Map<String, Object?> runWithStudyLog({
      required int entries,
      required int advanced,
      List<Map<String, Object?>> refs = const [],
    }) {
      final base = lastRunArchive();
      return {
        ...base,
        'counts': {
          ...(base['counts'] as Map<String, Object?>),
          'studyLog': <String, Object?>{
            'entries': entries,
            'subjects': entries > 0 ? 1 : 0,
            'refs': refs.length,
            'advanced': advanced,
            'wouldAdvance': 0,
            'missed': refs.where((r) => r['advanced'] != true).length,
            'consumed': 0,
            'consumeSkippedRetry': <int>[],
          },
        },
        'steps': <String, Object?>{
          'studyLog': <String, Object?>{
            'subjects': <Object?>[
              <String, Object?>{
                'subjectId': 'endo',
                'subjectName': '世界史',
                'refs': refs,
              },
            ],
            'entries': entries,
            'consumed': 0,
          },
        },
      };
    }

    final rev = ValueNotifier<int>(0);
    addTearDown(rev.dispose);
    await pumpCard(tester, fake, rev: rev);

    // ① 推进 2 章（entries=3、advanced=2）
    fake.snapshot = runWithStudyLog(
      entries: 3,
      advanced: 2,
      refs: [
        {'ref': '第一章，皮肤的结构与生理功能', 'ok': true, 'advanced': true, 'toNo': 1},
        {'ref': '第二章 表皮', 'ok': true, 'advanced': true, 'toNo': 2},
        {'ref': '第三章 真皮', 'ok': false, 'note': '教材未命中（低于低分线 0.30）——不推进'},
      ],
    );
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(
      find.text('学习记录：推进 2 章'),
      findsOneWidget,
      reason: '有推进 → 「学习记录：推进 N 章」（N=推进成功的章节引用数）',
    );

    // ② 有条目未推进 → 首因 note 逐字
    fake.snapshot = runWithStudyLog(
      entries: 1,
      advanced: 0,
      refs: [
        {'ref': '第一章，皮肤的结构与生理功能', 'ok': false,
         'note': '教材未命中（低于低分线 0.30）——不推进'},
      ],
    );
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(
      find.text('学习记录：教材未命中（低于低分线 0.30）——不推进'),
      findsOneWidget,
      reason: '失败时显示首因 note',
    );

    // ③ 有条目未推进、无 ref note 可取 → 通用「未推进」
    fake.snapshot = runWithStudyLog(entries: 1, advanced: 0);
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(find.text('学习记录：未推进'), findsOneWidget);

    // ④ 本轮无学习记录条目（entries=0）→ 行不渲染
    fake.snapshot = runWithStudyLog(entries: 0, advanced: 0);
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(
      find.textContaining('学习记录：'),
      findsNothing,
      reason: '无学习记录条目 → 摘要行隐藏（不渲染「学习记录：推进 0 章」噪音）',
    );
  });

  // ---------------- ⑦ 回炉待重造（/corpus/status reworkPending 联动） ----------------

  testWidgets('⑦ 回炉待重造：终态快照下常显 + 空态也显示 + rev 刷新数值更新'
      '（N=0 也显示）+ 未拉到不渲染/失败保持原值', (tester) async {
    final fake = FakeQueueSource();
    fake.snapshot = lastRunArchive(
      trigger: kPipelineTriggerManual,
      queue: queueSnapshot(total: 2, doneCount: 2, imported: 3, consumed: 2),
    );
    final rev = ValueNotifier<int>(0);
    addTearDown(rev.dispose);
    await pumpCard(tester, fake, rev: rev);

    // ① 未拉到（null）→ 行不渲染（不阻断队列主视图）；终态快照其余照常
    expect(
      find.textContaining('回炉待重造'),
      findsNothing,
      reason: '未拉到计数 → 行隐藏',
    );
    expect(find.text('已生成 2/2 · 入库 3 张 · 消费 2 条'), findsOneWidget);

    // ② 拉到计数（rev 自增重读）→「回炉待重造 3」常显（与运行内「回炉 N」
    //    组并存，口径不同：前者=当前回炉积压量，后者=本轮流水线消费的队列快照）
    fake.reworkPending = 3;
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(find.text('回炉待重造 3'), findsOneWidget);

    // ③ 计数回落 → 数值更新；N=0 也显示（用户要的就是数值会动）
    fake.reworkPending = 0;
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(
      find.text('回炉待重造 0'),
      findsOneWidget,
      reason: '归零后仍显示（N=0 态可见）',
    );

    // ④ 空态（无存档）也显示——待审核拒绝→回炉 / 回炉按钮提交后，无需
    //    跑过流水线即可见数值
    fake.snapshot = null;
    fake.reworkPending = 1;
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(find.text('暂无队列数据——收件箱存入关键词、设置页「强制开始拆卡 / 改卡」'
        '触发后，这里实时展示生成进度'), findsOneWidget);
    expect(find.text('回炉待重造 1'), findsOneWidget,
        reason: '空态下计数行独立渲染（不依赖队列帧）');

    // ⑤ 拉取失败（null）→ 保持原值（离线韧性：瞬态失败不闪没行）
    fake.reworkPending = null;
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(
      find.text('回炉待重造 1'),
      findsOneWidget,
      reason: '拉取失败保持上一值，不隐藏行',
    );
  });

  // ---------------- ⑤ 真题周扫摘要行（stage='weekly' 事件 / last_run.json weekly 块） ----------------

  testWidgets('⑤ 真题周扫摘要行：出卡/无新增/静默三态 + live 事件帧', (tester) async {
    final fake = FakeQueueSource();
    final rev = ValueNotifier<int>(0);
    addTearDown(rev.dispose);

    Map<String, Object?> archiveWithWeekly(Map<String, Object?>? weekly) {
      final base = lastRunArchive(
        queue: queueSnapshot(total: 1, doneCount: 1, imported: 2, consumed: 1),
      );
      return {...base, 'weekly': ?weekly};
    }

    // ① ran=true 出卡 2 → 「真题周扫：出卡 2 张 · 入库 2 张」
    fake.snapshot = archiveWithWeekly({'ran': true, 'cards': 2, 'imported': 2});
    await pumpCard(tester, fake, rev: rev);
    expect(find.text('真题周扫：出卡 2 张 · 入库 2 张'), findsOneWidget);
    expect(find.text('已生成 1/1 · 入库 2 张 · 消费 1 条'), findsOneWidget,
        reason: '既有汇总行不受影响');

    // ② ran=true 出卡 0 → 「本周无新增真题卡」
    fake.snapshot = archiveWithWeekly({'ran': true, 'cards': 0, 'imported': 0});
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(find.text('真题周扫：本周无新增真题卡'), findsOneWidget);

    // ③ 节流/空态（ran=false）→ 静默不渲染
    fake.snapshot = archiveWithWeekly({
      'ran': false,
      'skipped': 'throttled',
      'prevRunAt': '2026-09-01T00:00:00',
    });
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('真题周扫'), findsNothing,
        reason: '节流/空态静默（细节只在 last_run.json weekly 块）');

    // ④ 无 weekly 块（旧存档）→ 不渲染
    fake.snapshot = archiveWithWeekly(null);
    rev.value++;
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('真题周扫'), findsNothing);

    // ⑤ live：stage='weekly' 事件帧（开始 → 完成），⑦ reworkPending 行共存
    fake.reworkPending = 2;
    fake.running = true;
    rev.value++; // 重读：⑦ 计数（2）+ 运行位切换
    await tester.pump();
    await tester.pump();
    expect(find.text('回炉待重造 2'), findsOneWidget,
        reason: '⑦ 行与 ⑤ 行共存互不影响');
    fake.emit(
      const IsolateProgressEvent(
        stage: 'weekly',
        message: '真题周扫开始（距上次 ≥7 天自动触发）',
        counts: {
          'type': 'weekly_start',
          'weekly': {'phase': 'start'},
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('真题周扫进行中…'), findsOneWidget);

    fake.emit(
      const IsolateProgressEvent(
        stage: 'weekly',
        message: '真题周扫完成：候选 3、出卡 2、导入 2',
        counts: {
          'type': 'weekly_done',
          'weekly': {'ran': true, 'cards': 2, 'imported': 2},
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('真题周扫：出卡 2 张 · 入库 2 张'), findsOneWidget);
  });
}

/// 测试注入 fake 源（类声明须在顶层——函数体内不允许 class）：
/// broadcast 流 + 可变运行位/最近事件 + readSnapshot 替身。
class FakeQueueSource extends PipelineQueueSource {
  final StreamController<IsolateProgressEvent> _ctrl =
      StreamController<IsolateProgressEvent>.broadcast();

  @override
  bool running = false;

  @override
  IsolateProgressEvent? lastEvent;

  /// readSnapshot 替身（null = 模拟「无存档」）
  Map<String, Object?>? snapshot;

  /// ⑦ 回炉待重造计数替身（null = 模拟「拉取失败」→ 行不渲染）
  int? reworkPending;

  @override
  Stream<IsolateProgressEvent> get events => _ctrl.stream;

  @override
  Map<String, Object?>? readSnapshot() => snapshot;

  @override
  Future<int?> fetchReworkPending() async => reworkPending;

  void emit(IsolateProgressEvent e) => _ctrl.add(e);
}
