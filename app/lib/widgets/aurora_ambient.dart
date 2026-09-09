// 海浪氛围层 —— 首页 Hero 背景「多层正弦海浪涌动」（2026-09-07 节点⑧重写：
// 用户反馈蓝色窗口的柔光带观感不满意 → 改为海浪流动效果；方向随机且
// 自然优雅、缓慢不突兀——「余光可感知、直视不突兀」）。
//
// 设计取舍（随机 × 稳定 × 优雅三向平衡）：
//  · 随机可变：波传播方向（左→右 / 右→左）与各层振幅/波长/速度/相位/
//    水位/倾斜在实例创建时按随机源摇定（默认真随机——实例生命周期内
//    恒定，重建焕新；seed 可注入 → 测试可复现）。受控区间而非全自由
//    随机：振幅 3.5%~8% 屏高、单波周期 9~36s，杜绝突兀摆动。
//  · 缓慢自然：四层海浪自纵深（水位高、波长长、节奏缓）向近景（水位低、
//    灵动）层叠；振幅/水位再叠 36s 潮汐呼吸、色相按正弦极慢呼吸
//    （±7°~±12°）——方向与参数在生命周期内缓慢漂移，无机械循环感；
//    各层时间频率为 36s 主循环的整数分之一 → 回卷无缝。
//  · 优雅克制：波面峰值 alpha 合计 ≤ 0.15（沿「信息明确」硬约束口径），
//    配色沿用受控色池（[AuroraPalette]，高明度低灰度柔彩色，波面向下
//    渐隐），克制不抢内容。
//
// 「信息明确」硬约束落地（同进度页/首页既有口径）：
//   1. 纯装饰 CustomPainter 画在 Stack 最底层，信息 Widget 全在其上，
//      不参与命中测试（IgnorePointer），不遮挡任何文字；
//   2. 波面峰值 alpha 合计 ≤ 0.15（最坏全叠加不超帽）；
//   3. RepaintBoundary 隔离重绘（动画帧不外溢到信息层）；
//   4. MediaQuery.disableAnimations（系统「移除动画」/低性能模式）→
//      静止一帧（不启动控制器），信息层完全不受影响。
//
// 性能口径：单 AnimationController（36s repeat 永续）+ CustomPainter
// 确定性渲染（无逐帧随机）；每层 41 个采样点以 quadraticBezierTo 平滑
// 成波面（≤64 闸门），每帧分配仅 4 个 Path + 4 个渐变 Paint 量级（与
// 旧版三条整面渐变同量级）。永续动画——测试里禁用 pumpAndSettle，
// 一律固定时长 pump。

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一组流彩配色（波层循环取色）。色池为受控常量表：全部为高明度柔和色，
/// 组内成对色相差 ≥ 25°——「随机」只在池内发生，不会摇出刺眼组合。
class AuroraPalette {
  const AuroraPalette(this.name, this.colors);

  /// 搭配名（注释/测试报告用）
  final String name;

  /// 三色搭配（[AuroraFlowPainter.layers] 按 i % 3 循环取色）
  final List<Color> colors;

  /// 受控色池：六组三色搭配，全部高明度低灰度柔彩色（在品牌蓝底上呈现）。
  static const List<AuroraPalette> pool = [
    AuroraPalette('极光', [
      Color(0xFF7FF2E0), // 水绿 · 远层涌浪
      Color(0xFFC8B6FF), // 紫丁香 · 中层涌浪
      Color(0xFFFFE9C4), // 香槟金 · 近层涟漪
    ]),
    AuroraPalette('晨曦', [
      Color(0xFFFFD9C8), // 蜜桃 · 远层涌浪
      Color(0xFFFFC4D6), // 蔷薇粉 · 中层涌浪
      Color(0xFFA8F0E4), // 浅碧 · 近层涟漪
    ]),
    AuroraPalette('暮霭', [
      Color(0xFFC8B6FF), // 紫丁香 · 远层涌浪
      Color(0xFFCFE8FF), // 冰蓝 · 中层涌浪
      Color(0xFFFFC4D6), // 蔷薇粉 · 近层涟漪
    ]),
    AuroraPalette('湖屿', [
      Color(0xFFB9F0D0), // 薄荷 · 远层涌浪
      Color(0xFFFFE9C4), // 香槟金 · 中层涌浪
      Color(0xFFCFE8FF), // 冰蓝 · 近层涟漪
    ]),
    AuroraPalette('霜花', [
      Color(0xFFCFE8FF), // 冰蓝 · 远层涌浪
      Color(0xFFFFD9C8), // 蜜桃 · 中层涌浪
      Color(0xFFB9F0D0), // 薄荷 · 近层涟漪
    ]),
    AuroraPalette('鎏金', [
      Color(0xFFFFE9C4), // 香槟金 · 远层涌浪
      Color(0xFFFFC4D6), // 蔷薇粉 · 中层涌浪
      Color(0xFFB9F0D0), // 薄荷 · 近层涟漪
    ]),
  ];

