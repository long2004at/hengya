// 恒牙（hengya）· Phase 4 pipeline_runner 六步总编排测试
// ============================================================================
//
// 语义基准：automation/server-pipeline/run.py cmd_main_catchup L1590-1752
//（六步契约全流程）+ _assemble_result counts 口径（report.py 消费结构）。
//
// 测试姿势：fake 检索/LLM（脚本化分派）+ **真实临时 hengya.db** 全链——
// import/consume/reworkDone 落库为真实 SQLite 行为（LocalDbPort 直连，
// 与生产 App 实装同一条链路），progress.json 真文件落盘断言。触发幂等与
// 标志消费（≈force-check.sh）经 LocalBackend.pipelineKick /
// PipelineRunner.runOnceOverride 注入缝驱动。
// #16 罗盘懒初始化：条目缺失 + toc sidecar 在 → catchup 开跑自动 init
// 后推进链可用（dry-run 跳过零落盘；条目在场幂等不重刷）。
//
// 本文件为纯 dart test（非 testWidgets）：真实异步 IO 合法（假异步纪律
// 仅约束 widget 测试）；Windows 宿主 sqlite3.dll 加载同 local_backend_test。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/local/corpus/progress_db.dart'
    show emptyProgress, loadProgress, progressEntryOf;
import 'package:hengya/services/local/corpus/run_engine.dart'
    show RunOptions, SearchException;
import 'package:hengya/services/local/corpus/run_llm.dart' show LlmException;
import 'package:hengya/services/local/corpus/search_api.dart'
    show kEmbedApiUrl, normalizeEmbedEndpoint;
