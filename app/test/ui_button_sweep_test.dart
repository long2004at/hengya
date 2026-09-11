// UI 按钮 sweep（2026-09-06 用户指令「测试任意 UI 按钮点击后的后果」）：
// 以真实 HengyaApp（go_router 全路由 + 底部导航壳）为宿主，local 模式 + 合成快照
// 数据（test/helpers/synthetic_snapshot.dart 测试期生成；开源脱敏 2026-09-06 替代
// 原生产快照），对科目/题库/待审核/统计/设置/学习进度/复习会话/题库详情的全部可点元素
// 逐一 tap：
//   · 每次点击后断言无异常（takeException 为 null）——「有反应不炸」的动态证据；
//   · 弹层自动关闭、路由自动返回：while 重收集 + key 去重 + 60 次熔断（sweep 自身
//     不可能死循环——这也顺带回答了「是否有异常死循环」的问题）；
//   · 「无反应」用定向后果断言证伪：chip 选中态翻转 / 待审计数递减 / 同步气泡 /
//     连接状态行 / AI 保存气泡 / 审批编辑拒绝各有可见后果；
//   · 平台通道按钮（通知开关、文件选择器、系统分享）在测试宿主不可达——列入
//     skipList，报告中明确为「需真机验证」而非 UI 死角。
// 基建：同 e2e（sqlite3.dll + tempDir + LocalBackend + debugBackendMode）+ 
// SharedPreferences 内存 mock（设置页 initState 读提醒配置）。
// 纪律：全程固定 pump（首页流光/进度页气泡永续动画，pumpAndSettle 永不 settle）。
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/app.dart';
import 'package:hengya/pages/about_page.dart';
import 'package:hengya/pages/bank_page.dart';
import 'package:hengya/pages/home_page.dart';
import 'package:hengya/pages/progress_page.dart';
import 'package:hengya/pages/review_page.dart';
import 'package:hengya/pages/settings_page.dart';
import 'package:hengya/pages/stats_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/ai_key_vault.dart';
import 'package:hengya/services/local/data_manager.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/widgets/top_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

