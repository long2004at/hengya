// 恒牙（hengya）· 学习进度库（罗盘）· progress_db.dart
// ============================================================================
//
// Python 参考基线（只读，语义 1:1 移植，逐段注明行号，2026-09-06 读取态）：
//   - automation/server-pipeline/progress_db.py（621 行）：progress.json 读写
//     （load_progress L122 / save_progress L135）、find_chapter_no 三级章序
//     定位（L188）、_apply_change 单调前进校验 + history 落盘（L214）、
//     --set/--advance/--from-title/--learned 语义（main L576-608）、--init
//     从 toc sidecar 建/刷新（cmd_init L261）
//   - automation/server-pipeline/run.py（2425 行）：study_log_advance 三重保险
//     推进链（L1221）、compass_locate 当日科目罗盘定位（L1080）、
//     progress_advance（L735——Python 走 CLI 子进程，Dart 直连函数）、
//     subject_display 三层显示名（L769）、cmd_weekly 的 chapters 装配
//     （L1941-1948）、legal_subjects 装配（L1688-1690）
//
// 三重保险（设计 §1.3 ⑥，宁缺毋滥，逐条复刻不放宽）：
//   ① 教材检索 source_type=textbook k=3 → searchHits 过 floor 0.30，
//     未命中不推进（advanceFromTitle，run.py L1244「教材未命中」）；
//   ② 命中但 findChapterNo 定位不到章序 → 不落盘（progressAdvance，
//     progress_db.py main L598「无法从 title 定位章节」exit 2）；
//   ③ 倒退拒绝，进度只单调前进（applyChange，progress_db.py L242；
//     如确需回拨请人工改库）。
//   另加收紧校验（studylog 链）：报「第X章/第X篇」时命中 title 层级号须
//   与所报一致（run_engine.studyHitTrustworthy 六态；smoke 实测「第三章」
//   词面可误命中「…第二十九章…」大块 → 防跳章误推进，run.py L1158 注释）。
//
// #16 口径注记（设计如此，非缺陷，不改行为）：罗盘=教材章进度
// （learned_through 单调指针）。仅「章节」学习记录（收件箱 source=study-log
// 条目）经流水线 studyLogAdvance 推进；关键词→卡片→复习统计（统计页/
// 热力图/打卡）不推罗盘——三重保险防跳章误推进。罗盘条目由 toc sidecar
// 生成：initProgress（--init 整目录）与 initFromTocSidecar（#16 逐科目
// 接线形态）建/刷新，双接线见 local_backend 建库收尾 + pipeline_runner
// catchup 懒初始化；chapters 一律先经 effectiveTocChapters（toc_chapters
// .dart：真章救援 + 辅文过滤、稀疏保 no——2026-09-08 真章全丢根治）。
//
// 罗盘纯函数复用纪律：learnedChapterTitles / currentChapterTitle /
// nextChapterTitle / searchHits / studyHitTrustworthy / normChapterTitle 全部
// import run_engine.dart 复用，不另写实现。
//
// 已知坑（明示，务必规避）：罗盘函数只吃**原始 subjects Map**（进度条目
// {textbook, chapters, learned_through, updated_at, history}）。任何 List
// 视图转换（local_backend._progressView / server routes/progress.dart 的
// subjects 数组）会静默落空——本库读写与推进全部直连原始结构
// （run_probe.dart L275 同款口径）。
//
// 推进链零全局状态（对齐 run_engine 注入风格）：检索 RunSearchFn 注入；
// progressData 由调用方持有，推进直接改内存 Map（Python 每次推进经 CLI
// 子进程独立读改写文件；Dart 单进程内存演进等价且免重复 IO），落盘时机
// 归调用方（saveProgress）。
//
// 与 Python 的行为差异（边界场景，生产数据不涉及）：
//   - saveProgress 缩进：Dart JsonEncoder.withIndent(' ') 与 Python
//     json.dumps(indent=1) 结构等价、非 byte 等价；写出 LF + UTF-8 无 BOM
//     （extract_all.atomicWriteText 统一口径），Python/服务端读取双向兼容。
//   - CLI 交互层（--show/--learned 终端格式化）不移植：罗盘查询走纯函数
//     与 compassSummary；退出码 0/2 语义化为结果 record 的 ok 字段。
//   - findChapterNo 策略①对 no=0 的处理：Python `if best_no:` 视 0 为假
//     继续走策略②，Dart 以 bestNo > 0 同款语义（章序合法域 1..N）。
import 'dart:convert';
import 'dart:io';

import 'extract_all.dart' show atomicWriteText, nowIso;
import 'run_engine.dart'
    show
        RunOptions,
        RunSearchFn,
        SearchException,
        currentChapterTitle,
        learnedChapterTitles,
        nextChapterTitle,
        normChapterTitle,
        searchHits,
        studyHitTrustworthy;
import 'toc_chapters.dart';

// ------------------------------------------------------- 常量（醒目：可调） ----

const String kCompassSourceType = 'textbook'; // 罗盘/学习记录检索限定教材源
const int kCompassSearchK = 3; // 罗盘/学习记录教材检索条数（run.py compass/studylog k=3）

