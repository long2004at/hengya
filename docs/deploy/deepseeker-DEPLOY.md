# deeperseeker 部署文档（2026-10-11）

## 架构
App → https://47.100.82.115.nip.io:8443/v1 (TLS+Bearer) → nginx(8443, stream ssl_preread 分流)
→ [TLS] 127.0.0.1:2443 (nginx http ssl 终结) → 127.0.0.1:4000 (deeperseeker, systemd)
→ [明文HTTP] 127.0.0.1:18443 (App 更新通道 heng-update.conf，原样保留)

## 组件与文件
- /opt/deeperseeker        AmanCode22/deeperseeker v6.0（git clone，af80242）
  - .venv/                 uv 管理的 CPython 3.13.16 + 依赖（uv sync --frozen）
  - .env                   DEEPSEEKER_API_KEY / ADMIN 凭据（chmod 600）
  - deeperseeker.db        token 池 + 会话签名（sqlite，重启不丢）
- /etc/systemd/system/deeperseeker.service   常驻服务（MemoryMax=300M，开机自启）
- /etc/nginx/nginx.conf    顶部 load_module stream；末尾 stream{8443 ssl_preread 分流}
- /etc/nginx/conf.d/chat-deepseeker.conf    TLS 终结 2443 → 4000
- /etc/nginx/conf.d/heng-update.conf        更新通道（listen 已改 127.0.0.1:18443）
- /etc/nginx/ssl/chat.crt|.key   自签证书 10 年（CN=47.100.82.115.nip.io）
  SHA256 指纹: 3E:5E:57:76:9A:DA:9D:19:6A:5D:EC:37:E0:2F:E6:6B:F0:6C:17:B1:09:60:F6:39:A1:D4:AA:8F:6F:DB:39:E7

## 为什么不是 443 + Let's Encrypt
阿里云安全组未放行 80/443（2026-09-07 起），8443 已放行且被更新通道占用。
方案：stream ssl_preread 在 8443 上按"是否 TLS 握手"分流，明文→更新通道，TLS→聊天。
证书为自签 10 年，App 端做证书指纹 pinning（更新通道 URL 与行为零改动）。

## 运维命令
```
systemctl status|restart|stop deeperseeker
journalctl -u deeperseeker -n 50          # 日志（journald 自动轮转）
curl -s http://127.0.0.1:4000/health      # 本机健康检查（ok=token池有活token）
```

## 换/加 DeepSeek 网页 token
1. 无痕窗口登录 chat.deepseek.com → F12 控制台: `JSON.parse(localStorage.getItem("userToken")).value`
2. 服务器执行（ADMINPW 见 .env）:
```
curl -s -c /tmp/ck -X POST http://127.0.0.1:4000/login \
  --data-urlencode "username=hengadmin" --data-urlencode "password=$ADMINPW"
curl -s -b /tmp/ck -X POST http://127.0.0.1:4000/tokens/add \
  --data-urlencode "auth_token=<新token>" --data-urlencode "alias=probe-N"
```
封号/限流由 deeperseeker 自动冷却与切换（429 冷却 60s，重试 3 次）。

## 升级 deeperseeker
```
cd /opt/deeperseeker && git pull
UV_DEFAULT_INDEX=https://mirrors.aliyun.com/pypi/simple/ UV_HTTP_TIMEOUT=45 \
  UV_CONCURRENT_DOWNLOADS=2 /root/.local/bin/uv sync --frozen
systemctl restart deeperseeker
```

## 已知风险
- DeepSeek 风控可能升级 → 双通道 App 自动退回官方 API
- 小号封号风险自担 → token 池可扩
- 自签证书轮换需同步 App 发版（App 内置指纹）
