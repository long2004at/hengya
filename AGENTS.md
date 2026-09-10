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
3. CI 自动完成：构建 APK → 创建**草稿** Release → 同步 **ECS 通道**（latest.json 上传，连接信息在 Secrets）→ 回写 **GitHub 通道**（`update/latest.json`，apk 为 Release 资产绝对链接）；
4. 人工润色中文发布说明 → 发布 Release。

双更新通道（内容一致，CI 保证同步）：
- **ECS 通道**（国内手机推荐）：URL 含私有 token，**绝不写入公开仓库**；国内用户从维护者处获取。CI 经受限专用密钥（sftp chroot）自动同步
- **GitHub 通道**（海外/备份，国内连通性不稳）：`https://raw.githubusercontent.com/long2004at/hengya/main/update/latest.json`

### 发布签名 Secrets 清单（发版前置条件）

release-android job 的 APK 签名凭据**全部来自 GitHub Secrets**，仓库内不出现任何明文密码：

| Secret | 用途 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | 发布 keystore 文件（base64 全文） |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 存储密码 |
| `ANDROID_KEY_PASSWORD` | 签名 key 私钥密码 |
| `ANDROID_KEY_ALIAS` | 签名 key 别名 |
| `UPDATE_SIGN_KEY` | 更新清单 Ed25519 签名私钥（PEM 全文） |

- 值 = 当前发布 keystore 的真实凭据（维护者自有）；任一 Secret 缺失，打 tag 后 CI 签名 step 会因空密码失败——属预期防护，配置好再发版。
- `UPDATE_SIGN_KEY` 属**更新通道**（latest.json Ed25519 签名，安全修复 B）：值为 `secrets\update_signing_key.pem` 全文；缺失时 CI 两个清单生成 step 显式报错中止（拒绝产出无签名清单，新版 App 会拒收）。
- 可选密钥轮换（换证后用户需卸载重装一次，Android 同签名才能覆盖安装）：
  1. 线下生成新 keystore：`keytool -genkeypair -v -keystore hengya-release.keystore -alias hengya-release -keyalg RSA -keysize 4096 -validity 10000`（store/key 各配一把 `openssl rand -hex 24` 强密码）；
  2. 替换上述四个 Secrets（base64：`base64 -w0 hengya-release.keystore`）；
  3. 新证书首次构建后，把 CI「核对签名证书」step 打印的 ACTUAL 指纹回填 `ci.yml` 的 `EXPECTED`；
  4. 注意 `keytool -list -v` 打印的是 base64 指纹，`ci.yml` 用的是 64-hex（apksigner 格式），以 CI 输出为准，勿手抄转换。

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
