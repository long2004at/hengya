// 扫光层 —— 科目页（首页 Hero）蓝色 UI 屏的克制动效（Bug #14，P3）。
//
// 背景与定位：#14 用户真机反馈「科目界面蓝色 UI 屏无动态效果」。Hero 上
// 已有「渐变流动」①（AuroraAmbient，2026-09-07 节点⑧改版为多层海浪
// 涌动、2026-10-11 重构为多波向 × 多倍频波分量叠加——四层柔彩波面缓涌
// + 浪尖泡沫，36s 主循环），但真机观感仍近静态——低
// alpha 波面的慢漂移难以察觉。
// 本组件补足「shimmer 扫光」②：一条低透明度白色高光带从屏外缓慢扫过。
// 移动边缘对动效感知的增益远高于同亮度的静态柔光，克制参数下即可
// 「看得出在动」（不动 AuroraAmbient：已有验收测试锚定，且其 ≤0.15 alpha
// 帽是用户拍板的「信息明确」硬约束）。
//
// 2026-10-12 返工（用户真机反馈）：旧版是**一条直线光带、每轮都沿同一个
// 对角「\」方向**直直扫过——观感单调。改为：
//   · 方向随机：每轮绕基础对角在受控角度内随机偏转，并以 50% 概率反向
//     扫过（见 [ShimmerSweepPainter.maxAngleJitter]）——不再千篇一律；
//   · 形状随机但受控：中心线由直线改为**单条正弦缓波**，振幅 = 光带半宽 ×
//     [ShimmerSweepPainter.ampScaleRange]（0.30~0.62）、波长 = 屏宽 ×
//     [ShimmerSweepPainter.wavelengthScaleRange]（0.55~1.05）、初相任意，
//     行进中波形再极缓流动（[ShimmerSweepPainter.waveDriftTurns]）——
//     屏内 1~2 个圆润缓波，峰度有帽，绝不摇出尖刺/夸张变形；
//   · 软边不变：仍是一条「透明 → 峰值 → 透明」的柔和光带，只是边缘跟着
//     波浪走（多层同心描边逼近升余弦剖面，见 [ShimmerSweepPainter.paint]）。
//   返工不变量：峰值 alpha 帽、行程端点必出屏（关动效零残留）、确定性渲染
//   （参数在实例创建/每轮回卷时摇定，绝无逐帧随机）、seed 可注入可复现。
//
// 动效参数（数值锚点，真机复查可微调）：
//   · 单带一轮 6s（≥4s 低频闸门，与渐变流动①同口径；屏内缓移约 3.4s、
//     其余屏外行进，循环回卷无跳变——|phase| ≥ travel 时整带在可视区外）；
//   · 光带峰值 alpha 0.08（白）——与流彩①最坏瞬时叠加 0.23，仍远低于
//     常规 shimmer 用量，扫过文字不影响可读性；
//   · 光带半宽 0.16（沿渐变轴）——窄带 = 移动边缘更利于感知。
//
// 「信息明确」硬约束（同流彩①/进度页既有口径）：
//   1. 纯装饰 CustomPainter 垫底（调用处置于信息层之下），不参与命中
//      测试（IgnorePointer），不遮挡任何文字；
//   2. RepaintBoundary 隔离重绘（动画帧不外溢到 Hero 信息层）；
//   3. MediaQuery.disableAnimations（系统「移除动画」/低性能模式）→
//      不启动控制器，光带钉在屏外（蓝屏零残留，与无动效版视觉一致）。
//
// 性能口径（#14 任务要求）：单 AnimationController（repeat 永续）+
// 复用 Tween（State 内只建一次，每帧仅 evaluate）；绘制收敛在
// CustomPainter 内，绝不逐帧重建 Hero 信息子树；dispose 闸门随
// Widget 卸载必释放，Ticker 不外泄。永续 repeat 动画——测试里禁用
// pumpAndSettle，一律固定时长 pump。

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Hero 蓝色屏扫光层：单条低透明度白色波浪光带，6s 一轮缓慢扫过；
/// 每轮的方向偏转/反向与波形（峰度、波长、相位）在受控区间内重新摇定。
class HeroShimmer extends StatefulWidget {
  const HeroShimmer({super.key, this.seed});

  /// 一轮扫光周期。克制动效闸门 ≥4s（与渐变流动①同口径）。
  /// 动效参数待真机复查微调（节奏：屏内缓移约 3.4s + 屏外行进约 2.6s）。
  static const Duration sweepDuration = Duration(seconds: 6);

