// 顶部气泡 Toast —— 全局轻提示（纯 Flutter：Overlay + AnimationController，无第三方依赖）
//
// 行为（2026-09-06 真机截图拍板 v3；2026-09-07 v3.1 真机反馈修正 #11）：
//  · 出现在屏幕上方安全区下方；语义图标（对勾/i/警示）+ 语义色保留
//  · 底色氛围：每次展示从色池随机取一组浅色渐变（浅底深字；「随机氛围」保留）；
//    v3.1（#11）：真机反馈原色池对比过弱（浅色页面上几乎看不出底色）——
//    每组起/终色各加深一档，保持浅底深字不刺眼
//  · 边缘可感知度（#11，v3.1）：真机反馈「无描边 + blur36 大弥散柔影」边缘
//    淡化到看不出来——改为 1px 半透明描边 + 双层影（近实远虚：近层小半径
//    勾出边界、远层保留少量弥散氛围）。旧版白色描边贴字误读为下划线的
//    根因（半透明期背景元素透出）不复发：描边为深色半透明，与文字拉开
//  · 展示时长（#5）：次要状态默认 ~2.2s；重要状态（触发/上传完成等）经
//    [kToastStayImportant] ~3s（2026-09-07 用户反馈 2.2s 偏快）
//  · 消失效果：随时间整体逐渐变淡——进入(240ms) → 满透明停留(40%) →
//    连续渐淡至零(60%，easeInOut)。「消失」即渐淡本身，无末尾突变跳灭
//  · 新替旧：后到的 Toast 立即替换在先的 Toast，绝不堆叠
//
// 工程纪律对齐：
//  · 无 Timer.periodic / while(true) / 常驻流；仅「系统关动效」路径用一次性
//    Timer，组件 dispose 时 cancel
//  · AnimationController 随组件 dispose 释放
//  · OverlayEntry 在动画结束时 remove；新 Toast 到达时旧条目立即 remove；
//    宿主 Overlay 销毁（如测试结束）导致视图卸载时只清静态引用、不碰死 overlay
//  · MediaQuery.disableAnimations == true 时静态显示，照常按时移除（不做动画）

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Toast 语义类型（决定气泡内的图标与图标色）
enum TopToastType {
  /// 成功确认（绿色对勾）
  success,

  /// 中性信息（品牌蓝 i）
  info,

  /// 校验/失败（警示红）
  error,
}

/// 次要状态默认展示总时长（2026-09-06 拍板口径：来得及读完、不拖沓）。
const Duration kToastStayDefault = Duration(milliseconds: 2200);

/// 重要状态展示总时长（#5，2026-09-07）：「已触发 / 上传完成 / 建库完成 /
/// 导入成功」等一次性关键结果——用户反馈 2200ms 消失偏快（满透明窗仅
/// ~880ms），拉长到 ~3s；次要提示保持 [kToastStayDefault]。
const Duration kToastStayImportant = Duration(milliseconds: 3000);

/// 顶部气泡 Toast 入口。
///
/// 用法：`TopToast.show(context, '已拒绝', type: TopToastType.info);`
///
/// [context] 任意位于 MaterialApp 之下的 BuildContext（页面/弹窗/底部弹层均可，
/// 内部固定挂到 rootOverlay，保证浮于所有路由与弹窗之上）；
/// [stayDuration] 为展示总时长（进入动画 240ms 另计；其中后 60% 为连续渐淡），
/// 最短 600ms。
class TopToast {
  const TopToast._();

  /// 当前展示中的条目（新替旧：后到覆盖先到，不堆叠）
  static OverlayEntry? _current;

  /// 底色氛围池：每组浅→更浅的同族色渐变（深字浅底；「随机氛围」保留——
  /// 2026-09-06 拍板：深色渐变+白字被反馈「太深/淡化不明显」，改浅色系；
  /// 2026-09-07 v3.1（#11）：真机反馈对比过弱——起/终色各加深一档）。
  /// 每次展示随机取一组。
  /// 视觉参数待真机复查微调。
  static const List<List<Color>> _ambients = [
    [Color(0xFFD6E4FD), Color(0xFFEDF4FF)], // 品牌蓝
    [Color(0xFFD3F0E2), Color(0xFFEEFAF5)], // 青绿
    [Color(0xFFE2DBF8), Color(0xFFF5F2FE)], // 紫罗兰
    [Color(0xFFDAE4F5), Color(0xFFF0F5FC)], // 靛蓝
    [Color(0xFFF8E4CB), Color(0xFFFCF4E9)], // 暖橙
    [Color(0xFFF6DAE0), Color(0xFFFCF0F2)], // 绯红
  ];

