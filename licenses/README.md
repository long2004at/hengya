# 恒牙 · 第三方组件许可清单（licenses/）

> **主许可**：本项目自身代码以 MIT 许可（见根目录 `LICENSE`）发布。
> 本清单覆盖仓库内**实际分发/打包**的第三方组件。核实口径（2026-09-06）：
> pub 直接依赖逐包核对 **pub 缓存中包自带的 LICENSE 文件原文**（本地
> `%LOCALAPPDATA%\Pub\Cache\hosted\pub.dev\<pkg>\LICENSE`），resolved 版本取自
> `app/pubspec.lock`；原生组件以官方仓库/发布件口径核实。

## A. 原生二进制组件

| 组件 | 许可 | 出处与仓库内位置 |
|---|---|---|
| **pdfium**（PDF 文本抽取引擎） | BSD-3-Clause（本体）+ 内嵌第三方组件各自许可 + Apache-2.0（部分内嵌组件） | 预编译件来自 [bblanchon/pdfium](https://github.com/bblanchon/pdfium)（Benoît Blanchon 的 pdfium 预编译发布工程，工程本体 MIT），release `chromium/8035`（VERSION：MAJOR=154 MINOR=0 BUILD=8035 PATCH=0）。仓库内位置与 md5 见 `licenses/pdfium-NOTICE.md` 与 `app/test/fixtures/pdfium/README.md`；许可全文随库携带：`app/test/fixtures/pdfium/licenses/`（16 文件）+ `app/test/fixtures/pdfium/LICENSE`（构建工程 MIT） |
| **SQLite** | **Public Domain**（作者放弃版权，sqlite.org 官方口径：https://www.sqlite.org/copyright.html） | ① Android：经 `sqlite3_flutter_libs` 打包的官方 SQLite 预编译件；② Windows 测试宿主：`app/test/sqlite3.dll`（1,709,056 B，取自 [simolus3/sqlite3.dart](https://github.com/simolus3/sqlite3.dart) 官方 release 资产，内含 sqlite.org 源码编译件） |
| **sqlite-vec**（向量检索扩展，asg017） | MIT（https://github.com/asg017/sqlite-vec） | 仅历史 Python 建库管线使用过（该管线未随公开仓库分发）；**本仓库不加载、不打包**——Dart/Flutter 端 vec0 镜像恒为普通表 BLOB（契约见 `docs/sqlite-vec集成与Dart契约-2026-09-06.md`） |
| **Flutter SDK** | BSD-3-Clause（https://github.com/flutter/flutter/blob/master/LICENSE） | `flutter` / `flutter_test`（SDK 依赖，随 Flutter 工具链分发） |

## B. app/pubspec.yaml 直接依赖

resolved 版本来自 `app/pubspec.lock`；License 逐包核对包内 LICENSE 文件原文。

| 包 | resolved 版本 | License | 版权方（LICENSE 文件原文） |
|---|---|---|---|
| archive | 4.2.0 | MIT | Copyright (c) 2013-2021 Brendan Duncan |
| crypto | 3.0.7 | BSD-3-Clause | Copyright 2015, the Dart project authors |
| cupertino_icons | 1.0.9 | MIT | Copyright (c) 2016 Vladimir Kharlampidi |
| ffi | 2.2.0 | BSD-3-Clause | Copyright 2019, the Dart project authors |
| file_selector | 1.1.0 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| flutter_lints（dev） | 6.0.0 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| flutter_local_notifications | 19.5.0 | BSD-3-Clause | Copyright 2018 Michael Bui |
| go_router | 14.8.1 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| package_info_plus | 10.2.1 | BSD-3-Clause | Copyright 2017 The Chromium Authors |
| path_provider | 2.1.6 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| provider | 6.1.5+1 | MIT | Copyright (c) 2019 Remi Rousselet |
| share_plus | 13.3.0 | BSD-3-Clause | Copyright 2017, the Flutter project authors |
| shared_preferences | 2.5.5 | BSD-3-Clause | Copyright 2013 The Flutter Authors |
| sqlite3 | 2.4.0 | MIT | Copyright (c) 2020 Simon Binder |
| sqlite3_flutter_libs | 0.5.42 | MIT | Copyright (c) 2020 Simon Binder |
| timezone | 0.10.1 | BSD-2-Clause | Copyright (c) 2014, timezone project authors |
| shared（path 依赖 `../shared`） | — | 随本项目 MIT | 本项目自有代码，非第三方 |

## C. 自产资产说明（非第三方）

- `app/assets/prompts/`：LLM 提示词模板——项目自有资产。
- `app/test/fixtures/pdfium/`（LICENSE/VERSION/licenses/README.md）：第三方许可随库携带的合规文件，**不得删除**（见 `licenses/pdfium-NOTICE.md`）。历史上的自签 CA 证书（`app/assets/certs/ca.pem`）已随开源清理退役，`*.pem` 由 `.gitignore` 一律忽略。

## D. 维护纪律

1. `pubspec.yaml` 新增/升级**直接依赖**时必须同步更新 B 表（resolved 版本 + 包内 LICENSE 核对）。
2. 升级 pdfium（更换 `chromium/xxxx` 版本）时，同步更新 `licenses/pdfium-NOTICE.md` 的版本号/md5 与 `app/test/fixtures/pdfium/`（README/VERSION/LICENSE/licenses/）。
3. 开源发布（Release APK / 源码包）必须随附：根 `LICENSE` + 本目录全文件 + `app/test/fixtures/pdfium/licenses/` 全部许可文本。
4. GPL/AGPL 组件**禁止引入**（新增依赖前先核对本清单口径）。
