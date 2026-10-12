// 扫光层组件级测试（#14 科目页蓝色屏克制动效的验收锚点）：
//   克制参数不变量：一轮 ≥4s（低频闸门）+ 峰值 alpha ≤0.10（低透明度，
//                   扫过文字不影响可读性）+ 行程端点必出屏 + 半宽有帽
//                   （关动效零残留的结构性保证）——「动效参数待真机复查
//                   微调」后的回归底线；
//   2026-10-12 返工新增「随机但受控」不变量：方向偏转帽 / 振幅系数区间 /
//                   波长区间 / 波形漂移（见 ShimmerSweepPainter 常量与
//                   ShimmerWave.reroll 的区间断言）——随机只在池内发生。
//   组件行为：正常态 AnimatedBuilder 驱动且相位随固定 pump 推进 +
//             IgnorePointer 在位（纯装饰，绝不吞信息层点击）；
//             关动效 → 光带静止且钉在屏外（无 AnimatedBuilder，蓝屏零残留）；
//             卸载 dispose 无 Ticker 外泄（有限 pump 若干帧不崩）。
// 纪律：永续 repeat 动画 → 全程固定 pump，禁用 pumpAndSettle；
//       testWidgets 自动初始化测试绑定，本文件不调 ensureInitialized
//       （新写 plain test 纪律），plain 用例为纯常量断言、零绑定依赖。
import 'dart:math' as math;

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
      // 相位 ±travel 时中心平移 (sHalf + lineHalf)（带体半长已含屏沿投影 +
      // 带半宽）→ 整带（含圆头）必在可视区外；半宽帽防参数复查时误调成
      // 糊满半屏的「亮板」。
      expect(ShimmerSweepPainter.travel, greaterThanOrEqualTo(1.15));
      expect(ShimmerSweepPainter.bandHalf, lessThanOrEqualTo(0.25));
    });
  });

  group('「随机但受控」不变量（2026-10-12 返工锚点）', () {
    test('方向偏转帽 ≤20°（不摇出竖直/水平的突兀斜角）', () {
      expect(
        ShimmerSweepPainter.maxAngleJitter,
        lessThanOrEqualTo(20 * math.pi / 180),
        reason: '基础对角约 16°~26°，±20° 内偏转后仍在舒展斜角内',
      );
      expect(ShimmerSweepPainter.maxAngleJitter, greaterThan(0),
          reason: '必须存在方向随机性（否则回到「每轮同向」的单调）');
    });

    test('振幅系数区间落在 [0.2, 0.8]（峰度受控，缓波不夸张）', () {
      final r = ShimmerSweepPainter.ampScaleRange;
      expect(r.length, 2);
      expect(r[0], greaterThanOrEqualTo(0.2));
      expect(r[1], lessThanOrEqualTo(0.8));
      expect(r[0], lessThan(r[1]));
    });

    test('波长区间落在 [0.4, 1.6] 屏宽（屏内 1~2 个完整缓波）', () {
      final r = ShimmerSweepPainter.wavelengthScaleRange;
      expect(r.length, 2);
      expect(r[0], greaterThanOrEqualTo(0.4));
      expect(r[1], lessThanOrEqualTo(1.6));
      expect(r[0], lessThan(r[1]));
    });

    test('波形漂移为 36s 主循环的整数分之一（回卷无缝）', () {
      const turns = ShimmerSweepPainter.waveDriftTurns;
      expect(turns, greaterThan(0), reason: '必须缓慢流动（避免冻结曲线平移的机械感）');
      expect((1 / turns).roundToDouble(), closeTo(1 / turns, 1e-9),
          reason: '漂移周期须为整数轮（回卷无跳变）');
    });

    test('reroll：多轮摇定全部落在受控区间内（随机只在池内）', () {
      final rng = math.Random(20261012);
      var sawReverse = false;
      var sawForward = false;
      for (var i = 0; i < 300; i++) {
        final w = ShimmerWave.reroll(rng);
        expect(w.angleJitter.abs(),
            lessThanOrEqualTo(ShimmerSweepPainter.maxAngleJitter + 1e-12));
        final amp = ShimmerSweepPainter.ampScaleRange;
        expect(w.amplitudeScale, greaterThanOrEqualTo(amp[0] - 1e-12));
        expect(w.amplitudeScale, lessThanOrEqualTo(amp[1] + 1e-12));
        final len = ShimmerSweepPainter.wavelengthScaleRange;
        expect(w.wavelengthScale, greaterThanOrEqualTo(len[0] - 1e-12));
        expect(w.wavelengthScale, lessThanOrEqualTo(len[1] + 1e-12));
        expect(w.phase, greaterThanOrEqualTo(0));
        expect(w.phase, lessThan(2 * math.pi + 1e-12));
        if (w.reverse) {
          sawReverse = true;
        } else {
          sawForward = true;
        }
      }
      expect(sawReverse && sawForward,
          isTrue, reason: '反向扫过必须双向都可能出现（方向随机性的一半来源）');
    });

    test('reroll 同 seed 可复现 + 不同轮次参数可变（真随机非恒定）', () {
      final seq1 = List.generate(
          12, (_) => ShimmerWave.reroll(math.Random(7)).angleJitter);
      expect(seq1.toSet().length, 1, reason: '同 seed 重放必须逐字段复现');
      final rng = math.Random(7);
      final seq2 = List.generate(12, (_) => ShimmerWave.reroll(rng));
      expect(seq2.toSet().length, greaterThan(1),
          reason: '连续多轮必须摇出不同方向/波形（否则仍单调）');
    });
  });

  group('扫光几何（纯函数，直接审计三条结构保证）', () {
    const size = Size(360, 260);

    test('零残留：phase = ±travel 时带体（含圆头半径）全在屏外矩形之外', () {
      final rng = math.Random(2026);
      for (var i = 0; i < 60; i++) {
        final w = ShimmerWave.reroll(rng);
        for (final phase in [
          -ShimmerSweepPainter.travel,
          ShimmerSweepPainter.travel,
        ]) {
          final geo = ShimmerSweepGeometry.compute(size, w, phase);
          for (var j = 0; j <= ShimmerSweepPainter.samples; j++) {
            final s = -geo.lineHalf +
                2 * geo.lineHalf * (j / ShimmerSweepPainter.samples);
            final p = geo.pointAt(s);
            // 以该点为圆心、bandHalfPx 为半径的圆与屏幕矩形不相交：
            // 到矩形的最近距离 > bandHalfPx。
            final dx = math.max(
                math.max(-p.dx, p.dx - size.width), 0.0);
            final dy = math.max(
                math.max(-p.dy, p.dy - size.height), 0.0);
            final dist = math.sqrt(dx * dx + dy * dy);
            expect(dist, greaterThan(geo.bandHalfPx),
                reason: '端点相位下带体必须完全出屏（关动效零残留）');
          }
        }
      }
    });

    test('非直线：振幅 > 0 时中心线偏离弦线（正弦缓波）', () {
      final rng = math.Random(11);
      for (var i = 0; i < 30; i++) {
        final w = ShimmerWave.reroll(rng);
        final geo = ShimmerSweepGeometry.compute(size, w, 0.0);
        expect(geo.amp, greaterThan(0), reason: '正常态振幅必 > 0（波浪而非直线）');
        // 沿中心线采样，法向偏离（相对弦线的横向偏移）至少达到 0.5×振幅。
        var maxAbsOff = 0.0;
        for (var j = 0; j <= ShimmerSweepPainter.samples; j++) {
          final s = -geo.lineHalf +
              2 * geo.lineHalf * (j / ShimmerSweepPainter.samples);
          final off = geo.amp * math.sin(geo.k * s + geo.drift);
          maxAbsOff = math.max(maxAbsOff, off.abs());
        }
        expect(maxAbsOff, greaterThan(geo.amp * 0.5),
            reason: '屏内必出现可辨的波峰（不是一条直线）');
      }
    });

    test('带宽帽：最大横截面半宽恒 = bandHalf × 基础对角长', () {
      final rng = math.Random(99);
      for (var i = 0; i < 30; i++) {
        final w = ShimmerWave.reroll(rng);
        final geo = ShimmerSweepGeometry.compute(size, w, 0.3);
        final baseLen = Offset(0.9 * size.width, 0.35 * size.height).distance;
        expect(geo.bandHalfPx, closeTo(ShimmerSweepPainter.bandHalf * baseLen, 1e-9),
            reason: '光带半宽不得随随机参数漂移（防误调成糊满半屏的亮板）');
      }
    });

    test('方向随机：同一 seed 序列内方向确实变化（非恒定）', () {
      final rng = math.Random(5);
      final dirs = <String>{};
      for (var i = 0; i < 20; i++) {
        final w = ShimmerWave.reroll(rng);
        final geo = ShimmerSweepGeometry.compute(size, w, 0.0);
        dirs.add('${geo.dir.dx.toStringAsFixed(3)},'
            '${geo.dir.dy.toStringAsFixed(3)}');
      }
      expect(dirs.length, greaterThan(1), reason: '连续多轮方向必须变化');
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
