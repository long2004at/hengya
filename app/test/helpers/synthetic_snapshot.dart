// 合成迁移快照生成器（开源脱敏，2026-09-06）：
// 替代历史上的生产快照 fixture（fixtures/migration/hengya-pregoal-20260906.db
// ——含真实个人学习数据，真实件已移出仓库工作区，见 content/private-backups/）。
// 测试期在临时目录即时生成与生产库同 schema、同规模的中性演示库——
// 迁移链路（validateSource → importDatabase → reload → 端上全功能）的测试
// 价值完整保留；且日志日期相对「现在」计算，滑动窗口类断言（7 日
// totalReviews / streak「今日未复习不打断昨日」）永不失效——真实静态
// 快照本身就是时序炸弹：日志日期固定 2026-09-04/05，隔天 streak 归零、
// 7 天后窗口掉出，测试必然转红。
//
// 基线规模（与原生产快照逐项一致——e2e_local_journey / data_manager /
// ui_button_sweep 三套件的断言锚点，改动须三处同步）：
//   cards 21（13 active / 7 rejected / 1 rework / 0 pending）
//   review_logs 12（-1d×5 / -2d×3 / -3d×2 / -5d×2——全在 7 日窗内，
//     且「今天未复习时昨日必有日志」→ streak >= 1 恒成立）
//   subjects 8（7 个标准课程短码 + 1 个用户自建风格科目 demo1234）
//   rework_queue 8 条 pending（7 rejected 各登记一条 + 1 rework 一条）
//   meta.data_version = '78'（模拟既有学习历史的数据版本水位）
//   settings / inbox / card_notes 留空（零密钥、零个人信息）
//
// 经 [Db] 公共 API 构建——schema 与 server/lib/src/db.dart 逐字节同源，
// 零 DDL 复制零漂移。宿主 sqlite3.dll 覆盖由各测试文件自行完成
// （overrideForAll 进程级生效）。
import 'dart:io';

import 'package:hengya/services/local/db.dart';
import 'package:shared/hengya_shared.dart';

/// 在 [dirPath] 下生成 `hengya-synthetic-snapshot.db`，返回文件路径。
///
/// 用例体内 await 调用（内部纯同步 SQLite 写 + [Db.open] 的微任务级
/// Future——plain test 与 testWidgets 假异步纪律下均安全）。
/// testWidgets 套件禁止在 setUp/tearDown 内 await：请移入用例体首行。
Future<String> writeSyntheticSnapshot(String dirPath) async {
  final path = '$dirPath/hengya-synthetic-snapshot.db';
  final db = await Db.open(path);
  try {
    // ── 8 科：7 个标准课程短码 + 1 个用户自建风格科目（中性名）──
    // surg 必须名「口腔颌面外科学」（ui_button_sweep 按名点科目卡进复习
    // 会话 + 题库筛选胶囊）；oms 供 e2e/data_manager/sweep 的 queue 断言。
    const subjects = [
      ('oms', '口腔黏膜病学'),
      ('endo', '牙体牙髓病学'),
      ('perio', '牙周病学'),
      ('pros', '口腔修复学'),
      ('surg', '口腔颌面外科学'),
      ('pedo', '儿童口腔医学'),
      ('ortho', '口腔正畸学'),
      ('demo1234', '演示自建课程'),
    ];
    for (final (id, name) in subjects) {
      db.insertSubject(id: id, name: name);
    }

    // ── 21 卡（中性演示内容，编号自增保证题干唯一）──
    var seq = 0;
    FlashCard synth(String id, String subjectId, CardStatus status) =>
        FlashCard(
          id: id,
          subjectId: subjectId,
          type: CardType.basic,
          front: '【合成演示】题干 ${++seq}：本卡为中性演示内容',
          back: '【合成演示】答案 $seq（合成库不包含任何真实学习数据）',
          anchor: '演示课件 p$seq',
          source: '合成演示数据',
          status: status,
          tags: const ['演示'],
        );

    // 13 active：importCard 落 m_due_at=生成时刻 → 全部即刻到期
    //（queue?subject=oms / sweep 复习会话四档评分的断言基础）。
    const activeBySubject = {
      'oms': 4,
      'surg': 4,
      'endo': 2,
      'perio': 2,
      'pros': 1,
    };
    final activeIds = <String>[];
    for (final e in activeBySubject.entries) {
      for (var i = 0; i < e.value; i++) {
        final id = 'synth-${e.key}-${i.toString().padLeft(3, '0')}';
        db.importCard(synth(id, e.key, CardStatus.active));
        activeIds.add(id);
      }
    }

    // 7 rejected：每张登记一条回炉队列（reason 前缀「审核拒绝：」），
    // 与 1 rework 合计 8 条 pending——对齐原快照 rework_queue=8。
    const rejectedBySubject = {
      'endo': 2,
      'perio': 2,
      'pros': 1,
      'pedo': 1,
      'ortho': 1,
    };
    for (final e in rejectedBySubject.entries) {
      for (var i = 0; i < e.value; i++) {
        final id = 'synth-rej-${e.key}-${i.toString().padLeft(3, '0')}';
        db.importCard(synth(id, e.key, CardStatus.rejected));
        db.rejectCardWithReason(id, '答案有误（合成演示）', '合成演示批注');
      }
    }
    // 1 rework：active 卡出队进回炉（reworkCard 同时置状态 + 登记队列）。
    final reworkId = 'synth-rework-001';
    db.importCard(synth(reworkId, 'demo1234', CardStatus.active));
    db.reworkCard(reworkId, '表述绕（合成演示）', '合成演示批注');

    // ── 12 复习日志：相对 now 整日回退（-1d/-2d/-3d/-5d）──
    // 整日 Duration 保证「昨天」恒有日志（当前时刻无论早晚，now-24h 必落
    // 在昨日）——streak 断言永不失效；四档评分齐备（again/hard/good/easy）
    // 供保留率/热力图有料。
    const logDays = [1, 1, 1, 1, 1, 2, 2, 2, 3, 3, 5, 5];
    const logRatings = [
      ReviewRating.good,
      ReviewRating.good,
      ReviewRating.hard,
      ReviewRating.good,
      ReviewRating.easy,
      ReviewRating.again,
      ReviewRating.good,
      ReviewRating.hard,
      ReviewRating.good,
      ReviewRating.good,
      ReviewRating.easy,
      ReviewRating.good,
    ];
    for (var i = 0; i < logDays.length; i++) {
      final cardId = activeIds[i % activeIds.length];
      db.insertReviewLog(
        cardId: cardId,
        subjectId: cardId.split('-')[1],
        rating: logRatings[i],
        reviewedAt: DateTime.now().subtract(Duration(days: logDays[i])),
        latencyMs: 4200 + i * 137,
        offlineQueued: false,
        stateBefore: SchedulingState.review,
        stateAfter: SchedulingState.review,
        stabilityAfter: 3.0 + i * 0.7,
        intervalDays: 1.0 + i * 0.8,
      );
    }

    // ── data_version = 78：对齐原快照水位（e2e 断言导入后 '78'、
    // 写操作 bump 后 > 78、导出往返保持）。
    for (var i = 0; i < 78; i++) {
      db.bumpDataVersion();
    }
  } finally {
    db.close(); // 最后一个连接关闭：WAL 自动 checkpoint 收编单文件
  }
  // 防御性清理伴生件（正常 close 后不应存在；存在即删，保证
  // validateSource 只读打开的必是单文件完整库）。
  for (final suffix in const ['-wal', '-shm']) {
    final f = File('$path$suffix');
    if (f.existsSync()) f.deleteSync();
  }
  return path;
}