/// progress_db.py L85 _CHAP_TOKEN_RE（策略②「第X章/第X篇」token 提取；
/// 注意与 run_engine.kStudyChapNoRe 差异：此处无 `\s*`，对齐 progress_db 口径）。
final RegExp _chapTokenRe =
    RegExp(r'第([零〇一二两三四五六七八九十百千0-9]+)[篇章]');

// ------------------------------------------------------- progress.json 读写 ----

/// 空进度库（≈progress_db.py L125/L132 缺省态）。
Map<String, Object?> emptyProgress() => {
      'version': 1,
      'subjects': <String, Object?>{},
    };

/// 读 progress.json（≈load_progress L122）：缺失/JSON 损坏/顶层非对象/
/// subjects 非对象 → 空库；合法 → 原样返回（未知顶层键、未知科目键原样保留）。
Map<String, Object?> loadProgress(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    return emptyProgress();
  }
  try {
    final data = jsonDecode(f.readAsStringSync());
    if (data is Map && data['subjects'] is Map) {
      return Map<String, Object?>.from(data);
    }
  } catch (_) {}
  return emptyProgress();
}

/// 写 progress.json（≈save_progress L135：ensure_ascii=False + indent=1 +
/// 原子落盘）。未修改的科目键（含代码不认识的键与字段）原样序列化不动。
void saveProgress(String path, Map<String, Object?> data) {
  atomicWriteText(path, const JsonEncoder.withIndent(' ').convert(data));
}

/// datetime.date.today().isoformat()（history.date 口径）。
String todayIso() => DateTime.now().toIso8601String().substring(0, 10);

/// data['subjects'] 取原始 Map（loadProgress 保证存在；防御手工构造的
/// progressData：缺失/非 Map 时补空 Map——写路径都经此入口，保证可写）。
Map<dynamic, dynamic> _subjectsOf(Map<String, Object?> data) {
  var subs = data['subjects'];
  if (subs is! Map) {
    subs = <String, Object?>{};
    data['subjects'] = subs;
  }
  return subs;
}

/// 罗盘条目便捷取用（原始 subjects Map 直连，只读拷贝；罗盘函数
/// learnedChapterTitles/currentChapterTitle 等的唯一起点——勿用任何
/// List 视图）。科目不存在返回 null。
Map<String, Object?>? progressEntryOf(
    Map<String, Object?>? progressData, String subjectId) {
  final subs = progressData?['subjects'];
  if (subs is! Map) {
    return null;
  }
  final e = subs[subjectId];
  return e is Map ? Map<String, Object?>.from(e) : null;
}

// ------------------------------------------------------------- 定位 ----

/// 检索命中 title → 章序 no（≈find_chapter_no L188；无法定位返回 null）：
///   ① 章标题（去页码尾缀+去空白）包含于命中 title → 取其 no（最长标题优先）；
///   ② 提取「第X章/第X篇」token（中文数字或阿拉伯）→ 找含该 token 的章标题；
///   ③ 仍无法定位 → null（调用方吞掉不阻断——保险②的入口）。
int? findChapterNo(Map<String, Object?>? entry, String? hitTitle) {
  final t = normChapterTitle(hitTitle);
  if (t.isEmpty) {
    return null;
  }
  final chapters0 = entry?['chapters'];
  final chapters = chapters0 is List ? chapters0 : const [];
  // ① 章标题包含于命中 title（最长标题优先）
  int? bestNo;
  var bestLen = 0;
  for (final ch0 in chapters) {
    if (ch0 is! Map) {
      continue;
    }
    final ct = normChapterTitle(ch0['title'] as String?);
    if (ct.isNotEmpty && t.contains(ct) && ct.length > bestLen) {
      bestNo = (ch0['no'] as num?)?.toInt();
      bestLen = ct.length;
    }
  }
  // Python `if best_no:`——no=0（非法章序）同样继续走策略②
  if (bestNo != null && bestNo > 0) {
    return bestNo;
  }
  // ② 第X章/第X篇 token → 含该 token 的章标题
  for (final m in _chapTokenRe.allMatches(hitTitle ?? '')) {
    final token = normChapterTitle(m[0]);
    if (token.isEmpty) {
      continue;
    }
    for (final ch0 in chapters) {
      if (ch0 is! Map) {
        continue;
      }
      final ct = normChapterTitle(ch0['title'] as String?);
      if (ct.isNotEmpty && ct.contains(token)) {
        final no = (ch0['no'] as num?)?.toInt();
        if (no != null && no > 0) {
          return no;
        }
      }
    }
  }
  return null;
}

// ------------------------------------------------------------- 变更核心 ----

/// 单次变更结果：ok ⇔ progress_db CLI 退出码 0（含「未变（N）」原地）；
/// mutated=本次调用是否真的改了条目（创建/推进；未变=false——Python 每次
/// --set/--advance 都重写文件，Dart 交给调用方按 mutated 决定是否 save）。
typedef ProgressChange = ({bool ok, String note, bool mutated});

