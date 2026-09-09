// 进度页「章节管理」弹层（⑨ 需求 4：推进课程 + 去除科目章节的集成窗口）：
// 列出该科全部章节（章名来自罗盘数据源 toc sidecar → progress.json），
// 每章三态（已学/待学/不学）+ 两操作：
//   a) 「已学到此」：把 learned_through 直接推进到该章（支持任意位置；
//      目标 < 当前指针 = 回退，必须先弹确认对话框说明影响）；
//   b) 「不学/恢复」：切换该章 skip——被标记的章从有效总量与「下一章」
//      计算中剔除（跳过章视同未学，不进周扫真题池）。
// 数据面：GET/PUT /api/v1/progress/<subject>/chapters（local 实装 / demo
// 演示态 / remote 旧服务器 404 → 错误态提示）。写成功后即时刷新弹层与
// 底下进度页（onChanged 回调）。
// 与既有机制共存：入箱 study-log 流水线推进照旧（两端读-改-写同一
// progress.json，缺省字段不动）；手动推进走 manual history（evidence
// 注明「章节管理推进/回退」），与流水线 auto history 区分可审计。
import 'package:flutter/material.dart';

import '../services/api/api_client.dart';
import '../theme.dart';
import '../widgets/top_toast.dart';

/// 打开章节管理弹层。[p] 为进度页当前单科快照；[subjectName] 展示名；
/// [onChanged] 写成功后回调（进度页刷新罗盘）。
Future<bool?> showChapterManagerSheet(
  BuildContext context, {
  required SubjectProgress p,
  required String subjectName,
  required Future<void> Function() onChanged,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _ChapterManagerSheet(
      p: p,
      subjectName: subjectName,
      onChanged: onChanged,
    ),
  );
}

class _ChapterManagerSheet extends StatefulWidget {
  const _ChapterManagerSheet({
    required this.p,
    required this.subjectName,
    required this.onChanged,
  });

  final SubjectProgress p;
  final String subjectName;
  final Future<void> Function() onChanged;

  @override
  State<_ChapterManagerSheet> createState() => _ChapterManagerSheetState();
}

