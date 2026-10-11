// 今日复习 —— 跨科目每日任务会话页
//
// 每日计划（唯一口径）消费端：GET /cards/queue/today 一次拉取跨科目合并
// 队列（已按 remainingToday 截断）+ 四字段进度（goal/doneToday/dueTotal/
// remainingToday），与 /stats/today 同名同义，禁止页面内另算。
//
// 交互骨架复用科目会话页（review_page.dart 的 ReviewSessionPage）：
//   · 评分滑轨 RatingSlider / 雾气 FogPeel / 卡片堆叠布局 / 跳过 _deferred
//     / 回炉入口（local 工作台 + remote ReasonActionDialog）——组件不改行为；
//   · 评分失败口径一致：toast「评分未受理，已保留当前卡片」+ 停留当前卡。
// 差异：顶部常驻「N/目标 M」进度（初始 doneToday，评分成功本地 +1，
// 乐观更新以服务端 submitAnswer 受理为准）；每张卡带科目名小徽章
// （fetchSubjects 刷新 ApiClient.subjectNames 映射）；结算页按是否达成
// 目标区分庆祝态 / 「今日到期已清完」态。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared/hengya_shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api/api_client.dart';
import '../services/review/session_store.dart';
import '../theme.dart';
import '../widgets/fog_reveal.dart';
import '../widgets/offline_data_bar.dart';
import '../widgets/rating_slider.dart';
import '../widgets/reason_action_dialog.dart';
import '../widgets/top_toast.dart';
import 'rework_request_sheet.dart';
import 'rework_workbench_page.dart';

// ─── 纸质美学色板（与科目会话页同源） ───
const _kPageBg = Color(0xFFFAF8F5);
const _kCardColor = Color(0xFFF5F0E6);
const _kCardColorL2 = Color(0xFFEDE8DD);
const _kCardColorL3 = Color(0xFFE5E0D5);
const _kTextPrimary = Color(0xFF2C2C2C);
const _kTextSecondary = Color(0xFF3A3A3A);
const _kTextMuted = Color(0xFF999999);
const _kChipBg = Color(0xFFEDE8DD);
const _kChipText = Color(0xFF7A7060);

/// 今日复习会话页：/review/today
class TodayReviewPage extends StatefulWidget {
  const TodayReviewPage({super.key});

  @override
  State<TodayReviewPage> createState() => _TodayReviewPageState();
}