  /// 注入固定 seed → 每轮的方向/波形参数可复现（测试锚点）。
  /// null（默认）= 真随机（每次冷启动焕新）。
  final int? seed;

  @override
  State<HeroShimmer> createState() => _HeroShimmerState();
}

class _HeroShimmerState extends State<HeroShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: HeroShimmer.sweepDuration,
  );

  /// 相位 → 光带行程：复用单一 Tween（不逐帧新建对象），线性映射
  /// -travel（屏外一侧）→ +travel（屏外另一侧）。
  late final Animation<double> _sweep = Tween<double>(
    begin: -ShimmerSweepPainter.travel,
    end: ShimmerSweepPainter.travel,
  ).animate(_controller);

  /// 每轮摇定的方向/波形参数（实例生命周期内恒定，仅回卷时重摇一次）。
  late final math.Random _rng = math.Random(widget.seed);
  late ShimmerWave _wave = ShimmerWave.reroll(_rng);

  /// 上一帧相位：用于识别 repeat 回卷（相位由 +travel 跳回 -travel）。
  double _lastPhase = double.negativeInfinity;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统关动效（无障碍「移除动画」/低性能模式）→ 不启动控制器
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
    return IgnorePointer(
      child: RepaintBoundary(
        child: disabled
            // 关动效：光带钉在行程端点（屏外）——蓝屏零残留，信息层原样。
            // 静止帧用 painter 的默认波形（零振幅直线），端点必出屏。
            ? const CustomPaint(
                painter: ShimmerSweepPainter(ShimmerSweepPainter.travel),
                size: Size.infinite,
              )
            : AnimatedBuilder(
                animation: _sweep,
                builder: (context, _) {
                  final v = _sweep.value;
                  // 回卷（+travel → -travel）＝上一轮已完全出屏 → 此刻重摇
                  // 下一轮的方向/波形：带体不可见，形状突变零观感跳变。
                  if (v < _lastPhase) _wave = ShimmerWave.reroll(_rng);
                  _lastPhase = v;
                  return CustomPaint(
                    painter: ShimmerSweepPainter(v, wave: _wave),
                    size: Size.infinite,
                  );
                },
              ),
      ),
    );
  }
}

/// 一轮扫光的方向/波形参数（每轮回卷时按随机源摇定，生命周期内恒定）。
///
/// 全部字段都落在受控区间内（区间锚点在 [ShimmerSweepPainter]）——
/// 「随机」只在池内发生，不会摇出竖直/水平的突兀斜角，也不会摇出尖刺波形。
/// 默认构造 = 零偏转 + 零振幅（直线），仅供「关动效静止帧」使用。
class ShimmerWave {
  const ShimmerWave({
    this.angleJitter = 0,
    this.reverse = false,
    this.amplitudeScale = 0,
    this.wavelengthScale = 1,
    this.phase = 0,
  });

  /// 按随机源摇定一轮参数（方向偏转/反向 + 峰度/波长/相位）。
  factory ShimmerWave.reroll(math.Random rng) {
    final range = ShimmerSweepPainter.ampScaleRange;
    final waveRange = ShimmerSweepPainter.wavelengthScaleRange;
    return ShimmerWave(
      angleJitter:
          (rng.nextDouble() * 2 - 1) * ShimmerSweepPainter.maxAngleJitter,
      reverse: rng.nextBool(),
      amplitudeScale: range[0] + (range[1] - range[0]) * rng.nextDouble(),
      wavelengthScale:
          waveRange[0] + (waveRange[1] - waveRange[0]) * rng.nextDouble(),
      phase: rng.nextDouble() * 2 * math.pi,
    );
  }

  /// 绕基础对角「\」的角度偏转（弧度，|值| ≤ maxAngleJitter）。
  final double angleJitter;

  /// 是否反向扫过（真 = 沿对角反方向行进，方向随机性的一半来源）。
  final bool reverse;

  /// 波形振幅 = 光带半宽 × 此系数（受控区间 ampScaleRange）。
  final double amplitudeScale;

  /// 波长 = 屏宽 × 此系数（受控区间 wavelengthScaleRange）。
  final double wavelengthScale;

  /// 正弦初相（弧度）。
  final double phase;

