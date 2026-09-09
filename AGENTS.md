# AGENTS.md — 恒牙（hengya）AI 协作约定

面向在本仓库工作的 AI 编码助手与人类贡献者的既定纪律。

## 验证纪律（重要）

本仓库有 GitHub Actions CI（`.github/workflows/ci.yml`）：**每次 push / PR 自动在云端跑 `flutter analyze` + 全量测试（Windows job，约 5 分钟）**。

- 改动代码后**不要**在本机跑全量 `flutter test` 或 `flutter build apk`——commit + push，让 CI 验证。
- 本地允许且推荐的快检：`flutter analyze`（约 3 秒，cwd=app/）。
- 仅两种情况本地跑测试：
  1. CI 红了，需要定向复现 → `flutter test test/<单个文件>`（cwd=app/）；
  2. 改动的是测试基础设施本身。
- APK 出包由 **tag 触发的 CI** 自动完成（生成草稿 Release），无需本地构建。

## 发版流程

1. `app/pubspec.yaml` 版本递增——**versionCode 严格递增**（Android 不允许降级覆盖安装；应用内更新比较只认 versionCode）；
2. commit → `git tag v<版本>` → push（含 tag）；
3. CI 自动构建 APK 并创建**草稿** Release（构建日志含 sha256 / sizeBytes）；
4. 人工润色中文发布说明 → 发布 Release；
5. 自建更新通道（如 ECS nginx）的 `latest.json` 需手工同步新版本的 apk 名 / sha256 / sizeBytes / versionCode。

## 依赖红线

- `sqlite3` 锁 **2.4.0** + `sqlite3_flutter_libs` **^0.5.41**：0.6.0+ 是空壳桩，**升级即炸，禁止升级**。

## 提示词同步

修改 LLM 提示词必须同步两处：`run_engine.dart` 的 `kFallbackPrompts` + `app/assets/prompts/`（byte-equal 守门测试盯着）。

## 测试守卫约定

依赖私有课程语料 / 金样 fixtures 的测试必须带 **skip-guard**（公开仓库不含 `content/` 与版权金样，缺料时打印 `SKIP:` 后优雅跳过，不算失败）。参考 `extract_pdf_smoke_test.dart` / `corpusSourcesPresent()` 的现有写法。

## 项目背景速查

- local-first 口腔医学间隔复习 App（Flutter/Android，BACKEND=local 默认），MIT 许可；
- 主库 `hengya.db` + 语料库 `corpus/`（corpus.db + progress.json）；
- 详细架构见根 `README.md`，决策记录见 `docs/adr/`。
