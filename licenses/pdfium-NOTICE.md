# NOTICE — App 内置 pdfium 二进制组件

恒牙（Hengya）App 的发行物（含 APK）内置以下第三方二进制组件，特此声明来源与许可。

## 组件：pdfium（PDF 文本抽取引擎）

- **本体许可**：BSD-3-Clause —— Copyright 2014 The PDFium Authors。
  许可全文随仓库携带：`app/test/fixtures/pdfium/licenses/pdfium.txt`。
- **来源**：[bblanchon/pdfium](https://github.com/bblanchon/pdfium)（Benoît Blanchon
  维护的 pdfium 预编译发布工程，**工程本体 MIT**，全文：
  `app/test/fixtures/pdfium/LICENSE`），release `chromium/8035`。
- **版本**：`MAJOR=154 MINOR=0 BUILD=8035 PATCH=0`
  （随库携带 `app/test/fixtures/pdfium/VERSION`）。
- **构建配置**（包内 args.gn 原文，无 V8/XFA，独立静态构建）：
  `is_component_build=false / is_debug=false / pdf_enable_v8=false /
  pdf_enable_xfa=false / pdf_is_standalone=true / pdf_use_partition_alloc=false`

## 内置二进制清单

| 文件（仓库内路径） | 用途 | 大小(B) | md5 |
|---|---|---|---|
| `app/android/app/src/main/jniLibs/arm64-v8a/libpdfium.so` | Android arm64-v8a（真机主流，随 APK 分发） | 6,402,896 | 7f804f1db5c000a3f216f130b90701f7 |
| `app/android/app/src/main/jniLibs/armeabi-v7a/libpdfium.so` | Android armeabi-v7a（随 APK 分发） | 4,216,652 | 66ada9cf58ce9414802abcdd72dff8d0 |
| `app/android/app/src/main/jniLibs/x86_64/libpdfium.so` | Android x86_64（模拟器，随 APK 分发） | 6,572,216 | 504d9a0e96bbeb53ad17f6e51bf9a234 |
| `app/test/fixtures/pdfium/win-x64/pdfium.dll` | Windows x64 `flutter test` 宿主件（**不随 APK 分发**） | 7,266,816 | b2c62d8b0d015d809131cf1a31390d88 |

- Android 三 ABI 的 `.so` 由 gradle 自动打包进 APK；`dart:ffi` 侧
  `DynamicLibrary.open('libpdfium.so')` 直接命中（见
  `app/lib/services/local/corpus/pdfium_ffi.dart` 平台加载段）。

## 内嵌第三方组件许可

pdfium 二进制内嵌以下第三方组件，各自许可全文随仓库携带于
`app/test/fixtures/pdfium/licenses/`（再分发时不得删除）：

| 组件 | 许可文件 |
|---|---|
| abseil | `abseil.txt` |
| agg-2.3 | `agg23.txt` |
| fast_float | `fast_float.txt` |
| freetype | `freetype.txt` |
| ICU | `icu.txt` |
| lcms | `lcms.txt` |
| libjpeg-turbo | `libjpeg_turbo.md` + `libjpeg_turbo.ijg` |
| libopenjpeg | `libopenjpeg.txt` |
| libpng | `libpng.txt` |
| LLVM libc++ | `llvm-libc.txt` |
| simdutf | `simdutf.txt` |
| zlib | `zlib.txt` |
| pdfium 本体（BSD-3）及 Apache-2.0 授权部分 | `pdfium.txt` |

## 合规要求

1. 本仓库以源码公开（含上述二进制）再分发时，必须保留
   `app/test/fixtures/pdfium/` 下的 `LICENSE`、`VERSION`、`licenses/` 全部文件
   与本 NOTICE（`licenses/pdfium-NOTICE.md`）。
2. APK 发行（GitHub Release 等渠道）不剥离上述许可义务——本文件与
   `licenses/README.md` 应随项目发布物页面公开可查。
3. 升级 pdfium 版本时：更新本表 md5、`VERSION`、上游 release 标签，并同步
   `app/test/fixtures/pdfium/README.md`。
