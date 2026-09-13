// 答案雾（#12 雾气模式 M1，2026-09-13 拍板）：复习翻面后答案被「一页纸白
// 暖雾」覆盖——雾层本身就是一页纸，支持电子书式真卷曲翻页：
//   · 按住右下角纸角拖动 → 整页雾纸卷曲掀开（圆柱卷曲近似：折线镜像 +
//     分段明暗），拖到哪露到哪；松手超阈值（40% 对角线或甩动速度）→
//     纸页飞出全清（解锁滚动）；不足 → 弹性拉回重新盖住；
//   · 点纸角（未拖动）= 自动掀页动画（纸角抬起、卷曲沿对角线行进）；
//   · 纸角以外的拖动 = 擦雾（圆头笔刷 24dp，擦过不复原）；
//   · 雾未清时宿主内容不可滚动（滚动解锁只绑「雾已清」，见 review_page）；
//   · 换卡 reset() 重新上雾。
// 质感（用户拍板）：恒定纸白暖色（#F8F3E9 基底 + 纸浆黄噪点颗粒 + 轻微
// 暗角），卷曲背面用深一档纸色；深浅色模式相同（像真的纸片盖在屏上）。
// 不用 BackdropFilter 真模糊、不用 ui.Image 掩码——擦除笔画在 saveLayer 内
// 以 BlendMode.clear 抠穿；卷曲区按折线镜像 + 渐变阴影绘制（无网格变形）。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;

/// 纸白暖雾配色（深浅色模式恒定——像真的纸片）。
const Color kFogBase = Color(0xFFF8F3E9); // 纸白基底（一丝暖）
const Color kFogGrain = Color(0xFFEFE7D2); // 纸浆黄噪点
const Color kFogGrainDeep = Color(0xFFE9DFC6); // 深一档颗粒
const Color kFogBack = Color(0xFFF1EAD9); // 卷曲背面纸色（深一档）
const double kFogBrushRadius = 24; // 擦除笔刷半径（dp）
const double kFogCornerHotzone = 96; // 纸角拖拽热区半径（dp）
const double kFogPeelThresholdRatio = 0.4; // 掀走阈值：对角线比例
const double kFogFlingVelocity = 900; // 掀走阈值：松手速度（px/s）
const double kFogSheetMinHeight = 120; // 贴文字模式：纸片最小高度（保纸角可操作）

/// 纸片大小模式（用户拍板做成设置项双模式）：
/// fill = 盖满答案区剩余空间（恒定大纸，答案再短纸也不变小）；
/// hugText = 贴答案文字（纸高 = 文字实际高度，clamp 到 [120dp, 可用高度]）。
enum FogSheetMode { fill, hugText }

/// 雾状态机：idle（全盖，可擦可拖角）→ peeling（拖角中）→ flying（飞出）
/// / springback（回弹）→ idle；cleared 独立布尔（评分路径瞬时置位）。
enum FogPhase { idle, peeling, flying, springback, autopeel }

class FogPeelController extends ChangeNotifier {
  final List<List<Offset>> strokes = [];

  FogPhase _phase = FogPhase.idle;
  Offset _dragPoint = Offset.zero; // 纸角当前位置（局部坐标；idle 时 = 角点）
  bool _cleared = false;
  int _generation = 0; // 代数：reset 使运行中的动画 tick 失效（防串卡）

  int get generation => _generation;

  FogPhase get phase => _phase;
  Offset get dragPoint => _dragPoint;
  bool get isCleared => _cleared;
  bool get isFogged => !_cleared;

  bool get isPeeling =>
      _phase == FogPhase.peeling ||
      _phase == FogPhase.flying ||
      _phase == FogPhase.autopeel;

  /// 当前纸片高度（hugText 模式由 widget 测量后回填；fill = 可用高度）。
  /// 测试/调试用。
  double? sheetHeight;

