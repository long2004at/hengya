# 恒牙应用内更新 · 阿里云 ECS 部署指南（唯一分发通道）

> **适用场景**：你自己有一台 2C2G 阿里云 ECS（能 SSH 登录即可），作为恒牙 APK 的**唯一**分发源。
>
> **口径（已拍板）**：IP + 端口 + HTTP 直链即可——**免域名、免备案、免 HTTPS**。个人自用场景，随机长路径（token）足以防扫描；将来想升级域名 + HTTPS 也不影响 App（更新源随时可在设置页改）。
>
> **App 端填法**：设置 → 应用内更新 → 「更新源」填
> `http://<ECS-IP>:8080/heng-<token>/latest.json`
> （`<token>` 按下文第 2 步生成，`<ECS-IP>` 是你 ECS 的公网 IP。）

---

## 一、一次性部署（三条命令级）

### 第 1 步：装 nginx

SSH 登录 ECS 后执行：

```bash
apt update && apt install -y nginx
```

（Ubuntu/Debian 系；阿里云主机一般都装过 nginx，重复执行无害。）

### 第 2 步：生成随机 token + 写站点配置

```bash
TOKEN=$(openssl rand -hex 16)
echo "你的随机 token 是：$TOKEN"   # ← 抄下来！App 更新源 URL 要用
mkdir -p /var/www/heng-update

cat > /etc/nginx/sites-available/heng-update <<EOF
server {
    listen 8080;
    server_name _;
    autoindex off;
    location /heng-$TOKEN/ {
        alias /var/www/heng-update/;
    }
}
EOF

ln -sf /etc/nginx/sites-available/heng-update /etc/nginx/sites-enabled/heng-update
nginx -t && systemctl reload nginx
```

说明：`autoindex off` 关目录列表；路径前缀 `/heng-<token>/` 是随机的 32 位十六进制——扫描者猜不到路径就拿不到包，这就是「免 HTTPS 也够用」的全部安全逻辑。

### 第 3 步：阿里云安全组放行 8080/tcp

阿里云控制台 → ECS 实例 → 安全组 → 入方向规则 → 手动添加：

| 协议类型 | 端口范围 | 授权对象 |
| --- | --- | --- |
| TCP | 8080 | 0.0.0.0/0 |

（想更紧可把授权对象填你家宽带的公网 IP；个人自用一般全网放行即可。）

### （可选）scp 直传目录权限

如果你不是 root 登录，让上传目录归你的登录用户所有（scp 直传 `/var/www/heng-update` 需要）：

```bash
sudo chown -R <你的用户> /var/www/heng-update
```

### 验证（任意能上网的机器）

```bash
curl http://<ECS-IP>:8080/heng-<token>/latest.json
# 应返回 404 以外的 JSON（首次部署还没上传文件，上传后见下文验证）
```

---

## 二、从 Windows 发布新版本（日常流程）

1. **改代码**，并把 `app/pubspec.yaml` 的 `version:` 升一档，例如 `1.6.2+14` → `1.7.0+15`。
   **注意**：`+` 后面的 build 号必须严格递增——App 只认 `versionCode`（就是这个 build 号）判断谁新，不递增手机上永远「已是最新」。
2. （可选）写更新说明：任意 UTF-8 的 `.md` 文本文件（可多行），发布时会进 `latest.json` 的 `notes`。
3. 首次先准备部署配置（已配过跳过）：

```powershell
copy D:\heng\tools\deploy.config.example.json D:\heng\tools\deploy.config.json
# 用记事本打开 deploy.config.json，填 host（ECS 公网 IP）、user（登录用户）、
# sshPort、remoteDir（默认 /var/www/heng-update 不用改）。此文件已 gitignore，不会进仓库。
```

4. 发布（在 `D:\heng` 下执行）：

```powershell
powershell -ExecutionPolicy Bypass -File tools\release_build.ps1
powershell -ExecutionPolicy Bypass -File tools\release_build.ps1 -NotesFile D:\heng\update-dist\notes.md
```

脚本自动完成：构建 release APK → 复制为 `update-dist\heng-<版本>-local-release.apk` → 算 SHA-256/大小 → 生成 `update-dist\latest.json`（UTF-8 无 BOM）→ `scp -P <sshPort>` 上传 APK + latest.json 到 ECS。

5. 发布后验证：

```bash
curl http://<ECS-IP>:8080/heng-<token>/latest.json
curl -o /dev/null -w "%{http_code} %{size_download}\n" \
  http://<ECS-IP>:8080/heng-<token>/heng-<版本>-local-release.apk
```

第一条应返回完整 JSON；第二条应返回 `200` 与 APK 字节数。

6. **手机上**：设置 → 应用内更新 → 检查更新 → 「下载并安装」。
   首次安装会要求授「安装未知应用」权限：App 会引导跳系统授权页，勾选「允许来自此来源的应用」后返回再点一次即可。

---

## 三、latest.json 契约（发布脚本生成，勿手写）

```json
{
  "versionName": "1.7.0+15",
  "versionCode": 15,
  "apk": "heng-1.7.0+15-local-release.apk",
  "sha256": "<64 位十六进制>",
  "sizeBytes": 80530636,
  "date": "2026-09-07T12:00:00Z",
  "notes": "更新说明（可多行）"
}
```

App 端语义：

- **versionCode** 大于当前安装版本才提示更新；相等/更旧一律「已是最新」（降级拒绝）。
- **apk** 为相对 latest.json 所在目录的**纯文件名**（App 自动拼接完整 URL；禁止路径分隔符，防穿越）。
- **sha256** 不匹配 → App 拒绝安装并删除已下载文件（防篡改/防半截包）。
- **notes** 仅展示；**sizeBytes** 用于进度条与大小展示（缺失也能下载，进度转不确定态）。

---

## 四、维护与安全口径

- **磁盘**：每个版本一个 APK（约 80MB），留在 `/var/www/heng-update/` 下；定期 `ls` 看一眼、删旧包即可。`latest.json` 指向谁，App 就装谁——删旧 APK 不影响已发版本。
- **备份与迁移**：整套「分发服务」只有 nginx 静态目录 + 一段 site 配置，无状态无数据库。换 ECS 时把 `/var/www/heng-update/` 拷走 + 重跑第一部分三条命令即可；token 换了的话，记得改手机上的更新源 URL。
- **安全性**：无目录列表 + 随机长路径，包不会被扫到；HTTP 明文在「个人自用、内容仅为公开 APK」场景下可接受。SHA-256 校验保证手机拿到的包和发布的包逐字节一致（防 CDN/链路损坏，也防中途篡改内容）。
- **不用改 App**：以后升版本只是「改 pubspec 版本号 → 跑脚本 → 手机点检查更新」，全程不需要动 App 代码。

---

## 五、App 端源 URL 填法示例

```
http://47.98.xx.xx:8080/heng-3f9c2ab57de84112a6b0c1d2e3f4a5b6/latest.json
```

- `47.98.xx.xx` = 你的 ECS 公网 IP
- `3f9c2ab57de84112a6b0c1d2e3f4a5b6` = 第 2 步 `openssl rand -hex 16` 生成的 token
- 填入后点「检查更新」即连通；源 URL 持久化在本地数据库，下次进设置页自动回显。
