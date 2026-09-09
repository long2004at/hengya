// 恒牙（hengya）· Phase 4 run_engine 拆卡引擎（run_engine.dart）
// ============================================================================
//
// Python 参考基线：automation/server-pipeline/run.py（2425 行）语义 1:1 移植。
// 六步契约与 12 条语义不变量的验收基准 =
// docs/服务器端拆卡流水线迁移设计.md §1.2；LLM 提示词模板唯一出卡规则源 =
// automation/prompts/主跑-22-55-server.md + 周度扫题-周日-server.md
// （assets/prompts/ 为 byte 等拷贝，漂移由 run_engine_test 硬门把守）。
//
// 本刀移植范围（拆卡引擎核心）：
//   - 卡片归一化：slugifyTopic / keywordSeq（md5 确定性 3 位序号）/ countPoints /
//     cardViolations / makePlaceholderCard / normalizeCard / importPayload /
//     shouldConsume（契约 5/6/7/9）
//   - 检索包装：searchHits（floor 0.30 低分线，引擎外裁决——与 search_engine
//     「floor 不在引擎内做」口径一致）/ chunkToEvidence / composeAnchor（deck+
//     页码区间）/ examDeckOk（「大纲」deck 剔除）
//   - 编排：splitKeyword 三级递进（关键词原句 → 科目名+章节名 → LLM 同义表述
//     ≤kMaxSynonymQueries 条，契约 4；通道 A 真题候选每关键词 ≤2 张，契约 8；
//     批4 节点② 起两段式拆卡输出——plan 计划行 + 逐子考点多卡）+ importKeywordCards
//     （幂等 import → 只对插入成功者 consume，契约 9）+ processRework（双通道
//     「审核拒绝：」优先，契约 3）+ runWeekly（通道 B 周扫 round-robin ≤30/周）
//   - studylog 纯逻辑：splitPendingBySource / normalizeStudyLogRefs /
//     parseStudyLogRefs / studyHitTrustworthy（章/篇号收紧校验）
//
// 本刀明确推迟（依赖 progress_db 移植，属后续刀次）：studyLogAdvance 推进链与
// compass_locate（progress.json 写路径）、报告/推送（report.py）、六步总编排
// （cmd_main_catchup 的 health/四路上下文/归档——App 侧属 pipeline 触发接线）。
//
// 依赖注入纪律（对拍 Python self_test 的 monkeypatch seam）：检索（RunSearchFn）、
// LLM（LlmChatFn）、入库（CardPort）全部入参注入——引擎零全局状态、
// 纯 Dart 可离线测试；App/探针/测试各装配各的实现。
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'exam_topics.dart' show ExamTopic;
import 'run_llm.dart' show LlmException, LlmChatFn, extractJsonObj;

// ------------------------------------------------------- 常量（醒目：可调） ----

const int kExamPerKeywordCap = 2; // 通道 A：每关键词真题卡 ≤2 张（宁缺毋滥，0 张正常）【可调】
const int kWeeklyExamCap = 30; // 通道 B：每周 ≤30 张【可调】
// 节点⑤（B2 拍板）：技能五站专题（bingshi/bingli/jiancha/caozuo/jijiu，
// isSkill=true——见 exam_topics.dart）豁免「已学章」门控，但每类每周出卡
// ≤3 张；技能类卡仍计入上面 kWeeklyExamCap 的总量配额（并存不互斥）。
const int kWeeklySkillCapPerTopic = 3; // 通道 B：技能五站每类每周 ≤3 张【可调】
const double kLowScoreFloor = 0.30; // 检索低分线：低于此分视为不可信=未命中【可调】
const List<double> kSearchWeightsDefault = [0.40, 0.60]; // 词面/向量融合配比【可调】
const int kSearchK = 6; // 每级检索取回条数
const int kWeeklyKPerChapter = 6; // 周扫：每章候选真题检索条数
const int kWeeklyExamCandSend = 24; // 周扫：送 LLM 判定的候选上限（≥cap 留余量）
const int kImportRetrySec = 5; // import/consume 失败重试间隔（重试次数由 Port 实现负责）

// 批4 节点②（C1+泛化性拍板）：同义检索式上限 2→6；拆卡提示词升级两段式
// （plan 计划行 + 逐子考点出卡）。上限均「宁缺毋滥」——是上限不是配额。
const int kMaxSynonymQueries = 6; // 三级检索第三级：同义表述检索式上限【可调】
const int kMaxSubtopicsPerKeyword = 6; // 拆卡两段式：单关键词 plan 子考点上限（考点小=1，大才拆）【可调】
const int kMaxCardsPerSubtopic = 2; // 拆卡两段式：每子考点出卡上限【可调】

// 批4 节点①（C2/C3/D1 拍板）：占位口径由「PPT 未覆盖」改为「语料未覆盖」——
// 拆卡证据是 ppt 主源 + 教材兜底两级链（见 [kSplitMainSourceType]），两级都
// 空才出占位卡；措辞不再单指 PPT。
const String kPlaceholderBack = '【语料未覆盖】请结合课堂笔记/教材补全原文后审核';
const String kPlaceholderSource = '语料未覆盖·占位待补';
const String kPlaceholderAnchor = '（语料未覆盖，待补原文后回填）'; // anchor 非空必填的占位

/// 拆卡证据源分级（批4 节点①）：主源 = 该科目 ppt 课件语料（源内三级检索
/// 照旧）；主源未命中 → 兜底检索该科目教材树（第一层目录 <短码>-textbook →
/// subject_id 同短码、source_type=textbook，词面+向量同法检索）。exam 源
/// （-exam 树）不参与拆卡证据兜底——独立，仅供通道 A 真题候选与周扫。
const String kSplitMainSourceType = 'ppt';
const String kSplitFallbackSourceType = 'textbook';
const String kExamDeckExclude = '大纲'; // deck 名含此词的考纲 deck 不作为出卡对象（规范 §六 v1.3）
const List<String> kSinglePointTriggers = ['以及', '并简述']; // 一卡多问触发词
const Set<String> kNonContentChapters = {
  '目录',
  '目录尾',
  '前言',
  '序',
  '序言',
  '附录',
  '附录一',
  '附录二',
  '附录三',
};
const List<String> kCardTypes = ['basic', 'cloze', 'caseChain'];
const List<String> kCardSourceTiers = ['ppt', 'exam', 'textbook'];

const String kStudyLogSource = 'study-log'; // 收件箱 source：章节学习记录（不进拆卡链路）
const int kStudyLogMaxRefs = 40; // 同科单次规范化章节引用上限【可调】
const int kStudyLogRefMaxLen = 60; // 单条章节引用截断长度【可调】