  /// 会话级随机取一组：首次访问时摇定（static final），此后整个进程内
  /// 恒定同一组——「每次冷启动随机焕新，同一会话内稳定可识别」。
  static final AuroraPalette session = pick(math.Random());

  /// 按随机源取组（供 [session] 与测试注入确定性随机源）
  static AuroraPalette pick(math.Random rng) => pool[rng.nextInt(pool.length)];

  /// 恒等相等：色池为常量表，会话随机取组返回的是池内同一实例，
  /// 恒等即「同组配色」的精确语义（[AuroraFlowPainter.shouldRepaint] 用）。
  @override
  bool operator ==(Object other) => identical(other, this);

  @override
  int get hashCode => identityHashCode(this);
}

/// 波传播方向（水平主向；波面另有每层随机的小角度倾斜，见
/// [AuroraWaveLayer.tilt]——「带小角度倾斜」的组合效果）。
enum WaveDirection {
  /// 左 → 右传播
  leftToRight,

  /// 右 → 左传播
  rightToLeft,
}

/// 一层海浪的几何/呼吸参数（实例创建时按随机源摇定，生命周期内恒定；
/// 「缓慢漂移」由 [AuroraFlowPainter] 用相位 t 调制实现，不改本参数）。
class AuroraWaveLayer {
  const AuroraWaveLayer({
    required this.amplitude,
    required this.wavelength,
    required this.speed,
    required this.phase,
    required this.level,
    required this.tilt,
    required this.alpha,
    required this.hueDrift,
    required this.driftSeed,
  });

  /// 振幅（屏高占比 0.035~0.08）：波峰沿基线的起伏高度
  final double amplitude;

  /// 波长（屏宽占比 0.9~1.5）：一屏约一两个完整波——大波浪而非碎波纹
  final double wavelength;

  /// 时间频率：一个 36s 主循环内的完整周期数（1~4 → 单波周期 9~36s）。
  /// 整数倍保证主循环回卷时波面相位无缝衔接。
  final int speed;

  /// 空间相位（0~1，随机错开层间波峰位置）
  final double phase;

  /// 基线水位（屏高占比；远层高、近层低，错开形成纵深）
  final double level;

  /// 基线倾斜（±0.05 屏高）：波面带小角度，非水平机械线
  final double tilt;

  /// 波面峰值 alpha（常量表按层给定，见 [peakAlphas]）
  final double alpha;

  /// 色相呼吸幅度（度，同旧版柔光带口径）
  final double hueDrift;

  /// 潮汐呼吸相位种子（振幅/水位的 36s 慢漂移逐层错相）
  final double driftSeed;

  /// 层数（index 0 = 最远 … count-1 = 最近）
  static const int count = 4;

  /// 各层峰值 alpha 常量表（远→近）：合计 0.15（信息明确硬约束——
  /// 即使四层波面同点叠加也不超帽，对文字对比度影响可忽略）
  static const List<double> peakAlphas = [0.06, 0.04, 0.03, 0.02];

  /// 各层色相呼吸幅度（度）
  static const List<double> hueDrifts = [10, 7, 12, 8];

  /// 按随机源摇定全套层参数（index 0 = 最远 … count-1 = 最近）：
  /// 振幅/波长/速度/相位/倾斜落在克制区间随机，水位沿纵深梯度铺开，
  /// alpha/色相查常量表（不随机——保证 ≤0.15 帽可静态审计）。
  factory AuroraWaveLayer.generate(math.Random rng, int index) {
    final depth = index / (count - 1); // 0 远 → 1 近
    return AuroraWaveLayer(
      amplitude: 0.035 + rng.nextDouble() * 0.045,
      wavelength: 0.9 + rng.nextDouble() * 0.6,
      speed: 1 + rng.nextInt(4),
      phase: rng.nextDouble(),
      level: (0.32 + 0.5 * depth + (rng.nextDouble() - 0.5) * 0.08)
          .clamp(0.08, 0.92)
          .toDouble(),
      tilt: (rng.nextDouble() - 0.5) * 0.10,
      alpha: peakAlphas[index],
      hueDrift: hueDrifts[index],
      driftSeed: rng.nextDouble(),
    );
  }

