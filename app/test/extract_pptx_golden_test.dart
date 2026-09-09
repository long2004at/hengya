// 恒牙（hengya）· Phase 3a · extract_pptx Dart 移植金样对拍
// ============================================================================
//
// 对拍契约（golden_manifest.json → oms_ch2_pptx_chunks.jsonl）：
//   源  ../content/ppt_raw/oms/(2.1.2)--第二章口腔颌面外科基本操作与基础知识 (1).pptx
//   （20,845,733B / md5 60b35dff…，161 页，8 notesSlides）
//   金样 92 chunks / 66,403B（LF 规范文本）/ golden_md5 b884a9d1…
//
// 三层验证：
//   1. 逐字段（92 行 × 10 字段 = 920 断言，含字段序）；
//   2. 字节级：Dart 序列化（py_compat Python 风格 jsonl）字节数与 md5
//      == manifest golden_bytes/golden_md5 —— 转义/分隔符/行尾一锤定音；
//   3. 与盘上金样逐字节比对（盘上为 Python Windows 文本模式写出的 CRLF，
//      manifest 口径为 LF 规范文本，故先 CRLF→LF 归一）。
//
// 注：金样守门断言锁定语义分块前基线（PPT 页=天然语义单元，预期未变更）；
// 若金样确实更新（golden_md5 变化），本测试会在守门断言处红——按新 manifest
// 修正守门常量并先核对 Dart 实现语义再放行。

