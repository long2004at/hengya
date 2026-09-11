// 完整备份服务：全部数据即时合成，不依赖私有课件/生产快照。
// 测试执行由主代理/CI 统一安排；Windows worker 的 DLL override 由 IsolateRunner 重放。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/services/local/corpus/extract_all.dart'
    show
        schemaChunks,
        schemaVectors,
        schemaMeta,
        schemaState,
        schemaDecks,
        ftsDdl;
import 'package:hengya/services/local/data_maintenance.dart';
import 'package:hengya/services/local/full_backup.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

import 'helpers/synthetic_snapshot.dart';

const _liveKey = 'SYNTHETIC-API-KEY-NOT-A-REAL-CREDENTIAL-987654321';
const _deletedKey = 'SYNTHETIC-DELETED-KEY-HISTORY-123456789';
const _privateUpdate = 'https://updates.invalid/private?token=SYNTHETIC-TOKEN';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }

  late Directory temp;
  late Directory source;
  late FullBackupManager manager;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('hengya_full_backup_test_');
    source = Directory('${temp.path}/source')..createSync();
    final snapshot = await writeSyntheticSnapshot(temp.path);
    File(snapshot).copySync('${source.path}/hengya.db');
    manager = FullBackupManager(busyCheck: () => false);
    await LocalBackend.instance.resetForTest();
  });

  tearDown(() async {
    await LocalBackend.instance.resetForTest();
    expect(DataMaintenance.busy, isFalse, reason: '服务任何异常都必须释放主 isolate 的锁');
    if (temp.existsSync()) await temp.delete(recursive: true);
  });

  test('身份 token 单飞锁只允许所属任务释放', () {
    final token = DataMaintenance.acquire('测试备份');
    try {
      expect(DataMaintenance.busy, isTrue);
      expect(DataMaintenance.operation, '测试备份');
      expect(() => DataMaintenance.acquire('第二任务'), throwsStateError);
      DataMaintenance.release(Object());
      expect(DataMaintenance.busy, isTrue);
    } finally {
      DataMaintenance.release(token);
    }
    expect(DataMaintenance.operation, isNull);
    final next = DataMaintenance.acquire('下一任务');
    DataMaintenance.release(token);
    expect(DataMaintenance.busy, isTrue);
    DataMaintenance.release(next);
  });

  test('忙任务检查与 acquire 均在第一次 await 前完成；重复手动调用不能并发', () async {
    final busy = FullBackupManager(busyCheck: () => true);
    final rejected = busy.createBackup(source.path);
    expect(DataMaintenance.busy, isFalse);
    await expectLater(rejected, throwsA(isA<FullBackupException>()));
    final first = manager.createBackup(source.path);
    expect(DataMaintenance.busy, isTrue);
    await expectLater(
      manager.createBackup(source.path),
      throwsA(isA<FullBackupException>()),
    );
    final summary = await first;
    expect(File(summary.path).existsSync(), isTrue);
    expect(DataMaintenance.busy, isFalse);
    final second = await manager.createBackup(source.path);
    expect(second.path, isNot(summary.path));
    expect(manager.backupsOf(source.path), hasLength(2));
  });

  test('完整包往返：全部主表、向量 BLOB/dim/scale/meta/FTS/镜像/状态及原始文件保持', () async {
    _seedCorpus(source.path);
    _seedSettings(source.path);
    final beforeMain = _rows('${source.path}/hengya.db', [
      'cards',
      'review_logs',
      'subjects',
      'meta',
      'inbox',
      'rework_queue',
      'card_notes',
    ]);
    final beforeCorpus = _rows('${source.path}/corpus/corpus.db', [
      'chunks',
      'vectors',
      'chunk_state',
      'deck_state',
      'meta',
      'vec_chunks',
      'chunks_fts',
      'outline_entries',
    ]);
    final payloads = _persistentSidecars(source.path);
    final summary = await manager.createBackup(
      source.path,
      appVersion: '0.1.11+30',
    );
    expect(summary.cards, 21);
    expect(summary.reviewLogs, 12);
    expect(summary.subjects, 8);
    expect(summary.chunks, 1);
    expect(summary.vectors, 1);
    expect(summary.sourceFiles, 1);
    expect(summary.hasCorpus, isTrue);
    expect(summary.hasProgress, isTrue);
    expect(summary.modelName, 'synthetic-embedding-4');
    expect(summary.fileCount, 7);
    expect(summary.sizeBytes, File(summary.path).lengthSync());
    final manifest =
        jsonDecode(utf8.decode(_zipFiles(summary.path)['backup.json']!)) as Map;
    expect(manifest['kind'], FullBackupManager.kind);
    expect(manifest['schemaVersion'], FullBackupManager.schemaVersion);
    expect(manifest['appVersion'], '0.1.11+30');
    expect(manifest['files'], hasLength(7));
    for (final record in manifest['files'] as List) {
      expect((record as Map)['sha256'], matches(r'^[0-9a-f]{64}$'));
    }
    final validated = await manager.validateBackup(summary.path);
    expect(validated.toMap(), summary.toMap());
    final destination = Directory('${temp.path}/restored');
    final restored = await manager.restoreBackup(
      destination.path,
      summary.path,
    );
    expect(restored.cards, 21);
    expect(
      _rows('${destination.path}/hengya.db', beforeMain.keys.toList()),
      beforeMain,
    );
    expect(
      _rows('${destination.path}/corpus/corpus.db', beforeCorpus.keys.toList()),
      beforeCorpus,
    );
    for (final entry in payloads.entries) {
      expect(
        File('${destination.path}/${entry.key}').readAsBytesSync(),
        entry.value,
      );
    }
    final corpus = sqlite3.open('${destination.path}/corpus/corpus.db');
    try {
      expect(
        corpus.select(
          "SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH 'fixture'",
        ),
        hasLength(1),
      );
      final vector = corpus.select('SELECT * FROM vectors').single;
      expect(vector['dim'], 4);
      expect(vector['vec'], Uint8List.fromList([1, 254, 127, 0]));
      expect(vector['scale'], 0.125);
      expect(
        corpus.select('SELECT v FROM vec_chunks').single['v'],
        Float32List.fromList([0.1, -0.2, 0.3, 0.4]).buffer.asUint8List(),
      );
    } finally {
      corpus.dispose();
    }
    final settings = sqlite3.open('${destination.path}/hengya.db');
    try {
      final values = {
        for (final row in settings.select('SELECT key,value FROM settings'))
          row['key']: row['value'],
      };
      expect(values['embedding.model'], 'synthetic-embedding-4');
      expect(values['embedding.dim'], '4');
      expect(values['llm.endpoint'], 'https://example.invalid/v1');
      expect(values.keys, isNot(contains('llm.apiKey')));
      expect(values.keys, isNot(contains('update.source')));
    } finally {
      settings.dispose();
    }
  });

  test('密钥行与历史空闲页痕迹均不进包，原库逐字节不变', () async {
    _seedSettings(source.path);
    final file = File('${source.path}/hengya.db');
    final original = file.readAsBytesSync();
    expect(latin1.decode(original), contains(_liveKey));
    expect(latin1.decode(original), contains(_deletedKey));
    final summary = await manager.createBackup(source.path);
    final files = _zipFiles(summary.path);
    final mainText = latin1.decode(files['hengya.db']!);
    expect(mainText, isNot(contains(_liveKey)));
    expect(mainText, isNot(contains(_deletedKey)));
    expect(mainText, isNot(contains(_privateUpdate)));
    expect(file.readAsBytesSync(), original);
    expect(
      files.keys.any(
        (name) =>
            name.contains('secrets') ||
            name.endsWith('-wal') ||
            name.endsWith('-shm'),
      ),
      isFalse,
    );
    final originalDb = sqlite3.open(file.path, mode: OpenMode.readOnly);
    try {
      expect(
        originalDb
            .select("SELECT value FROM settings WHERE key='llm.apiKey'")
            .single['value'],
        _liveKey,
      );
      expect(
        originalDb
            .select("SELECT value FROM settings WHERE key='update.source'")
            .single['value'],
        _privateUpdate,
      );
    } finally {
      originalDb.dispose();
    }
  });

  test('旧 WAL 读事务阻挡 checkpoint 时仍备到最新主库与向量提交', () async {
    _seedCorpus(source.path);
    final mainWriter = sqlite3.open('${source.path}/hengya.db');
    final corpusWriter = sqlite3.open('${source.path}/corpus/corpus.db');
    Database? mainReader;
    Database? corpusReader;
    late FullBackupSummary backup;
    try {
      for (final db in [mainWriter, corpusWriter]) {
        db.execute('PRAGMA journal_mode=WAL');
        db.execute('PRAGMA wal_autocheckpoint=0');
      }
      mainReader = sqlite3.open('${source.path}/hengya.db');
      corpusReader = sqlite3.open('${source.path}/corpus/corpus.db');
      mainReader.execute('BEGIN');
      mainReader.select('SELECT count(*) FROM cards');
      corpusReader.execute('BEGIN');
      corpusReader.select('SELECT count(*) FROM vectors');
      mainWriter.execute(
        "UPDATE cards SET front='latest WAL committed card' WHERE id='synth-oms-000'",
      );
      mainWriter.execute(
        "UPDATE meta SET value='999' WHERE key='data_version'",
      );
      corpusWriter.execute('UPDATE vectors SET vec=?, scale=?', [
        Uint8List.fromList([7, 6, 5, 4]),
        0.5,
      ]);
      expect(
        mainWriter.select('PRAGMA wal_checkpoint(TRUNCATE)').first['busy'],
        1,
      );
      expect(
        corpusWriter.select('PRAGMA wal_checkpoint(TRUNCATE)').first['busy'],
        1,
      );
      expect(File('${source.path}/hengya.db-wal').lengthSync(), greaterThan(0));
      expect(
        File('${source.path}/corpus/corpus.db-wal').lengthSync(),
        greaterThan(0),
      );
      backup = await manager.createBackup(source.path);
    } finally {
      mainReader?.dispose();
      corpusReader?.dispose();
      mainWriter.dispose();
      corpusWriter.dispose();
    }
    final restored = '${temp.path}/wal-restored';
    await manager.restoreBackup(restored, backup.path);
    final main = sqlite3.open('$restored/hengya.db');
    final corpus = sqlite3.open('$restored/corpus/corpus.db');
    try {
      expect(
        main
            .select("SELECT front FROM cards WHERE id='synth-oms-000'")
            .single['front'],
        'latest WAL committed card',
      );
      expect(
        main
            .select("SELECT value FROM meta WHERE key='data_version'")
            .single['value'],
        '999',
      );
      expect(
        corpus.select('SELECT vec FROM vectors').single['vec'],
        Uint8List.fromList([7, 6, 5, 4]),
      );
      expect(corpus.select('SELECT scale FROM vectors').single['scale'], 0.5);
    } finally {
      main.dispose();
      corpus.dispose();
    }
  });

  test('无 corpus 的新安装可备份；恢复必须移除旧知识库但保留日志和历史备份', () async {
    final backup = await manager.createBackup(source.path);
    expect(backup.hasCorpus, isFalse);
    expect(backup.hasProgress, isFalse);
    expect(backup.chunks, 0);
    expect(backup.fileCount, 1);
    final target = await _targetWithOldData(temp.path, source.path);
    final log = _write('${target.path}/logs/keep.log', 'keep-log');
    final oldBackup = _write('${target.path}/backups/legacy.db', 'keep-backup');
    await manager.restoreBackup(target.path, backup.path);
    expect(Directory('${target.path}/corpus').existsSync(), isFalse);
    expect(log.readAsStringSync(), 'keep-log');
    expect(oldBackup.readAsStringSync(), 'keep-backup');
  });

  test('仅有未建库 incoming/progress 也原样保留，不假报已有知识库', () async {
    _write(
      '${source.path}/corpus/incoming/demo/source.pdf',
      'synthetic source',
    );
    _write(
      '${source.path}/corpus/progress.json',
      '{"version":1,"subjects":{}}',
    );
    final backup = await manager.createBackup(source.path);
    expect(backup.hasCorpus, isFalse);
    expect(backup.hasProgress, isTrue);
    expect(backup.sourceFiles, 1);
    expect(backup.warnings, isNotEmpty);
    await manager.restoreBackup('${temp.path}/incoming-only', backup.path);
    expect(
      File(
        '${temp.path}/incoming-only/corpus/incoming/demo/source.pdf',
      ).readAsStringSync(),
      'synthetic source',
    );
  });

  test('只保留最新 7 份本服务包；重复手动生成不覆盖，不误删其他文件', () async {
    final unrelated = _write(
      '${source.path}/backups/full/notes.zip',
      'keep zip',
    );
    final similar = _write(
      '${source.path}/backups/full/hengya-full-not-a-backup.zip',
      'keep similar',
    );
    final legacy = _write(
      '${source.path}/backups/hengya-backup-20260101-000000.db',
      'keep db',
    );
    final created = <String>[];
    for (var i = 0; i < 9; i++) {
      created.add((await manager.createBackup(source.path)).path);
    }
    expect(created.toSet(), hasLength(9));
    final kept = manager
        .backupsOf(source.path)
        .map((f) => f.resolveSymbolicLinksSync())
        .toList();
    expect(
      kept,
      created
          .sublist(2)
          .map((p) => File(p).resolveSymbolicLinksSync())
          .toList(),
    );
    expect(File(created.first).existsSync(), isFalse);
    expect(unrelated.readAsStringSync(), 'keep zip');
    expect(similar.readAsStringSync(), 'keep similar');
    expect(legacy.readAsStringSync(), 'keep db');
  });

  test('排除历史语料包、运行标志、执行日志和缓存，不误删原始课件/建库状态', () async {
    _seedCorpus(source.path);
    for (final name in [
      'bak-20260901/corpus.db',
      '.import-tmp-any/corpus.db',
      '.force_run',
      'last_run.json',
      'last_run_weekly.json',
      'logs/execution.jsonl',
      'tmp/work.bin',
      'cache/file.bin',
      'execution.log',
      '.env',
      '.env.local',
      'secrets/credentials.json',
      'progress.json.tmp-123',
      'toc/oms.json.tmp-123',
    ]) {
      _write('${source.path}/corpus/$name', 'excluded synthetic');
    }
    _write('${source.path}/logs/app.log', 'outside corpus');
    _write('${source.path}/exports/previous.zip', 'outside corpus');
    final summary = await manager.createBackup(source.path);
    final names = _zipFiles(summary.path).keys.toSet();
    expect(names, {
      'backup.json',
      'hengya.db',
      'corpus/corpus.db',
      'corpus/progress.json',
      'corpus/chunks.jsonl',
      'corpus/extract_manifest.json',
      'corpus/toc/oms.json',
      'corpus/incoming/oms/demo.pptx',
    });
  });

  test('缺少或损坏数据库不能伪装成成功包', () async {
    final missing = Directory('${temp.path}/missing')..createSync();
    await expectLater(
      manager.createBackup(missing.path),
      throwsA(isA<FullBackupException>()),
    );
    _write('${source.path}/corpus/corpus.db', 'not sqlite');
    await expectLater(
      manager.createBackup(source.path),
      throwsA(isA<FullBackupException>()),
    );
    expect(manager.backupsOf(source.path), isEmpty);
  });

  test('跨设备只重定位已包含的绝对来源路径，保留相对路径及向量内容', () async {
    _seedCorpus(source.path, absolutePaths: true);
    final originalManifest = File(
      '${source.path}/corpus/extract_manifest.json',
    ).readAsBytesSync();
    final backup = await manager.createBackup(source.path);
    final target = '${temp.path}/another-device';
    final result = await manager.restoreBackup(target, backup.path);
    expect(result.rebasedSourcePaths, 2);
    final expected = File(
      '$target/corpus/incoming/oms/demo.pptx',
    ).resolveSymbolicLinksSync();
    final db = sqlite3.open('$target/corpus/corpus.db');
    try {
      expect(
        db.select('SELECT file_path FROM deck_state').single['file_path'],
        expected,
      );
      expect(
        db.select('SELECT vec FROM vectors').single['vec'],
        Uint8List.fromList([1, 254, 127, 0]),
      );
    } finally {
      db.dispose();
    }
    final restored =
        jsonDecode(
              File('$target/corpus/extract_manifest.json').readAsStringSync(),
            )
            as Map;
    expect((restored['files'] as Map).containsKey(expected), isTrue);
    expect(
      File('${source.path}/corpus/extract_manifest.json').readAsBytesSync(),
      originalManifest,
    );
  });

  test('onBeforeSwap 等待期间始终持锁，之前不更换任何现有数据', () async {
    final backup = await manager.createBackup(source.path);
    final target = await _targetWithOldData(temp.path, source.path);
    final old = File('${target.path}/hengya.db').readAsBytesSync();
    final reached = Completer<void>();
    final release = Completer<void>();
    final restore = manager.restoreBackup(
      target.path,
      backup.path,
      onBeforeSwap: () async {
        expect(DataMaintenance.busy, isTrue);
        reached.complete();
        await release.future;
      },
    );
    await reached.future;
    expect(File('${target.path}/hengya.db').readAsBytesSync(), old);
    await expectLater(
      manager.createBackup(source.path),
      throwsA(isA<FullBackupException>()),
    );
    release.complete();
    await restore;
    expect(DataMaintenance.busy, isFalse);
  });

  test('关闭连接回调失败不碰原主库与 corpus，也不留下 journal', () async {
    final backup = await manager.createBackup(source.path);
    final target = await _targetWithOldData(temp.path, source.path);
    final before = _dataBytes(target.path);
    await expectLater(
      manager.restoreBackup(
        target.path,
        backup.path,
        onBeforeSwap: () async => throw StateError('synthetic close failure'),
      ),
      throwsA(isA<FullBackupException>()),
    );
    expect(_dataBytes(target.path), before);
    expect(
      File('${target.path}/.full-restore-journal.json').existsSync(),
      isFalse,
    );
  });

  for (final phase in [
    'journal-written',
    'old-moved:hengya.db',
    'old-moved:corpus',
    'new-main-installed',
    'new-corpus-installed',
    'before-commit',
  ]) {
    test('换库异常 $phase：主库、WAL/SHM 和 corpus 整体回滚', () async {
      _seedCorpus(source.path);
      final backup = await manager.createBackup(source.path);
      final target = await _targetWithOldData(temp.path, source.path);
      _write('${target.path}/hengya.db-wal', 'synthetic-old-wal');
      _write('${target.path}/hengya.db-shm', 'synthetic-old-shm');
      final before = _dataBytes(target.path);
      final failing = FullBackupManager(
        busyCheck: () => false,
        debugRestoreHook: (at) {
          if (at == phase) throw StateError('synthetic rename failure');
        },
      );
      await expectLater(
        failing.restoreBackup(target.path, backup.path),
        throwsA(isA<FullBackupException>()),
      );
      expect(_dataBytes(target.path), before);
      expect(
        File('${target.path}/.full-restore-journal.json').existsSync(),
        isFalse,
      );
    });

    test('进程中断 $phase：启动恢复幂等地还原两套原件', () async {
      _seedCorpus(source.path);
      final backup = await manager.createBackup(source.path);
      final target = await _targetWithOldData(temp.path, source.path);
      final before = _dataBytes(target.path);
      final interrupted = FullBackupManager(
        busyCheck: () => false,
        debugRestoreHook: (at) {
          if (at == phase) throw const FullBackupInterruptedForTest();
        },
      );
      await expectLater(
        interrupted.restoreBackup(target.path, backup.path),
        throwsA(isA<FullBackupInterruptedForTest>()),
      );
      expect(
        File('${target.path}/.full-restore-journal.json').existsSync(),
        isTrue,
      );
      manager.recoverInterruptedRestore(target.path);
      manager.recoverInterruptedRestore(target.path);
      expect(_dataBytes(target.path), before);
      expect(
        File('${target.path}/.full-restore-journal.json').existsSync(),
        isFalse,
      );
    });
  }

  test('全部换入且 commit 已落盘的中断只清理旧件，不回退新数据', () async {
    final backup = await manager.createBackup(source.path);
    final target = await _targetWithOldData(temp.path, source.path);
    final interrupted = FullBackupManager(
      busyCheck: () => false,
      debugRestoreHook: (phase) {
        if (phase == 'before-commit') {
          throw const FullBackupInterruptedForTest();
        }
      },
    );
    await expectLater(
      interrupted.restoreBackup(target.path, backup.path),
      throwsA(isA<FullBackupInterruptedForTest>()),
    );
    final journalFile = File('${target.path}/.full-restore-journal.json');
    final journal = jsonDecode(journalFile.readAsStringSync()) as Map;
    _write('${target.path}/${journal['staging']}/committed', 'committed');
    manager.recoverInterruptedRestore(target.path);
    expect(Directory('${target.path}/corpus').existsSync(), isFalse);
    expect(journalFile.existsSync(), isFalse);
    final db = sqlite3.open('${target.path}/hengya.db');
    try {
      expect(
        db
            .select("SELECT value FROM meta WHERE key='data_version'")
            .single['value'],
        '78',
      );
    } finally {
      db.dispose();
    }
  });

  test('恢复 journal 不接受路径穿越，原库不变且保留现场', () async {
    final before = _dataBytes(source.path);
    _write(
      '${source.path}/.full-restore-journal.json',
      jsonEncode({
        'kind': 'hengya-full-restore',
        'schemaVersion': 1,
        'staging': '../elsewhere',
        'previous': {},
        'hasNewCorpus': false,
      }),
    );
    expect(
      () => manager.recoverInterruptedRestore(source.path),
      throwsA(isA<FullBackupException>()),
    );
    expect(_dataBytes(source.path), before);
    expect(
      File('${source.path}/.full-restore-journal.json').existsSync(),
      isTrue,
    );
  });

  test('损坏、未声明、路径穿越、绝对路径、大小写/精确重复、符号链接全部拒绝且不触碰原数据', () async {
    _seedCorpus(source.path);
    final valid = await manager.createBackup(source.path);
    final target = await _targetWithOldData(temp.path, source.path);
    final before = _dataBytes(target.path);
    final clean = _zipFiles(valid.path);
    final variants = <String, List<int>>{};
    void variant(String name, void Function(Map<String, List<int>>) mutate) {
      final files = {
        for (final entry in clean.entries) entry.key: List<int>.of(entry.value),
      };
      mutate(files);
      variants[name] = _encodeZip(files);
    }

    variant(
      'bad-kind',
      (files) => _editManifest(files, (m) => m['kind'] = 'other'),
    );
    variant(
      'new-version',
      (files) => _editManifest(files, (m) => m['schemaVersion'] = 999),
    );
    variant('missing-file', (files) => files.remove('hengya.db'));
    variant(
      'sha-mismatch',
      (files) =>
          files['corpus/incoming/oms/demo.pptx'] = utf8.encode('tampered'),
    );
    variant(
      'undeclared',
      (files) => files['corpus/incoming/extra.pdf'] = [1, 2],
    );
    variant('traversal', (files) => files['corpus/../../escaped.txt'] = [1]);
    variant('absolute', (files) => files['/absolute.txt'] = [1]);
    variant('windows-absolute', (files) => files[r'C:\outside.txt'] = [1]);
    variant(
      'backslash-traversal',
      (files) => files[r'corpus\..\outside'] = [1],
    );
    variant(
      'case-duplicate',
      (files) => files['corpus/incoming/oms/DEMO.pptx'] = [1],
    );
    variant('device-name', (files) => files['corpus/incoming/NUL.txt'] = [1]);
    variant('ads-name', (files) => files['corpus/incoming/file:stream'] = [1]);
    variant(
      'manifest-duplicate',
      (files) => _editManifest(files, (m) {
        final records = m['files'] as List;
        records.add(Map.of(records.first as Map));
      }),
    );
    final duplicateFiles = {
      ...clean,
      'corpus/incoming/oms/xemo.pptx': [1],
    };
    variants['exact-duplicate'] = _renameZipEntry(
      _encodeZip(duplicateFiles),
      'corpus/incoming/oms/xemo.pptx',
      'corpus/incoming/oms/demo.pptx',
    );
    variants['symlink'] = _encodeZip(
      {...clean, 'corpus/incoming/link': utf8.encode('../../outside')},
      modes: {'corpus/incoming/link': 0xa1ff},
    );
    variants['truncated'] = File(valid.path).readAsBytesSync().sublist(0, 50);
    variants['not-zip'] = utf8.encode('not a zip');
    for (final entry in variants.entries) {
      final file = File('${temp.path}/${entry.key}.zip')
        ..writeAsBytesSync(entry.value);
      var beforeSwapCalled = false;
      await expectLater(
        manager.restoreBackup(
          target.path,
          file.path,
          onBeforeSwap: () async {
            beforeSwapCalled = true;
          },
        ),
        throwsA(isA<FullBackupException>()),
        reason: entry.key,
      );
      expect(beforeSwapCalled, isFalse, reason: entry.key);
      expect(_dataBytes(target.path), before, reason: entry.key);
    }
    expect(File('${temp.path}/escaped.txt').existsSync(), isFalse);
  });

  test('即使重算 SHA，缺主库核心表或 corpus 核心结构仍拒绝', () async {
    _seedCorpus(source.path);
    final valid = await manager.createBackup(source.path);
    final target = await _targetWithOldData(temp.path, source.path);
    final before = _dataBytes(target.path);
    final badDbPath = '${temp.path}/wrong-schema.db';
    final bad = sqlite3.open(badDbPath);
    bad.execute('CREATE TABLE filler(x)');
    bad.dispose();
    for (final name in ['hengya.db', 'corpus/corpus.db']) {
      final files = _zipFiles(valid.path);
      _replaceDeclaredFile(files, name, File(badDbPath).readAsBytesSync());
      final zip = File('${temp.path}/${name.replaceAll('/', '-')}.zip')
        ..writeAsBytesSync(_encodeZip(files));
      await expectLater(
        manager.restoreBackup(target.path, zip.path),
        throwsA(isA<FullBackupException>()),
      );
      expect(_dataBytes(target.path), before);
    }
  });

  test('进度、章节目录或建库清单损坏时，即便SHA匹配也拒绝覆盖现有数据', () async {
    _seedCorpus(source.path);
    final valid = await manager.createBackup(source.path);
    final target = await _targetWithOldData(temp.path, source.path);
    final before = _dataBytes(target.path);
    for (final entry in {
      'corpus/progress.json': '{"subjects":[]}',
      'corpus/toc/oms.json': 'broken-json',
      'corpus/extract_manifest.json': '{"files":[]}',
    }.entries) {
      final files = _zipFiles(valid.path);
      _replaceDeclaredFile(files, entry.key, utf8.encode(entry.value));
      final invalid = File('${temp.path}/bad-metadata.zip')
        ..writeAsBytesSync(_encodeZip(files));
      await expectLater(
        manager.restoreBackup(target.path, invalid.path),
        throwsA(isA<FullBackupException>()),
      );
      expect(_dataBytes(target.path), before);
    }
  });

  test('伪造 ZIP 声明尺寸不能绕过实际流式解压上限', () async {
    final valid = await manager.createBackup(source.path);
    final target = await _targetWithOldData(temp.path, source.path);
    final before = _dataBytes(target.path);
    final files = _zipFiles(valid.path);
    files['hengya.db'] = List<int>.filled(1024 * 1024, 0);
    _editManifest(files, (manifest) {
      final record = (manifest['files'] as List).cast<Map>().firstWhere(
        (r) => r['path'] == 'hengya.db',
      );
      record['size'] = 4;
      record['sha256'] = sha256.convert([0, 0, 0, 0]).toString();
    });
    final encoded = _setZipEntrySize(_encodeZip(files), 'hengya.db', 4);
    final zip = File('${temp.path}/forged-size.zip')..writeAsBytesSync(encoded);
    await expectLater(
      manager.restoreBackup(target.path, zip.path),
      throwsA(isA<FullBackupException>()),
    );
    expect(_dataBytes(target.path), before);
    final huge = _setZipEntrySize(
      _encodeZip(_zipFiles(valid.path)),
      'hengya.db',
      FullBackupManager.maxFileBytes + 1,
    );
    zip.writeAsBytesSync(huge);
    await expectLater(
      manager.validateBackup(zip.path),
      throwsA(isA<FullBackupException>()),
    );
  });

  test('旧无模块虚表及影子表保留；corpus 不经 VACUUM 重建', () async {
    _seedCorpus(source.path);
    final path = '${source.path}/corpus/corpus.db';
    final db = sqlite3.open(path);
    try {
      db.execute('CREATE VIRTUAL TABLE legacy_vec USING fts5(content)');
      db.execute(
        "INSERT INTO legacy_vec(content) VALUES ('synthetic shadow payload')",
      );
      db.execute('PRAGMA writable_schema=ON');
      db.execute(
        "UPDATE sqlite_master SET sql='CREATE VIRTUAL TABLE legacy_vec USING absent_vec0(embedding float[4])' WHERE name='legacy_vec'",
      );
      db.execute('PRAGMA writable_schema=OFF');
    } finally {
      db.dispose();
    }
    final before = _rows(path, [
      'legacy_vec_data',
      'legacy_vec_idx',
      'legacy_vec_content',
      'legacy_vec_docsize',
      'legacy_vec_config',
    ]);
    final backup = await manager.createBackup(source.path);
    final target = '${temp.path}/legacy-restored';
    await manager.restoreBackup(target, backup.path);
    expect(_rows('$target/corpus/corpus.db', before.keys.toList()), before);
    final restored = sqlite3.open('$target/corpus/corpus.db');
    try {
      expect(
        restored
            .select("SELECT sql FROM sqlite_master WHERE name='legacy_vec'")
            .single['sql'],
        contains('absent_vec0'),
      );
    } finally {
      restored.dispose();
    }
  });
}

