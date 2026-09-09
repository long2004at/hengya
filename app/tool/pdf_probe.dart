// 恒牙（hengya）· Phase 3b · PDF 跨引擎差异度探针（一次性实测 / 自金样再生成）
// ============================================================================
//
// 用法（cwd=app/；pdfium.dll 解析路径 test/fixtures/pdfium/win-x64/，见
// pdfium_ffi.dart 平台加载节）：
//   dart run tool/pdf_probe.dart diff <pdf> <golden.jsonl> [subjectId] [sourceType]
//   dart run tool/pdf_probe.dart golden <pdf> <out.jsonl> [subjectId] [sourceType]
//
// diff：Dart(pdfium) 抽取 vs Python(PyMuPDF) 金样 —— chunk_id 交集、text
//   全等、空白折叠/去空白归一全等、字符重合、行数、file_date、前 2 个差异
//   块样本。PDF 跨引擎不可 byte-equal（验收口径见 extract_pdf.dart 文件头）；
//   本探针输出即「与 Python 金样差异度实测报告」的数字交付。
// golden：抽取结果按 make_golden.py 契约（chunksToJsonl：LF 行尾、末行 \n、
//   Python 风格转义）写出自金样文件，打印 bytes/md5 供测试守门常量。

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:hengya/services/local/corpus/extract_pdf.dart';
import 'package:hengya/services/local/corpus/extract_pptx.dart'
    show chunksToJsonl;
import 'package:crypto/crypto.dart';

String _esc(String s) => s.replaceAll('\n', '⏎').replaceAll('\r', '⇠');

void main(List<String> argv) {
  if (argv.length < 3 || (argv[0] != 'diff' && argv[0] != 'golden')) {
    stderr.writeln('用法：dart run tool/pdf_probe.dart diff|golden '
        '<pdf> <jsonl> [subjectId] [sourceType]');
    exitCode = 2;
    return;
  }
  final mode = argv[0];
  final pdfPath = argv[1];
  final jsonlPath = argv[2];
  final subjectId = argv.length > 3 ? argv[3] : null;
  final sourceType = argv.length > 4 ? argv[4] : null;

  final sw = Stopwatch()..start();
  final res = extractPdfFile(pdfPath, subjectId: subjectId, sourceType: sourceType);
  sw.stop();
  final chunks = res.chunks;
  stdout.writeln('[probe] ${res.deckInfo.subjectId}/${res.deckInfo.sourceType} '
      'deck=${res.deckInfo.deck}');
  stdout.writeln('[probe] chunks=${chunks.length} '
      'file_date=${res.deckInfo.fileDate} file_md5=${res.deckInfo.fileMd5} '
      '提取耗时=${sw.elapsedMilliseconds}ms');

  if (mode == 'golden') {
    final bytes = utf8.encode(chunksToJsonl(chunks));
    File(jsonlPath).writeAsBytesSync(bytes, flush: true);
    stdout.writeln('[golden] 写出 $jsonlPath');
    stdout.writeln('[golden] bytes=${bytes.length} md5=${md5.convert(bytes)}');
    return;
  }

  // ---- diff 模式 ----
  final goldenNorm =
      utf8.decode(File(jsonlPath).readAsBytesSync()).replaceAll('\r\n', '\n');
  final golden = <String, Map<String, dynamic>>{};
  for (final l in goldenNorm.split('\n').where((x) => x.isNotEmpty)) {
    final row = jsonDecode(l) as Map<String, dynamic>;
    golden[row['chunk_id'] as String] = row;
  }
  final dartById = {for (final c in chunks) c.chunkId: c};
  final inter = dartById.keys.toSet().intersection(golden.keys.toSet()).toList()
    ..sort();
  var textEq = 0, wsEq = 0, stripEq = 0;
  var charSame = 0, charGold = 0, charDart = 0;
  var linesDart = 0, linesGold = 0;
  final wsRun = RegExp(r'\s+');
  final anyWs = RegExp(r'\s');
  for (final id in inter) {
    final d = dartById[id]!.text;
    final g = golden[id]!['text'] as String;
    final gSet = g.runes.toSet();
    if (d == g) textEq++;
    if (d.replaceAll(wsRun, ' ').trim() == g.replaceAll(wsRun, ' ').trim()) {
      wsEq++;
    }
    if (d.replaceAll(anyWs, '') == g.replaceAll(anyWs, '')) stripEq++;
    charSame += d.runes.where(gSet.contains).length;
    charGold += g.runes.length;
    charDart += d.runes.length;
    linesDart += '\n'.allMatches(d).length + 1;
    linesGold += '\n'.allMatches(g).length + 1;
  }
  stdout.writeln('[diff] golden=${golden.length} chunks vs dart=${chunks.length} '
      'chunks | chunk_id 交集=${inter.length}/${golden.length}');
  stdout.writeln('[diff] text 全等=$textEq | 空白折叠全等=$wsEq | '
      '去空白全等=$stripEq（交集 ${inter.length} 块口径）');
  stdout.writeln('[diff] 交集块字符重合=$charSame/$charGold'
      '（dart rune 总数=$charDart） | 行数 dart=$linesDart gold=$linesGold');
  if (golden.isNotEmpty) {
    stdout.writeln('[diff] file_date gold=${golden.values.first['file_date']} '
        'dart=${res.deckInfo.fileDate}');
  }
  var shown = 0;
  for (final id in inter) {
    if (shown >= 2) break;
    final d = dartById[id]!.text;
    final g = golden[id]!['text'] as String;
    if (d == g) continue;
    shown++;
    stdout.writeln('[sample] $id');
    stdout.writeln(
        '  dart: ${_esc(d.substring(0, math.min(120, d.length)))}');
    stdout.writeln(
        '  gold: ${_esc(g.substring(0, math.min(120, g.length)))}');
  }
}
