// 复习页 —— 核心学习循环（M1）·签名级卡片堆叠界面
// 流程：选科目 → 拉队列（50 张）→ 纸质卡片堆叠 → 题干+答案（雾覆盖）→ 擦雾/掀页
//       → 6 档评分滑轨（blackout/foggy/struggled/hesitant/smooth/instant）→ 下一张
// 回炉入口：卡右上角（选原因 → 自由输入 → POST /rework → 卡出队列）
// 离线韧性（问1+5）：
//   · 科目列表/复习队列带缓存回退——断网冷启动可继续背（评分仍走既有离线
//     评分队列），缓存数据带「离线数据 · 更新于 HH:mm」提示条；
//   · 错误态（无缓存可用）补上 RefreshIndicator——原文案「检查网络后下拉
//     刷新」此前并无下拉交互，文案与交互不符，现把交互补实（保留文案）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared/hengya_shared.dart';

import '../services/api/api_client.dart';
import '../widgets/fog_reveal.dart';
import '../widgets/rating_slider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/api/local_cache.dart';
import '../services/review/session_store.dart';
import '../widgets/offline_data_bar.dart';
import '../widgets/reason_action_dialog.dart';
import '../widgets/top_toast.dart';

// ─── 纸质美学色板 ───
const _kPageBg = Color(0xFFFAF8F5); // 灰暖底色
const _kCardColor = Color(0xFFF5F0E6); // 暖米色纸面
const _kCardColorL2 = Color(0xFFEDE8DD); // 第 2 层卡片（略暗）
const _kCardColorL3 = Color(0xFFE5E0D5); // 第 3 层卡片（更暗）
const _kTextPrimary = Color(0xFF2C2C2C); // 题目文字（比纯黑柔和）
const _kTextSecondary = Color(0xFF3A3A3A); // 答案文字
const _kTextMuted = Color(0xFF999999); // 锚点/来源
const _kChipBg = Color(0xFFEDE8DD); // 题型标签底色
const _kChipText = Color(0xFF7A7060); // 题型标签文字

class ReviewPage extends StatelessWidget {
  const ReviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kPageBg,
      appBar: AppBar(
        title: const Text(
          '复习',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: _kPageBg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      body: const _SubjectPicker(),
    );
  }
}

/// 科目选择（科目隔离，决策 #8）
class _SubjectPicker extends StatefulWidget {
  const _SubjectPicker();

  @override
  State<_SubjectPicker> createState() => _SubjectPickerState();
}

class _SubjectPickerState extends State<_SubjectPicker> {
  Future<List<SubjectWithDue>>? _future;
  DateTime? _cacheAt; // 非 null = 科目列表来自离线缓存回退

  @override
  void initState() {
    super.initState();
    _future = _fetchSubjects();
  }

  /// 拉取科目并在完成前记下缓存回退元信息（builder 渲染时即可读）
  Future<List<SubjectWithDue>> _fetchSubjects() async {
    final subjects = await ApiClient.instance.fetchSubjects();
    _cacheAt = ApiClient.instance.cacheServedAt(CacheKeys.subjects);
    return subjects;
  }

  Future<void> _reload() async {
    setState(() {
      _future = _fetchSubjects();
    });
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<SubjectWithDue>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          // 错误态补实「下拉刷新」交互（原文案称可下拉，此前并无 RefreshIndicator）
          return RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                const SizedBox(height: 120),
                _OfflineHint(error: snap.error!),
              ],
            ),
          );
        }
        final subjects = snap.data ?? const [];
        if (subjects.isEmpty) {
          return Center(
            child: Text(
              currentBackendMode == BackendMode.local
                  ? '暂无科目（可导入数据库或新建科目）'
                  : '暂无科目（服务器未初始化？）',
            ),
          );
        }
        final due = subjects.where((s) => s.dueCount > 0).toList();
        final idle = subjects.where((s) => s.dueCount == 0).toList();
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.all(16),
            children: [
              if (_cacheAt != null) ...[
                OfflineDataBar(savedAt: _cacheAt),
                const SizedBox(height: 12),
              ],
              if (due.isNotEmpty) ...[
                const Text('今日到期', style: _kSectionStyle),
                const SizedBox(height: 8),
                ...due.map((s) => _SubjectTile(subject: s)),
                const SizedBox(height: 16),
              ],
              const Text('全部科目', style: _kSectionStyle),
              const SizedBox(height: 8),
              ...idle.map((s) => _SubjectTile(subject: s)),
            ],
          ),
        );
      },
    );
  }
}

const _kSectionStyle = TextStyle(fontSize: 13, fontWeight: FontWeight.w600);

class _SubjectTile extends StatelessWidget {
  const _SubjectTile({required this.subject});