  /// 按随机源生成全套层参数（count 层，顺序消耗随机源）。
  /// [AuroraAmbient] 的 State 与测试复现共用同一入口。
  static List<AuroraWaveLayer> generateLayers(math.Random rng) => [
        for (var i = 0; i < count; i++) AuroraWaveLayer.generate(rng, i),
      ];

  /// 值相等：同 seed 重放的同层参数逐字段相等（测试复现性锚点）。
  @override
  bool operator ==(Object other) =>
      other is AuroraWaveLayer &&
      other.amplitude == amplitude &&
      other.wavelength == wavelength &&
      other.speed == speed &&
      other.phase == phase &&
      other.level == level &&
      other.tilt == tilt &&
      other.alpha == alpha &&
      other.hueDrift == hueDrift &&
      other.driftSeed == driftSeed;

  @override
  int get hashCode => Object.hash(
        amplitude,
        wavelength,
        speed,
        phase,
        level,
        tilt,
        alpha,
        hueDrift,
        driftSeed,
      );
}

/// 海浪氛围层组件：多层正弦海浪涌动（受控色池配色 + 方向/层参数
/// 构建时随机 + 潮汐/色相极慢呼吸）。永续 repeat 动画——测试里禁用
/// pumpAndSettle，一律固定时长 pump。
class AuroraAmbient extends StatefulWidget {
  const AuroraAmbient({super.key, this.palette, this.seed, this.direction});

  /// 本次会话的流彩配色；null → [AuroraPalette.session]（会话级随机）。
  /// 测试可显式传入池内固定组，断言确定性行为。
  final AuroraPalette? palette;

  /// 波参数随机源种子；null → 真随机（实例生命周期内恒定）。
  /// 注入固定 seed → 方向/层参数可复现（测试锚点）。
  final int? seed;

  /// 波传播方向；null → 按随机源摇定（左→右 / 右→左 各半）。
  /// 测试可显式指定（显式注入不改变层参数的随机序列）。
  final WaveDirection? direction;

  @override
  State<AuroraAmbient> createState() => _AuroraAmbientState();
}

class _AuroraAmbientState extends State<AuroraAmbient>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    // 36s 主循环：各层时间频率为其整数分之一（单波周期 9~36s，
    // 全部 ≥8s 低频闸门；潮汐/色相呼吸 36s 一轮）
    duration: const Duration(seconds: 36),
  );

  WaveDirection _direction = WaveDirection.leftToRight;
  List<AuroraWaveLayer> _layers = const [];

  @override
  void initState() {
    super.initState();
    final rng = math.Random(widget.seed); // seed null → 真随机
    // 消费顺序固定：先层参数（generateLayers 独立成序列，与
    // AuroraWaveLayer.generateLayers(Random(seed)) 逐层恒等——测试复现
    // 锚点），再摇方向（direction 显式注入可覆盖，但仍消耗一次随机，
    // 保证同 seed 下注入与否层参数序列一致）。
    _layers = AuroraWaveLayer.generateLayers(rng);
    _direction = widget.direction ?? WaveDirection.values[rng.nextInt(2)];
  }

  @override
  void didUpdateWidget(AuroraAmbient oldWidget) {
    super.didUpdateWidget(oldWidget);
    // seed/direction 属「实例创建时摇定」参数：父级以新值重建时重摇一次
    // （保持注入语义诚实；home_page 使用点为 const，不触发本分支）。
    if (oldWidget.seed != widget.seed ||
        oldWidget.direction != widget.direction) {
      final rng = math.Random(widget.seed);
      _layers = AuroraWaveLayer.generateLayers(rng);
      _direction = widget.direction ?? WaveDirection.values[rng.nextInt(2)];
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统关闭动效（无障碍「移除动画」/低性能模式）→ 氛围层静止
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose(); // dispose 闸门：随 Widget 卸载必释放，Ticker 不外泄
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.of(context).disableAnimations;
    final palette = widget.palette ?? AuroraPalette.session;
    return IgnorePointer(
      child: RepaintBoundary(
        child: disabled
            ? CustomPaint(
                painter: AuroraFlowPainter(0, palette, _layers, _direction),
                size: Size.infinite,
              )
            : AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: AuroraFlowPainter(
                    _controller.value,
                    palette,
                    _layers,
                    _direction,
                  ),
                  size: Size.infinite,
                ),
              ),
      ),
    );
  }
}

