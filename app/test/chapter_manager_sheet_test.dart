// 节点⑨ 章节管理弹层 UI 专项（testWidgets，全假桩 LocalBackend）：
//   1. 列表渲染：全章三态（已学/待学/不学）+ 摘要（已学/有效总量/不学数）
//   2. 「已学到此」推进：落盘 + 气泡 + onChanged 回调（进度页刷新缝）
//   3. 回退确认：目标 < 指针 → AlertDialog 说明影响；取消不落盘 / 确认落盘
//   4. 标记不学 → 有效总量/「下一章」变化；恢复 → 回原
//   5. 进度页集成：罗盘科目行有「章节管理」入口，derm 占位行没有
//
// 宿主基建同 course_flow_ui_test：Windows 显式加载 test/sqlite3.dll；
// setUp/tearDown 100% 同步；boot 在用例体首行；debugBackendMode 用后置回。
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/pages/chapter_manager_sheet.dart';
import 'package:hengya/pages/progress_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
      () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }

  late Directory tmp;
  final be = LocalBackend.instance;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_node9ui_');
  });

  tearDown(() {
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    LocalBackend.instance.resetForTest(); // 不 await：真实事件队列 FIFO 自完成
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 用例体首行调用（体内事件循环由 pump 驱动，await 安全）
  Future<void> boot() async {
    await be.resetForTest();
    be.init(tmp.path);
    debugBackendMode = BackendMode.local;
    final corpus = Directory('${tmp.path}/corpus')..createSync(recursive: true);
    File('${corpus.path}/progress.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'subjects': {
        'endo': {
          'textbook': '牙体牙髓病学-第5版',
          'chapters': [
            {'no': 1, 'title': '目录', 'page_start': 3},
            {'no': 2, 'title': '前言', 'page_start': 8},
            {'no': 3, 'title': '第一章 绪论', 'page_start': 14},
            {'no': 4, 'title': '第二章 龋病', 'page_start': 20},
            {'no': 5, 'title': '第三章 牙体修复', 'page_start': 44},
          ],
          'learned_through': 2,
          'updated_at': '2026-09-05T14:07:01',
          'history': <Object?>[],
        },
        'derm': {
          'textbook': null,
          'chapters': <Object?>[],
          'learned_through': 0,
          'updated_at': '2026-09-05T12:16:15',
          'history': <Object?>[],
        },
      },
    }));
  }

  const p = SubjectProgress(
    id: 'endo',
    textbook: '牙体牙髓病学-第5版',
    learnedThrough: 2,
    total: 5,
  );

  Widget host(void Function(BuildContext) onOpen) => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: FilledButton(
                onPressed: () => onOpen(ctx),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );

  Future<void> openSheet(
    WidgetTester tester, {
    int Function()? onChanged,
  }) async {
    await tester.pumpWidget(host((ctx) => showChapterManagerSheet(
          ctx,
          p: p,
          subjectName: '牙体牙髓病学',
          onChanged: () async {
            onChanged?.call();
          },
        )));
    await tester.tap(find.text('打开'));
    await tester.pump(); // sheet 入场
    await tester.pump(const Duration(milliseconds: 450)); // 列表加载
  }

  /// 行内「已学到此」按钮定位（按行标题）
  Finder learnedBtnOf(String title) => find
      .descendant(
        of: find
            .ancestor(of: find.text(title), matching: find.byType(Row))
            .first,
        matching: find.text('已学到此'),
      )
      .first;

  /// 行内「不学/恢复」按钮定位（行尾第二个 TextButton——文本随状态切换）
  Finder skipBtnOf(String title) => find
      .descendant(
        of: find
            .ancestor(of: find.text(title), matching: find.byType(Row))
            .first,
        matching: find.byType(TextButton),
      )
      .last;

  testWidgets('列表渲染：全章三态 + 摘要 + 指针标记', (tester) async {
    await boot();
    await openSheet(tester);

    expect(find.text('章节管理 · 牙体牙髓病学'), findsOneWidget);
    expect(find.text('牙体牙髓病学-第5版'), findsOneWidget);
    // #1 新口径：有效已学=正文章计数（指针 2 只越过目录/前言辅文）
    expect(find.textContaining('已学 0 / 有效 5 章'), findsOneWidget);
    // 五章全列出（罗盘数据源章名）
    for (final t in ['目录', '前言', '第一章 绪论', '第二章 龋病', '第三章 牙体修复']) {
      expect(find.text(t), findsOneWidget, reason: '章名 $t 应在列表');
    }
    // 指针 2 → 当前进度标记在「前言」行
    expect(find.text('当前进度'), findsOneWidget);
    expect(
      find.descendant(
        of: find
            .ancestor(of: find.text('前言'), matching: find.byType(Row))
            .first,
        matching: find.text('当前进度'),
      ),
      findsOneWidget,
    );
    // 状态图标：已学 2（check_circle）+ 待学 3（radio_button_unchecked）
    expect(find.byIcon(Icons.check_circle), findsNWidgets(2));
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(3));
    expect(find.byIcon(Icons.block), findsNothing, reason: '无不学章');
  });

  testWidgets('「已学到此」推进：直接落盘 + onChanged 回调触发', (tester) async {
    await boot();
    var changed = 0;
    await openSheet(tester, onChanged: () => changed++);

    // 对「第二章 龋病」（no=4 > 指针 2）点已学到此 → 无确认直接推进
    await tester.ensureVisible(learnedBtnOf('第二章 龋病'));
    await tester.tap(learnedBtnOf('第二章 龋病'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450)); // PUT + 重读 + 气泡

    // 落盘核对（端到端直查 json）
    final data =
        jsonDecode(File('${tmp.path}/corpus/progress.json').readAsStringSync())
            as Map<String, dynamic>;
    final endo = (data['subjects'] as Map)['endo'] as Map;
    expect(endo['learned_through'], 4);
    expect(((endo['history'] as List).last as Map)['evidence'],
        contains('章节管理推进'));
    // 气泡 + 进度页刷新缝触发
    expect(find.textContaining('已学到「第二章 龋病」'), findsOneWidget);
    expect(changed, 1);
    // 弹层即时刷新：摘要更新、状态图标随之（已学 4）
    expect(find.textContaining('已学 2 / 有效 5 章'),
        findsOneWidget, reason: '#1 新口径：正文章 ≤ 指针 4 共 2 章');
    // 行级 learned 标记仍按原始指针（含目录/前言）：4 行
    expect(find.byIcon(Icons.check_circle), findsNWidgets(4));
    // 收尾：让气泡走完生命周期
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('回退确认：取消不落盘；确认回退落盘并记 history', (tester) async {
    await boot();
    var changed = 0;
    await openSheet(tester, onChanged: () => changed++);

    // 对已学的「目录」（no=1 < 指针 2）点已学到此 → 必须弹确认
    await tester.tap(learnedBtnOf('目录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('回退学习进度'), findsOneWidget);
    expect(find.textContaining('从第 2 章'), findsOneWidget);
    expect(find.textContaining('回退到第 1 章'), findsOneWidget);
    expect(find.textContaining('1 个已学章节将回到待学状态'), findsOneWidget);

    // 取消：不落盘
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsNothing);
    var endo = ((jsonDecode(File('${tmp.path}/corpus/progress.json')
                .readAsStringSync()) as Map)['subjects'] as Map)['endo'] as Map;
    expect(endo['learned_through'], 2, reason: '取消回退不动盘');
    expect(changed, 0);

    // 再来一次 → 确认回退
    await tester.tap(learnedBtnOf('目录'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('确认回退'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    endo = ((jsonDecode(File('${tmp.path}/corpus/progress.json')
                .readAsStringSync()) as Map)['subjects'] as Map)['endo'] as Map;
    expect(endo['learned_through'], 1);
    expect(((endo['history'] as List).last as Map)['evidence'],
        contains('章节管理回退'));
    expect(find.textContaining('已回退到「目录」'), findsOneWidget);
    expect(changed, 1);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('标记不学 → 有效总量/下一章变化；恢复回原', (tester) async {
    await boot();
    var changed = 0;
    await openSheet(tester, onChanged: () => changed++);

    // 对下一章「第一章 绪论」（no=3）标记不学
    await tester.ensureVisible(find.text('第一章 绪论'));
    await tester.tap(skipBtnOf('第一章 绪论'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    // 落盘：skipped=[3]；有效口径联动
    final data =
        jsonDecode(File('${tmp.path}/corpus/progress.json').readAsStringSync())
            as Map<String, dynamic>;
    final endo = (data['subjects'] as Map)['endo'] as Map;
    expect(endo['skipped'], [3]);
    expect(endo['learned_through'], 2, reason: '跳过切换不动指针');
    expect(find.textContaining('不学 1 章'), findsOneWidget);
    expect(find.textContaining('有效 4 章'), findsOneWidget);
    expect(find.byIcon(Icons.block), findsOneWidget, reason: '不学章图标');
    // 该章行出现「恢复」按钮
    expect(
      find.descendant(
        of: find
            .ancestor(of: find.text('第一章 绪论'), matching: find.byType(Row))
            .first,
        matching: find.text('恢复'),
      ),
      findsOneWidget,
    );
    // 主视图（进度页数据源）核对：下一章越过不学章
    final view = await be.get('/progress');
    final e = (view['subjects'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['id'] == 'endo');
    expect(e['total'], 4);
    expect((e['next_chapter'] as Map)['no'], 4, reason: '下一章=第二章 龋病');

    // 恢复 → 回原
    await tester.tap(skipBtnOf('第一章 绪论'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    final endo2 = ((jsonDecode(File('${tmp.path}/corpus/progress.json')
                .readAsStringSync()) as Map)['subjects'] as Map)['endo'] as Map;
    expect(endo2.containsKey('skipped'), false, reason: '清空即移除字段');
    expect(find.textContaining('有效 5 章'), findsOneWidget);
    expect(changed, 2);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('进度页集成：罗盘科目行有「章节管理」入口，derm 占位行没有', (tester) async {
    await boot();
    await tester.pumpWidget(const MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: true),
        child: ProgressPage(),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));

    // endo（有罗盘）：入口在位；derm（占位）：无入口
    expect(find.byTooltip('章节管理'), findsOneWidget);
    expect(find.text('未配置教材'), findsOneWidget); // derm 行标注在位

    // 点击 → 弹层打开
    await tester.tap(find.byTooltip('章节管理'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('章节管理 · endo'), findsOneWidget,
        reason: 'subjects 表无科目名时 nameOf 回退 id');
    // #1 新口径：指针 2 只越过辅文 → 正文章计数 0
    expect(find.textContaining('已学 0 / 有效 5 章'), findsOneWidget);
  });
}
