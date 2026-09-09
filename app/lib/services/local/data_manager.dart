// 数据管理（Phase 2，local-first）：一人一机一库的文件级生命周期。
//
// 导入（生产 hengya.db → 端上迁移主通道）：
//   1. 只读校验源库 schema（必需表齐全 + cards 可查 + meta.data_version
//      可读），返回数据统计供 UI 二次确认（「将导入 21 张卡…」）；
//   2. 关闭在用连接（[LocalBackend.reload]）；
//   3. 原子替换：源 → hengya.db.import-tmp → 删旧 db/-wal/-shm → rename；
//      任何失败不碰原库（tmp 先行、rename 最后）。
//   注意：源必须是单文件完整库——服务器 `sqlite3 .backup` 产物、或导出件；
//   若从运行中的 WAL 库裸拷 .db（不带 -wal）会丢尾部写入，校验会读出
//   正常但数据偏旧（无从检测，UI 文案已提示「请使用完整备份文件」）。
//
// 导出：wal_checkpoint(TRUNCATE) 后拷贝到 exports/hengya-<ts>.db，
//   单文件完整（可直接再导入/传给他人）；settings 表 *.apiKey 已剥离
//   （2026-09-06 审计 P1-1：密钥绝不随导出件离开本机）。
//
// 自动备份：冷启动调用 [autoBackupIfNeeded]——距最近备份 ≥48h 则备份一份
//   到 backups/hengya-backup-<ts>.db，滚动保留最新 7 份（最老先删）。
//
// 路径布局（与 LocalBackend 约定一致）：dataDir/{hengya.db, backups/,
// exports/, corpus/}。所有方法纯同步文件操作（SQLite 调用为毫秒级），
// 测试直接传临时目录即可。
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

class DataManagerException implements Exception {
  DataManagerException(this.message);

  final String message;

  @override
  String toString() => 'DataManagerException: $message';
}

class DataManager {
  DataManager._();

  static final DataManager instance = DataManager._();

  /// 迁移契约必需表（对照 db.dart 迁移全集；settings 为 0.3.0+，老库缺表
  /// 由导入后 LocalBackend 首次 open 的幂等迁移自动补——此处只验核心 6 表）
  static const _requiredTables = [
    'meta',
    'subjects',
    'cards',
    'review_logs',
    'rework_queue',
    'inbox',
  ];

  static const maxBackups = 7;
  static const backupInterval = Duration(hours: 48);
  static const _dbFileName = 'hengya.db';
  static const _backupsDirName = 'backups';
  static const _exportsDirName = 'exports';

  String dbPathOf(String dataDir) => '$dataDir/$_dbFileName';

  // ---------------- 校验 ----------------

  /// 只读校验源库并返回统计（导入预览用）：
  /// {cards, activeCards, reviewLogs, subjects, dataVersion, journalMode}。
  /// 不满足契约抛 [DataManagerException]（文件不存在/不是 SQLite/缺表/坏数据）。
  Map<String, Object?> validateSource(String sourcePath) {
    final src = File(sourcePath);
    if (!src.existsSync()) {
      throw DataManagerException('文件不存在：$sourcePath');
    }
    if (src.lengthSync() == 0) {
      throw DataManagerException('文件为空');
    }
    Database? db;
    try {
      db = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
      final names = {
        for (final r in db.select(
            "SELECT name FROM sqlite_master WHERE type='table'"))
          r['name'] as String,
      };
      final missing = _requiredTables.where((t) => !names.contains(t));
      if (missing.isNotEmpty) {
        throw DataManagerException(
            '不是恒牙数据库（缺表：${missing.join('、')}）');
      }
      final journal = (db
              .select('PRAGMA journal_mode')
              .first
              .values
              .first ?? '') as String;
      final cards =
          db.select('SELECT COUNT(*) AS n FROM cards').first['n'] as int;
      final active = db.select(
              "SELECT COUNT(*) AS n FROM cards WHERE status = 'active'")
          .first['n'] as int;
      final logs =
          db.select('SELECT COUNT(*) AS n FROM review_logs').first['n'] as int;
      final subjects =
          db.select('SELECT COUNT(*) AS n FROM subjects').first['n'] as int;
      String? dataVersion;
      try {
        dataVersion = db.select(
                "SELECT value FROM meta WHERE key = 'data_version'")
            .firstOrNull?['value'] as String?;
      } catch (_) {}
      return {
        'cards': cards,
        'activeCards': active,
        'reviewLogs': logs,
        'subjects': subjects,
        'dataVersion': dataVersion ?? '?',
        'journalMode': journal,
      };
    } on DataManagerException {
      rethrow;
    } on SqliteException catch (e) {
      throw DataManagerException('不是合法的 SQLite 文件：${e.message}');
    } finally {
      db?.dispose();
    }
  }

  // ---------------- 导入 ----------------

