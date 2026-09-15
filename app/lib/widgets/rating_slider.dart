// 渐变评分滑轨 —— 6 级 SuperMemo 风格评分（0-5）
// 设计：纸质暖色美学，渐变轨道 + 吸附式滑块 + 标签
//
// API：
//   RatingSlider(onRated: (int level) {}, enabled: true)
//   level 0..5 对应 ReviewRating.values[level]
//
// 手势取消：拖拽中手指滑出滑轨 Y 范围（±_kDragYTolerance 容差）→
// 本次拖拽取消，松手不评分（防止误触）。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 6 级评分标签（与 ReviewRating 枚举 index 对齐）
const _kLabels = ['忘了', '见过', '费力', '犹豫', '顺畅', '秒答'];

/// 滑轨总高度（dp）
const double _kSliderHeight = 72;

/// 拖拽 Y 方向容差（dp）：指针超出滑轨高度 ± 此容差 → 取消本次拖拽
const double _kDragYTolerance = 40;

/// 每档颜色（深红 → 翠绿）
const _kDotColors = [
  Color(0xFFE53935), // blackout  — 深红
  Color(0xFFFF7043), // foggy     — 橙红
  Color(0xFFFFA726), // struggled — 橙黄
  Color(0xFFC0CA33), // hesitant  — 黄绿
  Color(0xFF66BB6A), // smooth    — 浅绿
  Color(0xFF26A69A), // instant   — 翠绿
];

/// 轨道渐变色
const _kTrackGradient = LinearGradient(
  colors: [
    Color(0xFFE53935),
    Color(0xFFFF7043),
    Color(0xFFFFA726),
    Color(0xFFC0CA33),
    Color(0xFF66BB6A),
    Color(0xFF26A69A),
  ],
);

class RatingSlider extends StatefulWidget {
  const RatingSlider({super.key, required this.onRated, this.enabled = true});

  final ValueChanged<int> onRated;
  final bool enabled;

  @override
  State<RatingSlider> createState() => _RatingSliderState();
}

