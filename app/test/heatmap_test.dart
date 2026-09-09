// M5 打卡热力图时间轴测试（用户明确要求）：
// 纯逻辑：空态 / 单日 / 跨月排序 / 首格=首学习日 / 坏键容错 / 未来日期收敛
// 组件：横向滚动初始定位今天（offset == maxScrollExtent）、空态引导文案
import 'package:hengya/pages/stats_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String dayKey(DateTime t) =>
    '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

Widget wrap(Widget child) => MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0052D9)),
      ),
      home: Scaffold(body: child),
    );

void main() {
  final today = DateTime(2026, 9, 4); // 固定「今天」，用例可复现

  // ---------------- heatmapCellsFor 纯逻辑 ----------------

  test('空数据 → 空列表（调用方显示空态）', () {
    expect(heatmapCellsFor({}, today), isEmpty);
  });

  test('仅今天一条 → 单格 [今天]', () {
    final cells = heatmapCellsFor({dayKey(today): 5}, today);
    expect(cells, hasLength(1));
    expect(cells.first, DateTime(2026, 9, 4));
  });

  test('单日过去记录 → 首格=那天，逐日递增到今天', () {
    final cells = heatmapCellsFor({'2026-09-01': 2}, today);
    expect(cells.first, DateTime(2026, 9, 1)); // 首格 = 第一天学习
    expect(cells.last, DateTime(2026, 9, 4)); // 末格 = 今天
    expect(cells, hasLength(4));
    // 严格递增
    for (var i = 1; i < cells.length; i++) {
      expect(cells[i].isAfter(cells[i - 1]), isTrue);
    }
  });

  test('跨月排序正确：8/28 → 9/2 逐日无缺漏', () {
    final cells = heatmapCellsFor({'2026-08-28': 3}, DateTime(2026, 9, 2));
    expect(cells, [
      DateTime(2026, 8, 28),
      DateTime(2026, 8, 29),
      DateTime(2026, 8, 30),
      DateTime(2026, 8, 31),
      DateTime(2026, 9, 1),
      DateTime(2026, 9, 2),
    ]);
  });

  test('乱序输入取最早日；坏日期键忽略；未来记录收敛为今天', () {
    // 乱序 map：首格仍是最早学习日
    final cells = heatmapCellsFor({
      '2026-09-03': 1,
      'garbage-key': 9, // 坏键直接忽略
      '2026-09-01': 5,
    }, today);
    expect(cells.first, DateTime(2026, 9, 1));

    // 时钟偏移出现“未来”记录 → 不产生越界时间轴，收敛为今天单格
    final future = heatmapCellsFor({dayKey(today.add(const Duration(days: 3))): 1}, today);
    expect(future, [DateTime(2026, 9, 4)]);
  });

  // ---------------- HeatmapCard 组件 ----------------

  testWidgets('组件：60 天历史 → 横向滚动且初始定位到最右（今天）', (tester) async {
    final data = <String, int>{};
    final now = DateTime.now();
    for (var i = 0; i < 60; i++) {
      data[dayKey(now.subtract(Duration(days: i)))] = (i * 7) % 21;
    }
    await tester.pumpWidget(wrap(
      HeatmapCard(
        data: data,
        scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0052D9)),
      ),
    ));
    await tester.pumpAndSettle();

    // 60 格全部渲染（Tooltip 每格一个）
    expect(find.byType(Tooltip), findsNWidgets(60));

    // 横向可滚 + 初始定位今天（offset == maxScrollExtent > 0）
    final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView));
    final ctrl = scroll.controller!;
    expect(ctrl.hasClients, isTrue);
    expect(ctrl.position.maxScrollExtent, greaterThan(0));
    expect(ctrl.offset, ctrl.position.maxScrollExtent);
  });

  testWidgets('组件：空历史（刚还原复习记录后）→ 引导空态而非空白错乱', (tester) async {
    await tester.pumpWidget(wrap(
      HeatmapCard(
        data: const {},
        scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0052D9)),
      ),
    ));
    await tester.pumpAndSettle();
    expect(
      find.text('暂无复习记录——完成第一次复习后，这里会从那一天开始点亮'),
      findsOneWidget,
    );
    expect(find.byType(Tooltip), findsNothing); // 没有格子，没有错乱渲染
    expect(find.byType(SingleChildScrollView), findsNothing);
  });

  testWidgets('组件：仅今天有记录 → 单格不滚动（offset 0）', (tester) async {
    final now = DateTime.now();
    await tester.pumpWidget(wrap(
      HeatmapCard(
        data: {dayKey(now): 6},
        scheme: ColorScheme.fromSeed(seedColor: const Color(0xFF0052D9)),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(Tooltip), findsOneWidget);
    final scroll = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView));
    expect(scroll.controller!.offset, 0);
    expect(scroll.controller!.position.maxScrollExtent, 0);
  });
}
