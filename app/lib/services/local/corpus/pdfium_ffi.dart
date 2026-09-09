// 恒牙（hengya）· 端上语料抽取 · pdfium FFI 绑定（最小面）
// ============================================================================
//
// Phase 3b：PDF 文本抽取引擎 = pdfium（bblanchon 预编译 chromium/8035，
// 二进制布局/来源/md5/许可见 app/test/fixtures/pdfium/README.md）。
// Python 参考实现 automation/server-pipeline/extract_pdf.py 用 PyMuPDF
// （MuPDF 系）；**跨引擎文本布局推断原理上不可逐字节一致**——验收口径 =
// 元数据（页数/书签/creationDate）硬对拍 + 分块结构等价 + Dart 自金样
// 回归 + 与 Python 金样的差异度实测报告（见交付 handoff）。
//
// 最小绑定面（只绑 extract_pdf.dart 用到的 API；签名为
// fpdf_view.h / fpdf_text.h / fpdf_doc.h 原文）：
//   FPDF_InitLibrary / FPDF_GetLastError
//   FPDF_LoadDocument(path, null) / FPDF_CloseDocument / FPDF_GetPageCount
//   FPDF_LoadPage / FPDF_ClosePage
//   FPDFText_LoadPage / FPDFText_ClosePage / FPDFText_CountChars +
//   行结构三件套 CountRects / GetRect / GetBoundedText（见下「行结构」）
//   FPDFBookmark_GetFirstChild / GetNextSibling / GetTitle / GetDest +
//   FPDFDest_GetDestPageIndex（2021 由 GetDestIndex 更名，签名不变——
//   chromium/8035 四平台二进制实测导出名为新名，旧名 lookup 抛 error 127）；
//   0 基 → 调用方 +1 对齐 PyMuPDF 1 基页码
//   FPDF_GetMetaText（'CreationDate'）
//
// 平台加载：Android → jniLibs 的 libpdfium.so（gradle 自动打包）；
// Windows（宿主测试）→ test/fixtures/pdfium/win-x64/pdfium.dll（cwd=app/）
// → PATH 回退。其余平台 UnsupportedError。
// FPDF_InitLibrary 进程级仅一次（幂等保护）；FPDF_DestroyLibrary 不主动
// 调用（进程退出由 OS 回收，Flutter 退出钩子不可靠，官方 sample 同）。
//
// 行结构（跨引擎差异根源）：PyMuPDF get_text() 内置 block→line 结构化
// 输出；pdfium 侧用其自带分段矩形三件套 CountRects → GetRect →
// GetBoundedText（复制粘贴同源的行划分，内部坐标自洽；2026-09-06 实测
// 对账 tool/pdf_rect_diag.dart：实字符零丢失、注入 \r\n 对随段边界丢弃、
// 段内注入空格保留、重叠段边界 ≤0.2% 字符重复）。注意 GetRect 参数序
// (l,t,r,b)；自制「字符盒中心点归属」因 GetRect/GetCharBox 坐标系不一致
// （疑 /Rotate）已实测证伪不可用。与 MuPDF 行划分的系统性差异（空格
// 注入/连字符/分段粒度）即「差异度」的来源——实测数字见冒烟测试与探针。

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

// ------------------------------------------------------------- C 句柄 ----

typedef FPDFDocument = Pointer<Void>;
typedef FPDFPage = Pointer<Void>;
typedef FPDFTextPage = Pointer<Void>;
typedef FPDFBookmark = Pointer<Void>;
typedef FPDFDest = Pointer<Void>;

/// FPDF_GetLastError 错误码（fpdf_view.h，仅列用到项）。
const fpdfErrPassword = 4;
const fpdfErrSecurity = 5;

/// 书签条目（对齐 PyMuPDF get_toc(simple=True) 的 [lvl, title, page]）。
/// level：1 基深度；page：**1 基**页码（DestIndex+1；无 dest → 0，调用方
/// clamp 后按 1 处理，同 Python `int(pg or 1)`）。
final class TocEntry {
  final int level;
  final String title;
  final int page;
  const TocEntry(this.level, this.title, this.page);
}