import 'package:hengya/services/local/db.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/hengya_shared.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Windows 测试宿主：显式加载 test/sqlite3.dll（同 local_backend_test 教训）
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_pipeline_test_');
  });

  tearDown(() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.pipelineKick = null;
    PipelineRunner.instance.runOnceOverride = null;
    PipelineRunner.instance.lastResult = null;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<Db> openDb() => Db.open('${tmp.path}/hengya.db');

  /// endo 罗盘：三章，learned_through=1（当前章=第一章）。
  Map<String, Object?> endoProgress() => <String, Object?>{
    'version': 1,
    'subjects': <String, Object?>{
      'endo': {
        'textbook': '世界通史-第2版',
        'chapters': [
          {'no': 1, 'title': '第一章 概述', 'page_start': 1},
          {'no': 2, 'title': '第二章 启蒙思想', 'page_start': 20},
          {'no': 3, 'title': '第三章 龋病', 'page_start': 40},
        ],
        'learned_through': 1,
        'updated_at': '2026-09-06T08:00:00',
        'history': <Object?>[],
      },
    },
  };

  Map<String, Object?> hit(
    String cid,
    String deck,
    String title,
    String pr,
    double score, {
    String sourceType = 'ppt',
  }) => {
    'chunk_id': cid,
    'deck': deck,
    'page_range': pr,
    'title': title,
    'source_type': sourceType,
    'subject_id': 'endo',
    'text': '正文：龋病四联因素相关内容。',
    'score': score,
  };

  test('六步总编排 fake 全链：分流→罗盘→studylog 推进→拆卡→import→consume→回炉→计数', () async {
    final db = await openDb();
    addTearDown(db.close);

    // 0.3.1 开源去内置：内置科目不再由迁移播种——测试自建科目（与生产
    // 「新建课程」/db.insertSubject 同源；拆卡/回炉链需要科目在场）。
    db.insertSubject(id: 'endo', name: '通史');

    // 种子：关键词 + 学习记录 + 回炉队列（active 卡 + AI 留言）
    db.insertKeyword(
      subjectId: 'endo',
      keyword: '龋病四联因素',
      source: 'chat',
      note: '',
    );
    final slId = db.insertKeyword(
      subjectId: 'endo',
      keyword: '第三章 龋病',
      source: 'study-log',
      note: '',
    );
    db.importCard(
      FlashCard(
        id: 'endo-orig-001',
        subjectId: 'endo',
        type: CardType.basic,
        front: '原始回炉题干',
        back: '原始答案',
        anchor: '绪论 p1',
        source: '课程 PPT',
        status: CardStatus.pending,
      ),
    );
    db.activateCard('endo-orig-001');
    db.reworkCard('endo-orig-001', '答案太啰嗦', '请精简为三点');
    db.updateAiNote('endo-orig-001', '留言：保留病因要点');

    final progressData = endoProgress();
    final progressPath = '${tmp.path}/progress.json';

    // fake 检索（脚本化分派；记录调用供限定断言）
    final searchCalls = <Map<String, Object?>>[];
    Future<Map<String, Object?>> runSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      searchCalls.add({
        'q': query,
        'subject': subject,
        'sourceType': sourceType,
        'k': k,
      });
      if (sourceType == 'textbook') {
        if (query.contains('第三章')) {
          return {
            'results': [
              hit(
                't3',
                '世界通史',
                '第三章 龋病·临床表现',
                '40-55',
                0.9,
                sourceType: 'textbook',
              ),
            ],
          };
        }
        if (query.contains('第一章')) {
          return {
            'results': [
              hit(
                't1',
                '世界通史',
                '第一章 概述·绪论',
                '1-8',
                0.7,
                sourceType: 'textbook',
              ),
            ],
          };
        }
        return {'results': <Object?>[]};
      }
      if (sourceType == 'exam') {
        return {
          'results': [
            hit('c9', '2023年真题', '龋病真题', '12', 0.85, sourceType: 'exam'),
          ],
        };
      }
      if (query.contains('龋病四联因素')) {
        return {
          'results': [hit('c1', '龋病概述', '第三章 龋病·四联因素', '12-15', 0.92)],
        };
      }
      if (query.contains('原始回炉题干')) {
        return {
          'results': [hit('r1', '回炉章', '回炉·原始题干', '30-32', 0.8)],
        };
      }
      return {'results': <Object?>[]};
    }

    // fake LLM（按 tag 分派）
    final llmTags = <String>[];
    Future<String> llmChat(
      String system,
      String user, {
      String tag = '',
    }) async {
      llmTags.add(tag);
      switch (tag) {
        case 'studylog':
          return '{"chapters": ["第三章 龋病"]}';
        case 'split':
          return jsonEncode({
            'cards': [
              {
                'kind': 'ppt',
                'front': '龋病四联因素的四大因素是什么？',
                'back': '细菌、食物、宿主、时间',
                'topic': '龋病四联因素',
                'evidenceChunkId': 'c1',
              },
              {
                'kind': 'exam',
                'front': '2023 年关于龋病四联因素的真题',
                'back': '标准答案',
                'examMeta': {'year': '2023', 'no': '42'},
                'evidenceChunkId': 'c9',
              },
            ],
          });
        case 'rework':
          return jsonEncode({
            'front': '重写后的回炉题干',
            'back': '重写后的三点答案',
            'evidenceChunkId': 'r1',
          });
        case 'synonym':
          return '{"queries": []}';
        case 'weekly':
          return '{"cards": []}';
      }
      throw LlmException('未知 tag: $tag');
    }

    final result = await runCatchup(
      deps: PipelineDeps(
        db: db,
        runSearch: runSearch,
        llmChat: llmChat,
        prompts: const {},
        progressData: progressData,
        progressPath: progressPath,
      ),
    );

    // ── counts（report.py 关键计数口径） ──
    final counts = result['counts'] as Map<String, Object?>;
    expect(counts['inbox'], 2);
    expect(counts['keywordsProcessed'], 1);
    final slc = counts['studyLog'] as Map<String, Object?>;
    expect(slc['entries'], 1);
    expect(slc['subjects'], 1);
    expect(slc['refs'], 1);
    expect(slc['advanced'], 1);
    expect(slc['consumed'], 1);
    expect((slc['consumeSkippedRetry'] as List), isEmpty);
    final cc = counts['cards'] as Map<String, Object?>;
    expect(cc['total'], 2);
    expect(cc['ppt'], 1);
    expect(cc['exam'], 1);
    expect(cc['placeholder'], 0);
    expect(cc['failed'], 0);
    final ic = counts['import'] as Map<String, Object?>;
    expect(ic['inserted'], 2);
    expect(ic['skipped'], 0);
    expect(ic['consumed'], 1);
    expect(counts['reworkDone'], 1);
    expect(counts['reworkDraft'], 0);
    // compass 行（含 hit 即计，≈run.py L1108）+ studylog advancedCount（≈L1266）
    expect(counts['compassAdvances'], 2);
    expect(counts['pendingPool'], 0); // 上下文取自开跑前（种子卡处于 rework 态）
    expect(counts['leech'], 0);

    // ── 步骤落位 ──
    // 罗盘在 studylog 之前跑（≈L1661 先于 L1667）：当前章=第一章 → 未变原地
    final compass = (result['steps'] as Map)['compass'] as Map<String, Object?>;
    expect(compass['endo'], isA<Map>());
    expect((compass['endo'] as Map)['hit'], '第一章 概述·绪论');
    expect((compass['endo'] as Map)['advanced'], true); // 未变（N）原地亦计
    final slStep = (result['steps'] as Map)['studyLog'] as Map<String, Object?>;
    final slSubj = (slStep['subjects'] as List).single as Map<String, Object?>;
    expect(slSubj['normalizeMode'], 'llm');
    expect(slSubj['entryIds'], [slId]);
    final slRef = (slSubj['refs'] as List).single as Map<String, Object?>;
    expect(slRef['ref'], '第三章 龋病');
    expect(slRef['advanced'], true);
    expect(slRef['toNo'], 3);
    // LLM 调用顺序 = 编排顺序：studylog（④）→ split（⑤）→ rework（⑦）
    expect(llmTags, ['studylog', 'split', 'rework']);
    // 检索限定：compass/studylog 走教材源 k=3
    final firstCall = searchCalls.first;
    expect(firstCall['sourceType'], 'textbook');
    expect(firstCall['k'], 3);
    expect(
      searchCalls.any((c) => c['sourceType'] == 'textbook' && c['k'] == 3),
      isTrue,
    );

    // ── 落库（真实 SQLite） ──
    expect(db.inboxPending(), isEmpty); // 关键词 + 学习记录条目均已消费
    expect(db.reworkPending(), isEmpty);
    final reworked = db.cardById('endo-orig-001')!;
    expect(reworked.status, CardStatus.pending); // 回炉完成 → 回待审核池
    expect(reworked.front, '重写后的回炉题干');
    expect(reworked.back, '重写后的三点答案');
    expect(reworked.anchor, '回炉章 p30-32'); // composeAnchor(evidenceChunkId)
    expect(db.unreadAiNotes(), isEmpty); // done 后自动标已读（契约 3）
    final examCard = db.cardById('exam-endo-2023-42')!;
    expect(examCard.sourceTier, SourceTier.exam);
    expect(examCard.examYear, '2023');
    expect(examCard.tags, contains('真题'));
    final pendingFronts = db
        .pendingCards(limit: 10)
        .map((c) => c.front)
        .toSet();
    expect(pendingFronts, contains('龋病四联因素的四大因素是什么？'));

    // ── 罗盘推进在编排内落位（内存 + 真文件） ──
    final endo =
        (progressData['subjects'] as Map)['endo'] as Map<String, Object?>;
    expect(endo['learned_through'], 3);
    expect((endo['history'] as List).length, 1);
    expect(File(progressPath).existsSync(), true);
    final saved = loadProgress(progressPath);
    final savedEndo =
        ((saved['subjects'] as Map)['endo']) as Map<String, Object?>;
    expect(savedEndo['learned_through'], 3);
    expect((result['meta'] as Map)['progressSaved'], true);
    final progressSummary =
        (result['progressSummary'] as Map)['endo'] as Map<String, Object?>;
    expect(progressSummary['learnedThrough'], 3);

    // violations/misses/placeholders 全空（答案合规 + PPT 命中）
    expect(result['violations'] as List, isEmpty);
    expect(result['misses'] as List, isEmpty);
    expect(result['placeholders'] as List, isEmpty);
  });

  test('契约 9：LLM 失败 → failed 不 import 不 consume，收件箱保留待补跑', () async {
    final db = await openDb();
    addTearDown(db.close);
    db.insertKeyword(
      subjectId: 'oms',
      keyword: '干槽症',
      source: 'chat',
      note: '',
    );

    final result = await runCatchup(
      deps: PipelineDeps(
        db: db,
        runSearch: (query, {subject, sourceType, k}) async => {
          'results': <Object?>[],
        },
        llmChat: (system, user, {tag = ''}) async =>
            throw const LlmException('HTTP 500: 上游故障'),
        prompts: const {},
        progressData: emptyProgress(), // 无 oms 科目 → 罗盘/推进跳过不阻断
      ),
    );

    final counts = result['counts'] as Map<String, Object?>;
    expect(((counts['cards'] as Map)['failed']), 1);
    final kw =
        ((result['steps'] as Map)['keywords'] as List).single
            as Map<String, Object?>;
    expect(kw['status'], 'failed');
    expect(kw['pptHit'], false);
    expect((kw['cards'] as List), isEmpty);
    final imp = kw['import'] as Map<String, Object?>;
    expect(imp['consumed'], false);
    final ic = counts['import'] as Map<String, Object?>;
    expect(ic['inserted'], 0);
    expect(ic['consumed'], 0);
    expect(db.inboxPending().length, 1); // 未 consume：留给下次补跑
    expect(db.pendingCards(), isEmpty); // 未 import
    expect((result['misses'] as List).length, 1); // 未命中清单如实入报告
    expect((result['meta'] as Map)['progressSaved'], false);
  });

  test('#7③ 单关键词异常隔离：split 抛 Error 只失败该条，整轮不中断', () async {
    final db = await openDb();
    addTearDown(db.close);
    db.insertSubject(id: 'endo', name: '通史');
    // 抛错关键词先入箱（排前）：若循环被炸穿，后一条永远到不了——
    // 后一条 status=ok 即「整轮不中断」的直接证据。
    db.insertKeyword(
      subjectId: 'endo',
      keyword: '白斑',
      source: 'chat',
      note: '',
    );
    db.insertKeyword(
      subjectId: 'endo',
      keyword: '龋病四联因素',
      source: 'chat',
      note: '',
    );

    final result = await runCatchup(
      deps: PipelineDeps(
        db: db,
        runSearch: (query, {subject, sourceType, k}) async => {
          'results': <Object?>[],
        },
        llmChat: (system, user, {tag = ''}) async {
          if (tag == 'split' && user.contains('白斑')) {
            // 模拟 splitKeyword 内逃逸的非预期 Error（如畸形数据 TypeError）
            throw StateError('模拟未捕获 Error（畸形数据 TypeError 同型）');
          }
          if (tag == 'split') {
            return jsonEncode({
              'cards': [
                {'kind': 'ppt', 'front': 'F', 'back': 'B'},
              ],
            });
          }
          return '{"queries": []}';
        },
        prompts: const {},
        progressData: emptyProgress(),
      ),
    );

    final counts = result['counts'] as Map<String, Object?>;
    expect(counts['keywordsProcessed'], 2, reason: '两条关键词都到达处理位');
    expect(((counts['cards'] as Map)['failed']), 1, reason: '仅异常关键词 failed');
    expect(((counts['import'] as Map)['consumed']), 1, reason: '好关键词照常消费');
    final kws = ((result['steps'] as Map)['keywords'] as List)
        .cast<Map<String, Object?>>();
    final byKw = {for (final k in kws) (k['keyword'] as String): k};
    expect(byKw['白斑']!['status'], 'failed');
    expect((byKw['白斑']!['error'] as String), contains('模拟未捕获 Error'));
    expect((byKw['白斑']!['notes'] as List).join(' '), contains('关键词处理异常'));
    expect(byKw['龋病四联因素']!['status'], 'ok', reason: '后续关键词完好未中断');
    expect((byKw['龋病四联因素']!['cards'] as List).length, 2, reason: 'LLM 卡+占位兜底');
    final inboxLeft = db.inboxPending();
    expect(inboxLeft.length, 1, reason: '失败条目不 consume 留补跑（契约 9）');
    expect(inboxLeft.single['keyword'], '白斑');
    expect(db.pendingCards().length, 2, reason: '好关键词的卡已真实入库');
  });

  test('studylog 检索故障 → 科目条目不 consume 留重试；关键词照常消费', () async {
    final db = await openDb();
    addTearDown(db.close);
    // 同上：开源去内置后科目由测试自建（关键词拆卡 import 需要科目在场）。
    db.insertSubject(id: 'endo', name: '通史');
    db.insertKeyword(
      subjectId: 'endo',
      keyword: '龋病四联因素',
      source: 'chat',
      note: '',
    );
    final slId = db.insertKeyword(
      subjectId: 'endo',
      keyword: '第三章 龋病',
      source: 'study-log',
      note: '',
    );

    final progressData = endoProgress();
    final progressPath = '${tmp.path}/progress.json';

    final result = await runCatchup(
      deps: PipelineDeps(
        db: db,
        runSearch: (query, {subject, sourceType, k}) async {
          if (sourceType == 'textbook') {
            throw const SearchException('网络故障'); // compass + studylog 同源故障
          }
          if (sourceType == 'exam') {
            return {'results': <Object?>[]};
          }
          return {
            'results': [hit('c1', '龋病概述', '龋病·四联因素', '12-15', 0.92)],
          };
        },
        llmChat: (system, user, {tag = ''}) async => switch (tag) {
          'studylog' => '{"chapters": ["第三章 龋病"]}',
          'split' => jsonEncode({
            'cards': [
              {
                'kind': 'ppt',
                'front': '龋病四联因素的四大因素是什么？',
                'back': '细菌、食物、宿主、时间',
                'evidenceChunkId': 'c1',
              },
            ],
          }),
          _ => throw LlmException('意外 tag: $tag'),
        },
        prompts: const {},
        progressData: progressData,
        progressPath: progressPath,
      ),
    );

    // 检索故障条目留重试（契约 9 同款）；关键词照常消费
    final counts = result['counts'] as Map<String, Object?>;
    final slc = counts['studyLog'] as Map<String, Object?>;
    expect(slc['consumed'], 0);
    expect(slc['consumeSkippedRetry'], [slId]);
    expect((counts['import'] as Map)['consumed'], 1);
    final remaining = db.inboxPending();
    expect(remaining.length, 1);
    expect(remaining.single['id'], slId);

    // 推进未生效：罗盘零推进、内存未动、不落盘
    expect(counts['compassAdvances'], 0);
    expect(
      ((progressData['subjects'] as Map)['endo'] as Map)['learned_through'],
      1,
    );
    expect(File(progressPath).existsSync(), false);
    expect((result['meta'] as Map)['progressSaved'], false);
    final slStep = (result['steps'] as Map)['studyLog'] as Map<String, Object?>;
    final slSubj = (slStep['subjects'] as List).single as Map<String, Object?>;
    final slRef = (slSubj['refs'] as List).single as Map<String, Object?>;
    expect((slRef['note'] as String).startsWith('教材检索失败'), isTrue);
  });

  test('/pipeline/trigger 路由契约：首次 triggered=true、重复排队中，两分支均 kick', () async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    var kicks = 0;
    LocalBackend.pipelineKick = () async => kicks++;

    final be = LocalBackend.instance;
    final t1 = await be.post('/pipeline/trigger', null);
    expect(t1['ok'], true);
    expect(t1['triggered'], true);
    expect(t1['note'], '已触发端上拆卡流水线（后台运行中）');
    expect(kicks, 1);
    final marker = File(PipelineRunner.markerPath(tmp.path));
    expect(marker.existsSync(), true);

    final t2 = await be.post('/pipeline/trigger', null);
    expect(t2['triggered'], false);
    expect(t2['note'], '已有任务排队中');
    expect(kicks, 2); // 排队分支同样 kick（失败遗留标志的重复触发=重试消费）
    expect(marker.existsSync(), true); // 幂等：标志保留给消费方
  });

  test('嵌入装配：无 key → 词面单路不炸；有 key → 真实 embedModel 透传（互斥命脉）', () async {
    final db = await openDb();
    addTearDown(db.close);

    // 无 key/model → (null, null)：词面单路（offline 无 key 路不炸）
    final noKey = assembleEmbedder(db);
    expect(noKey.embed, isNull);
    expect(noKey.embedModel, isNull);

    // 有 key+model → embed 注入 + 真实 model 透传（绝不打印 key）
    //（安全修复 C：key 不再读 settings 表——显式传 apiKey 模拟 vault 下发）
    db.settingSet('embedding.model', 'Qwen/Qwen3-VL-Embedding-8B');
    final wired = assembleEmbedder(db, apiKey: 'sk-embed-test-123456');
    expect(wired.embed, isNotNull);
    expect(wired.embedModel, 'Qwen/Qwen3-VL-Embedding-8B');

    // corpus.db 缺失 → SearchException（契约 10 降级统一出口，不炸）
    final missing = assembleRunSearch(
      corpusPath: '${tmp.path}/corpus/corpus.db',
      embed: null,
      embedModel: null,
    );
    await expectLater(
      missing('龋病', subject: 'endo', sourceType: null, k: 6),
      throwsA(isA<SearchException>()),
    );

    // 最小合成库：无嵌入 → ok:true（词面路，不炸）；真实 model 透传后与库内
    // meta.embedding_model 不一致 → 向量路互斥跳过（命中互斥校验命脉）
    final cdb = sqlite3.openInMemory();
    addTearDown(cdb.dispose);
    cdb.execute(
      'CREATE TABLE chunks ('
      'chunk_id TEXT PRIMARY KEY, deck TEXT, title TEXT, source_type TEXT,'
      'subject_id TEXT, page_start INTEGER, page_end INTEGER,'
      "page_range TEXT, text TEXT)",
    );
    cdb.execute(
      'CREATE TABLE vectors ('
      'chunk_id TEXT PRIMARY KEY, dim INTEGER NOT NULL,'
      ' vec BLOB NOT NULL, scale REAL NOT NULL)',
    );
    cdb.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
    cdb.execute("INSERT INTO meta VALUES ('embedding_model', 'ModelA')");
    cdb.execute(
      "INSERT INTO chunks VALUES ('c1', '龋病概述',"
      " '第三章 龋病·临床表现', 'textbook', 'endo', 12, 15, '12-15',"
      " '龋病四联因素是细菌食物宿主时间四联因素')",
    );
    cdb.execute(
      "INSERT INTO vectors VALUES ('c1', 3, x'00000000000000803F', 1.0)",
    );

    final lexOnly = assembleRunSearch(
      corpusDb: cdb,
      corpusPath: 'mem',
      embed: null,
      embedModel: null,
    );
    final res1 = await lexOnly('龋病四联因素', subject: null, sourceType: null, k: 6);
    expect(res1['ok'], true); // 无嵌入不炸：词面路照常
    expect(res1['results'], isA<List>());

    final mismatch = assembleRunSearch(
      corpusDb: cdb,
      corpusPath: 'mem',
      embed: (q) async => [0.1, 0.2, 0.3],
      embedModel: 'ModelB', // ≠ 库内 ModelA → 空间不兼容
    );
    final res2 = await mismatch(
      '龋病四联因素',
      subject: null,
      sourceType: null,
      k: 6,
    );
    expect(res2['ok'], true); // 互斥 → 向量路跳过，仍不炸
    expect((res2['notes'] as List).join('\n'), contains('嵌入空间不兼容'));
  });

  test('#6① normalizeEmbedEndpoint：…/v1 与 …/v1/embeddings 双形态统一成完整端点', () {
    const base = 'https://api.siliconflow.cn/v1';
    // settings 基址形态（服务器/用户主存形态）→ 自动补尾成完整端点
    expect(normalizeEmbedEndpoint(base), '$base/embeddings');
    // 尾部斜杠与首尾空白容错
    expect(normalizeEmbedEndpoint('$base/'), '$base/embeddings');
    expect(normalizeEmbedEndpoint('  $base  '), '$base/embeddings');
    expect(normalizeEmbedEndpoint(' $base/ '), '$base/embeddings');
    // 真机已手动补后缀形态 → 原样兼容（幂等，不重复补）
    expect(normalizeEmbedEndpoint('$base/embeddings'), '$base/embeddings');
    expect(normalizeEmbedEndpoint('$base/embeddings/'), '$base/embeddings');
    expect(normalizeEmbedEndpoint('  $base/embeddings '), '$base/embeddings');
    // 空/纯空白 → 回退默认端点（与旧 assembleEmbedder 空值行为一致）
    expect(normalizeEmbedEndpoint(''), kEmbedApiUrl);
    expect(normalizeEmbedEndpoint('   '), kEmbedApiUrl);
  });

  test('节点③ instruct 前缀开关接线：instructQuery=0 → 禁用；缺省/1 → 内置', () async {
    final db = await openDb();
    addTearDown(db.close);

    // 安全修复 C：key 不再读 settings 表——显式传 apiKey 模拟 vault 下发
    const key = 'sk-embed-test-123456';
    db.settingSet('embedding.model', 'Qwen/Qwen3-VL-Embedding-8B');

    // 缺省（默认开=保持旧行为）→ null = 内置 kQueryInstruct
    final def = assembleEmbedConfig(db, apiKey: key);
    expect(def, isNotNull);
    expect(def!.queryInstruct, isNull);

    // '0' → ''（禁用前缀——Gitee/模力方舟通道）
    db.settingSet('embedding.instructQuery', '0');
    final off = assembleEmbedConfig(db, apiKey: key);
    expect(off!.queryInstruct, '');

    // '1' → 显式开（与缺省同语义）
    db.settingSet('embedding.instructQuery', '1');
    expect(assembleEmbedConfig(db, apiKey: key)!.queryInstruct, isNull);

    // 端到端：闭包装配形态不受影响（embed 注入 + 真实 model 透传）
    final wired = assembleEmbedder(db, apiKey: key);
    expect(wired.embed, isNotNull);
    expect(wired.embedModel, 'Qwen/Qwen3-VL-Embedding-8B');
  });

  test('#8 查询嵌入异常 → 降级词面单路出真结果 + notes 标注（不炸穿）', () async {
    // 最小合成库（同「嵌入装配」测试款）：chunks + vectors + meta 一致模型
    final cdb = sqlite3.openInMemory();
    addTearDown(cdb.dispose);
    cdb.execute(
      'CREATE TABLE chunks ('
      'chunk_id TEXT PRIMARY KEY, deck TEXT, title TEXT, source_type TEXT,'
      ' subject_id TEXT, page_start INTEGER, page_end INTEGER,'
      " page_range TEXT, text TEXT)",
    );
    cdb.execute(
      'CREATE TABLE vectors ('
      'chunk_id TEXT PRIMARY KEY, dim INTEGER NOT NULL,'
      ' vec BLOB NOT NULL, scale REAL NOT NULL)',
    );
    cdb.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
    cdb.execute("INSERT INTO meta VALUES ('embedding_model', 'ModelA')");
    cdb.execute(
      "INSERT INTO chunks VALUES ('c1', '龋病概述',"
      " '第三章 龋病·四联因素', 'textbook', 'endo', 12, 15, '12-15',"
      " '龋病四联因素是细菌食物宿主时间四联因素')",
    );
    cdb.execute(
      "INSERT INTO vectors VALUES ('c1', 3, x'00000000000000803F', 1.0)",
    );

    // 恒抛异常的嵌入（生产同型：apiEmbed 重试尽后抛 StateError 含 HTTP 状态）
    var embedCalls = 0;
    final broken = assembleRunSearch(
      corpusDb: cdb,
      corpusPath: 'mem',
      embed: (q) async {
        embedCalls++;
        throw StateError('embeddings API 调用失败（重试 2 次）：HTTP 404: …');
      },
      embedModel: 'ModelA', // 与库内一致：无互斥拦截，抛错路径必经
    );
    final res = await broken('龋病四联因素', subject: null, sourceType: null, k: 6);
    expect(res['ok'], true, reason: '#8：嵌入异常不得炸穿整个检索');
    expect((res['results'] as List), isNotEmpty, reason: '词面单路仍出真卡');
    expect(embedCalls, 1, reason: '嵌入确实被调用过（降级发生在嵌入层）');
    final notes = (res['notes'] as List).join('\n');
    expect(notes, contains('向量路跳过'), reason: '向量路降级生效（词面单路）');
    expect(notes, contains('降级词面单路'), reason: '降级原因如实标注');
    expect(notes, contains('404'), reason: '嵌入异常原文可诊断');

    // 对照组：同库正常 embed → 向量路真用上（非降级态）
    final fine = assembleRunSearch(
      corpusDb: cdb,
      corpusPath: 'mem',
      embed: (q) async => [0.1, 0.2, 0.3],
      embedModel: 'ModelA',
    );
    final res2 = await fine('龋病四联因素', subject: null, sourceType: null, k: 6);
    expect(res2['ok'], true);
    expect(((res2['vec'] as Map)['used']), true, reason: '正常路向量参与融合');
    expect((res2['notes'] as List).join('\n'), isNot(contains('降级词面单路')));
  });

  test('标志消费（≈force-check.sh）：成功删标志、失败保留、运行中单飞不并发', () async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    final markerPath = PipelineRunner.markerPath(tmp.path);
    Directory('${tmp.path}/corpus').createSync(recursive: true);
    File(markerPath).writeAsStringSync('queued');

    var calls = 0;
    final gate = Completer<bool>();
    PipelineRunner.instance.runOnceOverride = (dir) {
      calls++;
      expect(dir, tmp.path);
      return gate.future;
    };

    final first = PipelineRunner.instance.consumeForceRun();
    final second = PipelineRunner.instance.consumeForceRun(); // 运行中：单飞
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1); // 未并发启动第二轮
    expect(PipelineRunner.instance.running, true);

    gate.complete(true);
    await first;
    await second;
    expect(File(markerPath).existsSync(), false); // rc==0 → 删标志
    expect(PipelineRunner.instance.running, false);

    // 失败留标志（下次触发/启动再消费；进程内不自动重试）
    File(markerPath).writeAsStringSync('retry');
    PipelineRunner.instance.runOnceOverride = (_) async => false;
    await PipelineRunner.instance.consumeForceRun();
    expect(File(markerPath).existsSync(), true);

    // 未初始化（dataDir=null）→ 无标志可消费：直接返回不炸
    PipelineRunner.instance.runOnceOverride = (_) async => true;
    await LocalBackend.instance.resetForTest();
    await PipelineRunner.instance.consumeForceRun();
  });

  test('周扫装配：weeklyChapters 供料（已学正文章）→ 无真题命中 → 零出卡零导入', () async {
    final db = await openDb();
    addTearDown(db.close);
    final progressData = endoProgress(); // 已学：第一章 概述

    final result = await runWeeklyScan(
      deps: PipelineDeps(
        db: db,
        runSearch: (query, {subject, sourceType, k}) async => {
          'results': <Object?>[],
        },
        llmChat: (system, user, {tag = ''}) async => '{"cards": []}',
        prompts: const {},
        progressData: progressData,
      ),
    );

    // chapters 装配 = 已学正文章唯一起点（第一章；未学不出卡）
    final chapters = result['chapters'] as List;
    expect(chapters.length, 1);
    expect((chapters.single as Map)['chapter'], '第一章 概述');
    final counts = result['counts'] as Map<String, Object?>;
    expect(counts['candidates'], 0);
    expect(counts['afterBalance'], 0);
    expect(counts['cards'], 0);
    expect(counts['imported'], 0);
    expect(db.pendingCards(), isEmpty);
  });

  // ---------------------------------- 节点⑤ 真题周扫接线（≥7 天自动 + 门控） ----

  test('⑤ weeklyScanDue：无/坏时间戳=从未跑过；<7 天未到期；≥7 天到期', () {
    final now = DateTime(2026, 9, 7, 12);
    expect(weeklyScanDue(null, now), true, reason: '无时间戳=从未跑过');
    expect(weeklyScanDue('', now), true, reason: '空串=从未跑过');
    expect(weeklyScanDue('not-a-date', now), true, reason: '坏值=从未跑过');
    expect(weeklyScanDue('2026-09-06T12:00:00', now), false, reason: '1 天');
    expect(weeklyScanDue('2026-09-01T12:00:00', now), false, reason: '6 天');
    expect(
      weeklyScanDue('2026-08-31T12:00:00', now),
      true,
      reason: '恰 7 天 → 到期',
    );
  });

  test('⑤ 周扫接线：≥7 天自动触发 + settings 时间戳节流两分支（注入假时间戳）', () async {
    final db = await openDb();
    addTearDown(db.close);
    db.insertSubject(id: 'endo', name: '通史');

    var llmCalls = 0;
    Future<Map<String, Object?>> runSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      if (sourceType == 'exam') {
        return {
          'results': [
            hit(
              'exam:2021:1',
              '2021年口腔执业医师资格试题（网友回忆版）',
              '真题',
              '1-2',
              0.85,
              sourceType: 'exam',
            ),
          ],
        };
      }
      return {'results': <Object?>[]};
    }

    Future<String> llmChat(String system, String user, {String tag = ''}) async {
      if (tag == 'weekly') {
        llmCalls++;
        return jsonEncode({
          'cards': [
            {
              'subjectId': 'endo',
              'type': 'basic',
              'front': '真题卡',
              'back': '答案',
              'evidenceChunkId': 'exam:2021:1',
              'examMeta': {'year': '2021', 'no': '9'},
            },
          ],
        });
      }
      throw LlmException('意外 tag: $tag');
    }

    final deps = PipelineDeps(
      db: db,
      runSearch: runSearch,
      llmChat: llmChat,
      prompts: const {},
      progressData: endoProgress(), // 已学第一章 → 1 章候选
    );

    // ① 无时间戳（从未跑过）→ 自动触发；时间戳落 settings
    final r1 = await runWeeklyAfterCatchup(deps: deps);
    expect(r1['ran'], true);
    expect(r1['cards'], 1);
    expect(r1['imported'], 1);
    expect(db.cardById('exam-endo-2021-9'), isNotNull, reason: '真题卡真实入库');
    expect(db.settingGet(kWeeklyScanSettingKey), isNotNull);

    // ② 时间戳刚写（<7 天）→ 节流跳过：LLM 不再调用
    final r2 = await runWeeklyAfterCatchup(deps: deps);
    expect(r2['ran'], false);
    expect(r2['skipped'], 'throttled');
    expect(llmCalls, 1);

    // ③ 注入 8 天前假时间戳 → 到期再触发（幂等 id → 重复导入计 skipped）
    db.settingSet(
      kWeeklyScanSettingKey,
      DateTime.now().subtract(const Duration(days: 8)).toIso8601String(),
    );
    final r3 = await runWeeklyAfterCatchup(deps: deps);
    expect(r3['ran'], true);
    expect(llmCalls, 2);
    expect(r3['cards'], 1);
    expect(r3['imported'], 0, reason: '幂等 id 重复导入 → skipped 计数');

    // ④ 注入 6 天前假时间戳 → 仍节流
    db.settingSet(
      kWeeklyScanSettingKey,
      DateTime.now().subtract(const Duration(days: 6)).toIso8601String(),
    );
    final r4 = await runWeeklyAfterCatchup(deps: deps);
    expect(r4['ran'], false);
    expect(r4['skipped'], 'throttled');
    expect(llmCalls, 2);
  });

  test('⑤ 周扫接线：空态静默跳过（无已学章命中且无技能候选）→ 不写时间戳可重试', () async {
    final db = await openDb();
    addTearDown(db.close);
    final progress = endoProgress();
    ((progress['subjects'] as Map)['endo'] as Map)['learned_through'] = 0;
    var llmCalls = 0;
    final deps = PipelineDeps(
      db: db,
      runSearch: (query, {subject, sourceType, k}) async =>
          {'results': <Object?>[]},
      llmChat: (system, user, {tag = ''}) async {
        llmCalls++;
        throw LlmException('不应调用');
      },
      prompts: const {},
      progressData: progress,
    );
    final r1 = await runWeeklyAfterCatchup(deps: deps);
    expect(r1['ran'], false);
    expect(r1['skipped'], 'empty');
    expect(llmCalls, 0);
    expect(db.settingGet(kWeeklyScanSettingKey), isNull, reason: '空态不写时间戳');
    // 未被节流卡死——下次 catchup 自然重试
    final r2 = await runWeeklyAfterCatchup(deps: deps);
    expect(r2['skipped'], 'empty');
  });

  test('⑤ 周扫接线：本机无 -exam 真题语料（检索恒降级）→ 静默零结果', () async {
    final db = await openDb();
    addTearDown(db.close);
    var llmCalls = 0;
    final r = await runWeeklyAfterCatchup(
      deps: PipelineDeps(
        db: db,
        runSearch: (query, {subject, sourceType, k}) async =>
            throw const SearchException('corpus.db 不存在或无法打开'),
        llmChat: (system, user, {tag = ''}) async {
          llmCalls++;
          throw LlmException('不应调用');
        },
        prompts: const {},
        progressData: endoProgress(),
      ),
    );
    expect(r['ran'], false);
    expect(r['skipped'], 'empty', reason: '检索全降级 → 零候选按空态静默');
    expect(llmCalls, 0);
    expect(db.settingGet(kWeeklyScanSettingKey), isNull);
    expect((r['notes'] as List).join('\n'), contains('周扫检索降级'));
  });

  test('⑤ runWeeklyScan 装配：技能五站常量注入（subject=<短码>、sourceType=exam 直检）', () async {
    final db = await openDb();
    addTearDown(db.close);
    final calls = <String>[];
    await runWeeklyScan(
      deps: PipelineDeps(
        db: db,
        runSearch: (query, {subject, sourceType, k}) async {
          if (sourceType == 'exam') calls.add('${subject ?? '-'}:$query');
          return {'results': <Object?>[]};
        },
        llmChat: (system, user, {tag = ''}) async =>
            throw LlmException('零候选不应调用 LLM'),
        prompts: const {},
        progressData: endoProgress(), // 已学第一章
      ),
    );
    // 章节检索（subject=null）+ 技能五站直检（subject=<短码>、检索词=专题名）
    expect(calls, contains('-:第一章 概述'));
    expect(calls, contains('bingshi:病史采集类'));
    expect(calls, contains('bingli:病例分析类'));
    expect(calls, contains('jiancha:检查方法类'));
    expect(calls, contains('caozuo:操作技能类'));
    expect(calls, contains('jijiu:急救技术类'));
    expect(calls.length, 6, reason: '1 已学章 + 5 技能专题，无多余检索');
  });

  test('编排 dry-run：全链只出草稿——不 import 不 consume 不推进不落盘', () async {
    final db = await openDb();
    addTearDown(db.close);
    db.insertKeyword(
      subjectId: 'endo',
      keyword: '龋病四联因素',
      source: 'chat',
      note: '',
    );
    final slId = db.insertKeyword(
      subjectId: 'endo',
      keyword: '第三章 龋病',
      source: 'study-log',
      note: '',
    );

    final progressData = endoProgress();
    final progressPath = '${tmp.path}/progress.json';

    final result = await runCatchup(
      opts: const RunOptions(dryRun: true),
      deps: PipelineDeps(
        db: db,
        runSearch: (query, {subject, sourceType, k}) async {
          if (sourceType == 'textbook') {
            return {
              'results': [
                hit(
                  't3',
                  '世界通史',
                  '第三章 龋病·临床表现',
                  '40-55',
                  0.9,
                  sourceType: 'textbook',
                ),
              ],
            };
          }
          if (sourceType == 'exam') {
            return {'results': <Object?>[]};
          }
          return {
            'results': [hit('c1', '龋病概述', '龋病·四联因素', '12-15', 0.92)],
          };
        },
        llmChat: (system, user, {tag = ''}) async => switch (tag) {
          'studylog' => '{"chapters": ["第三章 龋病"]}',
          'split' => jsonEncode({
            'cards': [
              {
                'kind': 'ppt',
                'front': '龋病四联因素的四大因素是什么？',
                'back': '细菌、食物、宿主、时间',
                'evidenceChunkId': 'c1',
              },
            ],
          }),
          _ => throw LlmException('意外 tag: $tag'),
        },
        prompts: const {},
        progressData: progressData,
        progressPath: progressPath,
      ),
    );

    // 只出草稿：不 import、不 consume、不推进落盘
    expect(db.inboxPending().length, 2); // 关键词 + 学习记录均保留
    expect(db.pendingCards(), isEmpty);
    expect(File(progressPath).existsSync(), false);
    expect(
      ((progressData['subjects'] as Map)['endo'] as Map)['learned_through'],
      1,
    );
    final counts = result['counts'] as Map<String, Object?>;
    expect((counts['import'] as Map)['inserted'], 0);
    expect(((counts['cards'] as Map)['total']), 1); // 草稿仍入 counts（报告可见）
    final slc = counts['studyLog'] as Map<String, Object?>;
    expect(slc['advanced'], 0);
    expect(slc['wouldAdvance'], 1); // 影子日志如实预演
    expect(slc['consumed'], 0);
    expect(counts['reworkDraft'], 0); // 无回炉队列
    final slStep = (result['steps'] as Map)['studyLog'] as Map<String, Object?>;
    final slSubj = (slStep['subjects'] as List).single as Map<String, Object?>;
    expect(slSubj['entryIds'], [slId]);
  });

  test('#16 罗盘懒初始化：条目缺失 + toc sidecar 在 → catchup 开跑自动 init 后推进链可用', () async {
    final db = await openDb();
    addTearDown(db.close);
    db.insertSubject(id: 'endo', name: '通史');
    db.insertKeyword(
      subjectId: 'endo',
      keyword: '第二章 启蒙思想',
      source: 'study-log',
      note: '',
    );

    // toc sidecar 在、罗盘条目缺失（模拟既有语料装新版后首次拆卡）
    final tocDir = '${tmp.path}/corpus/toc';
    Directory(tocDir).createSync(recursive: true);
    File('$tocDir/endo.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'subject': 'endo',
      'textbook': '世界通史-第2版',
      'chapters': [
        {'no': 1, 'title': '第一章 概述', 'page_start': 1},
        {'no': 2, 'title': '第二章 启蒙思想', 'page_start': 20},
        {'no': 3, 'title': '第三章 龋病', 'page_start': 40},
      ],
      'sections': <Object?>[],
    }));
    final progressData = emptyProgress();
    final progressPath = '${tmp.path}/progress.json';
    expect(progressEntryOf(progressData, 'endo'), isNull, reason: '前置：条目缺失');

    // fake 检索：仅「第二章」教材查询命中（罗盘链显示名回退查询不命中——
    // 推进归 studylog 链，断言聚焦懒初始化语义）
    Future<Map<String, Object?>> runSearch(String query,
        {String? subject, String? sourceType, int? k}) async {
      if (sourceType == 'textbook' && query.contains('第二章')) {
        return {
          'results': [
            hit('t2', '世界通史', '第二章 启蒙思想·兴起', '20-39', 0.9,
                sourceType: 'textbook'),
          ],
        };
      }
      return {'results': <Object?>[]};
    }

    Future<String> llmChat(String system, String user, {String tag = ''}) async =>
        '{"chapters": ["第二章 启蒙思想"]}';

    // ── dry-run 先行：懒初始化跳过（零落盘口径），推进链守卫如实报缺条目 ──
    final dryResult = await runCatchup(
      opts: const RunOptions(dryRun: true),
      deps: PipelineDeps(
        db: db,
        runSearch: runSearch,
        llmChat: llmChat,
        prompts: const {},
        progressData: progressData,
        progressPath: progressPath,
        tocDir: tocDir,
      ),
    );
    expect(progressEntryOf(progressData, 'endo'), isNull,
        reason: 'dry-run 不做懒初始化（零变更口径）');
    final dryStep = (dryResult['steps'] as Map)['studyLog'] as Map<String, Object?>;
    expect('${((dryStep['subjects'] as List).single as Map)['note']}',
        contains('进度库无该科目'),
        reason: '未 init 时推进链静默失败口径原样（修复前行为基线）');

    // ── 真跑：catchup 装配懒初始化（进度库缺条目 + sidecar 在 → init）──
    final result = await runCatchup(
      deps: PipelineDeps(
        db: db,
        runSearch: runSearch,
        llmChat: llmChat,
        prompts: const {},
        progressData: progressData,
        progressPath: progressPath,
        tocDir: tocDir,
      ),
    );

    // 懒初始化建条目 + studylog 推进 0→2 + ⑧ 落盘步持久（含 init 变更）
    final endo = (progressData['subjects'] as Map)['endo'] as Map<String, Object?>;
    expect(endo, isNotNull, reason: '懒初始化应从 toc sidecar 建条目');
    expect(endo['textbook'], '世界通史-第2版');
    expect((endo['chapters'] as List).length, 3);
    expect(endo['learned_through'], 2, reason: 'init 后推进链可用：study-log 0→2');
    expect((endo['history'] as List).length, 1);
    final saved = loadProgress(progressPath);
    final savedEndo = ((saved['subjects'] as Map)['endo']) as Map<String, Object?>;
    expect(savedEndo['learned_through'], 2, reason: 'progress.json 落盘（进度页可见）');
    final counts = result['counts'] as Map<String, Object?>;
    final slc = counts['studyLog'] as Map<String, Object?>;
    expect(slc['advanced'], 1);
    expect(slc['consumed'], 1);
    expect((result['meta'] as Map)['progressSaved'], true);
    // 无 sidecar 科目不建条目（宁缺毋滥）
    expect((progressData['subjects'] as Map).containsKey('oms'), false);

    // ── 幂等：再跑一轮——条目在场不重刷（updated_at 不动），零变更不落盘 ──
    final updatedAt = '${endo['updated_at']}';
    final result2 = await runCatchup(
      deps: PipelineDeps(
        db: db,
        runSearch: runSearch,
        llmChat: llmChat,
        prompts: const {},
        progressData: progressData,
        progressPath: progressPath,
        tocDir: tocDir,
      ),
    );
    expect('${endo['updated_at']}', updatedAt, reason: '已有条目懒路径不重刷');
    expect((result2['meta'] as Map)['progressSaved'], false,
        reason: '无推进无 init → 零变更不落盘');
    expect(db.inboxPending(), isEmpty, reason: '学习记录已消费');
  });

  test('节点④⑤.5 大纲细目打标：outlineTagger 命中 → 该关键词全部卡 tags 追加'
      '「大纲：单元＞细目」（含 exam/占位卡）；tagger null 不打标', () async {
    final db = await openDb();
    addTearDown(db.close);
    db.insertSubject(id: 'endo', name: '牙体牙髓病学');
    db.insertKeyword(
      subjectId: 'endo',
      keyword: '龋病的临床表现及诊断',
      source: 'chat',
      note: '',
    );

    // 两次 runOnce 的 split 响应须可区分（卡 id 幂等：ppt/占位 id 含关键
    // 词 slug、exam id=exam-{科目}-{年份}-{题号} 与关键词无关）——第二轮
    // 换关键词 + 换 examMeta 年份，否则 importCard 幂等跳过、带标卡不落库。
    var splitCalls = 0;
    Future<Map<String, Object?>> runOnce(
        List<String> Function(String, String, List<Object?>)? tagger) {
      return runCatchup(
        deps: PipelineDeps(
          db: db,
          runSearch: (query, {subject, sourceType, k}) async => {
            'results': <Object?>[],
          },
          llmChat: (system, user, {tag = ''}) async {
            if (tag == 'split') {
              final n = splitCalls++;
              final year = '${2023 + n}';
              return jsonEncode({
                'cards': [
                  {
                    'kind': 'ppt',
                    'front': n == 0 ? '龋病临床表现及诊断的要点？' : '龋病再问：临床表现及诊断',
                    'back': '分类、临床表现、诊断及鉴别诊断',
                  },
                  {
                    'kind': 'exam',
                    'front': '$year 年龋病临床表现真题',
                    'back': '标准答案',
                    'examMeta': {'year': year, 'no': '7'},
                  },
                ],
              });
            }
            return '{"queries": []}';
          },
          prompts: const {},
          progressData: emptyProgress(),
          outlineTagger: tagger,
        ),
      );
    }

    // tagger null（旧库/未上传大纲）→ 卡 tags 不含大纲标签
    final r0 = await runOnce(null);
    final kws0 = ((r0['steps'] as Map)['keywords'] as List)
        .cast<Map<String, Object?>>();
    for (final c in (kws0.single['cards'] as List)) {
      expect(((c as Map)['tags'] as List?)
              ?.whereType<String>()
              .any((t) => t.startsWith('大纲：')) ??
          false,
          isFalse,
          reason: '无大纲数据不打标（未命中不强推同态）');
    }
    // 干净重跑（收件箱已消费 → 再插一条；换关键词避开 ppt/占位卡 id 幂等）
    db.insertKeyword(
      subjectId: 'endo',
      keyword: '龋病临床表现及诊断再问',
      source: 'chat',
      note: '',
    );

    // fake tagger（生产 = loadZhiyeSubtopicIndex + outlineTagsFor 同签名）
    final r1 = await runOnce((sid, kw, subs) {
      expect(sid, 'endo');
      expect(kw, '龋病临床表现及诊断再问');
      expect(subs, isEmpty, reason: 'fake LLM 无 plan 行 → subtopics=null → 空表');
      return const ['大纲：龋病＞临床表现及诊断'];
    });
    final kws1 = ((r1['steps'] as Map)['keywords'] as List)
        .cast<Map<String, Object?>>();
    final kw1 = kws1.single;
    expect(kw1['status'], 'ok');
    expect((kw1['notes'] as List).join(' '), contains('大纲细目打标：1 条'));
    final cards = (kw1['cards'] as List).cast<Map<String, Object?>>();
    // pptHit=false 且 fake LLM 未给占位卡 → 引擎兜底补 1 张：共 3 张
    expect(cards.length, 3);
    for (final c in cards) {
      expect(c['tags'], contains('大纲：龋病＞临床表现及诊断'),
          reason: '该关键词全部卡（ppt + exam + 占位）都打标');
    }
    // 落库为真：FlashCard.tags 持久化（exam id 换年份避开第一轮幂等冲突）
    final exam = db.cardById('exam-endo-2024-7')!;
    expect(exam.tags, contains('真题'));
    expect(exam.tags, contains('大纲：龋病＞临床表现及诊断'));
    final pptCard = cards.firstWhere(
      (c) => c['kind'] == 'ppt' && c['isPlaceholder'] != true,
    );
    final ppt = db
        .pendingCards(limit: 10)
        .firstWhere((c) => c.id == pptCard['id']);
    expect(ppt.tags, contains('大纲：龋病＞临床表现及诊断'));
    // 第一轮（tagger null）已入库的卡幂等不被追标（不带标卡不被覆盖）
    expect(
      db.cardById('exam-endo-2023-7')!.tags.any((t) => t.startsWith('大纲：')),
      isFalse,
    );
  });
}
