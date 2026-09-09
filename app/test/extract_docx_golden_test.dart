// 恒牙（hengya）· Phase 3b · extract_docx Dart 移植金样对拍
// ============================================================================
//
// 对拍契约（golden_manifest.json → assistant_syllabus_docx_chunks.jsonl）：
//   源  ../content/ppt_raw/exam/大纲与考纲/6-口腔执业助理医师资格考试大纲.docx
//   （121,954B / md5 f5653a41…）
//   金样 19 chunks / 99,878B（LF 规范文本）/ golden_md5 0179ad1c…
//
// 三层验证（同 extract_pptx_golden_test.dart 范式）：
//   1. 逐字段（19 行 × 10 字段，含字段序）；
//   2. 字节级：Dart 序列化（py_compat Python 风格 jsonl）字节数与 md5
//      == manifest golden_bytes/golden_md5 —— 转义/分隔符/行尾一锤定音；
//   3. 与盘上金样逐字节比对（盘上为 Python Windows 文本模式写出的
//      CRLF，manifest 口径为 LF 规范文本，故先 CRLF→LF 归一）。
//
// 注：金样守门断言锁定当前基线；若金样确实更新（golden_md5 变化），
// 本测试会在守门断言处红——按新 manifest 修正守门常量并先核对 Dart
// 实现语义再放行。

import 'dart:convert';
import 'dart:io';

import 'package:hengya/services/local/corpus/extract_docx.dart';
import 'package:hengya/services/local/corpus/extract_pptx.dart';
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

/// 断言失败时截断长值，避免刷屏。
String _snip(Object? v) {
  final s = v.toString();
  return s.length > 80 ? '${s.substring(0, 80)}…(共${s.length}字符)' : s;
}