  @override
  bool operator ==(Object other) =>
      other is ShimmerWave &&
      other.angleJitter == angleJitter &&
      other.reverse == reverse &&
      other.amplitudeScale == amplitudeScale &&
      other.wavelengthScale == wavelengthScale &&
      other.phase == phase;

  @override
  int get hashCode => Object.hash(
    angleJitter,
    reverse,
    amplitudeScale,
    wavelengthScale,
    phase,
  );
}

/// 扫光绘制：一条**柔和的白色波浪光带**（中心线为单条正弦缓波，横向剖面
/// 为「透明 → 峰值 → 透明」的升余弦软边），随相位沿其法向整体平移——
/// 色标不动、「光」在动。与流彩①的 AuroraFlowPainter 同一手法
/// （确定性渲染，无逐帧随机）；两端 |phase| ≥ travel 时整带在可视区外，
/// 循环回卷无跳变。
class ShimmerSweepPainter extends CustomPainter {
  const ShimmerSweepPainter(this.phase, {this.wave = const ShimmerWave()});

  /// 光带行程相位：控制器 0→1 经 Tween 映射到 [-travel, +travel]。
  final double phase;

  /// 本轮的波形/方向参数（见 [ShimmerWave]）。
  final ShimmerWave wave;

  /// 动效参数待真机复查微调（克制动效的数值锚点，组件测试逐项锁定）：
  ///   travel    行程端点——|phase| 达此值时光带完全出屏（带体半长已含
  ///             屏沿投影 + 带半宽，端点外必无残留 → 关动效静止帧零残留）；
  ///   peakAlpha 光带峰值（白 0.08——低透明度，扫过文字不影响可读性）；
  ///   bandHalf  光带半宽（沿渐变轴 0.16）。
  static const double travel = 1.15;
  static const double peakAlpha = 0.08;
  static const double bandHalf = 0.16;

  /// 随机参数的**受控区间**（2026-10-12 返工锚点，「随机但受约束」的审计口）：
  ///   maxAngleJitter        方向偏转帽 ±14°（基础对角约 16°~26°，
  ///                         偏转后仍在 2°~40° 的舒展斜角内，不出现竖直/水平）；
  ///   ampScaleRange         波形振幅 = 带半宽 × 0.30~0.62（屏高的 2%~6% 量级，
  ///                         圆润缓波，不出现夸张变形）；
  ///   wavelengthScaleRange  波长 = 屏宽 × 0.55~1.05（屏内 1~2 个完整波峰）；
  ///   waveDriftTurns        行进中波形相位再缓移 0.25 个周期（避免「冻结曲线
  ///                         平移」的机械感，只动相位不动峰度）。
  static const double maxAngleJitter = 14 * math.pi / 180;
  static const List<double> ampScaleRange = [0.30, 0.62];
  static const List<double> wavelengthScaleRange = [0.55, 1.05];
  static const double waveDriftTurns = 0.25;

  /// 软边层数：多层同心描边叠加逼近升余弦剖面（层数越多越柔，
  /// 7 层时中心 alpha 误差 < 0.003，且总 overdraw 可控）。
  static const int edgeLayers = 7;

  /// 中心线采样段数（≤96 闸门内；缓波 1~2 个波峰，72 段远超 ≥10 点/波长）。
  static const int samples = 72;

  /// 端点余量（×bandHalfPx）：phase = ±travel 时中心平移额外多出这一份，
  /// 使带体（含圆头描边半径）完全越过屏沿 → 关动效静止帧零残留。
  static const double endpointMarginScale = 1.2;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final geo = ShimmerSweepGeometry.compute(size, wave, phase);
    final path = geo.buildPath();

    // 软边：多层同心描边，半径按 cos(πi/2L) 递减（覆盖计数逼近升余弦剖面），
    // 每层等权 alpha = peakAlpha / L → 中心累计 ≈ peakAlpha（≤ 帽），边缘渐隐。
    final layerAlpha = peakAlpha / edgeLayers;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = Colors.white.withValues(alpha: layerAlpha);
    for (var i = 0; i < edgeLayers; i++) {
      final r = geo.bandHalfPx * math.cos(math.pi * i / (2 * edgeLayers));
      if (r <= 0) continue;
      paint.strokeWidth = 2 * r;
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(ShimmerSweepPainter oldDelegate) =>
      oldDelegate.phase != phase || oldDelegate.wave != wave;
}

/// 扫光几何（纯函数计算，便于测试直接审计三条结构保证）：
///   · 零残留：phase = ±travel 时带体（含圆头半径）沿 [dir] 的投影必全在
///     屏外矩形之外；
///   · 非直线：中心线是正弦缓波（振幅 > 0 时偏离弦线）；
///   · 带宽帽：最大横截面半宽恒 = bandHalfPx = bandHalf × 基础对角长。
class ShimmerSweepGeometry {
  const ShimmerSweepGeometry({
    required this.dir,
    required this.normal,
    required this.center,
    required this.sHalf,
    required this.lineHalf,
    required this.bandHalfPx,
    required this.amp,
    required this.k,
    required this.drift,
  });

