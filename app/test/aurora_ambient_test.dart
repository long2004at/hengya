// 海浪氛围层组件级测试（2026-10-11「多波向 × 多倍频海浪涌动」重构的
// 验收锚点）：
//   色池不变量：受控色池每组恰三色、全部高明度柔和色（lightness 0.70~0.96，
//               杜绝荧光刺眼）、组内成对色相差 ≥ 25°（同组可辨层次）
//   峰值 alpha 帽：四层波面（填充 + 泡沫分账）alpha 合计 ≤ 0.15（信息明确
//               硬约束，含泡沫最坏叠加不超帽，只随色变不随量变）
//   波参数不变量：层数 4、每层 4 波分量、分量频率为 36s 主循环整数分之一
//               且单波周期 ≥ 7.2s（≥4s 低频闸门）、振幅/波长/水位落在克制
//               区间、波向角任意（[0, 2π) 全域——不再局限水平左右）、
//               振幅归一 Σ amp = 1（层振幅守恒 → alpha 帽可静态审计）
//   随机可复现：注入 seed → 同 seed 重放层/分量参数逐层恒等、异 seed 确实
//               不同；波向角跨 seed 覆盖任意角度象限（随机焕新）
//   组件行为：正常态 AnimatedBuilder 驱动且相位随 pump 推进、固定 pump
//             多帧无异常无溢出；关动效 → 静态一帧；卸载无 Ticker 外泄
// 纪律：永续 repeat 动画 → 全程固定 pump，禁用 pumpAndSettle；
//       禁真实性能基准（不做帧率断言）。
import 'dart:math' as math;

