// 原因操作弹窗（公共组件）：双列理由网格 + 补充说明 + 参数化确认按钮。
// 「拒绝（待审核池）」与「回炉重造（题库详情/复习会话）」强绑定共用同一版式——
// 同一套「选理由 → 补充说明 → 确认」交互：两条人工反馈通道视觉与行为完全一致，
// 都通向 AI 回炉改卡闭环（拒绝理由/回炉原因都会登记进 rework_queue，次日拆卡读到）。
// 参数化：标题/副标题/理由列表/输入框提示/按钮文案颜色图标/未选提示/确认回调。
// 行为对齐原待审核池拒绝弹窗：未选理由 → TopToast 提示；确认 → 先关弹窗再执行
// onConfirm（API 调用与成败提示归调用方）。
// 2026-09-06 真机问题整改（P0 白屏防御 + 多选改造）：
//  · 理由改多选且勾选后可取消（原单选不可取消）：onConfirm 收到的 reason
//    为多个 label 按「、」连接（后端只存 reason 字符串，拼接无兼容性问题）；
//  · 空选提示节流 1200ms：真机连点「确认」多次 → 每击重发 toast；且弹窗
//    pop 过渡中的击键可能带着失活 context 进 TopToast.show（白屏根因之一，
//    节流顺带压低该竞态窗口——另见 top_toast.dart 的容错改造）。
// 2026-09-07 键盘安全改造（真机问题 #9）：
//  · 旧版是居中 Dialog：输入法弹出时面板被顶起，但提交按钮的命中区不随视觉
//    位移（错位点不动，须收起键盘才可点）。现改为底部面板版式：调用方一律以
//    showModalBottomSheet(isScrollControlled: true) 承载（见 bank_page/
//    review_page/pending_page 三入口），本组件读 viewInsets.bottom 做真实
//    布局位移（Padding 属布局而非动画位移）——确认按钮随键盘上移、钉在键盘
//    上方的安全区，任意键盘状态下视觉位置与命中区一致。
import 'package:flutter/material.dart';

import '../theme.dart';
import 'top_toast.dart';

/// 回炉原因（题库详情页与复习会话共用；与拒绝理由刻意不同——
/// 回炉面向「这张卡怎么改好」，拒绝面向「这张卡为什么不合格」）
const List<(String, String)> kReworkReasons = [
  ('表述绕', '题干读几遍才能懂'),
  ('拆太粗', '一张卡考了多个点'),
  ('答案有误', '与 PPT/课堂讲授不符'),
  ('锚点失效', '找不到出处'),
  ('记不住', '背了很多次还是忘'),
  ('其他', '自由补充'),
];

/// 原因操作弹窗：reasons 为 (label, sub) 记录列表，onConfirm 收 (reason, note)。
class ReasonActionDialog extends StatefulWidget {
  const ReasonActionDialog({
    super.key,
    required this.title,
    required this.subtitle,
    required this.reasons,
    required this.noteHint,
    required this.buttonLabel,
    required this.emptyReasonToast,
    required this.onConfirm,
    this.buttonColor = HengyaColors.danger,
    this.buttonIcon = Icons.close_rounded,
  });

  final String title;
  final String subtitle;
  final List<(String, String)> reasons;
  final String noteHint;
  final String buttonLabel;
  final String emptyReasonToast;
  final Color buttonColor;
  final IconData buttonIcon;
  final Future<void> Function(String reason, String note) onConfirm;

  @override
  State<ReasonActionDialog> createState() => _ReasonActionDialogState();
}

