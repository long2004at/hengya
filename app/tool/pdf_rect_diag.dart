// 恒牙（hengya）· Phase 3b · pdfium 行结构三件套诊断 v4（一次性）
// ============================================================================
//
// 用法（cwd=app/）：dart run tool/pdf_rect_diag.dart [pdf] [pageNo0]
//   默认跑 endo p100 + exam p1 双对照。
//
// v3 已定谳：三件套出正常阅读序行；GetBoundedText needed=内容字符数（不含
// NUL）、copied 含尾 NUL、buflen 按 UTF-16 单位计。覆盖率 0.947/0.891。
// v4 终验：未覆盖字符多重集对账——
//   流侧逐字符 GetUnicode + IsGenerated → 实字符/注入字符计数；
//   行侧 Σ(GetBoundedText) → 拼接文本；
//   对账：行侧缺失的「实字符」（内容丢失？）与行侧多出的字符（重复？），
//   若缺失≈0 且多出仅为注入空格 → 零内容损失，方案成立。

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

typedef FPDFDoc = Pointer<Void>;
typedef FPDFPage = Pointer<Void>;
typedef FPDFTextPage = Pointer<Void>;

void main(List<String> argv) {
  final endoPdf =
      '../content/ppt_raw/endo-textbook/牙体牙髓病学-第5版.pdf';
  final examPdf =
      '../content/ppt_raw/exam/试卷与模拟题/2023年口腔助理医师试题（网友回忆版）.pdf';
  final endoPage0 = argv.length > 1 ? int.parse(argv[1]) : 99;
  final examPage0 = argv.length > 2 ? int.parse(argv[2]) : 0;

  final lib = DynamicLibrary.open('test/fixtures/pdfium/win-x64/pdfium.dll');
  lib.lookupFunction<Void Function(), void Function()>('FPDF_InitLibrary')();
  final fLoadDoc = lib.lookupFunction<
      FPDFDoc Function(Pointer<Utf8>, Pointer<Void>),
      FPDFDoc Function(Pointer<Utf8>, Pointer<Void>)>('FPDF_LoadDocument');
  final fLoadPage = lib.lookupFunction<FPDFPage Function(FPDFDoc, Int),
      FPDFPage Function(FPDFDoc, int)>('FPDF_LoadPage');
  final fTextLoad = lib.lookupFunction<FPDFTextPage Function(FPDFPage),
      FPDFTextPage Function(FPDFPage)>('FPDFText_LoadPage');
  final fCountChars = lib.lookupFunction<Int Function(FPDFTextPage),
      int Function(FPDFTextPage)>('FPDFText_CountChars');
  final fCountRects = lib.lookupFunction<
      Int Function(FPDFTextPage, Int, Int),
      int Function(FPDFTextPage, int, int)>('FPDFText_CountRects');
  final fGetRect = lib.lookupFunction<
      Int Function(FPDFTextPage, Int, Pointer<Double>, Pointer<Double>,
          Pointer<Double>, Pointer<Double>),
      int Function(
          FPDFTextPage,
          int,
          Pointer<Double>,
          Pointer<Double>,
          Pointer<Double>,
          Pointer<Double>)>('FPDFText_GetRect');
  final fBounded = lib.lookupFunction<
      Int Function(FPDFTextPage, Double, Double, Double, Double,
          Pointer<Uint16>, Int),
      int Function(FPDFTextPage, double, double, double, double,
          Pointer<Uint16>, int)>('FPDFText_GetBoundedText');
  final fGetUnicode = lib.lookupFunction<
      UnsignedInt Function(FPDFTextPage, Int),
      int Function(FPDFTextPage, int)>('FPDFText_GetUnicode');
  final fIsGen = lib.lookupFunction<Int Function(FPDFTextPage, Int),
      int Function(FPDFTextPage, int)>('FPDFText_IsGenerated');

  for (final entry in [
    ('endo p${endoPage0 + 1}', endoPdf, endoPage0),
    ('exam p${examPage0 + 1}', examPdf, examPage0),
  ]) {
    final (label, pdf, page0) = entry;
    final p = pdf.toNativeUtf8();
    final doc = fLoadDoc(p, nullptr);
    malloc.free(p);
    if (doc == nullptr) {
      stderr.writeln('doc load failed: $pdf');
      continue;
    }
    final page = fLoadPage(doc, page0);
    final tp = fTextLoad(page);
    final n = fCountChars(tp);
    final nRects = fCountRects(tp, 0, -1);
    stdout.writeln('===== $label：chars=$n rects=$nRects');

    // 流侧：实字符 / 注入字符 多重集
    final realCount = <int, int>{};
    final genCount = <int, int>{};
    var realTotal = 0, genTotal = 0;
    for (var i = 0; i < n; i++) {
      final code = fGetUnicode(tp, i);
      if (code == 0) continue;
      if (fIsGen(tp, i) != 0) {
        genTotal++;
        genCount[code] = (genCount[code] ?? 0) + 1;
      } else {
        realTotal++;
        realCount[code] = (realCount[code] ?? 0) + 1;
      }
    }
    stdout.writeln('流侧: 实字符=$realTotal 注入=$genTotal '
        '（注入样本: ${genCount.entries.take(6).map((e) => 'U+${e.key.toRadixString(16)}×${e.value}').join(' ')}）');

    // 行侧：三件套 → 行文本多重集
    final pl = malloc<Double>(), p1 = malloc<Double>(),
        p2 = malloc<Double>(), p3 = malloc<Double>();
    try {
      final linesCount = <int, int>{};
      var linesTotal = 0;
      final lines = <String>[];
      for (var i = 0; i < nRects; i++) {
        if (fGetRect(tp, i, pl, p1, p2, p3) == 0) continue;
        final needed =
            fBounded(tp, pl.value, p1.value, p2.value, p3.value, nullptr, 0);
        if (needed <= 0) continue;
        final cap = needed * 2 + 2;
        final buf = malloc<Uint16>(cap);
        try {
          final copied =
              fBounded(tp, pl.value, p1.value, p2.value, p3.value, buf, cap);
          var s = copied > 0
              ? String.fromCharCodes(buf.asTypedList(math.min(copied, cap)))
              : '';
          final nul = s.indexOf('\u0000');
          if (nul >= 0) s = s.substring(0, nul);
          lines.add(s);
          for (final r in s.runes) {
            linesCount[r] = (linesCount[r] ?? 0) + 1;
            linesTotal++;
          }
        } finally {
          malloc.free(buf);
        }
      }
      stdout.writeln('行侧: Σ=$linesTotal');

      // 对账：流侧实字符在行侧缺失 → 内容丢失；行侧多出 → 重复/混入注入
      var lostReal = 0;
      final lostSamples = <String>[];
      var extraInLines = 0;
      final extraSamples = <String>[];
      final allCodes = {...realCount.keys, ...linesCount.keys};
      for (final code in allCodes) {
        final rc = realCount[code] ?? 0;
        final lc = linesCount[code] ?? 0;
        if (lc < rc) {
          lostReal += rc - lc;
          if (lostSamples.length < 20) {
            lostSamples.add('U+${code.toRadixString(16)} '
                '(${String.fromCharCode(code)}) 缺${rc - lc}');
          }
        } else if (lc > rc) {
          extraInLines += lc - rc;
          if (extraSamples.length < 20) {
            extraSamples.add('U+${code.toRadixString(16)} '
                '(${String.fromCharCode(code)}) 多${lc - rc}');
          }
        }
      }
      stdout
        ..writeln('对账: 实字符丢失=$lostReal | 行侧多出=$extraInLines '
            '（流侧注入总量=$genTotal）')
        ..writeln('  丢失样本: ${lostSamples.join(' ')}')
        ..writeln('  多出样本: ${extraSamples.join(' ')}');
    } finally {
      malloc.free(pl);
      malloc.free(p1);
      malloc.free(p2);
      malloc.free(p3);
    }
  }
}
