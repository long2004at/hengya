// 答案雾（#12 v2：毛玻璃模式）
// =====================================================================
// 复习时答案被磨砂玻璃（BackdropFilter 真模糊）覆盖：
//   · 可以隐约看到下方答案的位置/轮廓，但读不清具体文字；
//   · 手指在雾面上滑动 = "擦玻璃"，沿轨迹擦开一条柔和渐变路径；
//   · 右下角纸角可拖动 → 纸页卷曲掀开，露出下面答案；
//     松手超阈值 → 飞出全清；不足 → 弹性拉回；
//   · 点纸角 = 自动掀页动画；
//   · 换卡 reset() 重新上雾。
// =====================================================================

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

// ---------------------------------------------------------------- 常量 ----

/// 模糊 sigma（越大越模糊，8-12 之间平衡清晰度和遮盖效果）
const double kFogBlurSigma = 10.0;

/// 雾层暖色调叠加（半透明纸白，让模糊区有温暖质感）
const Color kFogTintColor = Color(0x55F5F0E6);

/// 擦除笔刷半径（dp）
const double kEraseBrushRadius = 20.0;

/// 擦除边缘柔和模糊半径
const double kEraseSoftEdge = 6.0;

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

    return SizedBox(
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
            // Layer 0：答案内容（始终渲染，被模糊遮盖）
            Positioned.fill(child: answerContent),

            // Layer 1：毛玻璃模糊层（ClipPath 排除擦除区域和翻页区域）
            Positioned.fill(
              child: Opacity(
                opacity: ctrl.phase == FogPhase.flying ? _fade.clamp(0.0, 1.0) : 1.0,
                child: ClipPath(
                  clipper: _FogClipper(
                    strokes: ctrl.strokes,
                    peelCorner: ctrl.isPeeling ? ctrl.dragPoint : null,
                    sheetSize: avail,
                  ),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(
                      sigmaX: kFogBlurSigma,
                      sigmaY: kFogBlurSigma,
                    ),
                    child: Container(color: kFogTintColor),
                  ),
                ),
              ),
            ),

            // Layer 2：擦除边缘柔和发光（让擦除路径边缘更自然）
            if (ctrl.strokes.isNotEmpty)
              Positioned.fill(
                child: CustomPaint(
                  painter: _SoftEdgePainter(strokes: ctrl.strokes),
                ),
              ),

            // Layer 3：纸角提示 + 翻页卷曲视觉
            if (!ctrl.isCleared)
              Positioned.fill(
                child: CustomPaint(
                  painter: _CornerPainter(
                    phase: ctrl.phase,
                    dragPoint: ctrl.dragPoint,
                    sheetSize: avail,
                    fade: ctrl.phase == FogPhase.flying
                        ? _fade.clamp(0.0, 1.0)
                        : 1.0,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------- 雾区裁剪 ----

class _FogClipper extends CustomClipper<Path> {
  _FogClipper({
    required this.strokes,
    this.peelCorner,
    required this.sheetSize,
  });

  final List<List<Offset>> strokes;
  final Offset? peelCorner;
  final Size sheetSize;

  @override
  Path getClip(Size size) {
    final rect = Offset.zero & size;
    Path fogPath = Path()..addRect(rect);

    // 减去擦除笔画区域
    if (strokes.isNotEmpty) {
      final erasePath = _buildErasePath(strokes);
      fogPath = Path.combine(PathOperation.difference, fogPath, erasePath);
    }

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
  bool shouldReclip(covariant _FogClipper oldClipper) => true;

  /// 构建所有擦除笔画的合并路径
  static Path _buildErasePath(List<List<Offset>> strokes) {
    final path = Path();
    const r = kEraseBrushRadius;
    for (final stroke in strokes) {
      if (stroke.isEmpty) continue;
      if (stroke.length == 1) {
        path.addOval(Rect.fromCircle(center: stroke[0], radius: r));
      } else {
        // 沿笔画路径铺胶囊（圆角粗线）
        for (int i = 0; i < stroke.length; i++) {
          path.addOval(Rect.fromCircle(center: stroke[i], radius: r));
        }
        // 连接相邻点为矩形填充间隙
        for (int i = 0; i < stroke.length - 1; i++) {
          final a = stroke[i];
          final b = stroke[i + 1];
          final d = b - a;
          final len = d.distance;
          if (len < 1) continue;
          final perp = Offset(-d.dy / len, d.dx / len) * r;
          path.moveTo(a.dx + perp.dx, a.dy + perp.dy);
          path.lineTo(b.dx + perp.dx, b.dy + perp.dy);
          path.lineTo(b.dx - perp.dx, b.dy - perp.dy);
          path.lineTo(a.dx - perp.dx, a.dy - perp.dy);
          path.close();
        }
      }
    }
    return path;
  }

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
    final u = Offset(d.dx / len, d.dy / len); // corner → drag 方向
    final v = Offset(-u.dy, u.dx); // 垂直方向

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

// ------------------------------------------------------ 擦除柔和边缘 ----

class _SoftEdgePainter extends CustomPainter {
  _SoftEdgePainter({required this.strokes});

  final List<List<Offset>> strokes;

  @override
  void paint(Canvas canvas, Size size) {
    if (strokes.isEmpty) return;

    // 在擦除路径边缘画一圈柔和的半透明光晕
    final glowPaint = Paint()
      ..color = const Color(0x18F5F0E6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = kEraseSoftEdge * 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, kEraseSoftEdge);

    for (final stroke in strokes) {
      if (stroke.length < 2) continue;
      final path = Path()..moveTo(stroke[0].dx, stroke[0].dy);
      for (int i = 1; i < stroke.length; i++) {
        path.lineTo(stroke[i].dx, stroke[i].dy);
      }
      canvas.drawPath(path, glowPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SoftEdgePainter old) => true;
}

// -------------------------------------------------------- 纸角绘制 ----

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

  /// 静态纸角提示：右下角小三角 + 阴影
  void _paintCornerHint(Canvas canvas, Size size) {
    final br = Offset(size.width, size.height);
    const s = kCornerTriSize;

    // 阴影
    final shadowPath = Path()
      ..moveTo(br.dx, br.dy)
      ..lineTo(br.dx - s * 1.1, br.dy)
      ..lineTo(br.dx, br.dy - s * 1.1)
      ..close();
    canvas.drawShadow(shadowPath, Colors.black54, 3.0, false);

    // 纸角三角形（翻起的一角）
    final triPath = Path()
      ..moveTo(br.dx, br.dy)
      ..lineTo(br.dx - s, br.dy)
      ..lineTo(br.dx, br.dy - s)
      ..close();
    canvas.drawPath(
      triPath,
      Paint()..color = Color.lerp(const Color(0xFFF5F0E6), Colors.white, 0.3)!,
    );

    // 纸角边线
    canvas.drawPath(
      triPath,
      Paint()
        ..color = const Color(0x33000000)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.5,
    );
  }

  /// 翻页卷曲效果：折线 + 阴影 + 卷曲纸背面
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

    // 折线阴影
    final shadowPaint = Paint()
      ..color = Color.fromRGBO(0, 0, 0, 0.15 * fade)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

    final foldLine = Path()
      ..moveTo(mid.dx + v.dx * big, mid.dy + v.dy * big)
      ..lineTo(mid.dx - v.dx * big, mid.dy - v.dy * big);
    canvas.drawPath(foldLine, shadowPaint);

    // 卷曲纸背面（翻过来的部分，用镜像路径 + 渐变色表现厚度感）
    final curlPath = _buildCurlPath(corner, dragPoint, mid, u, v, big, size);
    if (curlPath != null) {
      // 裁剪到 sheet 范围
      canvas.save();
      canvas.clipRect(Offset.zero & size);

      final curlPaint = Paint()
        ..color = Color.fromRGBO(245, 240, 230, 0.7 * fade)
        ..style = PaintingStyle.fill;
      canvas.drawPath(curlPath, curlPaint);

      // 卷曲高光条
      final highlightPaint = Paint()
        ..color = Color.fromRGBO(255, 255, 255, 0.4 * fade)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawPath(foldLine, highlightPaint);

      canvas.restore();
    }
  }

  /// 构建卷曲纸背面路径（折线到拖动点之间的带状区域）
  Path? _buildCurlPath(
      Offset corner, Offset drag, Offset mid, Offset u, Offset v,
      double big, Size size) {
    final curlWidth = (corner - drag).distance * 0.3; // 卷曲宽度
    if (curlWidth < 2) return null;

    // 从折线向拖动点方向偏移一个卷曲宽度的带状区域
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