class _ChapterManagerSheetState extends State<_ChapterManagerSheet> {
  SubjectChapters? _data;
  String? _error;
  bool _busy = false; // 单飞守卫：任一写操作进行中禁止并发写

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await ApiClient.instance.fetchSubjectChapters(widget.p.id);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.statusCode == 404
            ? (currentBackendMode == BackendMode.local
                  ? '该科目尚无学习罗盘数据'
                  : '需服务器 0.5.0+（章节管理端点暂未部署）')
              : '加载失败：${e.message}';
      });
    }
  }

  /// 统一写入口：成功 → 重读弹层数据 + 通知进度页刷新；失败 → 气泡提示。
  Future<void> _apply({
    int? learnedThrough,
    List<int>? skipped,
    required String successNote,
  }) async {
    if (_busy || _data == null) return;
    setState(() => _busy = true);
    try {
      await ApiClient.instance.updateSubjectChapters(
        widget.p.id,
        learnedThrough: learnedThrough,
        skipped: skipped,
      );
      if (!mounted) return;
      TopToast.show(context, successNote);
      await _load();
      await widget.onChanged(); // 底下进度页即时刷新（罗盘/总量/下一章）
    } on ApiException catch (e) {
      if (!mounted) return;
      TopToast.show(context, '操作失败：${e.message}', type: TopToastType.error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 「已学到此」：目标 ≥ 当前指针直接推进；目标 < 当前指针 = 回退，
  /// 必须先确认（说明影响：已学章回到待学、罗盘与复习提示按新进度计算、
  /// 操作记入进度历史）。
  Future<void> _setLearnedThrough(SubjectChapterStatus ch) async {
    final data = _data;
    if (data == null || _busy) return;
    if (ch.no == data.learnedThrough) return; // 原地：无操作
    if (ch.no < data.learnedThrough) {
      final confirmed = await _confirmRollback(ch, data);
      if (confirmed != true) return;
      await _apply(
        learnedThrough: ch.no,
        successNote: '已回退到「${ch.title}」',
      );
      return;
    }
    await _apply(
      learnedThrough: ch.no,
      successNote: '已学到「${ch.title}」',
    );
  }

  Future<bool?> _confirmRollback(
    SubjectChapterStatus ch,
    SubjectChapters data,
  ) {
    final back = data.learnedThrough - ch.no;
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('回退学习进度'),
        content: Text(
          '将把「${widget.subjectName}」的学习进度从第 ${data.learnedThrough} 章'
          '回退到第 ${ch.no} 章（${ch.title}）。\n\n'
          '影响：$back 个已学章节将回到待学状态，学习罗盘、'
          '复习提示与周扫范围按新进度计算。此操作会记入进度历史。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认回退'),
          ),
        ],
      ),
    );
  }

  /// 「不学/恢复」：切换跳过——剔出有效总量与「下一章」。
  Future<void> _toggleSkip(SubjectChapterStatus ch) {
    final data = _data;
    if (data == null || _busy) return Future.value();
    final next = ch.skipped
        ? data.skipped.where((n) => n != ch.no).toList()
        : [...data.skipped, ch.no]..sort();
    return _apply(
      skipped: next,
      successNote: ch.skipped ? '已恢复「${ch.title}」' : '已标记「${ch.title}」不学',
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.72,
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              subjectName: widget.subjectName,
              textbook: data?.textbook ?? widget.p.textbook,
              summary: data == null
                  ? null
                  : '已学 ${data.effectiveLearned} / 有效 ${data.effectiveTotal} 章'
                        '${data.skipped.isEmpty ? '' : ' · 不学 ${data.skipped.length} 章'}'
                        '（共 ${data.total} 章）',
            ),
            const Divider(height: 1, color: HengyaColors.divider),
            if (_error != null && data == null)
              Expanded(child: _ErrorView(message: _error!, onRetry: _load))
            else if (data == null)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else
              Expanded(
                child: _busy && _error == null
                    ? const Center(child: CircularProgressIndicator())
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 16),
                        itemCount: data.chapters.length,
                        itemBuilder: (_, i) => _ChapterRow(
                          ch: data.chapters[i],
                          isPointer: data.chapters[i].no == data.learnedThrough,
                          busy: _busy,
                          onLearnedThrough: () => _setLearnedThrough(
                            data.chapters[i],
                          ),
                          onToggleSkip: () => _toggleSkip(data.chapters[i]),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 弹层头：拖拽条 + 科目名 + 教材名 + 有效统计摘要
class _Header extends StatelessWidget {
  const _Header({
    required this.subjectName,
    required this.textbook,
    required this.summary,
  });

  final String subjectName;
  final String? textbook;
  final String? summary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: HengyaColors.divider,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.format_list_numbered,
                  size: 18, color: HengyaColors.brand),
              const SizedBox(width: 6),
              Text(
                '章节管理 · $subjectName',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: HengyaColors.textPrimary,
                ),
              ),
            ],
          ),
          if (textbook != null && textbook!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              textbook!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                color: HengyaColors.textSecondary,
              ),
            ),
          ],
          if (summary != null) ...[
            const SizedBox(height: 6),
            Text(
              summary!,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: HengyaColors.brand,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 单章行：状态图标 + 章名（+当前指针标记）+「已学到此」/「不学·恢复」
class _ChapterRow extends StatelessWidget {
  const _ChapterRow({
    required this.ch,
    required this.isPointer,
    required this.busy,
    required this.onLearnedThrough,
    required this.onToggleSkip,
  });

  final SubjectChapterStatus ch;
  final bool isPointer; // 当前指针所在章（「已学到此」原地禁用）
  final bool busy;
  final VoidCallback onLearnedThrough;
  final VoidCallback onToggleSkip;

  @override
  Widget build(BuildContext context) {
    final titleColor = ch.skipped
        ? HengyaColors.textSecondary
        : ch.learned
        ? HengyaColors.textSecondary
        : HengyaColors.textPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          _statusIcon(),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  ch.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: ch.learned && !ch.skipped
                        ? FontWeight.w500
                        : FontWeight.w400,
                    color: titleColor,
                    decoration: ch.skipped ? TextDecoration.lineThrough : null,
                    decorationColor: HengyaColors.textSecondary,
                  ),
                ),
                if (isPointer)
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Text(
                      '当前进度',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: HengyaColors.brand,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          TextButton(
            onPressed: busy || isPointer ? null : onLearnedThrough,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
            ),
            child: const Text('已学到此', style: TextStyle(fontSize: 12)),
          ),
          TextButton(
            onPressed: busy ? null : onToggleSkip,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, 32),
              foregroundColor: ch.skipped
                  ? HengyaColors.brand
                  : HengyaColors.textSecondary,
            ),
            child: Text(ch.skipped ? '恢复' : '不学', style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _statusIcon() {
    if (ch.skipped) {
      return const Icon(Icons.block, size: 18, color: HengyaColors.textSecondary);
    }
    if (ch.learned) {
      return const Icon(Icons.check_circle, size: 18, color: HengyaColors.success);
    }
    return const Icon(Icons.radio_button_unchecked,
        size: 18, color: HengyaColors.divider);
  }
}

/// 加载/拉取失败态（旧服务器 404 等）：提示 + 重试
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off_outlined,
              size: 40, color: HengyaColors.divider),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: HengyaColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: 14),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
