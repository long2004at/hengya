# ADR-0004 · 部署形态：本地交叉编译 + 精简运行镜像（服务器零编译）

日期：2026-09-04 ｜ 状态：已定稿（修正 ADR-0002 部署注记与 §13.4 「不在服务器编译」的实现方式）

## 决策

服务端产物在**本地 Windows 交叉编译**：`dart compile exe bin/server.dart --target-os linux --target-arch x64` → scp 上服务器 → 精简运行镜像（仅二进制 + 运行时依赖）。**服务器上不做任何编译**。

## 修正记录

此前结论「Dart 不支持交叉编译」为**双重误判**：

1. **能力误判**：Dart 3.8 起 `dart compile exe` 支持 `--target-os/--target-arch`（当前 SDK 3.12.2 实测可用）
2. **根因误判**：当时报错 `PathNotFoundException: d:\d\hengya` 与交叉编译无关——Git Bash 把 `/d/hengya` 传给 dart 时按 `/` 开头解析为 `d:\d\hengya`。改用 Windows 原生路径 `D:/hengya/...` 立即成功

## 理由

1. **内存**：服务器仅 964Mi 可用。原 Docker 方案在服务器上跑 `dart compile`（AOT 高峰 >1Gi）有 OOM 风险；本地编译后服务器零负担
2. **磁盘**：磁盘 72% 已用（剩 11G）。省去 ~1GB 的 dart:3.12 构建镜像层
3. **链路**：7.8MB 二进制 scp 秒级；服务器只跑 `docker compose up`（免 build）或 systemd 直跑二进制

## 取舍

- 交叉编译产物无法在本地 Windows 直接运行验证 → 上服务器后先 `/health` 冒烟再对外
- AOT 平台差异风险接受（shelf/sqlite3 无平台 API 分支；`dart:io` Linux 目标成熟）

## 运行形态

服务器侧仍用 Docker 承载（利用已有的 compose 日志轮转/重启策略/资源限制），但镜像分两层：

- **产物层**：`deploy/Dockerfile.runtime`——精简运行镜像（debian-slim + ca-certificates + wget + sqlite3 + 二进制），服务器本地 `docker build` 仅装几个 apt 包，秒级完成
- **回退**：万一交叉编译链有问题，仓库保留原 `server/Dockerfile`（服务器构建）作为回退路径

## 关联文档同步

- 计划书 §13.4「代码部署到服务器」行：实现方式改为「本地交叉编译产物 → scp → 运行镜像」
- 计划书 §2 约束行「Docker 容器部署」语义不变（仍是容器承载），只是构建位置从服务器移到本地