  /// 擦雾（纸角以外的拖动）：追加笔画点。
  void beginStroke(Offset p) {
    if (_cleared || isPeeling) return;
    strokes.add([p]);
    notifyListeners();
  }

  void erase(Offset p) {
    if (_cleared || isPeeling || strokes.isEmpty) return;
    strokes.last.add(p);
    notifyListeners();
  }

  /// 开始拖纸角。
  void beginPeel(Offset p) {
    if (_cleared) return;
    _phase = FogPhase.peeling;
    _dragPoint = p;
    notifyListeners();
  }

  /// 拖动中更新纸角位置。
  void updatePeel(Offset p) {
    if (_phase != FogPhase.peeling) return;
    _dragPoint = p;
    notifyListeners();
  }

  /// 飞出（过阈值）：纸角沿拖动方向继续滑出 + 淡出（widget 驱动动画）。
  void startFlyOut(Offset to) {
    _phase = FogPhase.flying;
    _dragPoint = to;
    notifyListeners();
  }

  /// 回弹（未过阈值）：纸角飞回原位（widget 驱动动画）。
  void startSpringBack() {
    _phase = FogPhase.springback;
    notifyListeners();
  }

  /// 自动掀页（点纸角）：widget 驱动动画，纸角沿对角线行进直至整页掀走。
  void startAutoPeel(Offset from) {
    if (_cleared) return;
    _phase = FogPhase.autopeel;
    _dragPoint = from;
    notifyListeners();
  }

  /// 动画/评分路径更新纸角位置（不校验 phase——动画驱动专用）。
  void setDragPoint(Offset p) {
    _dragPoint = p;
    notifyListeners();
  }

  void setPhase(FogPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  /// 标记全清（动画完成/评分路径）：雾层移除、宿主解锁滚动。
  void markCleared() {
    if (_cleared) return;
    _cleared = true;
    strokes.clear();
    notifyListeners();
  }

  /// 重新上雾（换卡）：全部状态归零。代数 +1 使运行中的动画 tick
  /// （飞出/自动掀页/回弹）失效——否则旧卡的动画完成时会把新卡误清。
  void reset() {
    strokes.clear();
    _phase = FogPhase.idle;
    _dragPoint = Offset.zero;
    _cleared = false;
    _generation++;
    notifyListeners();
  }
}

/// 雾覆盖组件：child 正常渲染在底层，雾层（一页纸）盖在上面。
/// isCleared → 只渲染 child（雾层与手势整体移除，宿主解锁滚动）。
class FogPeel extends StatefulWidget {
  const FogPeel({
    super.key,
    required this.controller,
    required this.child,
    this.sheetMode = FogSheetMode.fill,
  });

  final FogPeelController controller;
  final Widget child;

  /// 纸片大小模式（fill=盖满区域 / hugText=贴答案文字）。
  final FogSheetMode sheetMode;