File _write(String path, String text) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(text, flush: true);
  return file;
}

void _seedSettings(String root) {
  final db = sqlite3.open('$root/hengya.db');
  try {
    db.execute('PRAGMA journal_mode=DELETE');
    db.execute('PRAGMA secure_delete=OFF');
    db.execute('INSERT INTO settings(key,value) VALUES (?,?)', [
      'old.apiKey',
      List.filled(200, _deletedKey).join(),
    ]);
    db.execute("DELETE FROM settings WHERE key='old.apiKey'");
    for (final entry in {
      'llm.apiKey': _liveKey,
      'embedding.APIKEY': 'SYNTHETIC-SECOND-KEY',
      'update.source': _privateUpdate,
      'embedding.model': 'synthetic-embedding-4',
      'embedding.dim': '4',
      'llm.endpoint': 'https://example.invalid/v1',
    }.entries) {
      db.execute('INSERT INTO settings(key,value) VALUES (?,?)', [
        entry.key,
        entry.value,
      ]);
    }
  } finally {
    db.dispose();
  }
}

void _seedCorpus(String root, {bool absolutePaths = false}) {
  Directory('$root/corpus').createSync(recursive: true);
  final sourcePath = absolutePaths
      ? File('$root/corpus/incoming/oms/demo.pptx').absolute.path
      : 'oms/demo.pptx';
  final db = sqlite3.open('$root/corpus/corpus.db');
  try {
    for (final ddl in [
      schemaChunks,
      schemaVectors,
      schemaMeta,
      schemaState,
      schemaDecks,
      ftsDdl,
    ]) {
      db.execute(ddl);
    }
    db.execute(
      'CREATE TABLE vec_chunks(chunk_id TEXT PRIMARY KEY, v BLOB NOT NULL) WITHOUT ROWID',
    );
    db.execute(
      'CREATE TABLE outline_entries(id TEXT PRIMARY KEY, subject_id TEXT, title TEXT, content TEXT)',
    );
    db.execute(
      "INSERT INTO chunks(chunk_id,subject_id,ppt_id,deck,page_start,page_end,title,text) VALUES ('c1','oms','demo','neutral deck',1,2,'fixture','neutral fixture lecture')",
    );
    db.execute('INSERT INTO vectors VALUES (?,?,?,?)', [
      'c1',
      4,
      Uint8List.fromList([1, 254, 127, 0]),
      0.125,
    ]);
    db.execute('INSERT INTO vec_chunks VALUES (?,?)', [
      'c1',
      Float32List.fromList([0.1, -0.2, 0.3, 0.4]).buffer.asUint8List(),
    ]);
    db.execute(
      "INSERT INTO meta VALUES ('embedding_model','synthetic-embedding-4')",
    );
    db.execute("INSERT INTO meta VALUES ('embedding_dim','4')");
    db.execute(
      "INSERT INTO chunk_state VALUES ('c1','synthetic-md5','synthetic-embedding-4',1234.5)",
    );
    db.execute('INSERT INTO deck_state VALUES (?,?,?,?,?,?,?)', [
      'oms',
      'demo',
      'incoming',
      sourcePath,
      'synthetic-md5',
      1,
      '2026-09-11',
    ]);
    db.execute(
      "INSERT INTO chunks_fts VALUES ('c1','fixture','neutral fixture lecture')",
    );
    db.execute(
      "INSERT INTO outline_entries VALUES ('o1','oms','neutral outline','neutral topic')",
    );
  } finally {
    db.dispose();
  }
  _write(
    '$root/corpus/incoming/oms/demo.pptx',
    'synthetic original course bytes',
  );
  _write(
    '$root/corpus/toc/oms.json',
    jsonEncode({
      'subject_id': 'oms',
      'chapters': [
        {'no': 1, 'title': 'neutral chapter'},
      ],
    }),
  );
  _write(
    '$root/corpus/progress.json',
    jsonEncode({
      'subjects': {
        'oms': {
          'learned_through': 3,
          'skipped': [2],
          'history': [
            {'date': '2026-09-10', 'chapter': 3},
          ],
        },
      },
    }),
  );
  _write(
    '$root/corpus/chunks.jsonl',
    '${jsonEncode({'chunk_id': 'c1', 'text': 'neutral fixture lecture'})}\n',
  );
  _write(
    '$root/corpus/extract_manifest.json',
    jsonEncode({
      'version': 1,
      'files': {
        sourcePath: {
          'md5': 'synthetic-md5',
          'subject': 'oms',
          'ppt_id': 'demo',
          'chunk_ids': ['c1'],
        },
      },
    }),
  );
}