/// 海浪绘制：四层正弦波面自远而近层叠（确定性渲染，无逐帧随机）。
/// 每层波面：
///   y(x) = 水位·h + 倾斜·h·(x/w − 0.5)
///          + 振幅·h·sin(2π(±x/λ − 速度·t + 相位))
/// ± 号即传播方向（[WaveDirection]）；振幅/水位再叠 36s 潮汐呼吸
/// （±25% / ±3%h）、色相按正弦极慢呼吸——层间速度/相位/水位/波长
/// 全部错开形成纵深，整数倍频率保证主循环回卷无跳变。波面以下用
/// 「波峰色 → 向下渐隐」的线性渐变填充（纵深下暗，同海水体感）。
class AuroraFlowPainter extends CustomPainter {
  AuroraFlowPainter(this.t, this.palette, this.layers, this.direction);

  /// 0.0~1.0 循环相位（36s 主循环）
  final double t;

  /// 本组流彩配色（波层按 i % 3 循环取色）
  final AuroraPalette palette;

  /// 波层参数（构建时随机摇定，生命周期内恒定）
  final List<AuroraWaveLayer> layers;

  /// 波传播方向
  final WaveDirection direction;

  /// 波面横向采样段数（≤64 闸门：41 个采样点 quadraticBezierTo 平滑
  /// 已足够圆滑，且波长远大于半屏无需更密）
  static const int samples = 40;

  /// 单层波面色：基色色相按正弦极慢漂移（「动态色彩」）。
  /// 高明度柔和基色在低 alpha 下呈薄纱般的淡彩，而非荧光色块。
  Color _waveColor(Color base, double hueDrift, double driftSeed) {
    final hsl = HSLColor.fromColor(base);
    final drift = math.sin(2 * math.pi * (t + driftSeed)) * hueDrift;
    final hue = (hsl.hue + drift).clamp(0.0, 360.0).toDouble();
    return hsl.withHue(hue).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final w = size.width;
    final h = size.height;
    // 两端越界采样：倾斜/波峰永不出可视直角（波面函数在屏外仍连续）
    final margin = w * 0.3;
    final x0 = -margin;
    final x1 = w + margin;
    final step = (x1 - x0) / samples;
    final dirSign = direction == WaveDirection.leftToRight ? 1.0 : -1.0;
    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      final twoPi = 2 * math.pi;
      // 潮汐呼吸（36s 周期，逐层错相）：振幅 ±25%、水位 ±3%h 缓慢漂移
      final drift = math.sin(twoPi * (t + layer.driftSeed));
      final amp = layer.amplitude * (0.75 + 0.25 * drift);
      final level = (layer.level + 0.03 * drift).clamp(0.05, 0.95).toDouble();
      final wavePhase =
          twoPi * (layer.phase - layer.speed * t); // −速度·t：回卷无缝
      final k = twoPi / (layer.wavelength * w); // 空间角频率（rad/px）
      double yAt(double x) =>
          level * h +
          layer.tilt * h * (x / w - 0.5) +
          amp * h * math.sin(dirSign * k * x + wavePhase);

      // 波面采样 → quadratic 平滑（中点法：控制点=前采样点，端点=中点）
      var px = x0;
      var py = yAt(x0);
      final path = Path()..moveTo(px, py);
      for (var s = 1; s <= samples; s++) {
        final nx = x0 + step * s;
        final ny = yAt(nx);
        path.quadraticBezierTo(px, py, (px + nx) / 2, (py + ny) / 2);
        px = nx;
        py = ny;
      }
      path.lineTo(x1, py); // 末端采样点（越界屏外）
      path.lineTo(x1, h + margin); // 封闭波面以下区域
      path.lineTo(x0, h + margin);
      path.close();

      // 填充：波峰色 → 向下渐隐（峰值 alpha 只在波峰带，向下衰减到 0）
      final breathe = 0.8 + 0.2 * math.sin(twoPi * (t + layer.driftSeed) + 1.3);
      final tint = _waveColor(
        palette.colors[i % palette.colors.length],
        layer.hueDrift,
        layer.driftSeed,
      );
      final band = Rect.fromLTRB(
        0,
        ((level - amp - 0.02).clamp(0.0, 1.0)).toDouble() * h,
        w,
        h,
      );
      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          tint.withValues(alpha: 0),
          tint.withValues(alpha: layer.alpha * breathe),
          tint.withValues(alpha: layer.alpha * breathe * 0.3),
          tint.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.12, 0.55, 1.0],
      );
      canvas.drawPath(path, Paint()..shader = gradient.createShader(band));
    }
  }

  @override
  bool shouldRepaint(AuroraFlowPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.palette != palette ||
      oldDelegate.direction != direction ||
      !identical(oldDelegate.layers, layers);
}
