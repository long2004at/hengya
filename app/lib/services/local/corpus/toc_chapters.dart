// 恒牙（hengya）· toc sidecar 章节列表推导（真章救援 + 辅文过滤）
// · toc_chapters.dart
// ============================================================================
//
// 【为什么存在】toc sidecar（extract_all.writeTocSidecar 建库落盘；结构
// {version, subject, textbook, updated_at, chapters:[{no,title,page_start}],
// sections:[{chapter_no,title,page_start}]}）的 chapters 是 PDF/DOCX 书签
// 第一层：混着辅文垃圾（目录/版权页/索引……）与「篇」级条目，而真正的
// 「第X章」在 derm/endo/patho 里只存在于 sections（书签第二层）。消费端
// （罗盘）原先裸取 chapters → 真章全丢、垃圾满屏。本文件是唯一的推导
// 入口 [effectiveTocChapters]，建库（progress_db.initProgress /
// initFromTocSidecar）与导入（corpus_package._syncProgress）两端同源接线。
//
// 【契约】纯函数：无 IO、无全局状态；sidecar 只读不改（sections 与其余
// 字段原样保留——幂等的根基）。输出为可直接落 progress.json 的章列表：
//   1. 标题归一：输出 title 剥尾部「 / 页码」污染（ortho「第一章 绪论 /
//      1」→「第一章 绪论」）+ trim（内部空白保留，含全角空格）；**比对**
//      一律用去空白形态（run_engine.normChapterTitle，同 findChapterNo）。
//   2. 真章判定：归一 title 命中 `^第[一二三四五六七八九十百零两]+[章篇]`
//      或恰为「绪论」；救援门只数「第X章」（篇/节不算章）。
//   3. sections 救援：chapters「第X章」条数 < 2 且 sections「第X章」条数
//      ≥ 3 → 采用 sections 的**真章**条目（节级内容——「一、」「第X节」
//      形态——一律不采纳），保持原顺序，no 重编 1..N 连续（旧列表本来就
//      是垃圾，手机端指针几乎必为 0，重编安全），保留 page_start、丢
//      chapter_no，title 归一。derm/endo/patho 走此路径。
//   4. 辅文过滤（其余情况用 chapters）：剔除 (a) 精确垃圾集合
//      [kTocJunkExact]（§7.5 拍板 9 项 ∪ 真机实测垃圾 17 项）；(b) 归一后
//      以「附录」「附表」开头（anatomy 附录口腔解剖生理学实验教程、
//      imaging 附录I/II、mucosa 附录名词、patho 附表统计等）；(c)「第X篇」
//      级条目（不是可学章）。幸存条目**保留原 no（稀疏编号，不重编）**——
//      手机端 learned_through/skipped 存的是章序号，保留原 no 才不错位。
//      注意：单独成条的「实习教程」（oms no=21）是真实学习内容，不在
//      垃圾集合内，勿动；带「第X章」编号的实习教程章（pedo 第十五章）
//      更必须保留。
//   5. 幂等：对已变换过的输入再跑一次结果完全一致——救援产出的新列表
//      真章数 ≥ 3 ≥ 2，二次走过滤路径空操作；过滤路径永不剔除「第X章」
//      条目，故「第X章」计数不下降、路径选择稳定（见
//      test/toc_chapters_test.dart 幂等组）。
//   6. 空防御：chapters 非 List → 空列表；sections 非 List、任一条目非
//      Map、缺 String title → 整体退化为「chapters 原样返回」（不过滤、
//      不归一、不重编——宁可不修，绝不歪曲数据；非 Map 条目无法装入返回
//      类型，静默丢弃）。任何输入不抛异常。
//
// 2026-09 真机实测 13 科形态（救援门逐一核对）：derm=17 垃圾+29 真章
// sections、endo=0 章（垃圾+4 篇）+29 真章、patho=0 章+22 真章 → 救援；
// ortho（带 / 页码尾）/oms/anatomy/imaging/implant/mucosa/pedo/peri/
// prevent/prostho 为 flat 章（≥2 章）→ 过滤，全部产出干净章列表。
import 'run_engine.dart' show normChapterTitle, stripChapterPageSuffix;

/// 精确辅文垃圾集合（比对在去空白归一后进行）。前 9 项 = §7.5 拍板
/// _NON_CONTENT_EXACT（demo_backend / local_backend / run_engine
/// .kNonContentChapters 三处同款，**那三处保持不动**）；后 17 项 =
/// 2026-09 真机实测 PDF 书签第一层垃圾（derm/patho/implant/ortho 等）。
const Set<String> kTocJunkExact = {
  // §7.5 拍板 9 项（勿增删——与三处展示层口径保持一致）
  '目录', '目录尾', '前言', '序', '序言',
  '附录', '附录一', '附录二', '附录三',
  // 真机实测 17 项
  '封面页', '封面', '封页', '封底页', '书名页', '书名', '版权页',
  '编委名单', '新形态教材使用说明', '教材修订说明', '主审简介',
  '主编简介', '副主编简介', '推荐阅读', '参考文献', '索引',
  '中英文名词对照索引',
};