  final SubjectWithDue subject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: subject.subject.isExamSubject
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          child: Text(
            subject.subject.name.characters.first,
            style: TextStyle(color: scheme.onSurface),
          ),
        ),
        title: Text(subject.subject.name),
        subtitle: Text(
          subject.subject.isExamSubject ? '考试课' : '考查课',
          style: TextStyle(
            fontSize: 12,
            color: subject.subject.isExamSubject
                ? scheme.primary
                : scheme.outline,
          ),
        ),
        trailing: subject.dueCount > 0
            ? Badge.count(
                count: subject.dueCount,
                backgroundColor: scheme.primary,
                textColor: scheme.onPrimary,
              )
            : const Text('无到期', style: TextStyle(fontSize: 12)),
        onTap: () => context.push('/review-home/${subject.subject.id}'),
      ),
    );
  }
}

/// 离线/错误提示（离线可背已拉取的卡；评分会自动补传）
class _OfflineHint extends StatelessWidget {
  const _OfflineHint({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.wifi_off_outlined,
              size: 48,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(
              currentBackendMode == BackendMode.local
                  ? '本地数据加载失败'
                  : '连不上服务器',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              currentBackendMode == BackendMode.local
                  ? '错误信息：$error'
                  : '检查网络后下拉刷新；已拉取的卡片离线也能背，评分自动补传。',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────── 复习会话 ───────────────

/// 复习会话页：/review-home/:subjectId
class ReviewSessionPage extends StatefulWidget {
  const ReviewSessionPage({super.key, required this.subjectId});

  final String subjectId;

  @override
  State<ReviewSessionPage> createState() => _ReviewSessionPageState();
}

class _ReviewSessionPageState extends State<ReviewSessionPage>
    with SingleTickerProviderStateMixin {
  List<FlashCard> _cards = [];
  int _index = 0;
  bool _loading = true;
  String? _error;
  DateTime? _cacheAt;
  DateTime _revealedAt = DateTime.now();

  // #12 雾气模式
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
    if (mounted) setState(() {});
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
      final cards = await ApiClient.instance.fetchQueue(
        widget.subjectId,
        limit: 50,
      );
      setState(() {
        _cards = cards;
        _cacheAt = ApiClient.instance.cacheServedAt(
          CacheKeys.queue(widget.subjectId, 50),
        );
        _revealedAt = DateTime.now();
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  // ─── 评分映射 ───
  ReviewRating _levelToRating(int level) => ReviewRating.values[level];

  Future<void> _rate(ReviewRating rating) async {
    if (_rating || _index >= _cards.length) return;
    _rating = true;
    _fog.markCleared(); // #12：评分=清雾+评分一步完成

    // 换卡飞出动画
    setState(() => _animatingOut = true);
    await _cardAnim.forward(from: 0);
    if (!mounted) return;

    final card = _cards[_index];
    final latency = DateTime.now().difference(_revealedAt).inMilliseconds;
    final log = ReviewLog(
      cardId: card.id,
      subjectId: card.subjectId,
      rating: rating,
      reviewedAt: DateTime.now(),
      latencyMs: latency,
    );
    try {
      await ApiClient.instance.submitAnswer(log);
    } on ApiException {
      if (mounted) {
        TopToast.show(
          context,
          '评分未受理（${card.front.characters.take(12)}…）',
          type: TopToastType.error,
        );
      }
    }
    if (mounted) {
      setState(() {
        _index++;
        _fog.reset();
        _revealedAt = DateTime.now();
        _animatingOut = false;
      });
    }
    _rating = false;
    unawaited(ApiClient.instance.flushPendingAnswers());
  }

  // 回炉（与待审核池拒绝/题库详情回炉共用 ReasonActionDialog）
  void _rework() {
    final card = _cards[_index];
    showModalBottomSheet<void>(
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
                _index++;
                _fog.reset();
                _revealedAt = DateTime.now();
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
                _index++;
                _fog.reset();
                _revealedAt = DateTime.now();
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
          '复习',
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
          IconButton(
            tooltip: '回炉重造',
            icon: const Icon(Icons.restart_alt_outlined),
            onPressed: _index < _cards.length ? _rework : null,
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
                      _OfflineHint(error: _error!),
                    ],
                  ),
                )
              : _cards.isEmpty
                  ? const _EmptyState()
                  : _index >= _cards.length
                      ? const _DoneState()
                      : _buildSession(),
    );
  }

  /// 完整会话布局：进度条 + 卡片堆叠 + 评分滑轨
  Widget _buildSession() {
    return Column(
      children: [
        // ── 圆角渐变进度条 ──
        _buildProgressBar(),
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
            child: RatingSlider(
              onRated: (level) => _rate(_levelToRating(level)),
              enabled: !_rating && _index < _cards.length,
            ),
          ),
        ),
      ],
    );
  }

  /// 渐变圆角进度条（红 → 绿）
  Widget _buildProgressBar() {
    final progress = _cards.isEmpty ? 0.0 : (_index + 1) / _cards.length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        height: 3,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(1.5),
          color: const Color(0x15000000),
        ),
        child: FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: progress.clamp(0.0, 1.0),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(1.5),
              gradient: const LinearGradient(
                colors: [Color(0xFFE57373), Color(0xFF66BB6A)],
              ),
            ),
          ),
        ),
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
        // 从底层到顶层构建
        for (int i = layers - 1; i >= 0; i--)
          if (i > 0)
            // 底层影子卡
            Transform.translate(
              offset: Offset(0, -i * 4.0),
              child: Transform.scale(
                scale: 1.0 - i * 0.03,
                alignment: Alignment.topCenter,
                child: _buildShadowCard(i),
              ),
            )
          else
            // 顶层：交互卡片（带飞出动画）
            AnimatedBuilder(
              animation: _cardAnim,
              builder: (context, child) {
                final t = _animatingOut ? _cardAnim.value : 0.0;
                return Transform.translate(
                  offset: Offset(-t * 300, -t * 40),
                  child: Opacity(
                    opacity: (1.0 - t).clamp(0.0, 1.0),
                    child: child,
                  ),
                );
              },
              child: _buildTopCard(),
            ),
      ],
    );
  }

  /// 底层影子卡片壳（纯装饰，无内容）
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
        border: Border.all(
          color: const Color(0x12000000),
          width: 0.5,
        ),
      ),
    );
  }

  /// 顶层完整交互卡片
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
        border: Border.all(
          color: const Color(0x12000000),
          width: 0.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _fogEnabled
              ? _buildCardFogged(card)
              : _buildCardNormal(card),
        ),
      ),
    );
  }

  /// 雾激活时的卡面布局
  Widget _buildCardFogged(FlashCard card) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCardHeader(card),
        const SizedBox(height: 16),
        Text(
          card.front,
          style: const TextStyle(
            fontSize: 20,
            height: 1.5,
            fontWeight: FontWeight.w500,
            color: _kTextPrimary,
          ),
        ),
        const SizedBox(height: 24),
        // 极细渐变分隔线（从中心向两端淡出）
        _buildSoftDivider(),
        const SizedBox(height: 16),
        Expanded(
          child: FogPeel(
            controller: _fog,
            sheetMode:
                _fogHug ? FogSheetMode.hugText : FogSheetMode.fill,
            child: Text(
              card.back,
              style: const TextStyle(
                fontSize: 18,
                height: 1.6,
                color: _kTextSecondary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildMetaRow(card),
      ],
    );
  }

  /// 无雾卡面布局
  Widget _buildCardNormal(FlashCard card) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCardHeader(card),
        const SizedBox(height: 16),
        Text(
          card.front,
          style: const TextStyle(
            fontSize: 20,
            height: 1.5,
            fontWeight: FontWeight.w500,
            color: _kTextPrimary,
          ),
        ),
        const SizedBox(height: 24),
        _buildSoftDivider(),
        const SizedBox(height: 16),
        Expanded(
          child: SingleChildScrollView(
            child: Text(
              card.back,
              style: const TextStyle(
                fontSize: 18,
                height: 1.6,
                color: _kTextSecondary,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildMetaRow(card),
      ],
    );
  }

  /// 卡片头部：题型标签 + 进度
  Widget _buildCardHeader(FlashCard card) {
    return Row(
      children: [
        _TypeChip(type: card.type),
        const Spacer(),
        Text(
          '#${_index + 1}/${_cards.length}',
          style: const TextStyle(fontSize: 12, color: _kTextMuted),
        ),
      ],
    );
  }

  /// 题目 / 答案之间的渐变分隔线
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

  /// 锚点/来源区（FogPeel 外面，卡片底部）
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
}

// ═══════════════════════════════════════════════════════════════
//  小组件
// ═══════════════════════════════════════════════════════════════

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
        Text(
          label,
          style: const TextStyle(fontSize: 11, color: _kTextMuted),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.celebration_outlined,
            size: 56,
            color: const Color(0xFFFFA726).withValues(alpha: 0.8),
          ),
          const SizedBox(height: 12),
          const Text(
            '该科目暂无到期卡',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: _kTextPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '审核池通过的新卡才会出现',
            style: TextStyle(fontSize: 12, color: _kTextMuted),
          ),
        ],
      ),
    );
  }
}

class _DoneState extends StatelessWidget {
  const _DoneState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.task_alt,
            size: 56,
            color: const Color(0xFF66BB6A).withValues(alpha: 0.85),
          ),
          const SizedBox(height: 12),
          const Text(
            '本批复习完成！',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: _kTextPrimary,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '剩下的卡在未来的记忆曲线里等你',
            style: TextStyle(fontSize: 12, color: _kTextMuted),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () => context.pop(),
            style: FilledButton.styleFrom(
              backgroundColor: _kCardColorL2,
              foregroundColor: _kTextPrimary,
              padding: const EdgeInsets.symmetric(
                horizontal: 32,
                vertical: 14,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }
}
