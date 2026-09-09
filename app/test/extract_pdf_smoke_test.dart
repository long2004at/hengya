// 恒牙（hengya）· Phase 3b · extract_pdf Dart 移植冒烟测试
// ============================================================================
//
// 验收口径（PDF 跨引擎不可 byte-equal，见 extract_pdf.dart 文件头）：
//   1. 分块算法纯函数 1:1——anatomy 夹具与 Python self_test 同输入同断言
//      （语义分块核心：层级递归/孤儿章/防参考文献防小数守卫/裸节名
//      吸收/HARD 兜底/行级页源/内容守恒/短块双归并/sidecar 大纲）；
//   2. 真实 PDF 冒烟：2023 助理真题（exam 按页 19 chunks 金样）——
//      元数据硬对拍 + 结构断言 + 差异度探针打印。2026-09-06 实测：pdfium
//      分段矩形三件套行结构下 exam 19 块与 PyMuPDF 金样**逐字节一致**
//      （text 全等 19/19）→ 升级为与 pptx/docx 同款 byte-equal 硬门
//      （golden_md5/bytes 守门 + 序列化逐字节比对）。教材类（endo）跨
//      引擎分段粒度差异为系统性（差异度数字见交付报告）；硬门仅 exam。

import 'dart:convert';
import 'dart:io';

import 'package:hengya/services/local/corpus/extract_docx.dart'
    show splitParagraphs;
import 'package:hengya/services/local/corpus/extract_pdf.dart';
import 'package:hengya/services/local/corpus/extract_pptx.dart'
    show chunksToJsonl;
import 'package:hengya/services/local/corpus/pdfium_ffi.dart';
import 'package:hengya/services/local/corpus/py_compat.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

/// chunks.jsonl 契约字段序（make_golden.py 金样字段序）。
const chunksFieldOrder = [
  'chunk_id',
  'subject_id',
  'ppt_id',
  'deck',
  'page_start',
  'page_end',
  'title',
  'text',
  'source_type',
  'file_date',
];

/// Python self_test 同款行生成器：`"%s-%03d %s" % (tag, i, "z"*width)`。
List<String> rep(String tag, int n, [int width = 70]) => [
      for (var i = 0; i < n; i++)
        '$tag-${i.toString().padLeft(3, '0')} ${'z' * width}',
    ];

