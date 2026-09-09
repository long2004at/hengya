// 学习罗盘表盘按钮（首页 Hero 右上角 · 2026-09-06 用户拍板重设计：
// 「与进度+罗盘主题契合」——原 Icons.explore_outlined 图标按钮改为真正的
// 表盘式圆形组件）。
//
// 视觉结构（自外而内）：
//  · 玻璃质感底盘：白 14% 底 + 白 30% 细描边圆（同 Hero 收件箱按钮语言），
//    左上微光泽（径向高光 alpha 0.10，金属表盘感）；
//  · 罗盘刻度环：12 刻度——4 主刻度（N/E/S/W 方位，白 55%）+ 8 细刻度
//    （白 26%），细线条、留白充分（高级感材质口径）；
//  · 进度弧：白 13% 轨道全环 + 白 95% 进度弧（圆头、2.4px），从正北
//    顺时针扫 fraction × 360°——数据源为学习罗盘总进度（learned/total，
//    与进度页 Hero「N/M 章已学」同口径，首页第四路尽力而为拉取）；
//  · 指针：双色罗盘针（亮头 95% + 半透尾 42%），指向进度弧末端——进度
//    变化时针随弧走（600ms easeOutCubic 隐式动画，进页有 Sweep-in）；
//    点击时指针恰旋摆一整圈（720ms easeInOutCubic 单次动画，落点与
//    起点视觉等价，无需复位）——「点一下进罗盘」的动效过渡。
//
// 降级与无障碍：
//  · fraction=0（拉不到 progress / 旧服务器 / 未配置教材）→ 空表盘：仅
//    刻度环 + 静止指针（正北），仍可点击进进度页（完整错误态由进度页兜底）；
//  · MediaQuery.disableAnimations（系统「移除动画」）→ 指针不旋摆、进度
//    变化瞬时到位（Duration.zero），点击行为不受影响；
//  · 动画均为一次性（TweenAnimationBuilder / 单次 forward），无永续动画
//    ——测试用固定 pump 即可推进，无需 pumpAndSettle。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// 罗盘表盘按钮：表盘绘制 + 点击旋摆 + 进度隐式动画 + Tooltip 挂点。
class CompassDialButton extends StatefulWidget {
  const CompassDialButton({
    super.key,
    required this.fraction,
    required this.onPressed,
    this.tooltip = '学习进度（学习罗盘）',
    this.size = 44,
  });

  /// 学习罗盘总进度 0.0~1.0（越界自动收敛到 [0,1]）
  final double fraction;

  /// 点击回调（首页接线：context.push('/progress')）
  final VoidCallback onPressed;

  /// 无障碍/长按提示文案（默认与原 IconButton tooltip 一致——上游
  /// ui_button_sweep_test 以 byTooltip 定位本按钮）
  final String tooltip;

  /// 表盘视觉直径（点击热区固定 48×48 Material 最小触达）
  final double size;

  @override
  State<CompassDialButton> createState() => _CompassDialButtonState();
}