  /// 原子替换当前库（须先 [validateSource] 校验；onBeforeSwap 供调用方在
  /// 关闭在用连接后、文件替换前做收尾）。返回导入统计。
  ///
  /// 失败语义：任何一步失败都抛异常且不破坏原库（tmp 临时文件残留会自清）。
  Future<Map<String, Object?>> importDatabase(
    String dataDir,
    String sourcePath, {
    Future<void> Function()? onBeforeSwap,
  }) async {
    final stats = validateSource(sourcePath); // 再验一次（文件可能在预览后被换）
    final dbPath = dbPathOf(dataDir);
    final tmp = File('$dbPath.import-tmp');
    if (tmp.existsSync()) tmp.deleteSync();
    try {
      tmp.writeAsBytesSync(File(sourcePath).readAsBytesSync());
      await onBeforeSwap?.call(); // 调用方关闭在用连接（LocalBackend.reload）
      // 删旧库三件套（-wal/-shm 若存在；replaceSync 直接覆盖也行，但先删
      // 更稳——Windows 上 rename 不允许目标存在时行为依平台）
      final wal = File('$dbPath-wal');
      final shm = File('$dbPath-shm');
      if (dbPath.startsWith(dataDir) && File(dbPath).existsSync()) {
        File(dbPath).deleteSync();
      }
      if (wal.existsSync()) wal.deleteSync();
      if (shm.existsSync()) shm.deleteSync();
      tmp.renameSync(dbPath);
    } catch (e) {
      if (tmp.existsSync()) tmp.deleteSync(); // 失败自清，不留残件
      rethrow;
    }
    return stats;
  }

  // ---------------- 导出 ----------------

  /// 导出单文件完整库到 exports/hengya-<时间戳>.db，返回导出路径。
  /// 先对在用库 wal_checkpoint(TRUNCATE)（多连接同库：checkpoint 需写锁，
  /// 在用连接空闲时正常完成）。
  /// 安全闸（2026-09-06 审计 P1-1）：导出件用于分享/传他人，settings 表的
  /// *.apiKey 明文密钥绝不随导出件离开本机——复制后剥离并 VACUUM 压实，
  /// 剥离失败则删除导出件并报错（宁可失败，绝不带 key 出门）。
  /// 本机库与 backups/ 自动备份不动（同机同安全域）。
  String exportDatabase(String dataDir) {
    final dbPath = dbPathOf(dataDir);
    if (!File(dbPath).existsSync()) {
      throw DataManagerException('本地数据库不存在（尚未初始化）');
    }
    Database? db;
    try {
      db = sqlite3.open(dbPath);
      db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } on SqliteException catch (e) {
      throw DataManagerException('导出前 checkpoint 失败：${e.message}');
    } finally {
      db?.dispose();
    }
    final dir = Directory('$dataDir/$_exportsDirName')
      ..createSync(recursive: true);
    final ts = _timestamp(DateTime.now());
    final out = File('${dir.path}/hengya-$ts.db');
    File(dbPath).copySync(out.path);
    Database? scrub;
    try {
      scrub = sqlite3.open(out.path);
      scrub.execute("DELETE FROM settings WHERE key LIKE '%.apiKey'");
      scrub.execute('VACUUM');
    } catch (_) {
      try {
        scrub?.dispose();
      } catch (_) {}
      if (out.existsSync()) out.deleteSync();
      throw DataManagerException('导出失败：密钥剥离异常，本次导出已取消');
    }
    scrub.dispose();
    return out.path;
  }

  // ---------------- 自动备份 ----------------

  /// 冷启动自动备份：距最近一份备份 ≥48h（或无备份）则新备一份，
  /// 滚动保留 [maxBackups] 份（最老先删）。返回本次是否执行了备份。
  bool autoBackupIfNeeded(String dataDir) {
    final dbPath = dbPathOf(dataDir);
    if (!File(dbPath).existsSync()) return false;
    final dir = Directory('$dataDir/$_backupsDirName');
    final existing = _backupFiles(dir);
    if (existing.isNotEmpty) {
      final newest = existing.last; // 已按文件名升序 = 时间序
      final newestTime = newest.lastModifiedSync();
      if (DateTime.now().difference(newestTime) < backupInterval) {
        return false; // 48h 内已有备份
      }
    }
    dir.createSync(recursive: true);
    // checkpoint（同导出）保证单文件完整
    Database? db;
    try {
      db = sqlite3.open(dbPath);
      db.execute('PRAGMA wal_checkpoint(TRUNCATE);');
    } finally {
      db?.dispose();
    }
    final ts = _timestamp(DateTime.now());
    File(dbPath).copySync('${dir.path}/hengya-backup-$ts.db');
    _pruneBackups(dir);
    return true;
  }

  /// 备份清单（时间升序）供 UI 展示「最近备份 / 份数」
  List<File> backupsOf(String dataDir) =>
      _backupFiles(Directory('$dataDir/$_backupsDirName'));

  List<File> _backupFiles(Directory dir) {
    if (!dir.existsSync()) return const [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.db'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  void _pruneBackups(Directory dir) {
    final files = _backupFiles(dir);
    final excess = files.length - maxBackups;
    for (var i = 0; i < excess; i++) {
      files[i].deleteSync(); // 最老先删
    }
  }

  static String _timestamp(DateTime t) =>
      '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
      '-${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}${t.second.toString().padLeft(2, '0')}';
}
