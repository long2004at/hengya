import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/hengya_shared.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:hengya/services/local/db.dart';
import 'package:hengya/services/local/pipeline_runner.dart';
import 'package:hengya/services/local/corpus/run_engine.dart';
import 'package:hengya/services/local/corpus/run_llm.dart' show LlmChatFn;
import 'package:hengya/services/local/corpus/rework_evidence.dart';
import 'helpers/rework_fixture.dart';

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }
  late Directory temp;
  late Db db;
  late Database corpus;
  setUp(() async {
    temp = Directory.systemTemp.createTempSync('hengya-rework-engine-');
    db = await Db.open('${temp.path}/hengya.db');
    db.insertSubject(id: 'endo', name: '课程');
    db.importCard(
      const FlashCard(
        id: 'parent',
        subjectId: 'endo',
        type: CardType.basic,
        front: '旧题干',
        back: '旧答案',
        anchor: '旧出处',
        source: '课程',
        status: CardStatus.active,
      ),
    );
    corpus = sqlite3.openInMemory();
    seedReworkEvidence(corpus, id: 'e1');
  });
  tearDown(() {
    corpus.dispose();
    db.close();
    temp.deleteSync(recursive: true);
  });
  Map<String, Object?> hit(String id) => {
    'chunk_id': id,
    'subject_id': 'endo',
    'deck': '课本',
    'source_type': 'textbook',
    'page_range': '1',
    'text': '原文',
    'score': .95,
  };
  Future<Map<String, Object?>> search(
    String q, {
    String? subject,
    String? sourceType,
    int? k,
  }) async => {
    'results': [hit('e1')],
  };
  Future<List<Map<String, Object?>>> run(
    LlmChatFn llm, {
    RunSearchFn? lookup,
  }) => processRework(
    runSearch: lookup ?? search,
    llmChat: llm,
    prompts: {},
    queue: [for (final q in db.reworkPending()) Map<String, Object?>.from(q)],
    aiNotes: [],
    subjectNames: {'endo': '课程'},
    opts: const RunOptions(),
    port: LocalDbPort(db, corpusDb: corpus),
  );
  int task(
    String action, {
    String reason = '答案有误',
    String instructions = '',
    int count = 2,
  }) => db.createReworkTask(
    'parent',
    action: action,
    reasons: [reason],
    instructions: instructions,
    targetCount: count,
  );
  test('模型只生成草案，不调用旧 done 或修改正式卡片', () async {
    final id = task('rewrite');
    final result = await run(
      (system, user, {tag = ''}) async => validReworkLlm(user),
    );
    expect(result.single['draft'], true);
    expect(result.single['saved'], true);
    expect(result.single['done'], false);
    expect(db.cardById('parent')!.front, '旧题干');
    expect(db.getReworkTask(id)!['status'], 'draft');
  });
  test('一拆多严格按用户数量生成独立子卡草案', () async {
    final id = task('split', reason: '拆太粗', count: 3);
    await run((system, user, {tag = ''}) async {
      final input = jsonDecode(user) as Map;
      expect(input['targetCount'], 3);
      return jsonEncode(
        validReworkDraft(
          input,
          cards: [
            for (var i = 0; i < 3; i++)
              {
                'front': '独立考点$i',
                'back': '答案$i',
                'evidenceChunkIds': ['e1'],
              },
          ],
        ),
      );
    });
    final draft = db.getReworkTask(id)!['draft'] as Map;
    expect(draft['cards'] as List, hasLength(3));
    expect(db.cardById('parent')!.front, '旧题干');
  });
  for (final action in ['defer', 'exclude']) {
    test('$action 不进入自动回炉队列，直接传入演练流程也不调用模型', () async {
      task(action, reason: action == 'defer' ? '目前还没学到' : '超出教学范围');
      expect(db.reworkPending(), isEmpty);
      var calls = 0;
      final result = await processRework(
        runSearch: search,
        llmChat: (s, u, {tag = ''}) async {
          calls++;
          return '{}';
        },
        prompts: {},
        queue: [
          {'id': 1, 'action': action, 'front': '旧题干', 'back': '旧答案'},
        ],
        aiNotes: [],
        subjectNames: {},
        opts: const RunOptions(dryRun: true),
      );
      expect(calls, 0);
      expect(result.single['needsInput'], true);
      expect(result.single['done'], false);
    });
  }
  test('无证据时不调用模型，不以原卡冒充新草案', () async {
    final id = task('rewrite');
    var calls = 0;
    await run((s, u, {tag = ''}) async {
      calls++;
      return '{}';
    }, lookup: (q, {subject, sourceType, k}) async => {'results': <Object>[]});
    expect(calls, 0);
    expect(db.getReworkTask(id)!['status'], 'needs_input');
    expect(db.reworkPending(), isEmpty);
    expect(db.cardById('parent')!.back, '旧答案');
  });
  for (final bad in ['not-json', '{}']) {
    test('畸形结果 $bad 停止并等待用户，不再自动重复尝试', () async {
      final id = task('rewrite');
      var calls = 0;
      final result = await run((s, u, {tag = ''}) async {
        calls++;
        return bad;
      });
      expect(result.single['needsInput'], true);
      expect(db.getReworkTask(id)!['draft'], isNull);
      await run((s, u, {tag = ''}) async {
        calls++;
        return bad;
      });
      expect(calls, 1);
      expect(db.cardById('parent')!.front, '旧题干');
    });
  }
  test('仅改变出处不能宣称修复了错误答案', () async {
    final id = task('rewrite');
    await run(
      (s, u, {tag = ''}) async => jsonEncode(
        validReworkDraft(jsonDecode(u) as Map, front: '旧题干', back: '旧答案'),
      ),
    );
    expect(db.getReworkTask(id)!['status'], 'needs_input');
    expect(db.getReworkTask(id)!['draft'], isNull);
  });
  test('用户固定证据和针对理由的检索证据不会被普通结果挤掉', () async {
    final id = task('rewrite', instructions: '特殊纠错词');
    for (final id in [
      'pin',
      'base',
      for (var i = 0; i < 6; i++) 'book$i',
      for (var i = 0; i < 6; i++) 'ppt$i',
    ]) {
      seedReworkEvidence(corpus, id: id);
    }
    db.configureRework(
      id,
      1,
      action: 'rewrite',
      instructions: '特殊纠错词',
      targetCount: 2,
      selected: readReworkEvidence(corpus, 'endo', ['pin']),
    );
    await run(
      (s, u, {tag = ''}) async {
        final input = jsonDecode(u) as Map;
        final ids = (input['evidence'] as List)
            .map((e) => (e as Map)['chunkId'])
            .toList();
        expect(ids.first, 'pin');
        expect(ids, hasLength(12));
        expect(ids, contains('book0'));
        expect(ids, contains('ppt0'));
        expect(ids, isNot(contains('base')));
        return validReworkLlm(u);
      },
      lookup: (q, {subject, sourceType, k}) async => {
        'results': q.contains('特殊纠错词')
            ? [
                for (var i = 0; i < 6; i++)
                  hit('${sourceType == 'textbook' ? 'book' : 'ppt'}$i'),
              ]
            : [hit('base')],
      },
    );
    expect(db.getReworkTask(id)!['status'], 'draft');
  });
  test('生成中更新方案，迟到结果不能覆盖新版本', () async {
    final id = task('rewrite');
    final entered = Completer<void>();
    final result = Completer<String>();
    late String payload;
    final running = run((s, u, {tag = ''}) {
      payload = u;
      entered.complete();
      return result.future;
    });
    await entered.future;
    db.configureRework(
      id,
      1,
      action: 'defer',
      instructions: '用户改为暂缓',
      targetCount: 2,
      selected: [],
    );
    result.complete(validReworkLlm(payload));
    final reports = await running;
    expect(reports.single['stale'], true);
    expect(reports.single['draft'], false);
    final current = db.getReworkTask(id)!;
    expect(current['action'], 'defer');
    expect(current['draft'], isNull);
    expect(current['status'], 'needs_input');
    expect(db.cardById('parent')!.front, '旧题干');
  });
  test('资源提示词与代码兜底回炉段严格同步', () {
    final asset = File(
      'assets/prompts/主跑-22-55-server.md',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    const begin = '<!-- run-prompt:rework:start -->';
    const end = '<!-- run-prompt:rework:end -->';
    final text = asset
        .substring(asset.indexOf(begin) + begin.length, asset.indexOf(end))
        .trim();
    expect(kFallbackPrompts['rework']!.replaceAll('\r\n', '\n'), text);
  });
  test('伪造证据编号不会获得有效草案或覆盖原卡', () async {
    final id = task('rewrite');
    await run(
      (system, user, {tag = ''}) async => jsonEncode(
        validReworkDraft(
          jsonDecode(user) as Map,
          evidenceId: 'not-in-evidence',
        ),
      ),
    );
    expect(db.getReworkTask(id)!['status'], 'needs_input');
    expect(db.getReworkTask(id)!['draft'], isNull);
    expect(db.cardById('parent')!.front, '旧题干');
  });
  test('模型仍有未解决理由时保留草案供修改，但不能标记为可应用', () async {
    final id = task('rewrite');
    final result = await run((system, user, {tag = ''}) async {
      final draft = validReworkDraft(jsonDecode(user) as Map);
      ((draft['issueResults'] as List).first as Map)['resolved'] = false;
      return jsonEncode(draft);
    });
    expect(result.single['needsInput'], true);
    final t = db.getReworkTask(id)!;
    expect(t['status'], 'needs_input');
    expect(t['draft'], isNotNull);
    expect(db.reworkPending(), isEmpty);
  });
}
