// 原文证据弹层 —— 复习页锚点/来源 chip 点开后的「答案出处原文」。
//
// 数据链：卡片 anchor（deck名 p页码区间，流水线 composeAnchor 产物）→
// GET /api/v1/evidence?subject=&deck=&pageStart=&pageEnd= → 语料库 chunks
// 反查。尽力而为：查不到（无本地库/demo/旧服务器/证据已失效）显示兜底提示，
// 绝不抛错打断复习流。内容只放该卡锚点页码区间的原文块（≤6 块，弱相关不堆砌），
// 单块超长默认折叠，点「展开全文」看完整原文。
import 'package:flutter/material.dart';

import '../services/api/api_client.dart';

/// 单块证据超长折叠阈值（字符）；以内直接全文显示
const int _kFoldThreshold = 600;
/// 折叠态预览字符数
const int _kFoldPreview = 280;

/// 打开原文证据弹层（复习页/今日复习页共用入口）。
/// [anchor] 为卡片锚点原文（如「龋病概述 p12-15」），未解析出 deck 时弹层
/// 直接显示「未找到原文」兜底说明。
Future<void> showEvidenceSheet(
  BuildContext context, {
  required String subjectId,
  required String anchor,
  required String source,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (_) => _EvidenceSheet(
      subjectId: subjectId,
      anchor: anchor,
      source: source,
    ),
  );
}

class _EvidenceSheet extends StatefulWidget {
  const _EvidenceSheet({
    required this.subjectId,
    required this.anchor,
    required this.source,
  });

  final String subjectId;
  final String anchor;
  final String source;

  @override
  State<_EvidenceSheet> createState() => _EvidenceSheetState();
}

class _EvidenceSheetState extends State<_EvidenceSheet> {
  late Future<List<Map<String, Object?>>> _future;

  @override
  void initState() {
    super.initState();
    _future = ApiClient.instance.fetchCardEvidence(widget.subjectId, widget.anchor);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.9,
      builder: (context, scrollCtrl) => Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // 拖拽把手 + 标题
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: scheme.outlineVariant,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Icon(Icons.menu_book_outlined,
                          size: 18, color: scheme.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '原文证据',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '锚点 ${widget.anchor.isEmpty ? '（无锚点）' : widget.anchor} · ${widget.source}',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const Divider(height: 16),
            // 内容区
            Expanded(
              child: FutureBuilder<List<Map<String, Object?>>>(
                future: _future,
                builder: (context, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  final list = snap.data ?? const [];
                  if (list.isEmpty) return _emptyView(scheme);
                  return ListView.builder(
                    controller: scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                    itemCount: list.length,
                    itemBuilder: (context, i) => _EvidenceCard(
                      evidence: list[i],
                      index: i,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 兜底：无本地库 / 旧服务器 / 证据已失效（旧卡 chunkId 失效属预期）
  Widget _emptyView(ColorScheme scheme) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_outlined, size: 44, color: scheme.outline),
            const SizedBox(height: 12),
            const Text(
              '未找到对应的语料原文',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            Text(
              '可能原因：尚未导入语料库、该卡来自旧版语料库（证据已失效）、'
              '或当前为远程模式（原文在服务器）。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: scheme.outline, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// 单块证据卡：元信息头（来源/页码/小节）+ 原文（长文折叠）
class _EvidenceCard extends StatefulWidget {
  const _EvidenceCard({required this.evidence, required this.index});

  final Map<String, Object?> evidence;
  final int index;

  @override
  State<_EvidenceCard> createState() => _EvidenceCardState();
}

class _EvidenceCardState extends State<_EvidenceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = (widget.evidence['text'] as String?) ?? '';
    final deck = (widget.evidence['deck'] as String?) ?? '';
    final title = (widget.evidence['title'] as String?) ?? '';
    final pageRange = (widget.evidence['pageRange'] as String?) ?? '';
    final sourceType = (widget.evidence['sourceType'] as String?) ?? '';
    final isTextbook = sourceType == 'textbook';
    final tooLong = text.length > _kFoldThreshold;
    final display = (_expanded || !tooLong)
        ? text
        : '${text.substring(0, _kFoldPreview)}…';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 元信息头
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: isTextbook
                        ? scheme.tertiaryContainer
                        : scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isTextbook ? '教材' : 'PPT',
                    style: TextStyle(
                      fontSize: 11,
                      color: isTextbook
                          ? scheme.onTertiaryContainer
                          : scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [
                      if (deck.isNotEmpty) deck,
                      if (pageRange.isNotEmpty) 'p$pageRange',
                    ].join(' · '),
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.index == 0)
                  Text(
                    '出卡依据',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
            if (title.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 8),
            SelectableText(
              display,
              style: TextStyle(
                fontSize: 14,
                height: 1.7,
                color: scheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
            if (tooLong) ...[
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                  ),
                  label: Text(_expanded ? '收起' : '展开全文（${text.length} 字）'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
