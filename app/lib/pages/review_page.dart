// 复习页 —— 核心学习循环（M1）
// 流程：选科目 → 拉队列（50 张）→ 题干 · 主动回忆 → 翻面（答案+锚点+出处）
//       → 四档评分（重来/困难/良好/简单）→ 下一张；离线评分自动入队补传（13.6）
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
import '../services/api/local_cache.dart';
import '../services/review/session_store.dart';
import '../widgets/offline_data_bar.dart';
import '../widgets/reason_action_dialog.dart';
import '../widgets/top_toast.dart';

class ReviewPage extends StatelessWidget {
  const ReviewPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('复习')),
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

// ---------------- 复习会话 ----------------

/// 复习会话页：/review-home/:subjectId
class ReviewSessionPage extends StatefulWidget {
  const ReviewSessionPage({super.key, required this.subjectId});

  final String subjectId;

  @override
  State<ReviewSessionPage> createState() => _ReviewSessionPageState();
}

class _ReviewSessionPageState extends State<ReviewSessionPage> {
  List<FlashCard> _cards = [];
  int _index = 0;
  bool _revealed = false;
  bool _loading = true;
  String? _error;
  DateTime? _cacheAt; // 非 null = 队列来自离线缓存回退（断网冷启动续背）
  DateTime _revealedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 拉取成功 → api_client 异步把队列 JSON 落盘（复习队列持久化）；
      // 断网 → 透明回退同一批卡，冷启动也能继续背
      final cards = await ApiClient.instance.fetchQueue(
        widget.subjectId,
        limit: 50,
      );
      setState(() {
        _cards = cards;
        _cacheAt = ApiClient.instance.cacheServedAt(
          CacheKeys.queue(widget.subjectId, 50),
        );
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// 防连点：await 网络往返期间四档按钮仍在屏（remote 慢网必现连点），
  /// 无重入保护时同一张卡会提交 N 条评分、FSRS 调度推进 N 次——
  /// 直接造成「界面显示与库不对齐」。评分后乐观推进（先走 UI 再补传），
  /// 4xx 仍按原设计不阻塞学习循环（仅气泡提示）。
  bool _rating = false;

  Future<void> _rate(ReviewRating rating) async {
    if (_rating || _index >= _cards.length) return;
    _rating = true;
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
      // 4xx 真错误：不阻塞学习循环，直接下一张
      if (mounted) {
        // 2026-09-06：轻提示统一顶部气泡（快速淡化 + 底色随机氛围），替换灰色 SnackBar
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
        _revealed = false;
        _revealedAt = DateTime.now();
      });
    }
    _rating = false;
    // P1 语义保留：联网恢复后立即追平离线积压（原为每次评分前置 await，
    // 现改评分后 fire-and-forget——不拖慢 UI 推进；flush 内部自捕获网络异常）
    unawaited(ApiClient.instance.flushPendingAnswers());
  }

  // 回炉（与待审核池拒绝/题库详情回炉共用 ReasonActionDialog，强绑定同一版式）
  // #9：底部面板承载（isScrollControlled + viewInsets 键盘安全，见组件头注释）
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
                _revealed = false;
              });
              // #10②：duplicate=true 幂等重复（该卡已在回炉队列——多半在别处
              // 已提交过）——提示明确文案，不暴露内部 id；卡已出复习队列照常跳过
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
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 待补传角标：SessionStore 由 app.dart 经 ChangeNotifierProvider 注入
    final pending = context.watch<SessionStore>().pendingCount;

    return Scaffold(
      appBar: AppBar(
        title: const Text('复习'),
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
            onPressed: _index < _cards.length && _revealed ? _rework : null,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          // 错误态补实「下拉刷新」交互（原文案称可下拉，此前并无 RefreshIndicator）
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
          : _buildCard(scheme),
    );
  }

  Widget _buildCard(ColorScheme scheme) {
    final card = _cards[_index];
    return Column(
      children: [
        LinearProgressIndicator(
          value: (_index + 1) / _cards.length,
          minHeight: 3,
          backgroundColor: scheme.surfaceContainerHighest,
        ),
        // 离线缓存回退提示条（队列来自缓存时可见——断网冷启动续背的明确标记）
        if (_cacheAt != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: OfflineDataBar(savedAt: _cacheAt),
          ),
        Expanded(
          child: GestureDetector(
            onTap: () {
              if (!_revealed) {
                setState(() {
                  _revealed = true;
                  _revealedAt = DateTime.now();
                });
              }
            },
            child: Card(
              margin: const EdgeInsets.all(16),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _TypeChip(type: card.type),
                          const Spacer(),
                          Text(
                            '#${_index + 1}/${_cards.length}',
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.outline,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        card.front,
                        style: const TextStyle(
                          fontSize: 20,
                          height: 1.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 24),
                      if (!_revealed)
                        Center(
                          child: Text(
                            '想一想，点卡片翻面',
                            style: TextStyle(
                              fontSize: 13,
                              color: scheme.outline,
                            ),
                          ),
                        ),
                      if (_revealed) ...[
                        const Divider(),
                        const SizedBox(height: 12),
                        Text(
                          card.back,
                          style: const TextStyle(fontSize: 16, height: 1.6),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            _MetaChip(
                              icon: Icons.anchor,
                              label: '锚点 ${card.anchor}',
                            ),
                            _MetaChip(
                              icon: Icons.menu_book_outlined,
                              label: card.source,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (_revealed)
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  Expanded(
                    child: _RateButton(
                      label: '重来',
                      color: scheme.errorContainer,
                      fg: scheme.onErrorContainer,
                      onPressed: () => _rate(ReviewRating.again),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _RateButton(
                      label: '困难',
                      color: scheme.tertiaryContainer,
                      fg: scheme.onTertiaryContainer,
                      onPressed: () => _rate(ReviewRating.hard),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _RateButton(
                      label: '良好',
                      color: scheme.primaryContainer,
                      fg: scheme.onPrimaryContainer,
                      onPressed: () => _rate(ReviewRating.good),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _RateButton(
                      label: '简单',
                      color: scheme.secondaryContainer,
                      fg: scheme.onSecondaryContainer,
                      onPressed: () => _rate(ReviewRating.easy),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
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
        color: Theme.of(context).colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSecondaryContainer,
        ),
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
        Icon(icon, size: 14, color: Theme.of(context).colorScheme.outline),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

class _RateButton extends StatelessWidget {
  const _RateButton({
    required this.label,
    required this.color,
    required this.fg,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final Color fg;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: fg,
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      onPressed: onPressed,
      child: Text(label),
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
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          const Text('该科目暂无到期卡', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('审核池通过的新卡才会出现', style: TextStyle(fontSize: 12)),
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
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          const Text('本批复习完成！', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('剩下的卡在未来的记忆曲线里等你', style: TextStyle(fontSize: 12)),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: () => context.pop(),
            child: const Text('返回'),
          ),
        ],
      ),
    );
  }
}
