// 恒牙（hengya）· Phase 4 run_engine 测试（run_engine.dart 对拍硬门）
// ============================================================================
//
// Python 金标准：automation/server-pipeline/run.py --self-test（16 组断言）。
// 本刀移植范围内的组全部对拍移植；未移植组（studylog 推进链/compass，依赖
// progress_db 移植）明确缺席，见 run_engine.dart 头注。
//
// 覆盖：
//   A. 纯函数锚点组：slugify/keywordSeq（md5 与 Python 逐位一致——锚点为
//      Python 3.12.0 实测值）/normalizeCard（ppt·exam·占位）/shouldConsume
//      矩阵/countPoints/cardViolations/searchHits 低分线/章名罗盘/大纲 deck
//      剔除/extractJsonObj 容错/balanceCandidates round-robin/composeAnchor。
//   B. studylog 纯逻辑组：分流/解析/清洗/章篇号收紧校验（六态）。
//   C. 提示词组：run-prompt 段提取（真实模板）+ 内置兜底 + asset 漂移硬门
//      （assets/prompts 拷贝与仓库源 byte-equal，skip-guard 同金样模式）。
//   D. 编排组（fake RunSearch/LlmChat/CardPort，全离线零真实网络）：
//      三级递进/通道 A 超额截断/占位兜底/LLM 失败不 consume/消费闸矩阵/
//      rework 双通道（审核拒绝优先 + dry-run 草稿）/周扫（大纲剔除+科目
//      合法性回退+配额）。
//   E. 源分级兜底链组（批4 节点①）：ppt 主源命中不做教材兜底/ppt 三级空
//      → 教材兜底命中（sourceTier=textbook 透传）/双源全空 → 占位卡
//      「语料未覆盖」口径。
//   F. 同义6条+考点多卡组（批4 节点②）：synonymQueries 上限 6/
//      extractSplitPlan（合法/缺行/坏 JSON→回退单卡路径）/subtopicsFromCardsObj
//      容错/两段式多卡（subtopic 关联+子考点超限违规）/kMaxSubtopicsPerKeyword
//      与 kMaxCardsPerSubtopic 边界/cardViolations 新规则。
import 'dart:convert';
import 'dart:io';