// ------------------------------------------------------------ 库单例 ----

/// pdfium 动态库单例（进程级；首次访问触发加载 + FPDF_InitLibrary）。
final class PdfiumLib {
  PdfiumLib._();

  /// 全局单例。
  static final PdfiumLib instance = PdfiumLib._();

  late final DynamicLibrary _lib = _openLib();
  var _inited = false;

  static DynamicLibrary _openLib() {
    if (Platform.isAndroid) {
      // jniLibs 打包的 .so 按名命中（System.loadLibrary 语义）
      return DynamicLibrary.open('libpdfium.so');
    }
    if (Platform.isWindows) {
      Object? lastErr;
      // flutter test 宿主：cwd=app/ → 测试夹具优先；否则 PATH 回退
      for (final cand in [
        'test/fixtures/pdfium/win-x64/pdfium.dll',
        'pdfium.dll',
      ]) {
        try {
          return DynamicLibrary.open(cand);
        } on Object catch (e) {
          lastErr = e;
        }
      }
      throw StateError(
        'pdfium.dll 加载失败（test/fixtures/pdfium/win-x64/ 与 PATH 均未'
        '命中；二进制获取见 test/fixtures/pdfium/README.md）：$lastErr',
      );
    }
    throw UnsupportedError(
      'pdfium FFI 仅支持 Android/Windows（当前平台 '
      '${Platform.operatingSystem} 不在预编译清单）',
    );
  }

  void ensureInit() {
    if (!_inited) {
      _fInit();
      _inited = true;
    }
  }

  // ---------------- 原始绑定（签名照抄 pdfium 头文件） ----------------

  late final void Function() _fInit = _lib
      .lookupFunction<Void Function(), void Function()>('FPDF_InitLibrary');

  late final int Function() _fLastError = _lib.lookupFunction<
      UnsignedLong Function(), int Function()>('FPDF_GetLastError');

  late final FPDFDocument Function(Pointer<Utf8>, Pointer<Void>) _fLoadDoc =
      _lib.lookupFunction<
              FPDFDocument Function(Pointer<Utf8>, Pointer<Void>),
              FPDFDocument Function(Pointer<Utf8>, Pointer<Void>)>(
          'FPDF_LoadDocument');

  late final void Function(FPDFDocument) _fCloseDoc = _lib.lookupFunction<
      Void Function(FPDFDocument),
      void Function(FPDFDocument)>('FPDF_CloseDocument');

  late final int Function(FPDFDocument) _fPageCount = _lib.lookupFunction<
      Int Function(FPDFDocument),
      int Function(FPDFDocument)>('FPDF_GetPageCount');

  late final FPDFPage Function(FPDFDocument, int) _fLoadPage = _lib
      .lookupFunction<FPDFPage Function(FPDFDocument, Int),
          FPDFPage Function(FPDFDocument, int)>('FPDF_LoadPage');

  late final void Function(FPDFPage) _fClosePage = _lib.lookupFunction<
      Void Function(FPDFPage),
      void Function(FPDFPage)>('FPDF_ClosePage');

  late final FPDFTextPage Function(FPDFPage) _fTextLoad = _lib.lookupFunction<
      FPDFTextPage Function(FPDFPage),
      FPDFTextPage Function(FPDFPage)>('FPDFText_LoadPage');

  late final void Function(FPDFTextPage) _fTextClose = _lib.lookupFunction<
      Void Function(FPDFTextPage),
      void Function(FPDFTextPage)>('FPDFText_ClosePage');

  late final int Function(FPDFTextPage) _fCountChars = _lib.lookupFunction<
      Int Function(FPDFTextPage),
      int Function(FPDFTextPage)>('FPDFText_CountChars');