void main() {
  group('extract_pdf：纯函数规则', () {
    test('headingLevel：四级模式 + L4 防小数/防句读守卫', () {
      expect(headingLevel('第一节 龋病'), 1);
      expect(headingLevel('第一百零一节'), 1); // 含"零"的 L1
      expect(headingLevel('一、龋病的病因'), 2);
      expect(headingLevel('十、治疗计划'), 2);
      expect(headingLevel('（一）微生物学说'), 3);
      expect(headingLevel('(二)四联因素'), 3); // 半角括号
      expect(headingLevel('1.浅龋'), 4);
      expect(headingLevel('12．深龋'), 4); // 全角句点
      expect(headingLevel('1、中龋'), 4); // 顿号
      expect(headingLevel('1.5度龋深浅'), 0); // \d[.]\d 小数形态
      expect(headingLevel('28.9%的患龋率'), 0); // 小数守卫
      expect(
          headingLevel('1.周学东，唐洁，谭静．口腔医学史．北京：人民卫生出版社，2013.'),
          0); // 句读守卫（实测 endo 参考文献行全滤）
      expect(headingLevel('正文普通行，无标题特征'), 0);
    });

    test('headingPathElem：裸节名吸收下一行（仅标题路径）', () {
      expect(
        headingPathElem(<(int, String)>[(1, '第二节'), (1, '窝洞的分类与结构')], 0),
        '第二节 窝洞的分类与结构',
      );
      // 守卫：下一行含句读不吸收
      expect(
        headingPathElem(<(int, String)>[(1, '第三节'), (1, '垫底：保护牙髓')], 0),
        '第三节',
      );
      // 守卫：下一行本身是标题行不吸收
      expect(
        headingPathElem(<(int, String)>[(1, '第四节'), (1, '一、垫底材料')], 0),
        '第四节',
      );
      // 守卫：下一行超 40 码点不吸收
      expect(
        headingPathElem(<(int, String)>[(1, '第七十一节'), (1, 'y' * 41)], 0),
        '第七十一节',
      );
      // 非裸节名（带正文后缀）不吸收
      expect(
        headingPathElem(<(int, String)>[(1, '第六节 盖髓术'), (1, '任意行')], 0),
        '第六节 盖髓术',
      );
      // 尾行无下一行：原样返回
      expect(headingPathElem(<(int, String)>[(1, '第一节')], 0), '第一节');
    });

    test('composeTitle：路径首部与单元题重复段折叠', () {
      expect(composeTitle('第二章 X·第一节 Y', ['第一节 Y', '一、Z']),
          '第二章 X·第一节 Y·一、Z');
      expect(composeTitle('第一篇 龋病学·第二章 病因', ['第一节 定义', '一、特征']),
          '第一篇 龋病学·第二章 病因·第一节 定义·一、特征');
      expect(composeTitle('章名', []), '章名');
      expect(composeTitle('A·B', ['B', 'B', 'C']), 'A·B·C');
    });

    test('clampPage：页码钳制 [1, max(pageCount,1)]', () {
      expect(clampPage(1, 10), 1);
      expect(clampPage(0, 10), 1); // 无效 dest → 0 → 按 1
      expect(clampPage(-5, 10), 1);
      expect(clampPage(11, 10), 10);
      expect(clampPage(5, 0), 1);
    });

    test('blocksByPage：1 块/页、空页跳过、title 前缀', () {
      final blocks = blocksByPage(['a', '', 'b c'], 'deck');
      expect(blocks.length, 2);
      expect(blocks[0].title, 'deck p1');
      expect(blocks[0].pageStart, 1);
      expect(blocks[1].title, 'deck p3');
      expect(blocks[1].pageStart, 3);
      expect(blocks[1].pageEnd, 3);
    });
  });

  group('extract_pdf：语义分块（复刻 Python self_test 断言）', () {
    test('短节并前块：page_end 扩展 + 「章名·节名」单元题', () {
      final pages = [
        rep('SEC1', 12), // p1 长节
        ['SHORT-SECTION-MARKER alpha tiny', 'second short line'], // p2 短节
        rep('SEC3', 12), // p3 长节
      ];
      final toc = [
        const TocEntry(1, 'Chapter One Intro', 1),
        const TocEntry(2, 'Section One Basics', 1),
        const TocEntry(2, 'Section Two Short', 2),
        const TocEntry(1, 'Chapter Two Deep', 3),
        const TocEntry(2, 'Section Three Caries', 3),
      ];
      final units = textbookUnits(toc, 3);
      expect(units.length, 3); // 两个 L2 节 + Section Three；章非孤儿不入
      final blocks = blocksFromUnits(pages, units);
      expect(blocks.length, 2); // 短节并入前块
      expect(blocks[0].pageStart, 1);
      expect(blocks[0].pageEnd, 2); // page_end 扩展
      expect(blocks[0].text.contains('SHORT-SECTION-MARKER'), isTrue);
      expect(blocks[0].title, contains('Chapter One Intro'));
      expect(blocks[0].title, contains('Section One Basics'));
      expect(blocks[1].pageStart, 3); // 单页节 → p3（无区间后缀形态）
      // sidecar 大纲（建库侧消费，结构对齐 extract_docx）
      final outline = sidecarOutline(toc, 3);
      expect(outline.chapters.length, 2);
      expect(
        [for (final c in outline.chapters) (c.no, c.pageStart)],
        [(1, 1), (2, 3)],
      );
      expect(
        [for (final s in outline.sections) (s.chapterNo, s.title)],
        [
          (1, 'Section One Basics'),
          (1, 'Section Two Short'),
          (2, 'Section Three Caries'),
        ],
      );
    });

    test('anatomy 夹具：层级递归/孤儿章/守卫/行级页源/内容守恒', () {
      // Python self_test 同款 4 页夹具（width=38 压行长）
      final b2Pages = <List<String>>[
        ['第一节', '下颌骨解剖总览', '一、结构组成', ...rep('AA', 12, 38)],
        [
          '（一）分组一',
          ...rep('BB', 30, 38),
          '1.内容甲',
          ...rep('CC', 8, 38),
          '28.9%',
          '1.周学东，唐洁，谭静．口腔医学史．北京：人民卫生出版社，2013.',
          '二、结构功能',
          ...rep('DD', 10, 38),
        ],
        rep('ORPH', 58, 38),
        rep('TOC', 5, 38),
      ];
      final toc = [
        const TocEntry(1, '第一章 头章', 1),
        const TocEntry(2, '第一节 混合结构', 1),
        const TocEntry(1, '第二章 尾章', 3),
        const TocEntry(1, '目录', 4),
      ];

      final units = textbookUnits(toc, 4);
      // 单元 = 第一节 混合结构(1..2) ∪ 孤儿章第二章(3..3)；「目录」被过滤
      expect(units.length, 2);
      expect(units[0].title, '第一章 头章·第一节 混合结构');
      expect(units[0].pageStart, 1);
      expect(units[0].pageEnd, 2); // 边界 = 第二章起始页-1
      expect(units[1].title, '第二章 尾章');
      expect(units[1].pageStart, 3);
      expect(units[1].pageEnd, 3); // 边界=目录书签（level 1 ≤ cap 2）起始页-1；目录页不入任何单元
      // 无 TOC 行入库（非正文孤儿章过滤）
      final blocks = blocksFromUnits(b2Pages, units);
      expect(blocks.any((b) => b.text.contains('TOC-')), isFalse);

      // 合并块序（首短块「第一节/下颌骨解剖总览」并入后块）→ 5 块，
      // 孤儿章 >1600 走段落兜底拆 2 件 → 共 6 chunks（Python 断言口径）
      expect(blocks.length, 5);
      final b1 = blocks[0];
      expect(b1.title, '第一章 头章·第一节 混合结构·一、结构组成');
      expect((b1.pageStart, b1.pageEnd), (1, 1)); // 行级页源：单页块
      expect(b1.text.contains('下颌骨解剖总览'), isTrue); // 首短块并入后块
      final b2 = blocks[1];
      expect(b2.title.endsWith('（一）分组一'), isTrue); // L3 无界不切（（一）组整块）
      expect(b2.text.contains('BB-029'), isTrue);
      expect(b2.text.contains('AA-011'), isFalse); // 不含上组内容
      final b3 = blocks[2];
      expect(b3.title, '第一章 头章·第一节 混合结构·一、结构组成·（一）分组一·1.内容甲');
      expect(b3.text.contains('28.9%'), isTrue); // 防小数守卫：不切块
      expect(b3.text.contains('周学东'), isTrue); // 防参考文献守卫：不切块
      final b4 = blocks[3];
      expect(b4.title.endsWith('二、结构功能'), isTrue);
      expect((b4.pageStart, b4.pageEnd), (2, 2));
      final b5 = blocks[4];
      expect(b5.title, '第二章 尾章'); // 孤儿章入库（无 L2 子女）
      expect(b5.title.contains('·'), isFalse); // 孤儿章无行内标题路径
      expect(b5.text.runes.length, greaterThan(semanticSoftMax)); // >1600
      final parts = splitParagraphs(b5.text, semanticSoftMax); // HARD 兜底
      expect(parts.length, 2);
      expect(parts[1].contains('ORPH-033'), isTrue); // 1600 贪心拆分件
      // 内容守恒：块序拼接 == 单元文本（p1+p2+p3 全部行）
      expect(
        blocks.map((b) => b.text).join('\n'),
        [for (final pg in b2Pages.sublist(0, 3)) pg.join('\n')].join('\n'),
      );

      // sidecar：书签导出与单元过滤无关（chapters 含目录、sections 挂章）
      final outline = sidecarOutline(toc, 4);
      expect(outline.chapters.length, 3);
      expect(outline.sections.length, 1);
      expect(
        [for (final c in outline.chapters) (c.no, c.title, c.pageStart)],
        [(1, '第一章 头章', 1), (2, '第二章 尾章', 3), (3, '目录', 4)],
      );
    });
  });

  test('真实 PDF 冒烟：2023 助理真题 exam 按页 + 差异度探针', () {
    // —— 金样契约（golden_manifest.json）——
    final manifestFile = File('test/fixtures/golden/golden_manifest.json');
    if (!manifestFile.existsSync()) {
      // skip-guard：公开仓库不含金样与私有语料（版权原因），本用例仅私有工作区生效
      // ignore: avoid_print
      print('SKIP: 金样 manifest 缺失（test/fixtures/golden/）');
      return;
    }
    final manifest =
        jsonDecode(manifestFile.readAsStringSync(encoding: utf8)) as Map<String, dynamic>;
    final g = (manifest['goldens']
            as Map<String, dynamic>)['exam_assistant2023_pdf_chunks.jsonl']
        as Map<String, dynamic>;
    expect(g['chunk_count'], 19);
    expect(g['golden_md5'], '57952b25d5088329ffe546ea51a18b18');
    expect(g['golden_bytes'], 43572);
    expect(g['source_md5'], '5c3eda561bef67ff74ef48f47382e4f8');
    expect(g['source_size'], 267080);
    expect(g['file_date'], '2026-05-12');
    expect(g['subject_id'], 'exam');
    expect(g['source_type'], 'exam');
    expect((manifest['chunks_fields'] as List<dynamic>).cast<String>(),
        chunksFieldOrder);

    // —— 源文件身份（大小 + md5）——
    const srcRel =
        '../content/ppt_raw/exam/试卷与模拟题/2023年口腔助理医师试题（网友回忆版）.pdf';
    final src = File(srcRel);
    expect(src.existsSync(), isTrue, reason: '源 PDF 缺失：$srcRel');
    expect(src.lengthSync(), g['source_size'], reason: '源 PDF 大小与 manifest 不符');
    expect(md5File(src.path), g['source_md5'],
        reason: '源 PDF md5 与 manifest 不符（源文件已被替换？）');

    // —— Dart 抽取（pdfium）——
    final res = extractPdfFile(src.path, subjectId: 'exam', sourceType: 'exam');
    final chunks = res.chunks;

    // 元数据硬对拍（跨引擎一致：file_date=creationDate、md5、科目口径）
    expect(res.deckInfo.fileDate, g['file_date'],
        reason: 'creationDate 解析不一致（pdfium GetMetaText vs PyMuPDF metadata）');
    expect(res.deckInfo.fileMd5, g['source_md5']);
    expect(res.deckInfo.subjectId, 'exam');
    expect(res.deckInfo.sourceType, 'exam');
    expect(res.deckInfo.deck, '2023年口腔助理医师试题（网友回忆版）');

    // 结构断言：按页块形态 + 字段序 + 页码范围
    expect(chunks, isNotEmpty);
    for (final c in chunks) {
      expect(c.chunkId,
          matches(RegExp(r'^exam:2023年口腔助理医师试题（网友回忆版）:p\d+(-s\d+)?$')));
      expect(
          c.title, matches(RegExp(r'^2023年口腔助理医师试题（网友回忆版） p\d+$')));
      expect(c.pageStart, greaterThanOrEqualTo(1));
      expect(c.pageEnd, greaterThanOrEqualTo(c.pageStart));
      expect(c.text, isNotEmpty);
      expect(c.toOrderedMap().keys.toList(), chunksFieldOrder);
    }

    // —— 差异度探针：与 Python 金样（PyMuPDF）的 chunk_id/文本差异 ——
    final goldenBytes = File(
      'test/fixtures/golden/exam_assistant2023_pdf_chunks.jsonl',
    ).readAsBytesSync();
    final goldenNorm = utf8.decode(goldenBytes).replaceAll('\r\n', '\n');
    final golden = <String, Map<String, dynamic>>{};
    for (final l in goldenNorm.split('\n').where((x) => x.isNotEmpty)) {
      final row = jsonDecode(l) as Map<String, dynamic>;
      golden[row['chunk_id'] as String] = row;
    }
    final dartById = {for (final c in chunks) c.chunkId: c};
    final inter = dartById.keys.toSet().intersection(golden.keys.toSet());
    var textEq = 0;
    var charSame = 0;
    var charGold = 0;
    for (final id in inter) {
      final dText = dartById[id]!.text;
      final gText = golden[id]!['text'] as String;
      if (dText == gText) textEq++;
      charSame += dText.runes.where((r) => gText.runes.contains(r)).length;
      charGold += gText.runes.length;
    }
    // ignore: avoid_print
    print('[差异度探针] Python 金样 ${golden.length} chunks vs Dart(pdfium) '
        '${chunks.length} chunks | chunk_id 交集 ${inter.length}/${golden.length} '
        '| text 全等 $textEq | 交集块字符重合 $charSame/$charGold');
    // 守门（2026-09-06 实测后收紧）：按页切块 chunk_id 全交集 + text 全等
    expect(inter.length, golden.length,
        reason: '跨引擎按页切块 chunk_id 应全交集（页码/拆分阈值一致）');
    expect(textEq, golden.length,
        reason: 'exam 文档类实测可达 byte-equal（三件套行结构）；'
            '回退须先查行结构/引擎版本变更');

    // —— 字节级硬门（与 pptx/docx 同款；19/19 全等实测后固化）——
    final dartJsonl = chunksToJsonl(chunks);
    final dartBytes = utf8.encode(dartJsonl);
    expect(dartBytes.length, g['golden_bytes'],
        reason: 'Dart 序列化字节数 ${dartBytes.length} ≠ '
            'golden_bytes ${g['golden_bytes']}');
    expect(md5.convert(dartBytes).toString(), g['golden_md5'],
        reason: 'Dart 序列化 md5 ≠ golden_md5（行结构/转义/行尾差异）');
    expect(dartJsonl, goldenNorm,
        reason: 'Dart 序列化与盘上金样（CRLF→LF 归一）逐字节不一致');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
