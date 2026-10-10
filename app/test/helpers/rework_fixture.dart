// 测试专用：真实 SQLite 证据 + 草案 + 人工应用，不绕开新工作台协议。
import 'dart:convert';
import 'dart:io';
import 'package:sqlite3/sqlite3.dart';
import 'package:hengya/services/local/corpus/extract_all.dart'
    show ensureCorpusSchema;
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/db.dart';

void seedReworkEvidence(
  Database db, {
  String id = 'r1',
  String subject = 'endo',
  String deck = '回炉章',
  int start = 30,
  int end = 32,
}) {
  ensureCorpusSchema(db);
  db.execute(
    'INSERT OR REPLACE INTO chunks(chunk_id,subject_id,ppt_id,deck,page_start,page_end,title,text,source_type) VALUES (?,?,?,?,?,?,?,?,?)',
    [
      id,
      subject,
      'fixture-$id',
      deck,
      start,
      end,
      '修复依据',
      '修正后的定义、病因与临床表现。',
      'textbook',
    ],
  );
}

Map<String, Object?> validReworkDraft(
  Map task, {
  List<Map<String, Object?>>? cards,
  String front = '重写后的题干',
  String back = '重写后的答案',
  String? evidenceId,
}) => {
  'action': task['action'],
  'cards':
      cards ??
      [
        {
          'front': front,
          'back': back,
          'evidenceChunkIds': [
            evidenceId ?? ((task['evidence'] as List).first as Map)['chunkId'],
          ],
        },
      ],
  'issueResults': [
    for (final i in task['issues'] as List)
      {'id': (i as Map)['id'], 'resolved': true, 'explanation': '已逐项对照原文修正'},
  ],
  'summary': '修复摘要',
};
String validReworkLlm(
  String payload, {
  String? evidenceId,
  String front = '重写后的回炉题干',
  String back = '重写后的三点答案',
}) => jsonEncode(
  validReworkDraft(
    jsonDecode(payload) as Map,
    evidenceId: evidenceId,
    front: front,
    back: back,
  ),
);

Future<Map<String, dynamic>> applyTestRewrite(
  LocalBackend backend,
  int id, {
  String front = '重写后的题干',
  String back = '重写后的答案',
}) async {
  var task = await backend.get('/rework/tasks/$id');
  final file = File('${backend.dataDir}/corpus/corpus.db');
  file.parent.createSync(recursive: true);
  final corpus = sqlite3.open(file.path);
  final evidenceId = 'fixture-task-$id';
  try {
    seedReworkEvidence(
      corpus,
      id: evidenceId,
      subject: task['subjectId'] as String,
    );
  } finally {
    corpus.dispose();
  }
  await backend.post('/rework/tasks/$id/configure', {
    'revision': task['revision'],
    'action': 'rewrite',
    'instructions': '按证据修改',
    'targetCount': 2,
    'selectedIds': [evidenceId],
  });
  task = await backend.get('/rework/tasks/$id');
  await backend.post('/rework/tasks/$id/draft', {
    'revision': task['revision'],
    'draft': validReworkDraft(
      task,
      front: front,
      back: back,
      evidenceId: evidenceId,
    ),
  });
  task = await backend.get('/rework/tasks/$id');
  final result = await backend.post('/rework/tasks/$id/apply', {
    'revision': task['revision'],
    'resetMemory': true,
    'confirmedIssues': [
      for (final i in task['issues'] as List) (i as Map)['id'],
    ],
  });
  return {
    ...result,
    'card': (await backend.sharedDb)
        .cardById(task['cardId'] as String)!
        .toJson(),
  };
}

Future<void> cancelTestRework(LocalBackend backend, String cardId) async {
  final db = await backend.sharedDb;
  final id = db.activeReworkTask(cardId)!;
  final task = db.getReworkTask(id)!;
  await backend.post('/rework/tasks/$id/cancel', {
    'revision': task['revision'],
  });
}