Map<String, List<Map<String, Object?>>> _rows(
  String path,
  List<String> tables,
) {
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    return {
      for (final table in tables)
        table: db
            .select('SELECT * FROM "$table"')
            .map((row) => Map<String, Object?>.from(row))
            .toList(),
    };
  } finally {
    db.dispose();
  }
}

Map<String, List<int>> _persistentSidecars(String root) => {
  for (final name in [
    'corpus/progress.json',
    'corpus/chunks.jsonl',
    'corpus/extract_manifest.json',
    'corpus/toc/oms.json',
    'corpus/incoming/oms/demo.pptx',
  ])
    name: File('$root/$name').readAsBytesSync(),
};

Map<String, List<int>> _dataBytes(String root) {
  final result = <String, List<int>>{};
  for (final name in ['hengya.db', 'hengya.db-wal', 'hengya.db-shm']) {
    final file = File('$root/$name');
    if (file.existsSync()) result[name] = file.readAsBytesSync();
  }
  final corpus = Directory('$root/corpus');
  if (corpus.existsSync()) {
    for (final file in corpus.listSync(recursive: true).whereType<File>()) {
      result[file.path.substring(root.length).replaceAll('\\', '/')] = file
          .readAsBytesSync();
    }
  }
  return result;
}

Future<Directory> _targetWithOldData(String temp, String source) async {
  final target = Directory('$temp/target')..createSync();
  File('$source/hengya.db').copySync('${target.path}/hengya.db');
  final db = sqlite3.open('${target.path}/hengya.db');
  db.execute("UPDATE meta SET value='old-device' WHERE key='data_version'");
  db.dispose();
  _seedCorpus(target.path);
  _write('${target.path}/corpus/incoming/old/keep.pdf', 'old device only');
  return target;
}