class _TodayReviewPageState extends State<TodayReviewPage>
    with SingleTickerProviderStateMixin {
  List<FlashCard> _cards = [];
  int _index = 0;
  final List<FlashCard> _deferred = [];
  int _removedCount = 0;
  int _round = 0;
  double _skipDrag = 0;
  double _skipStart = 0;
  bool _skipTransition = false;
  bool _draggingCard = false;
  double _exitStart = 0;
  double _exitSign = 1;
  bool _lastFogClear = false;
  bool _loading = true;
  String? _error;
  DateTime _revealedAt = DateTime.now();

  // 今日进度四字段（唯一口径：goal/doneToday/dueTotal/remainingToday）。
  // _doneToday 为乐观本地计数：初始 = 接口 doneToday，评分受理成功 +1。
  int _goal = 0;
  int _doneToday = 0;
  int _dueTotal = 0;
  DateTime? _cacheAt;

  // #12 雾气模式（与科目会话同一开关）
  final FogRevealController _fog = FogRevealController();
  bool _fogEnabled = false;
  bool _fogHug = false;

  // 换卡动画
  late final AnimationController _cardAnim;
  bool _animatingOut = false;

  // 防连点
  bool _rating = false;

  @override
  void initState() {
    super.initState();
    _cardAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _load();
    _loadFogEnabled();
    _fog.addListener(_onFogChanged);
  }

  Future<void> _loadFogEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _fogEnabled = prefs.getBool('hengya.review.fog') ?? false;
        _fogHug = prefs.getBool('hengya.review.fog.hug') ?? false;
      });
    } catch (_) {
      // 测试宿主无 prefs 插件/读取失败 → 默认关
    }
  }

  void _onFogChanged() {
    if (mounted && _lastFogClear != _fog.isCleared) {
      _lastFogClear = _fog.isCleared;
      setState(() {});
    }
  }

  @override
  void dispose() {
    _fog.removeListener(_onFogChanged);
    _fog.dispose();
    _cardAnim.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 科目名映射先行刷新（小徽章用；失败不阻塞队列——名字兜底显示 id）
      try {
        await ApiClient.instance.fetchSubjects();
      } catch (_) {}
      final queue = await ApiClient.instance.fetchTodayQueue();
      if (!mounted) return;
      setState(() {
        _cards = queue.cards;
        _goal = queue.goal;
        _doneToday = queue.doneToday;
        _dueTotal = queue.dueTotal;
        _revealedAt = DateTime.now();
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 今日是否已达成目标（进队即判：remaining==0 时接口 cards 为空）。
  /// 初始 remainingToday==0 直接进完成态而非空白——由队列为空 + 进度文案
  /// 联合表达，见 [_buildTodayDone]。
  bool get _goalReached => _goal > 0 && _doneToday >= _goal;

  // ─── 评分映射 ───
  ReviewRating _levelToRating(int level) => ReviewRating.values[level];

  Future<bool> _animateNext({bool skip = false}) async {
    if (!mounted) return false;
    setState(() {
      _animatingOut = true;
      _skipTransition = skip;
      _exitStart = _skipDrag * .5;
      _exitSign = _skipDrag < 0 ? -1 : 1;
      _draggingCard = false;
      _skipDrag = 0;
    });
    _cardAnim.duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240);
    try {
      await _cardAnim.forward(from: 0).orCancel;
    } on TickerCanceled {
      if (mounted) setState(() => _rating = false);
      return false;
    }
    if (!mounted) return false;
    return true;
  }

  void _nextCard() {
    _index++;
    _fog.reset();
    _revealedAt = DateTime.now();
    _animatingOut = false;
    _draggingCard = false;
    _exitStart = 0;
    _skipDrag = 0;
    _rating = false;
  }

  Future<void> _rate(ReviewRating rating) async {
    if (_rating || _index >= _cards.length) return;
    final card = _cards[_index];
    final now = DateTime.now();
    setState(() => _rating = true);
    _fog.markCleared();
    final log = ReviewLog(
      cardId: card.id,
      subjectId: card.subjectId,
      rating: rating,
      reviewedAt: now,
      latencyMs: now.difference(_revealedAt).inMilliseconds,
    );
    try {
      final accepted = await ApiClient.instance.submitAnswer(log);
      if (!accepted) throw StateError('评分未受理');
    } catch (e) {
      if (mounted) {
        setState(() => _rating = false);
        final reason = e is StateError ? '（${e.message}）' : '';
        TopToast.show(
          context,
          '评分未受理，已保留当前卡片$reason',
          type: TopToastType.error,
        );
      }
      return;
    }
    if (!await _animateNext()) return;
    // 乐观更新：服务端已受理才 +1（初始值 = 接口 doneToday，口径不另算）
    setState(() {
      _doneToday++;
      _nextCard();
    });
    unawaited(ApiClient.instance.flushPendingAnswers());
  }

  Future<void> _skip() async {
    if (_rating || _index >= _cards.length) return;
    final card = _cards[_index];
    setState(() => _rating = true);
    if (!await _animateNext(skip: true)) return;
    // 跳过不计 doneToday（服务端也不写账本行），保持会话内 _deferred 语义。
    setState(() {
      _deferred.add(card);
      _nextCard();
    });
  }

  void _retryDeferred() {
    if (_rating || _deferred.isEmpty) return;
    setState(() {
      _cards = List<FlashCard>.of(_deferred);
      _deferred.clear();
      _index = 0;
      _round++;
      _skipDrag = 0;
      _animatingOut = false;
      _fog.reset();
      _revealedAt = DateTime.now();
    });
  }

  void _endSkipDrag(DragEndDetails details) {
    if (_rating) return;
    final shouldSkip =
        _skipDrag.abs() >= 80 ||
        (_skipDrag.abs() >= 24 &&
            details.velocity.pixelsPerSecond.dx.abs() >= 900);
    if (shouldSkip) {
      _skip();
    } else {
      setState(() {
        _draggingCard = false;
        _skipDrag = 0;
      });
    }
  }

  // 回炉入口（与科目会话一致：local → 回炉工作台；remote → 弹层提交流程）
  Future<void> _rework() async {
    if (currentBackendMode == BackendMode.local) {
      if (_rating || _index >= _cards.length) return;
      setState(() => _rating = true);
      try {
        final task = await requestReworkTask(context, _cards[_index]);
        if (task != null && mounted) {
          setState(() {
            _removedCount++;
            _nextCard();
            _rating = true;
          });
          await Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute<void>(
              builder: (_) => ReworkWorkbenchPage(taskId: task),
            ),
          );
        }
      } finally {
        if (mounted) setState(() => _rating = false);
      }
      return;
    }
    if (_rating || _index >= _cards.length) return;
    final card = _cards[_index];
    setState(() => _rating = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        barrierColor: Colors.black.withValues(alpha: 0.45),
        builder: (dlgCtx) => ReasonActionDialog(
          title: '回炉重造',
          subtitle: '「${card.front}」将退出复习队列，重造后回待审核池',
          reasons: kReworkReasons,
          noteHint: '补充说明（可选）：想怎么改这张卡？',
          buttonLabel: '送进回炉队列',
          buttonIcon: Icons.restart_alt_outlined,
          emptyReasonToast: '先选至少一个回炉原因',
          onConfirm: (reason, note) async {
            try {
              final res = await ApiClient.instance.reworkCard(
                card.id,
                reason: reason,
                note: note,
              );
              if (mounted) {
                setState(() {
                  _removedCount++;
                  _nextCard();
                  _rating = true; // 弹层关闭前保持动作互斥
                });
                if (res['duplicate'] == true) {
                  TopToast.show(
                    context,
                    '已在回炉队列，无需重复提交',
                    type: TopToastType.info,
                  );
                }
              }
            } on ApiException catch (e) {
              if (mounted) {
                TopToast.show(
                  context,
                  '提交失败：${e.message}',
                  type: TopToastType.error,
                  stayDuration: const Duration(milliseconds: 1800),
                );
              }
            }
          },
          deleteLabel: '删除整卡（含学习记录，不可恢复）',
          onDelete: (reason, note) async {
            try {
              await ApiClient.instance.removeCard(
                card.id,
                reason: reason,
                note: note,
              );
              if (mounted) {
                setState(() {
                  _removedCount++;
                  _nextCard();
                  _rating = true;
                });
                TopToast.show(context, '已删除整卡', type: TopToastType.success);
              }
            } on ApiException catch (e) {
              if (mounted) {
                TopToast.show(
                  context,
                  '删除失败：${e.message}',
                  type: TopToastType.error,
                  stayDuration: const Duration(milliseconds: 1800),
                );
              }
            }
          },
        ),
      );
    } finally {
      if (mounted) setState(() => _rating = false);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final pending = context.watch<SessionStore>().pendingCount;

    return Scaffold(
      backgroundColor: _kPageBg,
      appBar: AppBar(
        title: const Text(
          '今日复习',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: _kPageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        actions: [
          if (pending > 0)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Text(
                  '待补传 $pending',
                  style: const TextStyle(fontSize: 12, color: Colors.orange),
                ),
              ),
            ),
          if (!_loading && _error == null && _index < _cards.length)
            IconButton(
              tooltip: '回炉重造',
              icon: const Icon(Icons.restart_alt_outlined),
              onPressed: !_rating ? _rework : null,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  const SizedBox(height: 160),
                  Center(
                    child: Text(
                      '本地数据加载失败\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: _kTextMuted),
                    ),
                  ),
                ],
              ),
            )
          : _cards.isEmpty
          ? _buildTodayDone()
          : _index >= _cards.length
          ? _buildTodayDone()
          : _buildSession(),
    );
  }

  /// 完整会话布局：今日进度条 + 卡片堆叠 + 评分滑轨
  Widget _buildSession() => LayoutBuilder(
    builder: (context, constraints) {
      final minHeight =
          560.0 +
          (MediaQuery.textScalerOf(context).scale(14) - 14)
                  .clamp(0.0, 100.0)
                  .toDouble() *
              4;
      if (constraints.maxHeight < minHeight) {
        return SingleChildScrollView(
          child: SizedBox(height: minHeight, child: _buildSessionLayout()),
        );
      }
      return _buildSessionLayout();
    },
  );

  Widget _buildSessionLayout() {
    return Column(
      children: [
        // ── 今日进度：N/目标 M + 进度条 ──
        _buildTodayProgressHeader(),
        // 离线缓存回退提示条
        if (_cacheAt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: OfflineDataBar(savedAt: _cacheAt),
          ),
        // ── 卡片堆叠区 ──
        Expanded(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
            child: _buildCardStack(),
          ),
        ),
        // ── 评分滑轨 ──
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: double.infinity,
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (_fogEnabled)
                        TextButton.icon(
                          key: const ValueKey('review-reveal'),
                          onPressed: _rating || _fog.isCleared
                              ? null
                              : _fog.markCleared,
                          icon: const Icon(Icons.visibility_outlined, size: 18),
                          label: Text(_fog.isCleared ? '答案已揭开' : '揭开答案'),
                        ),
                      TextButton.icon(
                        key: const ValueKey('review-skip'),
                        onPressed: _rating ? null : _skip,
                        icon: const Icon(Icons.skip_next_rounded, size: 20),
                        label: const Text('跳过 · 不评分'),
                      ),
                    ],
                  ),
                ),
                RatingSlider(
                  key: ValueKey('rating-$_round-${_cards[_index].id}'),
                  itemKey: _cards[_index].id,
                  onRated: (level) => _rate(_levelToRating(level)),
                  enabled: !_rating && _index < _cards.length,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// 今日进度头：常驻「N/目标 M」（口径基线措辞）+ 进度条。
  /// 进度分母 = goal（今日任务口径，非本批卡数）；分子 = doneToday 乐观计数。
  Widget _buildTodayProgressHeader() {
    final ratio = _goal > 0 ? (_doneToday / _goal).clamp(0.0, 1.0) : 0.0;
    final reached = _goalReached;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '$_doneToday/目标 $_goal',
                key: const ValueKey('today-progress'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: reached ? HengyaColors.success : HengyaColors.brand,
                ),
              ),
              const Spacer(),
              Text(
                reached ? '已完成' : '还剩 ${(_goal - _doneToday).clamp(0, 1 << 31)} 张',
                style: const TextStyle(fontSize: 12, color: _kTextMuted),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // 圆角渐变进度条（红 → 绿，与科目会话同源；达成后整条绿色）
          Container(
            height: 3,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(1.5),
              color: const Color(0x15000000),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: ratio,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1.5),
                  gradient: reached
                      ? const LinearGradient(
                          colors: [Color(0xFF66BB6A), Color(0xFF66BB6A)],
                        )
                      : const LinearGradient(
                          colors: [Color(0xFFE57373), Color(0xFF66BB6A)],
                        ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── 卡片堆叠 ───

  Widget _buildCardStack() {
    final remaining = _cards.length - _index;
    final layers = remaining.clamp(0, 3);

    return Stack(
      alignment: Alignment.topCenter,
      children: [
        for (int i = layers - 1; i >= 0; i--)
          if (i > 0)
            Transform.translate(
              offset: Offset(0, -i * 4.0),
              child: Transform.scale(
                scale: 1.0 - i * 0.03,
                alignment: Alignment.topCenter,
                child: _buildShadowCard(i),
              ),
            )
          else
            AnimatedSlide(
              offset: Offset(
                _skipDrag * .5 / MediaQuery.sizeOf(context).width,
                0,
              ),
              duration:
                  _draggingCard ||
                      _rating ||
                      MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: AnimatedBuilder(
                animation: _cardAnim,
                builder: (context, child) {
                  final t = _animatingOut ? _cardAnim.value : 0.0;
                  return Transform.translate(
                    offset: Offset(
                      _animatingOut
                          ? _exitStart * (1 - t) +
                                t * (_skipTransition ? 300 * _exitSign : -300)
                          : 0,
                      -t * 20,
                    ),
                    child: Opacity(
                      opacity: (1.0 - t).clamp(0.0, 1.0),
                      child: child,
                    ),
                  );
                },
                child: IgnorePointer(ignoring: _rating, child: _buildTopCard()),
              ),
            ),
      ],
    );
  }

  Widget _buildShadowCard(int layer) {
    final color = layer == 2 ? _kCardColorL3 : _kCardColorL2;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      height: double.infinity,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: const Color(0x12000000), width: 0.5),
      ),
    );
  }

  Widget _buildTopCard() {
    final card = _cards[_index];
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: _kCardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
        border: Border.all(color: const Color(0x12000000), width: 0.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: LayoutBuilder(
            builder: (context, constraints) =>
                _buildCardContent(card, constraints.maxHeight),
          ),
        ),
      ),
    );
  }

  Widget _buildCardContent(FlashCard card, double availableHeight) {
    final answer = Text(
      card.back,
      style: const TextStyle(fontSize: 18, height: 1.6, color: _kTextSecondary),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          key: const ValueKey('review-skip-zone'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragDown: (d) => _skipStart = d.globalPosition.dx,
          onHorizontalDragStart: _rating
              ? null
              : (d) => setState(() {
                  _draggingCard = true;
                  _skipDrag = (d.globalPosition.dx - _skipStart).clamp(
                    -180.0,
                    180.0,
                  );
                }),
          onHorizontalDragUpdate: _rating
              ? null
              : (d) => setState(() {
                  final wasReady = _skipDrag.abs() >= 80;
                  _skipDrag = (_skipDrag + d.delta.dx).clamp(-180.0, 180.0);
                  if (!wasReady && _skipDrag.abs() >= 80) {
                    HapticFeedback.selectionClick();
                  }
                }),
          onHorizontalDragEnd: _rating ? null : _endSkipDrag,
          onHorizontalDragCancel: () {
            if (mounted) {
              setState(() {
                _draggingCard = false;
                _skipDrag = 0;
              });
            }
          },
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: availableHeight * .42),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildCardHeader(card),
                  const SizedBox(height: 12),
                  Text(
                    card.front,
                    style: const TextStyle(
                      fontSize: 20,
                      height: 1.5,
                      fontWeight: FontWeight.w500,
                      color: _kTextPrimary,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _skipDrag.abs() >= 80 ? '松手跳过 · 不计评分' : '左右划动题干可跳过',
                    style: const TextStyle(fontSize: 11, color: _kTextMuted),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildSoftDivider(),
        const SizedBox(height: 12),
        Expanded(
          child: _fogEnabled
              ? FogPeel(
                  key: ValueKey('fog-$_round-${card.id}'),
                  controller: _fog,
                  sheetMode: _fogHug ? FogSheetMode.hugText : FogSheetMode.fill,
                  child: answer,
                )
              : SingleChildScrollView(
                  key: ValueKey('answer-${card.id}'),
                  child: answer,
                ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 28,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: _buildMetaRow(card),
          ),
        ),
      ],
    );
  }

  /// 卡片头部：科目徽章 + 题型标签 + 进度
  Widget _buildCardHeader(FlashCard card) {
    return Row(
      children: [
        _SubjectBadge(subjectId: card.subjectId),
        const SizedBox(width: 6),
        _TypeChip(type: card.type),
        const Spacer(),
        Text(
          '#${_index + 1}/${_cards.length}',
          style: const TextStyle(fontSize: 12, color: _kTextMuted),
        ),
      ],
    );
  }

  Widget _buildSoftDivider() {
    return Container(
      height: 0.5,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0x00000000),
            Color(0x18000000),
            Color(0x18000000),
            Color(0x00000000),
          ],
          stops: [0.0, 0.3, 0.7, 1.0],
        ),
      ),
    );
  }

  Widget _buildMetaRow(FlashCard card) {
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        _MetaChip(icon: Icons.anchor, label: '锚点 ${card.anchor}'),
        _MetaChip(icon: Icons.menu_book_outlined, label: card.source),
      ],
    );
  }

  /// 结算/完成态：进队即空（remainingToday==0）或全部答完都落到这里。
  /// 达成目标 → 庆祝态（克制动效：一次性缩放淡入，不循环不发光）；
  /// 未达目标（到期比目标少，到期清完即队列空）→「今日到期已清完 N 张」。
  Widget _buildTodayDone() {
    final reached = _goalReached;
    final skipped = _deferred.isNotEmpty;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 庆祝图标一次性入场动效（MediaQuery.disableAnimations 尊重无障碍）
            _CelebrationIcon(celebrate: reached),
            const SizedBox(height: 16),
            Text(
              reached ? '今日目标达成' : '今日到期已清完',
              key: const ValueKey('today-summary'),
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              skipped
                  ? '今日 $_doneToday/目标 $_goal 张 · 跳过 ${_deferred.length} 张'
                  : _removedCount > 0
                  ? '今日 $_doneToday/目标 $_goal 张 · 另有 $_removedCount 张已回炉或移除'
                  : '今日 $_doneToday/目标 $_goal 张',
              key: const ValueKey('today-summary-count'),
              textAlign: TextAlign.center,
            ),
            if (reached) ...[
              const SizedBox(height: 8),
              Text(
                _dueTotal > 0
                    ? '目标 $_goal 张已完成，今天到此为止，明天继续。'
                    : '已把今天的到期卡清完，休息一下吧。',
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: _kTextMuted),
              ),
            ] else ...[
              const SizedBox(height: 8),
              const Text(
                '到期卡已全部清完，未达目标是因为今日到期不足。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: _kTextMuted),
              ),
            ],
            if (skipped) ...[
              const SizedBox(height: 10),
              const Text('跳过的卡片没有评分，原复习计划保持不变。', textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                key: const ValueKey('review-retry-skipped'),
                onPressed: _retryDeferred,
                icon: const Icon(Icons.replay_rounded),
                label: Text('再看这 ${_deferred.length} 张跳过的卡'),
              ),
            ],
            const SizedBox(height: 12),
            TextButton(
              key: const ValueKey('today-back'),
              onPressed: () => context.pop(),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  小组件
// ═══════════════════════════════════════════════════════════════

/// 庆祝态图标：达成目标用 Hero 渐变圆底 + 一次性缩放淡入（克制动效，无循环）。
class _CelebrationIcon extends StatefulWidget {
  const _CelebrationIcon({required this.celebrate});

  final bool celebrate;

  @override
  State<_CelebrationIcon> createState() => _CelebrationIconState();
}

class _CelebrationIconState extends State<_CelebrationIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entrance;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 一次性入场动效（MediaQuery.disableAnimations 尊重无障碍；
    // inherited 依赖只能在 didChangeDependencies 读，不能在 initState）
    if (!_started && widget.celebrate) {
      _started = true;
      if (!MediaQuery.disableAnimationsOf(context)) _entrance.forward();
    }
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      widget.celebrate ? Icons.celebration_outlined : Icons.task_alt_rounded,
      size: widget.celebrate ? 44 : 48,
      color: widget.celebrate ? Colors.white : const Color(0xFF508575),
    );
    if (!widget.celebrate) return icon;
    return FadeTransition(
      opacity: CurvedAnimation(parent: _entrance, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: CurvedAnimation(parent: _entrance, curve: Curves.easeOutBack),
        child: Container(
          width: 72,
          height: 72,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: kHeroGradient,
          ),
          child: Center(child: icon),
        ),
      ),
    );
  }
}

/// 科目名小徽章：subjectId → 科目名（ApiClient.subjectNames 映射，
/// 由页面加载时 fetchSubjects 刷新；未命中兜底显示 id）。
class _SubjectBadge extends StatelessWidget {
  const _SubjectBadge({required this.subjectId});

  final String subjectId;

  @override
  Widget build(BuildContext context) {
    final name = ApiClient.instance.subjectNameOf(subjectId);
    return Container(
      key: const ValueKey('today-subject-badge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: HengyaColors.brand.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        name,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: HengyaColors.brand,
        ),
      ),
    );
  }
}

class _TypeChip extends StatelessWidget {
  const _TypeChip({required this.type});

  final CardType type;

  @override
  Widget build(BuildContext context) {
    final label = switch (type) {
      CardType.basic => '问答',
      CardType.cloze => '填空',
      CardType.caseChain => '病例',
      CardType.image => '图像',
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _kChipBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 12, color: _kChipText),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: _kTextMuted),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: _kTextMuted)),
      ],
    );
  }
}