/// 语料检索失败（契约 10：降级不阻断）。
class SearchException implements Exception {
  const SearchException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 单卡归一化失败（跳过该卡，不影响整批）。
class CardException implements Exception {
  const CardException(this.message);
  final String message;
  @override
  String toString() => message;
}

// ------------------------------------------------------------- 章节罗盘 ----

/// 剥离章名末尾目录页码标记「 / <数字>」。
String stripChapterPageSuffix(String? s) =>
    (s ?? '').replaceAll(RegExp(r'\s*/\s*\d+\s*$'), '').trim();

/// 章名/命中 title 归一（progress_db._norm 同款口径）：去页码尾缀 + 去所有空白。
/// 公开导出供 progress_db.dart（findChapterNo 三级定位）复用，勿另写实现。
String normChapterTitle(String? t) =>
    stripChapterPageSuffix(t).replaceAll(RegExp(r'\s+'), '');

/// 正文章过滤（目录/前言/附录/索引类不列；与 progress_db 展示层同款口径）。
bool isContentChapter(String? title) {
  final t = normChapterTitle(title);
  if (t.isEmpty) {
    return false;
  }
  if (kNonContentChapters.map(normChapterTitle).contains(t)) {
    return false;
  }
  if (t.contains('索引') || t.startsWith('附录')) {
    return false;
  }
  return true;
}

/// 已学正文章列表：no ∈ (0, learned_through] 且正文章。
List<({int no, String title})> learnedChapterTitles(
  Map<String, Object?>? entry,
) {
  final lt = (entry?['learned_through'] as num?)?.toInt() ?? 0;
  final out = <({int no, String title})>[];
  for (final ch0 in (entry?['chapters'] as List? ?? [])) {
    if (ch0 is! Map) {
      continue;
    }
    final no = (ch0['no'] as num?)?.toInt() ?? 0;
    if (no > 0 && no <= lt && isContentChapter(ch0['title'] as String?)) {
      out.add((no: no, title: stripChapterPageSuffix(ch0['title'] as String?)));
    }
  }
  return out;
}

/// 罗盘当前位置：已学到的最末正文章名（L2 检索与推进的默认锚）。
String? currentChapterTitle(Map<String, Object?>? entry) {
  final ls = learnedChapterTitles(entry);
  return ls.isEmpty ? null : ls.last.title;
}

/// 下一正文章名（罗盘展示/周扫范围预告）。
String? nextChapterTitle(Map<String, Object?>? entry) {
  final lt = (entry?['learned_through'] as num?)?.toInt() ?? 0;
  for (final ch0 in (entry?['chapters'] as List? ?? [])) {
    if (ch0 is! Map) {
      continue;
    }
    final no = (ch0['no'] as num?)?.toInt() ?? 0;
    if (no > lt && isContentChapter(ch0['title'] as String?)) {
      return stripChapterPageSuffix(ch0['title'] as String?);
    }
  }
  return null;
}

// ------------------------------------------------------------- 卡片归一化 ----

final RegExp _topicCleanRe = RegExp(r'[^0-9a-z\-]+');

/// 主题 slug（幂等 id 的组成部分）：非法字符归一、折叠连字符、截 24。
String slugifyTopic(Object? topic, {String fallback = 'topic'}) {
  final s = (topic?.toString() ?? '')
      .trim()
      .toLowerCase()
      .replaceAll(_topicCleanRe, '-')
      .replaceAll(RegExp(r'-{2,}'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  final cut = s.length > 24 ? s.substring(0, 24) : s;
  return cut.isEmpty ? fallback : cut;
}

/// PPT 卡 3 位序号：按关键词确定性散列（同关键词幂等、不同关键词错位防撞）
/// + 卡序偏移。与 run.py keyword_seq 逐位一致（md5 前 6 位 hex → 100+((h-100+i)%900)）。
/// 锚点（Python 3.12.0 实测）：龋病四联因素/0=191、/1=192、牙髓炎/0=466、
/// x/0=852、急性牙髓炎临床表现/0=910。
int keywordSeq(String keyword, [int i = 0]) {
  final hex = crypto.md5.convert(utf8.encode(keyword)).toString();
  final h = int.parse(hex.substring(0, 6), radix: 16);
  return 100 + ((h - 100 + i) % 900);
}

/// back 要点数启发式（契约 7 流水线侧复核用）：换行/分号切段 + 行内枚举标记。
int countPoints(String? back) {
  final t = (back ?? '').trim();
  if (t.isEmpty) {
    return 0;
  }
  var n = 0;
  for (final part0 in t.split(RegExp(r'[\n；;]+'))) {
    final part = part0.trim();
    if (part.isEmpty) {
      continue;
    }
    n += 1;
    final marks = RegExp(r'[①②③④⑤⑥⑦⑧⑨⑩]|\d+[.、]').allMatches(part).toList();
    if (marks.length >= 2) {
      n += marks.length - 1;
    }
  }
  return n;
}

/// 契约 7 流水线侧复核（只标记进报告，不拦截——LLM 已被提示词要求逐卡自检）。
/// 批4 节点②扩展：两段式拆卡的子考点上下文复核——subtopicTotal 超过
/// [kMaxSubtopicsPerKeyword]（计划拆太碎）、subtopicCardCount 超过
/// [kMaxCardsPerSubtopic]（单子考点出卡过多）均标记；两参缺省（无 plan 的
/// 回退单卡路径）不加新违规，既有规则原样保留。
List<String> cardViolations(
  Map<String, Object?> card, {
  int? subtopicTotal,
  int? subtopicCardCount,
}) {
  final v = <String>[];
  if (card['isPlaceholder'] == true) {
    return v;
  }
  final back = (card['back'] as String?) ?? '';
  final pts = countPoints(back);
  if (pts > 4) {
    v.add('back 要点 $pts > 4');
  }
  for (final w in kSinglePointTriggers) {
    if (back.contains(w)) {
      v.add('答案含触发词「$w」');
    }
  }
  if (back.contains('和') && pts >= 3) {
    v.add('答案含「和」且要点 $pts≥3（疑似一卡多问，请人工复核）');
  }
  if (subtopicTotal != null && subtopicTotal > kMaxSubtopicsPerKeyword) {
    v.add('子考点数 $subtopicTotal > $kMaxSubtopicsPerKeyword');
  }
  if (subtopicCardCount != null && subtopicCardCount > kMaxCardsPerSubtopic) {
    v.add('单子考点出卡 $subtopicCardCount > $kMaxCardsPerSubtopic');
  }
  return v;
}

/// 占位卡本地兜底（LLM 输出异常时；正常路径由 LLM 按模板规则生成）——绝不臆造答案。
Map<String, Object?> makePlaceholderCard(
  String subjectId,
  String keywordText,
  int seq,
) {
  return {
    'id':
        '$subjectId-${slugifyTopic(keywordText)}-${seq.toString().padLeft(3, '0')}',
    'subjectId': subjectId,
    'type': 'basic',
    'front': keywordText,
    'back': kPlaceholderBack,
    'anchor': kPlaceholderAnchor,
    'source': kPlaceholderSource,
    'sourceTier': 'ppt',
    'status': 'pending',
    'tags': ['待补原文'],
    'examYear': null,
    'kind': 'ppt',
    'isPlaceholder': true,
    'violations': <String>[],
  };
}

/// #7①（2026-09-07）：normalizeCard 字段类型宽容——LLM 偶发输出 front/back
/// 为 JSON 数组（历史实锤：as String? 直接 TypeError 炸穿整轮）。规则：
/// - String → trim；num/bool → toString；
/// - List → 逐项字符串化（跳过 null/嵌套结构，不臆造文本），换行合并；
/// - Map → 无法挽救 → CardException（调用方按「跳过该卡并记原因」处理）；
/// - null/合并后全空 → ''（由 front/back 空值守卫按 CardException 跳卡）。
String _cardStringField(String field, Object? v) {
  if (v == null) {
    return '';
  }
  if (v is String) {
    return v.trim();
  }
  if (v is List) {
    final parts = <String>[];
    for (final x in v) {
      if (x == null || x is Map || x is List) {
        continue;
      }
      final s = (x is String ? x : x.toString()).trim();
      if (s.isNotEmpty) {
        parts.add(s);
      }
    }
    return parts.join('\n');
  }
  if (v is Map) {
    throw CardException('$field 为 JSON 对象，无法挽救');
  }
  return v.toString().trim();
}

/// LLM 卡输出 → 服务器 schema 卡（契约 6：id/type/status/sourceTier/anchor 落位）。
///
/// - ppt 卡：id 由调用方落位（{subjectId}-{主题}-{3位序号}，splitKeyword 拼装），
///   anchor=deck+页码区间（由 evidenceChunkId 组合，不让 LLM 拼锚）。
/// - exam 卡：id=exam-{科目}-{年份}-{题号}，anchor={年份}年第{题号}题，
///   tags 必含「真题」。
/// - 占位卡：back/source/tags 按规范 v1.2 规则三逐字落位。
/// - #7①：字段类型宽容（[_cardStringField]）——畸形卡可挽救则挽救、否则
///   CardException 跳卡，绝不抛 TypeError 炸整轮。
Map<String, Object?> normalizeCard(
  Map<String, Object?> raw,
  String subjectId,
  String keywordText,
  Map<String, Map<String, Object?>> evidenceById,
) {
  var kind = _cardStringField('kind', raw['kind']).toLowerCase();
  if (kind != 'ppt' && kind != 'exam') {
    kind =
        _cardStringField('sourceTier', raw['sourceTier']).toLowerCase() ==
            'exam'
        ? 'exam'
        : 'ppt';
  }
  final front = _cardStringField('front', raw['front']);
  final back = _cardStringField('back', raw['back']);
  if (front.isEmpty || back.isEmpty) {
    throw const CardException('front/back 为空');
  }
  var ctype = _cardStringField('type', raw['type']);
  if (ctype.isEmpty) {
    ctype = 'basic';
  }
  if (!kCardTypes.contains(ctype)) {
    ctype = 'basic';
  }
  final tags = <String>[];
  final rawTags = raw['tags'];
  final tagItems = rawTags is List
      ? rawTags
      : (rawTags is String ? <Object?>[rawTags] : const <Object?>[]);
  for (final t0 in tagItems) {
    final t = (t0?.toString() ?? '').trim();
    if (t.isNotEmpty && !tags.contains(t)) {
      tags.add(t);
    }
  }
  final isPh = back == kPlaceholderBack;
  if (kind == 'exam') {
    final meta = raw['examMeta'];
    final m = meta is Map
        ? Map<String, Object?>.from(meta)
        : <String, Object?>{};
    var year = _cardStringField('examMeta.year', m['year']);
    if (year.isEmpty) {
      final ey = raw['examYear'];
      year = ((ey?.toString() ?? '')).trim();
    }
    final no = _cardStringField('examMeta.no', m['no']);
    if (year.isEmpty || no.isEmpty) {
      throw const CardException('exam 卡缺 examMeta{year,no}');
    }
    var sid = _cardStringField('subjectId', raw['subjectId']);
    if (sid.isEmpty) {
      sid = subjectId;
    }
    sid = sid.trim().isEmpty ? 'unknown' : sid.trim();
    if (!tags.contains('真题')) {
      tags.add('真题');
    }
    final src = _cardStringField('source', raw['source']);
    final card = <String, Object?>{
      'id': 'exam-$sid-$year-$no',
      'subjectId': sid,
      'type': ctype,
      'front': front,
      'back': back,
      'anchor': '$year年第$no题',
      'source': src.isEmpty ? '$year年真题' : src,
      'sourceTier': 'exam',
      'status': 'pending',
      'tags': tags,
      'examYear': year,
      'kind': 'exam',
      'isPlaceholder': false,
    };
    card['violations'] = cardViolations(card);
    return card;
  }
  var tier = _cardStringField('sourceTier', raw['sourceTier']).toLowerCase();
  if (!kCardSourceTiers.contains(tier)) {
    tier = 'ppt';
  }
  final ev =
      evidenceById[_cardStringField('evidenceChunkId', raw['evidenceChunkId'])];
  var anchor = ev != null ? composeAnchor(ev) : '';
  if (anchor.isEmpty) {
    anchor = _cardStringField('anchor', raw['anchor']);
  }
  final src = _cardStringField('source', raw['source']);
  final card = <String, Object?>{
    'id': '',
    'subjectId': subjectId,
    'type': ctype,
    'front': front,
    'back': back,
    'anchor': anchor,
    'source': src.isEmpty ? '课程 PPT' : src,
    'sourceTier': tier,
    'status': 'pending',
    'tags': tags,
    'examYear': null,
    'kind': 'ppt',
  };
  if (isPh) {
    card['back'] = kPlaceholderBack;
    card['type'] = 'basic';
    card['sourceTier'] = 'ppt';
    card['source'] = kPlaceholderSource;
    card['anchor'] = kPlaceholderAnchor;
    if (!tags.contains('待补原文')) {
      tags.add('待补原文');
    }
    card['isPlaceholder'] = true;
  } else {
    card['isPlaceholder'] = false;
  }
  card['violations'] = cardViolations(card);
  return card;
}

/// 导入用净荷：与服务器 FlashCard.fromJson 对齐——id/subjectId/type/front/
/// back/anchor/source 均非空必填（anchor 空 → 服务端解析失败按 skipped 计）；
/// 内部标记字段（kind/isPlaceholder/violations）不进 import。
Map<String, Object?> importPayload(Map<String, Object?> card) {
  final out = <String, Object?>{
    'id': card['id'],
    'subjectId': card['subjectId'],
    'type': card['type'],
    'front': card['front'],
    'back': card['back'],
    'anchor': ((card['anchor'] as String?) ?? '').isNotEmpty
        ? card['anchor']
        : '（无锚）',
    'source': ((card['source'] as String?) ?? '').isNotEmpty
        ? card['source']
        : '课程 PPT',
    'sourceTier': ((card['sourceTier'] as String?) ?? 'ppt'),
    'status': 'pending',
  };
  final tags = card['tags'];
  if (tags is List && tags.isNotEmpty) {
    out['tags'] = tags;
  }
  final ey = card['examYear'];
  if (ey != null && ey.toString().isNotEmpty) {
    out['examYear'] = ey.toString();
  }
  return out;
}

/// 契约 9 消费闸门：只对「插入成功」的关键词 consume；
/// 导入成功数=0 且 skipped>0 → 直接 consume（幂等收尾）。
bool shouldConsume(int? inserted, int? skipped) =>
    (inserted ?? 0) > 0 || ((inserted ?? 0) == 0 && (skipped ?? 0) > 0);

// ------------------------------------------------------------- 检索包装 ----

/// 低分线过滤（低于低分线视为不可信=未命中）。res 可携带 '_floor' 覆盖。
List<Map<String, Object?>> searchHits(Map<String, Object?> res, double? floor) {
  var f = floor ?? kLowScoreFloor;
  final rf = res['_floor'];
  if (rf is num) {
    f = rf.toDouble();
  }
  final out = <Map<String, Object?>>[];
  for (final r0 in (res['results'] as List? ?? [])) {
    if (r0 is! Map) {
      continue;
    }
    final s = r0['score'];
    if (s is num && s.toDouble() >= f) {
      out.add(Map<String, Object?>.from(r0));
    }
  }
  return out;
}

/// 检索结果 → LLM 证据条目（deck + 页码区间喂卡片 anchor，§2.3）。
Map<String, Object?> chunkToEvidence(Map<String, Object?> r) {
  final pr = (r['page_range'] as String?) ?? '';
  return {
    'chunkId': r['chunk_id'],
    'deck': r['deck'],
    'pageRange': pr.isNotEmpty ? pr : (r['page_start']?.toString() ?? ''),
    'title': r['title'],
    'sourceType': r['source_type'],
    'text': (r['text'] as String?) ?? (r['preview'] as String?) ?? '',
  };
}

/// 契约 6：anchor = deck + 页码区间（如「龋病概述 p12-15」）。
String composeAnchor(Map<String, Object?>? ev) {
  final deck = ((ev?['deck'] as String?) ?? '').isNotEmpty
      ? ev!['deck'] as String
      : '?';
  final pr = ((ev?['pageRange'] as String?) ?? '').isNotEmpty
      ? (ev!['pageRange'] as String)
      : '?';
  return '$deck p$pr';
}

/// 考纲 deck 剔除（规范 §六 v1.3：deck 名含「大纲」不作为出卡对象）。
/// 节点④（F 证据隔离）加固：source_type='outline' 的大纲树行一并剔除
/// ——大纲树 deck 名可能是拼音（dagang-outline），不含「大纲」字面，
/// [kExamDeckExclude] 的字面语义原样保留，此处按来源类型兜底。
bool examDeckOk(Map<String, Object?> r) =>
    ((r['source_type'] as String?) ?? '') != 'outline' &&
    !((r['deck'] as String?) ?? '').contains(kExamDeckExclude);

/// 科目间均衡分配（round-robin，不向单科倾斜）；总量 ≤ min(cap, sendCap)。
List<Map<String, Object?>> balanceCandidates(
  Map<String, List<Map<String, Object?>>> bySubject,
  int cap,
  int sendCap,
) {
  final queues = <String, List<Map<String, Object?>>>{};
  bySubject.forEach((s, v) {
    if (v.isNotEmpty) {
      queues[s] = List<Map<String, Object?>>.of(v);
    }
  });
  final out = <Map<String, Object?>>[];
  final limit = cap < sendCap ? cap : sendCap;
  while (out.length < limit) {
    if (!queues.values.any((q) => q.isNotEmpty)) {
      break;
    }
    for (final s in (queues.keys.toList()..sort())) {
      final q = queues[s]!;
      if (q.isNotEmpty && out.length < limit) {
        out.add(q.removeAt(0));
      }
    }
  }
  return out;
}

// ------------------------------------------------------------- 提示词模板 ----

/// run-prompt 段提取标记（与 run.py PROMPT_MARK_RE 同款；Dart RegExp 支持 \1 反向引用）。
final RegExp kPromptMarkRe = RegExp(
  r'<!--\s*run-prompt:([a-z]+):start\s*-->([\s\S]*?)<!--\s*run-prompt:\1:end\s*-->',
);

/// 内置兜底（模板缺失/提取失败时；与 run.py FALLBACK_PROMPTS 逐字一致）。
final Map<String, String> kFallbackPrompts = {
  'split':
      '你是恒牙复习系统的自动化拆卡助手。输入为 JSON（关键词+语料证据），'
      '输出两段：第一行计划行 plan:{"subtopics":["子考点",…]}——判断该关键词'
      '所指考点大小：考点小则 1 个子考点，考点大则拆成多个子考点（上限 '
      '$kMaxSubtopicsPerKeyword 个，宁缺毋滥不硬凑）；第二段输出一个 JSON 对象 '
      '{"cards":[...]}，逐子考点出卡（每子考点 1-2 张，每张卡用 subtopic 字段'
      '标注所属子考点）。每张卡一个考点（back 要点≤4，禁「和、以及、并简述」'
      '触发词）；答案以 evidence 的语料原文为准（PPT 课件或教材兜底，见 '
      'evidence.sourceType）；pptHit=false 时只输出一张占位卡'
      '（back=【语料未覆盖】请结合课堂笔记/教材补全原文后审核）。'
      'exam 卡每关键词 ≤2 张，需 examMeta{year,no}。',
  'rework':
      '你是恒牙复习系统的回炉重写助手。输入为 JSON（回炉项+理由+留言+证据），'
      '只输出 {"front","back","evidenceChunkId"}；「审核拒绝：」理由必须修正，'
      '重写不得凭空改写。',
  'synonym':
      '为课堂关键词生成最多 $kMaxSynonymQueries 条同义表述检索式'
      '（强相关、宁缺毋滥、不准硬凑数——上限不是配额，质量优先），只输出 '
      '{"queries":["..."]}，无法生成则输出空数组。',
  'weekly':
      '你是恒牙复习系统的周度扫题助手（通道 B）。输入为 JSON（候选真题），'
      '逐题判断出卡价值，宁缺毋滥；只输出 {"cards":[...]}，每张卡需 examMeta{year,no}、'
      'tags 含「真题」；deck 含「大纲」的候选跳过。',
  'studylog':
      '你是恒牙复习系统的学习记录规范化助手。输入为 JSON（学生报的已学章节原文），'
      '把每条规范化为可直接检索教材的章节引用（统一「第X章 章名」形态，兼容'
      '「第三章 / 第3章 / 第三章 临床表现」等写法；章名取学生原文，不臆造、不合并、'
      '不新增）。只输出 {"chapters":["第X章 …",...]}，逐条对应、顺序保持输入顺序。',
};

/// 提示词文件描述（name=展示名，text=null 表示缺失）。
typedef PromptFile = ({String name, String? text});

/// 从服务器版模板文本提取 prompt 段（主跑+周扫两文件；缺失段用内置兜底）。
(Map<String, String>, List<String>) loadPrompts(List<PromptFile> files) {
  final out = Map<String, String>.of(kFallbackPrompts);
  final notes = <String>[];
  var foundAny = false;
  for (final f in files) {
    final text = f.text;
    if (text == null) {
      notes.add('模板缺失（用内置兜底）：${f.name}');
      continue;
    }
    var got = false;
    for (final m in kPromptMarkRe.allMatches(text)) {
      final body = m.group(2)?.trim() ?? '';
      if (body.isNotEmpty) {
        out[m.group(1)!] = body;
        got = true;
      }
    }
    if (got) {
      foundAny = true;
    }
  }
  if (!foundAny) {
    notes.add('未提取到任何 run-prompt 段（全部用内置兜底）');
  }
  return (out, notes);
}

// ------------------------------------------------------------- 注入 seam ----

/// 语料检索注入（App/探针包 corpusSearch；测试注入脚本化 fake）。
/// 返回 corpusSearch 完整结果 map；失败抛 [SearchException]（契约 10 降级）。
typedef RunSearchFn =
    Future<Map<String, Object?>> Function(
      String query, {
      String? subject,
      String? sourceType,
      int? k,
    });

/// 卡片入库端口（App 包 LocalBackend；探针/测试各装配实现）。
abstract class CardPort {
  /// 幂等批量导入（对照 POST /api/v1/cards/import）：返回 inserted/skipped；
  /// 失败返回 ok=false + error（重试由实现负责，引擎只认结果）。
  Future<({bool ok, int inserted, int skipped, String? error})> importCards(
    List<Map<String, Object?>> cards,
  );

  /// 消费收件箱条目（POST /api/v1/inbox/consume {"ids":[...]}）。
  Future<({bool ok, String? error})> consumeInbox(List<Object?> ids);

  /// 回炉完成（POST /api/v1/cards/rework/{queueId}/done {front,back,anchor}）。
  Future<({bool ok, String? error})> reworkDone(
    int queueId, {
    required String front,
    required String back,
    required String anchor,
  });
}

/// 引擎运行选项（dry-run：只出卡不 import/consume/done）。
class RunOptions {
  const RunOptions({
    this.dryRun = false,
    this.floor = kLowScoreFloor,
    this.limit,
  });

  final bool dryRun;
  final double floor;
  final int? limit;
}

// ------------------------------------------------------------- study-log ----

/// 按 inbox.source 分流：study-log（章节学习记录→罗盘推进）/ 其余（关键词→拆卡）。
/// 兼容旧条目与 mock fixture（无 source 字段视为关键词）。
(List<Map<String, Object?>>, List<Map<String, Object?>>) splitPendingBySource(
  List? pending,
) {
  final kwItems = <Map<String, Object?>>[];
  final slItems = <Map<String, Object?>>[];
  for (final k0 in (pending ?? [])) {
    if (k0 is! Map) {
      continue;
    }
    final k = Map<String, Object?>.from(k0);
    if ((k['source']?.toString() ?? '') == kStudyLogSource) {
      slItems.add(k);
    } else {
      kwItems.add(k);
    }
  }
  return (kwItems, slItems);
}

const Map<String, int> _studyCnDigits = {
  '零': 0,
  '〇': 0,
  '一': 1,
  '二': 2,
  '两': 2,
  '三': 3,
  '四': 4,
  '五': 5,
  '六': 6,
  '七': 7,
  '八': 8,
  '九': 9,
};
const Map<String, int> _studyCnUnits = {'十': 10, '百': 100, '千': 1000};

/// 「第X章/第X篇」层级号提取正则（中文数字或阿拉伯；progress_db 同款口径）。
final RegExp kStudyChapNoRe = RegExp(r'第([零〇一二两三四五六七八九十百千0-9]+)\s*([篇章])');

int? _studyCnNumToInt(String? s0) {
  final s = (s0 ?? '').trim();
  if (s.isEmpty) {
    return null;
  }
  var allDigits = true;
  for (final ch in s.codeUnits) {
    if (ch < 0x30 || ch > 0x39) {
      allDigits = false;
      break;
    }
  }
  if (allDigits) {
    return int.parse(s);
  }
  var section = 0, digit = 0;
  for (final ch in s.split('')) {
    if (_studyCnDigits.containsKey(ch)) {
      digit = _studyCnDigits[ch]!;
    } else if (_studyCnUnits.containsKey(ch)) {
      section += (digit == 0 ? 1 : digit) * _studyCnUnits[ch]!;
      digit = 0;
    } else {
      return null;
    }
  }
  final n = section + digit;
  return n > 0 ? n : null;
}

/// 提取「第X章/第X篇」层级号 → (章号集, 篇号集)（中文数字归一为 int）。
(Set<int>, Set<int>) chapPartNos(String? s) {
  final chap = <int>{};
  final part = <int>{};
  for (final m in kStudyChapNoRe.allMatches(s ?? '')) {
    final n = _studyCnNumToInt(m.group(1));
    if (n == null) {
      continue;
    }
    (m.group(2) == '章' ? chap : part).add(n);
  }
  return (chap, part);
}

/// 引用与命中 title 的章/篇号一致性校验（收紧，宁缺毋滥；不放宽任何既有保险）：
/// 报章号（第X章）→ 命中 title 章号集须含其一；仅报篇号 → 篇号集须含其一；
/// 无层级号（纯章名）→ 不校验（交 progress_db 策略①兜底）。
bool studyHitTrustworthy(String ref, String hitTitle) {
  final (rChap, rPart) = chapPartNos(ref);
  if (rChap.isEmpty && rPart.isEmpty) {
    return true;
  }
  final (hChap, hPart) = chapPartNos(hitTitle);
  if (rChap.isNotEmpty) {
    return rChap.any(hChap.contains);
  }
  return rPart.any(hPart.contains);
}

/// 章节引用清洗：去空 → 截断 → 保序去重 → 上限截断。
List<String> cleanStudyRefs(List? lines) {
  final out = <String>[];
  final seen = <String>{};
  for (final x in (lines ?? [])) {
    var s = (x?.toString() ?? '').trim();
    if (s.length > kStudyLogRefMaxLen) {
      s = s.substring(0, kStudyLogRefMaxLen);
    }
    if (s.isNotEmpty && !seen.contains(s)) {
      seen.add(s);
      out.add(s);
      if (out.length >= kStudyLogMaxRefs) {
        break;
      }
    }
  }
  return out;
}

/// LLM 输出 → 章节引用列表（严格 JSON：{"chapters":[...]} 或裸数组；坏输出抛错）。
List<String> parseStudyLogRefs(String content) {
  final obj = extractJsonObj(content);
  Object? refs = obj is Map ? obj['chapters'] : obj;
  if (refs is String) {
    refs = [refs];
  }
  if (refs is! List) {
    throw const LlmException('chapters 不是数组');
  }
  final cleaned = cleanStudyRefs(refs);
  if (cleaned.isEmpty) {
    throw const LlmException('章节引用列表为空');
  }
  return cleaned;
}

/// source=study-log 条目规范化：同科合并一次 LLM 调用 → 章节引用列表。
/// 失败 → 降级为逐条原文直接当章节引用（notes 注明，报告可见）。
/// 返回 (refs, mode: llm|fallback|skip, notes)。
Future<(List<String>, String, List<String>)> normalizeStudyLogRefs({
  required LlmChatFn llmChat,
  required Map<String, String> prompts,
  required String subjectId,
  required String subjectName,
  required List<String> rawLines,
}) async {
  final notes = <String>[];
  final cleaned = cleanStudyRefs(rawLines);
  if (cleaned.isEmpty) {
    return (<String>[], 'skip', notes);
  }
  final system = prompts['studylog'] ?? kFallbackPrompts['studylog']!;
  final payload = jsonEncode({
    'task': 'studylog',
    'subjectId': subjectId,
    'subjectName': subjectName,
    'rawLines': cleaned,
  });
  try {
    final content = await llmChat(system, payload, tag: 'studylog');
    return (parseStudyLogRefs(content), 'llm', notes);
  } on LlmException catch (e) {
    notes.add('章节规范化 LLM 调用失败（降级为逐条原文引用）：$e');
    return (cleaned, 'fallback', notes);
  }
}

// ------------------------------------------------------------- 拆卡编排 ----

/// 三级检索第三级：LLM 生成 ≤[kMaxSynonymQueries] 条同义表述检索式（批4
/// 节点②：2→6，上限非配额——截断在引擎侧兜底；失败→空列表降级，契约 10）。
Future<List<String>> synonymQueries(
  LlmChatFn llmChat,
  Map<String, String> prompts,
  List<String> notes,
  String keyword,
  String subjectName,
) async {
  final system = prompts['synonym'] ?? kFallbackPrompts['synonym']!;
  final payload = jsonEncode({
    'task': 'synonym',
    'keyword': keyword,
    'subjectName': subjectName,
  });
  try {
    final content = await llmChat(system, payload, tag: 'synonym');
    final obj = extractJsonObj(content);
    Object? qs = obj is Map ? obj['queries'] : obj;
    if (qs is String) {
      qs = [qs];
    }
    if (qs is! List) {
      return <String>[];
    }
    final out = <String>[];
    for (final q0 in qs) {
      var q = (q0?.toString() ?? '').trim();
      if (q.length > 40) {
        q = q.substring(0, 40);
      }
      if (q.isNotEmpty) {
        out.add(q);
      }
      if (out.length >= kMaxSynonymQueries) {
        break;
      }
    }
    return out;
  } on LlmException catch (e) {
    notes.add('同义扩展失败（降级为未命中）：$e');
    return <String>[];
  }
}

// ------------------------------------------- 拆卡两段式（批4 节点②） ----

/// 计划行（plan line）提取正则：行首 plan: + 单行 JSON 对象
/// （{"subtopics":[…]}；贪心到行末最后一个 }，容忍行内嵌套花括号与 \r\n 行尾）。
final RegExp kPlanLineRe = RegExp(
  r'^[ \t]*plan:[ \t]*(\{.*\})[ \t\r]*$',
  multiLine: true,
);

/// subtopics 载荷清洗：字符串→单元素列表；数组→去空 trim；其余/全空 → null。
List<String>? _cleanSubtopics(Object? subs) {
  if (subs is String) {
    subs = [subs];
  }
  if (subs is! List) {
    return null;
  }
  final out = <String>[];
  for (final s0 in subs) {
    final s = (s0?.toString() ?? '').trim();
    if (s.isNotEmpty) {
      out.add(s);
    }
  }
  return out.isEmpty ? null : out;
}

/// 提取两段式拆卡输出中的计划行。返回 (subtopics, rest)：
/// - subtopics=null：计划行缺失 / JSON 损坏 / subtopics 非法或全空 →
///   调用方回退单卡路径（cards 照旧解析、无子考点分组——该关键词绝不因
///   计划行问题 fail 或中断整批）；
/// - rest：剥掉计划行后的剩余文本（无论计划行是否合法都剥除——避免 plan
///   行的 {...} 干扰 extractJsonObj 的首尾包裹扫描）。
(List<String>?, String) extractSplitPlan(String content) {
  final m = kPlanLineRe.firstMatch(content);
  if (m == null) {
    return (null, content);
  }
  final rest = content.replaceRange(m.start, m.end, '');
  Object? raw;
  try {
    raw = jsonDecode(m.group(1)!);
  } catch (_) {
    return (null, rest);
  }
  return (_cleanSubtopics(raw is Map ? raw['subtopics'] : raw), rest);
}

/// 容错：计划行缺失但 LLM 把计划放进了 cards JSON 顶层（{"plan":{"subtopics":
/// […]}} 或 {"subtopics":[…]}）——同语义采纳，仍算有效计划。
List<String>? subtopicsFromCardsObj(Object? obj) {
  if (obj is! Map) {
    return null;
  }
  final p = obj['plan'];
  return _cleanSubtopics(p is Map ? p['subtopics'] : obj['subtopics']);
}

/// 单关键词拆卡：主源 ppt 三级检索（契约 4）→ 教材兜底（批4 节点①：
/// 主源未命中重放教材树）→ LLM 两段式出卡（契约 5/7/8 + 通道 A + 批4 节点②
/// 计划行/子考点多卡）→ 归一化。
///
/// 返回 {inboxId, keyword, subjectId, pptHit, evidenceTier, triedQueries,
/// notes, evidenceChunks, examCandidates, cards, status: ok|failed, error,
/// subtopics}。
/// pptHit=有效证据命中（ppt 主源或教材兜底，批4 节点①起的两级语义）；
/// evidenceTier='ppt'|'textbook'|null 区分命中层级（null=两级皆未命中）；
/// subtopics=两段式计划行的子考点列表（批4 节点②；plan 行缺失/损坏时为
/// null=回退单卡路径，cards 照旧解析无分组）。
/// LLM 失败 → status=failed 不 consume（契约 9/10，留给补跑）。
Future<Map<String, Object?>> splitKeyword({
  required RunSearchFn runSearch,
  required LlmChatFn llmChat,
  required Map<String, String> prompts,
  required Map<String, Object?> kw,
  required String subjectName,
  Map<String, Object?>? progressEntry,
  required List<Map<String, Object?>> legalSubjects,
  required RunOptions opts,
}) async {
  final subjectId = ((kw['subjectId'] as String?) ?? '').trim();
  final text = ((kw['keyword'] as String?) ?? '').trim();
  final tried = <String>[];
  final notes = <String>[];
  final subject = subjectId.isEmpty ? null : subjectId;

  Future<List<Map<String, Object?>>> try_(
    String query, {
    String? subject,
    String? sourceType,
    int? k,
  }) async {
    tried.add(query);
    try {
      final res = await runSearch(
        query,
        subject: subject,
        sourceType: sourceType,
        k: k,
      );
      return searchHits(res, opts.floor);
    } on SearchException catch (e) {
      notes.add(
        '检索故障降级（${query.length > 24 ? query.substring(0, 24) : query}）：$e',
      );
      return <Map<String, Object?>>[];
    }
  }

  // ── 主源 ppt（批4 节点①）：源内三级检索照旧（契约 4），sourceType 钉死
  //    主源——教材/exam 语料不再混入主源证据（exam 永不出现在拆卡证据，
  //    教材只走下方兜底链）。──
  // ① 关键词原句
  var hits = await try_(
    text,
    subject: subject,
    sourceType: kSplitMainSourceType,
    k: kSearchK,
  );
  // ② 科目名+章节名
  final chapter = currentChapterTitle(progressEntry);
  final q2 = [
    subjectName,
    chapter,
  ].whereType<String>().where((x) => x.isNotEmpty).join(' ');
  final q2Valid = q2.isNotEmpty && q2 != text;
  if (hits.isEmpty && q2Valid) {
    hits = await try_(
      q2,
      subject: subject,
      sourceType: kSplitMainSourceType,
      k: kSearchK,
    );
  }
  // ③ 同义表述（LLM 生成 ≤kMaxSynonymQueries 条，批4 节点② 起 6 条）
  final synonyms = <String>[];
  if (hits.isEmpty) {
    synonyms.addAll(
      await synonymQueries(llmChat, prompts, notes, text, subjectName),
    );
    for (final q3 in synonyms) {
      if (q3.isNotEmpty && q3 != text) {
        hits = await try_(
          q3,
          subject: subject,
          sourceType: kSplitMainSourceType,
          k: kSearchK,
        );
        if (hits.isNotEmpty) {
          break;
        }
      }
    }
  }
  // ── 教材兜底（批4 节点①，C2/C3/D1 拍板）：主源三级未命中 → 同一批检索式
  //    重放该科目教材树（<短码>-textbook 语料，词面+向量同法；exam 源不参与）。
  //    同义词已在主源三级生成，重放不产生额外 LLM 调用；命中即出真卡，
  //    ppt 卡 sourceTier=textbook（下方落位，透传至待审核页「教材」标识）。──
  var textbookFallback = false;
  if (hits.isEmpty) {
    final ladder = <String>[
      text,
      if (q2Valid) q2,
      ...synonyms.where((s) => s.isNotEmpty && s != text),
    ];
    for (final q in ladder) {
      hits = await try_(
        q,
        subject: subject,
        sourceType: kSplitFallbackSourceType,
        k: kSearchK,
      );
      if (hits.isNotEmpty) {
        break;
      }
    }
    if (hits.isNotEmpty) {
      textbookFallback = true;
      notes.add('PPT 主源未命中，教材兜底命中（sourceTier=textbook）');
    }
  }
  // pptHit 语义（批4 节点①起）：有效证据命中（ppt 主源或教材兜底）——
  // 供 LLM「出真卡 vs 占位卡」判定与 misses 报告口径；命中层级见 evidenceTier。
  final pptHit = hits.isNotEmpty;
  final String? evidenceTier = hits.isEmpty
      ? null
      : (textbookFallback ? kSplitFallbackSourceType : kSplitMainSourceType);
  final evidence = hits.take(kSearchK).map(chunkToEvidence).toList();
  final evidenceById = <String, Map<String, Object?>>{};
  for (final e in evidence) {
    final cid = e['chunkId'];
    if (cid != null) {
      evidenceById[cid.toString()] = e;
    }
  }

  // 通道 A 真题候选（真题池共享 subject=exam，不带科目过滤；「大纲」deck 剔除）
  var examCands = <Map<String, Object?>>[];
  try {
    final res = await runSearch(
      text,
      subject: null,
      sourceType: 'exam',
      k: kSearchK * 2,
    );
    for (final r in searchHits(res, opts.floor)) {
      if (examDeckOk(r)) {
        examCands.add(chunkToEvidence(r));
      }
    }
  } on SearchException catch (e) {
    notes.add('真题候选检索故障（降级不出真题卡）：$e');
  }
  examCands = examCands.take(4).toList();

  final payload = {
    'task': 'split',
    'keyword': {
      'text': text,
      'subjectId': subjectId,
      'note': (kw['note']?.toString() ?? ''),
    },
    'compass': {
      'textbook': progressEntry?['textbook'],
      'learnedChapters': learnedChapterTitles(
        progressEntry,
      ).map((c) => c.title).toList(),
      'nextChapter': nextChapterTitle(progressEntry),
      'subjects': legalSubjects,
    },
    'channelACap': kExamPerKeywordCap,
    'maxSubtopics': kMaxSubtopicsPerKeyword,
    'pptHit': pptHit,
    'evidence': evidence,
    'examCandidates': examCands,
  };
  final result = <String, Object?>{
    'inboxId': kw['id'],
    'keyword': text,
    'subjectId': subjectId,
    'pptHit': pptHit,
    'evidenceTier': evidenceTier,
    'triedQueries': tried,
    'notes': notes,
    'evidenceChunks': evidence.length,
    'examCandidates': examCands.length,
    'cards': <Map<String, Object?>>[],
    'subtopics': null,
    'status': 'ok',
    'error': null,
  };
  List<Object?> rawCards;
  List<String>? subtopics;
  try {
    final content = await llmChat(
      prompts['split'] ?? kFallbackPrompts['split']!,
      jsonEncode(payload),
      tag: 'split',
    );
    // 批4 节点②：两段式输出——先剥计划行（plan 行缺失/JSON 损坏 → 回退
    // 单卡路径：subtopics=null、cards 照旧解析无分组，绝不因计划行问题
    // fail 该关键词）；剩余文本照旧 extractJsonObj 解析 cards。
    final (plan, rest) = extractSplitPlan(content);
    final obj = extractJsonObj(rest);
    subtopics = plan ?? subtopicsFromCardsObj(obj);
    if (subtopics == null) {
      notes.add(
        kPlanLineRe.hasMatch(content)
            ? 'plan 计划行 JSON 损坏（回退单卡路径）'
            : '无 plan 计划行（回退单卡路径）',
      );
    }
    final rc = obj is Map ? obj['cards'] : obj;
    if (rc is! List) {
      throw const LlmException('cards 不是数组');
    }
    rawCards = rc;
  } on LlmException catch (e) {
    result['status'] = 'failed'; // 不 consume，留给补跑（契约 9/10）
    result['error'] = e.toString();
    return result;
  }
  result['subtopics'] = subtopics;

  // 批4 节点②：子考点分组统计——raw ppt 卡（exam 卡除外）按 subtopic 字段
  // 聚合，供 cardViolations「单子考点出卡 > kMaxCardsPerSubtopic」复核；
  // plan 缺失（回退单卡路径）时不分组、不加子考点类新违规。
  final subtopicCounts = <String, int>{};
  if (subtopics != null) {
    for (final raw0 in rawCards) {
      if (raw0 is! Map ||
          (raw0['kind']?.toString() ?? '').toLowerCase() == 'exam') {
        continue;
      }
      final st = (raw0['subtopic']?.toString() ?? '').trim();
      if (st.isEmpty) {
        continue;
      }
      subtopicCounts[st] = (subtopicCounts[st] ?? 0) + 1;
    }
  }

  var seqI = 0;
  var examSeen = 0;
  final cards = result['cards'] as List<Map<String, Object?>>;
  for (final raw0 in rawCards) {
    if (raw0 is! Map) {
      continue;
    }
    final Map<String, Object?> raw = Map<String, Object?>.from(raw0);
    Map<String, Object?> card;
    try {
      card = normalizeCard(raw, subjectId, text, evidenceById);
    } catch (e) {
      // #7②（2026-09-07）：catch 扩围——CardException 之外的 Error（如历史
      // as String? 型 TypeError 的残留路径）一并捕获，单卡异常只跳该卡，
      // 保住本轮已成功的其余卡不炸整轮（normalizeCard 内部已类型宽容，
      // 此为纵深防御层）。
      notes.add('单卡归一化失败（跳过该卡）：$e');
      continue;
    }
    if (card['kind'] == 'exam') {
      examSeen += 1;
      if (examSeen > kExamPerKeywordCap) {
        notes.add('真题卡超额截断（上限 $kExamPerKeywordCap）');
        continue;
      }
    } else {
      final topic = raw['topic'] ?? text;
      card['id'] =
          '$subjectId-${slugifyTopic(topic)}-${keywordSeq(text, seqI).toString().padLeft(3, '0')}';
      seqI += 1;
      if (((card['anchor'] as String?) ?? '').isEmpty && evidence.isNotEmpty) {
        card['anchor'] = composeAnchor(evidence.first);
      }
      if (textbookFallback && card['isPlaceholder'] != true) {
        // 教材兜底证据出卡（批4 节点①）：sourceTier 透传 textbook（LLM
        // 可能已按提示词标了，此处确定性兜底）；source 缺省值同步口径。
        // 占位卡不在此列——有证据仍出占位属 LLM 违规，tier 保持 ppt 口径。
        card['sourceTier'] = kSplitFallbackSourceType;
        if ((card['source'] as String?) == '课程 PPT') {
          card['source'] = '教材';
        }
      }
      if (subtopics != null) {
        // 批4 节点②：子考点关联（「关键词→子考点→卡」对齐锚点，内部标记
        // 字段不进 importPayload）+ 子考点类违规复核（违规照既有路径只标记
        // 进报告不拦截）。
        final st = (raw['subtopic']?.toString() ?? '').trim();
        if (st.isNotEmpty) {
          card['subtopic'] = st;
          card['violations'] = cardViolations(
            card,
            subtopicTotal: subtopics.length,
            subtopicCardCount: subtopicCounts[st] ?? 1,
          );
        } else {
          card['violations'] = cardViolations(
            card,
            subtopicTotal: subtopics.length,
          );
        }
      }
    }
    cards.add(card);
  }
  if (!pptHit && !cards.any((c) => c['isPlaceholder'] == true)) {
    // LLM 未按规则给占位卡 → 本地兜底（绝不臆造，契约 5）
    cards.add(makePlaceholderCard(subjectId, text, keywordSeq(text, seqI)));
  }
  if (cards.isEmpty) {
    result['status'] = 'failed';
    result['error'] = 'LLM 未产出任何可用卡';
  }
  return result;
}

/// 契约 9：按关键词批量 import（幂等）→ 只对插入成功者 consume；
/// import 失败不 consume 留补跑；inserted=0 且 skipped>0 → 幂等收尾 consume。
Future<void> importKeywordCards(
  CardPort? port,
  Map<String, Object?> kwres,
  RunOptions opts,
) async {
  final cards = (kwres['cards'] as List? ?? []).cast<Map<String, Object?>>();
  if (opts.dryRun || port == null || cards.isEmpty) {
    kwres['import'] = {
      'note': opts.dryRun
          ? 'dry-run 未 import'
          : (cards.isEmpty ? '无卡' : '无 Port，未 import'),
      'consumed': false,
    };
    return;
  }
  final body = cards.map(importPayload).toList();
  final r = await port.importCards(body);
  if (!r.ok) {
    kwres['import'] = {
      'ok': false,
      'error': 'import 失败（不 consume，留补跑）：${r.error ?? ''}',
    };
    kwres['status'] = 'import_failed';
    return;
  }
  final inserted = r.inserted;
  final skipped = r.skipped;
  kwres['import'] = {'ok': true, 'inserted': inserted, 'skipped': skipped};
  if (shouldConsume(inserted, skipped)) {
    final ids = [kwres['inboxId']];
    final c = await port.consumeInbox(ids);
    (kwres['import'] as Map<String, Object?>)['consumeOk'] = c.ok;
    (kwres['import'] as Map<String, Object?>)['consumed'] = c.ok;
    if (!c.ok) {
      (kwres['import'] as Map<String, Object?>)['consumeError'] =
          (c.error ?? '').length > 200 ? c.error!.substring(0, 200) : c.error;
    }
  } else {
    (kwres['import'] as Map<String, Object?>)['consumed'] = false;
  }
}

/// 契约 3：rework 双通道逐条重写——「审核拒绝：」优先且回应理由本身；
/// aiNotes 重写时参考；重写须重新检索 PPT 原文；dry-run 只出草稿不 done。
///
/// queue 条目 {id, cardId, subjectId, front, back, anchor, reason, note}；
/// aiNotes 条目 {cardId, aiNote}；subjectNames：科目短码 → 显示名。
Future<List<Map<String, Object?>>> processRework({
  required RunSearchFn runSearch,
  required LlmChatFn llmChat,
  required Map<String, String> prompts,
  required List<Map<String, Object?>> queue,
  required List<Map<String, Object?>> aiNotes,
  required Map<String, String> subjectNames,
  required RunOptions opts,
  CardPort? port,
}) async {
  final notesByCard = <String, List<String>>{};
  for (final n0 in aiNotes) {
    final cid = (n0['cardId']?.toString() ?? '');
    if (cid.isNotEmpty) {
      notesByCard
          .putIfAbsent(cid, () => <String>[])
          .add((n0['aiNote']?.toString() ?? ''));
    }
  }
  int prio(Map<String, Object?> it) =>
      ((it['reason']?.toString() ?? '').startsWith('审核拒绝：') ? 0 : 1);
  final sorted = List<Map<String, Object?>>.of(queue)
    ..sort((a, b) {
      final d = prio(a).compareTo(prio(b));
      if (d != 0) {
        return d > 0 ? 1 : -1;
      }
      final ia = (a['id'] as num?)?.toInt() ?? 0;
      final ib = (b['id'] as num?)?.toInt() ?? 0;
      return ia.compareTo(ib);
    });
  final results = <Map<String, Object?>>[];
  for (final it in sorted) {
    final rid = it['id'];
    final frontNow = (it['front'] as String?) ?? '';
    final subjectId = (it['subjectId'] as String?) ?? '';
    final cardIdStr = it['cardId']?.toString() ?? '';
    final item = {
      'queueId': rid,
      'cardId': it['cardId'],
      'subjectId': subjectId,
      'subjectName': subjectNames[subjectId] ?? subjectId,
      'reason': it['reason'],
      'note': it['note'],
      'aiNotes': notesByCard[cardIdStr] ?? <String>[],
      'current': {
        'front': frontNow,
        'back': it['back'],
        'anchor': it['anchor'],
      },
    };
    var q = frontNow.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    if (q.length > 60) {
      q = q.substring(0, 60);
    }
    List<Map<String, Object?>> hits;
    try {
      final res = await runSearch(
        q.isNotEmpty ? q : frontNow,
        subject: subjectId.isEmpty ? null : subjectId,
        sourceType: 'ppt',
        k: kSearchK,
      );
      hits = searchHits(res, opts.floor);
    } on SearchException {
      hits = <Map<String, Object?>>[];
    }
    final evidence = hits.take(kSearchK).map(chunkToEvidence).toList();
    final evById = <String, Map<String, Object?>>{};
    for (final e in evidence) {
      final cid = e['chunkId'];
      if (cid != null) {
        evById[cid.toString()] = e;
      }
    }
    final payload = {
      'task': 'rework',
      'item': item,
      'pptHit': evidence.isNotEmpty,
      'evidence': evidence,
    };
    final rec = <String, Object?>{
      'queueId': rid,
      'cardId': it['cardId'],
      'priorityRejected': (it['reason']?.toString() ?? '').startsWith('审核拒绝：'),
      'aiNotesRead': (item['aiNotes'] as List).length,
      'done': false,
    };
    try {
      final content = await llmChat(
        prompts['rework'] ?? kFallbackPrompts['rework']!,
        jsonEncode(payload),
        tag: 'rework',
      );
      final obj = extractJsonObj(content) ?? const <String, Object?>{};
      final objM = obj is Map ? obj : const <String, Object?>{};
      final newFront = ((objM['front'] as String?) ?? '').trim().isNotEmpty
          ? (objM['front'] as String).trim()
          : frontNow;
      final newBack = ((objM['back'] as String?) ?? '').trim().isNotEmpty
          ? (objM['back'] as String).trim()
          : (it['back'] as String? ?? '');
      final ev = evById[((objM['evidenceChunkId'] as String?) ?? '')];
      final anchor = ev != null
          ? composeAnchor(ev)
          : ((it['anchor'] as String?) ?? '');
      rec['front'] = newFront;
      rec['back'] = newBack;
      rec['anchor'] = anchor;
      if (opts.dryRun || port == null) {
        rec['draft'] = true; // dry-run：只落草稿不 done（不写服务器）
      } else {
        final rid0 = rid;
        final ridInt = rid0 is num
            ? rid0.toInt()
            : (int.tryParse(rid0?.toString() ?? '') ?? 0);
        final r = await port.reworkDone(
          ridInt,
          front: newFront,
          back: newBack,
          anchor: anchor,
        );
        rec['done'] = r.ok;
        if (!r.ok) {
          final err = (r.error ?? '').length > 160
              ? r.error!.substring(0, 160)
              : (r.error ?? '');
          rec['error'] = 'done 失败（留队列下次处理）：$err';
        }
      }
    } on LlmException catch (e) {
      rec['error'] = 'LLM 失败（留队列下次处理）：$e';
    }
    results.add(rec);
  }
  return results;
}

/// 节点⑤（B3 拍板）：周扫 examMeta 本地兜底——LLM 未给年份/题号时，
/// 年份取候选 deck 名（=真题文件名）中的 4 位年份数字；题号取 deck 内页序
/// （网友回忆版无题号时「用其在 deck 内的序号」的模板规则，本地以候选
/// 页位/页码为确定序号）。**解析不出的字段绝不臆造**（保持缺失 →
/// [normalizeCard] 按 CardException 跳过该卡，宁漏不错）。
///
/// 就地补写 [raw] 的 examMeta（保留 LLM 已给出的字段），返回兜底说明列表
/// （空表 = 未做任何兜底；调用方据此在卡 source 注明兜底来源）。
List<String> examMetaFallback(
  Map<String, Object?> raw,
  Map<String, Object?>? ev,
) {
  final meta = raw['examMeta'];
  final m = meta is Map ? Map<String, Object?>.from(meta) : <String, Object?>{};
  var year = ((m['year'] ?? raw['examYear'])?.toString() ?? '').trim();
  var no = (m['no']?.toString() ?? '').trim();
  if (year.isNotEmpty && no.isNotEmpty) {
    return const [];
  }
  final reasons = <String>[];
  if (year.isEmpty && ev != null) {
    // deck 名（真题文件名）优先，title/chunkId 兜底——只认 19xx/20xx 四位年份
    for (final src0 in [
      ev['deck'],
      ev['title'],
      ev['chunkId'],
    ]) {
      final src = src0?.toString() ?? '';
      final mm = RegExp(r'(19|20)\d{2}').firstMatch(src);
      if (mm != null) {
        year = mm.group(0)!;
        reasons.add('年份取自 deck 名/文件名');
        break;
      }
    }
  }
  if (no.isEmpty && ev != null) {
    // deck 内序号：候选页位（pageRange）优先，chunkId 的 :p<页> 形态兜底
    final pr = (ev['pageRange']?.toString() ?? '');
    final pm = RegExp(r'\d+').firstMatch(pr);
    if (pm != null) {
      no = pm.group(0)!;
      reasons.add('题号取自 deck 内页序');
    } else {
      final cm = RegExp(r':p(\d+)').firstMatch(ev['chunkId']?.toString() ?? '');
      if (cm != null) {
        no = cm.group(1)!;
        reasons.add('题号取自 deck 内页序');
      }
    }
  }
  if (reasons.isEmpty) {
    return const []; // 一个字段都兜不出来 → 不动，交给 normalizeCard 跳卡
  }
  if (year.isNotEmpty) {
    m['year'] = year;
  }
  if (no.isNotEmpty) {
    m['no'] = no;
  }
  raw['examMeta'] = m;
  return reasons;
}

/// 通道 B 周扫：已学章名扫真题库（「大纲」deck 剔除 + 全局去重）→ round-robin
/// 均衡 → LLM 逐题判定 → ≤30 张/周【可调】→ 幂等 import。
///
/// chapters 条目 {subject, subjectName, chapter}（唯一起点：只扫已学章节，
/// 未学不出卡——由调用方从 progress 数据装配）；legalSubjects 条目 {id, name}。
/// 节点⑤（B2 拍板）新增 [skillTopics]：技能五站专题豁免「已学章」门控——
/// 按专题短码直检真题库（subject=<code>、sourceType='exam'）；每类出卡
/// ≤[kWeeklySkillCapPerTopic]，技能卡仍计入 kWeeklyExamCap 总量。
Future<Map<String, Object?>> runWeekly({
  required RunSearchFn runSearch,
  required LlmChatFn llmChat,
  required Map<String, String> prompts,
  required List<Map<String, Object?>> chapters,
  required List<Map<String, Object?>> legalSubjects,
  required RunOptions opts,
  CardPort? port,
  List<String> notes = const [],

  /// 节点⑤（B2）：技能五站专题（isSkill=true，见 exam_topics.dart）。
  /// 豁免「已学章」门控：逐专题按 subject=<code> 直检真题库。
  List<ExamTopic> skillTopics = const [],
}) async {
  final notes_ = List<String>.of(notes); // 默认参可为 const []，须拷贝可变副本
  var chapterList = chapters;
  if (opts.limit != null) {
    chapterList = chapterList.take(opts.limit!).toList();
  }
  // ① 逐章检索候选真题（「大纲」deck 剔除；全局去重）
  final bySubject = <String, List<Map<String, Object?>>>{};
  final seen = <String>{};
  var excluded = 0;
  for (final ch in chapterList) {
    final chapter = (ch['chapter'] as String? ?? '');
    try {
      final res = await runSearch(
        chapter,
        subject: null,
        sourceType: 'exam',
        k: kWeeklyKPerChapter,
      );
      for (final r in searchHits(res, opts.floor)) {
        if (!examDeckOk(r)) {
          excluded += 1;
          continue;
        }
        final cid = (r['chunk_id']?.toString() ?? '');
        if (cid.isEmpty || seen.contains(cid)) {
          continue;
        }
        seen.add(cid);
        final cand = chunkToEvidence(r);
        cand['subjectId'] = ch['subject'];
        cand['subjectName'] = ch['subjectName'];
        cand['chapter'] = chapter;
        final sid = (ch['subject']?.toString() ?? '');
        bySubject.putIfAbsent(sid, () => <Map<String, Object?>>[]).add(cand);
      }
    } on SearchException catch (e) {
      notes_.add('周扫检索降级（$chapter）：$e');
    }
  }
  // ①b 节点⑤（B2 拍板）：技能五站豁免「已学章」门控——逐专题按短码直检
  //    真题库（subject=<code>、sourceType='exam'、检索词=专题名）。候选照走
  //    「大纲」deck 剔除与全局去重；出卡侧每类 ≤kWeeklySkillCapPerTopic、
  //    总量仍受 kWeeklyExamCap 约束（技能卡计入总配额）。
  final skillTopicName = <String, String>{};
  var skillCands = 0;
  for (final topic in skillTopics) {
    try {
      final res = await runSearch(
        topic.name,
        subject: topic.code,
        sourceType: 'exam',
        k: kWeeklyKPerChapter,
      );
      for (final r in searchHits(res, opts.floor)) {
        if (!examDeckOk(r)) {
          excluded += 1;
          continue;
        }
        final cid = (r['chunk_id']?.toString() ?? '');
        if (cid.isEmpty || seen.contains(cid)) {
          continue;
        }
        seen.add(cid);
        skillCands += 1;
        skillTopicName[topic.code] = topic.name;
        final cand = chunkToEvidence(r);
        // 专题短码不在 subjects 表（③ 拍板：不进科目 Tab）——subjectId 置空
        // 提示 LLM 从 legalSubjects 里选；出卡侧非法科目跳过（宁漏不错）。
        cand['subjectId'] = '';
        cand['subjectName'] = topic.name;
        cand['chapter'] = topic.name;
        cand['skill'] = true;
        bySubject.putIfAbsent(topic.code, () => <Map<String, Object?>>[]).add(cand);
      }
    } on SearchException catch (e) {
      notes_.add('技能专题检索降级（${topic.name}）：$e');
    }
  }
  // ② 科目均衡 + 配额（round-robin，总量 ≤ min(cap, send_cap)）
  final selected = balanceCandidates(
    bySubject,
    kWeeklyExamCap,
    kWeeklyExamCandSend,
  );
  final payload = {
    'task': 'weekly',
    'chapters': chapterList,
    'subjects': legalSubjects,
    'weeklyCap': kWeeklyExamCap,
    if (skillTopics.isNotEmpty) ...<String, Object?>{
      // 节点⑤（B2）：技能五站专题候选（candidates 中 skill=true）豁免已学
      // 章门控——专题清单随载荷下发，提示词据模板规则正常判定。
      'skillTopics': [
        for (final t in skillTopics) {'code': t.code, 'name': t.name},
      ],
      'skillCapPerTopic': kWeeklySkillCapPerTopic,
    },
    'candidates': selected,
  };
  final cards = <Map<String, Object?>>[];
  String? llmErr;
  // 节点⑤：技能每类出卡计数 / examMeta 兜底计数（结果 counts 上报）
  final skillCardCount = <String, int>{};
  var examMetaFallbacks = 0;
  if (selected.isNotEmpty) {
    try {
      final content = await llmChat(
        prompts['weekly'] ?? kFallbackPrompts['weekly']!,
        jsonEncode(payload),
        tag: 'weekly',
      );
      final obj = extractJsonObj(content);
      final rc = obj is Map ? obj['cards'] : obj;
      final rawCards = rc is List ? rc : const <Object?>[];
      final legalIds = legalSubjects
          .map((s) => (s['id']?.toString() ?? ''))
          .where((x) => x.isNotEmpty)
          .toSet();
      final candSubj = <String, String>{};
      final candByChunk = <String, Map<String, Object?>>{};
      final candSkillTopic = <String, String>{}; // chunkId → 技能专题短码
      for (final c in selected) {
        final cid = c['chunkId']?.toString();
        if (cid != null) {
          candByChunk[cid] = c;
          candSubj[cid] = c['subjectId']?.toString() ?? 'unknown';
          if (c['skill'] == true) {
            // bySubject 键即专题短码（①b 装配）——反查所属技能专题
            for (final e in bySubject.entries) {
              if (e.value.any((x) => x['chunkId'] == cid)) {
                candSkillTopic[cid] = e.key;
                break;
              }
            }
          }
        }
      }
      for (final raw0 in rawCards.take(kWeeklyExamCap)) {
        if (raw0 is! Map) {
          continue;
        }
        final raw = Map<String, Object?>.from(raw0);
        raw['kind'] = 'exam'; // 通道 B 只出真题卡
        final chunkId = (raw['evidenceChunkId'] as String?) ?? '';
        final skillCode = candSkillTopic[chunkId];
        var sid = (raw['subjectId'] as String?)?.trim() ?? '';
        if (!legalIds.contains(sid)) {
          if (skillCode != null) {
            // 节点⑤：技能候选无法回退科目（专题短码不在 subjects 表）→
            // 宁漏不错跳过，绝不落 'unknown' 废卡。
            notes_.add(
              '技能真题卡科目非法（$sid），跳过——宁漏不错',
            );
            continue;
          }
          // 科目非法 → 回退该候选所属章的科目
          sid =
              candSubj[chunkId] ??
              'unknown';
          raw['subjectId'] = sid;
        }
        // 节点⑤（B3 拍板）：examMeta 兜底——年份取 deck 名（文件名）、题号
        // 取 deck 内页序；解析不出不臆造（normalizeCard 按缺 examMeta 跳卡）。
        final fb = examMetaFallback(raw, candByChunk[chunkId]);
        try {
          final card = normalizeCard(raw, sid, '', const {});
          if (fb.isNotEmpty) {
            // 兜底来源在卡 source 注明（B3 拍板；importPayload 只透传既有字段）
            card['source'] =
                '${card['source']}（examMeta 兜底：${fb.join('、')}）';
            examMetaFallbacks += 1;
          }
          if (skillCode != null) {
            // 节点⑤（B2）：技能五站每类每周 ≤kWeeklySkillCapPerTopic
            final n = (skillCardCount[skillCode] ?? 0) + 1;
            if (n > kWeeklySkillCapPerTopic) {
              notes_.add(
                '技能专题出卡超额截断（${skillTopicName[skillCode] ?? skillCode}'
                ' ≤$kWeeklySkillCapPerTopic）',
              );
              continue;
            }
            skillCardCount[skillCode] = n;
          }
          cards.add(card);
        } on CardException catch (e) {
          notes_.add('周扫单卡归一化跳过：$e');
        }
      }
      if (examMetaFallbacks > 0) {
        notes_.add('examMeta 兜底：$examMetaFallbacks 张（deck 名/页序）');
      }
    } on LlmException catch (e) {
      llmErr = e.toString();
    }
  }
  // ③ import（幂等；dry-run 只落草稿——由调用方归档）
  var imported = 0, skippedN = 0;
  String? importErr;
  if (cards.isNotEmpty && !opts.dryRun && port != null) {
    final r = await port.importCards(cards.map(importPayload).toList());
    if (r.ok) {
      imported = r.inserted;
      skippedN = r.skipped;
    } else {
      importErr = (r.error ?? '').length > 200
          ? r.error!.substring(0, 200)
          : r.error;
    }
  }
  final bySubjCards = <String, int>{};
  for (final c in cards) {
    final sid = (c['subjectId']?.toString() ?? '');
    bySubjCards[sid] = (bySubjCards[sid] ?? 0) + 1;
  }
  return {
    'chapters': chapterList,
    'candidates': selected.length,
    'excludedSyllabus': excluded,
    'llmError': llmErr,
    'cards': cards,
    'counts': {
      'candidates': seen.length + excluded,
      'afterBalance': selected.length,
      'cards': cards.length,
      'imported': imported,
      'skipped': skippedN,
      'bySubject': bySubjCards,
      // 节点⑤：技能五站候选/每类出卡计数 + examMeta 兜底计数（观测口径）
      'skillCandidates': skillCands,
      'skillByTopic': Map<String, int>.of(skillCardCount),
      'examMetaFallback': examMetaFallbacks,
    },
    'notes': notes_,
    'importError': importErr,
  };
}