  /// 展示一条顶部气泡提示（旧条目若在展示中会被立即替换）
  ///
  /// 容错（2026-09-06 真机白屏 P0 防御）：toast 是非关键路径——本方法全程
  /// 吞异常静默降级（debugPrint 一行），绝不向调用方/渲染管线冒泡。
  /// 复现实锤（test/tool_white_screen_repro_test.dart 复现①②③）：
  ///   · 弹窗等宿主 pop 卸载后，带着其 defunct context 调进来，
  ///     Overlay.maybeOf 会抛「Looking up a deactivated widget's ancestor
  ///     is unsafe」（复现③）；
  ///   · 更隐蔽的：entry builder 闭包若捕获调用方 context 并在重建时求值
  ///     MediaQuery.of（旧版 animationsEnabled 写法），宿主卸载后的任何一帧
  ///     overlay 重建都会打到死 element 上 → build 帧「Null check operator
  ///     used on a null value」→ 渲染管线反复失败 = 真机白屏卡死（复现①②）。
  /// 因此 animationsEnabled 必须在本方法同步段求值完毕，闭包里只留纯值。
  static void show(
    BuildContext context,
    String message, {
    TopToastType type = TopToastType.info,
    Duration stayDuration = kToastStayDefault,
  }) {
    final bool animationsEnabled;
    try {
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay == null) {
        debugPrint('[TopToast] show 降级：无 root overlay 可挂载');
        return;
      }
      // 同步段求值（此刻 context 由按钮回调带入、必然活跃）；绝不延迟到
      // entry builder 闭包——entry 生命周期长于任何调用方页面/弹窗。
      animationsEnabled = !MediaQuery.of(context).disableAnimations;

      _removeCurrent(); // 新替旧：先到的立即让位
      final ambient = _ambients[Random().nextInt(_ambients.length)]; // 底色随机氛围
      // late final：两个回调闭包要引用 entry 自身（identity 比对），先声明后赋值
      late final OverlayEntry entry;
      entry = OverlayEntry(
        builder: (_) => Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: _TopToastView(
            message: message,
            type: type,
            stayDuration: stayDuration,
            background: ambient,
            animationsEnabled: animationsEnabled,
            // 展示结束（动画走完 / 关动效计时到点）→ 移除条目
            onFinished: () {
              if (identical(_current, entry)) {
                _current = null;
                entry.remove();
              }
            },
            // 视图卸载（条目已被移除，或宿主 Overlay 已销毁）→ 只清静态引用，
            // 不再调用 remove（宿主若已销毁，remove 会打到死 overlay 上）
            onDismissed: () {
              if (identical(_current, entry)) {
                _current = null;
              }
            },
          ),
        ),
      );
      // 插入一致性守卫：insert 失败（宿主 overlay 已销毁等）时 _current 不落
      // 脏值——未插入的 entry 若被记录，下一次 _removeCurrent 会 remove 一个
      // 从未挂载的条目（OverlayEntry.remove 对未插入条目是断言级错误）。
      overlay.insert(entry);
      _current = entry;
    } catch (e) {
      debugPrint('[TopToast] show 容错降级（非关键路径，不冒泡）: $e');
    }
  }

  static void _removeCurrent() {
    final entry = _current;
    if (entry == null) {
      return;
    }
    _current = null;
    entry.remove();
  }
}

/// 气泡视图（持有 AnimationController；生命周期即 OverlayEntry 的挂载周期）
class _TopToastView extends StatefulWidget {
  const _TopToastView({
    required this.message,
    required this.type,
    required this.stayDuration,
    required this.background,
    required this.animationsEnabled,
    required this.onFinished,
    required this.onDismissed,
  });

  final String message;
  final TopToastType type;
  final Duration stayDuration;
  final List<Color> background; // 本次底色氛围（show 时从 _ambients 随机取）
  final bool animationsEnabled;
  final VoidCallback onFinished;
  final VoidCallback onDismissed;

  @override
  State<_TopToastView> createState() => _TopToastViewState();
}