/// 新科目条目（≈_entry L181）。
Map<String, Object?> _progressEntry(Object? textbook, List<Object?> chapters) =>
    {
      'textbook': textbook,
      'chapters': chapters.isEmpty ? <Object?>[] : chapters,
      'learned_through': 0,
      'updated_at': nowIso(),
      'history': <Object?>[],
    };

/// 条目 history 列表（缺失/非 List 时在**原引用**上补空列表，保证回写可见）。
List<dynamic> _historyOf(Map<dynamic, dynamic> e) {
  var hist = e['history'];
  if (hist is! List) {
    hist = <Object?>[];
    e['history'] = hist;
  }
  return hist;
}

/// 罗盘边界 = 章列表**最大 no**（2026-09-08 起编号可能稀疏：init 经
/// effectiveTocChapters 过滤后幸存条目保留原 no，如 oms 目录/附录剔除后
/// no=3..21 而 length=19——learned_through/skipped 的合法域上界是 21
/// 不是 19）。空列表/无合法 no → 0。learned_through 收口（init 刷新）、
/// 推进/章节管理的上界校验、skipped 规范化域共用本口径（applyChange /
/// setSubjectChapters / _applySidecarEntry 三处）。
int maxChapterNoOf(List chapters) {
  var m = 0;
  for (final c in chapters) {
    if (c is Map) {
      final n = (c['no'] as num?)?.toInt() ?? 0;
      if (n > m) {
        m = n;
      }
    }
  }
  return m;
}

/// 单调前进校验 + history 落盘（≈_apply_change L214，逐分支对齐）：
/// 倒退/超罗盘/负数拒绝；无罗盘科目（textbook=null）仅接受 0（占位）；
/// 未变原地返回 ok；推进时刷新 updated_at 并追加 history。直接改 data
/// 内原始条目引用（浅拷贝会丢回写，勿替换为 progressEntryOf 结果）。
ProgressChange applyChange(
  Map<String, Object?> data,
  String subject,
  int toNo, {
  String source = 'manual',
  String evidence = '',
  bool allowCreate = false,
  String createNote = '',
}) {
  final subs = _subjectsOf(data);
  final e0 = subs[subject];
  Map<dynamic, dynamic> e;
  if (e0 is Map) {
    e = e0;
  } else if (allowCreate) {
    e = _progressEntry(null, const []);
    subs[subject] = e;
  } else {
    return (
      ok: false,
      note: '科目 $subject 不在进度库——先 --init（或 --set 创建占位）',
      mutated: false,
    );
  }
  final cur = (e['learned_through'] as num?)?.toInt() ?? 0;
  final chapters0 = e['chapters'];
  final chapters = chapters0 is List ? chapters0 : const [];
  final nMax = maxChapterNoOf(chapters); // 稀疏编号：上界=最大 no
  if (toNo < 0) {
    return (ok: false, note: '章序不能为负：$toNo', mutated: false);
  }
  if (nMax == 0) {
    // 无教材罗盘（textbook=null，如 derm）：仅接受 0（建占位条目）
    if (toNo != 0) {
      return (
        ok: false,
        note: '科目 $subject 无教材罗盘（textbook=null），仅接受 0',
        mutated: false,
      );
    }
    if (cur == 0) {
      _historyOf(e).add({
        'date': todayIso(),
        'from': 0,
        'to': 0,
        'evidence': createNote.isNotEmpty ? createNote : '创建科目条目',
        'source': source.isNotEmpty ? source : 'manual',
      });
      e['updated_at'] = nowIso();
      return (
        ok: true,
        note: '已创建科目 $subject（无教材罗盘，learned_through=0）',
        mutated: true,
      );
    }
    return (ok: true, note: '未变（0）', mutated: false);
  }
  if (toNo > nMax) {
    return (
      ok: false,
      note: '超出罗盘：第 $toNo 章 > 共 $nMax 章',
      mutated: false,
    );
  }
  if (toNo < cur) {
    // 保险③：倒退拒绝——进度只单调前进
    return (
      ok: false,
      note: '倒退（$cur → $toNo）：进度只单调前进，如确需回拨请人工改库',
      mutated: false,
    );
  }
  if (toNo == cur) {
    return (ok: true, note: '未变（$cur）', mutated: false);
  }
  var title = '';
  for (final ch0 in chapters) {
    if (ch0 is Map && (ch0['no'] as num?)?.toInt() == toNo) {
      title = (ch0['title'] as String?) ?? '';
      break;
    }
  }
  e['learned_through'] = toNo;
  e['updated_at'] = nowIso();
  _historyOf(e).add({
    'date': todayIso(),
    'from': cur,
    'to': toNo,
    'evidence': evidence,
    'source': source.isNotEmpty ? source : 'manual',
  });
  return (
    ok: true,
    note: '$subject：$cur → $toNo（${title.isEmpty ? '?' : title}）',
    mutated: true,
  );
}

/// --set 手动校正（≈main L583：source 默认 manual、种子建议 seed；
/// allowCreate=true——科目不存在则创建占位）。
ProgressChange setSubjectNo(
  Map<String, Object?> data,
  String subject,
  int no, {
  String source = 'manual',
}) =>
    applyChange(
      data,
      subject,
      no,
      source: source,
      evidence: '',
      allowCreate: true,
      createNote: '--set 创建科目条目',
    );

