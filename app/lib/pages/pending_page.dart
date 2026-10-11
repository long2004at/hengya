// 待审核池 —— 自动化生成卡的质量硬闸门（M1）
// 每日拆卡先进池 → 逐张 批准（进复习队列）/ 编辑（改后保留）/ 拒绝（退回）
// 对齐设计稿 03 屏：计数胶囊 + 三键卡片流
import 'package:flutter/material.dart';
import 'package:shared/hengya_shared.dart';

import '../services/api/api_client.dart';
import '../theme.dart';
import '../widgets/reason_action_dialog.dart';
import 'rework_request_sheet.dart';
import 'rework_workbench_page.dart';
import '../widgets/top_toast.dart';

class PendingPage extends StatefulWidget {
  const PendingPage({super.key});

  @override
  State<PendingPage> createState() => _PendingPageState();
}

class _PendingPageState extends State<PendingPage> {
  bool _creatingRework = false;
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
        _cards.addAll([
          for (final c in cards)
            if (!known.contains(c.id)) c,
        ]);
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
    // 视觉重构（2026-10-11 整体质感）：头部改品牌蓝渐变（呼应首页 Hero），
    // 深色底自然压住下方内容，形成「稳重厚重」的第一层视觉锚点。
    return Scaffold(
      backgroundColor: scheme.surfaceContainerLow,
      appBar: AppBar(
        title: const Text('待审核池'),
        flexibleSpace: Container(
          decoration: const BoxDecoration(gradient: kHeroGradient),
        ),
        foregroundColor: Colors.white,
        titleTextStyle: const TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
        actions: [
          if (currentBackendMode == BackendMode.local)
            IconButton(
              tooltip: '回炉草案与任务',
              icon: const Icon(Icons.build_circle_outlined, color: Colors.white),
              onPressed: () async {
                await Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ReworkWorkbenchPage(),
                  ),
                );
                if (mounted) _load();
              },
            ),
          if (_cards.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                // 计数徽章厚重化：白底 10% 半透明 + 白描边 + 柔影，浮于渐变之上
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: HengyaColors.brandDeep.withValues(alpha: 0.35),
                        offset: const Offset(0, 3),
                        blurRadius: 8,
                      ),
                    ],
                  ),
                  child: Text(
                    _total > _cards.length
                        ? '${_cards.length}/$_total 张待审'
                        : '${_cards.length} 张待审',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
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
                // 视觉重构：水平留白 20 + 底部 28，给卡影留出呼吸空间
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
                // #15 分页：列表末尾追加「加载更多」（还有剩余时）
                itemCount: _cards.length + (_hasMore ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(height: 14),
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
  Future<void> _openReject(FlashCard card) async {
    if (currentBackendMode == BackendMode.local) {
      if (_creatingRework) return;
      _creatingRework = true;
      try {
        final task = await requestReworkTask(context, card);
        if (task != null && mounted) {
          await _load();
          if (mounted) {
            await Navigator.of(context, rootNavigator: true).push(
              MaterialPageRoute<void>(
                builder: (_) => ReworkWorkbenchPage(taskId: task),
              ),
            );
          }
          if (mounted) await _load();
        }
      } finally {
        _creatingRework = false;
      }
      return;
    }
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
        // 删除整卡（2026-09-13）：待审卡物理删除（区别于「拒绝」的柔性
        // 反馈通道——彻底不要这张卡），理由随删除进日志
        deleteLabel: '删除整卡（不可恢复）',
        onDelete: (reason, note) async {
          try {
            await ApiClient.instance.removeCard(
              card.id,
              reason: reason,
              note: note,
            );
            if (mounted) {
              TopToast.show(context, '已删除整卡', type: TopToastType.success);
            }
            await _load();
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
    // 视觉重构（2026-10-11 整体质感）：白卡承载在「底层柔影 + 顶部品牌色条」
    // 的厚重容器上——柔影让卡浮出底色，色条与头部渐变同源，保持全页一体感。
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          // 底层柔影：品牌深蓝调，下沉感（呼应 kCardSoftShadow，略加重）
          BoxShadow(
            color: HengyaColors.brandDeep.withValues(alpha: 0.10),
            offset: const Offset(0, 8),
            blurRadius: 24,
          ),
          // 贴地硬影：勾勒卡片轮廓，强化「纸叠在桌上」的厚度
          BoxShadow(
            color: const Color(0x1A000000),
            offset: const Offset(0, 2),
            blurRadius: 4,
          ),
        ],
      ),
      child: Card(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 顶部品牌色条：与 AppBar 渐变同源的 4px 深蓝条，
              // 是卡片与头部「同一视觉体系」的锚点
              Container(height: 4, color: HengyaColors.brand),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _badgesRow(typeLabel, scheme),
                    // 标签行（原挤在标识行尾，挤压徽标、有无不定——移到独立行固定展示）
                    if (card.tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          card.tags.join(' · '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.3,
                            color: scheme.outline,
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Text(
                      card.front,
                      style: const TextStyle(
                        fontSize: 16,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                        color: HengyaColors.textPrimary,
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
                            style: TextStyle(
                              fontSize: 11,
                              color: scheme.outline,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    // #11：疑似重复卡并排对比（新卡 vs 已有卡），方便人工裁决
                    if (card.dupCheck == 'dup') ...[
                      const SizedBox(height: 12),
                      _DupCompare(
                        newCard: card,
                        oldCard: dupTarget,
                        oldCardId: card.dupOf ?? '',
                      ),
                    ],
                  ],
                ),
              ),
              // 操作区（视觉重构）：浅底嵌板承托三键——与白色正文区形成
              // 明暗对比、边界分明，但仍在同一张卡内，不散成孤立 UI
              Container(
                width: double.infinity,
                decoration: const BoxDecoration(
                  color: Color(0xFFF7F8FA),
                  border: Border(top: BorderSide(color: Color(0xFFE4E8EF))),
                ),
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        label: '批准',
                        icon: Icons.check_rounded,
                        onPressed: onApprove,
                        style: _ActionButtonStyle.approve,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ActionButton(
                        label: '编辑',
                        icon: Icons.edit_outlined,
                        onPressed: onEdit,
                        style: _ActionButtonStyle.neutral,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _ActionButton(
                        label: '拒绝',
                        icon: Icons.close_rounded,
                        onPressed: onReject,
                        style: _ActionButtonStyle.reject,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 标识行（标识规范化改造，2026-10-11）：三类标识各占一个固定槽位、
  /// 每槽必有内容——无值时显示灰色「—」占位，保证所有卡头版式完全一致：
  ///   槽1 卡型 ｜ 槽2 来源层级（PPT/教材/真题） ｜ 槽3 查重（疑似重复/未查重/已查重）
  /// 查重需人工关注，槽 3 非中性态时加强调色。
  Widget _badgesRow(String typeLabel, ColorScheme scheme) {
    const placeholder = '—';
    final tierLabel = switch (card.sourceTier) {
      SourceTier.ppt => 'PPT',
      SourceTier.exam => '真题',
      SourceTier.textbook => '教材',
      SourceTier.user => placeholder,
    };
    final dupNeutral = card.dupCheck != 'dup' && card.dupCheck != 'skipped';
    return Row(
      children: [
        _BadgeChip(label: typeLabel, color: scheme.secondaryContainer),
        const SizedBox(width: 6),
        _BadgeChip(label: tierLabel, color: scheme.tertiaryContainer),
        const SizedBox(width: 6),
        _BadgeChip(
          label: switch (card.dupCheck) {
            'dup' => '疑似重复',
            'skipped' => '未查重',
            _ => '已查重',
          },
          color: dupNeutral
              ? scheme.surfaceContainerHighest
              : const Color(0xFFFDE8E8),
          foregroundColor: dupNeutral
              ? scheme.onSurfaceVariant
              : const Color(0xFFD54941),
          emphasized: !dupNeutral,
        ),
      ],
    );
  }
}

/// 统一规格徽标（标识规范化改造，2026-10-11）：待审核卡头所有标识共用
/// 同一芯片版式（字号 11 / 同内边距 / 同圆角），差异只在配色与字重。
/// 视觉重构：加 1px 半透明边线，让芯片在白底上也有清晰的界面感。
class _BadgeChip extends StatelessWidget {
  const _BadgeChip({
    required this.label,
    required this.color,
    this.foregroundColor,
    this.emphasized = false,
  });

  final String label;
  final Color color;
  final Color? foregroundColor;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: (foregroundColor ?? HengyaColors.textSecondary).withValues(
            alpha: 0.18,
          ),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          height: 1.4,
          fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
          color: foregroundColor,
        ),
      ),
    );
  }
}

/// 操作按钮语义（视觉重构 2026-10-11）：批准=品牌蓝（主行动）/ 编辑=白底
/// 描边（中性）/ 拒绝=警示红（破坏性）。
enum _ActionButtonStyle { approve, neutral, reject }

/// 卡片操作三键（视觉重构 2026-10-11）：实底 + 下沉硬影的立体按钮——
/// 主行动最重、中性次之、破坏性红底，权重一眼可辨且不依赖颜色单一维度。
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.style,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;
  final _ActionButtonStyle style;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg, Color border) = switch (style) {
      _ActionButtonStyle.approve => (
        HengyaColors.brand,
        Colors.white,
        Colors.transparent,
      ),
      _ActionButtonStyle.neutral => (
        Colors.white,
        HengyaColors.textSecondary,
        HengyaColors.divider,
      ),
      _ActionButtonStyle.reject => (
        HengyaColors.danger,
        Colors.white,
        Colors.transparent,
      ),
    };
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
            boxShadow: [
              // 下沉硬影：按钮「立」在嵌板上的厚度感
              BoxShadow(
                color: bg == Colors.transparent
                    ? const Color(0x14000000)
                    : bg.withValues(alpha: 0.28),
                offset: const Offset(0, 2),
                blurRadius: 4,
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 17, color: fg),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
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
      // 视觉重构：白底描边胶囊 + 柔影，与卡片语言一致（浅色嵌板承托操作）
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: HengyaColors.divider),
          boxShadow: kCardSoftShadow,
        ),
        child: TextButton.icon(
          style: TextButton.styleFrom(
            foregroundColor: HengyaColors.brand,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          ),
          onPressed: loading ? null : onTap,
          icon: loading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.expand_more_rounded, size: 18),
          label: Text(loading ? '加载中…' : '加载更多'),
        ),
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
    // 视觉重构：对比面板改「下沉内嵌」质感——深色底 + 内描边，
    // 与操作区嵌板同一语言（浅色嵌板承托、面板内凹承内容）。
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: highlight ? const Color(0xFFFDECEC) : scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: highlight
                ? const Color(0xFFD54941).withValues(alpha: 0.25)
                : HengyaColors.divider,
          ),
          boxShadow: highlight
              ? [
                  BoxShadow(
                    color: const Color(0xFFD54941).withValues(alpha: 0.08),
                    offset: const Offset(0, 2),
                    blurRadius: 6,
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.3,
                color: highlight ? const Color(0xFFD54941) : scheme.outline,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              front,
              style: const TextStyle(
                fontSize: 13,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: HengyaColors.textPrimary,
              ),
            ),
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
        _pane(context, '这张（新卡）', newCard.front, newCard.back, highlight: true),
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
    // 视觉重构：白卡 + 柔影承载空态，与列表卡片同一视觉语言，
    // 避免空态「孤零零漂在底色上」的割裂感。
    return Center(
      child: Container(
        margin: const EdgeInsets.all(32),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: HengyaColors.divider),
          boxShadow: kCardSoftShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.verified_outlined,
              size: 52,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            const Text(
              '审核池已清空',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              currentBackendMode == BackendMode.local
                  ? '拆卡流水线运行后新卡会送来审核（设置页「强制开始拆卡」可立即触发）'
                  : '每日 22:55 自动化拆卡后会推送新卡来审',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: HengyaColors.textSecondary,
              ),
            ),
          ],
        ),
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
    // 视觉重构：错误态与空态同一视觉语言（白卡 + 柔影），保持整页质感统一
    return Center(
      child: Container(
        margin: const EdgeInsets.all(32),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: HengyaColors.divider),
          boxShadow: kCardSoftShadow,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.wifi_off_outlined,
              size: 44,
              color: HengyaColors.textSecondary,
            ),
            const SizedBox(height: 12),
            const Text(
              '拉取待审核卡失败',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}