class _TopToastViewState extends State<_TopToastView>
    with SingleTickerProviderStateMixin {
  static const _enterMs = 240; // 进入
  static const _minStayMs = 600; // 展示总时长下限（40% 满透明 + 60% 渐淡都 > 0）

  // —— #11 v3.1 视觉参数（集中可调）——
  // 2026-09-07 真机反馈：v3「无描边 + blur36 大弥散柔影」边缘淡化到几乎
  // 不可感知、底色对比弱。v3.1：1px 深色半透明描边 + 近实远虚双层影
  //（近层小半径勾边界、远层少量弥散保留氛围）。
  // 视觉参数待真机复查微调。
  static const _borderColor = Color(0x1F18191C); // 描边：文字主色 ~12% 透明
  static const _shadowNear = BoxShadow(
    color: Color(0x16060913), // 近层影：偏冷深色 ~9%，勾出边界
    offset: Offset(0, 3),
    blurRadius: 8,
  );
  static const _shadowFar = BoxShadow(
    color: Color(0x12060913), // 远层影：~7%，弥散氛围
    offset: Offset(0, 10),
    blurRadius: 28,
  );

  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<double> _offsetY;
  Timer? _staticTimer; // 仅关动效路径使用（一次性），dispose 时 cancel

  @override
  void initState() {
    super.initState();
    final stayMs = widget.stayDuration.inMilliseconds < _minStayMs
        ? _minStayMs
        : widget.stayDuration.inMilliseconds;
    // 「随时间整体逐渐变淡」时间轴：满透明停留 40% → 连续渐淡至零 60%
    //（消失即渐淡本身；easeInOut 让淡出全程平滑、无末尾突变）
    final holdMs = (stayMs * 0.4).round();
    final fadeMs = stayMs - holdMs;
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: _enterMs + stayMs),
    );
    _opacity = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: _enterMs.toDouble(),
      ),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: holdMs.toDouble()),
      TweenSequenceItem(
        tween: Tween(
          begin: 1.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: fadeMs.toDouble(),
      ),
    ]).animate(_controller);
    _offsetY = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: -12.0,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeOut)),
        weight: _enterMs.toDouble(),
      ),
      TweenSequenceItem(tween: ConstantTween(0.0), weight: holdMs.toDouble()),
      // 渐淡期轻微上浮，像雾气向上散去（配合整体变淡，无跳灭感）
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: -14.0,
        ).chain(CurveTween(curve: Curves.easeInOut)),
        weight: fadeMs.toDouble(),
      ),
    ]).animate(_controller);

    if (widget.animationsEnabled) {
      _controller
        ..addStatusListener(_handleStatus)
        ..forward();
    } else {
      // 系统关闭动效：不做动画，静态显示满 stay 窗后照常移除
      _staticTimer = Timer(Duration(milliseconds: stayMs), widget.onFinished);
    }
  }

  void _handleStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      widget.onFinished();
    }
  }

  @override
  void dispose() {
    _staticTimer?.cancel();
    _controller.dispose();
    widget.onDismissed();
    super.dispose();
  }

  IconData get _icon => switch (widget.type) {
    TopToastType.success => Icons.check_circle_rounded,
    TopToastType.info => Icons.info_rounded,
    TopToastType.error => Icons.error_rounded,
  };

  /// 语义图标色（浅底深字时代替白图标承载语义）
  Color get _iconColor => switch (widget.type) {
    TopToastType.success => HengyaColors.successDeep,
    TopToastType.info => HengyaColors.brand,
    TopToastType.error => HengyaColors.danger,
  };

  @override
  Widget build(BuildContext context) {
    final bubble = Container(
      // 左右留白收敛宽度：短文案窄气泡，长文案至多两行
      margin: const EdgeInsets.symmetric(horizontal: 48),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        // 底色氛围：show 时随机取的一组浅色渐变（深字，语义由图标形状+图标色承载）
        gradient: LinearGradient(
          colors: widget.background,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        // 边缘可感知（#11 v3.1）：1px 深色半透明描边 + 近实远虚双层影。
        // 旧版白色描边「贴字误读为下划线」的根因（半透明期背景橙色元素
        // 透出）不复发——描边为深色半透明，与浅底文字色拉开。
        border: Border.all(color: _borderColor, width: 1),
        boxShadow: const <BoxShadow>[_shadowNear, _shadowFar],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 17, color: _iconColor),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              widget.message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: HengyaColors.textPrimary,
                // 显式关掉装饰：Text 会与 DefaultTextStyle 合并样式，
                // 万一宿主环境带 underline 会被继承——此处钉死为无装饰
                decoration: TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );

    // 忽略指针：纯展示气泡，不遮挡任何交互（文字仍进语义树，读屏可朗读）
    return IgnorePointer(
      child: SafeArea(
        minimum: const EdgeInsets.only(top: 10),
        child: Align(
          alignment: Alignment.topCenter,
          child: widget.animationsEnabled
              ? AnimatedBuilder(
                  animation: _controller,
                  builder: (context, child) => Opacity(
                    opacity: _opacity.value,
                    child: Transform.translate(
                      offset: Offset(0, _offsetY.value),
                      child: child,
                    ),
                  ),
                  child: bubble,
                )
              : bubble,
        ),
      ),
    );
  }
}