class _ReasonActionDialogState extends State<ReasonActionDialog> {
  // 多选（LinkedHashSet 保持勾选顺序，确认时按「、」连接传 onConfirm）
  final Set<String> _reasons = {};
  final _noteCtrl = TextEditingController();
  bool _submitting = false;
  // 空选提示节流（白屏防御之一）：1200ms 窗内重复点击不重发 toast——
  // 真机连点「确认」每次重发；且 pop 过渡中的击键带着失活 context 进
  // TopToast.show 是白屏根因之一，节流顺带压低该竞态窗口。
  DateTime? _lastEmptyToastAt;
  static const _emptyToastThrottle =
      Duration(milliseconds: 1200); // 与 toast stayDuration 同拍

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    if (_reasons.isEmpty) {
      final now = DateTime.now();
      final last = _lastEmptyToastAt;
      if (last == null ||
          now.difference(last) >= _emptyToastThrottle) {
        _lastEmptyToastAt = now;
        TopToast.show(
          context,
          widget.emptyReasonToast,
          type: TopToastType.error,
          stayDuration: const Duration(milliseconds: 1200),
        );
      }
      return;
    }
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final reason = _reasons.join('、'); // 多选按勾选顺序拼接
      if (mounted) Navigator.pop(context);
      await widget.onConfirm(reason, _noteCtrl.text.trim());
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // 理由选格：双列网格铺满行宽（消除固定宽芯片导致的右侧空洞），
  // 每格尾随状态图标；行/列间距 8，奇数收尾补占位保持等宽。
  // 多选：再点已勾选格即取消（toggle add/remove）
  void _toggleReason(String label) => setState(() {
        if (!_reasons.remove(label)) _reasons.add(label);
      });

  Widget _buildReasonGrid() {
    final rows = <Widget>[];
    for (var i = 0; i < widget.reasons.length; i += 2) {
      final cells = <Widget>[
        Expanded(
          child: _ReasonCell(
            label: widget.reasons[i].$1,
            sub: widget.reasons[i].$2,
            selected: _reasons.contains(widget.reasons[i].$1),
            onTap: () => _toggleReason(widget.reasons[i].$1),
          ),
        ),
      ];
      if (i + 1 < widget.reasons.length) {
        cells
          ..add(const SizedBox(width: 8))
          ..add(
            Expanded(
              child: _ReasonCell(
                label: widget.reasons[i + 1].$1,
                sub: widget.reasons[i + 1].$2,
                selected: _reasons.contains(widget.reasons[i + 1].$1),
                onTap: () => _toggleReason(widget.reasons[i + 1].$1),
              ),
            ),
          );
      } else {
        cells.add(const Expanded(child: SizedBox()));
      }
      rows.add(Row(children: cells));
      if (i + 2 < widget.reasons.length) {
        rows.add(const SizedBox(height: 8));
      }
    }
    return Column(children: rows);
  }

  @override
  Widget build(BuildContext context) {
    // 键盘安全（#9）：viewInsets.bottom 做真实布局位移——键盘弹出时整块内容
    // （含确认按钮）上移钉在键盘上方；Padding 是布局而非动画/Transform 位移，
    // 命中区随视觉同步移动，任意键盘状态下按钮可直接点中。
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: kCardSoftShadow,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                style: const TextStyle(
                  fontSize: 12,
                  color: HengyaColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              _buildReasonGrid(),
              const SizedBox(height: 12),
              TextField(
                controller: _noteCtrl,
                maxLines: 2,
                decoration: InputDecoration(
                  hintText: widget.noteHint,
                  isDense: true,
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: widget.buttonColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  icon: Icon(widget.buttonIcon, size: 18),
                  label: _submitting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Text(widget.buttonLabel),
                  onPressed: _submitting ? null : _confirm,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 理由选格（原待审核池拒绝理由格原样迁移：双列铺满半行宽，消除固定宽芯片的
/// 右侧空洞；尾随状态图标——未选空心圈、选中品牌蓝实心勾）
class _ReasonCell extends StatelessWidget {
  const _ReasonCell({
    required this.label,
    required this.sub,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final String sub;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque, // 整格可点（含留白），命中不漏
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? HengyaColors.brand : HengyaColors.divider,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? scheme.onPrimaryContainer
                          : HengyaColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                  size: 16,
                  color: selected ? HengyaColors.brand : HengyaColors.divider,
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: HengyaColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