/// 命中 title → 章序定位 → 单调推进（≈main --advance --from-title 分支
/// L597 + progress_advance L735 合体；source=auto、evidence=命中标题）。
/// 保险②：定位不到章序返回 ok=false，不落盘。返回 toNo=定位到的章序
/// （未定位/未推进为 null）。
({bool ok, String note, bool mutated, int? toNo}) progressAdvance(
    Map<String, Object?> data, String subject, String? fromTitle) {
  final subs = _subjectsOf(data);
  final e = subs[subject];
  if (e is! Map) {
    return (
      ok: false,
      note: '科目 $subject 不在进度库——先 --init',
      mutated: false,
      toNo: null,
    );
  }
  final no = findChapterNo(Map<String, Object?>.from(e), fromTitle);
  if (no == null) {
    return (
      ok: false,
      note:
          "无法从 title 定位章节：'$fromTitle'（命中 title 应为教材块「章名·节名」形态）",
      mutated: false,
      toNo: null,
    );
  }
  final r = applyChange(data, subject, no,
      source: 'auto', evidence: fromTitle ?? '', allowCreate: false);
  return (ok: r.ok, note: r.note, mutated: r.mutated, toNo: no);
}

// ------------------------------------------------ 章节管理（⑨：skipped 模型） ----

/// 章节管理数据契约（⑨，向后兼容第一）：
/// progress.json 科目条目新增**可选**字段 `skipped`——「不学」章序 int
/// 列表（升序）。缺失 / 非 List / 元素非 int = 无跳过（旧数据零迁移：
/// 未用过章节管理的条目文件保持一字节不变）。语义：
///   - 有效总量 = chapters.length − skipped 中真实存在于章列表的章数；
///   - learned_through 保持原始前缀指针（含跳过章——「已学到此」推进到
///     第 N 个非跳过章 = 指针落到该章 no，指针区间内的跳过章自然越过、
///     不计入有效已学数）；
///   - 「下一章」= no > learned_through 的第一条正文章且未被跳过。
/// Python 端 progress_db.py 不认识该字段：原样保留（load/save 全量读改写
/// 不丢字段），远端服务器视图暂不感知跳过（App 端 local 默认模式已生效）。

/// 读取条目 skipped 章序（只读透传；缺失/非 List → 空；非 int / ≤0 元素
/// 丢弃——章序合法域 1..N，no=0（个别 toc 抽取的 0 基目录行）不属于可
/// 跳过域）。规范化（去重排序）归 [setSubjectChapters]。
List<int> skippedChaptersOf(Map<String, Object?>? entry) {
  final raw = entry?['skipped'];
  if (raw is! List) {
    return const [];
  }
  return [for (final v in raw) if (v is int && v > 0) v];
}

/// skipped 规范化：去重、升序、仅保留 1..nMax 域内章序。
List<int> _normalizeSkipped(int nMax, List<int> nos) =>
    {...nos.where((n) => n >= 1 && n <= nMax)}.toList()..sort();

