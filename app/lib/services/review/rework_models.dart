import 'dart:convert';
import 'package:crypto/crypto.dart';

const reworkActions = ['rewrite', 'split', 'defer', 'exclude'];
String reworkActionLabel(String action) => switch (action) {
  'rewrite' => '改写 / 纠错',
  'split' => '一拆多',
  'defer' => '暂缓（手动恢复）',
  'exclude' => '排除此卡',
  _ => action,
};
String reworkStatusLabel(String status) => switch (status) {
  'queued' => '待生成',
  'generating' => '处理中',
  'needs_input' => '需要你补充',
  'draft' => '草案待确认',
  'applied' => '已应用',
  'deferred' => '已暂缓',
  'excluded' => '已排除',
  'cancelled' => '已撤销',
  _ => status,
};
String reworkStageLabel(String stage) => switch (stage) {
  'evidence' => '检索与选择证据',
  'generation' => '生成修复草案',
  'review' => '等待人工确认',
  _ => reworkStatusLabel(stage),
};
const reworkReasonLabels = [
  '表述绕',
  '题干歧义',
  '拆太粗',
  '拆分不当',
  '重复卡',
  '答案有误',
  '锚点失效',
  '记不住',
  '超出教学范围',
  '目前还没学到',
  '其他',
];
List<Map<String, Object?>> reworkIssues(String reason) {
  final labels = reason
      .replaceFirst('审核拒绝：', '')
      .split(RegExp(r'[、,，;；]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toSet()
      .take(8)
      .toList();
  if (labels.isEmpty) labels.add('其他');
  return [
    for (var i = 0; i < labels.length; i++) {'id': 'i$i', 'label': labels[i]},
  ];
}

String suggestReworkAction(String reason) {
  if (reason.contains('还没学') || reason.contains('暂未')) return 'defer';
  if (reason.contains('超出教学范围') ||
      reason.contains('超纲') ||
      reason.contains('重复卡')) {
    return 'exclude';
  }
  if (reason.contains('拆太粗') ||
      (reason.contains('拆分不当') && !reason.contains('太细'))) {
    return 'split';
  }
  return 'rewrite';
}

String reworkEvidenceHash(Map evidence) => sha256
    .convert(
      utf8.encode(
        jsonEncode([
          evidence['chunkId'],
          evidence['subjectId'],
          evidence['sourceType'],
          evidence['deck'],
          evidence['pageRange'],
          evidence['title'],
          evidence['text'],
        ]),
      ),
    )
    .toString();
String reworkAnchor(Map evidence) =>
    '${evidence['deck'] ?? '原文'} p${evidence['pageRange'] ?? '?'}';
String _normalized(String text) => text.replaceAll(RegExp(r'\s+'), '').trim();

/// 对模型/人工草案使用同一套结构校验。绝不以原卡补空字段或原样回写。
Map<String, Object?> validateReworkDraft({
  required Map raw,
  required String action,
  required int targetCount,
  required Map original,
  required List<Map<String, Object?>> evidence,
  required List<Map<String, Object?>> issues,
}) {
  if (raw['action'] != action) throw const FormatException('处理动作与已确认方案不一致');
  if (action != 'rewrite' && action != 'split') {
    throw const FormatException('暂缓和排除不应调用 AI 生成');
  }
  final cards = raw['cards'];
  final expected = action == 'split' ? targetCount : 1;
  if (expected < 1 ||
      expected > 5 ||
      (action == 'split' && expected < 2) ||
      cards is! List ||
      cards.length != expected) {
    throw FormatException('当前方案要求 $expected 张草案，不能原样退回或更改数量');
  }
  final byId = {for (final e in evidence) e['chunkId'].toString(): e};
  final output = <Map<String, Object?>>[];
  final fronts = <String>{};
  for (final item in cards) {
    if (item is! Map) throw const FormatException('草案卡格式无效');
    if (item['front'] is! String || item['back'] is! String) {
      throw const FormatException('题干和答案必须为文字');
    }
    final front = (item['front'] as String).trim();
    final back = (item['back'] as String).trim();
    if (front.isEmpty ||
        back.isEmpty ||
        front.length > 2000 ||
        back.length > 12000) {
      throw const FormatException('题干或答案为空 / 超过长度限制');
    }
    if (!fronts.add(_normalized(front))) {
      throw const FormatException('子卡题干重复，请拆成独立考点');
    }
    final ids = item['evidenceChunkIds'];
    if (ids is! List ||
        ids.isEmpty ||
        ids.length > 6 ||
        ids.any((id) => id is! String || !byId.containsKey(id))) {
      throw const FormatException('每张草案必须引用证据池中的有效原文');
    }
    final unique = ids.cast<String>().toSet().toList();
    final anchor = unique.map((id) => reworkAnchor(byId[id]!)).join('；');
    if (_normalized(front) ==
            _normalized(original['front']?.toString() ?? '') &&
        _normalized(back) == _normalized(original['back']?.toString() ?? '') &&
        (action == 'split' ||
            !issues.every(
              (i) => (i['label']?.toString() ?? '').contains('锚点'),
            ) ||
            anchor == (original['anchor']?.toString() ?? ''))) {
      throw const FormatException('没有实际修复，不能把原卡标为完成');
    }
    output.add({
      'front': front,
      'back': back,
      'anchor': anchor,
      'source': '回炉引用：$anchor',
      'sourceTier': byId[unique.first]!['sourceType'] == 'textbook'
          ? 'textbook'
          : 'ppt',
      'evidenceChunkIds': unique,
    });
  }
  final resultRows = raw['issueResults'];
  if (resultRows is! List || resultRows.length != issues.length) {
    throw const FormatException('必须逐项说明每个拒绝理由是否解决');
  }
  final seen = <String>{};
  final results = <Map<String, Object?>>[];
  for (final row in resultRows) {
    if (row is! Map ||
        row['id'] is! String ||
        row['resolved'] is! bool ||
        !issues.any((i) => i['id'] == row['id']) ||
        !seen.add(row['id'] as String)) {
      throw const FormatException('理由验收结果不完整或重复');
    }
    if (row['explanation'] is! String) throw const FormatException('修复说明必须为文字');
    final explanation = (row['explanation'] as String).trim();
    if (explanation.isEmpty || explanation.length > 2000) {
      throw const FormatException('每项理由需要可核验的修复说明');
    }
    results.add({
      'id': row['id'],
      'resolved': row['resolved'],
      'explanation': explanation,
    });
  }
  final summary = raw['summary'] ?? '';
  if (summary is! String || summary.length > 2000) {
    throw const FormatException('修复摘要无效或过长');
  }
  return {
    'action': action,
    'cards': output,
    'issueResults': results,
    'summary': summary.trim(),
  };
}