  /// 行进方向（单位向量，含方向偏转与反向）。
  final Offset dir;

  /// 单位法向（⊥ dir，波形沿此方向起伏）。
  final Offset normal;

  /// 中心线中点（相位平移后的位置）。
  final Offset center;

  /// 屏幕沿 [dir] 的半投影长。
  final double sHalf;

  /// 中心线半长（两端出屏）。
  final double lineHalf;

  /// 光带半宽（像素）。
  final double bandHalfPx;

  /// 波形振幅（像素）。
  final double amp;

  /// 波数（2π/波长）。
  final double k;

  /// 波形相位（含行进中缓移）。
  final double drift;

  /// 按尺寸/波形/相位计算本轮几何。
  static ShimmerSweepGeometry compute(Size size, ShimmerWave wave, double phase) {
    // 基础对角「\」单位方向（与 Hero 渐变同向），按 wave 微转 / 反向。
    final base = Offset(0.9 * size.width, 0.35 * size.height);
    final baseLen = base.distance;
    var dir = baseLen <= 0 ? const Offset(1, 0) : base / baseLen;
    final ca = math.cos(wave.angleJitter);
    final sa = math.sin(wave.angleJitter);
    dir = Offset(dir.dx * ca - dir.dy * sa, dir.dx * sa + dir.dy * ca);
    if (wave.reverse) dir = -dir;
    final n = Offset(-dir.dy, dir.dx); // 单位法向

    // 屏沿 dir 的半投影长（覆盖整屏所需）→ 中心线半长与行程换算。
    final sHalf = 0.5 * (size.width * dir.dx.abs() + size.height * dir.dy.abs());
    final bandHalfPx = ShimmerSweepPainter.bandHalf * baseLen;
    final lineHalf = sHalf + bandHalfPx;
    // phase = ±travel 时中心平移 sHalf + lineHalf + margin×bandHalfPx：
    // 整条带体（含圆头描边的半径）沿 dir 的最近投影 > sHalf（屏沿）→
    // 带体完全落在屏外矩形之外，关动效静止帧零残留。波形偏移沿法向 n
    // （⊥ dir），不改变 dir 投影，故不影响该结论。
    final travelPx = (sHalf + lineHalf +
            bandHalfPx * ShimmerSweepPainter.endpointMarginScale) /
        ShimmerSweepPainter.travel;
    final center =
        Offset(size.width / 2, size.height / 2) + dir * (phase * travelPx);

    // 波形：振幅 = 带半宽 × 系数（受控），波长 = 屏宽 × 系数（受控），
    // 相位 = 摇定初相 + 行进中极缓流动。
    final amp = bandHalfPx * wave.amplitudeScale;
    final wavelength =
        math.max(size.width * wave.wavelengthScale, 1.0);
    final k = 2 * math.pi / wavelength;
    final drift = wave.phase +
        2 * math.pi * ShimmerSweepPainter.waveDriftTurns * phase;

    return ShimmerSweepGeometry(
      dir: dir,
      normal: n,
      center: center,
      sHalf: sHalf,
      lineHalf: lineHalf,
      bandHalfPx: bandHalfPx,
      amp: amp,
      k: k,
      drift: drift,
    );
  }

  /// 中心线上参数 s ∈ [-lineHalf, lineHalf] 处的点。
  Offset pointAt(double s) =>
      center + dir * s + normal * (amp * math.sin(k * s + drift));

  /// 中心线路径（正弦缓波，[ShimmerSweepPainter.samples] 段）。
  Path buildPath() {
    final path = Path();
    for (var i = 0; i <= ShimmerSweepPainter.samples; i++) {
      final s = -lineHalf +
          2 * lineHalf * (i / ShimmerSweepPainter.samples);
      final p = pointAt(s);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path;
  }
}
