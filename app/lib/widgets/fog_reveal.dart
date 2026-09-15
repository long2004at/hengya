// 答案雾（#12 v3：预渲染模糊 + 渐变浓雾 + 擦除修复 + 纸角美化）
// =====================================================================
// 复习时答案被磨砂玻璃覆盖：
//   · 渐变浓雾：左上角淡（隐约可感）→ 右下角浓（完全遮盖）；
//   · 手指在雾面上滑动 = "擦玻璃"，saveLayer+dstOut 无缝隙擦除；
//   · 右下角纸角可拖动 → 纸页卷曲掀开，露出下面答案；
//     松手超阈值 → 飞出全清；不足 → 弹性拉回；
//   · 点纸角 = 自动掀页动画；
//   · 换卡 reset() 重新上雾。
//
// v3 性能策略（方案 B 混合策略）：
//   - 静态状态（idle/erasing）：保留 BackdropFilter 真模糊
//   - 翻页动画（peeling/springback/flying）：切换为不透明渐变遮罩
//     → 翻页 60fps，无 BackdropFilter 每帧重算开销
// =====================================================================

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// ---------------------------------------------------------------- 常量 ----

/// 模糊 sigma（越大越模糊，8-12 之间平衡清晰度和遮盖效果）
const double kFogBlurSigma = 10.0;

/// 雾层暖色调叠加（半透明纸白，让模糊区有温暖质感）
const Color kFogTintColor = Color(0x55F5F0E6);

/// 渐变浓雾：左上角淡色
const Color kFogGradientLight = Color(0x20F5F0E6);

/// 渐变浓雾：右下角浓色
const Color kFogGradientDense = Color(0x70F5F0E6);

/// 擦除笔刷半径（dp）
const double kEraseBrushRadius = 20.0;

/// 擦除边缘柔和模糊半径
const double kEraseSoftEdge = 6.0;

/// 擦除边缘柔和消散过渡半径（dp）
const double kEraseDissolveRadius = 10.0;

/// 纸角触摸热区大小（dp）
const double kCornerHitSize = 56.0;

/// 纸角三角形边长（dp）
const double kCornerTriSize = 28.0;

/// 飞出 / 弹回阈值：拖动距离 / 对角线
const double kFlyOutThreshold = 0.35;

/// 飞出速度阈值（px/s）
const double kFlyOutVelocity = 800.0;

/// 雾纸最小高度（dp）
const double kFogSheetMinHeight = 120.0;

// ---------------------------------------------------------------- 枚举 ----

enum FogPhase { idle, erasing, peeling, springback, flying, cleared }

enum FogSheetMode { fill, hugText }

// ---------------------------------------------------------- 控制器 ----

class FogRevealController extends ChangeNotifier {
  FogPhase _phase = FogPhase.idle;
  final List<List<Offset>> strokes = [];
  Offset _dragPoint = Offset.zero;
  int _generation = 0;
  double sheetHeight = 0;

  FogPhase get phase => _phase;
  bool get isCleared => _phase == FogPhase.cleared;
  bool get isPeeling =>
      _phase == FogPhase.peeling ||
      _phase == FogPhase.flying ||
      _phase == FogPhase.springback;
  Offset get dragPoint => _dragPoint;
  int get generation => _generation;

  void reset() {
    _phase = FogPhase.idle;
    strokes.clear();
    _dragPoint = Offset.zero;
    _generation++;
    notifyListeners();
  }

  // ---- 擦除 ----

  void beginErase(Offset p) {
    if (_phase == FogPhase.cleared || isPeeling) return;
    _phase = FogPhase.erasing;
    strokes.add([p]);
    notifyListeners();
  }

  void erase(Offset p) {
    if (_phase != FogPhase.erasing || strokes.isEmpty) return;
    strokes.last.add(p);
    notifyListeners();
  }

  void endErase() {
    if (_phase == FogPhase.erasing) {
      _phase = FogPhase.idle;
      notifyListeners();
    }
  }

  // ---- 纸角翻页 ----

  void beginPeel(Offset p) {
    if (_phase == FogPhase.cleared) return;
    _phase = FogPhase.peeling;
    _dragPoint = p;
    notifyListeners();
  }

  void updatePeel(Offset p) {
    if (_phase != FogPhase.peeling) return;
    _dragPoint = p;
    notifyListeners();
  }

  void startFlyOut(Offset to) {
    _phase = FogPhase.flying;
    _dragPoint = to;
    notifyListeners();
  }