  // 行结构三件套（fpdf_text.h）：分段矩形 = pdfium 复制粘贴同源的行划分。
  // CountRects(text_page, start_index, count) → 矩形数（count=-1 全量）
  late final int Function(FPDFTextPage, int, int) _fCountRects = _lib
      .lookupFunction<Int Function(FPDFTextPage, Int, Int),
          int Function(FPDFTextPage, int, int)>('FPDFText_CountRects');

  // GetRect(text_page, rect_index, left*, top*, right*, bottom*) → FPDF_BOOL。
  // 参数序 (l,t,r,b)（y 向上）——与历史 GetCharBox (l,b,r,t) 不同，实测
  // 114/114 矩形 p1>p3 定谳（tool/pdf_rect_diag.dart v1）。
  late final int Function(FPDFTextPage, int, Pointer<Double>, Pointer<Double>,
      Pointer<Double>, Pointer<Double>) _fGetRect = _lib.lookupFunction<
      Int Function(FPDFTextPage, Int, Pointer<Double>, Pointer<Double>,
          Pointer<Double>, Pointer<Double>),
      int Function(
          FPDFTextPage,
          int,
          Pointer<Double>,
          Pointer<Double>,
          Pointer<Double>,
          Pointer<Double>)>('FPDFText_GetRect');

  // GetBoundedText(text_page, l, t, r, b, buffer, buflen) → 字符数：
  // 首调 (null,0) 返回所需字符数（不含尾 NUL）；buflen 按 UTF-16 单位计。
  late final int Function(FPDFTextPage, double, double, double, double,
      Pointer<Uint16>, int) _fBoundedText = _lib.lookupFunction<
      Int Function(FPDFTextPage, Double, Double, Double, Double,
          Pointer<Uint16>, Int),
      int Function(FPDFTextPage, double, double, double, double,
          Pointer<Uint16>, int)>('FPDFText_GetBoundedText');

  late final FPDFBookmark Function(FPDFDocument, FPDFBookmark)
      _fBmFirstChild = _lib.lookupFunction<
          FPDFBookmark Function(FPDFDocument, FPDFBookmark),
          FPDFBookmark Function(
              FPDFDocument, FPDFBookmark)>('FPDFBookmark_GetFirstChild');

  late final FPDFBookmark Function(FPDFDocument, FPDFBookmark)
      _fBmNextSibling = _lib.lookupFunction<
          FPDFBookmark Function(FPDFDocument, FPDFBookmark),
          FPDFBookmark Function(
              FPDFDocument, FPDFBookmark)>('FPDFBookmark_GetNextSibling');

  // GetTitle：buffer=null + buflen=0 探测 → 返回所需**字节数**（UTF-16LE）
  late final int Function(FPDFBookmark, Pointer<Uint16>, int) _fBmTitle = _lib
      .lookupFunction<
          UnsignedLong Function(FPDFBookmark, Pointer<Uint16>, UnsignedLong),
          int Function(
              FPDFBookmark, Pointer<Uint16>, int)>('FPDFBookmark_GetTitle');

  late final FPDFDest Function(FPDFDocument, FPDFBookmark) _fBmGetDest = _lib
      .lookupFunction<
          FPDFDest Function(FPDFDocument, FPDFBookmark),
          FPDFDest Function(
              FPDFDocument, FPDFBookmark)>('FPDFBookmark_GetDest');

  // 2021 API 更名：GetDestIndex → GetDestPageIndex（旧名符号已不存在，
  // 用旧名 lookup 直接抛 error 127——绑定符号名须与二进制导出表核对）
  late final int Function(FPDFDocument, FPDFDest) _fDestPageIndex = _lib
      .lookupFunction<Int Function(FPDFDocument, FPDFDest),
          int Function(FPDFDocument, FPDFDest)>('FPDFDest_GetDestPageIndex');