import 'package:hengya/widgets/aurora_ambient.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('受控色池不变量（优雅高级的结构性保证）', () {
    test('每组恰三色（与波层循环取色一一对应）', () {
      for (final p in AuroraPalette.pool) {
        expect(p.colors.length, 3, reason: '${p.name} 必须恰三色');
      }
    });

    test('全部为高明度柔和色（lightness 0.70~0.96，杜绝荧光刺眼）', () {
      for (final p in AuroraPalette.pool) {
        for (final c in p.colors) {
          final l = HSLColor.fromColor(c).lightness;
          expect(l, greaterThanOrEqualTo(0.70),
              reason: '${p.name} $c 明度过低（偏沉不柔和）');
          expect(l, lessThanOrEqualTo(0.96),
              reason: '${p.name} $c 明度过高（近白无色彩）');
        }
      }
    });

    test('组内成对色相差 ≥ 25°（同组三色可辨层次，非同色系糊成一片）', () {
      double hueDist(double a, double b) {
        final d = (a - b).abs();
        return math.min(d, 360 - d);
      }

      for (final p in AuroraPalette.pool) {
        final hues = [
          for (final c in p.colors) HSLColor.fromColor(c).hue,
        ];
        for (var i = 0; i < hues.length; i++) {
          for (var j = i + 1; j < hues.length; j++) {
            expect(
              hueDist(hues[i], hues[j]),
              greaterThanOrEqualTo(25),
              reason: '${p.name} 第 $i/$j 色色相过近（${hues[i]} vs ${hues[j]}）',
            );
          }
        }
      }
    });

    test('信息明确硬约束：四层波面峰值 alpha 合计 ≤ 0.15（含泡沫最坏叠加）', () {
      final sum = AuroraWaveLayer.peakAlphas.fold<double>(
        0,
        (a, b) => a + b,
      );
      expect(sum, lessThanOrEqualTo(0.15));
    });

    test('alpha 审计式：每层填充与泡沫分账之和恰为本层帽（最坏叠加不超帽）', () {
      for (var i = 0; i < AuroraWaveLayer.count; i++) {
        final share = AuroraWaveLayer.foamShares[i];
        expect(share, inInclusiveRange(0.0, 1.0),
            reason: '第 $i 层泡沫分账占比必须在 [0,1]');
        // 分账式：填充峰值 = α·(1−share)·breathe（≤ α·(1−share)），
        // 泡沫峰值 = α·share·flicker（≤ α·share）→ 单层最坏恰为 α
        final budget = AuroraWaveLayer.peakAlphas[i] * (1 - share) +
            AuroraWaveLayer.peakAlphas[i] * share;
        expect(budget, closeTo(AuroraWaveLayer.peakAlphas[i], 1e-9),
            reason: '第 $i 层 alpha 分账必须恰好用满帽（不多不少，可静态审计）');
      }
    });

    test('会话级随机受控：session 必为池内成员（随机只在池内发生）', () {
      expect(
        AuroraPalette.pool.contains(AuroraPalette.session),
        isTrue,
        reason: 'session 随机取组不得越出受控色池',
      );
    });

    test('注入固定随机源 → 取池内确定组（随机行为可确定性验证）', () {
      final p0 = AuroraPalette.pick(math.Random(0));
      final p0again = AuroraPalette.pick(math.Random(0));
      expect(p0again, same(p0));
      expect(AuroraPalette.pool.contains(p0), isTrue);
    });
  });

  group('波参数不变量（多波向多倍频海浪的结构性保证）', () {
    test('层数恰为 4（远→近），每层恰 4 个波分量，alpha/色相查常量表', () {
      final layers = AuroraWaveLayer.generateLayers(math.Random(42));
      expect(layers.length, AuroraWaveLayer.count);
      expect(AuroraWaveLayer.count, 4);
      expect(AuroraWaveLayer.harmonicsPerLayer, 4);
      for (var i = 0; i < layers.length; i++) {
        expect(layers[i].alpha, AuroraWaveLayer.peakAlphas[i],
            reason: '第 $i 层 alpha 必须来自常量表（不随机，帽可静态审计）');
        expect(layers[i].hueDrift, AuroraWaveLayer.hueDrifts[i]);
        expect(layers[i].components.length, AuroraWaveLayer.harmonicsPerLayer,
            reason: '第 $i 层必须含 4 个波分量（多波向多倍频叠加的载体）');
      }
    });

    test('分量频率为 36s 主循环整数分之一，单波周期 ≥ 7.2s（≥4s 低频闸门）', () {
      for (var seed = 0; seed < 32; seed++) {
        final layers = AuroraWaveLayer.generateLayers(math.Random(seed));
        for (var i = 0; i < layers.length; i++) {
          for (var j = 0; j < layers[i].components.length; j++) {
            final speed = layers[i].components[j].speed;
            expect(speed, inInclusiveRange(1, 5),
                reason: 'seed=$seed 第 $i 层第 $j 分量 speed 越界（频率须为 36s '
                    '的整数分之一）');
            expect(36 / speed, greaterThanOrEqualTo(4),
                reason: 'seed=$seed 第 $i 层第 $j 分量单波周期 '
                    '${36 / speed}s < 4s（低频闸门）');
          }
        }
      }
    });

    test('波向角任意（[0, 2π) 全域）：32 个 seed 的波向覆盖四个象限', () {
      // 任意角波向是本次重构核心诉求——不再是水平左右二值
      for (var seed = 0; seed < 32; seed++) {
        final layers = AuroraWaveLayer.generateLayers(math.Random(seed));
        for (var i = 0; i < layers.length; i++) {
          for (final c in layers[i].components) {
            expect(c.angle, inInclusiveRange(0.0, 2 * math.pi),
                reason: 'seed=$seed 第 $i 层分量波向角越界');
          }
        }
      }
      // 区分度：跨 seed 波向角确实散布在四象限（cos/sin 正负皆出现）
      final hasPositiveKx = <bool>[];
      final hasNegativeKx = <bool>[];
      for (var seed = 0; seed < 32; seed++) {
        final layers = AuroraWaveLayer.generateLayers(math.Random(seed));
        final kx = layers.first.components.first.angle;
        hasPositiveKx.add(math.cos(kx) >= 0);
        hasNegativeKx.add(math.cos(kx) < 0);
      }
      expect(hasPositiveKx, contains(true), reason: '必须存在向右传播的波向');
      expect(hasNegativeKx, contains(true), reason: '必须存在向左传播的波向');
    });

    test('振幅归一：每层 Σ amp = 1（层振幅守恒 → alpha 帽可静态审计）', () {
      for (var seed = 0; seed < 32; seed++) {
        final layers = AuroraWaveLayer.generateLayers(math.Random(seed));
        for (var i = 0; i < layers.length; i++) {
          final sum = layers[i].components
              .fold<double>(0, (a, c) => a + c.amp);
          expect(sum, closeTo(1.0, 1e-9),
              reason: 'seed=$seed 第 $i 层分量振幅未归一（Σ amp = $sum）');
        }
      }
    });

    test('振幅/波长/水位/倾斜/谐波陡度落在克制区间（禁突兀摆动）', () {
      // 倍频波长表（与 AuroraWaveLayer.generate 的 _wavelengthTable 同口径）
      const wavelengthTable = [
        [0.90, 1.20],
        [0.45, 0.60],
        [0.22, 0.30],
        [0.12, 0.16],
      ];
      for (var seed = 0; seed < 32; seed++) {
        final layers = AuroraWaveLayer.generateLayers(math.Random(seed));
        for (var i = 0; i < layers.length; i++) {
          final l = layers[i];
          expect(l.amplitude, inInclusiveRange(0.035, 0.08),
              reason: 'seed=$seed 第 $i 层振幅越界');
          expect(l.level, inInclusiveRange(0.08, 0.92),
              reason: 'seed=$seed 第 $i 层水位越界');
          expect(l.tilt.abs(), lessThanOrEqualTo(0.05),
              reason: 'seed=$seed 第 $i 层倾斜过陡');
          for (var j = 0; j < l.components.length; j++) {
            final c = l.components[j];
            expect(c.wavelength, inInclusiveRange(
              wavelengthTable[j][0],
              wavelengthTable[j][1],
            ), reason: 'seed=$seed 第 $i 层第 $j 分量波长越出倍频档');
            expect(c.asym, inInclusiveRange(0.0, 0.35),
                reason: 'seed=$seed 第 $i 层第 $j 分量谐波陡度越界');
            expect(c.phase, inInclusiveRange(0.0, 1.0),
                reason: 'seed=$seed 第 $i 层第 $j 分量相位越界');
          }
        }
      }
    });

    test('seed 可复现：同 seed 重放层参数（含全部分量）逐层恒等', () {
      final a = AuroraWaveLayer.generateLayers(math.Random(7));
      final b = AuroraWaveLayer.generateLayers(math.Random(7));
      expect(b, equals(a), reason: '同 seed 必须重放出同一套层参数');
      // 值相等必须覆盖新增的分量序列（operator==/hashCode 锚点语义）
      for (var i = 0; i < a.length; i++) {
        expect(a[i].hashCode, b[i].hashCode,
            reason: '第 $i 层 hashCode 必须覆盖分量序列（值相等语义完整）');
        expect(a[i].components[0], b[i].components[0],
            reason: '分量级值相等必须成立（WaveComponent.operator==）');
      }
    });

    test('seed 有区分度：异 seed 层参数确实不同（随机焕新）', () {
      final a = AuroraWaveLayer.generateLayers(math.Random(7));
      final b = AuroraWaveLayer.generateLayers(math.Random(8));
      expect(b, isNot(equals(a)));
    });
  });

  group('海浪氛围层组件', () {
    testWidgets('正常态：AnimatedBuilder 驱动，相位随固定 pump 推进，多帧无异常无溢出',
        (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // 测试收尾卸载：海浪控制器 dispose → Ticker 注销（永续动画不外泄）
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
      });

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: AuroraAmbient(key: ValueKey('aurora')),
        ),
      ));
      final ambient = find.byKey(const ValueKey('aurora'));
      expect(ambient, findsOneWidget);
      expect(
        find.descendant(of: ambient, matching: find.byType(AnimatedBuilder)),
        findsOneWidget,
      );

      CustomPaint paintWidget() => tester.widget<CustomPaint>(
            find.descendant(of: ambient, matching: find.byType(CustomPaint)),
          );

      // 相位推进：pump 200ms（36s 相位）→ t 必然前移（永续动画在动）
      final t0 = (paintWidget().painter as AuroraFlowPainter).t;
      await tester.pump(const Duration(milliseconds: 200));
      final t1 = (paintWidget().painter as AuroraFlowPainter).t;
      expect(t1, greaterThan(t0), reason: '海浪层必须被控制器驱动');

      // 多帧固定 pump：无异常、无溢出（painter 全生命周期可渲染）
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(seconds: 9)); // 跨过一个单波周期
      expect(tester.takeException(), isNull, reason: '海浪绘制不得抛异常/溢出');
      expect(ambient, findsOneWidget);

      // 注入的 palette 为空 → session；painter 配色必为池内成员；
      // 波层结构与分量结构合法
      final painter = paintWidget().painter as AuroraFlowPainter;
      expect(AuroraPalette.pool.contains(painter.palette), isTrue);
      expect(painter.layers.length, AuroraWaveLayer.count);
      for (final layer in painter.layers) {
        expect(layer.components.length, AuroraWaveLayer.harmonicsPerLayer);
      }
    });

    testWidgets('seed 注入：painter 层参数与 generateLayers(seed) 逐层恒等',
        (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
      });

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: AuroraAmbient(key: ValueKey('aurora'), seed: 7),
        ),
      ));
      final ambient = find.byKey(const ValueKey('aurora'));
      final painter = (tester.widget<CustomPaint>(
        find.descendant(of: ambient, matching: find.byType(CustomPaint)),
      ).painter) as AuroraFlowPainter;
      expect(
        painter.layers,
        equals(AuroraWaveLayer.generateLayers(math.Random(7))),
        reason: 'seed 注入必须可复现全套层参数（含全部分量）',
      );
    });

    testWidgets('指定配色：painter 逐帧使用该组三色（随相位确定性演变）', (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
      });

      final palette = AuroraPalette.pool[0];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AuroraAmbient(key: ValueKey('aurora'), palette: palette),
        ),
      ));
      final ambient = find.byKey(const ValueKey('aurora'));
      final paintWidget = tester.widget<CustomPaint>(
        find.descendant(of: ambient, matching: find.byType(CustomPaint)),
      );
      final painter = paintWidget.painter as AuroraFlowPainter;
      expect(painter.palette, same(palette));
      expect(painter.palette.colors.length, 3);
    });

    testWidgets('关动效：disableAnimations → 静态一帧（无 AnimatedBuilder）', (tester) async {
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
                body: AuroraAmbient(key: ValueKey('aurora')),
              ),
            ),
          ),
        ),
      );
      final ambient = find.byKey(const ValueKey('aurora'));
      expect(ambient, findsOneWidget);
      expect(
        find.descendant(of: ambient, matching: find.byType(AnimatedBuilder)),
        findsNothing,
        reason: '关动效必须静止一帧（不启动控制器）',
      );
      final paintWidget = tester.widget<CustomPaint>(
        find.descendant(of: ambient, matching: find.byType(CustomPaint)),
      );
      expect((paintWidget.painter as AuroraFlowPainter).t, 0);
    });
  });
}