class _RatingSliderState extends State<RatingSlider>
    with SingleTickerProviderStateMixin {
  int? _selected; // null = 未选择
  int? _dragging; // 拖拽中临时高亮的档位
  bool _dragCancelled = false; // 拖拽滑出 Y 范围 → 本次松手取消
  Offset? _lastPointerLocal; // 最近一次指针事件位置（局部坐标）
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// 将全局 dx 转换为最近的档位 (0-5)
  int _hitLevel(double dx, double totalWidth) {
    if (totalWidth <= 0) return 0;
    final padding = 20.0; // 两侧内边距
    final usable = totalWidth - padding * 2;
    final t = ((dx - padding) / usable).clamp(0.0, 1.0);
    return (t * 5).round().clamp(0, 5);
  }

  void _select(int level) {
    if (!widget.enabled) return;
    HapticFeedback.lightImpact();
    setState(() => _selected = level);
    _pulse.forward(from: 0);
    // 短暂延迟让用户看到视觉反馈后再回调
    Future.delayed(const Duration(milliseconds: 180), () {
      if (mounted) {
        widget.onRated(level);
        // 评分发出后重置状态，为下一张卡准备
        Future.delayed(const Duration(milliseconds: 300), () {
          if (mounted) setState(() => _selected = null);
        });
      }
    });
  }

  /// 指针是否已滑出滑轨 Y 范围（含容差）
  bool get _pointerOutOfYRange {
    final p = _lastPointerLocal;
    if (p == null) return false;
    return p.dy < -_kDragYTolerance || p.dy > _kSliderHeight + _kDragYTolerance;
  }

  @override
  Widget build(BuildContext context) {
    final disabled = !widget.enabled;
    final opacity = disabled ? 0.4 : 1.0;

    return Opacity(
      opacity: opacity,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          return Listener(
            // 原始指针追踪：手势识别器未接管前（纯垂直拖拽）也能感知滑出 Y 范围
            onPointerDown: (e) => _lastPointerLocal = e.localPosition,
            onPointerMove: (e) => _lastPointerLocal = e.localPosition,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: disabled
                  ? null
                  : (d) => _select(_hitLevel(d.localPosition.dx, width)),
              onHorizontalDragStart: disabled
                  ? null
                  : (d) {
                      _dragCancelled = false;
                      setState(
                        () => _dragging = _hitLevel(d.localPosition.dx, width),
                      );
                    },
              onHorizontalDragUpdate: disabled
                  ? null
                  : (d) {
                      if (_dragCancelled) return;
                      // 手指滑出滑轨 Y 范围 → 取消本次拖拽（高亮复位）
                      if (_pointerOutOfYRange) {
                        _dragCancelled = true;
                        setState(() => _dragging = null);
                        return;
                      }
                      final level = _hitLevel(d.localPosition.dx, width);
                      if (level != _dragging) {
                        HapticFeedback.selectionClick();
                        setState(() => _dragging = level);
                      }
                    },
              onHorizontalDragEnd: disabled
                  ? null
                  : (d) {
                      final cancelled = _dragCancelled || _pointerOutOfYRange;
                      final level = _dragging;
                      _dragCancelled = false;
                      setState(() => _dragging = null);
                      if (cancelled) return; // 已滑出 Y 范围 → 松手不评分
                      if (level != null) _select(level);
                    },
              onHorizontalDragCancel: disabled
                  ? null
                  : () {
                      _dragCancelled = false;
                      setState(() => _dragging = null);
                    },
              child: SizedBox(
                height: _kSliderHeight,
                child: CustomPaint(
                  size: Size(width, _kSliderHeight),
                  painter: _SliderPainter(
                    selected: _selected,
                    dragging: _dragging,
                    pulseValue: _pulse,
                  ),
                  child: _buildLabels(width),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLabels(double totalWidth) {
    final padding = 20.0;
    final usable = totalWidth - padding * 2;
    final step = usable / 5;
    final active = _dragging ?? _selected;

    return Stack(
      children: [
        for (int i = 0; i < 6; i++)
          Positioned(
            left: padding + step * i - 24,
            bottom: 4,
            child: SizedBox(
              width: 48,
              child: Text(
                _kLabels[i],
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: active == i ? FontWeight.w600 : FontWeight.normal,
                  color: active == i ? _kDotColors[i] : const Color(0xFF999999),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _SliderPainter extends CustomPainter {
  _SliderPainter({
    required this.selected,
    required this.dragging,
    required this.pulseValue,
  }) : super(repaint: pulseValue);

  final int? selected;
  final int? dragging;
  final Animation<double> pulseValue;

  @override
  void paint(Canvas canvas, Size size) {
    final padding = 20.0;
    final trackY = 28.0; // 轨道垂直中心
    final trackH = 6.0;
    final usable = size.width - padding * 2;
    final step = usable / 5;

    // --- 轨道背景（浅灰圆角条） ---
    final trackRect = RRect.fromLTRBR(
      padding,
      trackY - trackH / 2,
      size.width - padding,
      trackY + trackH / 2,
      const Radius.circular(3),
    );
    canvas.drawRRect(trackRect, Paint()..color = const Color(0x18000000));

    // --- 渐变轨道填充 ---
    final gradientPaint = Paint()
      ..shader = _kTrackGradient.createShader(
        Rect.fromLTRB(
          padding,
          trackY - trackH / 2,
          size.width - padding,
          trackY + trackH / 2,
        ),
      );
    canvas.drawRRect(trackRect, gradientPaint);

    // --- 6 个刻度点 ---
    final active = dragging ?? selected;
    for (int i = 0; i < 6; i++) {
      final cx = padding + step * i;
      final isActive = active == i;

      // 外圈（活跃时放大 + 脉冲）
      if (isActive) {
        final pulseR = 14.0 + pulseValue.value * 4.0;
        canvas.drawCircle(
          Offset(cx, trackY),
          pulseR,
          Paint()..color = _kDotColors[i].withValues(alpha: 0.15),
        );
      }

      // 白底圆（底座）
      canvas.drawCircle(
        Offset(cx, trackY),
        isActive ? 12.0 : 8.0,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill,
      );

      // 阴影
      canvas.drawCircle(
        Offset(cx, trackY),
        isActive ? 12.0 : 8.0,
        Paint()
          ..color = const Color(0x15000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );

      // 彩色内圆
      canvas.drawCircle(
        Offset(cx, trackY),
        isActive ? 8.0 : 5.0,
        Paint()..color = _kDotColors[i],
      );

      // 活跃状态内白点
      if (isActive) {
        canvas.drawCircle(
          Offset(cx, trackY),
          3.0,
          Paint()..color = Colors.white,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SliderPainter oldDelegate) =>
      selected != oldDelegate.selected ||
      dragging != oldDelegate.dragging ||
      pulseValue.value != oldDelegate.pulseValue.value;
}