class _CompassDialButtonState extends State<CompassDialButton>
    with SingleTickerProviderStateMixin {
  /// 点击旋摆：一次性 forward(from: 0)，720ms 恰一整圈后停在 1.0
  /// （+2π ≡ 原角，视觉无残留，无需复位）
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  );

  /// 旋摆缓动：慢起慢收的整圈旋转（easeInOutCubic）
  late final Animation<double> _spinEased = CurvedAnimation(
    parent: _spin,
    curve: Curves.easeInOutCubic,
  );

  @override
  void dispose() {
    _spin.dispose(); // dispose 闸门：一次性动画随卸载必释放
    super.dispose();
  }

  void _handleTap() {
    if (!MediaQuery.of(context).disableAnimations) {
      _spin.forward(from: 0); // 指针整圈旋摆（点击进罗盘的动效过渡）
    }
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.of(context).disableAnimations;
    final fraction = widget.fraction.clamp(0.0, 1.0).toDouble();
    return Tooltip(
      message: widget.tooltip,
      child: SizedBox(
        width: 48,
        height: 48, // Material 最小触达热区（表盘视觉 44px 居中其内）
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _handleTap,
            child: Center(
              child: Container(
                width: widget.size,
                height: widget.size,
                // 玻璃底盘：白 14% 底 + 白 30% 细描边（同 Hero 玻璃语言）
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.14),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.30),
                    width: 1.2,
                  ),
                ),
                child: RepaintBoundary(
                  // 进度隐式动画：首次构建 Sweep-in、数据变化平滑跟针；
                  // 关动效 → Duration.zero 瞬时到位
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: fraction),
                    duration: disabled
                        ? Duration.zero
                        : const Duration(milliseconds: 600),
                    curve: Curves.easeOutCubic,
                    builder: (context, f, _) => AnimatedBuilder(
                      animation: _spinEased,
                      builder: (context, _) => CustomPaint(
                        painter: CompassDialPainter(
                          fraction: f,
                          spin: disabled ? 0 : _spinEased.value,
                        ),
                        size: Size.square(widget.size),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 表盘绘制：微光泽 + 罗盘刻度环 + 进度弧（轨道+进度）+ 双色罗盘针。
/// 纯绘制不含动画状态（fraction/spin 由外部动画驱动逐帧传入）。
class CompassDialPainter extends CustomPainter {
  const CompassDialPainter({required this.fraction, required this.spin});

  /// 已动画到位的进度值（0.0~1.0）
  final double fraction;

  /// 点击旋摆相位（0.0~1.0，恰一整圈；0 = 无旋摆）
  final double spin;

  /// 指针角（屏幕弧度系：0 = 正东，顺时针为正）。
  /// 0 进度 → 正北（-π/2），随进度顺时针走满一圈；
  /// 旋摆 spin ∈ [0,1] 恰加 2π → 落点与起点视觉等价。
  static double needleAngle(double fraction, double spin) =>
      -math.pi / 2 + fraction * 2 * math.pi + spin * 2 * math.pi;

  /// 进度弧扫角：从正北顺时针 fraction × 360°
  static double arcSweep(double fraction) => fraction * 2 * math.pi;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide / 2;

    // —— 微光泽：左上径向高光（alpha 0.10，金属表盘感）——
    final gloss = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.45, -0.5),
        radius: 1.1,
        colors: [
          Colors.white.withValues(alpha: 0.10),
          Colors.white.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, gloss);

    // —— 罗盘刻度环：12 刻度（4 主 N/E/S/W + 8 细），自正北起 ——
    final tickOuter = radius - 2.5;
    for (var i = 0; i < 12; i++) {
      final major = i % 3 == 0; // 0°/90°/180°/270° 主刻度
      final len = major ? 5.0 : 2.8;
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: major ? 0.55 : 0.26)
        ..strokeWidth = major ? 1.4 : 0.9
        ..strokeCap = StrokeCap.round;
      final angle = -math.pi / 2 + i * math.pi / 6;
      final dir = Offset(math.cos(angle), math.sin(angle));
      canvas.drawLine(
        center + dir * (tickOuter - len),
        center + dir * tickOuter,
        paint,
      );
    }

    // —— 进度弧：白 13% 轨道全环 + 白 95% 进度弧（圆头，自正北顺时针）——
    final arcRadius = radius - 8.5;
    final track = Paint()
      ..color = Colors.white.withValues(alpha: 0.13)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;
    canvas.drawCircle(center, arcRadius, track);
    final sweep = arcSweep(fraction);
    if (sweep > 0.001) {
      final progress = Paint()
        ..color = Colors.white.withValues(alpha: 0.95)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: arcRadius),
        -math.pi / 2,
        sweep,
        false,
        progress,
      );
    }

    // —— 罗盘针：双色（亮头 + 半透尾），指向进度弧末端 ——
    final angle = needleAngle(fraction, spin);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle); // 旋转后局部 +x 即指针指向
    const headLen = 10.5; // 针头长（指向弧末端）
    const tailLen = 6.5; // 针尾长（配重感）
    const halfWidth = 2.6;
    final head = Path()
      ..moveTo(headLen, 0)
      ..lineTo(0, halfWidth)
      ..lineTo(0, -halfWidth)
      ..close();
    canvas.drawPath(
      head,
      Paint()..color = Colors.white.withValues(alpha: 0.95),
    );
    final tail = Path()
      ..moveTo(-tailLen, 0)
      ..lineTo(0, halfWidth)
      ..lineTo(0, -halfWidth)
      ..close();
    canvas.drawPath(
      tail,
      Paint()..color = Colors.white.withValues(alpha: 0.42),
    );
    canvas.restore();

    // —— 轴心：白点 + 品牌蓝深芯（表盘针轴的金属层次）——
    canvas.drawCircle(
      center,
      1.8,
      Paint()..color = Colors.white.withValues(alpha: 0.95),
    );
    canvas.drawCircle(center, 0.9, Paint()..color = HengyaColors.brandDeep);
  }

  @override
  bool shouldRepaint(CompassDialPainter oldDelegate) =>
      oldDelegate.fraction != fraction || oldDelegate.spin != spin;
}