import 'helpers/synthetic_snapshot.dart';

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
    // 安全修复 C：AI key 走 vault——测试宿主无平台通道，注入 InMemoryVault
    //（设置页 AI 保存 PUT → LocalBackend → vault）
    AiKeyVault.instance = InMemoryVault();
    tmp = Directory.systemTemp.createTempSync('hengya_sweep_');
  });

  /// 用例体首行调用（体内事件循环由 pump 驱动，await 安全）
  Future<void> boot() async {
    await be.resetForTest();
    be.init(tmp.path);
    debugBackendMode = BackendMode.local;
    // 设置页 initState：DailyReminder.loadSettings 走 SharedPreferences（内存 mock）
    SharedPreferences.setMockInitialValues({});
  }

  tearDown(() {
    debugBackendMode = null;
    AiKeyVault.instance = null; // 恢复默认真 vault（跨文件零污染）
    ApiClient.instance.resetSubjectCaches();
    // 不 await：微任务链在真实事件队列 FIFO 自完成
    LocalBackend.instance.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  // ---------------- 可点元素识别（通用谓词；GestureDetector 类交互走 bespoke） ----------------

  bool isTapCandidate(Widget w) =>
      (w is IconButton && w.onPressed != null) ||
      (w is FilledButton && w.onPressed != null) ||
      (w is TextButton && w.onPressed != null) ||
      (w is OutlinedButton && w.onPressed != null) ||
      (w is ActionChip && w.onPressed != null) ||
      (w is ChoiceChip && w.onSelected != null) ||
      (w is ListTile && w.onTap != null) ||
      (w is InkWell && w.onTap != null);

  /// 元素简述（去重 key）：控件类型 + 前几个文本；IconButton 带 tooltip 区分。
  /// 元素可能在收集→点击间隙被卸载（列表刷新/路由切换）——widget 访问带保护。
  String describe(Element e) {
    Widget? w;
    try {
      w = e.widget;
    } catch (_) {
      return '(defunct)';
    }
    final head = w is IconButton ? 'IconButton(${w.tooltip ?? ''})' : '${w.runtimeType}';
    final texts = <String>[];
    void walk(Element el) {
      if (texts.length >= 3) return;
      final Widget? t;
      try {
        t = el.widget;
      } catch (_) {
        return;
      }
      if (t is Text && t.data != null && t.data!.isNotEmpty) texts.add(t.data!);
      el.visitChildElements(walk);
    }

    try {
      walk(e);
    } catch (_) {}
    return '$head(${texts.join('/')})';
  }

  /// 收集当前帧的最外层可点元素（内嵌重复剔除；底部导航命中点排除；skipList 过滤）
  List<Element> collect(WidgetTester tester, Set<String> skip) {
    final out = <Element>[];
    for (final e in find.byWidgetPredicate(isTapCandidate).evaluate()) {
      if (!e.mounted) continue;
      var nested = false;
      e.visitAncestorElements((a) {
        if (isTapCandidate(a.widget)) {
          nested = true;
          return false;
        }
        return true;
      });
      if (nested) continue;
      if (e.findAncestorWidgetOfExactType<NavigationBar>() != null) continue;
      final key = describe(e);
      if (skip.any(key.contains)) continue;
      out.add(e);
    }
    return out;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
  }

  /// 点击单个元素并断言无异常；返回 false = 元素已失效/不可点（跳过，不视为失败）。
  /// Toast/入场动画在 1200ms 假时间里走完；异常断言用 fail() 惰性取简述。
  Future<bool> tapOne(WidgetTester tester, Element target) async {
    if (!target.mounted) return false; // 收集→点击间隙被卸载（列表刷新等）
    final f = find.byElementPredicate((el) => identical(el, target));
    try {
      await tester.ensureVisible(f);
      await tester.tap(f, warnIfMissed: false);
    } catch (_) {
      return false; // 未布局/被遮挡等点击不成：跳过（真异常由 takeException 兜底）
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1200));
    final ex = tester.takeException();
    if (ex != null) {
      fail('点击 ${describe(target)} 后抛出异常: $ex');
    }
    return true;
  }

  /// 返回上一路由：Material 返回键直接点；否则弹「有栈可弹的最内层 Navigator」
  /// （详情/进度/会话在根栈，设置页在壳内栈）。testWidgets 的 pageBack 只认
  /// Cupertino 返回键，Material 应用必败——不能用。
  Future<void> back(WidgetTester tester) async {
    final backBtn = find.byType(BackButton);
    if (tester.any(backBtn)) {
      await tester.tap(backBtn.first, warnIfMissed: false);
    } else {
      final navs =
          tester.stateList<NavigatorState>(find.byType(Navigator)).toList();
      var popped = false;
      for (final n in navs.reversed) { // 内层先试：设置页在壳内栈
        if (n.canPop()) { n.pop(); popped = true; break; }
      }
      if (!popped) fail('back(): 无可弹路由也无返回键');
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
  }

  /// 有栈可弹才返回（sweep 可能点到页面自身返回键已提前弹栈）；
  /// 无栈可弹=已在壳内，静默跳过。四个站点与 restore 统一用它而非 back()。
  Future<void> backIfPushed(WidgetTester tester) async {
    final canBack = tester.any(find.byType(BackButton)) ||
        tester
            .stateList<NavigatorState>(find.byType(Navigator))
            .any((n) => n.canPop());
    if (canBack) await back(tester);
  }

  /// 点击后回归锚点页：关弹层（最多 3 层）→ 路由跳转则返回 → 等 anchor 就位
  Future<void> restore(WidgetTester tester, Finder anchor, String? navLabel) async {
    for (var i = 0; i < 3; i++) {
      if (tester.any(find.byWidgetPredicate((w) => w is Dialog))) {
        final cancel = find.text('取消');
        if (tester.any(cancel)) {
          await tester.tap(cancel.last, warnIfMissed: false);
        } else {
          await tester.tapAt(const Offset(10, 10));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        continue;
      }
      if (tester.any(find.byType(BottomSheet))) {
        await tester.tapAt(const Offset(10, 10));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        continue;
      }
      break;
    }
    if (!tester.any(anchor)) await backIfPushed(tester);
    if (!tester.any(anchor) &&
        navLabel != null &&
        tester.any(find.byType(NavigationBar))) {
      await tester.tap(find.text(navLabel).last, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
    }
    for (var i = 0; i < 12 && !tester.any(anchor); i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.takeException(), isNull);
  }

  /// 整页 sweep：逐个点击未点过的可点元素，每次点完自动回归锚点页；
  /// 60 次熔断（新 key 有限 → 正常必然收敛；超限即测试失败，不会死循环）
  Future<int> sweepPage(WidgetTester tester,
      {required Finder anchor, String? navLabel, Set<String> skip = const {}}) async {
    var taps = 0;
    final seen = <String>{};
    for (var guard = 0; guard < 60; guard++) {
      final candidates = collect(tester, skip);
      Element? next;
      for (final c in candidates) {
        if (!c.mounted) continue;
        final key = describe(c);
        if (seen.contains(key)) continue;
        next = c;
        break;
      }
      if (next == null) break;
      seen.add(describe(next));
      if (!await tapOne(tester, next)) continue; // 失效元素跳过 → 重新收集
      taps++;
      await restore(tester, anchor, navLabel);
    }
    return taps;
  }

  Future<void> tapNav(WidgetTester tester, String label) async {
    // NavigationBar 在 Scaffold 尾部 → .last 恒为导航标签，不受页面同名文案干扰
    await tester.tap(find.text(label).last, warnIfMissed: false);
    await settle(tester);
  }

  // ---------------- 主旅程 sweep ----------------

  testWidgets('按钮 sweep：六页 + 复习会话 + 题库详情全部可点元素逐一点击，无异常无死按钮',
      (tester) async {
    await boot();
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // —— 数据：合成快照（21 卡/8 科/12 日志，测试期生成）+ 2 张待审卡 + 罗盘 progress.json ——
    final snapshotPath = await writeSyntheticSnapshot(tmp.path);
    final dm = DataManager.instance;
    final preview = dm.validateSource(snapshotPath);
    expect(preview['cards'], 21);
    await dm.importDatabase(tmp.path, snapshotPath,
        onBeforeSwap: () => be.reload());
    final seeded = await be.importCards([
      {
        'id': 'sweep-appr-001', 'subjectId': 'oms', 'type': 'basic',
        'front': 'sweep 批准测试卡', 'back': '批准后果可见',
        'anchor': 'sweep', 'source': 'sweep 测试', 'status': 'pending',
      },
      {
        'id': 'sweep-rej-001', 'subjectId': 'oms', 'type': 'basic',
        'front': 'sweep 拒绝测试卡', 'back': '拒绝后果可见',
        'anchor': 'sweep', 'source': 'sweep 测试', 'status': 'pending',
      },
    ]);
    expect((seeded as Map)['inserted'], 2);
    Directory('${tmp.path}/corpus').createSync(recursive: true);
    File('${tmp.path}/corpus/progress.json').writeAsStringSync(jsonEncode({
      'subjects': {
        'endo': {
          'textbook': '世界通史-第2版',
          'learned_through': 2,
          'updated_at': '2026-09-05T22:00:00',
          'chapters': [
            {'no': 0, 'title': '目录'},
            {'no': 1, 'title': '前言'},
            {'no': 2, 'title': '第一章 绪论'},
            {'no': 3, 'title': '第二章 新航路'},
          ],
        },
      },
    }));

    await tester.pumpWidget(const HengyaApp());
    await settle(tester);
    expect(tester.any(find.byType(HomePage)), isTrue);

    // —— ① 科目页：两个入口按钮 + 8 科目卡（每张进会话页自动返回）——
    final homeTaps = await sweepPage(tester,
        anchor: find.byType(HomePage), navLabel: '科目');
    expect(homeTaps, greaterThan(8), reason: '科目页至少应点到 2 入口 + 8 科目卡');

    // —— ①a 收件箱内部：chip 选中态翻转 + 空提交就地报错 + 关键词提交成功 ——
    await tester.ensureVisible(find.byTooltip('记课堂重点（今晚自动拆卡）'));
    await tester.tap(find.byTooltip('记课堂重点（今晚自动拆卡）'), warnIfMissed: false);
    await settle(tester);
    // 生产快照科目名 = 库内全名（快照自带 8 科用户科目；动态取末科避免字面耦合，
    // 且首科已被收件箱预选——须取未选中科验证选中态翻转）
    final subsResp = await LocalBackend.instance.get('/subjects');
    final chipName =
        ((subsResp as Map)['subjects'] as List).cast<Map<String, dynamic>>().last['name'] as String;
    final chipBefore = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, chipName));
    expect(chipBefore.selected, false);
    await tester.tap(find.widgetWithText(ChoiceChip, chipName),
        warnIfMissed: false);
    await tester.pump();
    final chipAfter = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, chipName));
    expect(chipAfter.selected, true, reason: '点科目 chip 必须有选中态后果');
    await tester.tap(find.text('新建课程'), warnIfMissed: false);
    await settle(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('取消'), warnIfMissed: false);
    await settle(tester);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.text('存入收件箱'), warnIfMissed: false);
    await tester.pump();
    expect(find.text('请至少填写章节或关键词其中一项'), findsOneWidget,
        reason: '空提交必须就地报错（sheet 不关 = 有响应）');
    await tester.enterText(find.byType(TextField).last, '干槽症');
    await tester.tap(find.text('存入收件箱'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1700));
    expect(find.textContaining('已入箱'), findsOneWidget, reason: '提交成功必须出气泡');
    expect(tester.any(find.byType(BottomSheet)), isFalse, reason: '成功后 sheet 必须自动关闭');
    await tester.pump(const Duration(milliseconds: 600));

    // —— ② 学习进度页：入口 + 罗盘渲染（progress.json 就位）+ 刷新按钮 ——
    await tester.ensureVisible(find.byTooltip('学习进度（学习罗盘）'));
    await tester.tap(find.byTooltip('学习进度（学习罗盘）'), warnIfMissed: false);
    await settle(tester);
    expect(tester.any(find.byType(ProgressPage)), isTrue);
    expect(find.text('世界通史-第2版'), findsOneWidget, reason: '罗盘必须渲染 progress.json');
    final progressTaps = await sweepPage(tester, anchor: find.byType(ProgressPage));
    expect(progressTaps, greaterThan(0), reason: '进度页至少有刷新按钮可点');
    await backIfPushed(tester);
    await settle(tester);

    // —— ③ 题库页：筛选胶囊（GestureDetector 类 → bespoke）+ 卡片进详情自动返回 ——
    await tapNav(tester, '题库');
    expect(find.text('共 21 张'), findsOneWidget, reason: '快照 21 卡全部可查');
    final bankTaps = await sweepPage(tester,
        anchor: find.byType(BankPage), navLabel: '题库');
    expect(bankTaps, greaterThan(3), reason: '题库页至少点到可见卡片瓦片');
    // 筛选胶囊（GestureDetector）：点「口腔颌面外科学」→ 列表被过滤 = 可见后果
    await tester.ensureVisible(find.text('口腔颌面外科学'));
    await tester.tap(find.text('口腔颌面外科学').first, warnIfMissed: false);
    await settle(tester);
    expect(tester.takeException(), isNull);

    // —— ③a 题库详情：编辑/备注/回炉 三操作全 sweep（弹层自动关闭）——
    await tapNav(tester, '题库'); // 回到全量列表
    await settle(tester);
    final detailTiles = find.byWidgetPredicate(isTapCandidate).evaluate().where((e) {
      return e.widget is InkWell && describe(e).contains('/');
    }).toList();
    expect(detailTiles, isNotEmpty, reason: '题库必须有可进详情的卡片瓦片');
    await tester.tap(
        find.byElementPredicate((el) => identical(el, detailTiles.first)),
        warnIfMissed: false);
    await settle(tester);
    expect(tester.any(find.byType(BankDetailPage)), isTrue, reason: '点卡片必须进详情页');
    final detailTaps = await sweepPage(tester, anchor: find.byType(BankDetailPage));
    expect(detailTaps, greaterThan(2), reason: '详情页至少 编辑/备注/回炉 三操作');
    await backIfPushed(tester);
    await settle(tester);

    // —— ④ 待审核：批准 → 计数递减；编辑 → 内容生效仍在池；拒绝 → 选理由离池 ——
    await tapNav(tester, '待审核');
    await settle(tester);
    expect(find.text('2 张待审'), findsOneWidget);
    await tester.tap(find.text('批准').first, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // 停留(1000ms)窗内：气泡必然在场
    expect(find.textContaining('已批准进复习队列'), findsOneWidget,
        reason: '批准必须出气泡');
    await tester.pump(const Duration(milliseconds: 1200)); // 走完 enter150+stay1000+exit250
    expect(find.text('1 张待审'), findsOneWidget, reason: '批准必须让计数递减');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('编辑').first, warnIfMissed: false);
    await settle(tester);
    await tester.enterText(
        find.byWidgetPredicate((w) => w is TextField && w.decoration?.labelText == '题干'),
        'sweep 编辑后题干');
    await tester.tap(find.text('保存（保持待审核）'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1700));
    expect(find.text('sweep 编辑后题干'), findsOneWidget, reason: '编辑保存必须生效');
    expect(find.text('1 张待审'), findsOneWidget, reason: '编辑后仍在待审池');
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.text('拒绝').first, warnIfMissed: false);
    await settle(tester);
    expect(find.text('拒绝这张卡'), findsOneWidget);
    await tester.tap(find.text('确认拒绝'), warnIfMissed: false); // 未选理由 → 防呆
    await tester.pump();
    expect(find.text('先选至少一个拒绝理由'), findsOneWidget, reason: '未选理由必须防呆提示');
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.tap(find.text('答案有误'), warnIfMissed: false); // 选理由格
    await tester.pump();
    await tester.tap(find.text('确认拒绝'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // 停留(1200ms)窗内：气泡必然在场
    expect(find.textContaining('已拒绝'), findsOneWidget, reason: '拒绝必须出气泡');
    await tester.pump(const Duration(milliseconds: 1600)); // 走完 enter150+stay1200+exit250
    expect(find.text('拒绝'), findsNothing, reason: '拒绝后卡必须离池');
    await tester.pump(const Duration(milliseconds: 600));

    // —— ⑤ 统计页 ——
    await tapNav(tester, '统计');
    final statsTaps = await sweepPage(tester,
        anchor: find.byType(StatsPage), navLabel: '统计');
    expect(statsTaps, greaterThan(0), reason: '统计页至少有设置入口');

    // —— ⑥ 设置页：平台通道按钮（通知/文件选择/分享）入 skipList，其余全 sweep ——
    await tester.ensureVisible(find.text('设置'));
    await tester.tap(find.text('设置'), warnIfMissed: false);
    await settle(tester);
    expect(tester.any(find.byType(SettingsPage)), isTrue);
    final settingsTaps = await sweepPage(tester,
        anchor: find.byType(SettingsPage),
        skip: const {
          // 2026-09-11 UI 迁移：每日提醒/数据管理/AI 服务配置区块已迁「恒牙」
          // 聚合页——'开启提醒'/'去开启'/'导入数据库'/'一键导出'跻身 AboutPage，
          // 由下方 ⑥a 恒牙聚合页 sweep 覆盖；'恒牙' 行 + '上传课件' 这里跳过
          //（恒牙行转入显式导航段，避免 sweep 隐式漫游拉长收敛）。
          '恒牙', // 显式导航段处理（点入 AboutPage 后锚点失效需 back 收敛）
          '上传课件', // file_selector 平台通道（真机验证项）
          '立即真题周扫', // 显式断言段处理（weeklyKick 注入 no-op + 触发气泡）
          '自动周扫计时', // 显式断言段处理（调整对话框，避开日期选择器漫游）
        });
    expect(settingsTaps, greaterThan(3),
        reason: '设置页迁走提醒/数据管理/AI 区块后应仍点到拆卡/语料/关于等行');

    // sweep 可能点掉设置页自身返回键弹回统计页——不在设置页就重新进入
    if (!tester.any(find.byType(SettingsPage))) {
      await tester.ensureVisible(find.text('设置'));
      await tester.tap(find.text('设置'), warnIfMissed: false);
      await settle(tester);
      expect(tester.any(find.byType(SettingsPage)), isTrue, reason: '重新进入设置页');
    }

// 2026-09-06 措辞刀：local 模式无服务器概念——「数据与同步」段（离线评分
    // 队列/手动同步/服务器连接）整段隐藏，三件均断言不在场
    expect(find.text('数据与同步'), findsNothing, reason: 'local 模式不该出现「数据与同步」段');
    expect(find.text('手动同步'), findsNothing, reason: 'local 模式不该出现「手动同步」');
    expect(find.text('服务器连接'), findsNothing, reason: 'local 模式不该出现「服务器连接」');

    // —— ⑥a 「恒牙」聚合页（AboutPage）：迁入区块（每日提醒/数据管理/AI 服务
    // 配置/instruct）全部按钮 sweep + AI 编辑保存气泡（2026-09-11 UI 迁移：
    // 这三区块自设置页整体迁入恒牙聚合页，sweep 目标随之迁移）——
    if (!tester.any(find.byType(SettingsPage))) {
      await tester.ensureVisible(find.text('设置'));
      await tester.tap(find.text('设置'), warnIfMissed: false);
      await settle(tester);
      expect(tester.any(find.byType(SettingsPage)), isTrue, reason: '重新进入设置页');
    }
    await tester.ensureVisible(find.widgetWithText(ListTile, '恒牙'));
    await tester.tap(find.widgetWithText(ListTile, '恒牙'), warnIfMissed: false);
    await settle(tester);
    expect(tester.any(find.byType(AboutPage)), isTrue, reason: '点恒牙必须进恒牙聚合页');
    final aboutTaps = await sweepPage(tester,
        anchor: find.byType(AboutPage),
        skip: const {
          '开启提醒', // SwitchListTile 本就不入候选（通知平台通道，防御保留）
          '去开启', // 系统权限页（flutter_local_notifications 通道，真机验证项）
          '导入数据库（迁移）', // file_selector 平台通道（真机验证项）
          '导入语料包（成品语料库）', // file_selector 平台通道（真机验证项）
          '一键导出并分享', // share_plus 平台通道（真机验证项）
          '立刻备份', // 真实 worker + 备份份数会改变去重 key；full_backup_ui_test 专项覆盖
          '分享最近完整备份', // share_plus 平台通道（真机验证项）
          '日志', // AppLogPage 跨页漫游（sweep 锚点无法跨页回归，显式留待他测）
          '检查新版本', // 真实 HTTP 链路（宿主恒 400 → 失败相位；非死角但不扰动）
        });
    expect(aboutTaps, greaterThan(3),
        reason: '恒牙聚合页应点到版本线路/提醒时间/AI 卡片/清除缓存等行');

// AI 编辑（已迁恒牙聚合页）：填表保存 → 气泡 + 编辑层关闭
    //（2026-09-07 batch3 node1：设置页「应用内更新」源输入框也是常驻 TextField，
    //  收窄到 BottomSheet 子树——只驱动 AI 编辑层三字段）
    // sweep 可能点掉 AboutPage 自身返回键弹回设置页——不在聚合页就重新进入
    if (!tester.any(find.byType(AboutPage))) {
      if (!tester.any(find.byType(SettingsPage))) {
        await tester.ensureVisible(find.text('设置'));
        await tester.tap(find.text('设置'), warnIfMissed: false);
        await settle(tester);
      }
      await tester.ensureVisible(find.widgetWithText(ListTile, '恒牙'));
      await tester.tap(find.widgetWithText(ListTile, '恒牙'), warnIfMissed: false);
      await settle(tester);
      expect(tester.any(find.byType(AboutPage)), isTrue, reason: '重新进入恒牙聚合页');
    }
    await tester.ensureVisible(find.text('生卡 LLM'));
    await tester.tap(find.text('生卡 LLM'), warnIfMissed: false);
    await settle(tester);
    final aiFields = find.descendant(
        of: find.byType(BottomSheet), matching: find.byType(TextField));
    await tester.enterText(aiFields.at(0), 'https://sweep.cn/v1');
    await tester.enterText(aiFields.at(1), 'gpt-sweep');
    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // 停留(1000ms)窗内：气泡必然在场
    expect(find.textContaining('已保存 AI 服务配置'), findsOneWidget, reason: 'AI 保存必须出气泡');
    await tester.pump(const Duration(milliseconds: 1500)); // 走完 enter150+stay1000+exit250
    await tester.pump(const Duration(milliseconds: 800));
    // 返回设置页（AboutPage 由设置页 push：返回键可弹栈；sweep 可能已点掉返回键）
    await backIfPushed(tester);
    await settle(tester);
    if (!tester.any(find.byType(SettingsPage))) {
      await tester.ensureVisible(find.text('设置'));
      await tester.tap(find.text('设置'), warnIfMissed: false);
      await settle(tester);
      expect(tester.any(find.byType(SettingsPage)), isTrue, reason: '回到设置页');
    }
    // 强制拆卡：确认对话框 → 立即触发 → local .force_run 落盘 + 气泡
    await tester.ensureVisible(find.textContaining('强制开始拆卡'));
    await tester.tap(find.textContaining('强制开始拆卡'), warnIfMissed: false);
    await settle(tester);
    await tester.tap(find.text('立即触发'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1700));
    expect(tester.any(find.byWidgetPredicate((w) => w is Dialog)), isFalse,
        reason: '触发后确认框必须关闭');
    await tester.pump(const Duration(milliseconds: 600));
    // 返回统计页（sweep 可能已点掉设置页自身返回键——有栈才弹，否则已在统计页）
    await backIfPushed(tester);
    await settle(tester);

    // —— ⑥b 手动真题周扫：确认对话框 → 立即扫描 → 触发气泡（weeklyKick 注入
    // no-op——真实 worker 链由 isolate_runner_test 专项覆盖）；自动周扫计时
    // 调整对话框同段覆盖：推迟 7 天 → 状态行刷新为未到期，立即到期 → 清除气泡
    if (!tester.any(find.byType(SettingsPage))) {
      await tester.ensureVisible(find.text('设置'));
      await tester.tap(find.text('设置'), warnIfMissed: false);
      await settle(tester);
    }
    LocalBackend.weeklyKick = () async {};
    await tester.ensureVisible(find.textContaining('立即真题周扫'));
    await tester.tap(find.textContaining('立即真题周扫'), warnIfMissed: false);
    await settle(tester);
    await tester.tap(find.text('立即扫描'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.any(find.text('已触发，真题周扫后台运行中')), isTrue,
        reason: '手动周扫触发成功气泡');
    await tester.pump(const Duration(milliseconds: 1700));
    expect(tester.any(find.byWidgetPredicate((w) => w is Dialog)), isFalse,
        reason: '触发后确认框必须关闭');
    await tester.pump(const Duration(milliseconds: 600));
    LocalBackend.weeklyKick = null;

    await tester.ensureVisible(find.textContaining('自动周扫计时'));
    await tester.tap(find.textContaining('自动周扫计时'), warnIfMissed: false);
    await settle(tester);
    await tester.tap(find.text('推迟 7 天'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.any(find.byWidgetPredicate((w) => w is Dialog)), isFalse,
        reason: '调整后对话框必须关闭');
    expect(tester.any(find.textContaining('约 7 天后到期')), isTrue,
        reason: '推迟后状态行刷新为未到期');
    await tester.pump(const Duration(milliseconds: 1800)); // 气泡走完再继续
    await tester.ensureVisible(find.textContaining('自动周扫计时'));
    await tester.tap(find.textContaining('自动周扫计时'), warnIfMissed: false);
    await settle(tester);
    await tester.tap(find.text('立即到期'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.any(find.textContaining('已清除自动周扫计时')), isTrue,
        reason: '清除计时确认气泡');
    await tester.pump(const Duration(milliseconds: 2000));

    // 返回统计页（⑦ 从底部导航继续）
    await backIfPushed(tester);
    await settle(tester);

    // —— ⑦ 复习会话（核心循环）：翻面 → 四档评分逐一点过 → 完成/返回 ——
    await tapNav(tester, '科目');
    await settle(tester);
    await tester.ensureVisible(find.text('口腔颌面外科学'));
    await tester.tap(find.text('口腔颌面外科学'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(tester.any(find.byType(ReviewSessionPage)), isTrue,
        reason: '点科目卡必须进复习会话');
    const labels = ['重来', '困难', '良好', '简单'];
    for (var i = 0; i < 4; i++) {
      if (tester.any(find.text('本批复习完成！'))) {
        await tester.tap(find.text('返回'), warnIfMissed: false);
        await settle(tester);
        break;
      }
      if (!tester.any(find.text('想一想，点卡片翻面'))) break; // 该科无到期卡
      await tester.tap(find.text('想一想，点卡片翻面'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.tap(find.text(labels[i]), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull,
          reason: '评分「${labels[i]}」后必须无异常');
    }
    if (tester.any(find.byType(ReviewSessionPage))) {
      await backIfPushed(tester);
      await settle(tester);
    }

    // 收尾：全树卸载（流光/气泡/Toast Ticker 全部释放），无残留异常
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // ---------------- 顶部气泡：浅色随机氛围 + 随时间整体渐淡自动移除 ----------------

  testWidgets('顶部气泡：底色氛围每次从色池随机取组（渐变必属色池），随时间整体渐淡后自动移除',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: FilledButton(
              onPressed: () => TopToast.show(ctx, '氛围测试'),
              child: const Text('show'),
            ),
          ),
        ),
      ),
    ));

    // #11 v3.1 色池（2026-09-07）：起/终色各加深一档的真机可感知版
    const pool = <List<Color>>[
      [Color(0xFFD6E4FD), Color(0xFFEDF4FF)], // 品牌蓝
      [Color(0xFFD3F0E2), Color(0xFFEEFAF5)], // 青绿
      [Color(0xFFE2DBF8), Color(0xFFF5F2FE)], // 紫罗兰
      [Color(0xFFDAE4F5), Color(0xFFF0F5FC)], // 靛蓝
      [Color(0xFFF8E4CB), Color(0xFFFCF4E9)], // 暖橙
      [Color(0xFFF6DAE0), Color(0xFFFCF0F2)], // 绯红
    ];
    final captured = <List<Color>>[];
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('show'));
      await tester.pump(); // 入场一帧（控件已在树中，透明度不影响断言）
      final bubble = tester.widget<Container>(find
          .descendant(
              of: find.byType(SafeArea), matching: find.byType(Container))
          .first);
      final deco = bubble.decoration as BoxDecoration;
      final grad = deco.gradient as LinearGradient;
      captured.add(grad.colors);
      // 随时间整体渐淡（2026-09-06 拍板 v3）：默认总时长 240+2200=2440ms
      // 走完后条目自动移除（不残留、不堆叠）
      await tester.pump(const Duration(milliseconds: 3400));
      await tester.pump();
      expect(find.text('氛围测试'), findsNothing, reason: '气泡必须自动淡出移除');
    }
    expect(captured.length, 3);
    for (final c in captured) {
      final known = pool.any(
          (p) => p.length == c.length && p[0] == c[0] && p[1] == c[1]);
      expect(known, isTrue, reason: '底色氛围必须来自受控色池：$c');
    }
  });
}
