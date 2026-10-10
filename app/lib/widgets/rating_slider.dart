// 六档记忆轨道：触点释放时同步提交，绝不排队延迟评分。
// 视觉参考：Material discrete sliders / Radix slider keyboard & commit model。
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _labels = ['忘了', '见过', '费力', '犹豫', '顺畅', '秒答'];
const _descriptions = ['完全忘记', '只记得见过', '费力才想起', '想起但有犹豫', '回忆比较顺畅', '立即想起答案'];
const _accents = [
  Color(0xFFA8534A),
  Color(0xFFAD704B),
  Color(0xFF9B813F),
  Color(0xFF7F8951),
  Color(0xFF508575),
  Color(0xFF287767),
];

class RatingSlider extends StatefulWidget {
  const RatingSlider({
    super.key,
    required this.onRated,
    this.enabled = true,
    this.itemKey,
  });
  final ValueChanged<int> onRated;
  final bool enabled;

  /// 新卡必须有新的身份，取消上一张卡的预览/触摸/键盘状态。
  final Object? itemKey;
  @override
  State<RatingSlider> createState() => _RatingSliderState();
}

class _RatingSliderState extends State<RatingSlider> {
  int? _preview;
  bool _cancelled = false;
  bool _locked = false;
  bool _dragActive = false;
  final Set<int> _pointers = {};
  Timer? _cooldown;
  bool get _enabled => widget.enabled && !_locked;

  @override
  void didUpdateWidget(covariant RatingSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.itemKey != widget.itemKey || !widget.enabled) {
      _cooldown?.cancel();
      _preview = null;
      _dragActive = false;
      _cancelled = true;
      _pointers.clear();
      _locked = false;
    }
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }

  int _level(double dx, double width) =>
      width <= 0 ? 0 : (dx / width * 6).floor().clamp(0, 5);

  void _show(int level) {
    if (!_enabled || _cancelled || level == _preview) {
      return;
    }
    HapticFeedback.selectionClick();
    setState(() => _preview = level);
  }

  void _commit(int level) {
    if (!_enabled || _cancelled) return;
    setState(() {
      _locked = true;
      _preview = level;
    });
    HapticFeedback.lightImpact();
    // 只延迟解除节流，不延迟业务回调；旧卡不可能给新卡补发评分。
    _cooldown?.cancel();
    _cooldown = Timer(const Duration(milliseconds: 350), () {
      if (mounted) {
        setState(() {
          _locked = false;
          _preview = null;
        });
      }
    });
    widget.onRated(level);
  }

  void _cancel() {
    _cancelled = true;
    if (mounted) setState(() => _preview = null);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || !_enabled) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight) {
      _cancelled = false;
      _show(
        ((_preview ?? 2) + (key == LogicalKeyboardKey.arrowRight ? 1 : -1))
            .clamp(0, 5),
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _cancel();
      return KeyEventResult.handled;
    }
    if ((key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.space) &&
        _preview != null) {
      _commit(_preview!);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 140);
    return Focus(
      onKeyEvent: _key,
      child: Opacity(
        opacity: widget.enabled ? 1 : .42,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 72,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final width = constraints.maxWidth;
                  return Listener(
                    onPointerDown: (e) {
                      _pointers.add(e.pointer);
                      if (_pointers.length == 1) {
                        _cancelled = false;
                      } else {
                        _cancel();
                      }
                    },
                    onPointerMove: (e) {
                      if (e.localPosition.dy < -32 ||
                          e.localPosition.dy > 104 ||
                          e.localPosition.dx < -32 ||
                          e.localPosition.dx > width + 32) {
                        _cancel();
                      }
                    },
                    onPointerUp: (e) => _pointers.remove(e.pointer),
                    onPointerCancel: (e) {
                      _pointers.remove(e.pointer);
                      _cancel();
                    },
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: _enabled
                          ? (d) => _show(_level(d.localPosition.dx, width))
                          : null,
                      // Tap 识别器被纵向滚动/拖动取消后，不留下可被 Enter 提交的预览。
                      // 这里只清预览，不设置 sticky cancel：横向拖动胜出后仍需正常选档。
                      onTapCancel: () {
                        if (mounted && !_dragActive) {
                          setState(() => _preview = null);
                        }
                      },
                      onTapUp: _enabled
                          ? (d) => _commit(_level(d.localPosition.dx, width))
                          : null,
                      onHorizontalDragStart: _enabled
                          ? (d) {
                              _dragActive = true;
                              _show(_level(d.localPosition.dx, width));
                            }
                          : null,
                      onHorizontalDragUpdate: _enabled
                          ? (d) => _show(_level(d.localPosition.dx, width))
                          : null,
                      onHorizontalDragEnd: _enabled
                          ? (_) {
                              if (_preview != null) _commit(_preview!);
                              _dragActive = false;
                            }
                          : null,
                      // 简单点击时 tap 在竞技场胜出、horizontalDrag 输掉也会触发本回调；
                      // 只有真正拖动过（_dragActive）才应取消，否则会误把随后的
                      // onTapUp 提交挡掉（_cancelled 被置真 → _commit 提前返回）。
                      onHorizontalDragCancel: () {
                        if (_dragActive) {
                          _dragActive = false;
                          _cancel();
                        }
                      },
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: const Color(0xFFF0ECE4),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0xFFE3DDD2)),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Row(
                            children: [
                              for (var i = 0; i < 6; i++)
                                Expanded(
                                  child: Semantics(
                                    button: true,
                                    enabled: _enabled,
                                    selected: _preview == i,
                                    label: '记忆等级 $i，${_descriptions[i]}',
                                    onTap: _enabled
                                        ? () {
                                            _cancelled = false;
                                            _commit(i);
                                          }
                                        : null,
                                    child: ExcludeSemantics(
                                      child: AnimatedContainer(
                                        duration: duration,
                                        margin: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: _preview == i
                                              ? _accents[i]
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            13,
                                          ),
                                        ),
                                        child: Center(
                                          child: FittedBox(
                                            fit: BoxFit.scaleDown,
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 4,
                                                  ),
                                              child: Column(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    '$i',
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: _preview == i
                                                          ? Colors.white70
                                                          : const Color(
                                                              0xFF8B887F,
                                                            ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 5),
                                                  Text(
                                                    _labels[i],
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color: _preview == i
                                                          ? Colors.white
                                                          : const Color(
                                                              0xFF494B45,
                                                            ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 7),
            Text(
              _preview == null ? '轻点评分 · 滑动选档，松手确认' : _descriptions[_preview!],
              style: const TextStyle(fontSize: 11, color: Color(0xFF84847B)),
            ),
          ],
        ),
      ),
    );
  }
}
