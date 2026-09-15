// RatingSlider（6 级渐变评分滑轨）widget 测试。
//
// 覆盖：
//   1. 点触滑轨中心 → 回调等级 2 或 3（半程四舍五入）
//   2. 点触滑轨最左端 → 等级 0；最右端 → 等级 5
//   3. 水平拖拽到某档位松手 → 回调对应等级
//   4. enabled=false 时不响应任何手势
//   5. 纯垂直滑出滑轨 Y 范围松手 → 不触发回调（手势未成立）
//
// 时序注意：_select 内部有 180ms 视觉反馈延迟才回调、再 300ms 重置选中态，
// 测试中每次有效交互后需 pump 共 500ms+ 冲掉全部 pending Timer。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/widgets/rating_slider.dart';

/// 泵入一个 400dp 宽的 RatingSlider，返回回调记录列表。
Future<List<int>> pumpSlider(
  WidgetTester tester, {
  bool enabled = true,
}) async {
  final calls = <int>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            child: RatingSlider(
              onRated: calls.add,
              enabled: enabled,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return calls;
}

/// 冲掉 _select 的 180ms 回调延迟 + 300ms 重置延迟两个 Timer。
Future<void> flushTimers(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('点触滑轨中心 → 回调等级 2 或 3', (tester) async {
    final calls = await pumpSlider(tester);
    await tester.tapAt(tester.getCenter(find.byType(RatingSlider)));
    await flushTimers(tester);
    // 400dp 宽：padding=20，usable=360，中心 dx=200 → t=0.5 → 2.5 四舍五入为 3
    expect(calls, isNotEmpty, reason: '点击中心必须触发回调');
    expect(calls.single, inInclusiveRange(2, 3));
  });

  testWidgets('点触滑轨最左端 → 等级 0', (tester) async {
    final calls = await pumpSlider(tester);
    final topLeft = tester.getTopLeft(find.byType(RatingSlider));
    await tester.tapAt(topLeft + const Offset(1, 36));
    await flushTimers(tester);
    expect(calls, [0], reason: '最左端必须吸附到等级 0（忘了）');
  });

  testWidgets('点触滑轨最右端 → 等级 5', (tester) async {
    final calls = await pumpSlider(tester);
    final topLeft = tester.getTopLeft(find.byType(RatingSlider));
    await tester.tapAt(topLeft + const Offset(399, 36));
    await flushTimers(tester);
    expect(calls, [5], reason: '最右端必须吸附到等级 5（秒答）');
  });

  testWidgets('滑动到某位置松手 → 回调对应等级', (tester) async {
    final calls = await pumpSlider(tester);
    final topLeft = tester.getTopLeft(find.byType(RatingSlider));
    // 从左端起手（等级 0）水平拖到 dx=164（= 20 + 360×2/5，第 2 档刻度点）
    final gesture =
        await tester.startGesture(topLeft + const Offset(30, 36));
    await tester.pump();
    await gesture.moveBy(const Offset(134, 0));
    await tester.pump();
    await gesture.up();
    await flushTimers(tester);
    expect(calls, [2], reason: '拖到第 2 档刻度松手必须回调等级 2（费力）');
  });

  testWidgets('enabled=false 时不响应手势', (tester) async {
    final calls = await pumpSlider(tester, enabled: false);
    // 点击
    await tester.tapAt(tester.getCenter(find.byType(RatingSlider)));
    // 拖拽
    final topLeft = tester.getTopLeft(find.byType(RatingSlider));
    final gesture =
        await tester.startGesture(topLeft + const Offset(30, 36));
    await tester.pump();
    await gesture.moveBy(const Offset(200, 0));
    await tester.pump();
    await gesture.up();
    await flushTimers(tester);
    expect(calls, isEmpty, reason: '禁用态不得触发任何评分回调');
  });

  testWidgets('手指滑出滑轨 Y 范围 → 不触发回调（取消）', (tester) async {
    final calls = await pumpSlider(tester);
    final topLeft = tester.getTopLeft(find.byType(RatingSlider));
    // 起手后在滑轨内，随后纯垂直大幅滑出 Y 范围（远超 72dp 高度）
    final gesture =
        await tester.startGesture(topLeft + const Offset(200, 36));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 300));
    await tester.pump();
    await gesture.up();
    await flushTimers(tester);
    expect(calls, isEmpty,
        reason: '纯垂直滑出 Y 范围 = 非水平滑轨手势，不得触发评分回调');
  });
}