  @override
  State<FogPeel> createState() => _FogPeelState();
}

class _FogPeelState extends State<FogPeel>
    with SingleTickerProviderStateMixin {
  // initState 显式创建（late 懒初始化会在 teardown 期首次访问——
  // TickerMode 查询崩溃）
  late final AnimationController _anim;
  Offset _animFrom = Offset.zero;
  Offset _animTo = Offset.zero;
  Offset? _panDownPoint; // 本轮拖动的按下点（手势分流用）
  int _animGeneration = -1; // 当前动画绑定的控制器代数（reset 后 tick 自杀）
  double _fade = 1.0;
  double? _measuredTextHeight; // hugText：答案文字实际高度（Offstage 副本测量）

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
    _anim.dispose();
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Offset _corner(Size size) => Offset(size.width, size.height);

  /// 点纸角 → 自动掀页：纸角沿对角线行进直至越过远端 + 淡出 → 全清。
  void _autoPeel(Size size) {
    if (_anim.isAnimating) return; // 动画中忽略新手势（防双写拖点）
    final c = _corner(size);
    final gen = widget.controller.generation;
    final diag = math.sqrt(size.width * size.width + size.height * size.height);
    final u = Offset(-size.width, -size.height) / diag; // 指向左上
    _animFrom = c;
    _animTo = c + u * (diag * 1.15);
    _fade = 1.0;
    widget.controller.startAutoPeel(c);
    _animGeneration = gen;
    _anim
      ..duration = const Duration(milliseconds: 520)
      ..reset();
    _anim.addListener(_autoPeelTick);
    _anim.forward();
  }

  void _autoPeelTick() {
    if (widget.controller.generation != _animGeneration) return;
    final t = _anim.value;
    final p = Offset.lerp(_animFrom, _animTo, t)!;
    final diag = _animTo.distance;
    // 越过远端后整体淡出（纸背盖满 → 纸飞走）
    _fade = t < 0.75 ? 1.0 : (1.0 - (t - 0.75) / 0.25).clamp(0.0, 1.0);
    widget.controller.setDragPoint(p);
    if (t >= 0.75 && widget.controller.phase != FogPhase.flying) {
      widget.controller.setPhase(FogPhase.flying);
    }
    if (t >= 1.0 || (diag > 0 && (p - _animTo).distance < 1)) {
      _anim.removeListener(_autoPeelTick);
      widget.controller.markCleared();
      setState(() => _fade = 1.0);
    }
  }

  /// 拖角松手：超阈值（距离/速度）→ 飞出全清；否则弹性拉回。
  void _endPeel(Size size, double flingSpeed) {
    final gen = widget.controller.generation;
    final c = _corner(size);
    final diag = math.sqrt(size.width * size.width + size.height * size.height);
    final dragDist = (widget.controller.dragPoint - c).distance;
    if (dragDist >= diag * kFogPeelThresholdRatio ||
        flingSpeed >= kFogFlingVelocity) {
      final u = dragDist > 0
          ? (widget.controller.dragPoint - c) / dragDist
          : const Offset(-1, -1);
      _animFrom = widget.controller.dragPoint;
      _animTo = c + u * (diag * 1.2);
      _fade = 1.0;
      widget.controller.startFlyOut(_animFrom);
      _animGeneration = gen;
      _anim
        ..duration = const Duration(milliseconds: 260)
        ..reset();
      _anim.addListener(_flyOutTick);
      _anim.forward();
    } else {
      _animFrom = widget.controller.dragPoint;
      _animTo = c;
      widget.controller.startSpringBack();
      _animGeneration = gen;
      _anim
        ..duration = const Duration(milliseconds: 240)
        ..reset();
      _anim.addListener(_springBackTick);
      _anim.forward();
    }
  }

  void _flyOutTick() {
    if (widget.controller.generation != _animGeneration) return;
    final t = _anim.value;
    widget.controller.setDragPoint(Offset.lerp(_animFrom, _animTo, t)!);
    _fade = 1.0 - t;
    if (t >= 1.0) {
      _anim.removeListener(_flyOutTick);
      widget.controller.markCleared();
      setState(() => _fade = 1.0);
    }
  }

  void _springBackTick() {
    if (widget.controller.generation != _animGeneration) return;
    final t = Curves.easeOutBack.transform(_anim.value);
    widget.controller.setDragPoint(Offset.lerp(_animFrom, _animTo, t)!);
    if (_anim.value >= 1.0) {
      _anim.removeListener(_springBackTick);
      widget.controller.setPhase(FogPhase.idle);
    }
  }

  @override
  Widget build(BuildContext context) {
    // 全清 → 完整答案可滚动阅读（两模式同态）
    if (widget.controller.isCleared) {
      return Align(
        alignment: Alignment.topLeft,
        child: SingleChildScrollView(child: widget.child),
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      // 高度无界（滚动容器内）→ 雾不可用，直接渲染 child（无界约束传给
      // 文本会炸 RenderParagraph）
      if (!constraints.maxHeight.isFinite || !constraints.maxWidth.isFinite) {
        return widget.child;
      }
      final avail = Size(constraints.maxWidth, constraints.maxHeight);
      final fade = _fade.clamp(0.0, 1.0);

      // 雾层（两模式同一套手势/绘制，只是覆盖区域不同）
      Widget fogLayer(Size sheetSize) => Positioned.fromRect(
            rect: Offset.zero & sheetSize,
            child: Opacity(
              opacity: fade,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                // onPanDown 即时记录起点（onPanStart 的 localPosition 是
                // 识别器胜出时的位置——大幅拖动已远离纸角，热区判定失真）
                onPanDown: (d) => _panDownPoint = d.localPosition,
                onPanStart: (d) {
                  if (_anim.isAnimating) return; // 动画中不接新手势
                  final origin = _panDownPoint ?? d.localPosition;
                  if (_inCornerHotzone(origin, sheetSize)) {
                    widget.controller.beginPeel(origin);
                  } else {
                    widget.controller.beginStroke(origin);
                  }
                },
                onPanUpdate: (d) {
                  if (widget.controller.isPeeling) {
                    widget.controller.updatePeel(d.localPosition);
                  } else if (widget.controller.phase == FogPhase.idle) {
                    widget.controller.erase(d.localPosition);
                  }
                },
                onPanEnd: (d) {
                  if (widget.controller.phase == FogPhase.peeling) {
                    _endPeel(sheetSize, d.velocity.pixelsPerSecond.distance);
                  }
                },
                onTapUp: (d) {
                  // 纸角热区内点击（未拖动）= 自动掀页
                  if (_inCornerHotzone(
                      _panDownPoint ?? d.localPosition, sheetSize)) {
                    _autoPeel(sheetSize);
                  }
                },
                child: CustomPaint(
                  painter: _FogPainter(
                    controller: widget.controller,
                    corner: _corner(sheetSize),
                  ),
                ),
              ),
            ),
          );

      // 答案内容（雾激活期间不可滚——锁定在纸片可视范围内，ClipRect 裁掉
      // 超出部分；掀页/评分后由 cleared 滚动视图接管）
      Widget content(Size sheetSize) => Positioned.fromRect(
            rect: Offset.zero & sheetSize,
            child: ClipRect(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: widget.child,
              ),
            ),
          );

      if (widget.sheetMode == FogSheetMode.fill) {
        // 盖满区域：纸 = 整个答案区剩余空间（恒定大纸）
        widget.controller.sheetHeight = avail.height;
        return Stack(children: [content(avail), fogLayer(avail)]);
      }

      // 贴答案文字：纸高 = clamp(文字实际高度, 120dp, 可用高度)；
      // 文字高度用 Offstage 副本测量（首帧用下限起步，测后更新）
      final measured = _measuredTextHeight;
      final sheetH = measured == null
          ? kFogSheetMinHeight
          : measured.clamp(kFogSheetMinHeight, avail.height).toDouble();
      widget.controller.sheetHeight = sheetH;
      return Stack(
        children: [
          content(Size(avail.width, sheetH)),
          fogLayer(Size(avail.width, sheetH)),
          // 测量副本：布局但不绘制（Offstage），约束 = 同宽 + 高度无界
          Positioned(
            left: 0,
            top: 0,
            width: avail.width,
            child: Offstage(
              child: _MeasureTextHeight(
                onHeight: (h) {
                  if (mounted && _measuredTextHeight != h) {
                    setState(() => _measuredTextHeight = h);
                  }
                },
                child: widget.child,
              ),
            ),
          ),
        ],
      );
    });
  }

  bool _inCornerHotzone(Offset p, Size size) {
    final c = _corner(size);
    return (p - c).distance <= kFogCornerHotzone;
  }
}