  // GetMetaText(document, tag, buffer, buflen) → 字节数（同 GetTitle 模式）
  late final int Function(FPDFDocument, Pointer<Utf8>, Pointer<Uint16>, int)
      _fMetaText = _lib.lookupFunction<
          UnsignedLong Function(
              FPDFDocument, Pointer<Utf8>, Pointer<Uint16>, UnsignedLong),
          int Function(
              FPDFDocument, Pointer<Utf8>, Pointer<Uint16>, int)>(
          'FPDF_GetMetaText');

  // ---------------- 高层封装 ----------------

  /// 两次调用模式读 FPDF_WCHAR 输出（GetTitle/GetMetaText 共用）：
  /// 首调 (null, 0) 得所需字节数 → 分配 → 次调读回 → UTF-16 组合
  /// （String.fromCharCodes 按 code units 组合，代理对正确成对）→ NUL 截断。
  String readWide(int Function(Pointer<Uint16>, int) call) {
    final neededBytes = call(nullptr, 0);
    if (neededBytes <= 0) return '';
    final units = (neededBytes + 1) ~/ 2; // 字节 → UTF-16 单元（含尾 NUL 余量）
    final buf = malloc<Uint16>(units);
    try {
      final writtenBytes = call(buf, units * 2);
      var codeUnits = writtenBytes > 0 && writtenBytes ~/ 2 <= units
          ? writtenBytes ~/ 2
          : units; // 0 返回 → 读全缓冲（下步按 NUL 截断）
      if (codeUnits > units) codeUnits = units;
      // String.fromCharCodes 按 UTF-16 code units 组合（代理对正确成对）
      var s = String.fromCharCodes(buf.asTypedList(codeUnits));
      final nul = s.indexOf('\u0000');
      if (nul >= 0) s = s.substring(0, nul); // 尾 NUL 截断（meta/标题不含 NUL）
      return s;
    } finally {
      malloc.free(buf);
    }
  }

  /// FPDFText_GetBoundedText 两次调用模式（实测语义，tool/pdf_rect_diag.dart
  /// v3）：首调 (null,0) → 所需**字符数**（不含尾 NUL；buflen 按 UTF-16
  /// 单位）；二调写回内容 + 尾 NUL，返回写出单位数（含 NUL）。缓冲按
  /// needed×2+2 分配（「字符数」按码点口径时 astral 最坏 2 单位/码点，
  /// +NUL 余量），读回按 NUL 截断——对返回值两种口径均正确。
  String readBounded(
      FPDFTextPage tp, double left, double top, double right, double bottom) {
    final needed = _fBoundedText(tp, left, top, right, bottom, nullptr, 0);
    if (needed <= 0) return '';
    final cap = needed * 2 + 2;
    final buf = malloc<Uint16>(cap);
    try {
      final copied = _fBoundedText(tp, left, top, right, bottom, buf, cap);
      var s = copied > 0
          ? String.fromCharCodes(buf.asTypedList(math.min(copied, cap)))
          : '';
      final nul = s.indexOf('\u0000');
      if (nul >= 0) s = s.substring(0, nul);
      return s;
    } finally {
      malloc.free(buf);
    }
  }
}

// ----------------------------------------------------------- 文档封装 ----

/// 打开的 PDF 文档（extract_pdf.dart 的唯一入口形态；等价 PyMuPDF 的
/// Document：pageCount/metadata/toc/逐页文本）。
final class PdfDocument {
  final FPDFDocument _doc;
  PdfDocument._(this._doc);
  var _closed = false;

  /// 打开文档（path UTF-8）。加密（空密码不可解，errCode=PASSWORD/
  /// SECURITY）→ FormatException（对应 Python `raise ValueError("加密
  /// PDF（needs_pass），跳过")`）；其他失败 → FormatException（坏 PDF）。
  static PdfDocument open(String path) {
    final lib = PdfiumLib.instance..ensureInit();
    final p = path.toNativeUtf8();
    try {
      final doc = lib._fLoadDoc(p, nullptr);
      if (doc == nullptr) {
        final err = lib._fLastError();
        if (err == fpdfErrPassword || err == fpdfErrSecurity) {
          throw const FormatException('加密 PDF（needs_pass），跳过');
        }
        throw const FormatException('坏 PDF：FPDF_LoadDocument 失败');
      }
      return PdfDocument._(doc);
    } finally {
      malloc.free(p);
    }
  }

