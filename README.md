# 恒牙（Hengya）· 口腔医学复习系统

[![CI](https://github.com/long2004at/hengya/actions/workflows/ci.yml/badge.svg)](https://github.com/long2004at/hengya/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/long2004at/hengya)](https://github.com/long2004at/hengya/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Local-first 个人口腔医学间隔复习（SRS）应用：教材 / PPT / 真题在端上建库，AI 拆卡、人工终审、FSRS 调度复习。一人一机一库，日常使用零服务器依赖。

> 当前版本 **0.1.0**（首个公开发布版本；Android versionCode 19）。App 身份为 `dev.hengya.hengya`，数据文件 `hengya.db`；公开版为全新应用身份，自备学习资料即可开始。

## 架构一览

```
手机 App（Flutter/Android · BACKEND=local）
 ├─ hengya.db      卡片 / 复习记录 / 科目（SQLite，WAL）
 ├─ corpus/         语料库 corpus.db + 学习罗盘 progress.json
 ├─ 端上拆卡流水线   收件箱关键词 → 罗盘推进 → 检索取证据 → LLM 拆卡 → 待审池
 └─ 可选云端 API     LLM / Embedding / Reranker（用户自备 key，仅出卡与检索增强）
电脑（可选，仅首次建库）：Dart CLI 建库探针 → corpus.db 拷贝入机
```

- **卡片全部经待审核池人工终审**（质量硬闸门）；FSRS-4.5 间隔调度、科目隔离、回炉重造闭环
- 端内检索：FTS5 词面 + 向量余弦融合（linear 0.40/0.60）+ 可选 reranker 精排
- 全链已 Dart 化：建库（extract_all）/ 检索（corpusSearch）/ 拆卡（run_engine）/ 罗盘（progress_db）/ 编排（pipeline_runner）
- 应用内更新：任意 HTTP 直链（自建 nginx / GitHub Release 均可，见 `docs/ECS更新服务部署指南.md`），比较只认 versionCode

## 目录结构

| 目录 | 内容 |
|---|---|
| `app/` | Flutter App（local-first 主战场；含 corpus 建库/检索/拆卡/罗盘全链与测试套件） |
| `shared/` | 共享数据模型（卡片 schema、FSRS-4.5 调度器） |
| `docs/` | ADR / 真机验证清单 / 卡片编写规范 / 检索与分块技术文档 |
| `licenses/` | MIT 主许可 + 第三方组件许可清单（pdfium / SQLite 等） |
| `tools/` | 出包脚本 `release_build.ps1`（含可选 scp 上传）与部署配置模板 |
| `design/` | 应用图标设计源文件（SVG + 渲染工具） |

## 快速开始（App · local 模式）

```bash
cd app
flutter pub get
flutter build apk --release
```

> **裸构建默认即 local**（`BACKEND` 缺省 = local，零配置开箱即用）。
> 需要时显式覆盖：`--dart-define=BACKEND=local|demo|remote`（remote = 连自建服务器的历史架构，须另行注入 `API_BASE`/`API_TOKEN`）。

```bash
flutter test   # 全量测试（Windows 宿主自动用 test/sqlite3.dll 与 fixtures/pdfium；
               #  迁移 fixture 由 test/helpers/synthetic_snapshot.dart 测试期即时生成；
               #  依赖私有课程语料/金样的用例会打印 SKIP 后自动跳过，不算失败）
```

## 语料建库（首次，可在电脑）

```bash
cd app
dart run tool/corpus_build_probe.dart <语料目录> <输出库路径/corpus.db>
```

三态：`offline`（无 key 词面单路）/ `drill`（本地伪向量演练）/ `online`（OpenAI 兼容嵌入端点，可断点续传）。产出 `corpus.db` 与 toc sidecar 拷入手机 `<应用数据目录>/corpus/` 即可端上检索；也可在 App 内直接上传课件建库（设置 → 知识库），或导入成品语料包 zip（设置 → 数据管理 → 导入语料包）。

> 出于版权原因，公开仓库**不包含**任何教材 / 真题 / 课件语料与对应金样 fixtures——请使用自备的学习资料建库。

## 卡片生产规范

所有卡片（人工或 AI 生成）必须遵循 `docs/卡片编写规范.md`：单卡单考点、主动回忆、来源可追溯、题干自包含、答案带锚点。

## 真机验收

`docs/真机验证清单-2026-09-06.md`（内测期 50 项回归记录，P→A→…→K 组，作为验收方法学参考；其中引用的部分内测版本文档未随公开仓库分发）。

## 隐私

- 学习数据（卡片 / 复习记录 / 科目 / AI 配置）全部存于本机 SQLite（`hengya.db`），**不出设备、不经任何服务器**。
- 唯一外联是可选的 AI 服务调用（拆卡 / 向量检索增强）：由用户自备 API key，AI 服务密钥存于系统安全存储（Android Keystore 加密），不写入应用数据库，「一键导出」产物不含密钥。
- 开源版默认不与任何服务器通信。

## 免责声明

本项目按「现状」以 MIT 许可发布，供个人学习与复习管理使用；内容不构成任何医疗建议，口腔医学知识以权威教材与现行诊疗规范为准。

## 许可

MIT（见根 `LICENSE`）；第三方组件（pdfium、SQLite、Dart/Flutter 生态包）清单与合规要求见 `licenses/`。