import 'dart:convert';
import 'dart:io';

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
  group('py_compat：Python 标准库语义等价（探针对拍常量）', () {
    test('pyStrip：Python str.strip() 空白集', () {
      expect(pyStrip('  a b  '), 'a b'); // 中间空白保留
      expect(pyStrip('\x1c好\x1f'), '好'); // \x1c-\x1f Python 剥、Dart trim 不剥
      expect(pyStrip('\ufeffa\ufeff'), '\ufeffa\ufeff'); // U+FEFF Python 不剥
      expect(pyStrip('\u00a0x\u2029'), 'x');
      expect(pyStrip(''), '');
    });

    test('posixNormpath：与 Python 3.12 实测一致', () {
      expect(posixNormpath('ppt/slides/../notesSlides/notesSlide1.xml'),
          'ppt/notesSlides/notesSlide1.xml');
      expect(posixNormpath('ppt/slides/../../x.xml'), 'x.xml');
      expect(posixNormpath('../x.xml'), '../x.xml');
      expect(posixNormpath(''), '.');
      expect(posixNormpath('.'), '.');
      expect(posixNormpath('/a/../b'), '/b');
      expect(posixNormpath('a//b'), 'a/b');
      expect(posixNormpath('a/./b/'), 'a/b');
    });

    test('resolveZipPart：rels 相对地址 → zip 部件名', () {
      expect(
        resolveZipPart('ppt/slides/slide1.xml', '../notesSlides/notesSlide1.xml'),
        'ppt/notesSlides/notesSlide1.xml',
      );
      expect(
        resolveZipPart('ppt/slides/slide2.xml', '../tags/tag467.xml'),
        'ppt/tags/tag467.xml',
      );
      expect(posixJoin(['ppt/slides', '_rels', 'slide1.xml.rels']),
          'ppt/slides/_rels/slide1.xml.rels');
    });

    test('pyPathStem/pyPathParentName：Windows pathlib 规则', () {
      expect(pyPathStem('(2.1.2)--第二章 (1).pptx'), '(2.1.2)--第二章 (1)');
      expect(pyPathStem('x.'), 'x.'); // 尾部点名：pathlib 不视为后缀
      expect(pyPathStem('.bashrc'), '.bashrc');
      expect(pyPathStem('a.b.pptx'), 'a.b');
      expect(pyPathStem('plain'), 'plain');
      expect(pyPathStem('D:/a/b/deck.pptx'), 'deck');
      expect(pyPathName('D:\\a\\b\\deck.pptx'), 'deck.pptx');
      expect(pyPathParentName('D:/a/b/x.pptx'), 'b');
      expect(pyPathParentName('x.pptx'), '');
      expect(pyPathParentName('D:/x.pptx'), ''); // 盘根 parent.name == ""
    });

    test('pyDateFromIso：fromisoformat 常用形态与越界', () {
      expect(pyDateFromIso('2025-09-16'), '2025-09-16');
      expect(pyDateFromIso('2025-09-16T12:11:00+00:00'), '2025-09-16'); // created 原串 Z 已替换
      expect(pyDateFromIso('2025-09-16T14:51:01'), '2025-09-16');
      expect(pyDateFromIso('2025-09-16 14:51:01'), '2025-09-16');
      expect(pyDateFromIso('2025-09-16T14:51:01.123456+08:00'), '2025-09-16');
      expect(pyDateFromIso('20250916T145101'), '2025-09-16'); // 基本格式
      expect(pyDateFromIso('2024-02-29'), '2024-02-29');
      expect(pyDateFromIso('2025-02-30'), isNull);
      expect(pyDateFromIso('2025-02-29'), isNull); // 平年
      expect(pyDateFromIso('2025-13-01'), isNull);
      expect(pyDateFromIso('2025-09-16T24:00:00'), isNull);
      expect(pyDateFromIso('2025-09-16T14:51:60'), isNull);
      expect(pyDateFromIso('2025-09-16T'), isNull);
      expect(pyDateFromIso('bogus'), isNull);
    });

    test('pyJsonDumps/serializeChunksJsonl：json.dumps(ensure_ascii=False) 风格', () {
      expect(pyJsonDumps(<String, Object?>{'k': 'v', 'n': 1}), '{"k": "v", "n": 1}');
      expect(pyJsonDumps(<String, Object?>{'z': null, 'b': true}), '{"z": null, "b": true}');
      expect(
        pyJsonDumps(<String, Object?>{'t': 'a"b\\c\nd\te\x01f中“文”'}),
        r'{"t": "a\"b\\c\nd\te\u0001f中“文”"}',
      );
      expect(
        pyJsonDumps(<String, Object?>{'d': String.fromCharCode(0x7f)}),
        '{"d": "${String.fromCharCode(0x7f)}"}', // DEL 不转义（同 Python）
      );
      expect(
        serializeChunksJsonl([
          <String, Object?>{'a': 1},
          <String, Object?>{'b': 2},
        ]),
        '{"a": 1}\n{"b": 2}\n',
      );
      // 浮点不在 chunks.jsonl 契约内，pyJsonDumps 拒绝而非静默产出错误字节
      expect(() => pyJsonDumps(<String, Object?>{'f': 1.5}), throwsArgumentError);
    });
  });

  group('extract_pptx：纯函数规则', () {
    test('splitSubjectSource：目录名 → 科目/来源', () {
      expect(splitSubjectSource('oms'), (subject: 'oms', sourceType: 'ppt'));
      expect(splitSubjectSource('endo-textbook'),
          (subject: 'endo', sourceType: 'textbook'));
      expect(splitSubjectSource('oms-exam'), (subject: 'oms', sourceType: 'exam'));
      expect(splitSubjectSource('exam'), (subject: 'exam', sourceType: 'exam'));
      expect(splitSubjectSource(''), (subject: 'unknown', sourceType: 'ppt'));
      expect(splitSubjectSource(null), (subject: 'unknown', sourceType: 'ppt'));
      expect(splitSubjectSource('  oms  '), (subject: 'oms', sourceType: 'ppt'));
      // 小写匹配后缀、截取保留原大小写（Python 同）
      expect(splitSubjectSource('Endo-Textbook'),
          (subject: 'Endo', sourceType: 'textbook'));
      expect(splitSubjectSource('Exam'), (subject: 'exam', sourceType: 'exam'));
      expect(detectSourceType('xxx-exam'), 'exam');
      expect(detectSourceType(null), 'ppt');
    });

    test('chunkIdOf：单页/区间', () {
      expect(chunkIdOf('oms', 'deck', 3, 3), 'oms:deck:p3');
      expect(chunkIdOf('oms', 'deck', 1, 2), 'oms:deck:p1-2');
      expect(chunkIdOf('oms', 'deck', 1, 0), 'oms:deck:p1'); // end<start 不可能，仅固化行为
    });
  });

  test('金样对拍：oms 第二章 PPT 92 chunks 逐字段 100% 一致', () {
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
    final g = (manifest['goldens'] as Map<String, dynamic>)['oms_ch2_pptx_chunks.jsonl']
        as Map<String, dynamic>;
    // 守门：PPT 金样须仍为语义分块前基线（预期未变更，见 handoff）
    expect(g['chunk_count'], 92, reason: 'oms PPT 金样 chunk 数已变更——先核对语义分块节点 handoff');
    expect(g['golden_md5'], 'b884a9d18ed1fb4dbbc848a15d041de9',
        reason: 'oms PPT 金样 md5 已变更——以新金样重核 Dart 语义后更新守门常量');
    expect(g['golden_bytes'], 66403);
    expect(g['source_md5'], '60b35dffda63c69a25cffff9c3e8ec51');
    expect(g['source_size'], 20845733);
    expect(g['file_date'], '2025-09-16');
    expect(g['subject_id'], 'oms');
    expect(g['source_type'], 'ppt');
    expect((manifest['chunks_fields'] as List<dynamic>).cast<String>(), chunksFieldOrder);

    // —— 源文件身份（大小 + md5）——
    const srcRel =
        '../content/ppt_raw/oms/(2.1.2)--第二章口腔颌面外科基本操作与基础知识 (1).pptx';
    final src = File(srcRel);
    expect(src.existsSync(), isTrue, reason: '源 pptx 缺失：$srcRel');
    expect(src.lengthSync(), g['source_size'], reason: '源 pptx 大小与 manifest 不符');
    expect(md5File(src.path), g['source_md5'],
        reason: '源 pptx md5 与 manifest 不符（源文件已被替换？）');

    // —— Dart 抽取 ——
    final sw = Stopwatch()..start();
    final (deckInfo, chunks) = extractFile(src.path, subjectId: 'oms', sourceType: 'ppt');
    sw.stop();
    expect(sw.elapsedMicroseconds, greaterThan(0));

    // deck_info
    expect(deckInfo.subjectId, 'oms');
    expect(deckInfo.sourceType, 'ppt');
    expect(deckInfo.deck, '(2.1.2)--第二章口腔颌面外科基本操作与基础知识 (1)');
    expect(deckInfo.pptId, deckInfo.deck);
    expect(deckInfo.fileDate, g['file_date'], reason: 'dcterms:created 日期解析不一致');
    expect(deckInfo.fileSize, g['source_size']);
    expect(deckInfo.fileMd5, g['source_md5']);
    expect(deckInfo.filePath, src.path);

    expect(chunks.length, g['chunk_count'],
        reason: 'chunk 总数 ${chunks.length} ≠ 金样 ${g['chunk_count']}');

    // —— 金样 jsonl 逐行逐字段（920 断言）——
    final goldenBytes =
        File('test/fixtures/golden/oms_ch2_pptx_chunks.jsonl').readAsBytesSync();
    // 盘上金样为 Python Windows 文本模式写出（CRLF，66,495B=66,403+92）；
    // manifest 口径为 LF 规范文本 → CRLF→LF 归一后对拍
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
        reason: 'Dart 序列化字节数 ${dartBytes.length} ≠ golden_bytes ${g['golden_bytes']}');
    expect(md5.convert(dartBytes).toString(), g['golden_md5'],
        reason: 'Dart 序列化 md5 ≠ golden_md5（转义/分隔符/行尾存在差异）');
    expect(dartJsonl, goldenNorm,
        reason: 'Dart 序列化与盘上金样（CRLF→LF 归一）逐字节不一致');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