bool _sameIntList(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 章节管理手动变更（⑨：进度页「章节管理」弹层的落库核心，与流水线
/// 三重保险推进链并行共存——两路殊途同归改同一 json 条目）：
///   - [learnedThrough]：任意位置推进 / **回退**（回退由 UI 弹确认后调用；
///     与 applyChange 保险③「倒退拒绝」不冲突——那是防流水线误回拨，
///     人工明确确认的回退走本函数，evidence 注明「章节管理回退」）；
///   - [skipped]：全量替换「不学」章序列表（null=不动该字段）。
/// 校验：负数 / 超罗盘拒绝；无罗盘占位（nMax==0，如 derm/med）仅接受 0。
/// history 仅在 learnedThrough 实际变化时追加（from/to/evidence/source，
/// 与 applyChange 同构）；跳过切换只 bump updated_at（不伪造 from==to 的
/// 历史行）。直接改 data 内原始条目引用；落盘归调用方（saveProgress）。
ProgressChange setSubjectChapters(
  Map<String, Object?> data,
  String subject, {
  int? learnedThrough,
  List<int>? skipped,
  String source = 'manual',
}) {
  final subs = _subjectsOf(data);
  final e = subs[subject];
  if (e is! Map) {
    return (
      ok: false,
      note: '科目 $subject 不在进度库——章节管理仅面向已有科目',
      mutated: false,
    );
  }
  final cur = (e['learned_through'] as num?)?.toInt() ?? 0;
  final chapters0 = e['chapters'];
  final chapters = chapters0 is List ? chapters0 : const [];
  final nMax = maxChapterNoOf(chapters); // 稀疏编号：上界=最大 no
  final notes = <String>[];
  var mutated = false;
  if (learnedThrough != null) {
    if (learnedThrough < 0) {
      return (ok: false, note: '章序不能为负：$learnedThrough', mutated: false);
    }
    if (nMax == 0 && learnedThrough != 0) {
      // 无教材罗盘占位（textbook=null，如 derm/med）：仅接受 0（同 applyChange）
      return (
        ok: false,
        note: '科目 $subject 无教材罗盘（textbook=null），仅接受 0',
        mutated: false,
      );
    }
    if (learnedThrough > nMax) {
      return (
        ok: false,
        note: '超出罗盘：第 $learnedThrough 章 > 共 $nMax 章',
        mutated: false,
      );
    }
    if (learnedThrough != cur) {
      var title = '';
      for (final ch0 in chapters) {
        if (ch0 is Map && (ch0['no'] as num?)?.toInt() == learnedThrough) {
          title = (ch0['title'] as String?) ?? '';
          break;
        }
      }
      e['learned_through'] = learnedThrough;
      _historyOf(e).add({
        'date': todayIso(),
        'from': cur,
        'to': learnedThrough,
        'evidence': learnedThrough < cur
            ? '章节管理回退${title.isEmpty ? '' : '（$title）'}'
            : '章节管理推进${title.isEmpty ? '' : '（$title）'}',
        'source': source.isNotEmpty ? source : 'manual',
      });
      mutated = true;
      notes.add(learnedThrough < cur ? '回退 $cur → $learnedThrough' : '推进 $cur → $learnedThrough');
    }
  }
  if (skipped != null) {
    final norm = _normalizeSkipped(nMax, skipped);
    if (!_sameIntList(skippedChaptersOf(Map<String, Object?>.from(e)), norm)) {
      if (norm.isEmpty) {
        e.remove('skipped'); // 清空即移除字段：旧格式零残留
      } else {
        e['skipped'] = norm;
      }
      mutated = true;
      notes.add('不学章 ${norm.length} 个');
    }
  }
  if (mutated) {
    e['updated_at'] = nowIso();
  }
  return (
    ok: true,
    note: notes.isEmpty ? '未变' : notes.join('，'),
    mutated: mutated,
  );
}

// ------------------------------------------------------------- 初始化 ----

/// 从 toc sidecar 建/刷新进度库（≈cmd_init L261；sidecar 结构与
/// extract_all._writeTocSidecar / Python _write_toc_sidecar 完全一致：
/// {version, subject, textbook, chapters:[{no,title,page_start}], sections}）。
/// 新科目全 0 初始化；已有科目刷新 textbook/chapters 但保留 learned_through
/// （收口到新列表最大 no）与 history；force 全部重建（清零清史）；不来自
/// sidecar 的科目（如 derm 占位）保留。目录缺失/无 *.json/结构异常 →
/// ok=false。chapters 经 effectiveTocChapters 变换（真章救援 + 辅文过滤，
/// 稀疏保 no）——过滤后章数与原 sidecar 条目数不同属预期。
({bool ok, String note, int added, int refreshed}) initProgress(
  Map<String, Object?> data,
  String tocDir, {
  bool force = false,
}) {
  final dir = Directory(tocDir);
  if (!dir.existsSync()) {
    return (
      ok: false,
      note: 'toc sidecar 目录不存在：$tocDir（先跑建库落 toc sidecar）',
      added: 0,
      refreshed: 0,
    );
  }
  final paths = dir
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.json'))
      .toList()
    ..sort(); // ≈sorted(tdir.glob("*.json"))，小写扩展名（建库统一 .json）
  if (paths.isEmpty) {
    return (
      ok: false,
      note: 'toc sidecar 目录无 *.json：$tocDir',
      added: 0,
      refreshed: 0,
    );
  }
  var added = 0;
  var refreshed = 0;
  final subs = _subjectsOf(data);
  for (final p in paths) {
    final name = _baseName(p);
    Map<String, Object?> sc;
    try {
      final obj = jsonDecode(File(p).readAsStringSync());
      sc = obj is Map ? Map<String, Object?>.from(obj) : const {};
    } catch (ex) {
      return (
        ok: false,
        note: 'sidecar 解析失败 $name：$ex',
        added: 0,
        refreshed: 0,
      );
    }
    if (sc['chapters'] is! List) {
      return (
        ok: false,
        note: 'sidecar 结构异常 $name（缺 chapters）',
        added: 0,
        refreshed: 0,
      );
    }
    final scSubject = (sc['subject'] as String?) ?? '';
    final subject = scSubject.isNotEmpty ? scSubject : _stemOf(name);
    // 真章救援 + 辅文过滤（toc_chapters.dart 契约；幸存条目稀疏保 no）
    final chapters = effectiveTocChapters(sc);
    final r = _applySidecarEntry(subs, sc, subject, chapters, force: force);
    if (r.created) {
      added += 1;
    } else {
      refreshed += 1;
    }
  }
  final verb = force ? '重建' : '建/刷新';
  return (
    ok: true,
    note: '--init $verb：新增 $added、刷新 $refreshed（进度库共 ${subs.length} 科目）',
    added: added,
    refreshed: refreshed,
  );
}

/// 单 sidecar 条目建/刷新核心（initProgress 与 initFromTocSidecar 共用；
/// ≈cmd_init L280-290）：新科目（或 [force]）建全 0 条目；已有科目刷新
/// textbook/chapters 并把 learned_through 收口到列表**最大 no**（稀疏
/// 编号：effectiveTocChapters 后 no 可大于条目数——按条目数收口会错误
/// 截断指针；空列表收 0；**learned_through 与 history 绝不回拨/清空**
/// ——除 force）。created/refreshed 二选一。
({bool created, bool refreshed}) _applySidecarEntry(
  Map<dynamic, dynamic> subs,
  Map<String, Object?> sc,
  String subject,
  List<Object?> chapters, {
  required bool force,
}) {
  final prev = subs[subject];
  if (prev is! Map || force) {
    subs[subject] = _progressEntry(sc['textbook'], chapters);
    return (created: true, refreshed: false);
  }
  prev['textbook'] = sc['textbook'];
  prev['chapters'] = chapters;
  final lt = (prev['learned_through'] as num?)?.toInt() ?? 0;
  final nMax = maxChapterNoOf(chapters); // 稀疏编号：收口按最大 no
  prev['learned_through'] = lt < 0 ? 0 : (lt > nMax ? nMax : lt);
  prev['updated_at'] = nowIso();
  return (created: false, refreshed: true);
}

/// #16 罗盘初始化·逐科目形态（对齐 Python cmd_init L261 的单 sidecar 语义；
/// 建库收尾与流水线懒初始化两处接线的公共入口）：
/// `<tocDir>/<subjectId>.json` 存在 → 条目不存在则建全 0 条目（textbook=
/// 教材名、chapters=effectiveTocChapters(sidecar)（真章救援+辅文过滤，
/// 稀疏保 no——derm 17 垃圾 → 29 真章即此路径）、learned_through=0、
/// history=[]）；已存在则刷新 textbook/chapters、**保留 learned_through 与
/// history**（建/刷新语义，绝不回拨进度；收口到新列表最大 no）。sidecar
/// 缺失/解析失败/结构异常 → ok=false 且**不动进度库**，note 记录原因
/// （宁缺毋滥——多科目场景由调用方逐科目调用，单科目损坏不株连其他科目）。
/// 条目键优先 sidecar 自带 subject 字段（≈cmd_init L278
/// `sc.get("subject") or f.stem`，writeTocSidecar 侧两者恒一致）。
({bool ok, String note, bool mutated}) initFromTocSidecar(
  Map<String, Object?> data,
  String tocDir,
  String subjectId,
) {
  final f = File('$tocDir/$subjectId.json');
  if (!f.existsSync()) {
    return (
      ok: false,
      note: 'toc sidecar 缺失：${f.path}（跳过初始化，不动进度库）',
      mutated: false,
    );
  }
  final Map<String, Object?> sc;
  try {
    final obj = jsonDecode(f.readAsStringSync());
    sc = obj is Map ? Map<String, Object?>.from(obj) : const {};
  } catch (ex) {
    return (
      ok: false,
      note: 'sidecar 解析失败 $subjectId：$ex（不动进度库）',
      mutated: false,
    );
  }
  if (sc['chapters'] is! List) {
    return (
      ok: false,
      note: 'sidecar 结构异常 $subjectId（缺 chapters，不动进度库）',
      mutated: false,
    );
  }
  final scSubject = (sc['subject'] as String?) ?? '';
  final subject = scSubject.isNotEmpty ? scSubject : subjectId;
  // 真章救援 + 辅文过滤（toc_chapters.dart 契约；幸存条目稀疏保 no）
  final chapters = effectiveTocChapters(sc);
  final r =
      _applySidecarEntry(_subjectsOf(data), sc, subject, chapters, force: false);
  return (
    ok: true,
    mutated: true, // 建/刷新均改条目（cmd_init 语义：刷新也 bump updated_at）
    note: r.created
        ? '罗盘新增科目 $subject（${chapters.length} 章，全 0 起步）'
        : '罗盘刷新科目 $subject（${chapters.length} 章，保留进度与历史）',
  );
}

/// toc sidecar 目录的科目短码清单（`<tocDir>/<stem>.json` 的 stem，排序
/// 稳定；≈cmd_init `sorted(tdir.glob("*.json"))` 的预处理）。目录缺失/
/// IO 异常 → null（调用方按「无 sidecar」静默跳过，不阻断）。
List<String>? tocSidecarSubjects(String tocDir) {
  try {
    final dir = Directory(tocDir);
    if (!dir.existsSync()) {
      return null;
    }
    return [
      for (final p in dir.listSync().whereType<File>().map((f) => f.path))
        if (p.endsWith('.json')) _stemOf(_baseName(p)),
    ]..sort();
  } catch (_) {
    return null;
  }
}

String _baseName(String p) {
  final i = p.lastIndexOf('/');
  final j = p.lastIndexOf('\\');
  final k = i > j ? i : j;
  return k < 0 ? p : p.substring(k + 1);
}

String _stemOf(String name) =>
    name.endsWith('.json') ? name.substring(0, name.length - 5) : name;

// ------------------------------------------------------------- 推进链 ----

/// 三重保险推进链（seam 注入版；≈run.py study_log_advance L1233-1268 单 ref
/// 步 + compass_locate L1088-1107 单科目步合体）：
/// 教材检索（source_type=textbook k=3，RunSearchFn 注入——引擎零全局状态）
/// → searchHits 过 floor 0.30（保险①）→ [trustworthy] 章/篇号收紧校验
/// → progressAdvance 章序定位（保险②）+ 单调推进（保险③）。
///
/// [query]：studylog 链=章节引用（学生口报）；compass 链=罗盘当前章名。
/// [trustworthy] 默认 true（宁紧勿松：漏传只可能「少推进」，绝不「误推进」）；
/// compass 链传 false——罗盘当前章是内部数据非学生口报，无收紧校验
/// （Python compass_locate 无 _study_hit_trustworthy，同口径）。
///
/// 返回 row（键对齐 Python study_log_advance 的 row dict，advanceExit→ok）：
///   {ok, note, advanced?, hit?, toNo?, wouldAdvance?}
///   - ok=true ⇔ 推进成功（含「未变（N）」原地；Python rc==0）
///   - dry-run：ok=false + wouldAdvance=命中标题，不真推进
///   - SearchException/未命中/不可信/定位不到/倒退：ok=false + note（不阻断）
///   - 推进直接改 [progressData] 内存；落盘归调用方（saveProgress）。
Future<Map<String, Object?>> advanceFromTitle({
  required RunSearchFn runSearch,
  required String subjectId,
  required String query,
  required Map<String, Object?> progressData,
  required RunOptions opts,
  bool trustworthy = true,
}) async {
  // 保险前置：进度库无该科目 → 不检索不推进不阻断（run.py L1229/L1085）
  if (progressEntryOf(progressData, subjectId) == null) {
    return {'ok': false, 'note': '进度库无该科目（先 --init）——不推进，不阻断'};
  }
  try {
    final res = await runSearch(query,
        subject: subjectId.isEmpty ? null : subjectId,
        sourceType: kCompassSourceType,
        k: kCompassSearchK);
    final hits = searchHits(res, opts.floor);
    if (hits.isEmpty) {
      // 保险①：低于低分线视为不可信=未命中，不推进
      return {
        'ok': false,
        'note':
            '教材未命中（低于低分线 ${opts.floor.toStringAsFixed(2)}）——不推进',
      };
    }
    final hitTitle = (hits.first['title'] as String?) ?? '';
    if (trustworthy && !studyHitTrustworthy(query, hitTitle)) {
      // 收紧校验（dry-run 亦执行，使影子日志如实预演转正效果）：
      // 报「第X章/第X篇」时命中 title 层级号须与所报一致，否则视为误
      // 命中不推进（smoke 实测：报「第三章」词面可命中「…第二十章 …」大块）
      final h = hitTitle.length > 40 ? hitTitle.substring(0, 40) : hitTitle;
      return {'ok': false, 'note': '命中章节与所报章/篇号不一致——不推进（命中：$h）'};
    }
    if (opts.dryRun) {
      return {
        'ok': false,
        'note': 'dry-run 跳过罗盘推进（命中：$hitTitle）',
        'wouldAdvance': hitTitle,
      };
    }
    final r = progressAdvance(progressData, subjectId, hitTitle);
    return {
      'ok': r.ok,
      'note': r.note,
      'advanced': r.ok, // 含「未变（N）」原地；倒退/定位不到 ok=false
      'hit': hitTitle,
      'toNo': r.toNo,
    };
  } on SearchException catch (e) {
    // 契约 10：检索故障降级记 note，不阻断（条目留次日补跑由调用方判 note）
    return {'ok': false, 'note': '教材检索失败（不阻断）：$e'};
  }
}

/// 学习记录逐章节引用走罗盘推进（≈run.py study_log_advance L1221 全函数；
/// trustworthy=true 收紧校验；dry-run 仅记 wouldAdvance）。
///
/// 返回 {subjectId, subjectName, refs:[{ref, …advanceFromTitle row}],
/// advancedCount}；进度库无该科目 → {…, note}（不检索不推进不阻断）。
Future<Map<String, Object?>> studyLogAdvance({
  required RunSearchFn runSearch,
  required String subjectId,
  required String subjectName,
  required List<String> refs,
  required Map<String, Object?> progressData,
  required RunOptions opts,
}) async {
  final out = <String, Object?>{
    'subjectId': subjectId,
    'subjectName': subjectName.isEmpty ? subjectId : subjectName,
    'refs': <Map<String, Object?>>[],
  };
  if (progressEntryOf(progressData, subjectId) == null) {
    out['note'] = '进度库无该科目（先 --init）——不推进，不阻断';
    return out;
  }
  final rows = out['refs'] as List<Map<String, Object?>>;
  for (final ref in refs) {
    final row = await advanceFromTitle(
      runSearch: runSearch,
      subjectId: subjectId,
      query: ref,
      progressData: progressData,
      opts: opts,
      trustworthy: true,
    );
    row['ref'] = ref;
    rows.add(row);
  }
  out['advancedCount'] =
      rows.where((r) => r['advanced'] == true).length; // ≈st['compassAdvances']
  return out;
}

/// 当日科目罗盘定位（≈run.py compass_locate L1080）：逐科目检索
/// 「当前章名（currentChapterTitle）→ 科目显示名回退」→ advanceFromTitle
/// 推进（trustworthy=false——内部数据无收紧校验；dry-run 仅记 wouldAdvance）。
/// subjectsToday 去重排序（≈sorted(set(...))）；返回 sid → row Map。
Future<Map<String, Map<String, Object?>>> compassLocate({
  required RunSearchFn runSearch,
  required Iterable<String> subjectsToday,
  required Map<String, Object?> progressData,
  required String Function(String subjectId) subjectDisplay,
  required RunOptions opts,
}) async {
  final out = <String, Map<String, Object?>>{};
  for (final sid in ({...subjectsToday}.toList()..sort())) {
    final entry = progressEntryOf(progressData, sid);
    if (entry == null) {
      // ≈run.py L1085：进度库无该科目 → 不检索不推进，不阻断
      out[sid] = {'ok': false, 'note': '进度库无该科目（先 --init）——不阻断'};
      continue;
    }
    out[sid] = await advanceFromTitle(
      runSearch: runSearch,
      subjectId: sid,
      query:
          currentChapterTitle(entry) ?? subjectDisplay(sid), // 未开始 → 显示名回退
      progressData: progressData,
      opts: opts,
      trustworthy: false,
    );
  }
  return out;
}

// ------------------------------------------------------------- 装配器 ----

/// 科目显示名三层回退（≈subject_display L769）：课表/DB 科目名 →
/// 教材名（去「-第X版」尾缀）→ 短码。
String subjectDisplayName(
  String subjectId, {
  Map<String, String> subjectNames = const {},
  Map<String, Object?>? progressData,
}) {
  final n = subjectNames[subjectId];
  if (n != null && n.isNotEmpty) {
    return n;
  }
  final tb = progressEntryOf(progressData, subjectId)?['textbook'] as String?;
  if (tb != null && tb.isNotEmpty) {
    return tb.replaceAll(RegExp(r'-第\d+版$'), '');
  }
  return subjectId;
}

/// 周扫 chapters 装配（≈cmd_weekly L1941-1948，runWeekly 留缝处的唯一供料）：
/// 全科目已学正文章名 → [{subject, subjectName, chapter}]（按科目名排序；
/// 目录/前言/索引类经 learnedChapterTitles 正文过滤，唯一起点=已学章节，
/// 未学不出卡）。⑨ 章节管理：**跳过章（skipped）视同未学**——指针虽越过
/// 仍不进周扫真题池（宁少勿多，与「不学」的用户意图一致）。
List<Map<String, Object?>> weeklyChapters(
  Map<String, Object?> progressData, {
  Map<String, String> subjectNames = const {},
}) {
  final out = <Map<String, Object?>>[];
  final subs = progressData['subjects'];
  if (subs is! Map) {
    return out;
  }
  for (final sid in (subs.keys.map((k) => k.toString()).toList()..sort())) {
    final e = subs[sid];
    if (e is! Map) {
      continue;
    }
    final entry = Map<String, Object?>.from(e);
    final skipped = skippedChaptersOf(entry).toSet();
    for (final c in learnedChapterTitles(entry)) {
      if (skipped.contains(c.no)) {
        continue; // 「不学」章：不出周扫真题卡
      }
      out.add({
        'subject': sid,
        'subjectName':
            subjectDisplayName(sid, subjectNames: subjectNames, progressData: progressData),
        'chapter': c.title,
      });
    }
  }
  return out;
}

/// 合法科目装配（≈cmd_main L1688-1690：课表科目 ∪ 进度库科目；
/// cmd_weekly L1980-1983 再并检索命中科目——经 extraIds）。
/// 返回 [{id, name}]（排序去重；name 走三层显示名）。
List<Map<String, Object?>> legalSubjects(
  Map<String, Object?> progressData, {
  Map<String, String> subjectNames = const {},
  Iterable<String>? extraIds,
}) {
  final ids = <String>{...subjectNames.keys};
  final subs = progressData['subjects'];
  if (subs is Map) {
    ids.addAll(subs.keys.map((k) => k.toString()));
  }
  ids.addAll(extraIds ?? const Iterable<String>.empty());
  return [
    for (final sid in (ids.toList()..sort()))
      {
        'id': sid,
        'name': subjectDisplayName(sid,
            subjectNames: subjectNames, progressData: progressData),
      },
  ];
}

// ------------------------------------------------------------- 罗盘查询 ----

/// 罗盘单科查询（--learned/--show 的数据层；展示归调用方）：
/// learnedThrough（章序指针，0=未开始）、chapterCount（含目录/索引辅文章，
/// 不重编号）、learned（已学正文章）、current（当前章）、next（下一正文章）。
({
  int learnedThrough,
  int chapterCount,
  List<({int no, String title})> learned,
  String? current,
  String? next,
}) compassSummary(Map<String, Object?>? entry) {
  final chapters0 = entry?['chapters'];
  return (
    learnedThrough: (entry?['learned_through'] as num?)?.toInt() ?? 0,
    chapterCount: chapters0 is List ? chapters0.length : 0,
    learned: learnedChapterTitles(entry),
    current: currentChapterTitle(entry),
    next: nextChapterTitle(entry),
  );
}
