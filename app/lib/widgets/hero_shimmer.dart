// 扫光层 —— 科目页（首页 Hero）蓝色 UI 屏的克制动效（Bug #14，P3）。
//
// 背景与定位：#14 用户真机反馈「科目界面蓝色 UI 屏无动态效果」。Hero 上
// 已有「渐变流动」①（AuroraAmbient，2026-09-07 节点⑧已改版为多层正弦
// 海浪涌动——四层柔彩波面缓涌，36s 主循环），但真机观感仍近静态——低
// alpha 波面的慢漂移难以察觉。
// 本组件补足「shimmer 扫光」②：一条低透明度白色高光带沿对角（与 Hero
// 渐变同向「\」）从屏左外缓慢扫到屏右外。移动边缘对动效感知的增益远高于
// 同亮度的静态柔光，克制参数下即可「看得出在动」（不动 AuroraAmbient：
// 已有验收测试锚定，且其 ≤0.15 alpha 帽是用户拍板的「信息明确」硬约束）。
//
// 动效参数待真机复查微调：
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

import 'package:flutter/material.dart';

/// Hero 蓝色屏扫光层：单条低透明度白色高光带，6s 一轮沿对角缓慢扫过。
class HeroShimmer extends StatefulWidget {
  const HeroShimmer({super.key});

  /// 一轮扫光周期。克制动效闸门 ≥4s（与渐变流动①同口径）。
  /// 动效参数待真机复查微调（节奏：屏内缓移约 3.4s + 屏外行进约 2.6s）。
  static const Duration sweepDuration = Duration(seconds: 6);

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
  /// -travel（屏左外）→ +travel（屏右外）。
  late final Animation<double> _sweep = Tween<double>(
    begin: -ShimmerSweepPainter.travel,
    end: ShimmerSweepPainter.travel,
  ).animate(_controller);

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
            // 关动效：光带钉在行程端点（屏外）——蓝屏零残留，信息层原样
            ? const CustomPaint(
                painter: ShimmerSweepPainter(ShimmerSweepPainter.travel),
                size: Size.infinite,
              )
            : AnimatedBuilder(
                animation: _sweep,
                builder: (context, _) => CustomPaint(
                  painter: ShimmerSweepPainter(_sweep.value),
                  size: Size.infinite,
                ),
              ),
      ),
    );
  }
}

/// 扫光绘制：一条对角「\」白色高光带（透明 → 峰值 → 透明的柔和渐变轴），
/// 随相位把渐变轴沿自身方向整体平移——色标不动、「光」在动。与流彩①的
/// AuroraFlowPainter 同一手法（确定性渲染，无逐帧随机）；两端 |phase| ≥
/// travel 时整带在可视区外，循环回卷无跳变。
class ShimmerSweepPainter extends CustomPainter {
  const ShimmerSweepPainter(this.phase);

  /// 光带行程相位：控制器 0→1 经 Tween 映射到 [-travel, +travel]。
  final double phase;

  /// 动效参数待真机复查微调（克制动效的数值锚点，组件测试逐项锁定）：
  ///   travel    行程端点——|phase| 达此值时光带完全出屏（1.8×1.15=2.07
  ///             的轴向平移远越屏缘 ±1 → 关动效静止帧零残留）；
  ///   peakAlpha 光带峰值（白 0.08——低透明度，扫过文字不影响可读性）；
  ///   bandHalf  光带半宽（沿渐变轴 0.16）。
  static const double travel = 1.15;
  static const double peakAlpha = 0.08;
  static const double bandHalf = 0.16;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final rect = Offset.zero & size;
    // 渐变轴（对角「\」，与 Hero 渐变同向）随 phase 沿轴向整体平移；
    // 光带中心（stop 0.5）恒在轴中点 → 相位即光带位置。
    final dx = 1.8 * phase;
    final dy = 0.7 * phase;
    final band = LinearGradient(
      begin: Alignment(-0.9 + dx, -0.35 + dy),
      end: Alignment(0.9 + dx, 0.35 + dy),
      colors: [
        Colors.white.withValues(alpha: 0),
        Colors.white.withValues(alpha: peakAlpha),
        Colors.white.withValues(alpha: 0),
      ],
      stops: [0.5 - bandHalf, 0.5, 0.5 + bandHalf],
    );
    canvas.drawRect(rect, Paint()..shader = band.createShader(rect));
  }

  @override
  bool shouldRepaint(ShimmerSweepPainter oldDelegate) =>
      oldDelegate.phase != phase;
}
