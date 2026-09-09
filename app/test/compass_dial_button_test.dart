// 罗盘表盘按钮组件级测试（「进度+罗盘」重设计的验收锚点）：
//   几何数学：0 进度指针指正北、随进度顺时针走满一圈、点击旋摆恰一整圈
//             （+2π ≡ 落点=起点，无视觉残留）；弧扫角 = fraction × 2π
//   渲染：Tooltip 在位（上游 sweep 以 byTooltip 定位）、painter 为表盘绘制
//   进度动画：首建 Sweep-in（0 → fraction），数据变化平滑跟针，600ms 收敛
//   点击：回调必触发 + 指针整圈旋摆（720ms 单次动画，固定 pump 推进）
//   关动效：无旋摆、进度瞬时到位、点击行为不受影响
//   空表盘：fraction 0（拉不到 progress）照常渲染可点击
// 纪律：全部动画为一次性 → 固定 pump 推进到收敛即可，禁用 pumpAndSettle。
import 'dart:math' as math;

import 'package:hengya/widgets/compass_dial_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('罗盘几何数学（纯函数）', () {
    test('0 进度 → 指针指正北（-π/2）', () {
      expect(CompassDialPainter.needleAngle(0, 0), -math.pi / 2);
    });

    test('指针随进度顺时针走（0.25 → 正东 0，0.5 → 正南 π/2）', () {
      expect(CompassDialPainter.needleAngle(0.25, 0), closeTo(0, 1e-9));
      expect(CompassDialPainter.needleAngle(0.5, 0), closeTo(math.pi / 2, 1e-9));
      expect(CompassDialPainter.needleAngle(1, 0), closeTo(-math.pi / 2 + 2 * math.pi, 1e-9));
    });

    test('点击旋摆恰一整圈：spin 1 → 角度 +2π（落点=起点，无残留）', () {
      const f = 0.3;
      expect(
        CompassDialPainter.needleAngle(f, 1) - CompassDialPainter.needleAngle(f, 0),
        closeTo(2 * math.pi, 1e-9),
      );
    });

    test('进度弧扫角 = fraction × 2π', () {
      expect(CompassDialPainter.arcSweep(0), 0);
      expect(CompassDialPainter.arcSweep(0.5), closeTo(math.pi, 1e-9));
      expect(CompassDialPainter.arcSweep(1), closeTo(2 * math.pi, 1e-9));
    });
  });

  group('罗盘表盘按钮组件', () {
    CompassDialPainter painterOf(WidgetTester tester) {
      // Material(shape:) 自带一个 _ShapeBorderPainter 的 CustomPaint——
      // 按 painter 类型精确定位表盘绘制那一枚
      final w = tester.widget<CustomPaint>(
        find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is CompassDialPainter,
        ),
      );
      return w.painter as CompassDialPainter;
    }

    Future<void> pumpButton(
      WidgetTester tester, {
      double fraction = 0,
      bool disableAnimations = false,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(disableAnimations: disableAnimations),
              child: Scaffold(
                body: Center(
                  child: CompassDialButton(
                    key: const ValueKey('compass'),
                    fraction: fraction,
                    onPressed: () {},
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('渲染：Tooltip 在位 + 表盘 painter 在位 + 首建 Sweep-in', (tester) async {
      await pumpButton(tester, fraction: 0.5);
      expect(find.byType(CompassDialButton), findsOneWidget);
      expect(find.byTooltip('学习进度（学习罗盘）'), findsOneWidget);

      // 首建 Sweep-in：第一帧从 0 起步（指针自正北扫入）
      await tester.pump();
      expect(painterOf(tester).fraction, 0);

      // 固定 pump 推进到收敛（600ms easeOutCubic）
      await tester.pump(const Duration(milliseconds: 700));
      expect(painterOf(tester).fraction, closeTo(0.5, 1e-6));
      expect(painterOf(tester).spin, 0);
    });

    testWidgets('点击：回调必触发 + 指针整圈旋摆（单次动画收敛）', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: CompassDialButton(
                key: const ValueKey('compass'),
                fraction: 0.5,
                onPressed: () => taps++,
              ),
            ),
          ),
        ),
      );
      // 等进度 Sweep-in 完成，指针静停在 0.5
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));

      await tester.tap(find.byType(CompassDialButton));
      await tester.pump();
      expect(taps, 1, reason: '点击必须触发 onPressed（首页接线进 /progress）');

      // 旋摆中段：spin ∈ (0,1)
      await tester.pump(const Duration(milliseconds: 300));
      final midSpin = painterOf(tester).spin;
      expect(midSpin, greaterThan(0));
      expect(midSpin, lessThan(1));

      // 推进到收敛：spin 停在 1.0（+2π ≡ 原角，视觉无残留）
      await tester.pump(const Duration(milliseconds: 500));
      expect(painterOf(tester).spin, 1);
      expect(painterOf(tester).fraction, closeTo(0.5, 1e-6));
    });

    testWidgets('数据变化：进度弧/指针平滑跟针（0.25 → 0.75）', (tester) async {
      await pumpButton(tester, fraction: 0.25);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(painterOf(tester).fraction, closeTo(0.25, 1e-6));

      // 模拟下拉刷新后进度增长
      await pumpButton(tester, fraction: 0.75);
      await tester.pump(); // didUpdateWidget 启动新 tween
      await tester.pump(const Duration(milliseconds: 100));
      final mid = painterOf(tester).fraction;
      expect(mid, greaterThan(0.25), reason: '进度变化必须平滑动画而非跳变');
      expect(mid, lessThan(0.75));
      await tester.pump(const Duration(milliseconds: 700));
      expect(painterOf(tester).fraction, closeTo(0.75, 1e-6));
    });

    testWidgets('关动效：无旋摆、进度瞬时到位、点击行为不受影响', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: Scaffold(
                body: Center(
                  child: CompassDialButton(
                    key: const ValueKey('compass'),
                    fraction: 0.5,
                    onPressed: () => taps++,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      // Duration.zero 隐式动画 → 瞬时到位
      expect(painterOf(tester).fraction, 0.5);

      await tester.tap(find.byType(CompassDialButton));
      await tester.pump();
      expect(taps, 1, reason: '关动效不影响点击语义');
      expect(painterOf(tester).spin, 0, reason: '关动效不得旋摆');
      await tester.pump(const Duration(milliseconds: 800));
      expect(painterOf(tester).spin, 0);
    });

    testWidgets('空表盘：fraction 0（拉不到 progress）照常渲染', (tester) async {
      await pumpButton(tester, fraction: 0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(find.byType(CompassDialButton), findsOneWidget);
      expect(painterOf(tester).fraction, 0);
      expect(painterOf(tester).spin, 0);
      expect(tester.takeException(), isNull);
    });
  });
}
