// 扫光层组件级测试（#14 科目页蓝色屏克制动效的验收锚点）：
//   克制参数不变量：一轮 ≥4s（低频闸门）+ 峰值 alpha ≤0.10（低透明度，
//                   扫过文字不影响可读性）+ 行程端点必出屏 + 半宽有帽
//                   （关动效零残留的结构性保证）——「动效参数待真机复查
//                   微调」后的回归底线
//   组件行为：正常态 AnimatedBuilder 驱动且相位随固定 pump 推进 +
//             IgnorePointer 在位（纯装饰，绝不吞信息层点击）；
//             关动效 → 光带静止且钉在屏外（无 AnimatedBuilder，蓝屏零残留）；
//             卸载 dispose 无 Ticker 外泄（有限 pump 若干帧不崩）。
// 纪律：永续 repeat 动画 → 全程固定 pump，禁用 pumpAndSettle；
//       testWidgets 自动初始化测试绑定，本文件不调 ensureInitialized
//       （新写 plain test 纪律），plain 用例为纯常量断言、零绑定依赖。
import 'package:hengya/widgets/hero_shimmer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('克制参数不变量（真机复查微调时的回归底线）', () {
    test('一轮周期 ≥4s（低频闸门，与渐变流动①同口径）', () {
      expect(
        HeroShimmer.sweepDuration,
        greaterThanOrEqualTo(const Duration(seconds: 4)),
        reason: '扫光节奏必须克制（≥4s），不得调成高频闪光',
      );
    });

    test('光带峰值 alpha ≤0.10（低透明度，不影响文字可读性）', () {
      expect(
        ShimmerSweepPainter.peakAlpha,
        lessThanOrEqualTo(0.10),
        reason: '高光带必须低透明度（当前 0.08）',
      );
    });

    test('行程端点必出屏 + 半宽有帽（关动效/循环回卷零残留的结构保证）', () {
      // 对角轴平移 1.8×travel ≥ 2.07（远越屏缘 ±1）→ |phase| = travel 时
      // 整带必在可视区外；半宽帽防参数复查时误调成糊满半屏的「亮板」。
      expect(ShimmerSweepPainter.travel, greaterThanOrEqualTo(1.15));
      expect(ShimmerSweepPainter.bandHalf, lessThanOrEqualTo(0.25));
    });
  });

  group('扫光层组件', () {
    /// 读当前光带相位（组件内恰一枚 CustomPaint，painter 必为扫光）
    double shimmerPhase(WidgetTester tester, Finder shimmer) {
      final paintWidget = tester.widget<CustomPaint>(
        find.descendant(of: shimmer, matching: find.byType(CustomPaint)),
      );
      return (paintWidget.painter as ShimmerSweepPainter).phase;
    }

    testWidgets('正常态：AnimatedBuilder 驱动，相位随固定 pump 推进', (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 测试收尾卸载：扫光控制器 dispose → Ticker 注销（永续动画不外泄）
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: HeroShimmer(key: ValueKey('shimmer'))),
        ),
      );
      final shimmer = find.byKey(const ValueKey('shimmer'));
      expect(shimmer, findsOneWidget);
      expect(
        find.descendant(of: shimmer, matching: find.byType(AnimatedBuilder)),
        findsOneWidget,
        reason: '正常态扫光必须被单控制器驱动（#14：蓝屏不能观感静止）',
      );
      // 纯装饰硬约束：IgnorePointer 在位（绝不吞信息层的点击）
      expect(
        find.descendant(of: shimmer, matching: find.byType(IgnorePointer)),
        findsOneWidget,
      );

      // 相位推进：pump 200ms（6s 相位）→ 光带位置必然前移（永续动画在动）
      final p0 = shimmerPhase(tester, shimmer);
      await tester.pump(const Duration(milliseconds: 200));
      final p1 = shimmerPhase(tester, shimmer);
      expect(p1, greaterThan(p0), reason: '扫光必须被控制器驱动');
      // 相位全程钉在 [-travel, travel] 行程内（Tween 端点即屏外）
      expect(p1.abs(), lessThanOrEqualTo(ShimmerSweepPainter.travel + 1e-9));
    });

    testWidgets('关动效：disableAnimations → 光带静止且出屏（蓝屏零残留）', (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
      });

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: const Scaffold(
                body: HeroShimmer(key: ValueKey('shimmer')),
              ),
            ),
          ),
        ),
      );
      final shimmer = find.byKey(const ValueKey('shimmer'));
      expect(shimmer, findsOneWidget);
      expect(
        find.descendant(of: shimmer, matching: find.byType(AnimatedBuilder)),
        findsNothing,
        reason: '关动效必须静止一帧（不启动控制器）',
      );
      // 静止帧的光带钉在行程端点（屏外）→ 蓝屏与无动效版完全一致
      final p0 = shimmerPhase(tester, shimmer);
      expect(p0, ShimmerSweepPainter.travel);
      await tester.pump(const Duration(milliseconds: 300));
      expect(shimmerPhase(tester, shimmer), p0, reason: '关动效后相位不得漂移');
    });

    testWidgets('dispose 无泄漏：有限 pump 若干帧不崩，卸载后 Ticker 注销', (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: HeroShimmer(key: ValueKey('shimmer'))),
        ),
      );
      // 有限帧推进：页面渲染正常、永续动画每帧着色不崩
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(tester.takeException(), isNull);

      // 卸载 → dispose 闸门释放控制器；再泵两帧无异常、无 Ticker 泄漏
      // （若 Ticker 外泄，用例结束时框架以「disposed with an active
      //   Ticker」自动判失败——此为结构性兜底）
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('shimmer')), findsNothing);
    });
  });
}