  int get pageCount => PdfiumLib.instance._fPageCount(_doc);

  /// FPDF_GetMetaText(tag)：元数据文本（'CreationDate'/'Title'/…）。
  /// 读取失败 → ''（Python 侧 metadata 缺字段即 ''）。
  String metaText(String tag) {
    final lib = PdfiumLib.instance;
    final t = tag.toNativeUtf8();
    try {
      return lib.readWide(
          (buf, lenBytes) => lib._fMetaText(_doc, t, buf, lenBytes));
    } finally {
      malloc.free(t);
    }
  }

  /// 页原始行列表（pdfium 分段矩形三件套行结构；strip/过滤由调用方做——
  /// 对齐 Python `page.get_text().splitlines()` 的位置）。pageNo0 为 0 基。
  ///
  /// 行 = GetRect 分段（阅读序，复制粘贴同源）；逐段 GetBoundedText 取
  /// 文本（见文件头「行结构」与 PdfiumLib.readBounded 实测语义）。
  /// 无文本页 → []。
  List<String> rawPageLines(int pageNo0) {
    final lib = PdfiumLib.instance;
    final page = lib._fLoadPage(_doc, pageNo0);
    if (page == nullptr) return const [];
    try {
      final tp = lib._fTextLoad(page);
      if (tp == nullptr) return const [];
      try {
        if (lib._fCountChars(tp) <= 0) return const [];
        final nRects = lib._fCountRects(tp, 0, -1);
        if (nRects <= 0) return const [];
        final pl = malloc<Double>();
        final pt = malloc<Double>();
        final pr = malloc<Double>();
        final pb = malloc<Double>();
        try {
          final lines = <String>[];
          for (var i = 0; i < nRects; i++) {
            if (lib._fGetRect(tp, i, pl, pt, pr, pb) == 0) continue;
            final s =
                lib.readBounded(tp, pl.value, pt.value, pr.value, pb.value);
            if (s.isNotEmpty) lines.add(s);
          }
          return lines;
        } finally {
          malloc.free(pl);
          malloc.free(pt);
          malloc.free(pr);
          malloc.free(pb);
        }
      } finally {
        lib._fTextClose(tp);
      }
    } finally {
      lib._fClosePage(page);
    }
  }

  /// 书签树 → 先序 (level, title, page1based) 列表（等价
  /// `doc.get_toc(simple=True)`；无书签 → []）。parent=null 走根层，
  /// GetFirstChild/GetNextSibling 递归 = 先序 DFS。
  List<TocEntry> getToc() {
    final lib = PdfiumLib.instance;
    final out = <TocEntry>[];

    void walk(FPDFBookmark parent, int depth) {
      for (var bm = lib._fBmFirstChild(_doc, parent);
          bm != nullptr;
          bm = lib._fBmNextSibling(_doc, bm)) {
        final title = lib.readWide((buf, lenBytes) => lib._fBmTitle(bm, buf, lenBytes));
        final dest = lib._fBmGetDest(_doc, bm);
        var page = 0;
        if (dest != nullptr) {
          final idx = lib._fDestPageIndex(_doc, dest);
          page = idx >= 0 ? idx + 1 : 0; // 0 基 → 1 基；无效 -1 → 0
        }
        out.add(TocEntry(depth, title, page));
        walk(bm, depth + 1);
      }
    }

    walk(nullptr, 1);
    return out;
  }

  void close() {
    if (!_closed) {
      _closed = true;
      PdfiumLib.instance._fCloseDoc(_doc);
    }
  }
}
