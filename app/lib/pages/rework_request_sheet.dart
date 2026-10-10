import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared/hengya_shared.dart';
import '../services/api/api_client.dart';
import '../services/review/rework_models.dart';
import '../widgets/top_toast.dart';

/// 弹层只收集选择；调用者 await 真正创建完成后才移动卡片，避免先关弹层的异步竞态。
Future<int?> requestReworkTask(BuildContext context, FlashCard card) async {
  final note = TextEditingController();
  final reasons = <String>{};
  var action = 'rewrite';
  var count = 2;
  var chosenAction = false;
  String? error;
  Map<String, Object?>? request;
  try {
    request = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * .78,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    '交给回炉工作台',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          card.front,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 12),
                        const Text('这张卡有什么问题？'),
                        Wrap(
                          spacing: 8,
                          children: [
                            for (final reason in reworkReasonLabels)
                              FilterChip(
                                label: Text(reason),
                                selected: reasons.contains(reason),
                                onSelected: (on) => set(() {
                                  if (on) {
                                    if (reasons.length < 8) reasons.add(reason);
                                  } else {
                                    reasons.remove(reason);
                                  }
                                  if (!chosenAction) {
                                    action = suggestReworkAction(
                                      reasons.join('、'),
                                    );
                                  }
                                }),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          key: ValueKey(action),
                          initialValue: action,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: '希望怎样处理',
                          ),
                          items: [
                            for (final a in reworkActions)
                              DropdownMenuItem(
                                value: a,
                                child: Text(reworkActionLabel(a)),
                              ),
                          ],
                          onChanged: (v) => set(() {
                            action = v!;
                            chosenAction = true;
                          }),
                        ),
                        if (action == 'split')
                          DropdownButtonFormField<int>(
                            initialValue: count,
                            decoration: const InputDecoration(
                              labelText: '拆成几张独立考点卡',
                            ),
                            items: [
                              for (var n = 2; n <= 5; n++)
                                DropdownMenuItem(value: n, child: Text('$n 张')),
                            ],
                            onChanged: (v) => set(() => count = v!),
                          ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: note,
                          minLines: 2,
                          maxLines: 5,
                          maxLength: 4000,
                          decoration: const InputDecoration(
                            labelText: '补充说明 / 正确方向',
                            hintText: '例如：按教材纠正定义；分别拆成病因和表现两张卡',
                          ),
                        ),
                        Text(
                          action == 'exclude'
                              ? '只排除此卡，不设置课程级禁出规则，不删除学习资料。'
                              : action == 'defer'
                              ? '暂停这张卡，之后在工作台手动恢复；不改变记忆参数。'
                              : '先保存原卡快照，生成的只是草案；你确认后才应用。',
                        ),
                        if (error != null)
                          Text(
                            error!,
                            style: TextStyle(
                              color: Theme.of(ctx).colorScheme.error,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton(
                      onPressed: () {
                        if (reasons.isEmpty) {
                          set(() => error = '至少选择一个问题');
                          return;
                        }
                        Navigator.pop(ctx, {
                          'action': action,
                          'reasons': reasons.toList(),
                          'instructions': note.text.trim(),
                          'targetCount': count,
                        });
                      },
                      child: const Text('创建任务并查看'),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  } finally {
    // 弹层关闭动画期间仍可能重建 TextField（用到本 controller）——延迟到下一帧
    // 之后再释放，避免「TextEditingController was used after being disposed」。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      note.dispose();
    });
  }
  if (request == null || !context.mounted) return null;
  final navigator = Navigator.of(context, rootNavigator: true);
  final progress = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('正在登记修复任务'),
          ],
        ),
      ),
    ),
  );
  unawaited(navigator.push(progress));
  try {
    final result = await ApiClient.instance.createReworkTask(
      card.id,
      action: request['action'] as String,
      reasons: (request['reasons'] as List).cast<String>(),
      instructions: request['instructions'] as String,
      targetCount: request['targetCount'] as int,
    );
    if (result.alreadyExists && context.mounted) {
      if (progress.isActive) navigator.removeRoute(progress);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: const Text('该卡已有回炉任务'),
          content: SelectableText(
            '已保留现有方案，本次填写没有覆盖原任务。请在工作台编辑原任务。\n\n本次说明（未保存，可复制）：\n${request!['instructions']}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('查看原任务'),
            ),
          ],
        ),
      );
    }
    return result.taskId;
  } catch (e) {
    if (context.mounted) {
      TopToast.show(context, '登记失败：$e', type: TopToastType.error);
    }
    return null;
  } finally {
    if (navigator.mounted && progress.isActive) navigator.removeRoute(progress);
  }
}