  void startSpringBack() {
    _phase = FogPhase.springback;
    notifyListeners();
  }

  void endSpringBack() {
    if (_phase == FogPhase.springback) {
      _phase = FogPhase.idle;
      notifyListeners();
    }
  }

  void setDragPoint(Offset p) {
    _dragPoint = p;
    notifyListeners();
  }

  void markCleared() {
    _phase = FogPhase.cleared;
    notifyListeners();
  }
}

// ---------------------------------------------------------- 主 Widget ----

class FogPeel extends StatefulWidget {
  const FogPeel({
    super.key,
    required this.controller,
    required this.child,
    this.sheetMode = FogSheetMode.fill,
  });

  final FogRevealController controller;
  final Widget child;
  final FogSheetMode sheetMode;

  @override
  State<FogPeel> createState() => _FogPeelState();
}

class _FogPeelState extends State<FogPeel> with SingleTickerProviderStateMixin {
  late AnimationController _anim;
  Offset _animFrom = Offset.zero;
  Offset _animTo = Offset.zero;
  Offset? _panDownPoint;
  int _animGeneration = -1;
  double _fade = 1.0;
  double? _measuredTextHeight;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant FogPeel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _anim.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  // ---- 手势 ----

  bool _inCornerZone(Offset local, Size size) {
    return local.dx >= size.width - kCornerHitSize &&
        local.dy >= size.height - kCornerHitSize;
  }

  void _onPanDown(DragDownDetails d) {
    _panDownPoint = d.localPosition;
  }

