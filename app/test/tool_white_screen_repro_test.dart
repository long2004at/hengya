// 白屏竞态复现与防御回归（2026-09-06 真机恶性 bug P0）：
//
// 真机复现路径：题库详情页「回炉」弹窗 → 不选理由、连点「送进回炉队列」多次
// → 按系统返回 → 应用白屏（半透明白层、隐约可见文字、任何操作无法进行）。
//
// 根因分析：空理由时每次点击都 TopToast.show（rootOverlay 插条目、无节流）；
// 按系统返回后弹窗 pop 过渡中/后的击键可能带着正在失活（deactivated）的
// dialog context 进入 TopToast.show —— Overlay.maybeOf / MediaQuery.of 在
// defunct element 上查找祖先会抛「Looking up a deactivated widget's
// ancestor is unsafe」。该异常发生在事件分发/回调链上会打断渲染管线，
// release 真机表现即整页卡死白屏（旧帧残留 + 手势事件全部丢弃）。
//
// 本文件三个复现用例：
//  ① 全链路复现（真实 App + local 后端）：连点 ×8 + handlePopRoute（系统返回
//    同路）→ 断言无异常 + 弹窗已关 + 页面仍可交互（备注入口可再开弹层）；
//  ② 竞态变体：pop 过渡半途再点确认键 → 断言无异常 + 编辑入口可再开；
//  ③ defunct 语境实锤：直接以已卸载 context 调 TopToast.show —— 原始实现
//    必抛异常（复现证据）；防御实现必须吞掉静默降级。
// debug 下 ①② 可能不炸（tester 时序与真机事件队列不同），③ 是确定性复现。
// 防御整改（多选改造 + 空选节流 + show 容错）落地后三者必须全绿——
// 用例同时是防御回归网：任何一步退化都会在此翻红。
//
// 基建纪律（同 ui_button_sweep_test 的两层假异步结论）：
//  · setUp/tearDown 100% 同步（体内 await 安全、setup/teardown await 永挂）；
//  · boot() 放用例体首行；sqlite3.dll 用 sqlite_open.overrideForAll 注入；
//  · SharedPreferences.setMockInitialValues({})（内存 mock）；
//  · 固定 pump、不用 pumpAndSettle——StatefulShellRoute 隐藏分支的 home
//    流光是永续动画，pumpAndSettle 会 10 分钟超时挂死；
//  · 播种科目用 POST /subjects 自建科目再 importCards 到该科目 id
//    （勿用内置 'oms' 等短码，避免与「内置科目播种下线」节点耦合）。
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/app.dart';
import 'package:hengya/pages/bank_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/widgets/reason_action_dialog.dart';
import 'package:hengya/widgets/top_toast.dart';
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
  final be = LocalBackend.instance;

  // !! 同 course_flow_ui_test 的两层假异步坑结论：setUp/tearDown 必须 100% 同步
  // （体内 await 安全、setup/teardown await 永挂）；后端 boot 在用例体首行。
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_wsrepro_');
  });

  /// 用例体首行调用（体内事件循环由 pump 驱动，await 安全）
  Future<void> boot() async {
    await be.resetForTest();
    be.init(tmp.path);
    debugBackendMode = BackendMode.local;
    // 设置页等页面 initState 会读提醒配置（SharedPreferences 内存 mock）
    SharedPreferences.setMockInitialValues({});
  }

  tearDown(() {
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    // 不 await：微任务链在真实事件队列 FIFO 自完成
    LocalBackend.instance.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
  }

  Future<void> tapNav(WidgetTester tester, String label) async {
    // NavigationBar 在 Scaffold 尾部 → .last 恒为导航标签，不受页面同名文案干扰
    await tester.tap(find.text(label).last, warnIfMissed: false);
    await settle(tester);
  }

  /// 播种：POST /subjects 自建科目 + importCards 一张 active 卡（可进详情、可回炉）
  Future<void> seedActiveCard() async {
    final created = await be.post('/subjects', {'name': '白屏复现课'});
    expect((created as Map)['ok'], true, reason: '自建科目必须成功');
    final subjectId = created['id'] as String;
    final seeded = await be.importCards([
      {
        'id': 'ws-repro-001',
        'subjectId': subjectId,
        'type': 'basic',
        'front': '白屏复现题干',
        'back': '白屏复现答案',
        'anchor': 'repro 第一章',
        'source': 'white screen repro',
        'status': 'active',
      },
    ]);
    expect((seeded as Map)['inserted'], 1, reason: '播种卡必须入库');
  }

  /// 测试宿主共享初始化（物理尺寸固定 800x1800，防小屏布局干扰）
  Future<void> fixView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  // ---------------- 复现①：连点 ×8 + 系统返回 → 必须无异常且仍可交互 ----------------

  testWidgets(
      '复现①：不选理由连点「送进回炉队列」×8 + 系统返回 → 无异常、弹窗关闭、详情页仍可交互',
      (tester) async {
    await boot();
    await fixView(tester);
    await seedActiveCard();

    await tester.pumpWidget(const HengyaApp());
    await settle(tester);
    await tapNav(tester, '题库');
    expect(find.text('共 1 张'), findsOneWidget, reason: '播种卡必须可查');

    // 进详情
    await tester.tap(find.text('白屏复现题干'), warnIfMissed: false);
    await settle(tester);
    expect(tester.any(find.byType(BankDetailPage)), isTrue, reason: '必须进入题库详情页');

    // 开回炉弹窗
    await tester.tap(find.text('回炉'), warnIfMissed: false);
    await settle(tester);
    expect(find.byType(ReasonActionDialog), findsOneWidget, reason: '回炉弹窗必须在场');

    // 不选理由连点 ×8（每击 50ms 假时——真机连点节奏；空理由路径每次都发 toast）
    for (var i = 0; i < 8; i++) {
      await tester.tap(find.text('送进回炉队列'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 防呆提示在场（findTextContaining 兼容多选改造前后两版文案）
    expect(find.textContaining('回炉原因'), findsOneWidget,
        reason: '空选必须出防呆提示');

    // 系统返回（handlePopRoute 与 Android 返回键同路）：应关掉弹窗而非卡死
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // pop 过渡走完

    expect(tester.takeException(), isNull, reason: '竞态路径不得产生 framework 异常');
    expect(find.byType(ReasonActionDialog), findsNothing, reason: '系统返回必须关掉弹窗');

    // 页面仍可交互：备注入口必须能再开弹层
    await tester.ensureVisible(find.text('备注'));
    await tester.tap(find.text('备注'), warnIfMissed: false);
    await settle(tester);
    expect(find.text('写给自己看：口诀、联想、易错点…'), findsOneWidget,
        reason: '返回后详情页必须仍可交互（备注弹层可开）');
    expect(tester.takeException(), isNull);

    // 收尾：全树卸载（Toast/弹层 Ticker 全部释放），无残留异常
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // ---------------- 复现②（竞态变体）：pop 过渡半途再点确认键 ----------------

  testWidgets('复现②（竞态变体）：pop 过渡半途再点「送进回炉队列」→ 无异常、编辑入口仍可开',
      (tester) async {
    await boot();
    await fixView(tester);
    await seedActiveCard();

    await tester.pumpWidget(const HengyaApp());
    await settle(tester);
    await tapNav(tester, '题库');
    await tester.tap(find.text('白屏复现题干'), warnIfMissed: false);
    await settle(tester);
    await tester.tap(find.text('回炉'), warnIfMissed: false);
    await settle(tester);

    // 第一击（toast 出场）→ 立即系统返回（弹窗 pop 过渡 150ms 进行中）→ 半途再点
    await tester.tap(find.text('送进回炉队列'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 30));
    await tester.binding.handlePopRoute(); // 弹窗开始 pop
    await tester.pump(const Duration(milliseconds: 50)); // 过渡半途
    await tester.tap(find.text('送进回炉队列'),
        warnIfMissed: false); // 竞态一击（过渡中的击键）
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // 过渡走完

    expect(tester.takeException(), isNull, reason: '过渡中的击键不得引发异常');
    expect(find.byType(ReasonActionDialog), findsNothing, reason: '弹窗必须已关闭');

    // 交互性收尾：active 卡编辑入口必须还能打开（编辑弹层三字段可定位）
    await tester.ensureVisible(find.text('编辑'));
    await tester.tap(find.text('编辑'), warnIfMissed: false);
    await settle(tester);
    expect(find.text('题干'), findsOneWidget, reason: '编辑弹层必须能打开（页面可交互）');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // ---------------- 复现③（defunct 语境实锤）：TopToast.show 容错 ----------------

  testWidgets(
      '复现③（defunct 实锤）：TopToast.show 收到已卸载 context 必须吞掉异常（toast 非关键路径）',
      (tester) async {
    // 第一棵树留下 context，然后整树换掉 → 该 context 已 defunct（不再在树上）
    BuildContext? stale;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) {
            stale = ctx;
            return const SizedBox();
          },
        ),
      ),
    ));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();

    // 原始实现：Overlay.maybeOf 在 defunct element 上抛
    // 「Looking up a deactivated widget's ancestor is unsafe」→ 异常直接冒泡到
    // 调用方；真机上该异常发生于事件分发链 = 白屏卡死的直接嫌疑。
    // 防御实现（show 全程 try/catch 静默降级）必须吞掉。
    TopToast.show(stale!, 'defunct 语境测试');
    expect(tester.takeException(), isNull, reason: 'show 必须吞掉 defunct 异常');
  });

  // ---------------- 多选 + 可取消（2026-09-06 真机问题 3 改造行为） ----------------

  testWidgets(
      '回炉弹窗多选：可同时勾选两格，再点已勾选格即取消，onConfirm 收「、」拼接理由',
      (tester) async {
    String? gotReason;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showModalBottomSheet<void>(
                context: ctx,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => ReasonActionDialog(
                  title: '回炉重造',
                  subtitle: '多选测试',
                  reasons: kReworkReasons,
                  noteHint: '补充说明（可选）',
                  buttonLabel: '送进回炉队列',
                  emptyReasonToast: '先选至少一个回炉原因',
                  onConfirm: (reason, note) async {
                    gotReason = reason;
                  },
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    // 底部面板滑入动画（250ms）走完再点内部控件——单帧时控件仍在屏幕外
    await tester.pump(const Duration(milliseconds: 450));

    // 初始零勾选（选中格尾随 check_circle 实心勾图标）
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing,
        reason: '初始必须零勾选');
    // 勾两格（多选行为：第二勾不挤掉第一勾——旧单选此刻只剩 1 个）
    await tester.tap(find.text('表述绕'), warnIfMissed: false);
    await tester.pump();
    await tester.tap(find.text('拆太粗'), warnIfMissed: false);
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2),
        reason: '多选：两格必须能同时选中');
    // 再点已勾选格 → 取消（旧单选不可取消）
    await tester.tap(find.text('表述绕'), warnIfMissed: false);
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget,
        reason: '再点已勾选格必须取消勾选');
    // 确认 → 弹窗关闭，onConfirm 收到剩余选中 label
    await tester.tap(find.text('送进回炉队列'), warnIfMissed: false);
    await tester.pump();
    // pop 起步帧 + 退出动画走完（单次 pump 不推进新启动的动画）
    await tester.pump(const Duration(milliseconds: 600));
    expect(gotReason, '拆太粗', reason: '确认必须传剩余选中 label');
    expect(find.byIcon(Icons.check_circle_rounded), findsNothing,
        reason: '确认后弹窗必须关闭');

    // 再开一次：双选不取消 → 按勾选顺序「、」拼接
    gotReason = null;
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.tap(find.text('答案有误'), warnIfMissed: false);
    await tester.pump();
    await tester.tap(find.text('表述绕'), warnIfMissed: false);
    await tester.pump();
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(2));
    await tester.tap(find.text('送进回炉队列'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(gotReason, '答案有误、表述绕', reason: '多选理由必须按勾选顺序「、」拼接');

    // 收尾：全树卸载（弹窗内 Ticker/Controller 释放）
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // ---------------- 空选提示节流（白屏防御之一） ----------------

  testWidgets('空选提示节流：首次必发；1200ms 窗内连点不重发（toast 时间轴不被重置）',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => showModalBottomSheet<void>(
                context: ctx,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => ReasonActionDialog(
                  title: '回炉重造',
                  subtitle: '节流测试',
                  reasons: kReworkReasons,
                  noteHint: '补充说明（可选）',
                  buttonLabel: '送进回炉队列',
                  emptyReasonToast: '先选至少一个回炉原因',
                  onConfirm: (reason, note) async {},
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    // 底部面板滑入动画（250ms）走完再点内部控件——单帧时控件仍在屏幕外
    await tester.pump(const Duration(milliseconds: 450));

    // 首次空点 → 防呆提示必须出现
    await tester.tap(find.text('送进回炉队列'), warnIfMissed: false);
    await tester.pump(); // 入场一帧（控件已在树中，透明度不影响文本断言）
    expect(find.text('先选至少一个回炉原因'), findsOneWidget,
        reason: '空选首次点击必须出防呆提示');

    // 1200ms 节流窗内连点 4 次（击间真实墙钟近乎 0，全在窗内）
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('送进回炉队列'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
    }
    // 把假时间推过首个 toast 的完整生命周期（enter 240 + stay 1200 = 1440ms）。
    // 若任何一次窗内点击重发了 toast，新 toast 会重置时间轴、此刻仍在场；
    // 节流正确（窗内全部吞掉）→ toast 按首个时间轴自然淡出移除。
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('先选至少一个回炉原因'), findsNothing,
        reason: '节流窗内连点不得重发 toast（时间轴不重置，首泡已自然走完）');

    // 窗口过期后的重发分支由真实墙钟驱动（DateTime.now() 不受测试假时钟控制，
    // testWidgets 内无法推进真实 1200ms）：行为是简单的间隔比较，代码评审
    // 保证；真机验证清单见 handoff（停 1.2s+ 再点必须重新弹提示）。

    // 收尾：弹窗开着，整树卸载释放 Ticker
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
