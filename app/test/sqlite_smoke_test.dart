// sqlite3 宿主 smoke：验证 Windows 测试宿主 + test/sqlite3.dll 可用性
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as so;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    so.open
        .overrideForAll(() => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  test('内存库建表读写', () {
    final db = sqlite3.openInMemory();
    db.execute('CREATE TABLE t(id TEXT PRIMARY KEY, v INTEGER)');
    db.execute('INSERT INTO t VALUES (?, ?)', ['a', 1]);
    final rows = db.select('SELECT * FROM t');
    expect(rows.first['v'], 1);
    db.dispose();
  });

  test('磁盘库 WAL + 迁移同构（hengya.db 头部语义）', () {
    final dir =
        Directory.systemTemp.createTempSync('hengya_sqlite_smoke_');
    final path = '${dir.path}\\hengya.db';
    final db = sqlite3.open(path);
    db.execute('PRAGMA journal_mode = WAL;');
    db.execute('PRAGMA foreign_keys = ON;');
    db.execute('CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)');
    db.execute("INSERT OR IGNORE INTO meta (key, value) VALUES ('data_version', '0')");
    db.execute("UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'data_version'");
    final v = db.select("SELECT value FROM meta WHERE key = 'data_version'").first['value'];
    expect(v, '1');
    db.dispose();
    dir.deleteSync(recursive: true);
  });
}