  void _onPanStart(DragStartDetails d) {
    final ctrl = widget.controller;
    if (ctrl.isCleared) return;
    final p = d.localPosition;
    final sz = context.size ?? Size.zero;
    if (_inCornerZone(_panDownPoint ?? p, sz)) {
      ctrl.beginPeel(p);
    } else {
      ctrl.beginErase(p);
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final ctrl = widget.controller;
    if (ctrl.phase == FogPhase.peeling) {
      ctrl.updatePeel(d.localPosition);
    } else if (ctrl.phase == FogPhase.erasing) {
      ctrl.erase(d.localPosition);
    }
  }

  void _onPanEnd(DragEndDetails d) {
    final ctrl = widget.controller;
    final gen = ctrl.generation;
    if (ctrl.phase == FogPhase.erasing) {
      ctrl.endErase();
      return;
    }
    if (ctrl.phase != FogPhase.peeling) return;

    final sz = context.size ?? Size.zero;
    final c = Offset(sz.width, sz.height); // 右下角原点
    final diag = c.distance;
    final dragDist = (ctrl.dragPoint - c).distance;
    final vel = d.velocity.pixelsPerSecond.distance;

    if (dragDist >= diag * kFlyOutThreshold || vel >= kFlyOutVelocity) {
      // 飞出
      final dir = (ctrl.dragPoint - c);
      final norm = dir / dir.distance;
      final target = c + norm * diag * 1.5;
      _animFrom = ctrl.dragPoint;
      _animTo = target;
      ctrl.startFlyOut(target);
      _animGeneration = gen;
      _anim
        ..duration = const Duration(milliseconds: 350)
        ..reset();
      _fade = 1.0;
      _anim.addListener(_flyOutTick);
      _anim.forward();
    } else {
      // 弹回
      _animFrom = ctrl.dragPoint;
      _animTo = c;
      ctrl.startSpringBack();
      _animGeneration = gen;
      _anim
        ..duration = const Duration(milliseconds: 240)
        ..reset();
      _anim.addListener(_springBackTick);
      _anim.forward();
    }
  }

  void _onTap() {
    final ctrl = widget.controller;
    if (ctrl.isCleared) return;
    final sz = context.size ?? Size.zero;
    final c = Offset(sz.width, sz.height);
    // 自动掀页：从右下角到左上方
    final gen = ctrl.generation;
    ctrl.beginPeel(c);
    _animFrom = c;
    _animTo = Offset(-sz.width * 0.3, -sz.height * 0.3);
    ctrl.startFlyOut(_animTo);
    _animGeneration = gen;
    _anim
      ..duration = const Duration(milliseconds: 450)
      ..reset();
    _fade = 1.0;
    _anim.addListener(_flyOutTick);
    _anim.forward();
  }

  void _flyOutTick() {
    if (widget.controller.generation != _animGeneration) return;
    final t = Curves.easeOut.transform(_anim.value);
    widget.controller
        .setDragPoint(Offset.lerp(_animFrom, _animTo, t)!);
    _fade = 1.0 - t;
    if (_anim.value >= 1.0) {
      _anim.removeListener(_flyOutTick);
      widget.controller.markCleared();
      setState(() => _fade = 1.0);
    }
  }

  void _springBackTick() {
    if (widget.controller.generation != _animGeneration) return;
    final t = Curves.elasticOut.transform(_anim.value);
    widget.controller
        .setDragPoint(Offset.lerp(_animFrom, _animTo, t)!);
    if (_anim.value >= 1.0) {
      _anim.removeListener(_springBackTick);
      widget.controller.setDragPoint(_animTo);
      widget.controller.endSpringBack();
    }
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;

    return LayoutBuilder(builder: (context, constraints) {
      final avail = Size(constraints.maxWidth,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 400);

      Widget answerContent(Size sz) => SizedBox(
            width: sz.width,
            child: widget.child,
          );

      if (ctrl.isCleared) {
        return answerContent(avail);
      }

      if (widget.sheetMode == FogSheetMode.fill) {
        ctrl.sheetHeight = avail.height;
        return _buildFogStack(answerContent(avail), avail);
      }

      // hugText 模式：测量文字高度
      final measured = _measuredTextHeight;
      final sheetH = measured == null
          ? kFogSheetMinHeight
          : measured.clamp(kFogSheetMinHeight, avail.height);
      ctrl.sheetHeight = sheetH;

      return SizedBox(
        width: avail.width,
        height: sheetH,
        child: Stack(
          children: [
            // Offstage 副本测量文字实际高度
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: _HugTextMeasurer(
                width: avail.width,
                onHeight: (h) {
                  if ((_measuredTextHeight == null ||
                          (h - _measuredTextHeight!).abs() > 1)) {
                    setState(() => _measuredTextHeight = h);
                  }
                },
                child: widget.child,
              ),
            ),
            SizedBox(
              width: avail.width,
              height: sheetH,
              child: _buildFogStack(answerContent(Size(avail.width, sheetH)),
                  Size(avail.width, sheetH)),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildFogStack(Widget answerContent, Size avail) {
    final ctrl = widget.controller;
    final isAnimating = ctrl.isPeeling;
    final fadeOpacity =
        ctrl.phase == FogPhase.flying ? _fade.clamp(0.0, 1.0) : 1.0;

    // P4: ClipRect 兜底——翻页卷曲不溢出自身边界
    return ClipRect(
      child: SizedBox(
        width: avail.width,
        height: avail.height,
        child: GestureDetector(
          onPanDown: _onPanDown,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onTap: _onTap,
          behavior: HitTestBehavior.opaque,
          child: Stack(
            children: [
              // Layer 0：答案内容（始终渲染，被雾遮盖）
              Positioned.fill(child: answerContent),

              // Layer 1：模糊层
              // P0 方案 B：静态用 BackdropFilter 真模糊，翻页动画切换为不透明遮罩
              if (!isAnimating)
                // 静态状态：BackdropFilter 真模糊（仅裁剪翻页区域，擦除由 tint 层处理）
                Positioned.fill(
                  child: Opacity(
                    opacity: fadeOpacity,
                    child: ClipPath(
                      clipper: _PeelOnlyClipper(
                        peelCorner: null, // 静态无翻页
                        sheetSize: avail,
                      ),
                      child: BackdropFilter(
                        filter: ui.ImageFilter.blur(
                          sigmaX: kFogBlurSigma,
                          sigmaY: kFogBlurSigma,
                        ),
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),

              // Layer 2：渐变雾色叠加层（P1 渐变浓雾 + P2 擦除 + P5 柔和消散）
              // 统一用 CustomPainter + saveLayer + dstOut 处理
              Positioned.fill(
                child: Opacity(
                  opacity: fadeOpacity,
                  child: CustomPaint(
                    painter: _FogTintPainter(
                      strokes: ctrl.strokes,
                      peelCorner: ctrl.isPeeling ? ctrl.dragPoint : null,
                      sheetSize: avail,
                      isAnimating: isAnimating,
                    ),
                  ),
                ),
              ),

              // Layer 3：纸角提示 + 翻页卷曲视觉（P3 美化）
              if (!ctrl.isCleared)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CornerPainter(
                      phase: ctrl.phase,
                      dragPoint: ctrl.dragPoint,
                      sheetSize: avail,
                      fade: fadeOpacity,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------- 翻页区域裁剪 ----
// 仅处理翻页揭开区域裁剪，擦除由 _FogTintPainter 的 saveLayer+dstOut 处理

class _PeelOnlyClipper extends CustomClipper<Path> {
  _PeelOnlyClipper({
    this.peelCorner,
    required this.sheetSize,
  });

  final Offset? peelCorner;
  final Size sheetSize;

  @override
  Path getClip(Size size) {
    final rect = Offset.zero & size;
    Path fogPath = Path()..addRect(rect);

    // 减去翻页揭开区域
    if (peelCorner != null) {
      final peelPath = _buildPeelRevealPath(peelCorner!, size);
      if (peelPath != null) {
        fogPath = Path.combine(PathOperation.difference, fogPath, peelPath);
      }
    }

    return fogPath;
  }

  @override
  bool shouldReclip(covariant _PeelOnlyClipper oldClipper) =>
      oldClipper.peelCorner != peelCorner;

  /// 翻页揭开区域：从右下角到拖动点，用折线分割
  static Path? _buildPeelRevealPath(Offset drag, Size size) {
    final corner = Offset(size.width, size.height);
    final mid = Offset(
      (corner.dx + drag.dx) / 2,
      (corner.dy + drag.dy) / 2,
    );
    final d = corner - drag;
    final len = d.distance;
    if (len < 2) return null;

    // 折线方向（垂直于 corner→drag）
    final u = Offset(d.dx / len, d.dy / len);
    final v = Offset(-u.dy, u.dx);

    // 折线延伸足够长以覆盖整个 sheet
    final big = size.width + size.height;
    final foldA = mid + v * big;
    final foldB = mid - v * big;

    // 揭开区域 = corner 侧的半平面
    final path = Path()
      ..moveTo(foldA.dx, foldA.dy)
      ..lineTo(foldB.dx, foldB.dy)
      ..lineTo(foldB.dx + u.dx * big, foldB.dy + u.dy * big)
      ..lineTo(foldA.dx + u.dx * big, foldA.dy + u.dy * big)
      ..close();

    // 与 sheet rect 相交，只取 sheet 内的部分
    final sheetPath = Path()..addRect(Offset.zero & size);
    return Path.combine(PathOperation.intersect, path, sheetPath);
  }
}

// ----------------------------------------- 渐变雾色 + 擦除 + 消散 ----
// P1: 渐变浓雾（左上淡 → 右下浓）
// P2: saveLayer + dstOut 无缝擦除
// P5: 擦除边缘柔和消散（MaskFilter.blur）

class _FogTintPainter extends CustomPainter {
  _FogTintPainter({
    required this.strokes,
    this.peelCorner,
    required this.sheetSize,
    required this.isAnimating,
  });

  final List<List<Offset>> strokes;
  final Offset? peelCorner;
  final Size sheetSize;
  final bool isAnimating;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;

    // 翻页时裁剪掉揭开区域
    if (peelCorner != null) {
      final peelPath = _PeelOnlyClipper._buildPeelRevealPath(
          peelCorner!, size);
      if (peelPath != null) {
        final clipPath = Path()..addRect(rect);
        final clipped =
            Path.combine(PathOperation.difference, clipPath, peelPath);
        canvas.save();
        canvas.clipPath(clipped);
      }
    }

    // saveLayer 以支持 dstOut 擦除
    canvas.saveLayer(rect, Paint());

    // P1: 渐变浓雾底色 —— 左上淡，右下浓
    final gradientPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [kFogGradientLight, kFogGradientDense],
      ).createShader(rect);
    canvas.drawRect(rect, gradientPaint);

    // 翻页动画时叠加额外不透明度补偿（取代 BackdropFilter 的遮盖力）
    if (isAnimating) {
      final solidPaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0x60E8E0D4), Color(0xC0E8E0D4)],
        ).createShader(rect);
      canvas.drawRect(rect, solidPaint);
    }

    // P2 + P5: 擦除（saveLayer 内 dstOut，无缝隙 + 柔和消散边缘）
    if (strokes.isNotEmpty) {
      final erasePaint = Paint()
        ..blendMode = BlendMode.dstOut
        ..color = const Color(0xFFFFFFFF)
        ..strokeWidth = kEraseBrushRadius * 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        // P5: MaskFilter 让擦除边缘柔和过渡
        ..maskFilter =
            const MaskFilter.blur(BlurStyle.normal, kEraseDissolveRadius);

      for (final stroke in strokes) {
        if (stroke.isEmpty) continue;
        if (stroke.length == 1) {
          canvas.drawCircle(
            stroke[0],
            kEraseBrushRadius,
            erasePaint
              ..style = PaintingStyle.fill
              ..strokeWidth = 0,
          );
        } else {
          final path = Path()..moveTo(stroke[0].dx, stroke[0].dy);
          for (int i = 1; i < stroke.length; i++) {
            path.lineTo(stroke[i].dx, stroke[i].dy);
          }
          canvas.drawPath(
            path,
            erasePaint
              ..style = PaintingStyle.stroke
              ..strokeWidth = kEraseBrushRadius * 2,
          );
        }
      }
    }

    canvas.restore(); // saveLayer

    // 恢复翻页裁剪
    if (peelCorner != null) {
      final peelPath = _PeelOnlyClipper._buildPeelRevealPath(
          peelCorner!, size);
      if (peelPath != null) {
        canvas.restore();
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FogTintPainter old) => true;
}

// -------------------------------------------------------- 纸角绘制 ----
// P3: 柔和「翘起纸角」——渐变填充 + 柔和阴影 + 卷曲高光弧线

class _CornerPainter extends CustomPainter {
  _CornerPainter({
    required this.phase,
    required this.dragPoint,
    required this.sheetSize,
    required this.fade,
  });

  final FogPhase phase;
  final Offset dragPoint;
  final Size sheetSize;
  final double fade;

  @override
  void paint(Canvas canvas, Size size) {
    if (phase == FogPhase.cleared) return;

    final isPeeling = phase == FogPhase.peeling ||
        phase == FogPhase.flying ||
        phase == FogPhase.springback;

    if (isPeeling) {
      _paintPeelCurl(canvas, size);
    } else {
      _paintCornerHint(canvas, size);
    }
  }

  /// P3: 静态纸角——渐变填充 + 柔和阴影 + 卷曲高光弧线 + 极细分隔线
  void _paintCornerHint(Canvas canvas, Size size) {
    final br = Offset(size.width, size.height);
    const s = kCornerTriSize;

    // 柔和阴影（MaskFilter.blur 替代 drawShadow 硬边）
    final shadowPath = Path()
      ..moveTo(br.dx, br.dy)
      ..lineTo(br.dx - s * 1.2, br.dy)
      ..lineTo(br.dx, br.dy - s * 1.2)
      ..close();
    canvas.drawPath(
      shadowPath,
      Paint()
        ..color = const Color(0x22000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0),
    );

    // 纸角三角形 —— 渐变填充（从雾色过渡到略亮的纸白）
    final triPath = Path()
      ..moveTo(br.dx, br.dy)
      ..lineTo(br.dx - s, br.dy)
      ..lineTo(br.dx, br.dy - s)
      ..close();

    final triBounds = Rect.fromLTRB(
      br.dx - s, br.dy - s, br.dx, br.dy,
    );
    final triPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          const Color(0xFFFAF6F0), // 亮纸白
          const Color(0xFFF0EBE2), // 雾色
        ],
      ).createShader(triBounds);
    canvas.drawPath(triPath, triPaint);

    // 极细分隔线（0.3px，低透明度）暗示纸页可掀
    final dividerPaint = Paint()
      ..color = const Color(0x28000000)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.3;
    canvas.drawLine(
      Offset(br.dx - s, br.dy),
      Offset(br.dx, br.dy - s),
      dividerPaint,
    );

    // 卷曲高光弧线：沿对角线内侧，微妙弧形暗示纸角翘起
    final highlightPaint = Paint()
      ..color = const Color(0x30FFFFFF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    final arcPath = Path();
    // 从三角形斜边内侧画一条微弧
    const inset = 3.0;
    final p1 = Offset(br.dx - s + inset * 1.5, br.dy - inset);
    final p2 = Offset(br.dx - inset, br.dy - s + inset * 1.5);
    final midArc = Offset(
      (p1.dx + p2.dx) / 2 + inset * 0.5,
      (p1.dy + p2.dy) / 2 + inset * 0.5,
    );
    arcPath.moveTo(p1.dx, p1.dy);
    arcPath.quadraticBezierTo(midArc.dx, midArc.dy, p2.dx, p2.dy);
    canvas.drawPath(arcPath, highlightPaint);
  }

  /// 翻页卷曲效果：折线 + 柔和阴影 + 渐变卷曲纸背面 + 高光
  void _paintPeelCurl(Canvas canvas, Size size) {
    final corner = Offset(size.width, size.height);
    final d = corner - dragPoint;
    final len = d.distance;
    if (len < 2) return;

    final mid = Offset(
      (corner.dx + dragPoint.dx) / 2,
      (corner.dy + dragPoint.dy) / 2,
    );
    final u = Offset(d.dx / len, d.dy / len);
    final v = Offset(-u.dy, u.dx);
    final big = size.width + size.height;

    // 折线柔和阴影（MaskFilter.blur 代替硬阴影）
    final shadowPaint = Paint()
      ..color = Color.fromRGBO(0, 0, 0, 0.12 * fade)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

    final foldLine = Path()
      ..moveTo(mid.dx + v.dx * big, mid.dy + v.dy * big)
      ..lineTo(mid.dx - v.dx * big, mid.dy - v.dy * big);
    canvas.drawPath(foldLine, shadowPaint);

    // 卷曲纸背面（翻过来的部分）——渐变填充表现厚度感
    final curlPath = _buildCurlPath(corner, dragPoint, mid, u, v, big, size);
    if (curlPath != null) {
      canvas.save();
      canvas.clipRect(Offset.zero & size);

      // 渐变填充：从折线处亮 → 向拖动点方向暗
      final curlBounds = curlPath.getBounds();
      final curlPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [
            Color.fromRGBO(250, 246, 240, 0.8 * fade), // 亮纸白
            Color.fromRGBO(235, 228, 218, 0.6 * fade), // 暗雾色
          ],
        ).createShader(curlBounds);
      canvas.drawPath(curlPath, curlPaint);

      // 卷曲高光条（折线处）
      final highlightPaint = Paint()
        ..color = Color.fromRGBO(255, 255, 255, 0.35 * fade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.5);
      canvas.drawPath(foldLine, highlightPaint);

      // 卷曲内侧轻微阴影（增加立体感）
      final innerShadowPaint = Paint()
        ..color = Color.fromRGBO(0, 0, 0, 0.06 * fade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2);
      // 阴影画在折线靠卷曲一侧
      final shadowOffset = -u * 3.0;
      final innerShadowLine = Path()
        ..moveTo(mid.dx + v.dx * big + shadowOffset.dx,
            mid.dy + v.dy * big + shadowOffset.dy)
        ..lineTo(mid.dx - v.dx * big + shadowOffset.dx,
            mid.dy - v.dy * big + shadowOffset.dy);
      canvas.drawPath(innerShadowLine, innerShadowPaint);

      canvas.restore();
    }
  }

  /// 构建卷曲纸背面路径（折线到拖动点之间的带状区域）
  Path? _buildCurlPath(
      Offset corner, Offset drag, Offset mid, Offset u, Offset v,
      double big, Size size) {
    final curlWidth = (corner - drag).distance * 0.3; // 卷曲宽度
    if (curlWidth < 2) return null;

    final a = mid + v * big;
    final b = mid - v * big;
    final c = Offset(mid.dx - u.dx * curlWidth, mid.dy - u.dy * curlWidth);
    final ca = c + v * big;
    final cb = c - v * big;

    return Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy)
      ..lineTo(cb.dx, cb.dy)
      ..lineTo(ca.dx, ca.dy)
      ..close();
  }

  @override
  bool shouldRepaint(covariant _CornerPainter old) =>
      old.phase != phase ||
      old.dragPoint != dragPoint ||
      old.fade != fade;
}

// ------------------------------------------------ 文字高度测量 ----

class _HugTextMeasurer extends SingleChildRenderObjectWidget {
  const _HugTextMeasurer({
    required this.width,
    required this.onHeight,
    required super.child,
  });

  final double width;
  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _HugTextRenderBox(width: width, onHeight: onHeight);

  @override
  void updateRenderObject(
      BuildContext context, covariant _HugTextRenderBox renderObject) {
    renderObject
      ..width = width
      ..onHeight = onHeight;
  }
}

class _HugTextRenderBox extends RenderBox
    with RenderObjectWithChildMixin<RenderBox> {
  _HugTextRenderBox({required this._width, required this.onHeight});

  double _width;
  double _last = -1;
  ValueChanged<double> onHeight;

  set width(double v) {
    if (_width == v) return;
    _width = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.constrain(Size.zero);
      return;
    }
    c.layout(
      BoxConstraints.tightFor(width: _width),
      parentUsesSize: true,
    );
    final h = c.size.height;
    size = constraints.constrain(Size(_width, h));
    if ((h - _last).abs() > 0.5) {
      _last = h;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onHeight(h);
      });
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Offstage — 不绘制
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => false;
}