Map<String, List<int>> _zipFiles(String path) {
  final archive = ZipDecoder().decodeBytes(File(path).readAsBytesSync());
  return {for (final file in archive) file.name: List<int>.from(file.content)};
}

Uint8List _encodeZip(
  Map<String, List<int>> files, {
  Map<String, int> modes = const {},
}) {
  final archive = Archive();
  for (final entry in files.entries) {
    final file = ArchiveFile.bytes(entry.key, entry.value);
    if (modes.containsKey(entry.key)) file.mode = modes[entry.key]!;
    archive.add(file);
  }
  return ZipEncoder().encodeBytes(archive);
}

void _editManifest(
  Map<String, List<int>> files,
  void Function(Map<String, dynamic>) edit,
) {
  final manifest =
      jsonDecode(utf8.decode(files['backup.json']!)) as Map<String, dynamic>;
  edit(manifest);
  files['backup.json'] = utf8.encode(jsonEncode(manifest));
}

void _replaceDeclaredFile(
  Map<String, List<int>> files,
  String name,
  List<int> content,
) {
  files[name] = content;
  _editManifest(files, (manifest) {
    final record = (manifest['files'] as List).cast<Map>().firstWhere(
      (r) => r['path'] == name,
    );
    record['size'] = content.length;
    record['sha256'] = sha256.convert(content).toString();
  });
}