/// 救援门计数口径：「第X章」才算章（「篇」「节」不算）。
final RegExp _chapterNoRe = RegExp(r'^第[一二三四五六七八九十百零两]+章');

/// 真章判定（救援采纳口径）：第X章/第X篇 编号，或恰为「绪论」。
final RegExp _realChapterRe = RegExp(r'^第[一二三四五六七八九十百零两]+[章篇]');

/// 「第X篇」级条目（chapters 路径剔除：不是可学章）。
final RegExp _partRe = RegExp(r'^第[一二三四五六七八九十百零两]+篇');

/// toc sidecar → 罗盘章节列表（唯一口径；契约见文件头）。
///
/// 输入为 sidecar 原始 Map（只读）；输出条目均为新 Map（与输入无共享引用）：
/// 过滤路径原样携带输入条目的全部字段（仅 title 换归一形态、no 保留原值）；
/// 救援路径仅产 {no, title, page_start}。
List<Map<String, Object?>> effectiveTocChapters(Map<String, Object?> sidecar) {
  final raw = sidecar['chapters'];
  if (raw is! List) {
    return const <Map<String, Object?>>[];
  }
  // 预检：条目形态异常（非 Map / 缺 String title）→ 整体退化原样返回。
  for (final e in raw) {
    if (e is! Map || e['title'] is! String) {
      return _asIs(raw);
    }
  }
  final sections = sidecar['sections'];
  if (sections is! List) {
    return _asIs(raw); // 空防御：sections 无法判读时不冒险变换
  }
  for (final s in sections) {
    if (s is! Map || s['title'] is! String) {
      return _asIs(raw);
    }
  }

  // 救援门：chapters 真章 < 2 且 sections 真章 ≥ 3 → sections 真章接管。
  var chaptersReal = 0;
  for (final e in raw) {
    if (_chapterNoRe.hasMatch(_key(e as Map))) {
      chaptersReal += 1;
    }
  }
  var sectionsReal = 0;
  for (final s in sections) {
    if (_chapterNoRe.hasMatch(_key(s as Map))) {
      sectionsReal += 1;
    }
  }
  if (chaptersReal < 2 && sectionsReal >= 3) {
    final out = <Map<String, Object?>>[];
    for (final s0 in sections) {
      final s = s0 as Map;
      if (!_isRealChapter(_key(s))) {
        continue; // 节级（一、/第X节）不误采纳——只收真章
      }
      out.add(<String, Object?>{
        'no': out.length + 1, // 重编 1..N 连续（丢 chapter_no）
        'title': _cleanTitle(s),
        if (s.containsKey('page_start')) 'page_start': s['page_start'],
      });
    }
    return out;
  }

  // 过滤路径：幸存条目保留原 no（稀疏编号，不重编）。
  final out = <Map<String, Object?>>[];
  for (final e0 in raw) {
    final e = e0 as Map;
    final key = _key(e);
    if (kTocJunkExact.contains(key)) continue; // (a) 精确垃圾
    if (key.startsWith('附录') || key.startsWith('附表')) continue; // (b) 前缀
    if (_partRe.hasMatch(key)) continue; // (c) 篇级
    final m = Map<String, Object?>.from(e);
    m['title'] = _cleanTitle(e); // 归一：剥「 / 页码」尾 + trim（幂等）
    out.add(m);
  }
  return out;
}

/// 比对键：去页码尾 + 去全部空白（run_engine.normChapterTitle 复用口径，
/// 含全角空格——derm「第一章　皮肤性病学导论」）。
String _key(Map e) => normChapterTitle(e['title'] as String?);

/// 输出 title：剥「 / 页码」尾 + trim（内部空白保留——含全角空格）。
String _cleanTitle(Map e) => stripChapterPageSuffix(e['title'] as String?);

/// 真章判定（救援采纳口径）：第X章/第X篇 或 「绪论」。
bool _isRealChapter(String key) =>
    _realChapterRe.hasMatch(key) || key == '绪论';

/// 空防御退化：chapters 原样返回（浅拷条目，不过滤/不归一/不重编；非 Map
/// 条目无法装入返回类型，静默丢弃——sidecar 生成端不产此类条目）。
List<Map<String, Object?>> _asIs(List raw) => [
      for (final e in raw)
        if (e is Map) Map<String, Object?>.from(e),
    ];
