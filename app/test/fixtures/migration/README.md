# 本目录现状（开源脱敏，2026-09-06）

历史上的迁移 fixture（`hengya-pregoal-20260906.db`，生产服务器
2026-09-06 `.backup` 产物）**含真实个人学习数据**，已按开源决策移出：

- 仓库内不再存在任何二进制快照（该文件从未被 git 跟踪——`*.db`
  忽略规则早已生效，历史提交仅误收过 `-wal/-shm` 伴生件且已清除）。
- 三个依赖它的测试（`e2e_local_journey_test.dart` /
  `data_manager_test.dart` / `ui_button_sweep_test.dart`）已改为
  **测试期即时生成合成快照**：见 `test/helpers/synthetic_snapshot.dart`
  （同 schema、同规模、中性演示内容；日志日期相对「现在」计算，
  滑动窗口断言永不失效）。
- 真实快照的机内备份位置：`content/private-backups/`（`content/` 整体
  gitignored，不入公开库）；确认合成链路稳定后可自行删除。
