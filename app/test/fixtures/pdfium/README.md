# pdfium 预编译二进制（端上 PDF 文本抽取引擎）

来源：[bblanchon/pdfium](https://github.com/bblanchon/pdfium)（Benoît Blanchon 的
pdfium 预编译发布工程），release `chromium/8035`，包内 `VERSION` 文件为
`MAJOR=154 MINOR=0 BUILD=8035 PATCH=0`（2026-09-06 经 GitHub 直连下载 4 个
tgz 后解包放置；tgz 留存 `.snow/tmp/pdfium/`，不入库）。

## 放置布局

| 用途 | 路径 | 大小(B) | md5 |
|---|---|---|---|
| Android arm64-v8a（真机主流） | `app/android/app/src/main/jniLibs/arm64-v8a/libpdfium.so` | 6,402,896 | 7f804f1db5c000a3f216f130b90701f7 |
| Android armeabi-v7a | `app/android/app/src/main/jniLibs/armeabi-v7a/libpdfium.so` | 4,216,652 | 66ada9cf58ce9414802abcdd72dff8d0 |
| Android x86_64（模拟器） | `app/android/app/src/main/jniLibs/x86_64/libpdfium.so` | 6,572,216 | 504d9a0e96bbeb53ad17f6e51bf9a234 |
| Windows x64（`flutter test` 宿主机） | `app/test/fixtures/pdfium/win-x64/pdfium.dll` | 7,266,816 | b2c62d8b0d015d809131cf1a31390d88 |

- `jniLibs/` 下的 `.so` 由 gradle 按 ABI 自动打包进 APK，`dart:ffi` 侧
  `DynamicLibrary.open('libpdfium.so')` 直接命中。
- `test/fixtures/` 下的 `pdfium.dll` 仅供宿主机（Windows x64）`flutter test`
  跑 PDF 冒烟/自金样测试；`pdfium_ffi.dart` 的 Windows loader 候选路径即
  `test/fixtures/pdfium/win-x64/pdfium.dll`（cwd=app/），回退 PATH 上的
  `pdfium.dll`。

## 构建配置（包内 args.gn 原文）

```
is_component_build = false
is_debug = false
pdf_enable_v8 = false        # 无 JS 引擎
pdf_enable_xfa = false      # 无 XFA 表单
pdf_is_standalone = true
pdf_use_partition_alloc = false
```

## 上游 tgz 源文件（下载件 md5，未解包即校验）

| tgz | 大小(B) | md5 |
|---|---|---|
| pdfium-win-x64.tgz | 3,772,597 | db7cf39a59846d1c7daef64e2a0215a6 |
| pdfium-android-arm64.tgz | 3,362,107 | cd02a8da5838607047e31e467a39fc84 |
| pdfium-android-arm.tgz | 2,803,355 | 49ba896380db44612657e667871f1cae |
| pdfium-android-x64.tgz | 3,469,512 | 016eddf110bc56f91e13ade5ed43d5c1 |

下载 URL 形如
`https://github.com/bblanchon/pdfium/releases/download/chromium%2F8035/pdfium-win-x64.tgz`
（`chromium/8035` 须 URL 转义为 `chromium%2F8035`；`curl.exe -L` 直连可下）。

## 许可合规（开源发布时必须随附，勿删）

- **pdfium 本体：BSD-3-Clause** —— `licenses/pdfium.txt`
  （"Copyright 2014 The PDFium Authors"，三条款 BSD）。
- **预编译发布工程：MIT** —— `LICENSE`（Benoît Blanchon 构建工程本体）。
- **内嵌第三方组件许可** —— `licenses/` 全目录（zlib、libpng、
  libjpeg-turbo、freetype、lcms、icu、abseil、openjpeg、agg-2.3、
  simdutf、fast_float、cpu_features、libunwind、llvm-libc、catapult 等）。

恒牙开源时，仓库/发布包必须保留本目录 `LICENSE` 与 `licenses/` 全部文件，
并在开源声明（LICENSE/NOTICE）中列出 pdfium（BSD-3-Clause）及其第三方
许可清单。**此事项列入开源拍板清单**（见交付报告遗留事项）。