void main() {
  group('extract_docx：纯函数规则', () {
    test('splitParagraphs：贪心装行/超长硬切/码点切', () {
      expect(splitParagraphs('', 100), isEmpty);
      // 贪心装行：'a\nb\nc' limit 3 → ['a\nb', 'c']（grow 含与前段的换行）
      expect(splitParagraphs('a\nb\nc', 3), ['a\nb', 'c']);
      // 超长单行硬切（BMP 快路径）：不丢内容、每段 ≤limit
      final huge = 'y' * (examPackChars + 1000);
      final parts = splitParagraphs(huge, examPackChars);
      expect(parts.length, greaterThanOrEqualTo(2));
      expect(parts.join(''), huge); // 硬切段无分隔拼接还原
      for (final p in parts) {
        expect(p.runes.length, lessThanOrEqualTo(examPackChars));
      }
      // 含代理对（emoji）：按**码点**硬切，不拆半个字符（10 码点 → 4+4+2；
      // 若误用 UTF-16 .length 会切成 5 段）
      expect(splitParagraphs('😀' * 10, 4), ['😀😀😀😀', '😀😀😀😀', '😀😀']);
      // 正常路径（无硬切）join('\n') 逐字还原
      expect(splitParagraphs('ab\ncd\nef', 10).join('\n'), 'ab\ncd\nef');
    });

    test('joinTitle：章·节三态', () {
      expect(joinTitle('章', '节'), '章·节');
      expect(joinTitle('', '节'), '节');
      expect(joinTitle('章', ''), '章');
      expect(joinTitle('', ''), '');
    });
  });

  test('金样对拍：考纲 docx 19 chunks 逐字段 100% 一致', () {
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
            as Map<String, dynamic>)['assistant_syllabus_docx_chunks.jsonl']
        as Map<String, dynamic>;
    // 守门：金样须仍为当前基线（chunk 数/md5/字节），变更需先核 Dart 语义
    expect(g['chunk_count'], 19,
        reason: '考纲 docx 金样 chunk 数已变更——先核对实现语义再更新守门常量');
    expect(g['golden_md5'], '0179ad1c4dd2feaae463ed74c03228be',
        reason: '考纲 docx 金样 md5 已变更——以新金样重核 Dart 语义后更新守门常量');
    expect(g['golden_bytes'], 99878);
    expect(g['source_md5'], 'f5653a413b83cfb08dfa3f48fca2e105');
    expect(g['source_size'], 121954);
    expect(g['file_date'], '2026-09-05');
    expect(g['subject_id'], 'exam');
    expect(g['source_type'], 'exam');
    expect((manifest['chunks_fields'] as List<dynamic>).cast<String>(),
        chunksFieldOrder);

    // —— 源文件身份（大小 + md5）——
    const srcRel =
        '../content/ppt_raw/exam/大纲与考纲/6-口腔执业助理医师资格考试大纲.docx';
    final src = File(srcRel);
    expect(src.existsSync(), isTrue, reason: '源 docx 缺失：$srcRel');
    expect(src.lengthSync(), g['source_size'], reason: '源 docx 大小与 manifest 不符');
    expect(md5File(src.path), g['source_md5'],
        reason: '源 docx md5 与 manifest 不符（源文件已被替换？）');

    // —— Dart 抽取 ——
    final sw = Stopwatch()..start();
    final res = extractDocxFile(src.path, subjectId: 'exam', sourceType: 'exam');
    sw.stop();
    expect(sw.elapsedMicroseconds, greaterThan(0));

    // deck_info
    final deckInfo = res.deckInfo;
    final chunks = res.chunks;
    expect(deckInfo.subjectId, 'exam');
    expect(deckInfo.sourceType, 'exam');
    expect(deckInfo.deck, '6-口腔执业助理医师资格考试大纲');
    expect(deckInfo.pptId, deckInfo.deck);
    expect(deckInfo.fileDate, g['file_date'], reason: 'dcterms:created 日期解析不一致');
    expect(deckInfo.fileSize, g['source_size']);
    expect(deckInfo.fileMd5, g['source_md5']);

    expect(chunks.length, g['chunk_count'],
        reason: 'chunk 总数 ${chunks.length} ≠ 金样 ${g['chunk_count']}');

    // —— 金样 jsonl 逐行逐字段（19 × 10 断言）——
    final goldenBytes = File(
      'test/fixtures/golden/assistant_syllabus_docx_chunks.jsonl',
    ).readAsBytesSync();
    // 盘上金样为 Python Windows 文本模式写出（CRLF）；manifest 口径为
    // LF 规范文本 → CRLF→LF 归一后对拍
    final goldenNorm = utf8.decode(goldenBytes).replaceAll('\r\n', '\n');
    final goldenLines = goldenNorm.split('\n').where((l) => l.isNotEmpty).toList();
    expect(goldenLines.length, chunks.length,
        reason: '金样行数 ${goldenLines.length} ≠ Dart chunk 数 ${chunks.length}');

    for (var idx = 0; idx < chunks.length; idx++) {
      final gold = jsonDecode(goldenLines[idx]) as Map<String, dynamic>;
      final dart = chunks[idx].toOrderedMap();
      expect(dart.keys.toList(), chunksFieldOrder, reason: 'chunk[$idx] 字段序不符');
      expect(gold.keys.toList(), chunksFieldOrder,
          reason: '金样行[$idx] 字段序不符（金样被改动？）');
      for (final field in chunksFieldOrder) {
        expect(
          dart[field],
          gold[field],
          reason: 'chunk[$idx].$field 不一致\n'
              '  dart  : ${_snip(dart[field])}\n'
              '  golden: ${_snip(gold[field])}',
        );
      }
    }

    // —— 字节级：Dart 序列化 == 金样规范文本（转义+分隔符+行尾一锤定音）——
    final dartJsonl = chunksToJsonl(chunks);
    final dartBytes = utf8.encode(dartJsonl);
    expect(dartBytes.length, g['golden_bytes'],
        reason:
            'Dart 序列化字节数 ${dartBytes.length} ≠ golden_bytes ${g['golden_bytes']}');
    expect(md5.convert(dartBytes).toString(), g['golden_md5'],
        reason: 'Dart 序列化 md5 ≠ golden_md5（转义/分隔符/行尾存在差异）');
    expect(dartJsonl, goldenNorm,
        reason: 'Dart 序列化与盘上金样（CRLF→LF 归一）逐字节不一致');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