import 'package:hengya/services/local/corpus/exam_topics.dart';
import 'package:hengya/services/local/corpus/run_engine.dart';
import 'package:hengya/services/local/corpus/run_llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // ------------------------------------------------------ A. 纯函数锚点 ----

  test('slugifyTopic 清洗 + 章名尾缀容错（Python self-test 1）', () {
    expect(slugifyTopic('Caries Etiology!!病因'), 'caries-etiology');
    expect(slugifyTopic('  --Mixed---Case--  '), 'mixed-case');
    expect(slugifyTopic('龋病四联因素'), 'topic'); // 全中文 → 空 → fallback
    expect(slugifyTopic(null), 'topic');
    expect(stripChapterPageSuffix('第一章 绪论 / 1'), '第一章 绪论');
    expect(stripChapterPageSuffix(null), '');
  });

  test('keywordSeq：md5 确定性 3 位序号与 Python 逐位一致（2026-09-06 实测锚点）', () {
    expect(keywordSeq('龋病四联因素', 0), 191);
    expect(keywordSeq('龋病四联因素', 1), 192);
    expect(keywordSeq('牙髓炎', 0), 466);
    expect(keywordSeq('x', 0), 852);
    expect(keywordSeq('急性牙髓炎临床表现', 0), 910);
    expect(keywordSeq('龋病四联因素', 0), keywordSeq('龋病四联因素', 0)); // 幂等
    expect(keywordSeq('龋病四联因素', 0), isNot(equals(keywordSeq('牙髓炎', 0))));
    for (final kw in ['任意关键词', 'abc', '釉质发育不全的病因']) {
      expect(keywordSeq(kw), inInclusiveRange(100, 999), reason: kw);
    }
  });

  test('normalizeCard：PPT 卡 schema 落位（契约 6；anchor=deck+页码区间）', () {
    final ev = {
      'chunkId': 'c1',
      'deck': '龋病概述',
      'pageRange': '12-15',
      'title': '龋病',
      'sourceType': 'ppt',
      'text': '原文',
    };
    final card = normalizeCard(
      {
        'kind': 'ppt',
        'topic': 'caries',
        'type': 'basic',
        'front': 'F?',
        'back': 'B。',
        'evidenceChunkId': 'c1',
        'sourceTier': 'ppt',
      },
      'endo',
      '龋病四联因素',
      {'c1': ev},
    );
    expect(card['status'], 'pending');
    expect(card['sourceTier'], 'ppt');
    expect(card['anchor'], '龋病概述 p12-15');
    expect(card['id'], ''); // id 由 splitKeyword 落位
    expect(card['isPlaceholder'], false);
    expect(card['violations'], isEmpty);
    // id 形态（splitKeyword 同款拼装）：endo-caries-191（keywordSeq 锚点）
    final pptId =
        'endo-${slugifyTopic('caries')}-${keywordSeq('龋病四联因素', 0).toString().padLeft(3, '0')}';
    expect(pptId, 'endo-caries-191');
    expect(RegExp(r'^endo-caries-\d{3}$').hasMatch(pptId), isTrue);
  });

  test('normalizeCard：exam 卡 id/anchor/tags（契约 6）', () {
    final ecard = normalizeCard(
      {
        'kind': 'exam',
        'subjectId': 'endo',
        'type': 'cloze',
        'front': 'F',
        'back': 'B',
        'examMeta': {'year': '2021', 'no': '142'},
      },
      'endo',
      '',
      const {},
    );
    expect(ecard['id'], 'exam-endo-2021-142');
    expect(ecard['anchor'], '2021年第142题');
    expect((ecard['tags'] as List), contains('真题'));
    expect(ecard['sourceTier'], 'exam');
    expect(ecard['source'], '2021年真题');
    // examMeta 缺失 → CardException
    expect(
      () => normalizeCard(
        {'kind': 'exam', 'front': 'F', 'back': 'B'},
        'endo',
        '',
        const {},
      ),
      throwsA(isA<CardException>()),
    );
    // front/back 空 → CardException
    expect(
      () => normalizeCard(
        {'kind': 'ppt', 'front': ' ', 'back': 'B'},
        'endo',
        '',
        const {},
      ),
      throwsA(isA<CardException>()),
    );
  });

  test('normalizeCard：占位卡字段逐字落位 + 豁免违规检查（契约 5）', () {
    final pcard = normalizeCard(
      {
        'kind': 'ppt',
        'front': '四联因素是？',
        'back': kPlaceholderBack,
        'type': 'basic',
        'sourceTier': 'ppt',
      },
      'endo',
      '',
      const {},
    );
    expect(pcard['back'], kPlaceholderBack);
    expect(pcard['source'], kPlaceholderSource);
    expect((pcard['tags'] as List), contains('待补原文'));
    expect(pcard['anchor'], kPlaceholderAnchor);
    expect(cardViolations(pcard), isEmpty);
    // 本地兜底占位卡：全中文关键词 slug → fallback 'topic'
    final local = makePlaceholderCard('endo', '龋病四联因素', 191);
    expect(local['id'], 'endo-topic-191');
    expect(local['back'], kPlaceholderBack);
    expect(local['isPlaceholder'], true);
  });

  test('#7① normalizeCard：字段类型宽容（数组→合并/对象→跳卡），绝不抛 TypeError', () {
    final ev = {
      'chunkId': 'c1',
      'deck': '龋病概述',
      'pageRange': '12-15',
      'title': '龋病',
      'sourceType': 'ppt',
      'text': '原文',
    };
    // front/back 为 JSON 数组（#7 实锤形态）→ 逐项字符串化换行合并（可挽救）
    final card = normalizeCard(
      {
        'kind': 'ppt',
        'front': ['四联因素包括哪些？', '（多选）'],
        'back': ['细菌', '食物', '宿主', '时间'],
        'tags': ['龋病'],
        'evidenceChunkId': 'c1',
      },
      'endo',
      '龋病四联因素',
      {'c1': ev},
    );
    expect(card['front'], '四联因素包括哪些？\n（多选）');
    expect(card['back'], '细菌\n食物\n宿主\n时间');
    expect(card['anchor'], '龋病概述 p12-15');
    expect(card['isPlaceholder'], false);
    // tags 为字符串（历史 as List 崩点）→ 单标签宽容
    final card2 = normalizeCard(
      {'kind': 'ppt', 'front': 'F', 'back': 'B', 'tags': '真题'},
      'endo',
      '',
      const {},
    );
    expect(card2['tags'], ['真题']);
    // examMeta year/no 为数字 → 字符串化（历史 as String? 崩点）
    final ecard = normalizeCard(
      {
        'kind': 'exam',
        'front': 'F',
        'back': 'B',
        'examMeta': {'year': 2021, 'no': 42},
      },
      'endo',
      '',
      const {},
    );
    expect(ecard['id'], 'exam-endo-2021-42');
    // front 为 JSON 对象 → 无法挽救 → CardException 跳卡记原因（非 TypeError）
    expect(
      () => normalizeCard(
        {
          'kind': 'ppt',
          'front': {'q': 'x'},
          'back': 'B',
        },
        'endo',
        '',
        const {},
      ),
      throwsA(
        isA<CardException>().having(
          (e) => e.toString(),
          '原因',
          contains('front 为 JSON 对象'),
        ),
      ),
    );
    // 全空数组 → 合并后为空 → 与空字段同判 CardException
    expect(
      () => normalizeCard(
        {'kind': 'ppt', 'front': 'F', 'back': <Object?>[]},
        'endo',
        '',
        const {},
      ),
      throwsA(isA<CardException>()),
    );
  });

  test('shouldConsume：契约 9 消费决策矩阵', () {
    expect(shouldConsume(2, 0), true); // 插入成功
    expect(shouldConsume(0, 3), true); // 幂等收尾（0 插入有 skip）
    expect(shouldConsume(0, 0), false); // 全失败不 consume
    expect(shouldConsume(null, null), false);
  });

  test('countPoints 要点计数 + 触发词违规（契约 7）', () {
    expect(countPoints('①a\n②b\n③c\n④d\n⑤e'), 5);
    expect(countPoints(''), 0);
    expect(countPoints(null), 0);
    final v7 = cardViolations({'back': '病因以及治疗原则'});
    expect(v7.any((v) => v.contains('以及')), isTrue);
    final longBack = List.generate(6, (i) => '要点$i').join('\n');
    expect(
      cardViolations({'back': longBack}).any((v) => v.contains('要点 6 > 4')),
      isTrue,
    );
    expect(
      cardViolations({'back': 'A和B和C'}).any((v) => v.contains('疑似一卡多问')),
      isFalse,
    ); // pts<3 不标
    final v8 = cardViolations({'back': '病因和发病机制\n临床表现\n诊断与治疗'});
    expect(v8.single, '答案含「和」且要点 3≥3（疑似一卡多问，请人工复核）'); // pts>=3 且含「和」→ 标
  });

  test('searchHits：低分线过滤（0.30；_floor 覆盖）', () {
    final res = {
      'results': [
        {'score': 0.29},
        {'score': 0.31},
      ],
    };
    final hits = searchHits(res, 0.30);
    expect(hits.length, 1);
    expect(hits.first['score'], 0.31);
    expect(
      searchHits({
        'results': [
          {'score': 0.5},
        ],
        '_floor': 0.9,
      }, 0.30),
      isEmpty,
    );
    expect(
      searchHits({
        'results': [
          {'score': 0.5},
        ],
      }, null).length,
      1,
    ); // floor 缺省 0.30
  });

  test('章节罗盘：正文章过滤 + 当前章/已学章（Python self-test 8）', () {
    final entry = {
      'learned_through': 3,
      'chapters': [
        {'no': 1, 'title': '目录'},
        {'no': 2, 'title': '绪论'},
        {'no': 3, 'title': '第一篇 龋病学'},
        {'no': 4, 'title': '索引'},
      ],
    };
    expect(currentChapterTitle(entry), '第一篇 龋病学');
    expect(learnedChapterTitles(entry).map((c) => c.title).toList(), [
      '绪论',
      '第一篇 龋病学',
    ]);
    expect(currentChapterTitle(null), null);
    expect(nextChapterTitle(entry), null); // no>3 的正文章：索引被滤 → null
  });

  test('「大纲」deck 剔除（规范 §六 v1.3）', () {
    expect(examDeckOk({'deck': '2-口腔执业医师资格考试大纲'}), false);
    expect(examDeckOk({'deck': '2021年口腔执业医师资格试题（网友回忆版）'}), true);
    expect(examDeckOk({'deck': null}), true);
  });

  test('extractJsonObj：围栏/裸数组/坏输出（Python self-test 10）', () {
    expect(extractJsonObj('```json\n{"cards": [1]}\n```'), {
      'cards': [1],
    });
    expect(extractJsonObj('[{"a":1}]'), [
      {'a': 1},
    ]);
    expect(extractJsonObj('前缀 {"x": 1} 后缀'), {'x': 1});
    expect(() => extractJsonObj('这不是 JSON'), throwsA(isA<LlmException>()));
    expect(() => extractJsonObj(null), throwsA(isA<LlmException>()));
  });

  test('balanceCandidates：round-robin 科目均衡（Python self-test 11）', () {
    final bs = {
      'endo': [
        {'c': 1},
        {'c': 2},
        {'c': 3},
      ],
      'oms': [
        {'c': 4},
      ],
      'peri': [
        {'c': 5},
      ],
    };
    final sel = balanceCandidates(bs, 4, 24);
    expect(sel.length, 4);
    expect(sel.map((c) => c['c']).toList(), [1, 4, 5, 2]);
    expect(balanceCandidates(bs, 2, 24).length, 2);
    expect(balanceCandidates({}, 30, 24), isEmpty);
  });

  test('composeAnchor：deck + 页码区间（契约 6）', () {
    expect(
      composeAnchor({'deck': '龋病概述', 'pageRange': '12-15'}),
      '龋病概述 p12-15',
    );
    expect(composeAnchor(null), '? p?');
    expect(composeAnchor({'deck': '', 'pageRange': ''}), '? p?');
  });

  test('importPayload：净荷字段与内部标记剔除', () {
    final p = importPayload({
      'id': 'endo-caries-191',
      'subjectId': 'endo',
      'type': 'basic',
      'front': 'F',
      'back': 'B',
      'anchor': '',
      'source': '',
      'sourceTier': 'ppt',
      'status': 'pending',
      'tags': ['龋病'],
      'examYear': null,
      'kind': 'ppt',
      'isPlaceholder': false,
      'violations': ['x'],
    });
    expect(p['anchor'], '（无锚）');
    expect(p['source'], '课程 PPT');
    expect(p['status'], 'pending');
    expect(p.containsKey('kind'), false);
    expect(p.containsKey('isPlaceholder'), false);
    expect(p.containsKey('violations'), false);
  });

  // ------------------------------------------------------ B. studylog ----

  test('splitPendingBySource：study-log 分流（含旧条目）', () {
    final pend = [
      {'id': 1, 'subjectId': 'endo', 'keyword': '第三章', 'source': 'study-log'},
      {'id': 2, 'subjectId': 'endo', 'keyword': '干槽症', 'source': 'app'},
      {'id': 3, 'subjectId': 'endo', 'keyword': '旧条目无source'},
    ];
    final (kw, sl) = splitPendingBySource(pend);
    expect(sl.map((k) => k['id']).toList(), [1]);
    expect(kw.map((k) => k['id']).toList(), [2, 3]);
  });

  test('parseStudyLogRefs：围栏/裸数组/单串/坏输出（Python self-test 15 前半）', () {
    expect(
      parseStudyLogRefs(
        '```json\n{"chapters": ["第三章 近代变革", "第三章 近代变革", "", "第四章"]}\n```',
      ),
      ['第三章 近代变革', '第四章'],
    );
    expect(parseStudyLogRefs('["第三章"]'), ['第三章']);
    expect(parseStudyLogRefs('"第三章"'), ['第三章']);
    for (final bad in ['{"nope": 123}', '{"chapters": []}']) {
      expect(
        () => parseStudyLogRefs(bad),
        throwsA(isA<LlmException>()),
        reason: bad,
      );
    }
    // 清洗：截断 60 + 上限 40 + 保序去重
    expect(cleanStudyRefs([' a ', '', 'a', 'b']), ['a', 'b']);
  });

  test('studyHitTrustworthy：章/篇号收紧校验六态（Python self-test 15d）', () {
    expect(studyHitTrustworthy('第三章 近代变革', '第三章 近代变革·概述'), isTrue);
    expect(
      studyHitTrustworthy('第三章 近代变革', '第四篇 口腔检查与术区隔离·第二十九章 世界通史实习教程'),
      isFalse,
    );
    expect(studyHitTrustworthy('第3章 临床表现', '第三章 临床表现、诊断与治疗·第一节'), isTrue);
    expect(studyHitTrustworthy('龋病学', '第一篇 龋病学·概述'), isTrue);
    expect(studyHitTrustworthy('第一篇 龋病学', '第一篇 龋病学·第四章 龋病的治疗计划'), isTrue);
    expect(studyHitTrustworthy('第三章', '第一篇 龋病学·概述'), isFalse);
  });

  test('normalizeStudyLogRefs：LLM 规范化与降级（Python self-test 15a/15b）', () async {
    final tags = <String>[];
    Future<String> ok(String system, String user, {String tag = ''}) async {
      tags.add(tag);
      return '{"chapters": ["第三章 近代变革"]}';
    }

    final (refs, mode, _) = await normalizeStudyLogRefs(
      llmChat: ok,
      prompts: const {},
      subjectId: 'endo',
      subjectName: '世界通史',
      rawLines: ['第三章'],
    );
    expect(mode, 'llm');
    expect(refs, ['第三章 近代变革']);
    expect(tags, ['studylog']);
    Future<String> bad(String system, String user, {String tag = ''}) async {
      throw const LlmException('模拟 LLM 宕机');
    }

    final (refs2, mode2, n2) = await normalizeStudyLogRefs(
      llmChat: bad,
      prompts: const {},
      subjectId: 'endo',
      subjectName: '世界通史',
      rawLines: ['第三章', ' ', '第四章 口腔检查'],
    );
    expect(mode2, 'fallback');
    expect(refs2, ['第三章', '第四章 口腔检查']);
    expect(n2.any((n) => n.contains('降级为逐条原文引用')), isTrue);
    final (refs3, mode3, _) = await normalizeStudyLogRefs(
      llmChat: bad,
      prompts: const {},
      subjectId: 'endo',
      subjectName: '世界通史',
      rawLines: [' ', ''],
    );
    expect(mode3, 'skip');
    expect(refs3, isEmpty);
  });

  // ------------------------------------------------------ C. 提示词 ----

  test(
    'loadPrompts：真实模板 run-prompt 段提取（split/rework/synonym/studylog/weekly）',
    () {
      final mainText = File(
        'assets/prompts/主跑-22-55-server.md',
      ).readAsStringSync();
      final weeklyText = File(
        'assets/prompts/周度扫题-周日-server.md',
      ).readAsStringSync();
      final (prompts, notes) = loadPrompts([
        (name: '主跑-22-55-server.md', text: mainText),
        (name: '周度扫题-周日-server.md', text: weeklyText),
      ]);
      expect(
        prompts.keys,
        containsAll(['split', 'rework', 'synonym', 'studylog', 'weekly']),
      );
      expect(prompts['split']!, contains('占位卡'));
      expect(prompts['split']!, contains('四联因素')); // 规则逐字保留抽查
      expect(prompts['weekly']!, contains('通道 B'));
      expect(prompts['rework']!, contains('审核拒绝'));
      expect(prompts['synonym']!, contains('queries'));
      expect(prompts['studylog']!, contains('第X章'));
      expect(notes, isEmpty);
    },
  );

  test('loadPrompts：模板缺失 → 内置兜底 + note', () {
    final (prompts, notes) = loadPrompts([
      const (name: 'missing.md', text: null),
    ]);
    expect(notes.first, contains('模板缺失')); // text=null → 缺失 note
    expect(notes.last, contains('未提取到任何 run-prompt 段')); // 且整体降级 note
    expect(prompts['split'], kFallbackPrompts['split']);
    final (prompts2, notes2) = loadPrompts([
      (name: 'empty.md', text: '无标记的正文'),
    ]);
    expect(notes2.single, contains('未提取到任何 run-prompt 段'));
    expect(prompts2['weekly'], kFallbackPrompts['weekly']);
  });

  test('prompt 模板漂移硬门：assets 拷贝与仓库源 byte-equal（skip-guard）', () {
    for (final name in ['主跑-22-55-server.md', '周度扫题-周日-server.md']) {
      final asset = File(
        'assets${Platform.pathSeparator}prompts${Platform.pathSeparator}$name',
      );
      expect(asset.existsSync(), isTrue, reason: 'asset 缺失：$name');
      final src = File(
        '..${Platform.pathSeparator}automation${Platform.pathSeparator}prompts${Platform.pathSeparator}$name',
      );
      if (!src.existsSync()) {
        // ignore: avoid_print
        print('SKIP: 仓库源缺失（$name，本机为裁剪检出）');
        continue;
      }
      expect(asset.lengthSync(), src.lengthSync(), reason: name);
      expect(asset.readAsBytesSync(), src.readAsBytesSync(), reason: name);
    }
  });

  // ------------------------------------------------------ D. 编排（fake） ----

  // 共用 fake：语料检索（脚本化）+ LLM（按 tag 分派）+ 入库 Port（记录仪）。
  Map<String, Object?> Function(String) hitsByQuery(
    Map<String, List<Map<String, Object?>>> table,
  ) {
    return (q) => {
      'results': (table[q] ?? [])
          .map((r) => Map<String, Object?>.from(r))
          .toList(),
    };
  }

  const pptHitRow = {
    'chunk_id': 'endo:drill-ppt:p1',
    'deck': '龋病概述',
    'page_range': '12-15',
    'title': '龋病',
    'source_type': 'ppt',
    'text': '细菌 食物 宿主 时间',
    'score': 0.9,
  };
  // 教材兜底命中行（-textbook 树语料：subject_id 同短码、source_type=textbook）
  const textbookHitRow = {
    'chunk_id': 'endo:textbook-pdf:p20',
    'deck': '牙体牙髓病学 第5版',
    'page_range': '20-23',
    'title': '龋病',
    'source_type': 'textbook',
    'text': '四联因素：细菌、食物、宿主、时间',
    'score': 0.85,
  };
  const examHitRow = {
    'chunk_id': 'exam:2021:1',
    'deck': '2021年口腔执业医师资格试题（网友回忆版）',
    'page_range': '1-2',
    'title': '真题',
    'source_type': 'exam',
    'text': '题干与解析',
    'score': 0.8,
  };
  const examSyllabusRow = {
    'chunk_id': 'exam:dg:1',
    'deck': '2-口腔执业医师资格考试大纲',
    'page_range': '3-4',
    'title': '考纲',
    'source_type': 'exam',
    'text': '考纲条目',
    'score': 0.95,
  };

  test('splitKeyword：L1 命中全链 + 通道 A 超额截断 + id/anchor 落位', () async {
    final searchCalls = <String>[];
    final llmPayloads = <String>[];
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      searchCalls.add('$query|$subject|$sourceType|$k');
      if (sourceType == 'exam') {
        return {
          'results': [
            Map<String, Object?>.from(examHitRow),
            Map<String, Object?>.from(examSyllabusRow),
          ],
        };
      }
      return {
        'results': [Map<String, Object?>.from(pptHitRow)],
      };
    }

    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      llmPayloads.add(user);
      if (tag == 'split') {
        return jsonEncode({
          'cards': [
            {
              'kind': 'ppt',
              'topic': 'caries',
              'type': 'basic',
              'front': '龋病四联因素是哪四个？',
              'back': '①细菌②食物③宿主④时间',
              'evidenceChunkId': 'endo:drill-ppt:p1',
              'sourceTier': 'ppt',
              'tags': ['龋病'],
            },
            {
              'kind': 'ppt',
              'topic': 'caries',
              'type': 'basic',
              'front': 'F2',
              'back': 'B2',
              'evidenceChunkId': 'endo:drill-ppt:p1',
              'sourceTier': 'ppt',
            },
            {
              'kind': 'exam',
              'subjectId': 'endo',
              'type': 'cloze',
              'front': 'F',
              'back': 'B',
              'examMeta': {'year': '2021', 'no': '142'},
            },
            {
              'kind': 'exam',
              'subjectId': 'endo',
              'type': 'cloze',
              'front': 'F2',
              'back': 'B2',
              'examMeta': {'year': '2021', 'no': '143'},
            },
            {
              'kind': 'exam',
              'subjectId': 'endo',
              'type': 'cloze',
              'front': 'F3',
              'back': 'B3',
              'examMeta': {'year': '2021', 'no': '144'},
            },
          ],
        });
      }
      return '{"queries": []}';
    }

    final res = await splitKeyword(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      kw: {'id': 7, 'subjectId': 'endo', 'keyword': '龋病四联因素', 'note': ''},
      subjectName: '世界通史',
      legalSubjects: const [
        {'id': 'endo', 'name': '世界通史'},
      ],
      opts: const RunOptions(),
    );
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(res['pptHit'], true);
    expect((res['triedQueries'] as List).single, '龋病四联因素'); // L1 即命中
    expect(res['evidenceChunks'], 1);
    expect(res['examCandidates'], 1); // 「大纲」deck 被剔除
    expect(cards.length, 4); // 2 ppt + 2 exam（第 3 张 exam 超额截断）
    expect((res['notes'] as List).join(' '), contains('真题卡超额截断（上限 2）'));
    expect(cards[0]['id'], 'endo-caries-191');
    expect(cards[1]['id'], 'endo-caries-192');
    expect(cards[0]['anchor'], '龋病概述 p12-15');
    expect(cards[2]['id'], 'exam-endo-2021-142');
    expect(cards[3]['id'], 'exam-endo-2021-143');
    // split user 净荷：task/evidence/examCandidates/compass 齐全
    final payload = jsonDecode(llmPayloads.single) as Map<String, dynamic>;
    expect(payload['task'], 'split');
    expect(payload['pptHit'], true);
    expect((payload['evidence'] as List).isNotEmpty, isTrue);
    expect(payload['channelACap'], 2);
    // 真题候选检索：不带科目过滤、k=12、sourceType=exam
    expect(searchCalls.any((c) => c.endsWith('|null|exam|12')), isTrue);
    // 批4 节点①：主源证据检索钉死 sourceType=ppt；命中即止，不触发教材兜底
    expect(searchCalls.first, '龋病四联因素|endo|ppt|6');
    expect(searchCalls.any((c) => c.contains('|textbook|')), isFalse);
    expect(res['evidenceTier'], 'ppt');
  });

  test('splitKeyword：三级递进 L2（科目名+当前章名）→ L3（LLM 同义）', () async {
    final byQuery = hitsByQuery({
      '四联因素学说': [Map<String, Object?>.from(pptHitRow)],
    });
    final tried = <String>[];
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      tried.add(query);
      if (sourceType == 'exam') {
        return {'results': <Map<String, Object?>>[]};
      }
      return byQuery(query);
    }

    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      if (tag == 'synonym') {
        return '{"queries": ["四联因素学说", "龋病病因四因素"]}';
      }
      return jsonEncode({
        'cards': [
          {
            'kind': 'ppt',
            'topic': 'caries',
            'type': 'basic',
            'front': 'F?',
            'back': 'B。',
            'evidenceChunkId': 'endo:drill-ppt:p1',
            'sourceTier': 'ppt',
          },
        ],
      });
    }

    final res = await splitKeyword(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      kw: {'id': 1, 'subjectId': 'endo', 'keyword': '龋病四联因素', 'note': ''},
      subjectName: '世界通史',
      progressEntry: {
        'learned_through': 3,
        'chapters': [
          {'no': 2, 'title': '绪论'},
          {'no': 3, 'title': '第一篇 龋病学'},
        ],
      },
      legalSubjects: const [],
      opts: const RunOptions(),
    );
    expect(res['triedQueries'], ['龋病四联因素', '世界通史 第一篇 龋病学', '四联因素学说']);
    expect(res['pptHit'], true);
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(cards.single['anchor'], '龋病概述 p12-15');
  });

  test('splitKeyword：三级全未命中 → 本地占位卡兜底（契约 5，绝不臆造）', () async {
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      return {'results': <Map<String, Object?>>[]};
    }

    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      if (tag == 'synonym') {
        return '{"queries": []}';
      }
      return jsonEncode({
        'cards': [
          {
            'kind': 'exam',
            'subjectId': 'endo',
            'type': 'basic',
            'front': 'F',
            'back': 'B',
            'examMeta': {'year': '2021', 'no': '99'},
          },
        ],
      });
    }

    final res = await splitKeyword(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      kw: {'id': 3, 'subjectId': 'endo', 'keyword': '白斑癌变', 'note': ''},
      subjectName: '口腔病理学',
      legalSubjects: const [],
      opts: const RunOptions(),
    );
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(res['pptHit'], false);
    expect(cards.length, 2); // LLM 的 exam 卡 + 本地占位兜底
    expect(cards.first['id'], 'exam-endo-2021-99');
    final ph = cards.last;
    expect(ph['isPlaceholder'], true);
    expect(ph['back'], kPlaceholderBack);
    expect(ph['front'], '白斑癌变');
    expect(RegExp(r'^endo-topic-\d{3}$').hasMatch(ph['id'] as String), isTrue);
  });

  // -------------------------------------- E. 源分级兜底链（批4 节点①） ----

  test('批4① splitKeyword：ppt 三级未命中 → 教材兜底命中（sourceTier=textbook 透传）', () async {
    final searchCalls = <String>[];
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      searchCalls.add('$query|$subject|$sourceType|$k');
      if (sourceType == kSplitFallbackSourceType && query == '白斑癌变') {
        return {
          'results': [Map<String, Object?>.from(textbookHitRow)],
        };
      }
      return {'results': <Map<String, Object?>>[]}; // ppt 三级全空 / exam 空
    }

    // LLM 未标 sourceTier/source（考验引擎确定性兜底改写）
    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      if (tag == 'split') {
        return jsonEncode({
          'cards': [
            {
              'kind': 'ppt',
              'topic': 'leukoplakia',
              'type': 'basic',
              'front': '白斑癌变的高危因素有哪些？',
              'back': '①白斑类型②部位③病程',
              'evidenceChunkId': 'endo:textbook-pdf:p20',
            },
          ],
        });
      }
      return '{"queries": []}'; // 无同义 → 教材兜底只重放原句
    }

    final res = await splitKeyword(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      kw: {'id': 11, 'subjectId': 'endo', 'keyword': '白斑癌变', 'note': ''},
      subjectName: '口腔黏膜病学',
      legalSubjects: const [],
      opts: const RunOptions(),
    );
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(res['pptHit'], true, reason: '教材兜底命中=有效证据命中（两级语义）');
    expect(res['evidenceTier'], 'textbook');
    expect((res['notes'] as List).join(' '), contains('教材兜底命中'));
    expect(cards.single['sourceTier'], 'textbook');
    expect(cards.single['source'], '教材'); // 缺省「课程 PPT」→ 教材口径
    expect(cards.single['anchor'], '牙体牙髓病学 第5版 p20-23');
    expect(cards.single['isPlaceholder'], false);
    // 检索链：ppt 主源（原句+科目名，三级内）→ 教材兜底重放原句命中即止
    // → exam 候选；兜底重放不产生额外 synonym LLM 调用。
    expect(searchCalls, [
      '白斑癌变|endo|ppt|6',
      '口腔黏膜病学|endo|ppt|6',
      '白斑癌变|endo|textbook|6',
      '白斑癌变|null|exam|12',
    ]);
  });

  test('批4① splitKeyword：ppt+教材双源全空 → 占位卡「语料未覆盖」口径', () async {
    final searchCalls = <String>[];
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      searchCalls.add('$query|$subject|$sourceType|$k');
      return {'results': <Map<String, Object?>>[]};
    }

    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      if (tag == 'synonym') {
        return '{"queries": ["白斑恶变"]}';
      }
      return jsonEncode({'cards': []}); // LLM 未给占位卡 → 本地兜底
    }

    final res = await splitKeyword(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      kw: {'id': 12, 'subjectId': 'endo', 'keyword': '白斑癌变', 'note': ''},
      subjectName: '口腔黏膜病学',
      legalSubjects: const [],
      opts: const RunOptions(),
    );
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(res['pptHit'], false);
    expect(res['evidenceTier'], isNull);
    final ph = cards.single;
    expect(ph['isPlaceholder'], true);
    expect(ph['back'], kPlaceholderBack);
    expect(ph['back'], contains('语料未覆盖'));
    expect(ph['source'], kPlaceholderSource);
    expect(ph['source'], '语料未覆盖·占位待补');
    expect(ph['anchor'], kPlaceholderAnchor);
    expect((ph['tags'] as List), contains('待补原文'));
    expect(ph['sourceTier'], 'ppt'); // 占位卡 tier 不变
    // 检索链：ppt（原句/科目名/同义）→ 教材重放同批三级 → exam 候选
    expect(searchCalls, [
      '白斑癌变|endo|ppt|6',
      '口腔黏膜病学|endo|ppt|6',
      '白斑恶变|endo|ppt|6',
      '白斑癌变|endo|textbook|6',
      '口腔黏膜病学|endo|textbook|6',
      '白斑恶变|endo|textbook|6',
      '白斑癌变|null|exam|12',
    ]);
  });

  test('splitKeyword：LLM 失败 → status=failed 不出卡（契约 9/10）', () async {
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      return {'results': <Map<String, Object?>>[]};
    }

    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      throw const LlmException('模拟 LLM 宕机');
    }

    final res = await splitKeyword(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      kw: {'id': 4, 'subjectId': 'endo', 'keyword': '干槽症', 'note': ''},
      subjectName: '口腔颌面外科学',
      legalSubjects: const [],
      opts: const RunOptions(),
    );
    expect(res['status'], 'failed');
    expect(res['error'], contains('模拟 LLM 宕机'));
    expect((res['cards'] as List), isEmpty);
    expect((res['notes'] as List).join(' '), contains('同义扩展失败')); // L3 降级 note
  });

  test('#7 splitKeyword：畸形卡（back/front 数组/对象）不炸整轮，其余卡完好', () async {
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      if (sourceType == 'exam') {
        return {'results': <Map<String, Object?>>[]};
      }
      return {
        'results': [Map<String, Object?>.from(pptHitRow)],
      };
    }

    // LLM 输出混入畸形卡：卡2 back=数组（可挽救）、卡3 front=对象（不可挽救）
    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      if (tag == 'split') {
        return jsonEncode({
          'cards': [
            {
              'kind': 'ppt',
              'front': '正常卡正面',
              'back': '正常卡背面',
              'evidenceChunkId': 'endo:drill-ppt:p1',
            },
            {
              'kind': 'ppt',
              'front': ['数组正面1', '数组正面2'],
              'back': ['细菌', '食物', '宿主', '时间'],
              'evidenceChunkId': 'endo:drill-ppt:p1',
            },
            {
              'kind': 'ppt',
              'front': {'不可挽救': '对象'},
              'back': 'B',
            },
            {
              'kind': 'ppt',
              'front': '正常卡2正面',
              'back': '正常卡2背面',
              'evidenceChunkId': 'endo:drill-ppt:p1',
            },
          ],
        });
      }
      return '{"queries": []}';
    }

    // 修复前：normalizeCard 的 as String? 对 List/Map 抛 TypeError 炸穿整轮；
    // 修复后：#7① 类型宽容 + #7② catch 扩围 → 整轮完成、好卡全保。
    final res = await splitKeyword(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      kw: {'id': 9, 'subjectId': 'endo', 'keyword': '龋病四联因素', 'note': ''},
      subjectName: '世界通史',
      legalSubjects: const [],
      opts: const RunOptions(),
    );
    expect(res['status'], 'ok', reason: '畸形卡不得中断整轮');
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(cards.length, 3, reason: '卡1+卡2（数组合并挽救）+卡4；卡3 跳过');
    expect(cards[0]['front'], '正常卡正面');
    expect(cards[1]['front'], '数组正面1\n数组正面2');
    expect(cards[1]['back'], '细菌\n食物\n宿主\n时间');
    expect(cards[2]['front'], '正常卡2正面');
    expect(cards[2]['back'], '正常卡2背面');
    final notes = (res['notes'] as List).join(' ');
    expect(notes, contains('单卡归一化失败（跳过该卡）'), reason: '跳卡原因入账');
    expect(notes, contains('front 为 JSON 对象'), reason: '无法挽救原因可诊断');
  });

  test('importKeywordCards：消费闸矩阵 + import 失败不 consume（契约 9）', () async {
    final kwres = <String, Object?>{
      'inboxId': 9,
      'cards': [
        {'id': 'endo-caries-191'},
        {'id': 'exam-endo-2021-142'},
      ],
    };
    // dry-run → 不动 Port
    final portDry = _RecorderPort();
    await importKeywordCards(portDry, kwres, const RunOptions(dryRun: true));
    expect(portDry.log, isEmpty);
    expect((kwres['import'] as Map)['note'], 'dry-run 未 import');
    // 插入成功 → consume
    final kw2 = Map<String, Object?>.of(kwres);
    await importKeywordCards(
      _RecorderPort(inserted: 2),
      kw2,
      const RunOptions(),
    );
    expect((kw2['import'] as Map)['consumed'], true);
    expect((kw2['import'] as Map)['inserted'], 2);
    // 0 插入有 skip → 幂等收尾 consume
    final kw3 = Map<String, Object?>.of(kwres);
    final port3 = _RecorderPort(inserted: 0, skipped: 3);
    await importKeywordCards(port3, kw3, const RunOptions());
    expect((kw3['import'] as Map)['consumed'], true);
    expect(port3.log, ['import:2', 'consume:[9]']);
    // 全 0 → 不 consume
    final kw4 = Map<String, Object?>.of(kwres);
    final port4 = _RecorderPort(inserted: 0, skipped: 0);
    await importKeywordCards(port4, kw4, const RunOptions());
    expect((kw4['import'] as Map)['consumed'], false);
    expect(port4.log, ['import:2']); // import 调过（全 0 插入），仅不 consume
    // import 失败 → import_failed + 不 consume
    final kw5 = Map<String, Object?>.of(kwres);
    final port5 = _RecorderPort(importOk: false);
    await importKeywordCards(port5, kw5, const RunOptions());
    expect(kw5['status'], 'import_failed');
    expect((kw5['import'] as Map)['consumed'], isNot(true));
    expect(port5.log.single, 'import:2');
  });

  test('processRework：双通道闭环（审核拒绝优先 + dry-run 草稿 + done 顺序）', () async {
    final doneCalls = <String>[];
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      return {'results': <Map<String, Object?>>[]};
    }

    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      return '{"front": "新题干", "back": "新答案", "evidenceChunkId": ""}';
    }

    final queue = [
      {
        'id': 5,
        'cardId': 'c5',
        'subjectId': 'endo',
        'front': '旧题干',
        'back': '旧答案',
        'anchor': 'p.1',
        'reason': '表述绕',
      },
      {
        'id': 2,
        'cardId': 'c2',
        'subjectId': 'endo',
        'front': 'x',
        'back': 'y',
        'anchor': '',
        'reason': '审核拒绝：答案有误',
      },
    ];
    final notes = [
      {'cardId': 'c2', 'aiNote': '希望更短'},
    ];
    // dry-run：只出草稿不 done
    final dry = await processRework(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      queue: queue,
      aiNotes: notes,
      subjectNames: {'endo': '世界通史'},
      opts: const RunOptions(dryRun: true),
    );
    expect(dry.length, 2);
    expect(dry.every((r) => r['draft'] == true), isTrue);
    expect(doneCalls, isEmpty);
    expect(dry.first['queueId'], 2); // 审核拒绝排前
    expect(dry.first['aiNotesRead'], 1); // aiNotes 注入重写参考
    // 非 dry-run：逐条 done，顺序 [2, 5]
    final port = _RecorderPort()..onDone = doneCalls.add;
    final live = await processRework(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      queue: queue,
      aiNotes: notes,
      subjectNames: {'endo': '世界通史'},
      opts: const RunOptions(),
      port: port,
    );
    expect(doneCalls, ['done:2:新题干', 'done:5:新题干']);
    expect(live.every((r) => r['done'] == true), isTrue);
    expect(live.first['back'], '新答案');
    expect(live.first['anchor'], ''); // queueId 2（审核拒绝优先）原锚为空
    expect(live.last['anchor'], 'p.1'); // queueId 5 证据缺失 → 保留原锚
  });

  test('runWeekly：大纲剔除 + 去重 + 均衡 + 科目合法性回退 + 配额（通道 B）', () async {
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      if (query == '龋病') {
        return {
          'results': [
            Map<String, Object?>.from(examHitRow),
            Map<String, Object?>.from(examSyllabusRow),
            Map<String, Object?>.from(examHitRow), // 重复 chunk → 去重
          ],
        };
      }
      if (query == '釉质发育') {
        return {
          'results': [
            {
              'chunk_id': 'exam:2021:3',
              'deck': '2021年口腔执业医师资格试题（网友回忆版）',
              'page_range': '3-3',
              'title': 't3',
              'source_type': 'exam',
              'text': '题三',
              'score': 0.85,
            },
          ],
        };
      }
      return {'results': <Map<String, Object?>>[]};
    }

    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      return jsonEncode({
        'cards': [
          {
            'subjectId': 'bogus', // 非法科目 → 回退候选所属章科目
            'type': 'basic',
            'front': 'f',
            'back': 'b',
            'evidenceChunkId': 'exam:2021:1',
            'examMeta': {'year': '2021', 'no': '1'},
          },
          {
            'subjectId': 'omo',
            'type': 'basic',
            'front': 'f2',
            'back': 'b2',
            'evidenceChunkId': 'exam:2021:3',
            'examMeta': {'year': '2021', 'no': '3'},
          },
        ],
      });
    }

    final port = _RecorderPort();
    final notes = <String>[];
    final res = await runWeekly(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      chapters: [
        {'subject': 'endo', 'subjectName': '世界通史', 'chapter': '龋病'},
        {'subject': 'omo', 'subjectName': '口腔病理', 'chapter': '釉质发育'},
      ],
      legalSubjects: const [
        {'id': 'endo', 'name': '世界通史'},
        {'id': 'omo', 'name': '口腔病理'},
      ],
      opts: const RunOptions(),
      port: port,
      notes: notes,
    );
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(res['excludedSyllabus'], 1); // 「大纲」deck 剔除
    final counts = res['counts'] as Map<String, Object?>;
    expect(
      counts['candidates'],
      3,
    ); // 去重后 2 + 大纲剔除 1 也计入（Python 口径 len(seen)+excluded）
    expect(counts['afterBalance'], 2);
    expect(cards.length, 2);
    expect(cards[0]['subjectId'], 'endo'); // bogus → 回退 endo
    expect(cards[0]['id'], 'exam-endo-2021-1');
    expect(cards[1]['id'], 'exam-omo-2021-3');
    expect(counts['imported'], 2);
    expect(port.log.first, 'import:2');
    // LLM 失败 → llmError + 不出卡
    final notes2 = <String>[];
    final res2 = await runWeekly(
      runSearch: fakeSearch,
      llmChat: (system, user, {tag = ''}) async =>
          throw const LlmException('模拟周扫宕机'),
      prompts: const {},
      chapters: [
        {'subject': 'endo', 'subjectName': '世界通史', 'chapter': '龋病'},
      ],
      legalSubjects: const [
        {'id': 'endo', 'name': '世界通史'},
      ],
      opts: const RunOptions(dryRun: true),
      notes: notes2,
    );
    expect(res2['llmError'], contains('模拟周扫宕机'));
    expect((res2['cards'] as List), isEmpty);
  });

  // ---------------------- G. 节点⑤ 周扫接线（技能门控/examMeta 兜底/空态） ----

  /// G 组共用：单行检索结果包装。
  Future<Map<String, Object?>> searchOf(Map<String, Object?> row) =>
      Future.value({'results': [row]});

  test('⑤ runWeekly：技能五站豁免已学门控 + 每类 ≤kWeeklySkillCapPerTopic 封顶', () async {
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      if (subject == 'bingshi') {
        return {
          'results': [
            for (var i = 1; i <= 4; i++)
              {
                'chunk_id': 'exam:bs:$i',
                'deck': '2021年口腔执业医师实践技能试题（网友回忆版）',
                'page_range': '$i-$i',
                'title': '病史采集题$i',
                'source_type': 'exam',
                'text': '题干$i',
                'score': 0.8,
              },
          ],
        };
      }
      if (subject == 'caozuo') {
        return {
          'results': [
            for (var i = 1; i <= 2; i++)
              {
                'chunk_id': 'exam:cz:$i',
                'deck': '2022年口腔执业医师实践技能试题（网友回忆版）',
                'page_range': '$i-$i',
                'title': '操作技能题$i',
                'source_type': 'exam',
                'text': '题干$i',
                'score': 0.8,
              },
          ],
        };
      }
      return {'results': <Map<String, Object?>>[]};
    }

    var llmCalls = 0;
    Future<String> fakeLlm(String system, String user, {String tag = ''}) async {
      llmCalls += 1;
      return jsonEncode({
        'cards': [
          // bingshi 4 张（超每类 3 上限 → 截 1）+ caozuo 2 张（未超）
          for (var i = 1; i <= 4; i++)
            {
              'subjectId': 'endo',
              'type': 'basic',
              'front': '病史采集卡$i',
              'back': '答$i',
              'evidenceChunkId': 'exam:bs:$i',
              'examMeta': {'year': '2021', 'no': '$i'},
            },
          for (var i = 1; i <= 2; i++)
            {
              'subjectId': 'endo',
              'type': 'basic',
              'front': '操作技能卡$i',
              'back': '答$i',
              'evidenceChunkId': 'exam:cz:$i',
              'examMeta': {'year': '2022', 'no': '$i'},
            },
        ],
      });
    }

    final res = await runWeekly(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      chapters: const [], // 无已学章——豁免证明：仅靠技能专题直检出卡
      legalSubjects: const [
        {'id': 'endo', 'name': '牙体牙髓病学'},
      ],
      opts: const RunOptions(dryRun: true),
      skillTopics: const [
        ExamTopic(code: 'bingshi', name: '病史采集类', isSkill: true),
        ExamTopic(code: 'caozuo', name: '操作技能类', isSkill: true),
      ],
    );
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(llmCalls, 1);
    expect(cards.length, 5, reason: 'bingshi 封顶 3 + caozuo 2');
    expect(
      cards
          .where((c) => c['front'].toString().startsWith('病史采集卡'))
          .length,
      3,
      reason: '技能每类 ≤kWeeklySkillCapPerTopic=3',
    );
    expect(
      cards
          .where((c) => c['front'].toString().startsWith('操作技能卡'))
          .length,
      2,
    );
    final counts = res['counts'] as Map<String, Object?>;
    expect(counts['skillCandidates'], 6);
    expect((counts['skillByTopic'] as Map)['bingshi'], 3);
    expect((counts['skillByTopic'] as Map)['caozuo'], 2);
    expect(
      (res['notes'] as List).join('\n'),
      contains('技能专题出卡超额截断（病史采集类 ≤3）'),
    );
    expect(counts['cards'], 5, reason: '技能卡计入总量（≤kWeeklyExamCap=30）');
  });

  test('⑤ runWeekly：非技能保持严格已学门控（命中/跳过）+ 技能卡科目非法宁漏不错', () async {
    // ① 命中分支：已学章「龋病」检索 → 出卡；未学章「釉质发育」绝不被检索
    final queries = <String>[];
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      queries.add(query);
      return searchOf({
        'chunk_id': 'exam:g:$query',
        'deck': '2021年口腔执业医师资格试题（网友回忆版）',
        'page_range': '1-2',
        'title': '真题',
        'source_type': 'exam',
        'text': '题干',
        'score': 0.8,
      });
    }

    final res1 = await runWeekly(
      runSearch: fakeSearch,
      llmChat: (system, user, {tag = ''}) async => jsonEncode({
        'cards': [
          {
            'subjectId': 'endo',
            'type': 'basic',
            'front': 'F',
            'back': 'B',
            'evidenceChunkId': 'exam:g:龋病',
            'examMeta': {'year': '2021', 'no': '1'},
          },
        ],
      }),
      prompts: const {},
      chapters: const [
        {'subject': 'endo', 'subjectName': '牙体牙髓病学', 'chapter': '龋病'},
      ],
      legalSubjects: const [
        {'id': 'endo', 'name': '牙体牙髓病学'},
      ],
      opts: const RunOptions(dryRun: true),
    );
    expect((res1['cards'] as List).length, 1, reason: '已学章命中 → 出卡');
    expect(queries, ['龋病'], reason: '只检索已学章（未学章不检索不出卡）');

    // ② 跳过分支：无已学章 → 零候选、LLM 不调用、零出卡
    var llmCalls = 0;
    final res2 = await runWeekly(
      runSearch: fakeSearch,
      llmChat: (system, user, {tag = ''}) async {
        llmCalls += 1;
        return '{"cards": []}';
      },
      prompts: const {},
      chapters: const [],
      legalSubjects: const [
        {'id': 'endo', 'name': '牙体牙髓病学'},
      ],
      opts: const RunOptions(),
    );
    expect(llmCalls, 0, reason: '零候选不进 LLM');
    expect((res2['counts'] as Map)['afterBalance'], 0);
    expect((res2['cards'] as List), isEmpty);

    // ③ 技能卡科目非法（LLM 抄了专题短码）→ 宁漏不错跳过，不落 unknown 废卡
    final res3 = await runWeekly(
      runSearch: fakeSearch,
      llmChat: (system, user, {tag = ''}) async => jsonEncode({
        'cards': [
          {
            'subjectId': 'bingshi', // 非法：专题短码不在 subjects 表
            'type': 'basic',
            'front': 'F',
            'back': 'B',
            'evidenceChunkId': 'exam:g:病史采集类',
            'examMeta': {'year': '2021', 'no': '2'},
          },
        ],
      }),
      prompts: const {},
      chapters: const [],
      legalSubjects: const [
        {'id': 'endo', 'name': '牙体牙髓病学'},
      ],
      opts: const RunOptions(dryRun: true),
      skillTopics: const [
        ExamTopic(code: 'bingshi', name: '病史采集类', isSkill: true),
      ],
    );
    expect((res3['cards'] as List), isEmpty, reason: '科目非法 → 跳过不出卡');
    expect(
      (res3['notes'] as List).join('\n'),
      contains('技能真题卡科目非法（bingshi）'),
    );
  });

  test('⑤ runWeekly：examMeta 兜底（deck 名年份 + deck 内页序；严禁臆造）', () async {
    // ① 正例：LLM 未给 examMeta → 年份取 deck 名「2021年…」、题号取页序 12
    final res = await runWeekly(
      runSearch: (query, {subject, sourceType, k}) async => searchOf({
        'chunk_id': 'exam:2021:p12',
        'deck': '2021年口腔执业医师资格试题（网友回忆版）',
        'page_range': '12-12',
        'title': '真题',
        'source_type': 'exam',
        'text': '题干与解析',
        'score': 0.8,
      }),
      llmChat: (system, user, {tag = ''}) async => jsonEncode({
        'cards': [
          {
            'subjectId': 'endo',
            'type': 'basic',
            'front': 'F',
            'back': 'B',
            'evidenceChunkId': 'exam:2021:p12',
            // 无 examMeta——触发本地兜底
          },
        ],
      }),
      prompts: const {},
      chapters: const [
        {'subject': 'endo', 'subjectName': '牙体牙髓病学', 'chapter': '龋病'},
      ],
      legalSubjects: const [
        {'id': 'endo', 'name': '牙体牙髓病学'},
      ],
      opts: const RunOptions(dryRun: true),
    );
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(cards.length, 1);
    final card = cards.single;
    expect(card['id'], 'exam-endo-2021-12', reason: '兜底年份/题号进幂等 id');
    expect(card['anchor'], '2021年第12题');
    expect(card['examYear'], '2021');
    expect(
      (card['source'] as String).contains('examMeta 兜底'),
      isTrue,
      reason: '兜底来源在卡 source 注明（B3 拍板）',
    );
    final counts = res['counts'] as Map<String, Object?>;
    expect(counts['examMetaFallback'], 1);
    expect(
      (res['notes'] as List).join('\n'),
      contains('examMeta 兜底：1 张'),
    );

    // ② 反例：deck 名无年份 → 解析不出绝不臆造，跳卡（宁漏不错）
    final res2 = await runWeekly(
      runSearch: (query, {subject, sourceType, k}) async => searchOf({
        'chunk_id': 'exam:x:5',
        'deck': '口腔执业医师真题汇编',
        'page_range': '5-5',
        'title': '真题',
        'source_type': 'exam',
        'text': '题干与解析',
        'score': 0.8,
      }),
      llmChat: (system, user, {tag = ''}) async => jsonEncode({
        'cards': [
          {
            'subjectId': 'endo',
            'type': 'basic',
            'front': 'F',
            'back': 'B',
            'evidenceChunkId': 'exam:x:5',
          },
        ],
      }),
      prompts: const {},
      chapters: const [
        {'subject': 'endo', 'subjectName': '牙体牙髓病学', 'chapter': '龋病'},
      ],
      legalSubjects: const [
        {'id': 'endo', 'name': '牙体牙髓病学'},
      ],
      opts: const RunOptions(dryRun: true),
    );
    expect((res2['cards'] as List), isEmpty, reason: '年份兜不出 → 跳卡不臆造');
    expect((res2['notes'] as List).join('\n'), contains('缺 examMeta'));
  });

  test('⑤ runWeekly：双空态静默（无章节无技能 / 无真题语料）——零结果不报错', () async {
    // ① chapters=[] 且无技能专题 → LLM 不调用、零候选零卡零导入
    var llmCalls = 0;
    final res1 = await runWeekly(
      runSearch: (query, {subject, sourceType, k}) async =>
          {'results': <Object?>[]},
      llmChat: (system, user, {tag = ''}) async {
        llmCalls += 1;
        return '{"cards": []}';
      },
      prompts: const {},
      chapters: const [],
      legalSubjects: const [
        {'id': 'endo', 'name': '牙体牙髓病学'},
      ],
      opts: const RunOptions(),
    );
    expect(llmCalls, 0);
    expect((res1['counts'] as Map)['cards'], 0);
    expect(res1['llmError'], isNull);
    expect(res1['importError'], isNull);

    // ② 本机无 -exam 真题语料（检索恒抛 SearchException）→ 降级零结果不上抛
    final res2 = await runWeekly(
      runSearch: (query, {subject, sourceType, k}) async =>
          throw const SearchException('corpus.db 不存在或无法打开'),
      llmChat: (system, user, {tag = ''}) async {
        llmCalls += 1;
        return '{"cards": []}';
      },
      prompts: const {},
      chapters: const [
        {'subject': 'endo', 'subjectName': '牙体牙髓病学', 'chapter': '龋病'},
      ],
      legalSubjects: const [
        {'id': 'endo', 'name': '牙体牙髓病学'},
      ],
      opts: const RunOptions(),
      skillTopics: const [
        ExamTopic(code: 'bingshi', name: '病史采集类', isSkill: true),
      ],
    );
    expect(llmCalls, 0, reason: '检索全降级 → 零候选不进 LLM');
    expect((res2['counts'] as Map)['cards'], 0);
    expect(res2['llmError'], isNull, reason: '静默：不报错');
    expect((res2['notes'] as List).join('\n'), contains('周扫检索降级'));
    expect((res2['notes'] as List).join('\n'), contains('技能专题检索降级'));
  });

  // ---------------------------- F. 同义6条+考点多卡（批4 节点②） ----

  test('批4② cardViolations：子考点数/单子考点卡数新规则（契约 7 扩展）', () {
    expect(cardViolations({'back': 'B'}), isEmpty); // 无子考点上下文 → 不加新违规
    // 边界：=上限不违规
    expect(
      cardViolations({'back': 'B'}, subtopicTotal: kMaxSubtopicsPerKeyword),
      isEmpty,
    );
    expect(
      cardViolations({'back': 'B'}, subtopicCardCount: kMaxCardsPerSubtopic),
      isEmpty,
    );
    // 超限 → 标记（照既有路径：只标记进报告，不拦截）
    expect(
      cardViolations({'back': 'B'}, subtopicTotal: 7).single,
      '子考点数 7 > 6',
    );
    expect(
      cardViolations({'back': 'B'}, subtopicCardCount: 3).single,
      '单子考点出卡 3 > 2',
    );
    // 占位卡仍免检
    expect(
      cardViolations({'isPlaceholder': true, 'back': 'x'}, subtopicTotal: 9),
      isEmpty,
    );
    // 既有规则与新增可叠加
    final both = cardViolations(
      {'back': '①a\n②b\n③c\n④d\n⑤e\n⑥f'},
      subtopicTotal: 7,
    );
    expect(both.where((v) => v.contains('要点 6 > 4')), isNotEmpty);
    expect(both.where((v) => v.contains('子考点数 7 > 6')), isNotEmpty);
  });

  test('批4② synonymQueries：上限 6（kMaxSynonymQueries，上限非配额）', () async {
    Future<String> many(String system, String user, {String tag = ''}) async {
      return jsonEncode({
        'queries': ['一', '二', '三', '四', '五', '六', '七', '八'],
      });
    }

    final notes = <String>[];
    expect(
      await synonymQueries(many, const {}, notes, '龋病', '牙体牙髓病学'),
      ['一', '二', '三', '四', '五', '六'], // 第 7、8 条引擎侧截断
    );
    Future<String> few(String system, String user, {String tag = ''}) async {
      return '{"queries": ["a", "b"]}';
    }

    expect(
      await synonymQueries(few, const {}, notes, '龋病', '牙体牙髓病学'),
      ['a', 'b'], // 不足上限照给（上限不是配额）
    );
  });

  test('批4② extractSplitPlan：合法/缺行/坏 JSON/空载荷（回退口径）', () {
    // 合法：计划行 + cards JSON（rest 剥除计划行后照旧可解析）
    const c1 = 'plan:{"subtopics":["病因","临床表现","治疗"]}\n{"cards":[]}';
    final (p1, r1) = extractSplitPlan(c1);
    expect(p1, ['病因', '临床表现', '治疗']);
    expect(r1.trim(), '{"cards":[]}');
    // 缺行：原样返回（旧格式完全兼容）
    const c2 = '{"cards":[1]}';
    final (p2, r2) = extractSplitPlan(c2);
    expect(p2, isNull);
    expect(r2, c2);
    // 坏 JSON：计划行仍剥除（避免污染 extractJsonObj 包裹扫描），回退单卡
    const c3 = 'plan:{"subtopics":[broken}\n{"cards":[]}';
    final (p3, r3) = extractSplitPlan(c3);
    expect(p3, isNull);
    expect(r3.trim(), '{"cards":[]}');
    // 空数组/非数组载荷 → null；单字符串 → 单元素
    expect(extractSplitPlan('plan:{"subtopics":[]}\n{}').$1, isNull);
    expect(extractSplitPlan('plan:{"subtopics":123}\n{}').$1, isNull);
    expect(extractSplitPlan('plan:{"subtopics":"病因"}\n{}').$1, ['病因']);
    // 行首空白 / plan: 后空格 / CRLF 行尾也认
    expect(
      extractSplitPlan('  plan: {"subtopics":["x"]}\n{"cards":[]}').$1,
      ['x'],
    );
    expect(
      extractSplitPlan('plan:{"subtopics":["x"]}\r\n{"cards":[]}').$1,
      ['x'],
    );
  });

  test('批4② subtopicsFromCardsObj：计划放进 cards JSON 顶层的容错', () {
    expect(subtopicsFromCardsObj({'plan': {'subtopics': ['a', 'b']}}), [
      'a',
      'b',
    ]);
    expect(subtopicsFromCardsObj({'subtopics': ['a']}), ['a']);
    expect(subtopicsFromCardsObj({'cards': []}), isNull);
    expect(subtopicsFromCardsObj(<String, Object?>{}), isNull);
    expect(subtopicsFromCardsObj(null), isNull);
    expect(subtopicsFromCardsObj(<Object?>[]), isNull);
  });

  test('批4② splitKeyword：两段式多卡（plan 行 + subtopic 关联 + 超限违规）', () async {
    final llmPayloads = <String>[];
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      if (sourceType == 'exam') {
        return {'results': <Map<String, Object?>>[]};
      }
      return {
        'results': [Map<String, Object?>.from(pptHitRow)],
      };
    }

    // 7 子考点（>6 违规）+「病因」子考点 3 张卡（>2 违规）
    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      llmPayloads.add(user);
      if (tag == 'split') {
        final cardsJson = jsonEncode({
          'cards': [
            for (var i = 0; i < 3; i++)
              {
                'kind': 'ppt',
                'topic': 'caries',
                'subtopic': '病因',
                'type': 'basic',
                'front': 'F$i',
                'back': 'B$i',
                'evidenceChunkId': 'endo:drill-ppt:p1',
                'sourceTier': 'ppt',
              },
          ],
        });
        return 'plan:{"subtopics":["病因","分类","临床表现","治疗","预防","并发症","流行病学"]}\n'
            '$cardsJson';
      }
      return '{"queries": []}';
    }

    final res = await splitKeyword(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      kw: {'id': 21, 'subjectId': 'endo', 'keyword': '龋病四联因素', 'note': ''},
      subjectName: '牙体牙髓病学',
      legalSubjects: const [],
      opts: const RunOptions(),
    );
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(res['status'], 'ok');
    expect(res['subtopics'], hasLength(7));
    expect(cards, hasLength(3));
    // 「关键词→子考点→卡」对齐：subtopic 关联字段落位（内部标记，不进 import）
    expect(cards.every((c) => c['subtopic'] == '病因'), isTrue);
    expect(cards[0]['id'], 'endo-caries-191'); // seq 仍连续落位
    expect(cards[2]['id'], 'endo-caries-193');
    // 新违规：子考点数 7>6（全部卡）+ 单子考点出卡 3>2（该子考点的卡）
    for (final c in cards) {
      final vs = (c['violations'] as List).cast<String>();
      expect(vs, contains('子考点数 7 > 6'));
      expect(vs, contains('单子考点出卡 3 > 2'));
    }
    // split user 净荷带 maxSubtopics（LLM 侧上限提示）
    final payload = jsonDecode(llmPayloads.single) as Map<String, dynamic>;
    expect(payload['maxSubtopics'], kMaxSubtopicsPerKeyword);
  });

  test('批4② kMaxSubtopicsPerKeyword/kMaxCardsPerSubtopic 边界：6×≤2 不违规', () async {
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      if (sourceType == 'exam') {
        return {'results': <Map<String, Object?>>[]};
      }
      return {
        'results': [Map<String, Object?>.from(pptHitRow)],
      };
    }

    final subs = ['一', '二', '三', '四', '五', '六'];
    Future<String> fakeLlm(
      String system,
      String user, {
      String tag = '',
    }) async {
      if (tag == 'split') {
        final cardsJson = jsonEncode({
          'cards': [
            for (var i = 0; i < subs.length; i++)
              for (var j = 0; j < (i == 0 ? 2 : 1); j++)
                {
                  'kind': 'ppt',
                  'topic': 't$i$j',
                  'subtopic': subs[i],
                  'front': 'F$i$j',
                  'back': 'B$i$j',
                  'evidenceChunkId': 'endo:drill-ppt:p1',
                },
          ],
        });
        return 'plan:${jsonEncode({'subtopics': subs})}\n$cardsJson';
      }
      return '{"queries": []}';
    }

    final res = await splitKeyword(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      kw: {'id': 22, 'subjectId': 'endo', 'keyword': '龋病', 'note': ''},
      subjectName: '牙体牙髓病学',
      legalSubjects: const [],
      opts: const RunOptions(),
    );
    final cards = (res['cards'] as List).cast<Map<String, Object?>>();
    expect(res['subtopics'], subs);
    expect(cards, hasLength(7)); // 2+1+1+1+1+1
    for (final c in cards) {
      expect(c['violations'], isEmpty, reason: '边界内不加子考点类违规');
      expect(c['subtopic'], isNotNull);
    }
  });

  test('批4② splitKeyword：plan 行缺失/损坏 → 回退单卡路径（不 fail 不中断）', () async {
    Future<Map<String, Object?>> fakeSearch(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    }) async {
      if (sourceType == 'exam') {
        return {'results': <Map<String, Object?>>[]};
      }
      return {
        'results': [Map<String, Object?>.from(pptHitRow)],
      };
    }

    // A. 无 plan 行（旧格式）：cards 照旧解析、subtopics=null、note 可诊断
    Future<String> noPlan(String system, String user, {String tag = ''}) async {
      if (tag == 'split') {
        return jsonEncode({
          'cards': [
            {
              'kind': 'ppt',
              'topic': 'caries',
              'type': 'basic',
              'front': 'F?',
              'back': 'B。',
              'evidenceChunkId': 'endo:drill-ppt:p1',
              'sourceTier': 'ppt',
            },
          ],
        });
      }
      return '{"queries": []}';
    }

    Future<Map<String, Object?>> run(Future<String> Function(String, String,
        {String tag}) llm) async {
      return splitKeyword(
        runSearch: fakeSearch,
        llmChat: llm,
        prompts: const {},
        kw: {'id': 23, 'subjectId': 'endo', 'keyword': '龋病四联因素', 'note': ''},
        subjectName: '牙体牙髓病学',
        legalSubjects: const [],
        opts: const RunOptions(),
      );
    }

    final resA = await run(noPlan);
    expect(resA['status'], 'ok');
    expect(resA['subtopics'], isNull);
    expect((resA['cards'] as List), hasLength(1));
    expect((resA['cards'] as List).first['violations'], isEmpty);
    expect((resA['notes'] as List).join(' '), contains('无 plan 计划行'));

    // B. plan 行 JSON 损坏：计划行剥除后 cards 照旧解析（绝不 fail）
    Future<String> brokenPlan(
      String system,
      String user, {
      String tag = '',
    }) async {
      if (tag == 'split') {
        final cardsJson = jsonEncode({
          'cards': [
            {
              'kind': 'ppt',
              'topic': 'caries',
              'front': 'F?',
              'back': 'B。',
              'evidenceChunkId': 'endo:drill-ppt:p1',
            },
          ],
        });
        return 'plan:{"subtopics":[oops}\n$cardsJson';
      }
      return '{"queries": []}';
    }

    final resB = await run(brokenPlan);
    expect(resB['status'], 'ok', reason: '计划行损坏不得 fail 该关键词');
    expect(resB['subtopics'], isNull);
    expect((resB['cards'] as List), hasLength(1));
    expect((resB['notes'] as List).join(' '), contains('plan 计划行 JSON 损坏'));

    // C. 计划放进 cards JSON 顶层（无独立计划行）→ 容错采纳
    Future<String> inlinePlan(
      String system,
      String user, {
      String tag = '',
    }) async {
      if (tag == 'split') {
        return jsonEncode({
          'plan': {'subtopics': ['病因']},
          'cards': [
            {
              'kind': 'ppt',
              'topic': 'caries',
              'subtopic': '病因',
              'front': 'F?',
              'back': 'B。',
              'evidenceChunkId': 'endo:drill-ppt:p1',
            },
          ],
        });
      }
      return '{"queries": []}';
    }

    final resC = await run(inlinePlan);
    expect(resC['subtopics'], ['病因']);
    expect((resC['cards'] as List).first['subtopic'], '病因');
  });
  test('日志回流（node-1）：runWeekly onLog 周扫检索降级→warn、LLM 失败→error 如实上报', () async {
    // ① 检索降级：runSearch 抛 SearchException → onLog warn（weekly tag）
    final logs1 = <String>[];
    await runWeekly(
      runSearch: (query, {subject, sourceType, k}) async {
        throw const SearchException('模拟检索降级：corpus.db 缺失');
      },
      llmChat: (system, user, {tag = ''}) async => '{"cards": []}',
      prompts: const {},
      chapters: const [
        {'subject': 'endo', 'subjectName': '牙体牙鼓病学', 'chapter': '麧病'},
      ],
      legalSubjects: const [{'id': 'endo', 'name': '牙体牙鼓病学'}],
      opts: const RunOptions(),
      onLog: (level, tag, message) => logs1.add('$level/$tag/$message'),
    );
    expect(
      logs1.join('\n'),
      contains('周扫检索降级（麧病）：'),
      reason: '检索降级必须经 onLog 如实上报',
    );
    expect(logs1.first, startsWith('warn/weekly/'),
        reason: '检索降级 = warn级、weekly tag');

    // ② LLM 失败：检索有候选，llmChat 抛 LlmException → onLog error（llm tag）
    final logs2 = <String>[];
    await runWeekly(
      runSearch: (query, {subject, sourceType, k}) async => searchOf({
        'chunk_id': 'exam:g:q1',
        'deck': '2021年执业医师资格考试',
        'page_range': '1-1',
        'title': '麧病',
        'source_type': 'exam',
        'text': '模拟文本',
        'score': 0.8,
      }),
      llmChat: (system, user, {tag = ''}) async {
        throw const LlmException('模拟周扫 LLM 崩溃');
      },
      prompts: const {},
      chapters: const [
        {'subject': 'endo', 'subjectName': '牙体牙鼓病学', 'chapter': '麧病'},
      ],
      legalSubjects: const [{'id': 'endo', 'name': '牙体牙鼓病学'}],
      opts: const RunOptions(dryRun: true),
      onLog: (level, tag, message) => logs2.add('$level/$tag/$message'),
    );
    expect(logs2.any((e) => e.startsWith('error/llm/')), isTrue,
        reason: 'LLM 失败必须经 onLog 以 error级、llm tag 上报');
    expect(logs2.join('\n'), contains('周扫 LLM 失败'),
        reason: '消息带上下文（不含 key）');
  });

}

/// 记录仪 Port：全部调用入 log，行为可配置（测试消费闸矩阵）。
class _RecorderPort implements CardPort {
  _RecorderPort({this.inserted = 2, this.skipped = 0, this.importOk = true});

  final int inserted;
  final int skipped;
  final bool importOk;
  final List<String> log = [];
  void Function(String entry)? onDone;

  @override
  Future<({bool ok, int inserted, int skipped, String? error})> importCards(
    List<Map<String, Object?>> cards,
  ) async {
    log.add('import:${cards.length}');
    if (!importOk) {
      return (ok: false, inserted: 0, skipped: 0, error: '模拟 import 失败');
    }
    return (ok: true, inserted: inserted, skipped: skipped, error: null);
  }

  @override
  Future<({bool ok, String? error})> consumeInbox(List<Object?> ids) async {
    log.add('consume:$ids');
    return (ok: true, error: null);
  }

  @override
  Future<({bool ok, String? error})> reworkDone(
    int queueId, {
    required String front,
    required String back,
    required String anchor,
  }) async {
    final entry = 'done:$queueId:$front';
    log.add(entry);
    onDone?.call(entry);
    return (ok: true, error: null);
  }
}