Uint8List _renameZipEntry(Uint8List input, String oldName, String newName) {
  final data = Uint8List.fromList(input);
  expect(utf8.encode(oldName).length, utf8.encode(newName).length);
  _visitZipEntry(data, oldName, (header, localOffset, centralOffset) {
    data.setRange(
      localOffset + 30,
      localOffset + 30 + utf8.encode(newName).length,
      utf8.encode(newName),
    );
    data.setRange(
      centralOffset + 46,
      centralOffset + 46 + utf8.encode(newName).length,
      utf8.encode(newName),
    );
  });
  return data;
}

Uint8List _setZipEntrySize(Uint8List input, String name, int size) {
  final data = Uint8List.fromList(input);
  _visitZipEntry(data, name, (header, localOffset, centralOffset) {
    header.setUint32(localOffset + 22, size, Endian.little);
    header.setUint32(centralOffset + 24, size, Endian.little);
  });
  return data;
}

void _visitZipEntry(
  Uint8List bytes,
  String name,
  void Function(ByteData, int, int) update,
) {
  final view = ByteData.sublistView(bytes);
  final eocd = bytes.length - 22; // 测试编码器没有 ZIP comment。
  var cursor = view.getUint32(eocd + 16, Endian.little);
  final count = view.getUint16(eocd + 10, Endian.little);
  for (var i = 0; i < count; i++) {
    final nameLength = view.getUint16(cursor + 28, Endian.little);
    final found = utf8.decode(
      bytes.sublist(cursor + 46, cursor + 46 + nameLength),
    );
    if (found == name) {
      update(view, view.getUint32(cursor + 42, Endian.little), cursor);
      return;
    }
    cursor +=
        46 +
        nameLength +
        view.getUint16(cursor + 30, Endian.little) +
        view.getUint16(cursor + 32, Endian.little);
  }
  fail('合成 ZIP 缺少待修改条目 $name');
}
