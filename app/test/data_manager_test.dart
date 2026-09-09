// 数据管理验证（Phase 2）：导入校验/原子替换/导出 checkpoint/48h 滚动备份
// + 合成快照端到端迁移验证（helpers/synthetic_snapshot.dart 测试期生成，
// 开源脱敏 2026-09-06 起替代原生产快照：21 卡/12 日志/8 科/data_version=78）。
// 迁移链路 = 用户主通道，此套件是生产数据在端上可用的硬保证。
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/local/data_manager.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

import 'helpers/synthetic_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open
        .overrideForAll(() => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  late Directory tmp;
  final dm = DataManager.instance;
  // 合成快照路径（setUp 期生成于 tmp 内；开源脱敏，2026-09-06）
  late String snapshotPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hengya_dm_test_');
    snapshotPath = await writeSyntheticSnapshot(tmp.path);
    await LocalBackend.instance.resetForTest();
  });

  tearDown(() async {
    await LocalBackend.instance.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('校验（validateSource）', () {
    test('生产快照：schema 合格，统计与服务器基线一致', () {
      final stats = dm.validateSource(snapshotPath);
      expect(stats['cards'], 21);
      expect(stats['activeCards'], 13);
      expect(stats['reviewLogs'], 12);
      expect(stats['subjects'], 8);
      expect(stats['dataVersion'], '78');
    });

    test('非 SQLite 文件 → 明确报错不崩溃', () {
      final junk = File('${tmp.path}/junk.db')
        ..writeAsStringSync('this is not a database at all');
      expect(
        () => dm.validateSource(junk.path),
        throwsA(isA<DataManagerException>()),
      );
    });

    test('缺核心表的库 → 报「不是恒牙数据库」', () {
      // 造一个合法 SQLite 但空 schema 的库（执行 DDL 强制落盘——open 后
      // 不写任何内容时 SQLite 惰性建库，文件保持 0 字节）
      final empty = '${tmp.path}/empty.db';
      final db = sqlite3.sqlite3.open(empty);
      db.execute('CREATE TABLE filler(x)');
      db.dispose();
      expect(
        () => dm.validateSource(empty),
        throwsA(isA<DataManagerException>()
            .having((e) => e.message, 'msg', contains('不是恒牙数据库'))),
      );
    });

    test('文件不存在 / 空文件 → 报错', () {
      expect(() => dm.validateSource('${tmp.path}/ghost.db'),
          throwsA(isA<DataManagerException>()));
      final empty = File('${tmp.path}/zero.db')..writeAsBytesSync([]);
      expect(() => dm.validateSource(empty.path),
          throwsA(isA<DataManagerException>()));
    });
  });

  group('导入（importDatabase）', () {
    test('空库导入生产快照 → 端上即可见全部生产数据（迁移主通道）', () async {
      // 现状：本地空库 + 打开过（产生 -wal/-shm 残留的常见场景）
      LocalBackend.instance.init(tmp.path);
      final subs0 = await LocalBackend.instance.get('/subjects');
      expect((subs0['subjects'] as List).length, 0); // 0.3.1 新库零科目

      final stats = await dm.importDatabase(
        tmp.path,
        snapshotPath,
        onBeforeSwap: () => LocalBackend.instance.reload(),
      );
      expect(stats['cards'], 21);

      // reload 后生产数据完整可见
      final subs = await LocalBackend.instance.get('/subjects');
      final ids = (subs['subjects'] as List)
          .cast<Map<String, dynamic>>()
          .map((s) => s['id'])
          .toList();
      expect(ids.length, 8);
      expect(ids, contains('demo1234')); // 用户自建风格科目随迁（合成）
      // active 13 张到期（合成库 m_due_at=生成时刻 → 全部即刻到期）
      final q = await LocalBackend.instance
          .get('/cards/queue?subject=oms');
      expect((q['cards'] as List), isNotEmpty);
      // 题库 21 张全可见（search 只排 pending；active 13/rejected 7/
      // rework 1 都可查——对照 db.searchCards 契约）
      final bank = await LocalBackend.instance.get('/cards/search?limit=200');
      expect(bank['total'], 21);
      // data_version 随迁
      final meta = await LocalBackend.instance.get('/meta/version');
      expect(meta['data_version'], '78');
      // 复习日志 → streak 有值
      final streak = await LocalBackend.instance.get('/stats/streak');
      expect(streak['streak'], greaterThanOrEqualTo(1));
      // rework 队列 8 条
      final rq = await LocalBackend.instance.get('/cards/rework/pending');
      expect((rq['queue'] as List), isNotEmpty);
    });

    test('导入失败不碰原库（非法文件 → 原数据完好）', () async {
      LocalBackend.instance.init(tmp.path);
      // 原库写入一张卡（0.3.1 新库零科目：先自建科目再导卡）
      await LocalBackend.instance.post('/subjects', {'name': '世界历史', 'id': 'oms'});
      await LocalBackend.instance.importCards([
        {'id': 'keep-1', 'subjectId': 'oms', 'type': 'basic',
         'front': 'f', 'back': 'b', 'anchor': 'a', 'source': 's',
         'status': 'pending'},
      ]);
      final junk = File('${tmp.path}/junk.db')
        ..writeAsStringSync('junk junk junk');
      await expectLater(
        dm.importDatabase(tmp.path, junk.path,
            onBeforeSwap: () => LocalBackend.instance.reload()),
        throwsA(isA<DataManagerException>()),
      );
      // 原库数据仍在
      final pending = await LocalBackend.instance.get('/cards/pending');
      expect((pending['list'] as List).length, 1);
      // tmp 残件自清
      expect(File('${tmp.path}/hengya.db.import-tmp').existsSync(), false);
    });
  });

  group('导出（exportDatabase）', () {
    test('导出 → 单文件完整 → 可再导入（往返保持）', () async {
      LocalBackend.instance.init(tmp.path);
      await LocalBackend.instance.post('/subjects', {'name': '基础化学', 'id': 'endo'});
      await LocalBackend.instance.importCards([
        {'id': 'exp-1', 'subjectId': 'endo', 'type': 'basic',
         'front': '往返题干', 'back': '往返答案', 'anchor': 'a', 'source': 's',
         'status': 'pending'},
      ]);
      // 触发 WAL 有内容（写入后未 checkpoint）
      final out = dm.exportDatabase(tmp.path);
      expect(File(out).existsSync(), true);
      expect(out, contains('exports/hengya-2'));

      // 导出件本身完整可导入到新目录
      final tmp2 = await Directory.systemTemp.createTemp('hengya_dm2_');
      addTearDown(() => tmp2.delete(recursive: true));
      final stats = dm.validateSource(out);
      expect(stats['cards'], 1);
      await dm.importDatabase(tmp2.path, out);
      expect(dm.validateSource(dm.dbPathOf(tmp2.path))['cards'], 1);
    });
  });

  group('自动备份（autoBackupIfNeeded）', () {
    test('首调备份、48h 内二调跳过', () async {
      LocalBackend.instance.init(tmp.path);
      await LocalBackend.instance.get('/health'); // 触发惰性建库落盘
      expect(dm.autoBackupIfNeeded(tmp.path), true);
      expect(Directory('${tmp.path}/backups').listSync().length, 1);
      // 无写入间隔二调 → 不重复备份
      expect(dm.autoBackupIfNeeded(tmp.path), false);
      expect(dm.backupsOf(tmp.path).length, 1);
    });

    test('滚动保留 7 份（最老先删）', () async {
      LocalBackend.instance.init(tmp.path);
      await LocalBackend.instance.get('/health'); // 触发惰性建库落盘
      // 直接造 8 个历史备份文件（含真实 db 头）
      final dir = Directory('${tmp.path}/backups')..createSync(recursive: true);
      final dbPath = dm.dbPathOf(tmp.path);
      for (var i = 1; i <= 8; i++) {
        final f = File(dbPath).copySync(
            '${dir.path}/hengya-backup-2026010$i-000000.db');
        f.setLastModifiedSync(DateTime(2026, 1, i)); // 伪造历史时间
      }
      expect(dm.autoBackupIfNeeded(tmp.path), true); // 最新备份 01-08 很旧
      final after = dm.backupsOf(tmp.path);
      expect(after.length, 7); // 8 旧 + 1 新 = 9 → 删最老 2
      // 最老两份（0101/0102）已删
      expect(after.any((f) => f.path.contains('20260101')), false);
      expect(after.any((f) => f.path.contains('20260102')), false);
      expect(after.any((f) => f.path.contains('20260108')), true);
    });

    test('无库不备份（冷启动安全）', () {
      expect(dm.autoBackupIfNeeded(tmp.path), false);
    });
  });
}
