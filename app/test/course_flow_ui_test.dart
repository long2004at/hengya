// 课程添加全链路 UI 专项（2026-09-06 五问）：
// Q1 建课流程跑通：收件箱内联「新建课程」→ 落库（0.3.1 起新库零科目，
//    建课后 1 科）→ 新课程 chip 立即选中
//    → 顶部气泡提示（2026-09-06 拍板：轻提示统一气泡化，替换灰色 SnackBar）
// Q5 修正回归：409 有两种冲突（重名/短码重复），透传后端裸中文 message；
//    旧硬编码「短码已被占用，请换一个」绝不再出现（修正前重名场景被误导）
// Q2 题库空占位：新建课程出现在题库筛选胶囊；点选后 0 卡空态优雅（无崩溃）
// Q3 罗盘可见性：新课程不进罗盘 = 设计使然（无教材语料无罗盘）；progress.json
//    就位后罗盘正常渲染；无 progress.json → 引导空态（local 迁移边界：导库后
//    罗盘为空直到 corpus/progress.json 就位）
// Q4 异常进度防崩：learned_through > total 钳制 100% + 学完态、垃圾时间戳 →
//    「尚未更新」、除零/负数在模型层被吞
// Q5 模型级兜底：科目视觉按 id 稳定散列（同 id 恒同色/同图标，新课程 UI 不炸）
// Q6 首启空库语义（0.3.1 开源去内置）：新库零科目——home 引导空态 + 题库/
//    待审核/统计空态正常渲染
//
// 宿主基建同 e2e_local_journey_test：Windows 显式加载 test/sqlite3.dll
// （sqlite3 2.4.0 overrideForAll；python 自带 dll 跨进程 open_v2 即崩不可用）。
// 约定：进度页等永续氛围动画一律 MediaQuery.disableAnimations 包裹 + 固定 pump，
// 绝不 pumpAndSettle；对话框 TextField 用 labelText 精确定位（sheet 下有多个
// 输入框，按遍历序取 .first 会错位）；debugBackendMode 测试后置回 null。
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/pages/bank_page.dart';
import 'package:hengya/pages/home_page.dart';
import 'package:hengya/pages/inbox_sheet.dart';
import 'package:hengya/pages/pending_page.dart';
import 'package:hengya/pages/progress_page.dart';
import 'package:hengya/pages/stats_page.dart';
import 'package:hengya/pages/subject_picker.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
        () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  late Directory tmp;
  final be = LocalBackend.instance;

  // !! testWidgets 假异步坑（2026-09-06 探针实证，两层结论）：
  // ① fake_async 下真实异步 IO 体内 await 必死锁（目录建删用同步版）；
  // ② 事件循环只被 tester.pump 驱动——测试体内 await 微任务链安全（E2/E3 实证），
  //    但 setUp/tearDown 里任何 await（哪怕纯微任务级 resetForTest）都因无人驱动
  //    而永久挂起，且测试超时定时器也住在假时钟里永不触发（15s --timeout 无效）。
  // 因此 setUp/tearDown 必须 100% 同步；后端 boot 移到每个用例体首行。
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_course_');
  });

  /// 用例体首行调用（体内事件循环由 pump 驱动，await 安全）
  Future<void> boot() async {
    await be.resetForTest();
    be.init(tmp.path);
    debugBackendMode = BackendMode.local; // 顶层 @visibleForTesting 覆盖变量
  }

  tearDown(() {
    debugBackendMode = null; // 置回 null：跨用例/跨文件零污染
    ApiClient.instance.resetSubjectCaches();
    // 不 await：微任务链在真实事件队列 FIFO 自完成（下一用例 boot 前必达）
    LocalBackend.instance.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Finder nameField() => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '课程名称（必填）');
  Finder idField() => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == '短码（可选）');

  // 对话框表单必须配齐字段才能提交（与真机一致的最短可用表单）
  Widget host(void Function(BuildContext) onOpen) => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                  onPressed: () => onOpen(ctx), child: const Text('打开')),
            ),
          ),
        ),
      );

  testWidgets(
      'Q1 建课全流程：收件箱（零科目空库起步）→ 新建课程 → 落库 1 科'
      '（自动 8 位短码/0 到期）→ 气泡提示 → 新课程 chip 立即选中，对话框自动关闭',
      (tester) async {
    await boot();
    await tester.pumpWidget(host((ctx) => showInboxSheet(ctx)));
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // sheet 入场 + 科目列表

    // 前置（0.3.1 开源去内置）：新库零科目——无 ChoiceChip，「新建课程」在位
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('新建课程'), findsOneWidget);

    await tester.tap(find.text('新建课程'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(nameField(), '全流程新课程');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 落库验证：零科目起步 + 新课 = 1；自动 8 位短码；0 到期
    final subs = await be.get('/subjects');
    final list = (subs['subjects'] as List).cast<Map<String, dynamic>>();
    expect(list.length, 1);
    final created = list.firstWhere((s) => s['name'] == '全流程新课程');
    expect((created['id'] as String).length, 8);
    expect(created['dueCount'], 0);

    // 对话框自动关闭；新 chip 在位且已选中（创建成功立即可选）
    expect(find.byType(AlertDialog), findsNothing);
    final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, '全流程新课程'));
    expect(chip.selected, true);

    // 顶部气泡提示（替换旧灰色 SnackBar）：课程名 + 短码都在气泡里
    expect(find.textContaining('已创建「全流程新课程」'), findsOneWidget);
    expect(find.textContaining('短码 ${created['id']}'), findsOneWidget);

    // 收尾：让气泡走完生命周期（控制器释放，不遗留 Ticker）
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('Q5 修正回归：409 重名/短码冲突分别透传后端 message，旧硬编码文案绝不再出现',
      (tester) async {
    await boot();
    // 预置：牙周护理学（短码 perio2）
    await be.post('/subjects', {'name': '牙周护理学', 'id': 'perio2'});

    await tester.pumpWidget(host((ctx) => showCreateSubjectDialog(ctx)));
    await tester.tap(find.text('打开'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // ① 重名（名称重复、短码留空）→ 透传「科目名称「牙周护理学」已存在」
    await tester.enterText(nameField(), '牙周护理学');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('科目名称「牙周护理学」已存在'), findsOneWidget);
    expect(find.text('短码已被占用，请换一个'), findsNothing); // 修正前重名被误导
    expect(find.byType(AlertDialog), findsOneWidget); // 对话框不误关

    // ② 短码冲突（新名称 + 已占用短码）→ 透传「科目短码 perio2 已存在」
    await tester.enterText(nameField(), '牙周病学基础');
    await tester.enterText(idField(), 'perio2');
    await tester.tap(find.widgetWithText(FilledButton, '创建'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('科目短码 perio2 已存在'), findsOneWidget);
    expect(find.text('科目名称「牙周护理学」已存在'), findsNothing); // 旧错误已让位
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('Q2 题库空占位：新建课程出现在题库筛选胶囊，点选后 0 卡空态优雅',
      (tester) async {
    await boot();
    final made = await be.post('/subjects', {'name': '题库新课程'});
    expect((made as Map)['ok'], true);

    await tester.pumpWidget(const MaterialApp(home: BankPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('共 0 张'), findsOneWidget); // 空库 0 卡
    expect(find.text('题库新课程'), findsOneWidget); // 筛选胶囊在位（subjectNameOf 链）

    // 点新课程胶囊 → 该科筛选：0 卡空态（无崩溃、无白屏）
    await tester.ensureVisible(find.text('题库新课程'));
    await tester.tap(find.text('题库新课程'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('没有匹配的卡片'), findsOneWidget);
    expect(find.text('共 0 张'), findsOneWidget);
  });

  testWidgets(
      'Q3+Q4 罗盘正常态：progress.json 就位后正常渲染（1/5、20%、下一章）；'
      '新课程不进罗盘（设计使然）；derm 未配置教材标注；垃圾时间戳 → 「尚未更新」',
      (tester) async {
    await boot();
    await be.post('/subjects', {'name': '罗盘外新课程', 'id': 'novis001'});
    // progress.json：endo 正常学到第 2 章（共 5 章含目录/前言辅文章）；
    // derm 无教材 + 垃圾时间戳（字符串字典序最大 → 顶层 updated_at 取到垃圾值）
    final corpus = Directory('${tmp.path}/corpus')..createSync(recursive: true);
    File('${corpus.path}/progress.json').writeAsStringSync(jsonEncode({
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
            {'no': 4, 'title': '附录'},
          ],
        },
        'derm': {
          'textbook': null,
          'learned_through': 0,
          'updated_at': 'garbage-not-a-timestamp',
          'chapters': [],
        },
      },
    }));

    // 永续气泡氛围层：disableAnimations 包裹 → 静止一帧，固定 pump 即可
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: ProgressPage(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // endo 行：教材名 / 1/5 / 20% / 下一章预告（辅文章被跳过 → 直指第二章 新航路）
    // #1 新口径：指针 2 只越过 目录(no0)/前言(no1) 辅文 + 第一章(no2) → 有效已学 1
    expect(find.text('世界通史-第2版'), findsOneWidget);
    expect(find.text('1/5'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
    expect(find.textContaining('下一章：'), findsOneWidget);
    // 「下一章」预告在两处合法出现：联动卡预告行 + 科目进度行（Text.rich 子段）
    expect(find.textContaining('第二章 新航路'), findsNWidgets(2));
    // derm 行：未配置教材（占位行可见，但不参与复习提示）
    expect(find.text('未配置教材'), findsOneWidget);
    expect(find.text('教材未配置，暂不参与复习提示'), findsOneWidget);
    // 联动卡：空库 0 到期 → 今天没有到期复习卡
    expect(find.text('今天没有到期复习卡'), findsOneWidget);
    // 总览胶囊：罗盘 1 科（derm 无罗盘不计）/ 已开学 1 科
    expect(find.text('罗盘科目 1 科'), findsOneWidget);
    expect(find.text('已开学 1 科'), findsOneWidget);
    // 垃圾时间戳 → DateTime.tryParse null → 「尚未更新」（防崩 + 优雅降级）
    expect(find.text('尚未更新'), findsOneWidget);
    // 新课程不进罗盘：无教材语料无罗盘（设计使然，非 bug）
    expect(find.text('罗盘外新课程'), findsNothing);
  });

  testWidgets('Q3 罗盘空态：无 progress.json → 引导文案（local 迁移边界：导库后罗盘为空）',
      (tester) async {
    await boot();
    await be.post('/subjects', {'name': '罗盘外新课程', 'id': 'novis001'});

    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: ProgressPage(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('暂无学习进度数据'), findsOneWidget);
    expect(find.textContaining('尚未在本机生成'), findsOneWidget);
    expect(find.text('罗盘外新课程'), findsNothing); // 空态同样不出现新课程
  });

  testWidgets('Q4 异常进度防崩：learned_through 99 / 共 3 章 → 展示收敛 3/3 + 学完态',
      (tester) async {
    await boot();
    final corpus = Directory('${tmp.path}/corpus')..createSync(recursive: true);
    File('${corpus.path}/progress.json').writeAsStringSync(jsonEncode({
      'subjects': {
        'endo': {
          'textbook': '世界通史-第2版',
          'learned_through': 99,
          'updated_at': '2026-09-05T22:00:00',
          'chapters': [
            {'no': 1, 'title': '第一章 绪论'},
            {'no': 2, 'title': '第二章 新航路'},
            {'no': 3, 'title': '第三章 启蒙运动'},
          ],
        },
      },
    }));

    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: ProgressPage(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // #1 新口径：展示用有效已学（正文章计数 ≤ 指针）= 3 → '3/3'（不再
    // 原样展示 99/3；API 层仍原样透传，收敛在展示层）
    expect(find.text('3/3'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('已学完'), findsOneWidget); // 无下一章（全部 no ≤ 99）→ 学完
    expect(find.text('教材正文章已全部学完'), findsOneWidget);
    // LinearProgressIndicator value=1.0 正常渲染——未抛异常本身就是断言
  });

  test('Q5 模型级兜底：进度钳制/除零/垃圾时间戳/未知科目渐变与图标', () {
    // 进度分数：learned > total → 1.0；负数 → 0.0；total = 0 防除零
    final over = SubjectProgress.fromJson(const {
      'id': 'endo', 'textbook': 'x', 'learned_through': 99, 'total': 3,
    });
    expect(over.fraction, 1.0);
    expect(over.completed, true); // next_chapter 缺席 → null → 学完
    final neg = SubjectProgress.fromJson(const {
      'id': 'endo', 'textbook': 'x', 'learned_through': -5, 'total': 3,
    });
    expect(neg.fraction, 0.0);
    final zero = SubjectProgress.fromJson(const {
      'id': 'endo', 'textbook': 'x', 'learned_through': 2, 'total': 0,
    });
    expect(zero.fraction, 0.0);
    // 垃圾时间戳 → null（UI 层显示「尚未更新」，不炸 DateTime.parse）
    final ov = ProgressOverview.fromJson(const {
      'subjects': [],
      'updated_at': 'garbage',
    });
    expect(ov.updatedAt, isNull);
    // 未知科目（新建课程）：科目视觉按 id 稳定散列——同 id 恒同色/同图标，
    // 色必来自受控色盘、图标必来自通用图标集（UI 不因未知 id 炸）
    final grad = HengyaColors.gradientOf('novis001');
    expect(HengyaColors.gradientOf('novis001'), same(grad)); // 稳定：两次调用恒同
    expect(grad.length, 2); // 一组渐变双色
    expect(subjectIcon('novis001'), subjectIcon('novis001')); // 同 id 恒同图标
    expect(HengyaColors.gradientOf(''), [HengyaColors.brand, HengyaColors.brandLight]);
    expect(subjectIcon(''), Icons.menu_book_outlined); // 空 id 兜底
  });

  // ---------------- Q6 首启空库语义（0.3.1 开源去内置） ----------------

  /// 永续氛围动画页统一包装：disableAnimations → 静止一帧，固定 pump 推进
  Widget stillFrame(Widget child) => MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: child,
      );

  testWidgets(
      'Q6 首启空库：新库零科目——数据层零行 + home 引导空态 + '
      '题库/待审核/统计空态全部正常渲染（无崩溃、无白屏）',
      (tester) async {
    await boot();

    // 数据层：0.3.1 起无内置播种——新库零科目、零待审、零到期
    final subs = await be.get('/subjects');
    expect((subs as Map)['subjects'], isEmpty);
    final pending = await be.get('/cards/pending');
    expect((pending as Map)['list'], isEmpty);

    // ① 首页：Hero 照常 + 「还没有课程」引导（右上「记课堂重点」可建课）
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: stillFrame(const HomePage())));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('恒牙'), findsOneWidget);
    expect(find.text('0'), findsOneWidget); // totalDue = 0
    expect(find.text('还没有课程'), findsOneWidget);
    expect(find.textContaining('新建第一门课程'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink()); // 卸载（Ticker 注销）

    // ② 题库：0 卡空态优雅
    await tester.pumpWidget(const MaterialApp(home: BankPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('共 0 张'), findsOneWidget);
    expect(find.text('没有匹配的卡片'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    // ③ 待审核：审核池清空空态
    await tester.pumpWidget(const MaterialApp(home: PendingPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('审核池已清空'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    // ④ 统计：空历史引导文案而非空白错乱
    await tester.pumpWidget(MaterialApp(home: stillFrame(const StatsPage())));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('暂无复习记录'), findsOneWidget);
    expect(find.text('暂无痛觉卡，状态很好 👍'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
