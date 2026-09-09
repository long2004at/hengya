// 回炉交互专项（2026-09-07 真机问题 #9/#10 修复回归）：
//
// #9  回炉理由面板键盘安全：旧版居中 Dialog 被输入法顶起时，提交按钮的命中区
//     不随视觉位移（错位点不动，须收起键盘才可点）。现以 showModalBottomSheet
//     (isScrollControlled: true) 承载 + 组件内 viewInsets.bottom 真实布局位移
//     ——测试模拟键盘（FakeViewPadding）断言：提交按钮钉在键盘上方的安全区，
//     且键盘弹出状态下直接点按钮即可命中提交（tap 默认 warnIfMissed=true，
//     点空即翻红）。
// #10① 题库回炉后卡片显示「重造中」：详情头部徽标 + 列表徽标 + 操作按钮换
//     「重造中」态；重造中的卡点击只提示、不再弹回炉面板（从入口杜绝重复提交）。
// #10② 重复回炉幂等：local 路由对重造中的重复提交返回 duplicate:true 幂等成功
//     （旧版抛 400「卡 <内部id> 状态为 rework，仅 active 可回炉」→ UI 前缀
//     「提交失败：」把内部 id 泄给用户）；UI 统一逐字提示
//     「已在回炉队列，无需重复提交」——用户可见文案不再出现内部 id。
// #15 移除废卡：rejected 卡操作排换「移除」入口（物理删除 + 二次确认），
//     「回炉」入口对 rejected/archived 隐藏（注定 400 的失败入口不再露出）；
//     /cards/rework 余下分支 400/404 文案全部去内部 id 化。
//
// 基建纪律（同 tool_white_screen_repro_test）：Windows 显式加载 test/sqlite3.dll
// （overrideForAll；python 自带 dll 跨进程 open_v2 即崩不可用）；setUp/tearDown
// 100% 同步；boot() 放用例体首行；固定 pump 不用 pumpAndSettle（隐藏分支 home
// 流光永续动画会超时挂死）；异步加载/Toast 用锚点等待循环；Toast v3 全程约
// 2440ms。
// !! 底部面板动画时序坑（showDialog→BottomSheet 承载改造后的新纪律）：
//  · 面板入场是「从底部滑入」（非 Dialog 的原地淡入）——打开后必须 pump ×2
//    （pump() + pump(450ms)）再点内部控件，单帧时控件仍在屏幕外、tap 落空；
//  · 确认后面板 pop 起退出动画——必须 pump()（起步帧）+ pump(600ms)（走完）
//    再断言面板已关。单次 pump(600) 只跑一帧、新启动的动画仅得首个 tick
//    （elapsed≈0），会停在 reverse 中间假性「未关闭」。
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/app.dart';
import 'package:hengya/pages/bank_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/db.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/widgets/reason_action_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/hengya_shared.dart'
    show CardStatus, CardType, FlashCard;
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

  // !! 同 tool_white_screen_repro_test 的两层假异步坑结论：setUp/tearDown
  // 必须 100% 同步（体内 await 安全、setup/teardown await 永挂）；后端 boot
  // 在用例体首行。
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_reworkui_');
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

  /// 测试宿主共享初始化（物理尺寸固定 800x1800、dpr=1——viewInsets 逻辑值
  /// 即物理值，键盘模拟无须换算）
  Future<void> fixView(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
  }

  /// 播种：POST /subjects 自建科目 + importCards 一张 active 卡
  /// （可进详情、可回炉；勿用内置短码，避免与「内置科目播种下线」节点耦合）
  Future<void> seedSubjectAndActiveCard() async {
    final created = await be.post('/subjects', {'name': '回炉专项课'});
    expect(created['ok'], true, reason: '自建科目必须成功');
    final subjectId = created['id'] as String;
    final seeded = await be.importCards([
      {
        'id': 'rework-ui-001',
        'subjectId': subjectId,
        'type': 'basic',
        'front': '回炉专项题干',
        'back': '回炉专项答案',
        'anchor': 'repro 第一章',
        'source': 'rework ui test',
        'status': 'active',
      },
    ]);
    expect(seeded['inserted'], 1, reason: '播种卡必须入库');
  }

  /// 进入题库详情页（列表 → 点卡 → 详情在场）。
  /// [frontText] 待点卡的题干文本；[total] 列表计数锚点（「共 N 张」）。
  Future<void> enterDetail(WidgetTester tester,
      {String frontText = '回炉专项题干', int total = 1}) async {
    await tester.pumpWidget(const HengyaApp());
    await settle(tester);
    await tapNav(tester, '题库');
    for (var i = 0; i < 14 && !tester.any(find.text('共 $total 张')); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(tester.any(find.text('共 $total 张')), isTrue, reason: '播种卡必须可查');
    await tester.tap(find.text(frontText), warnIfMissed: false);
    for (var i = 0; i < 14 && !tester.any(find.byType(BankDetailPage)); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await settle(tester);
    expect(tester.any(find.byType(BankDetailPage)), isTrue, reason: '必须进入题库详情页');
  }

  /// 打开回炉面板并等待入场动画走完（滑入动画 250ms）
  Future<void> openReworkSheet(WidgetTester tester) async {
    await tester.tap(find.text('回炉'), warnIfMissed: false);
    await settle(tester);
    expect(find.byType(ReasonActionDialog), findsOneWidget, reason: '回炉面板必须在场');
  }

  // ---------------- #10① 全链路：提交成功 → 重造中徽标 → 幂等提示逐字 ----------------

  testWidgets(
      '回炉全链路（#10①）：面板选原因+输入说明 → 提交成功 → 「重造中」徽标+按钮换态 → 点击提示幂等文案（逐字）',
      (tester) async {
    await boot();
    await fixView(tester);
    await seedSubjectAndActiveCard();
    await enterDetail(tester);
    await openReworkSheet(tester);

    // 选原因 + 输入补充说明
    await tester.tap(find.text('表述绕'), warnIfMissed: false);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '题干再直白一点');
    await tester.pump();

    // 提交 → 面板关闭（pump() 起步帧 + pump(600) 退出动画走完——见文件头时序坑）
    await tester.tap(find.text('送进回炉队列'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(ReasonActionDialog), findsNothing, reason: '提交后面板必须关闭');

    // 成功提示逐字（_load 异步刷新 → 锚点等待）
    const successToast = '已送进回炉队列，重造后回待审核池';
    for (var i = 0; i < 14 && !tester.any(find.text(successToast)); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text(successToast), findsOneWidget, reason: '提交成功必须出成功提示（逐字）');
    await tester.pump(const Duration(milliseconds: 100)); // 详情重载帧

    // #10① 徽标：详情头部「重造中」徽标 + 操作按钮换「重造中」态（两处同文案）
    expect(find.text('重造中'), findsNWidgets(2),
        reason: '「重造中」徽标（头部）与操作按钮换态都必须在场');

    // 重造中的卡禁再次回炉：点按钮 → 只提示（逐字、不含内部 id），不再弹面板
    expect(find.byIcon(Icons.autorenew_rounded), findsOneWidget,
        reason: '「重造中」按钮图标必须在场');
    await tester.tap(find.byIcon(Icons.autorenew_rounded));
    await tester.pump(); // toast 入场帧（控件已在树中，透明度不影响文本断言）
    const dupToast = '已在回炉队列，无需重复提交';
    expect(find.text(dupToast), findsOneWidget, reason: '重造中卡点击必须出幂等提示（逐字）');
    expect(find.byType(ReasonActionDialog), findsNothing,
        reason: '重造中的卡不得再弹回炉面板');
    expect(find.textContaining('提交失败'), findsNothing,
        reason: '幂等路径不得出现「提交失败」（旧版把内部 id 泄进用户文案）');

    // #10① 列表面：按详情页 AppBar 返回键退回题库列表，卡片同样显示「重造中」徽标
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450)); // 详情页退场过渡
    for (var i = 0; i < 14 && tester.any(find.byType(BankDetailPage)); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(BankDetailPage), findsNothing,
        reason: '返回键必须退出详情页回到题库列表');
    for (var i = 0; i < 14 && !tester.any(find.text('重造中')); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('重造中'), findsOneWidget,
        reason: '回到题库列表后，重造中的卡必须显示「重造中」徽标');

    // 收尾：全树卸载（Toast/面板 Ticker 全部释放），无残留异常
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // ---------------- #9 键盘安全：键盘弹出时提交按钮可定位可点 ----------------

  testWidgets(
      '键盘安全（#9）：模拟键盘弹出（viewInsets）时「送进回炉队列」钉在键盘上方，不收键盘直接点即命中提交',
      (tester) async {
    await boot();
    await fixView(tester);
    await seedSubjectAndActiveCard();
    await enterDetail(tester);
    await openReworkSheet(tester);

    // 选原因（提交前置）
    await tester.tap(find.text('表述绕'), warnIfMissed: false);
    await tester.pump();

    // 键盘弹出：模拟 viewInsets.bottom = 420（dpr 已固定 1.0，逻辑值即物理值）
    tester.view.viewInsets = const FakeViewPadding(bottom: 420);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 面板位移重排稳定

    // 提交按钮必须整体钉在键盘上方（键盘顶 = 屏高 1800 - 420 = 1380；
    // 面板 margin 12 → 按钮至少离键盘线 12px）
    final btnRect = tester.getRect(find.text('送进回炉队列'));
    expect(btnRect.bottom, lessThan(1380),
        reason: '提交按钮必须位于键盘上方的安全区（视觉位置）');

    // 不收起键盘直接点提交：默认 warnIfMissed=true——命中区若不随视觉位移
    // （旧版错位 bug）此处必翻红；命中即证明视觉位置 == 命中区
    await tester.tap(find.text('送进回炉队列'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // 面板 pop 走完
    expect(find.byType(ReasonActionDialog), findsNothing,
        reason: '键盘弹出时点提交必须正常关面板');

    const successToast = '已送进回炉队列，重造后回待审核池';
    for (var i = 0; i < 14 && !tester.any(find.text(successToast)); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(tester.any(find.text(successToast)), isTrue,
        reason: '键盘弹出时提交按钮必须可点且提交成功');
    expect(tester.takeException(), isNull);

    // 收尾：全树卸载，无残留异常
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  // ---------------- #10② 路由幂等：重造中的重复提交不报错、不重复入队 ----------------

  test('路由幂等（#10②）：重复回炉重造中的卡 → duplicate:true 幂等成功、不重复入队；pending 卡守卫不变',
      () async {
    await boot();
    // 播种：一 active（可回炉）+ 一 pending（守卫对照）
    final created = await be.post('/subjects', {'name': '回炉专项课'});
    final subjectId = created['id'] as String;
    final seeded = await be.importCards([
      {
        'id': 'rework-ui-001',
        'subjectId': subjectId,
        'type': 'basic',
        'front': '回炉专项题干',
        'back': '回炉专项答案',
        'anchor': 'repro 第一章',
        'source': 'rework ui test',
        'status': 'active',
      },
      {
        'id': 'rework-ui-pending',
        'subjectId': subjectId,
        'type': 'basic',
        'front': '守卫对照题干',
        'back': '守卫对照答案',
        'anchor': 'repro 第二章',
        'source': 'rework ui test',
        'status': 'pending',
      },
    ]);
    expect(seeded['inserted'], 2, reason: '播种卡必须入库');

    // 首次回炉：正常入队，无 duplicate 标记
    final first = await be.post(
        '/cards/rework', {'cardId': 'rework-ui-001', 'reason': '表述绕', 'note': ''});
    expect(first['ok'], true, reason: '首次回炉必须成功');
    expect(first['duplicate'], isNot(true), reason: '首次提交不得带 duplicate 标记');

    // 重复回炉同一卡：幂等成功（旧版此处抛 400「卡 <内部id> 状态为 rework…」
    // → UI 前缀「提交失败：」把内部 id 泄给用户）
    final again = await be.post(
        '/cards/rework', {'cardId': 'rework-ui-001', 'reason': '表述绕', 'note': ''});
    expect(again['ok'], true, reason: '重复回炉必须幂等成功（不抛 ApiException）');
    expect(again['duplicate'], true, reason: '重复回炉必须带 duplicate 标记');

    // 幂等 = 不重复入队：该卡在回炉队列中只有一条 pending 项
    final rq = await be.get('/cards/rework/pending');
    final queue = (rq['queue'] as List).cast<Map<String, dynamic>>();
    expect(queue.where((r) => r['cardId'] == 'rework-ui-001').length, 1,
        reason: '重复提交不得重复入队');

    // 守卫语义不变：pending 卡回炉仍 400（幂等只放行「重造中」重复提交）。
    // #15：文案去内部 id 化——逐字断言新文案（旧版泄「卡 <内部id> 状态为…」）
    await expectLater(
      be.post('/cards/rework', {'cardId': 'rework-ui-pending', 'reason': '绕'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)
          .having((e) => e.message, 'message',
              '该卡当前状态不支持回炉（仅审核通过的在学卡可回炉）')),
    );
  });

  // ---------------- #10② db 层幂等判据：cardInReworkQueue ----------------

  test('db 层幂等判据（#10②）：cardInReworkQueue——rework 卡 true；拒绝带理由卡（也登记队列）必须 false',
      () async {
    final db = await Db.open('${tmp.path}/hengya.db');
    addTearDown(db.close);
    db.insertSubject(id: 'rwsubj', name: '回炉判据课');

    // active 卡回炉 → 重造中：预检必须翻真
    db.importCard(FlashCard(
      id: 'rw-active-001',
      subjectId: 'rwsubj',
      type: CardType.basic,
      front: '判据A',
      back: '答案A',
      anchor: '',
      source: 'db contract test',
      status: CardStatus.active,
    ));
    expect(db.cardInReworkQueue('rw-active-001'), false,
        reason: 'active 卡不在回炉队列');
    db.reworkCard('rw-active-001', '表述绕', '');
    expect(db.cardInReworkQueue('rw-active-001'), true,
        reason: '回炉后（重造中）预检必须为真');

    // 审核拒绝带理由：也登记 rework_queue，但卡状态是 rejected——
    // 仅查队列会误判，预检判据必须以状态为准
    db.importCard(FlashCard(
      id: 'rw-pending-001',
      subjectId: 'rwsubj',
      type: CardType.basic,
      front: '判据B',
      back: '答案B',
      anchor: '',
      source: 'db contract test',
      status: CardStatus.pending,
    ));
    db.rejectCardWithReason('rw-pending-001', '答案有误', '');
    expect(db.cardInReworkQueue('rw-pending-001'), false,
        reason: '拒绝卡登记过队列但状态是 rejected——不得误判成重造中');
  });

  // ---------------- #15 rejected 废卡移除：入口 + 二次确认 + 列表消失 ----------------

  testWidgets(
      '移除废卡全链路（#15）：rejected 卡显示「移除」不显示「回炉」→ 二次确认弹窗逐字 → 取消不删 → 确认后「已移除」+ 卡从列表消失',
      (tester) async {
    await boot();
    await fixView(tester);
    // 播种 pending 卡 → 拒绝成 rejected（带理由 → 正常登记队列行）
    final created = await be.post('/subjects', {'name': '移除专项课'});
    final subjectId = created['id'] as String;
    final seeded = await be.importCards([
      {
        'id': 'remove-ui-001',
        'subjectId': subjectId,
        'type': 'basic',
        'front': '移除专项废卡题干',
        'back': '移除专项废卡答案',
        'anchor': 'removeui 第一章',
        'source': 'remove ui test',
        'status': 'pending',
      },
    ]);
    expect(seeded['inserted'], 1, reason: '播种卡必须入库');
    final rej =
        await be.post('/cards/remove-ui-001/reject', {'reason': '答案有误'});
    expect(rej['status'], 'rejected', reason: '播种卡必须已是 rejected 废卡');

    await enterDetail(tester, frontText: '移除专项废卡题干');

    // #15 入口断言：rejected 卡操作排有「移除」无「回炉」（注定失败的入口不再露出）
    expect(find.byIcon(Icons.delete_outline_outlined), findsOneWidget,
        reason: 'rejected 卡必须显示「移除」按钮（垃圾桶图标）');
    expect(find.text('移除'), findsOneWidget, reason: '「移除」按钮文案必须在场');
    expect(find.text('回炉'), findsNothing,
        reason: 'rejected 卡不得显示注定失败的「回炉」入口');
    expect(find.text('重造中'), findsNothing, reason: '非重造卡不得显示「重造中」');

    // 点「移除」→ 二次确认弹窗（标题/警示文案/按钮逐字）
    await tester.tap(find.byIcon(Icons.delete_outline_outlined),
        warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450)); // Dialog 入场
    expect(find.text('移除废卡'), findsOneWidget, reason: '确认弹窗标题逐字');
    expect(find.textContaining('移除后不可恢复'), findsOneWidget,
        reason: '警示文案必须含「移除后不可恢复」');
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('确认移除'), findsOneWidget);

    // 取消路径：弹窗关闭、卡仍在（不调后端）
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('确认移除'), findsNothing, reason: '取消后弹窗必须关闭');
    expect(tester.any(find.text('移除专项废卡题干')), isTrue,
        reason: '取消不得删卡');
    expect(find.text('已移除'), findsNothing, reason: '取消不得出成功提示');

    // 再开弹窗 → 确认移除
    await tester.tap(find.byIcon(Icons.delete_outline_outlined),
        warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    await tester.tap(find.text('确认移除'));
    await tester.pump(); // dialog pop 起步帧 + removeCard 微任务

    // 成功提示逐字（TopToast 挂 rootOverlay，先 toast 后 pop 都在场）
    const removedToast = '已移除';
    for (var i = 0; i < 14 && !tester.any(find.text(removedToast)); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text(removedToast), findsOneWidget,
        reason: '移除成功必须出「已移除」提示（逐字）');

    // 确认后自动 pop 回题库列表（dataVersion 已 bump → 列表自动重查）
    for (var i = 0; i < 14 && tester.any(find.byType(BankDetailPage)); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(BankDetailPage), findsNothing,
        reason: '确认移除后必须自动返回题库列表');

    // 卡从列表消失：计数归零 + 题干不在场 + 无失败提示
    for (var i = 0; i < 14 && !tester.any(find.text('共 0 张')); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.text('共 0 张'), findsOneWidget, reason: '移除后列表计数必须归零');
    expect(find.text('移除专项废卡题干'), findsNothing,
        reason: '被移除的卡必须从列表消失');
    expect(find.textContaining('移除失败'), findsNothing,
        reason: '成功路径不得出现失败提示');

    // 收尾：全树卸载（Toast Ticker 全部释放），无残留异常
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      '移除入口守卫（#15）：active 卡只显示「回炉」无「移除」；archived 卡无「回炉」无「移除」（防呆）',
      (tester) async {
    await boot();
    await fixView(tester);
    final created = await be.post('/subjects', {'name': '移除守卫课'});
    final subjectId = created['id'] as String;
    final seeded = await be.importCards([
      {
        'id': 'guard-active-001',
        'subjectId': subjectId,
        'type': 'basic',
        'front': '守卫active题干',
        'back': '守卫active答案',
        'anchor': '',
        'source': 'guard ui test',
        'status': 'active',
      },
      {
        'id': 'guard-archived-001',
        'subjectId': subjectId,
        'type': 'basic',
        'front': '守卫archived题干',
        'back': '守卫archived答案',
        'anchor': '',
        'source': 'guard ui test',
        'status': 'archived',
      },
    ]);
    expect(seeded['inserted'], 2, reason: '播种两卡必须入库');

    // active 卡：有「回炉」无「移除」（既有回炉行为零回归）
    await enterDetail(tester, frontText: '守卫active题干', total: 2);
    expect(find.text('回炉'), findsOneWidget,
        reason: 'active 卡「回炉」入口必须在场（既有行为零回归）');
    expect(find.text('移除'), findsNothing, reason: 'active 卡不得显示「移除」');
    expect(find.byIcon(Icons.delete_outline_outlined), findsNothing,
        reason: 'active 卡不得出现移除图标');

    // 返回列表 → archived 卡：既无「回炉」也无「移除」
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450)); // 详情页退场过渡
    for (var i = 0; i < 14 && tester.any(find.byType(BankDetailPage)); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    expect(find.byType(BankDetailPage), findsNothing,
        reason: '返回键必须退出详情页回到题库列表');
    await tester.tap(find.text('守卫archived题干'), warnIfMissed: false);
    for (var i = 0; i < 14 && !tester.any(find.byType(BankDetailPage)); i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await settle(tester);
    expect(find.byType(BankDetailPage), findsOneWidget,
        reason: '必须进入 archived 卡详情');
    expect(find.text('回炉'), findsNothing,
        reason: 'archived 卡不得显示注定失败的「回炉」入口');
    expect(find.text('移除'), findsNothing,
        reason: 'archived 卡不得显示「移除」（仅 rejected 可移除）');
    expect(find.text('备注'), findsOneWidget,
        reason: '备注按钮恒显（不受状态影响）');

    // 收尾：全树卸载，无残留异常
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
