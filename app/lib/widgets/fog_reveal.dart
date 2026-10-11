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
import 'dart:math' as math;

import 'package:flutter/services.dart';

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

/// 翻页动画期不透明补偿层：左上略亮 / 右下略暗（保留雾面明暗质感）。
/// 动画期没有 BackdropFilter 真模糊，全靠这层遮盖——必须完全不透明，
/// 否则半透明叠加会透出答案文字（透底 bug）。
const Color kFogAnimCoverLight = Color(0xFFE8E0D4);
const Color kFogAnimCoverDense = Color(0xFFD8CEC0);

/// 擦除笔刷半径（dp）
const double kEraseBrushRadius = 26.0;

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
  Path _erasePath = Path();
  int _strokeRevision = 0;
  int _pointCount = 0;
  Path get erasePath => _erasePath;
  bool isErased(Offset position) => _erasePath.contains(position);
  int get strokeRevision => _strokeRevision;

  void _appendMask(Offset p, [Offset? previous]) {
    _erasePath.addOval(Rect.fromCircle(center: p, radius: kEraseBrushRadius));
    if (previous != null && (p - previous).distance > .01) {
      final delta = p - previous;
      final normal =
          Offset(delta.dy, -delta.dx) / delta.distance * kEraseBrushRadius;
      _erasePath.addPolygon([
        previous + normal,
        p + normal,
        p - normal,
        previous - normal,
      ], true);
    }
    _pointCount++;
    _strokeRevision++;
  }

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
    _erasePath = Path();
    _pointCount = 0;
    _strokeRevision++;
    _dragPoint = Offset.zero;
    _generation++;
    notifyListeners();
  }

  // ---- 擦除 ----

  void beginErase(Offset p) {
    if (_phase == FogPhase.cleared || isPeeling) return;
    _phase = FogPhase.erasing;
    strokes.add([p]);
    _appendMask(p);
    notifyListeners();
  }

  void erase(Offset p) {
    if (_phase != FogPhase.erasing || strokes.isEmpty) return;
    final previous = strokes.last.last;
    // 空间采样，避免手指静止时不断堆积点；所有路径段均为连续圆头笔刷。
    if ((p - previous).distance < 2.5 || _pointCount >= 6000) return;
    strokes.last.add(p);
    _appendMask(p, previous);
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
    if (isCleared) return;
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
  int _seenGeneration = 0;
  bool _motionActive = false;
  bool _flying = false;
  double _fade = 1.0;
  double? _measuredTextHeight;
  Size _sheetSize = Size.zero;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _seenGeneration = widget.controller.generation;
    _anim.addListener(_motionTick);
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant FogPeel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _stopMotion();
      oldWidget.controller.removeListener(_onChanged);
      _seenGeneration = widget.controller.generation;
      _measuredTextHeight = null;
      widget.controller.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _anim.dispose();
    super.dispose();
  }

  void _stopMotion() {
    _motionActive = false;
    _anim.stop();
  }

  void _onChanged() {
    final ctrl = widget.controller;
    if (ctrl.generation != _seenGeneration || ctrl.isCleared) {
      _stopMotion();
      _fade = 1;
      _panDownPoint = null;
      if (ctrl.generation != _seenGeneration) {
        _measuredTextHeight = null;
      }
      _seenGeneration = ctrl.generation;
    }
    if (mounted) setState(() {});
  }

  bool _inCornerZone(Offset p, Size size) =>
      p.dx >= size.width - kCornerHitSize &&
      p.dy >= size.height - kCornerHitSize;

  void _onPanDown(DragDownDetails d) {
    _panDownPoint = d.localPosition;
  }

  void _onPanStart(DragStartDetails d) {
    final ctrl = widget.controller;
    if (ctrl.isCleared) return;
    final size = _sheetSize;
    if (_inCornerZone(_panDownPoint ?? d.localPosition, size)) {
      _stopMotion();
      _fade = 1;
      HapticFeedback.selectionClick();
      ctrl.beginPeel(d.localPosition);
    } else if (!ctrl.isPeeling) {
      ctrl.beginErase(_panDownPoint ?? d.localPosition);
      ctrl.erase(d.localPosition);
    }
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final ctrl = widget.controller;
    final size = _sheetSize;
    if (ctrl.phase == FogPhase.peeling) {
      ctrl.updatePeel(
        Offset(
          d.localPosition.dx.clamp(-size.width, size.width),
          d.localPosition.dy.clamp(-size.height, size.height),
        ),
      );
    } else if (ctrl.phase == FogPhase.erasing) {
      ctrl.erase(d.localPosition);
    }
  }

  void _onPanCancel() {
    _panDownPoint = null;
    final ctrl = widget.controller;
    if (ctrl.phase == FogPhase.erasing) ctrl.endErase();
    if (ctrl.phase == FogPhase.peeling) _startMotion(fly: false);
  }

  void _onPanEnd(DragEndDetails d) {
    _panDownPoint = null;
    final ctrl = widget.controller;
    if (ctrl.phase == FogPhase.erasing) {
      ctrl.endErase();
      return;
    }
    if (ctrl.phase != FogPhase.peeling) return;
    final size = _sheetSize;
    final corner = Offset(size.width, size.height);
    final direction = ctrl.dragPoint - corner;
    final distance = direction.distance;
    final velocity = distance < 1
        ? 0.0
        : (d.velocity.pixelsPerSecond.dx * direction.dx +
                  d.velocity.pixelsPerSecond.dy * direction.dy) /
              distance;
    final fly =
        corner.distance > 0 &&
        distance > 20 &&
        (distance >= corner.distance * kFlyOutThreshold ||
            velocity >= kFlyOutVelocity);
    _startMotion(fly: fly);
  }

  void _onTap() {
    final ctrl = widget.controller;
    if (ctrl.isCleared || ctrl.isPeeling) return;
    final size = _sheetSize;
    ctrl.beginPeel(Offset(size.width, size.height));
    _startMotion(fly: true, fromTap: true);
  }

  void _startMotion({required bool fly, bool fromTap = false}) {
    final ctrl = widget.controller;
    final size = _sheetSize;
    final corner = Offset(size.width, size.height);
    _stopMotion();
    if (MediaQuery.disableAnimationsOf(context) || corner.distance < 1) {
      if (fly) {
        ctrl.markCleared();
      } else {
        ctrl.startSpringBack();
        ctrl.setDragPoint(corner);
        ctrl.endSpringBack();
      }
      return;
    }
    _animFrom = ctrl.dragPoint;
    final direction = _animFrom - corner;
    _animTo = !fly
        ? corner
        : fromTap || direction.distance < 1
        ? Offset(-size.width * .3, -size.height * .3)
        : corner + direction / direction.distance * corner.distance * 1.5;
    _animGeneration = ctrl.generation;
    _flying = fly;
    _fade = 1;
    _anim.duration = Duration(milliseconds: fly ? 280 : 240);
    _anim.value = 0;
    _motionActive = true;
    if (fly) {
      HapticFeedback.lightImpact();
      ctrl.startFlyOut(_animFrom);
    } else {
      ctrl.startSpringBack();
    }
    _anim.forward();
  }

  // 固定注册的单一监听器。取消/换卡不会留下重复监听或过期回调。
  void _motionTick() {
    if (!_motionActive || widget.controller.generation != _animGeneration) {
      return;
    }
    final ctrl = widget.controller;
    final t = (_flying ? Curves.easeOutCubic : Curves.easeOutBack).transform(
      _anim.value,
    );
    _fade = _flying ? 1 - _anim.value : 1;
    ctrl.setDragPoint(Offset.lerp(_animFrom, _animTo, t)!);
    if (_anim.value >= 1) {
      _motionActive = false;
      if (_flying) {
        ctrl.markCleared();
      } else {
        ctrl.setDragPoint(_animTo);
        ctrl.endSpringBack();
      }
      _fade = 1;
    }
  }

  // ---- 构建 ----

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;

    return LayoutBuilder(
      builder: (context, constraints) {
        final avail = Size(
          constraints.maxWidth,
          constraints.maxHeight.isFinite ? constraints.maxHeight : 400,
        );

        Widget answerContent(Size sz) => SizedBox(
          width: sz.width,
          height: sz.height,
          child: ExcludeSemantics(
            excluding: !ctrl.isCleared,
            child: SingleChildScrollView(child: widget.child),
          ),
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
        final sheetH =
            (measured == null
                    ? math.min(kFogSheetMinHeight, avail.height)
                    : measured.clamp(
                        math.min(kFogSheetMinHeight, avail.height),
                        avail.height,
                      ))
                .toDouble();
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
                    if (mounted &&
                        (_measuredTextHeight == null ||
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
                child: _buildFogStack(
                  answerContent(Size(avail.width, sheetH)),
                  Size(avail.width, sheetH),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildFogStack(Widget answerContent, Size avail) {
    // hugText 的手势局部坐标属于小纸片，不能拿外层 Expanded 的尺寸判定纸角。
    _sheetSize = avail;
    final ctrl = widget.controller;
    final isAnimating = ctrl.isPeeling;
    final fadeOpacity = ctrl.phase == FogPhase.flying
        ? _fade.clamp(0.0, 1.0)
        : 1.0;

    // P4: ClipRect 兜底——翻页卷曲不溢出自身边界
    return ClipRect(
      child: SizedBox(
        key: const ValueKey('fog-sheet'),
        width: avail.width,
        height: avail.height,
        child: GestureDetector(
          onPanDown: _onPanDown,
          onPanStart: _onPanStart,
          onPanUpdate: _onPanUpdate,
          onPanEnd: _onPanEnd,
          onPanCancel: _onPanCancel,
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
                        erasePath: ctrl.erasePath,
                        revision: ctrl.strokeRevision,
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
    this.erasePath,
    this.revision = 0,
    required this.sheetSize,
  });

  final Offset? peelCorner;
  final Path? erasePath;
  final int revision;
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

    if (erasePath != null) {
      fogPath = Path.combine(PathOperation.difference, fogPath, erasePath!);
    }
    return fogPath;
  }

  @override
  bool shouldReclip(covariant _PeelOnlyClipper oldClipper) =>
      oldClipper.peelCorner != peelCorner ||
      oldClipper.revision != revision ||
      oldClipper.sheetSize != sheetSize;

  /// 翻页揭开区域：从右下角到拖动点，用折线分割
  static Path? _buildPeelRevealPath(Offset drag, Size size) {
    final corner = Offset(size.width, size.height);
    final mid = Offset((corner.dx + drag.dx) / 2, (corner.dy + drag.dy) / 2);
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
      final peelPath = _PeelOnlyClipper._buildPeelRevealPath(peelCorner!, size);
      if (peelPath != null) {
        final clipPath = Path()..addRect(rect);
        final clipped = Path.combine(
          PathOperation.difference,
          clipPath,
          peelPath,
        );
        canvas.save();
        canvas.clipPath(clipped);
      }
    }

    // saveLayer 以支持 dstOut 擦除
    canvas.saveLayer(rect, Paint());

    if (isAnimating) {
      // 翻页动画期：BackdropFilter 已移除，由这层完全不透明遮罩承担全部遮盖
      // （原补偿层最高约 45% 不透明度，答案文字直接透底）。
      final solidPaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kFogAnimCoverLight, kFogAnimCoverDense],
        ).createShader(rect);
      canvas.drawRect(rect, solidPaint);
    } else {
      // 静态状态：渐变浓雾底色 —— 左上淡，右下浓（BackdropFilter 真模糊负责遮盖）
      final gradientPaint = Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [kFogGradientLight, kFogGradientDense],
        ).createShader(rect);
      canvas.drawRect(rect, gradientPaint);
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
        ..maskFilter = const MaskFilter.blur(
          BlurStyle.normal,
          kEraseDissolveRadius,
        );

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
      final peelPath = _PeelOnlyClipper._buildPeelRevealPath(peelCorner!, size);
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

    final isPeeling =
        phase == FogPhase.peeling ||
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

    final triBounds = Rect.fromLTRB(br.dx - s, br.dy - s, br.dx, br.dy);
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
        ..moveTo(
          mid.dx + v.dx * big + shadowOffset.dx,
          mid.dy + v.dy * big + shadowOffset.dy,
        )
        ..lineTo(
          mid.dx - v.dx * big + shadowOffset.dx,
          mid.dy - v.dy * big + shadowOffset.dy,
        );
      canvas.drawPath(innerShadowLine, innerShadowPaint);

      canvas.restore();
    }
  }

  /// 构建卷曲纸背面路径（折线到拖动点之间的带状区域）
  Path? _buildCurlPath(
    Offset corner,
    Offset drag,
    Offset mid,
    Offset u,
    Offset v,
    double big,
    Size size,
  ) {
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
      old.phase != phase || old.dragPoint != dragPoint || old.fade != fade;
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
    BuildContext context,
    covariant _HugTextRenderBox renderObject,
  ) {
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
    c.layout(BoxConstraints.tightFor(width: _width), parentUsesSize: true);
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
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {}

  @override
  void paint(PaintingContext context, Offset offset) {
    // Offstage — 不绘制，也不把被遮盖的答案读给屏幕阅读器。
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) => false;
}