class _FogPainter extends CustomPainter {
  _FogPainter({required this.controller, required this.corner})
    : super(repaint: controller);

  final FogPeelController controller;
  final Offset corner;

  // 种子化噪点：固定种子保证重绘颗粒布局一致（不闪烁）。
  static final List<(double, double, double)> _grain = () {
    final rng = math.Random(20260913);
    return List.generate(200, (_) {
      final tone = rng.nextDouble();
      return (
        rng.nextDouble(), // x 比例
        rng.nextDouble(), // y 比例
        tone < 0.55 ? 0.5 : 1.0, // 明暗两档
      );
    });
  }();

  static void _paintPaper(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = kFogBase);
    for (final (gx, gy, tone) in _grain) {
      canvas.drawCircle(
        Offset(gx * size.width, gy * size.height),
        1.4 + tone,
        Paint()
          ..color = tone == 1.0
              ? kFogGrainDeep.withValues(alpha: 0.5)
              : kFogGrain.withValues(alpha: 0.6),
      );
    }
    final vignette = Paint()
      ..shader = ui.Gradient.radial(
        size.center(Offset.zero),
        size.longestSide * 0.75,
        [const Color(0x00000000), const Color(0x14000000)],
      );
    canvas.drawRect(Offset.zero & size, vignette);
  }

  void _paintStrokes(Canvas canvas) {
    final eraser = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = kFogBrushRadius * 2;
    for (final stroke in controller.strokes) {
      if (stroke.isEmpty) continue;
      if (stroke.length == 1) {
        canvas.drawCircle(
          stroke.single,
          kFogBrushRadius,
          Paint()..blendMode = BlendMode.clear,
        );
        continue;
      }
      final path = Path()..moveTo(stroke.first.dx, stroke.first.dy);
      for (final p in stroke.skip(1)) {
        path.lineTo(p.dx, p.dy);
      }
      canvas.drawPath(path, eraser);
    }
  }

  /// 半平面裁剪路径：{dot(X-M, u) 与 side 同号}（BIG 尺寸四边形）。
  static Path _halfPlane(Offset m, Offset u, double side, double big) {
    final v = Offset(-u.dy, u.dx);
    return Path()
      ..moveTo(m.dx + v.dx * big + u.dx * side * big,
          m.dy + v.dy * big + u.dy * side * big)
      ..lineTo(m.dx - v.dx * big + u.dx * side * big,
          m.dy - v.dy * big + u.dy * side * big)
      ..lineTo(m.dx - v.dx * big - u.dx * side * big,
          m.dy - v.dy * big - u.dy * side * big)
      ..lineTo(m.dx + v.dx * big - u.dx * side * big,
          m.dy + v.dy * big - u.dy * side * big)
      ..close();
  }

  /// 折线镜像变换（绕过 M、方向 v 的直线反射：v 不变、u 取反）。
  static Matrix4 _mirrorAcross(Offset m, Offset u) {
    final v = Offset(-u.dy, u.dx);
    final l11 = v.dx * v.dx - u.dx * u.dx;
    final l12 = v.dx * v.dy - u.dx * u.dy;
    final l22 = v.dy * v.dy - u.dy * u.dy;
    return Matrix4(
      l11, l12, 0, m.dx - (l11 * m.dx + l12 * m.dy),
      l12, l22, 0, m.dy - (l12 * m.dx + l22 * m.dy),
      0, 0, 1, 0,
      0, 0, 0, 1,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final p = controller.dragPoint;
    final d = (p - corner).distance;
    final bounds = Offset.zero & size;
    final big = size.longestSide * 3;

    // —— idle（纸角未拖起）：整页雾 + 纸角提示 ——
    if (controller.phase == FogPhase.idle || d < 4) {
      canvas.saveLayer(bounds, Paint());
      _paintPaper(canvas, size);
      _paintStrokes(canvas);
      canvas.restore();
      // 纸角提示：右下角小三角（微翘起的可抓提示）
      final hint = Path()
        ..moveTo(size.width - 28, size.height)
        ..lineTo(size.width, size.height - 28)
        ..lineTo(size.width, size.height)
        ..close();
      canvas.drawShadow(hint, const Color(0xFF8A7A55), 3, false);
      canvas.drawPath(hint, Paint()..color = kFogGrain.withValues(alpha: 0.9));
      return;
    }

    // —— 卷曲（peeling/flying/autopeel/springback）——
    final u = (p - corner) / d;
    final m = corner + u * (d / 2); // 折线：CP 的垂直平分线

    // ① 未掀起侧：{dot(X-M,u) ≥ 0}（靠远端一侧）——雾纸原样 + 折线接触阴影
    canvas.save();
    canvas.clipPath(_halfPlane(m, u, 1, big));
    canvas.saveLayer(bounds, Paint());
    _paintPaper(canvas, size);
    _paintStrokes(canvas);
    canvas.restore();
    final foldShadow = Paint()
      ..shader = ui.Gradient.linear(
        m,
        m + u * 36,
        [const Color(0x33000000), const Color(0x00000000)],
      );
    canvas.drawRect(bounds, foldShadow);
    canvas.restore();

    // ② 掀起侧：折线镜像绘制「纸背」（深一档 + 曲面明暗：折线处最暗）。
    // 用户拍板（2026-09-13）：手动擦出的空洞是「纸上的洞」，随纸卷走——
    // 镜像空间内同样渲染擦除笔画（clear 抠穿 → 洞的位置露出底下的答案）
    canvas.save();
    canvas.transform(_mirrorAcross(m, u).storage);
    canvas.clipPath(_halfPlane(m, u, 1, big)); // 镜像后即掀起区
    canvas.saveLayer(bounds, Paint());
    canvas.drawRect(bounds, Paint()..color = kFogBack);
    for (final (gx, gy, tone) in _grain) {
      canvas.drawCircle(
        Offset(gx * size.width, gy * size.height),
        1.4 + tone,
        Paint()
          ..color = tone == 1.0
              ? kFogGrainDeep.withValues(alpha: 0.45)
              : kFogGrain.withValues(alpha: 0.5),
      );
    }
    final curlShade = Paint()
      ..shader = ui.Gradient.linear(
        m,
        m - u * 56,
        [const Color(0x2E000000), const Color(0x00000000)],
      );
    canvas.drawRect(bounds, curlShade);
    _paintStrokes(canvas); // 空洞随纸卷走（镜像位置即物理位置）
    canvas.restore();
    canvas.restore();

    // ③ 折线高光（细亮线：卷曲棱）
    canvas.drawLine(
      m - vOf(u) * big,
      m + vOf(u) * big,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.55)
        ..strokeWidth = 1.2,
    );
  }

  static Offset vOf(Offset u) => Offset(-u.dy, u.dx);

  @override
  bool shouldRepaint(_FogPainter oldDelegate) => false; // repaint 挂 controller
}


/// hugText 模式的文字高度测量：子项按「同宽 + 固有高度」布局，高度经
/// postFrame 回调上报（layout 期间不可 setState）。Offstage 承载（布局
/// 但不绘制）。
class _MeasureTextHeight extends SingleChildRenderObjectWidget {
  const _MeasureTextHeight({required this.onHeight, required super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMeasureTextHeight(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasureTextHeight renderObject,
  ) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderMeasureTextHeight extends RenderProxyBox {
  _RenderMeasureTextHeight(this.onHeight);

  ValueChanged<double> onHeight;
  double _last = -1;

  @override
  void performLayout() {
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    final h = child!.getMaxIntrinsicHeight(constraints.maxWidth);
    final safe = h.isFinite && h > 0 ? h : 0.0;
    child!.layout(
      BoxConstraints.tightFor(width: constraints.maxWidth, height: safe),
      parentUsesSize: true,
    );
    size = constraints.constrain(Size(constraints.maxWidth, safe));
    if ((safe - _last).abs() > 0.5) {
      _last = safe;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        onHeight(safe);
      });
    }
  }
}
