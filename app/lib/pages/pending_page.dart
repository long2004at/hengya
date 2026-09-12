// 待审核池 —— 自动化生成卡的质量硬闸门（M1）
// 每日拆卡先进池 → 逐张 批准（进复习队列）/ 编辑（改后保留）/ 拒绝（退回）
// 对齐设计稿 03 屏：计数胶囊 + 三键卡片流
import 'package:flutter/material.dart';
import 'package:shared/hengya_shared.dart';

import '../services/api/api_client.dart';
import '../widgets/reason_action_dialog.dart';
import '../widgets/top_toast.dart';

class PendingPage extends StatefulWidget {
  const PendingPage({super.key});

  @override
  State<PendingPage> createState() => _PendingPageState();
}

class _PendingPageState extends State<PendingPage> {
  static const int _pageSize = 100;

  List<FlashCard> _cards = [];
  final Map<String, FlashCard> _dupTargets = {}; // #11 dupOf → 已有卡（对比视图）
  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  bool get _hasMore => _cards.length < _total;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// #11：拉取疑似重复卡的指向目标（并排对比用）；单张失败不阻塞列表
  Future<void> _loadDupTargets(List<FlashCard> cards) async {
    final ids = {
      for (final c in cards)
        if (c.dupCheck == 'dup' && (c.dupOf?.isNotEmpty ?? false)) c.dupOf!,
    };
    for (final id in ids) {
      if (_dupTargets.containsKey(id)) continue;
      try {
        final bank = await ApiClient.instance.fetchCardById(id);
        _dupTargets[id] = bank.card;
      } on ApiException catch (_) {
        // 目标卡可能已被移除：对比区降级显示 id
      }
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final (cards, total) = await ApiClient.instance.fetchPendingCards(
        limit: _pageSize,
      );
      await _loadDupTargets(cards);
      if (!mounted) return;
      setState(() {
        _cards = cards;
        _total = total;
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  /// #15 分页：加载下一页（原 100 张硬截断会把 created_at 较旧的回炉完成
  /// 卡挤出待审池，形成审核区/题库两端都找不到的假性丢卡）。
  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final (cards, total) = await ApiClient.instance.fetchPendingCards(
        limit: _pageSize,
        offset: _cards.length,
      );
      await _loadDupTargets(cards);
      if (!mounted) return;
      setState(() {
        final known = _cards.map((c) => c.id).toSet();
        _cards.addAll([for (final c in cards) if (!known.contains(c.id)) c]);
        _total = total;
        _loadingMore = false;
      });
    } on ApiException catch (e) {
      setState(() => _loadingMore = false);
      if (mounted) {
        TopToast.show(
          context,
          '加载更多失败：${e.message}',
          type: TopToastType.error,
          stayDuration: const Duration(milliseconds: 1800),
        );
      }
    }
  }

  Future<void> _act(Future<void> Function() action, String okMsg) async {
    try {
      await action();
      if (mounted) {
        TopToast.show(context, okMsg, type: TopToastType.success);
      }
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        TopToast.show(
          context,
          '操作失败：${e.message}',
          type: TopToastType.error,
          stayDuration: const Duration(milliseconds: 1800),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('待审核池'),
        actions: [
          if (_cards.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _total > _cards.length
                        ? '${_cards.length}/$_total 张待审'
                        : '${_cards.length} 张待审',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorState(message: _error!, onRetry: _load)
          : _cards.isEmpty
          ? const _EmptyPool()
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView.separated(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                // #15 分页：列表末尾追加「加载更多」（还有剩余时）
                itemCount: _cards.length + (_hasMore ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, i) {
                  if (i >= _cards.length) {
                    return _LoadMoreTile(
                      hasMore: _hasMore,
                      loading: _loadingMore,
                      onTap: _loadMore,
                    );
                  }
                  final card = _cards[i];
                  return _PendingCard(
                    card: card,
                    dupTarget: card.dupOf == null
                        ? null
                        : _dupTargets[card.dupOf],
                    onApprove: () => _act(
                      () => ApiClient.instance.approveCard(card.id),
                      '已批准进复习队列',
                    ),
                    onEdit: () => _openEditor(card),
                    onReject: () => _openReject(card),
                  );
                },
              ),
            ),
    );
  }

  // 拒绝弹窗（设计稿 03b：六理由 + 自由输入 + 确认拒绝；
  // 理由会登记进回炉队列，次日拆卡 AI 会读到——与回炉弹窗共用同一公共组件）
  // #9：底部面板承载（isScrollControlled + viewInsets 键盘安全，见组件头注释）
  void _openReject(FlashCard card) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (dlgCtx) => ReasonActionDialog(
        title: '拒绝这张卡',
        subtitle: '理由会交给 AI，帮助下次拆得更好',
        reasons: const [
          ('答案有误', '与教材/课堂讲授不符'),
          ('题干歧义', '读不懂在问什么'),
          ('拆分不当', '太粗或太细'),
          ('重复卡', '已有类似卡片'),
          ('超出教学范围', '课堂没讲过'),
          ('其他', '自由补充说明'),
        ],
        noteHint: '补充说明（可选）',
        buttonLabel: '确认拒绝',
        emptyReasonToast: '先选至少一个拒绝理由',
        onConfirm: (reason, note) async {
          try {
            await ApiClient.instance.rejectCard(
              card.id,
              reason: reason,
              note: note,
            );
            if (mounted) {
              TopToast.show(
                context,
                '已拒绝；理由已交给 AI（次日拆卡可见）',
                type: TopToastType.info,
                stayDuration: const Duration(milliseconds: 1200),
              );
            }
            await _load();
          } on ApiException catch (e) {
            if (mounted) {
              TopToast.show(
                context,
                '操作失败：${e.message}',
                type: TopToastType.error,
                stayDuration: const Duration(milliseconds: 1800),
              );
            }
          }
        },
      ),
    );
  }

  void _openEditor(FlashCard card) {
    final frontCtrl = TextEditingController(text: card.front);
    final backCtrl = TextEditingController(text: card.back);
    final anchorCtrl = TextEditingController(text: card.anchor);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetCtx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '编辑卡片',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: frontCtrl,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '题干',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: backCtrl,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '答案',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: anchorCtrl,
                decoration: const InputDecoration(
                  labelText: '锚点（PPT 页码/章节）',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              // 保存按钮：自带 loading/防重/空输入校验；
              // 失败保留弹层并显示真实错误，成功关闭弹层并刷新列表
              _EditorSaveButton(
                cardId: card.id,
                frontCtrl: frontCtrl,
                backCtrl: backCtrl,
                anchorCtrl: anchorCtrl,
                onSaved: () async {
                  if (sheetCtx.mounted) Navigator.pop(sheetCtx);
                  await _load();
                  if (mounted) {
                    TopToast.show(
                      context,
                      '已保存修改（仍在待审核池）',
                      type: TopToastType.success,
                    );
                  }
                },
                onError: (msg) {
                  if (sheetCtx.mounted) {
                    TopToast.show(
                      sheetCtx,
                      '保存失败：$msg',
                      type: TopToastType.error,
                      stayDuration: const Duration(milliseconds: 1800),
                    );
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 保存按钮（自带 loading/防重/空输入校验）
class _EditorSaveButton extends StatefulWidget {
  const _EditorSaveButton({
    required this.cardId,
    required this.frontCtrl,
    required this.backCtrl,
    required this.anchorCtrl,
    required this.onSaved,
    required this.onError,
  });

  final String cardId;
  final TextEditingController frontCtrl;
  final TextEditingController backCtrl;
  final TextEditingController anchorCtrl;
  final Future<void> Function() onSaved;
  final void Function(String msg) onError;

  @override
  State<_EditorSaveButton> createState() => _EditorSaveButtonState();
}

class _EditorSaveButtonState extends State<_EditorSaveButton> {
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    final front = widget.frontCtrl.text.trim();
    final back = widget.backCtrl.text.trim();
    final anchor = widget.anchorCtrl.text.trim();
    if (front.isEmpty || back.isEmpty) {
      widget.onError('题干和答案不能为空');
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiClient.instance.editPendingCard(
        widget.cardId,
        front: front,
        back: back,
        anchor: anchor,
      );
      await widget.onSaved();
    } on ApiException catch (e) {
      if (mounted) setState(() => _saving = false);
      widget.onError(e.message);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      widget.onError('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: _saving ? null : _save,
        child: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('保存（保持待审核）'),
      ),
    );
  }
}

class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.card,
    required this.onApprove,
    required this.onEdit,
    required this.onReject,
    this.dupTarget,
  });

  final FlashCard card;
  final FlashCard? dupTarget; // #11：疑似重复指向的已有卡（并排对比）
  final VoidCallback onApprove;
  final VoidCallback onEdit;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final typeLabel = switch (card.type) {
      CardType.basic => '问答',
      CardType.cloze => '填空',
      CardType.caseChain => '病例',
      CardType.image => '图像',
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    typeLabel,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
                // 教材兜底标识（批4 节点①）：sourceTier=textbook 的卡证据来自
                // 教材树（ppt 主源未命中后的兜底检索）——同款徽标风格、
                // tertiaryContainer 配色与类型徽标区分。
                if (card.sourceTier == SourceTier.textbook) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.tertiaryContainer,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '教材',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
                // #11 查重徽标（用户要求标识明显）：红=疑似重复；橙=未查重降级
                if (card.dupCheck == 'dup') ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFDE8E8),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '疑似重复',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFD54941),
                      ),
                    ),
                  ),
                ],
                if (card.dupCheck == 'skipped') ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFF3E0),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      '未查重',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFE37318),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                if (card.tags.isNotEmpty)
                  Expanded(
                    child: Text(
                      card.tags.take(3).join(' · '),
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              card.front,
              style: const TextStyle(
                fontSize: 16,
                height: 1.4,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              card.back,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.anchor, size: 13, color: scheme.outline),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    '${card.anchor} · ${card.source}',
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            // #11：疑似重复卡并排对比（新卡 vs 已有卡），方便人工裁决
            if (card.dupCheck == 'dup')
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _DupCompare(
                  newCard: card,
                  oldCard: dupTarget,
                  oldCardId: card.dupOf ?? '',
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: scheme.primaryContainer,
                      foregroundColor: scheme.onPrimaryContainer,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    icon: const Icon(Icons.check_rounded, size: 18),
                    label: const Text('批准'),
                    onPressed: onApprove,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    icon: const Icon(Icons.edit_outlined, size: 18),
                    label: const Text('编辑'),
                    onPressed: onEdit,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      foregroundColor: scheme.error,
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    icon: const Icon(Icons.close_rounded, size: 18),
                    label: const Text('拒绝'),
                    onPressed: onReject,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// #15 分页：加载更多入口（超出首页 100 张的待审卡由此带出）
class _LoadMoreTile extends StatelessWidget {
  const _LoadMoreTile({
    required this.hasMore,
    required this.loading,
    required this.onTap,
  });

  final bool hasMore;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: FilledButton.tonal(
        onPressed: loading ? null : onTap,
        child: loading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('加载更多'),
      ),
    );
  }
}

/// #11：疑似重复并排对比（左=这张新卡，右=已有卡；目标卡被移除时降级显示 id）
class _DupCompare extends StatelessWidget {
  const _DupCompare({
    required this.newCard,
    required this.oldCard,
    required this.oldCardId,
  });

  final FlashCard newCard;
  final FlashCard? oldCard;
  final String oldCardId;

  Widget _pane(
    BuildContext context,
    String title,
    String front,
    String back, {
    bool highlight = false,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: highlight
              ? const Color(0xFFFDE8E8)
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: highlight ? const Color(0xFFD54941) : scheme.outline,
              ),
            ),
            const SizedBox(height: 6),
            Text(front, style: const TextStyle(fontSize: 13, height: 1.35)),
            const SizedBox(height: 6),
            Text(
              back,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _pane(context, '这张（新卡）', newCard.front, newCard.back,
            highlight: true),
        const SizedBox(width: 8),
        oldCard != null
            ? _pane(context, '已有卡', oldCard!.front, oldCard!.back)
            : Expanded(
                child: Text(
                  '已有卡 $oldCardId 暂不可比（可能已被移除）',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ),
      ],
    );
  }
}

class _EmptyPool extends StatelessWidget {
  const _EmptyPool();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.verified_outlined,
            size: 56,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 12),
          const Text('审核池已清空', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            currentBackendMode == BackendMode.local
                ? '拆卡流水线运行后新卡会送来审核（设置页「强制开始拆卡」可立即触发）'
                : '每日 22:55 自动化拆卡后会推送新卡来审',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

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
            const Text(
              '拉取待审核卡失败',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
