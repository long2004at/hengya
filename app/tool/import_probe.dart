// 恒牙（hengya）· 导入链路实证探针（2026-09-06 真机排查落地；随工具集保留：
// 任意 hengya.db 快照均可验「导入 → Db.open 迁移 → 各页查询」应显数字）
// ============================================================================
// 重放「hengya.db 导入成功 → LocalBackend 首次 open（含幂等迁移）→ 各页查询」
// 全链，回答：真机导入后 App 各页面此刻应显示什么数字。
//   1. 把生产快照拷到系统临时目录（源文件只读不动）；
//   2. Db.open（与真机首开完全同一条迁移路径）；
//   3. 逐项跑 LocalBackend GET 使用的 db.* 查询 + 原始 SQL 状态直方图/日期范围。
// 用法（cwd=app/；Windows 自动加载 test/sqlite3.dll）：
//   dart run tool/import_probe.dart <hengya.db 路径>
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/services/local/db.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/import_probe.dart <hengya.db>');
    exitCode = 2;
    return;
  }
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
        () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }
  final src = File(args[0]);
  if (!src.existsSync()) {
    stderr.writeln('源库不存在: ${args[0]}');
    exitCode = 2;
    return;
  }
  final tmp = Directory.systemTemp.createTempSync('hengya-import-probe');
  final dst = File('${tmp.path}${Platform.pathSeparator}hengya.db');
  src.copySync(dst.path);
  stdout.writeln('probe db: ${dst.path} (${src.lengthSync()} B)');

  final db = await Db.open(dst.path); // ← 迁移在此发生（真机导入后首开同路径）

  stdout.writeln('== 迁移后基线 ==');
  stdout.writeln('data_version = ${db.dataVersion}（预期 78）');
  final subjects = db.subjectRows();
  stdout.writeln('subjects = ${subjects.length}');
  for (final s in subjects) {
    stdout.writeln('  ${s['id']} | ${s['name']}');
  }
  stdout.writeln('dueCounts = ${db.dueCounts()}');
  stdout.writeln('pendingCards = ${db.pendingCards().length}（预期 0）');
  stdout.writeln('reworkPending = ${db.reworkPending().length}（预期 8）');
  final (cards, total) =
      db.searchCards(subject: null, q: null, offset: 0, limit: 200);
  stdout.writeln('searchCards total = $total / 本页 ${cards.length}（题库口径）');
  stdout.writeln('streakDays = ${db.streakDays()}');
  stdout.writeln('statsSummary(7d) = ${db.statsSummary(days: 7)}');
  final heat = db.heatmapDays(days: 84);
  stdout
      .writeln('heatmap(84d) = ${heat.length} 天；前 3 格样本 ${heat.take(3).toList()}');

  stdout.writeln('== 原始 SQL 直方图（独立连接） ==');
  final raw = sqlite3.open(dst.path);
  try {
    for (final r
        in raw.select('SELECT status, COUNT(*) AS n FROM cards GROUP BY status')) {
      stdout.writeln('cards[${r['status']}] = ${r['n']}');
    }
    for (final r in raw.select('SELECT m_state, COUNT(*) AS n FROM cards GROUP BY m_state')) {
      stdout.writeln('m_state[${r['m_state']}] = ${r['n']}');
    }
    final due = raw.select(
        "SELECT MIN(m_due_at) AS mn, MAX(m_due_at) AS mx FROM cards WHERE status = 'active'")
        .first;
    stdout.writeln(
        "active m_due_at 范围: ${due['mn']} ~ ${due['mx']}（现在 ${DateTime.now()}）");
    final dueNow = raw.select(
            "SELECT COUNT(*) AS n FROM cards WHERE status = 'active' AND m_due_at <= ?",
            [DateTime.now().toIso8601String()])
        .first['n'];
    stdout.writeln('（宽松口径）active 卡 m_due_at <= 现在 的张数 = $dueNow');
    stdout.writeln(
        'review_logs = ${raw.select('SELECT COUNT(*) AS n FROM review_logs').first['n']}（预期 12）');
    stdout.writeln(
        '最后复习时间 = ${raw.select('SELECT MAX(reviewed_at) AS m FROM review_logs').first['m']}');
    stdout.writeln(
        'inbox 总/pending = ${raw.select('SELECT COUNT(*) AS n FROM inbox').first['n']} / ${raw.select('SELECT COUNT(*) AS n FROM inbox WHERE consumed_at IS NULL').first['n']}');
    stdout.writeln(
        'settings 行数 = ${raw.select('SELECT COUNT(*) AS n FROM settings').first['n']}');
  } finally {
    raw.dispose();
  }

  db.close();
  stdout.writeln('== 探针完成（迁移零异常） ==');
}
