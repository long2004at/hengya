// 恒牙完整学习数据备份。格式 v1：backup.json + hengya.db + corpus/ 持久项。
// 不遍历数据根目录（尤其不访问 secrets/），不复制裸 WAL，不修改源库或 vault。
// SQLite online backup 保留虚表及影子表；仅主库副本用 secure_delete + VACUUM
// 去除密钥及空闲页残留，corpus 永不 VACUUM（旧 vec0 模块可能不在本端）。
//
// archive 4.2.0 的 ZipEncoder / ZLibDecoder 部分路径会聚合整文件，不能用于
// 大库。下面的 ZIP32 编解码使用 dart:io 分块 zlib + 直接写盘的 sink；只有
// 有上限的目录和 JSON 元数据进入内存。明确拒绝 ZIP64/分卷/加密包。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart' show getCrc32;
import 'package:crypto/crypto.dart';

import 'package:sqlite3/sqlite3.dart';

import 'corpus_package.dart';
import 'data_maintenance.dart';
import 'isolate_runner.dart';
import 'local_backend.dart';
import 'pipeline_runner.dart';

class FullBackupException implements Exception {
  const FullBackupException(this.message);
  final String message;
  @override
  String toString() => 'FullBackupException: $message';
}

class FullBackupSummary {
  const FullBackupSummary({
    required this.path,
    required this.createdAt,
    required this.sizeBytes,
    required this.fileCount,
    required this.cards,
    required this.reviewLogs,
    required this.subjects,
    required this.chunks,
    required this.vectors,
    required this.sourceFiles,
    required this.hasCorpus,
    required this.hasProgress,
    required this.modelName,
    this.warnings = const [],
    this.rebasedSourcePaths = 0,
  });

  final String path;
  final DateTime createdAt;
  final int sizeBytes;

  /// 数据文件数，不包含 backup.json 自身。
  final int fileCount;
  final int cards;
  final int reviewLogs;
  final int subjects;
  final int chunks;
  final int vectors;
  final int sourceFiles;

  /// 是否实际含 corpus.db（只有待建库 incoming/ 的情况为 false）。
  final bool hasCorpus;
  final bool hasProgress;
  final String modelName;
  final List<String> warnings;
  final int rebasedSourcePaths;

  factory FullBackupSummary.fromMap(Map<String, Object?> map) =>
      FullBackupSummary(
        path: map['path'] as String,
        createdAt: DateTime.parse(map['createdAt'] as String),
        sizeBytes: map['sizeBytes'] as int,
        fileCount: map['fileCount'] as int,
        cards: map['cards'] as int,
        reviewLogs: map['reviewLogs'] as int,
        subjects: map['subjects'] as int,
        chunks: map['chunks'] as int,
        vectors: map['vectors'] as int,
        sourceFiles: map['sourceFiles'] as int,
        hasCorpus: map['hasCorpus'] as bool,
        hasProgress: map['hasProgress'] as bool,
        modelName: map['modelName'] as String,
        warnings: List<String>.from(map['warnings'] as List? ?? const []),
        rebasedSourcePaths: map['rebasedSourcePaths'] as int? ?? 0,
      );

  Map<String, Object?> toMap() => {
    'path': path,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'sizeBytes': sizeBytes,
    'fileCount': fileCount,
    'cards': cards,
    'reviewLogs': reviewLogs,
    'subjects': subjects,
    'chunks': chunks,
    'vectors': vectors,
    'sourceFiles': sourceFiles,
    'hasCorpus': hasCorpus,
    'hasProgress': hasProgress,
    'modelName': modelName,
    'warnings': warnings,
    'rebasedSourcePaths': rebasedSourcePaths,
  };
}

/// 仅故障注入测试使用：模拟进程在 rename 后终止，留下 journal 供启动恢复。
/// 生产没有 debugRestoreHook，因此不会走此分支。
class FullBackupInterruptedForTest implements Exception {
  const FullBackupInterruptedForTest();
}

class FullBackupManager {
  FullBackupManager({bool Function()? busyCheck, this.debugRestoreHook})
    : _busyCheck = busyCheck ?? _defaultBusyCheck;

  static final instance = FullBackupManager();
  static const maxBackups = 7;
  static const kind = 'hengya-full-backup';
  static const schemaVersion = 1;

  // ZIP32 的明确资源边界。实测输出逐块计数，不能只信任 ZIP/manifest 尺寸。
  static const maxFileBytes = 2 * 1024 * 1024 * 1024;
  static const maxTotalBytes = 8 * 1024 * 1024 * 1024;
  static const maxZipBytes = 0xffffffff - 65536;
  static const maxFiles = 20000;
  static const maxManifestBytes = 8 * 1024 * 1024;
  static const maxDirectoryBytes = 32 * 1024 * 1024;

  final bool Function() _busyCheck;
  final void Function(String phase)? debugRestoreHook;
  static int _jobSequence = 0;

  static bool _defaultBusyCheck() =>
      PipelineRunner.instance.running ||
      LocalBackend.instance.corpusBuildRunning ||
      CorpusPackageManager.instance.importRunning;

  Object _acquire(String operation) {
    // 必须在 acquire 和第一次 await 之前检查；worker 的 static 锁不共享。
    if (_busyCheck()) {
      throw const FullBackupException('拆卡、建库或导入正在进行，请完成后再备份或恢复');
    }
    if (DataMaintenance.busy) {
      throw FullBackupException('正在${DataMaintenance.operation}，请稍后再试');
    }
    return DataMaintenance.acquire(operation);
  }

  Future<FullBackupSummary> createBackup(
    String dataDir, {
    String? appVersion,
    void Function(String message)? onProgress,
  }) async {
    final token = _acquire('完整备份');
    try {
      final root = _dataRoot(dataDir);
      _requireNoRestoreJournal(root);
      return FullBackupSummary.fromMap(
        await _worker('create', {
          'dataDir': root,
          'sourceDataDir': Directory(dataDir).absolute.path,
          'appVersion': appVersion,
        }, onProgress),
      );
    } on FullBackupException {
      rethrow;
    } catch (_) {
      throw const FullBackupException('完整备份失败，请检查可用空间和数据文件');
    } finally {
      DataMaintenance.release(token);
    }
  }

  Future<FullBackupSummary> validateBackup(
    String zipPath, {
    void Function(String message)? onProgress,
  }) async => FullBackupSummary.fromMap(
    await _worker('validate', {
      'zipPath': File(zipPath).absolute.path,
    }, onProgress),
  );

  Future<FullBackupSummary> restoreBackup(
    String dataDir,
    String zipPath, {
    Future<void> Function()? onBeforeSwap,
    void Function(String message)? onProgress,
  }) async {
    final token = _acquire('恢复完整备份');
    Directory? staging;
    String? root;
    try {
      root = _dataRoot(dataDir, create: true);
      _requireNoRestoreJournal(root);
      staging = Directory('$root/.full-restore-${_nonce()}')..createSync();
      final result = await _worker('stage-restore', {
        'dataDir': root,
        'zipPath': File(zipPath).absolute.path,
        'staging': staging.path,
      }, onProgress);
      // 完整校验、解包、路径重定位都完成后才允许关闭连接、触碰现有数据。
      await onBeforeSwap?.call();
      _notify(onProgress, '校验通过，正在安全切换学习数据');
      _swapRestore(root, staging, debugRestoreHook);
      _notify(onProgress, '完整学习数据已恢复');
      return FullBackupSummary.fromMap(result);
    } on FullBackupInterruptedForTest {
      rethrow;
    } on FullBackupException {
      rethrow;
    } catch (_) {
      throw const FullBackupException('恢复失败，原数据未替换或已回滚');
    } finally {
      // journal 存在时绝不删暂存区：里面可能是仅存的旧主库/知识库。
      if (staging != null && root != null && !_journalFile(root).existsSync()) {
        _tryDeleteDirectory(staging);
      }
      DataMaintenance.release(token);
    }
  }

  /// 仅本服务发布的 ZIP，升序；不会返回/删除既有自动 .db 备份或其他文件。
  List<File> backupsOf(String dataDir) => _listBackups(dataDir);

  /// 启动时在打开任何 SQLite 连接之前调用。未 commit 的事务一律回滚；
  /// commit 已落盘的事务只清理旧件。回滚可反复运行，中断后仍可继续。
  /// 若 journal 损坏或原件缺失，明确抛错并保留所有现场，不能继续静默开库。
  void recoverInterruptedRestore(String dataDir) {
    if (!_journalFile(dataDir).existsSync()) return;
    final token = _acquire('修复中断的恢复');
    try {
      _recoverRestore(_dataRoot(dataDir));
    } finally {
      DataMaintenance.release(token);
    }
  }

  static Future<Map<String, Object?>> _worker(
    String action,
    Map<String, Object?> args,
    void Function(String)? onProgress,
  ) async {
    try {
      final handle = await IsolateRunner.instance.start<Map<String, Object?>>(
        jobId: 'full-backup-$action-${++_jobSequence}',
        workerEntry: fullBackupWorkerEntry,
        args: {'action': action, ...args},
      );
      final subscription = handle.progress.listen(
        (event) => _notify(onProgress, event.message),
      );
      try {
        return await handle.done;
      } finally {
        await subscription.cancel();
      }
    } on IsolateJobException catch (error) {
      const prefix = 'FullBackupException: ';
      throw FullBackupException(
        error.message.startsWith(prefix)
            ? error.message.substring(prefix.length)
            : '备份包处理失败，请检查文件和可用空间',
      );
    } on FullBackupException {
      rethrow;
    } catch (_) {
      throw const FullBackupException('无法完成备份后台任务，请稍后再试');
    }
  }
}

void fullBackupWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (context) async {
    final args = Map<String, Object?>.from(boot.args as Map);
    void progress(String message) => context.emit(
      IsolateProgressEvent(stage: args['action'] as String, message: message),
    );
    try {
      switch (args['action']) {
        case 'create':
          return await _createBackup(
            args['dataDir'] as String,
            args['appVersion'] as String?,
            progress,
            args['sourceDataDir'] as String,
          );
        case 'validate':
          final temp = Directory.systemTemp.createTempSync(
            'hengya-full-check-',
          );
          try {
            return _validateAndExtract(
              args['zipPath'] as String,
              temp,
              progress,
            ).summary.toMap();
          } finally {
            _tryDeleteDirectory(temp);
          }
        case 'stage-restore':
          final next = Directory('${args['staging']}/new')..createSync();
          final checked = _validateAndExtract(
            args['zipPath'] as String,
            next,
            progress,
          );
          progress('正在处理跨设备课件路径');
          final rebase = _rebaseSourcePaths(
            next.path,
            args['dataDir'] as String,
            checked.sourceDataDir,
            checked.files.keys.toSet(),
          );
          // 重定位只改已验证的暂存件；改后再查库，之后才交给主 isolate 换入。
          _inspectData(next.path, checked.files.keys.toList());
          return {
            ...checked.summary.toMap(),
            'rebasedSourcePaths': rebase.$1,
            'warnings': [...checked.summary.warnings, ...rebase.$2],
          };
        default:
          throw const FullBackupException('不支持的备份任务');
      }
    } on FullBackupException {
      rethrow;
    } catch (_) {
      // 不把数据库异常中的 SQL、设置值或 JSON 原文带进 UI/日志。
      throw const FullBackupException('备份包处理失败：文件损坏、被占用或空间不足');
    }
  });
}

const _chunkSize = 64 * 1024;
const _manifestName = 'backup.json';
const _restoreSlots = ['hengya.db', 'hengya.db-wal', 'hengya.db-shm', 'corpus'];
final _backupName = RegExp(r'^hengya-full-\d{8}-\d{12}-[0-9a-f]{24}\.zip$');
final _shaPattern = RegExp(r'^[0-9a-f]{64}$');

void _notify(void Function(String)? callback, String message) {
  // 进度展示异常不能打断已提交的恢复，也不能泄漏锁。
  try {
    callback?.call(message);
  } catch (_) {}
}

String _nonce() {
  final random = Random.secure();
  return List.generate(
    12,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

String _timestamp(DateTime time) {
  String pad(int n, int width) => n.toString().padLeft(width, '0');
  return '${pad(time.year, 4)}${pad(time.month, 2)}${pad(time.day, 2)}-'
      '${pad(time.hour, 2)}${pad(time.minute, 2)}${pad(time.second, 2)}'
      '${pad(time.millisecond, 3)}${pad(time.microsecond, 3)}';
}

FileSystemEntityType _type(String path) =>
    FileSystemEntity.typeSync(path, followLinks: false);

String _dataRoot(String path, {bool create = false}) {
  if (path.trim().isEmpty) throw const FullBackupException('数据目录不能为空');
  final directory = Directory(path).absolute;
  if (create && _type(directory.path) == FileSystemEntityType.notFound) {
    directory.createSync(recursive: true);
  }
  if (_type(directory.path) != FileSystemEntityType.directory) {
    throw const FullBackupException('数据目录不存在或不是普通目录');
  }
  return directory.resolveSymbolicLinksSync();
}

Directory _plainDirectory(String path) {
  final type = _type(path);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.directory) {
    throw const FullBackupException('备份目录不能是符号链接或文件');
  }
  return Directory(path)..createSync();
}

void _requireFile(String path) {
  if (_type(path) != FileSystemEntityType.file ||
      File(path).lengthSync() == 0) {
    throw const FullBackupException('必需的数据文件不存在、为空或不是普通文件');
  }
}

void _tryDeleteDirectory(Directory directory) {
  try {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  } catch (_) {
    // 清理失败不反向破坏已经发布/恢复的数据；仅遗留本服务隔离目录。
  }
}

List<File> _listBackups(String root) {
  final dir = Directory('$root/backups/full');
  if (_type('$root/backups') != FileSystemEntityType.directory ||
      _type(dir.path) != FileSystemEntityType.directory) {
    return [];
  }
  final result = dir.listSync(followLinks: false).whereType<File>().where((
    file,
  ) {
    final name = file.uri.pathSegments.last;
    return _backupName.hasMatch(name);
  }).toList();
  result.sort((a, b) => a.path.compareTo(b.path));
  return result;
}

bool _persistentCorpusPath(String relative) {
  final parts = relative.toLowerCase().split('/');
  final first = parts.first;
  final leaf = parts.last;
  // 不读取密钥目录和 CLI 环境密钥文件；保留未知的持久语料/向量附属文件。
  if (parts.contains('secrets') || leaf == '.env' || leaf.startsWith('.env.')) {
    return false;
  }
  if (first.startsWith('bak-') || first.startsWith('.import-tmp-')) {
    return false;
  }
  if (const [
    'tmp',
    'temp',
    'cache',
    'logs',
    'log',
    'backups',
    '.force_run',
  ].contains(first)) {
    return false;
  }
  if (RegExp(r'^last_run.*\.json$').hasMatch(first)) return false;
  if (first.endsWith('.log') ||
      first.endsWith('.log.jsonl') ||
      RegExp(r'\.tmp(?:[-.]|$)').hasMatch(leaf) ||
      leaf.endsWith('.part')) {
    return false;
  }
  if (const [
    'corpus.db-wal',
    'corpus.db-shm',
    'corpus.db-journal',
  ].contains(first)) {
    return false;
  }
  return true;
}

Map<String, File> _scanCorpus(String root) {
  final directory = Directory('$root/corpus');
  if (_type(directory.path) == FileSystemEntityType.notFound) return {};
  if (_type(directory.path) != FileSystemEntityType.directory) {
    throw const FullBackupException('知识库目录不能是符号链接或文件');
  }
  final files = <String, File>{};
  void visit(Directory dir, String prefix) {
    for (final entity in dir.listSync(followLinks: false)) {
      final leaf = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final name = prefix.isEmpty ? leaf : '$prefix/$leaf';
      if (!_persistentCorpusPath(name)) continue;
      _checkArchivePath('corpus/$name');
      if (entity is Directory) {
        visit(entity, name);
      } else if (entity is File) {
        files['corpus/$name'] = entity;
        if (files.length >= FullBackupManager.maxFiles) {
          throw const FullBackupException('持久数据文件过多，超过备份包安全上限');
        }
      } else {
        throw const FullBackupException('持久数据包含符号链接，无法安全备份');
      }
    }
  }

  visit(directory, '');
  return Map.fromEntries(
    files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

bool _sameStat(FileStat a, FileStat b) =>
    a.type == b.type &&
    a.size == b.size &&
    a.modified == b.modified &&
    a.changed == b.changed;

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

class _DirectByteSink extends ByteConversionSink {
  _DirectByteSink(this.consume);
  final void Function(List<int>) consume;
  @override
  void add(List<int> chunk) => consume(chunk);
  @override
  void close() {}
}

class _FileRecord {
  const _FileRecord(this.path, this.size, this.digest, this.modifiedMs);
  final String path;
  final int size;
  final String digest;
  final int modifiedMs;
  Map<String, Object?> toMap() => {
    'path': path,
    'size': size,
    'sha256': digest,
    'modifiedMs': modifiedMs,
  };
}

_FileRecord _fingerprint(File file, String name, {File? copyTo}) {
  final before = file.statSync();
  if (before.type != FileSystemEntityType.file ||
      before.size > FullBackupManager.maxFileBytes) {
    throw const FullBackupException('数据文件不是普通文件或超过单文件 2 GiB 上限');
  }
  copyTo?.parent.createSync(recursive: true);
  final input = file.openSync();
  final output = copyTo?.openSync(mode: FileMode.write);
  final digest = _DigestSink();
  final hash = sha256.startChunkedConversion(digest);
  var size = 0;
  try {
    while (true) {
      final bytes = input.readSync(_chunkSize);
      if (bytes.isEmpty) break;
      size += bytes.length;
      if (size > before.size || size > FullBackupManager.maxFileBytes) {
        throw const FullBackupException('备份时文件发生变化，请稍后重试');
      }
      hash.add(bytes);
      output?.writeFromSync(bytes);
    }
    hash.close();
    output?.flushSync();
  } finally {
    input.closeSync();
    output?.closeSync();
  }
  if (size != before.size || !_sameStat(before, file.statSync())) {
    throw const FullBackupException('备份时文件发生变化，请稍后重试');
  }
  copyTo?.setLastModifiedSync(before.modified);
  return _FileRecord(
    name,
    size,
    digest.value.toString(),
    before.modified.millisecondsSinceEpoch,
  );
}

Future<void> _snapshotDatabase(String sourcePath, String destination) async {
  _requireFile(sourcePath);
  final source = sqlite3.open(sourcePath, mode: OpenMode.readOnly);
  Database? target;
  try {
    source.execute('PRAGMA busy_timeout = 3000');
    source.execute('BEGIN');
    // 固定此连接的 WAL 读快照；不 checkpoint，不调用 VACUUM INTO。
    source.select('SELECT name FROM sqlite_master LIMIT 1');
    target = sqlite3.open(destination);
    await source.backup(target, nPage: -1).drain<void>();
    final mode = target
        .select('PRAGMA journal_mode = DELETE')
        .first
        .values
        .first;
    if ('$mode'.toLowerCase() != 'delete') {
      throw const FullBackupException('无法生成独立一致的数据库快照');
    }
  } finally {
    target?.dispose();
    source.dispose();
  }
}

Map<String, String> _tableSql(Database db) => {
  for (final row in db.select(
    "SELECT name, sql FROM sqlite_master WHERE type='table'",
  ))
    row['name'] as String: row['sql'] as String? ?? '',
};

void _scrubMainSnapshot(String path) {
  final db = sqlite3.open(path);
  try {
    db.execute('PRAGMA secure_delete = ON');
    if (_tableSql(db).containsKey('settings')) {
      _columns(db, 'settings', const ['key', 'value']);
      db.execute(
        "DELETE FROM settings WHERE lower(key) LIKE '%.apikey' "
        "OR lower(key) = 'update.source'",
      );
    }
    // 重建主库才能清除备份前就已删除的密钥在空闲页/空闲块中的历史残留。
    db.execute('VACUUM');
  } finally {
    db.dispose();
  }
}

void _columns(Database db, String table, List<String> expected) {
  final names = {
    for (final row in db.select('PRAGMA table_info("$table")'))
      row['name'] as String,
  };
  if (!names.containsAll(expected)) {
    throw FullBackupException('数据库表 $table 的核心结构不完整');
  }
}

void _integrity(Database db) {
  final result = db.select('PRAGMA quick_check');
  if (result.length != 1 || result.first.values.first != 'ok') {
    throw const FullBackupException('数据库完整性检查失败');
  }
}

Map<String, Object?> _inspectData(String root, List<String> files) {
  // 仅 SHA 正确不能证明进度可恢复：损坏 JSON 会被运行时降级成空进度。
  for (final name in files.where(
    (name) =>
        name == 'corpus/progress.json' ||
        name == 'corpus/extract_manifest.json' ||
        (name.startsWith('corpus/toc/') && name.endsWith('.json')),
  )) {
    final file = File('$root/$name');
    if (file.lengthSync() > FullBackupManager.maxManifestBytes) {
      throw FullBackupException('学习元数据过大，无法安全校验：$name');
    }
    Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } catch (_) {
      throw FullBackupException('学习进度或章节目录 JSON 损坏：$name');
    }
    if (json is! Map ||
        (name == 'corpus/progress.json' && json['subjects'] is! Map) ||
        (name == 'corpus/extract_manifest.json' && json['files'] is! Map)) {
      throw FullBackupException('学习元数据结构不完整：$name');
    }
  }
  _requireFile('$root/hengya.db');
  final main = sqlite3.open('$root/hengya.db', mode: OpenMode.readOnly);
  final stats = <String, Object?>{};
  try {
    main.execute('PRAGMA trusted_schema = OFF');
    final tables = _tableSql(main);
    const core = {
      'meta': ['key', 'value'],
      'subjects': ['id', 'name'],
      'cards': ['id', 'subject_id', 'front', 'back', 'status', 'm_due_at'],
      'review_logs': ['id', 'card_id', 'subject_id', 'rating', 'reviewed_at'],
      'rework_queue': ['id', 'card_id'],
      'inbox': ['id', 'keyword'],
    };
    for (final entry in core.entries) {
      if (!tables.containsKey(entry.key) ||
          tables[entry.key]!.toUpperCase().contains('CREATE VIRTUAL TABLE')) {
        throw const FullBackupException('不是完整的恒牙主数据库（缺少核心表）');
      }
      _columns(main, entry.key, entry.value);
    }
    _integrity(main);
    if (tables.containsKey('settings')) {
      _columns(main, 'settings', const ['key', 'value']);
      if (main
              .select(
                "SELECT count(*) n FROM settings WHERE lower(key) LIKE '%.apikey' "
                "OR lower(key) = 'update.source'",
              )
              .first['n'] !=
          0) {
        throw const FullBackupException('备份包含有密钥或私有更新设置，拒绝恢复');
      }
    }
    stats.addAll({
      'cards': main.select('SELECT count(*) n FROM cards').first['n'],
      'reviewLogs': main
          .select('SELECT count(*) n FROM review_logs')
          .first['n'],
      'subjects': main.select('SELECT count(*) n FROM subjects').first['n'],
    });
  } finally {
    main.dispose();
  }
  final hasCorpus = files.contains('corpus/corpus.db');
  stats.addAll({
    'chunks': 0,
    'vectors': 0,
    'hasCorpus': hasCorpus,
    'hasProgress': files.contains('corpus/progress.json'),
    'sourceFiles': files
        .where((name) => name.startsWith('corpus/incoming/'))
        .length,
    'modelName': '',
    'warnings': <String>[],
  });
  if (hasCorpus) {
    _requireFile('$root/corpus/corpus.db');
    final corpus = sqlite3.open(
      '$root/corpus/corpus.db',
      mode: OpenMode.readOnly,
    );
    try {
      corpus.execute('PRAGMA trusted_schema = OFF');
      final tables = _tableSql(corpus);
      for (final name in const ['chunks', 'meta']) {
        if (!tables.containsKey(name)) {
          throw const FullBackupException('知识库缺少 chunks 或 meta 核心表');
        }
      }
      _columns(corpus, 'chunks', const [
        'chunk_id',
        'subject_id',
        'ppt_id',
        'text',
      ]);
      _columns(corpus, 'meta', const ['key', 'value']);
      _integrity(corpus);
      stats['chunks'] = corpus
          .select('SELECT count(*) n FROM chunks')
          .first['n'];
      if (tables.containsKey('vectors')) {
        _columns(corpus, 'vectors', const ['chunk_id', 'dim', 'vec', 'scale']);
        stats['vectors'] = corpus
            .select('SELECT count(*) n FROM vectors')
            .first['n'];
      }
      final model = corpus.select(
        "SELECT value FROM meta WHERE key='embedding_model'",
      );
      stats['modelName'] = model.isEmpty ? '' : '${model.first['value'] ?? ''}';
      // 不查询/重建 vec0；在线备份和文件摘要保护其 schema 与所有影子表。
    } finally {
      corpus.dispose();
    }
  } else if (files.any((name) => name.startsWith('corpus/'))) {
    (stats['warnings'] as List<String>).add('尚无 corpus.db；已保留现有进度、课件及建库状态');
  }
  return stats;
}

Future<Map<String, Object?>> _createBackup(
  String root,
  String? appVersion,
  void Function(String) progress,
  String sourceDataDir,
) async {
  _requireFile('$root/hengya.db');
  _plainDirectory('$root/backups');
  final outputDir = _plainDirectory('$root/backups/full');
  final createdAt = DateTime.now().toUtc();
  final target = File(
    '${outputDir.path}/hengya-full-${_timestamp(createdAt)}-${_nonce()}.zip',
  );
  final staging = Directory('${outputDir.path}/.full-create-${_nonce()}')
    ..createSync();
  final snapshot = Directory('${staging.path}/snapshot')..createSync();
  final zip = File('${staging.path}/package.tmp');
  try {
    final originals = _scanCorpus(root);
    final copied = <String, _FileRecord>{};
    progress('正在生成主数据库一致性快照（含 WAL）');
    await _snapshotDatabase('$root/hengya.db', '${snapshot.path}/hengya.db');
    _scrubMainSnapshot('${snapshot.path}/hengya.db');
    for (final entry in originals.entries) {
      final destination = File('${snapshot.path}/${entry.key}');
      destination.parent.createSync(recursive: true);
      if (entry.key == 'corpus/corpus.db') {
        progress('正在备份完整知识库和向量');
        await _snapshotDatabase(entry.value.path, destination.path);
      } else {
        copied[entry.key] = _fingerprint(
          entry.value,
          entry.key,
          copyTo: destination,
        );
      }
    }
    final names = ['hengya.db', ...originals.keys]..sort();
    final stats = _inspectData(snapshot.path, names);
    final records = <_FileRecord>[];
    var total = 0;
    for (final name in names) {
      final record =
          copied[name] ?? _fingerprint(File('${snapshot.path}/$name'), name);
      records.add(record);
      total += record.size;
      if (total > FullBackupManager.maxTotalBytes) {
        throw const FullBackupException('完整数据超过 8 GiB 备份安全上限');
      }
    }
    final manifest = File('${snapshot.path}/$_manifestName');
    manifest.writeAsStringSync(
      jsonEncode({
        'kind': FullBackupManager.kind,
        'schemaVersion': FullBackupManager.schemaVersion,
        'createdAt': createdAt.toIso8601String(),
        'appVersion': appVersion ?? '',
        // 保留调用方实际使用的路径拼写（Android /data/user/0 与 /data/data、
        // Windows 短文件名都可能不同于 resolveSymbolicLinks 的规范路径）。
        'sourceDataDir': sourceDataDir.replaceAll('\\', '/'),
        'files': records.map((record) => record.toMap()).toList(),
        'stats': stats,
      }),
      flush: true,
    );
    if (manifest.lengthSync() > FullBackupManager.maxManifestBytes) {
      throw const FullBackupException('备份清单超过安全上限');
    }
    progress('正在分块压缩完整学习数据');
    final encoder = _StreamingZipWriter(zip);
    try {
      encoder.add(manifest, _fingerprint(manifest, _manifestName));
      var completed = 0;
      for (final record in records) {
        encoder.add(File('${snapshot.path}/${record.path}'), record);
        if (++completed % 50 == 0) {
          progress('已压缩 $completed / ${records.length} 个文件');
        }
      }
      encoder.finish();
    } finally {
      encoder.close();
    }
    // 压缩期间任何原始持久文件被增删/改写都不发布一个混合快照。
    final after = _scanCorpus(root);
    if (after.length != originals.length ||
        !after.keys.toSet().containsAll(originals.keys)) {
      throw const FullBackupException('备份时知识库文件发生变化，请稍后重试');
    }
    for (final entry in copied.entries) {
      final latest = _fingerprint(after[entry.key]!, entry.key);
      if (latest.size != entry.value.size ||
          latest.digest != entry.value.digest ||
          latest.modifiedMs != entry.value.modifiedMs) {
        throw const FullBackupException('备份时课件或进度发生变化，请稍后重试');
      }
    }
    progress('正在逐文件校验新备份包');
    final verify = Directory('${staging.path}/verified')..createSync();
    final checked = _validateAndExtract(zip.path, verify, progress);
    // 通过同一恢复校验器后才原子发布；失败不动任何历史备份。
    if (target.existsSync()) throw const FullBackupException('备份名称冲突，请重试');
    zip.renameSync(target.path);
    final backups = _listBackups(root);
    final warnings = [...checked.summary.warnings];
    for (final old in backups.take(
      max(0, backups.length - FullBackupManager.maxBackups),
    )) {
      try {
        old.deleteSync();
      } catch (_) {
        warnings.add('一份旧完整备份被占用，未能清理；新备份已安全保存');
      }
    }
    progress('完整备份已保存并通过校验');
    return {
      ...checked.summary.toMap(),
      'path': target.path,
      'warnings': warnings,
    };
  } finally {
    _tryDeleteDirectory(staging);
  }
}

// ---------------- 有界 ZIP32，直接 sink 写盘 ----------------

class _ZipEntry {
  _ZipEntry(
    this.name,
    this.offset,
    this.dataOffset,
    this.end,
    this.compressedSize,
    this.size,
    this.crc,
    this.method,
    this.flags,
    this.dosTime,
    this.dosDate,
  );
  final String name;
  final int offset;
  final int dataOffset;
  final int end;
  final int compressedSize;
  final int size;
  final int crc;
  final int method;
  final int flags;
  final int dosTime;
  final int dosDate;
}

Uint8List _header(int size, Map<int, int> u16, Map<int, int> u32) {
  final data = ByteData(size);
  for (final entry in u16.entries) {
    data.setUint16(entry.key, entry.value, Endian.little);
  }
  for (final entry in u32.entries) {
    data.setUint32(entry.key, entry.value, Endian.little);
  }
  return data.buffer.asUint8List();
}

class _StreamingZipWriter {
  _StreamingZipWriter(File file) : output = file.openSync(mode: FileMode.write);
  final RandomAccessFile output;
  final entries = <_ZipEntry>[];
  int position = 0;
  bool closed = false;

  void _write(List<int> bytes) {
    if (position + bytes.length > FullBackupManager.maxZipBytes) {
      throw const FullBackupException('压缩包超过 ZIP32 安全上限（约 4 GiB）');
    }
    output.writeFromSync(bytes);
    position += bytes.length;
  }

  void add(File file, _FileRecord expected) {
    _checkArchivePath(expected.path);
    final name = utf8.encode(expected.path);
    final date = DateTime.fromMillisecondsSinceEpoch(expected.modifiedMs);
    final timeBits =
        (date.hour << 11) | (date.minute << 5) | (date.second ~/ 2);
    final dateBits =
        ((date.year.clamp(1980, 2107) - 1980) << 9) |
        (date.month << 5) |
        date.day;
    final start = position;
    _write(
      _header(
        30,
        {4: 20, 6: 0x808, 8: 8, 10: timeBits, 12: dateBits, 26: name.length},
        {0: 0x04034b50},
      ),
    );
    _write(name);
    final dataOffset = position;
    var crc = 0;
    var size = 0;
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    final compressed = ZLibEncoder(
      raw: true,
      level: 6,
    ).startChunkedConversion(_DirectByteSink(_write));
    final input = file.openSync();
    try {
      while (true) {
        final bytes = input.readSync(_chunkSize);
        if (bytes.isEmpty) break;
        size += bytes.length;
        if (size > expected.size) {
          throw const FullBackupException('压缩时快照文件发生变化');
        }
        crc = getCrc32(bytes, crc);
        hash.add(bytes);
        compressed.add(bytes);
      }
      hash.close();
      compressed.close();
    } finally {
      input.closeSync();
    }
    if (size != expected.size || digest.value.toString() != expected.digest) {
      throw const FullBackupException('压缩时快照校验不一致');
    }
    final compressedSize = position - dataOffset;
    _write(
      _header(16, {}, {0: 0x08074b50, 4: crc, 8: compressedSize, 12: size}),
    );
    entries.add(
      _ZipEntry(
        expected.path,
        start,
        dataOffset,
        position,
        compressedSize,
        size,
        crc,
        8,
        0x808,
        timeBits,
        dateBits,
      ),
    );
  }

  void finish() {
    final centralStart = position;
    for (final entry in entries) {
      final name = utf8.encode(entry.name);
      _write(
        _header(
          46,
          {
            4: 0x314,
            6: 20,
            8: entry.flags,
            10: entry.method,
            12: entry.dosTime,
            14: entry.dosDate,
            28: name.length,
          },
          {
            0: 0x02014b50,
            16: entry.crc,
            20: entry.compressedSize,
            24: entry.size,
            38: 0x81a40000,
            42: entry.offset,
          },
        ),
      );
      _write(name);
    }
    final centralSize = position - centralStart;
    if (centralSize > FullBackupManager.maxDirectoryBytes ||
        entries.length > FullBackupManager.maxFiles + 1) {
      throw const FullBackupException('备份包目录超过安全上限');
    }
    _write(
      _header(
        22,
        {8: entries.length, 10: entries.length},
        {0: 0x06054b50, 12: centralSize, 16: centralStart},
      ),
    );
    output.flushSync();
  }

  void close() {
    if (!closed) {
      closed = true;
      output.closeSync();
    }
  }
}

void _checkArchivePath(String path) {
  final parts = path.split('/');
  if (path.isEmpty ||
      utf8.encode(path).length > 1024 ||
      parts.length > 32 ||
      RegExp(r'[\x00-\x1f\x7f\\:<>"|?*]').hasMatch(path)) {
    throw const FullBackupException('备份包含不安全或过长的文件路径');
  }
  final reserved = RegExp(
    r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
    caseSensitive: false,
  );
  for (final part in parts) {
    if (part.isEmpty ||
        part == '.' ||
        part == '..' ||
        part.endsWith('.') ||
        part.endsWith(' ') ||
        reserved.hasMatch(part)) {
      throw const FullBackupException('备份包含绝对路径、路径穿越或非便携文件名');
    }
  }
  if (path != _manifestName &&
      path != 'hengya.db' &&
      !(path.startsWith('corpus/') &&
          _persistentCorpusPath(path.substring(7)))) {
    throw const FullBackupException('备份包包含范围外文件（密钥、日志、缓存或历史备份）');
  }
}

class _ZipReader {
  _ZipReader(File file) : input = file.openSync(), length = file.lengthSync() {
    try {
      _readDirectory();
    } catch (_) {
      input.closeSync();
      rethrow;
    }
  }
  final RandomAccessFile input;
  final int length;
  final entries = <String, _ZipEntry>{};

  Uint8List _read(int offset, int size) {
    if (size < 0 || offset < 0 || offset + size > length || size > 200000) {
      throw const FullBackupException('ZIP 结构越界或损坏');
    }
    input.setPositionSync(offset);
    final bytes = input.readSync(size);
    if (bytes.length != size) throw const FullBackupException('ZIP 文件被截断或改写');
    return bytes;
  }

  void _readDirectory() {
    if (length < 22 || length > FullBackupManager.maxZipBytes) {
      throw const FullBackupException('ZIP 文件为空、损坏或超过约 4 GiB 上限');
    }
    final tailStart = max(0, length - 65557);
    final tail = _read(tailStart, length - tailStart);
    final tailData = ByteData.sublistView(tail);
    var eocd = -1;
    for (var i = tail.length - 22; i >= 0; i--) {
      if (tailData.getUint32(i, Endian.little) == 0x06054b50 &&
          i + 22 + tailData.getUint16(i + 20, Endian.little) == tail.length) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw const FullBackupException('不是完整的 ZIP 备份包');
    int u16(int at) => tailData.getUint16(eocd + at, Endian.little);
    int u32(int at) => tailData.getUint32(eocd + at, Endian.little);
    final count = u16(10);
    final centralSize = u32(12);
    final centralStart = u32(16);
    if (u16(4) != 0 ||
        u16(6) != 0 ||
        u16(8) != count ||
        count < 2 ||
        count > FullBackupManager.maxFiles + 1 ||
        centralSize > FullBackupManager.maxDirectoryBytes ||
        centralStart + centralSize != tailStart + eocd) {
      throw const FullBackupException('不支持 ZIP64、分卷或超限/损坏的 ZIP 目录');
    }
    var cursor = centralStart;
    final folded = <String>{};
    final directorySpelling = <String, String>{};
    var declaredTotal = 0;
    for (var index = 0; index < count; index++) {
      if (cursor + 46 > centralStart + centralSize) {
        throw const FullBackupException('ZIP 目录记录被截断');
      }
      final header = ByteData.sublistView(_read(cursor, 46));
      int h16(int at) => header.getUint16(at, Endian.little);
      int h32(int at) => header.getUint32(at, Endian.little);
      if (h32(0) != 0x02014b50) throw const FullBackupException('ZIP 目录标识损坏');
      final nameLength = h16(28);
      final extraLength = h16(30);
      final commentLength = h16(32);
      final recordEnd = cursor + 46 + nameLength + extraLength + commentLength;
      if (recordEnd > centralStart + centralSize || nameLength > 1024) {
        throw const FullBackupException('ZIP 文件名或目录大小不合法');
      }
      final name = utf8.decode(_read(cursor + 46, nameLength));
      _checkArchivePath(name);
      if (!folded.add(name.toLowerCase())) {
        throw const FullBackupException('ZIP 含重复文件名（含大小写冲突）');
      }
      final components = name.split('/');
      for (var part = 1; part < components.length; part++) {
        final prefix = components.take(part).join('/');
        final previous = directorySpelling[prefix.toLowerCase()];
        if (previous != null && previous != prefix) {
          throw const FullBackupException('ZIP 目录名大小写冲突');
        }
        directorySpelling[prefix.toLowerCase()] = prefix;
      }
      final flags = h16(8);
      final method = h16(10);
      final mode = (h32(38) >> 16) & 0xf000;
      if (h16(34) != 0 ||
          flags & ~0x80e != 0 ||
          (method != 0 && method != 8) ||
          (mode != 0 && mode != 0x8000) ||
          (h32(38) & 0x10) != 0) {
        throw const FullBackupException('ZIP 包含链接、目录、加密或不支持的压缩格式');
      }
      final compressedSize = h32(20);
      final size = h32(24);
      final offset = h32(42);
      final limit = name == _manifestName
          ? FullBackupManager.maxManifestBytes
          : FullBackupManager.maxFileBytes;
      declaredTotal += size;
      if (size > limit ||
          compressedSize > FullBackupManager.maxZipBytes ||
          declaredTotal >
              FullBackupManager.maxTotalBytes +
                  FullBackupManager.maxManifestBytes ||
          offset + 30 > centralStart) {
        throw const FullBackupException('ZIP 声明尺寸超过安全上限或偏移越界');
      }
      final local = ByteData.sublistView(_read(offset, 30));
      int l16(int at) => local.getUint16(at, Endian.little);
      int l32(int at) => local.getUint32(at, Endian.little);
      final localNameLength = l16(26);
      final dataOffset = offset + 30 + localNameLength + l16(28);
      if (l32(0) != 0x04034b50 ||
          l16(6) != flags ||
          l16(8) != method ||
          localNameLength != nameLength ||
          dataOffset + compressedSize > centralStart ||
          utf8.decode(_read(offset + 30, localNameLength)) != name) {
        throw const FullBackupException('ZIP 本地记录与中央目录不一致');
      }
      var end = dataOffset + compressedSize;
      if ((flags & 8) != 0) {
        final first = ByteData.sublistView(
          _read(end, 4),
        ).getUint32(0, Endian.little);
        final descriptorStart = first == 0x08074b50 ? end + 4 : end;
        final descriptor = ByteData.sublistView(_read(descriptorStart, 12));
        if (descriptor.getUint32(0, Endian.little) != h32(16) ||
            descriptor.getUint32(4, Endian.little) != compressedSize ||
            descriptor.getUint32(8, Endian.little) != size) {
          throw const FullBackupException('ZIP 数据描述符不一致');
        }
        end = descriptorStart + 12;
      } else if (l32(14) != h32(16) ||
          l32(18) != compressedSize ||
          l32(22) != size) {
        throw const FullBackupException('ZIP 本地尺寸或 CRC 不一致');
      }
      if (end > centralStart) throw const FullBackupException('ZIP 数据区越界');
      entries[name] = _ZipEntry(
        name,
        offset,
        dataOffset,
        end,
        compressedSize,
        size,
        h32(16),
        method,
        flags,
        h16(12),
        h16(14),
      );
      cursor = recordEnd;
    }
    if (cursor != centralStart + centralSize ||
        directorySpelling.keys.any(folded.contains)) {
      throw const FullBackupException('ZIP 含隐藏目录记录或文件/目录冲突');
    }
    final byOffset = entries.values.toList()
      ..sort((a, b) => a.offset.compareTo(b.offset));
    var next = 0;
    for (final entry in byOffset) {
      if (entry.offset != next) {
        throw const FullBackupException('ZIP 存在重叠、隐藏文件或非标准前缀');
      }
      next = entry.end;
    }
    if (next != centralStart) throw const FullBackupException('ZIP 数据范围不完整');
  }

  void extract(
    _ZipEntry entry,
    File destination, {
    required int expectedSize,
    String? expectedHash,
  }) {
    destination.parent.createSync(recursive: true);
    final output = destination.openSync(mode: FileMode.write);
    final digest = _DigestSink();
    final hash = sha256.startChunkedConversion(digest);
    var size = 0;
    var crc = 0;
    final sink = _DirectByteSink((bytes) {
      size += bytes.length;
      if (size > expectedSize || size > FullBackupManager.maxFileBytes) {
        throw const FullBackupException('ZIP 实际解压尺寸超过声明/安全上限');
      }
      hash.add(bytes);
      crc = getCrc32(bytes, crc);
      output.writeFromSync(bytes);
    });
    final ByteConversionSink decoder = entry.method == 8
        ? ZLibDecoder(raw: true).startChunkedConversion(sink)
        : sink;
    try {
      input.setPositionSync(entry.dataOffset);
      var remaining = entry.compressedSize;
      while (remaining > 0) {
        final bytes = input.readSync(min(_chunkSize, remaining));
        if (bytes.isEmpty) throw const FullBackupException('ZIP 内容被截断');
        remaining -= bytes.length;
        decoder.add(bytes);
      }
      decoder.close();
      hash.close();
      if (size != expectedSize ||
          size != entry.size ||
          crc != entry.crc ||
          (expectedHash != null && digest.value.toString() != expectedHash)) {
        throw const FullBackupException('备份文件的尺寸、CRC 或 SHA-256 校验失败');
      }
      output.flushSync();
    } finally {
      output.closeSync();
    }
  }

  void close() => input.closeSync();
}

class _ValidatedBackup {
  _ValidatedBackup(this.summary, this.files, this.sourceDataDir);
  final FullBackupSummary summary;
  final Map<String, _FileRecord> files;
  final String? sourceDataDir;
}

_ValidatedBackup _validateAndExtract(
  String zipPath,
  Directory destination,
  void Function(String) progress,
) {
  _requireFile(zipPath);
  final zipFile = File(zipPath);
  final before = zipFile.statSync();
  final reader = _ZipReader(zipFile);
  try {
    progress('正在校验备份格式与文件清单');
    final manifestEntry = reader.entries[_manifestName];
    if (manifestEntry == null) {
      throw const FullBackupException('不是恒牙完整备份包（缺少 backup.json）');
    }
    final manifestFile = File('${destination.path}/$_manifestName');
    reader.extract(
      manifestEntry,
      manifestFile,
      expectedSize: manifestEntry.size,
    );
    final decoded = jsonDecode(manifestFile.readAsStringSync());
    if (decoded is! Map ||
        decoded['kind'] != FullBackupManager.kind ||
        decoded['schemaVersion'] != FullBackupManager.schemaVersion ||
        decoded['schemaVersion'] is! int) {
      throw const FullBackupException('备份种类或版本不受支持，请升级应用后重试');
    }
    final createdAt = decoded['createdAt'] is String
        ? DateTime.tryParse(decoded['createdAt'] as String)
        : null;
    final rawFiles = decoded['files'];
    if (createdAt == null ||
        rawFiles is! List ||
        rawFiles.isEmpty ||
        rawFiles.length > FullBackupManager.maxFiles) {
      throw const FullBackupException('备份时间或文件清单不合法');
    }
    final files = <String, _FileRecord>{};
    final folded = <String>{};
    var total = 0;
    for (final raw in rawFiles) {
      if (raw is! Map ||
          raw['path'] is! String ||
          raw['size'] is! int ||
          raw['sha256'] is! String ||
          !_shaPattern.hasMatch(raw['sha256'] as String)) {
        throw const FullBackupException('备份清单缺少合法的路径、尺寸或 SHA-256');
      }
      final name = raw['path'] as String;
      _checkArchivePath(name);
      final size = raw['size'] as int;
      final modified = raw['modifiedMs'] ?? createdAt.millisecondsSinceEpoch;
      if (name == _manifestName ||
          !folded.add(name.toLowerCase()) ||
          size < 0 ||
          size > FullBackupManager.maxFileBytes ||
          modified is! int ||
          modified < 0 ||
          modified > 8640000000000000) {
        throw const FullBackupException('备份清单含重复路径或非法尺寸/时间');
      }
      final entry = reader.entries[name];
      if (entry == null || entry.size != size) {
        throw const FullBackupException('备份文件与清单不一致或存在缺失文件');
      }
      total += size;
      if (total > FullBackupManager.maxTotalBytes) {
        throw const FullBackupException('备份解压总量超过 8 GiB 安全上限');
      }
      files[name] = _FileRecord(name, size, raw['sha256'] as String, modified);
    }
    if (!files.containsKey('hengya.db') ||
        reader.entries.length != files.length + 1) {
      throw const FullBackupException('备份缺少主库或含未声明文件');
    }
    var completed = 0;
    for (final record in files.values) {
      final target = File('${destination.path}/${record.path}');
      reader.extract(
        reader.entries[record.path]!,
        target,
        expectedSize: record.size,
        expectedHash: record.digest,
      );
      target.setLastModifiedSync(
        DateTime.fromMillisecondsSinceEpoch(record.modifiedMs),
      );
      if (++completed % 50 == 0) {
        progress('已校验 $completed / ${files.length} 个文件');
      }
    }
    progress('正在检查主库、知识库与真实数据统计');
    final stats = _inspectData(destination.path, files.keys.toList());
    if (!_sameStat(before, zipFile.statSync())) {
      throw const FullBackupException('校验期间备份文件发生变化，请重试');
    }
    final source = decoded['sourceDataDir'];
    if (source != null && (source is! String || source.length > 4096)) {
      throw const FullBackupException('备份的原始数据目录记录不合法');
    }
    return _ValidatedBackup(
      FullBackupSummary.fromMap({
        'path': zipPath,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'sizeBytes': reader.length,
        'fileCount': files.length,
        ...stats,
      }),
      files,
      source as String?,
    );
  } finally {
    reader.close();
  }
}

// ---------------- 绝对课件路径重定位，仅修改暂存副本 ----------------

(int, List<String>) _rebaseSourcePaths(
  String stagedRoot,
  String destinationRoot,
  String? sourceRoot,
  Set<String> files,
) {
  var rebased = 0;
  var unresolved = 0;
  final oldRoot = sourceRoot
      ?.replaceAll('\\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  final newRoot = destinationRoot
      .replaceAll('\\', '/')
      .replaceFirst(RegExp(r'/+$'), '');
  String relocate(String value) {
    final normalized = value.replaceAll('\\', '/');
    if (!normalized.startsWith('/') &&
        !RegExp(r'^[A-Za-z]:/').hasMatch(normalized)) {
      return value; // extract_manifest 树模式相对路径原样保留。
    }
    if (oldRoot != null &&
        normalized.toLowerCase().startsWith('${oldRoot.toLowerCase()}/')) {
      final relative = normalized.substring(oldRoot.length + 1);
      if (files.contains(relative) && relative.startsWith('corpus/')) {
        final replacement = '$newRoot/$relative';
        if (normalized != replacement) rebased++;
        return Platform.isWindows
            ? replacement.replaceAll('/', '\\')
            : replacement;
      }
    }
    unresolved++;
    return value;
  }

  if (files.contains('corpus/corpus.db')) {
    final db = sqlite3.open('$stagedRoot/corpus/corpus.db');
    try {
      if (_tableSql(db).containsKey('deck_state')) {
        _columns(db, 'deck_state', const ['subject_id', 'ppt_id', 'file_path']);
        final rows = db.select(
          'SELECT subject_id, ppt_id, file_path FROM deck_state',
        );
        db.execute('BEGIN IMMEDIATE');
        for (final row in rows) {
          final value = row['file_path'];
          if (value is! String) continue;
          final relocated = relocate(value);
          if (relocated != value) {
            db.execute(
              'UPDATE deck_state SET file_path=? WHERE subject_id=? AND ppt_id=?',
              [relocated, row['subject_id'], row['ppt_id']],
            );
          }
        }
        db.execute('COMMIT');
      }
      final mode = db.select('PRAGMA journal_mode=DELETE').first.values.first;
      if ('$mode'.toLowerCase() != 'delete') {
        throw const FullBackupException('无法完成知识库路径重定位');
      }
    } finally {
      db.dispose();
    }
  }
  if (files.contains('corpus/extract_manifest.json')) {
    final manifest = File('$stagedRoot/corpus/extract_manifest.json');
    // 元数据也设上限；不把任意大小的 JSONL/课程文档读进内存。
    if (manifest.lengthSync() > FullBackupManager.maxManifestBytes) {
      unresolved++;
    } else {
      final decoded = jsonDecode(manifest.readAsStringSync());
      if (decoded is! Map || decoded['files'] is! Map) {
        throw const FullBackupException('建库状态 extract_manifest.json 结构损坏');
      }
      final updated = <String, Object?>{};
      var changed = false;
      for (final entry in (decoded['files'] as Map).entries) {
        if (entry.key is! String) throw const FullBackupException('建库状态路径不合法');
        final key = relocate(entry.key as String);
        if (updated.containsKey(key)) {
          throw const FullBackupException('课件路径重定位发生冲突');
        }
        updated[key] = entry.value;
        changed = changed || key != entry.key;
      }
      if (changed) {
        manifest.writeAsStringSync(
          jsonEncode({...decoded, 'files': updated}),
          flush: true,
        );
      }
    }
  }
  return (
    rebased,
    [
      if (unresolved > 0)
        '有 $unresolved 项原设备外部课件路径或超大建库清单无法自动重定位；已保留原值，相关课件可能需重新关联',
    ],
  );
}

// ---------------- journal + 同卷 rename；中断时整体回滚 ----------------

File _journalFile(String root) => File('$root/.full-restore-journal.json');

void _requireNoRestoreJournal(String root) {
  if (_type(_journalFile(root).path) != FileSystemEntityType.notFound) {
    throw const FullBackupException('检测到未完成的恢复，请重启应用先修复恢复事务');
  }
}

void _moveSlot(String source, String destination) {
  final type = _type(source);
  if (_type(destination) != FileSystemEntityType.notFound) {
    throw const FullBackupException('恢复目标已存在，已停止切换');
  }
  if (type == FileSystemEntityType.directory) {
    Directory(source).renameSync(destination);
  } else if (type == FileSystemEntityType.file) {
    File(source).renameSync(destination);
  } else {
    throw const FullBackupException('恢复文件缺失或为符号链接');
  }
}

void _deleteSlot(String path) {
  final type = _type(path);
  if (type == FileSystemEntityType.directory) {
    Directory(path).deleteSync(recursive: true);
  } else if (type == FileSystemEntityType.file) {
    File(path).deleteSync();
  } else if (type != FileSystemEntityType.notFound) {
    throw const FullBackupException('恢复位置存在符号链接，已保留现场');
  }
}

void _writeAtomicMarker(File file, String text) {
  final temporary = File('${file.path}.tmp');
  temporary.writeAsStringSync(text, flush: true);
  temporary.renameSync(file.path);
}

void _swapRestore(String root, Directory staging, void Function(String)? hook) {
  final previous = <String, bool>{};
  for (final slot in _restoreSlots) {
    final type = _type('$root/$slot');
    final expected = slot == 'corpus'
        ? FileSystemEntityType.directory
        : FileSystemEntityType.file;
    if (type != FileSystemEntityType.notFound && type != expected) {
      throw const FullBackupException('现有数据库或知识库位置不是普通文件/目录');
    }
    previous[slot] = type != FileSystemEntityType.notFound;
  }
  Directory('${staging.path}/old').createSync();
  final hasNewCorpus = Directory('${staging.path}/new/corpus').existsSync();
  _writeAtomicMarker(
    _journalFile(root),
    jsonEncode({
      'kind': 'hengya-full-restore',
      'schemaVersion': 1,
      'staging': staging.uri.pathSegments.where((s) => s.isNotEmpty).last,
      'previous': previous,
      'hasNewCorpus': hasNewCorpus,
    }),
  );
  try {
    hook?.call('journal-written');
    for (final slot in _restoreSlots) {
      if (previous[slot]!) {
        _moveSlot('$root/$slot', '${staging.path}/old/$slot');
      }
      hook?.call('old-moved:$slot');
    }
    _moveSlot('${staging.path}/new/hengya.db', '$root/hengya.db');
    hook?.call('new-main-installed');
    if (hasNewCorpus) _moveSlot('${staging.path}/new/corpus', '$root/corpus');
    hook?.call('new-corpus-installed');
    hook?.call('before-commit');
    _writeAtomicMarker(File('${staging.path}/committed'), 'committed');
  } on FullBackupInterruptedForTest {
    rethrow;
  } catch (_) {
    try {
      _recoverRestore(root);
    } catch (_) {
      throw const FullBackupException('恢复失败且回滚暂未完成，请重启应用；旧数据仍保留在恢复暂存区');
    }
    throw const FullBackupException('恢复切换失败，已完整回滚原主库和知识库');
  }
  // journal 先删，再清理目录；否则清理中被杀可能留下一个无原件的 journal。
  // commit 标志之后的清理失败不再回滚，下一次启动会完成相同清理。
  try {
    _journalFile(root).deleteSync();
    _tryDeleteDirectory(staging);
  } catch (_) {}
}

void _recoverRestore(String root) {
  final journal = _journalFile(root);
  if (_type(journal.path) == FileSystemEntityType.notFound) return;
  if (_type(journal.path) != FileSystemEntityType.file ||
      journal.lengthSync() > 16384) {
    throw const FullBackupException('恢复 journal 损坏，已保留数据，请勿继续写入');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(journal.readAsStringSync());
  } catch (_) {
    throw const FullBackupException('恢复 journal 无法读取，已保留原件');
  }
  if (decoded is! Map ||
      decoded['kind'] != 'hengya-full-restore' ||
      decoded['schemaVersion'] != 1 ||
      decoded['staging'] is! String ||
      !RegExp(
        r'^\.full-restore-[0-9a-f]{24}$',
      ).hasMatch(decoded['staging'] as String) ||
      decoded['previous'] is! Map ||
      decoded['hasNewCorpus'] is! bool) {
    throw const FullBackupException('恢复 journal 格式不合法，已保留原件');
  }
  final previous = decoded['previous'] as Map;
  if (previous.length != _restoreSlots.length ||
      _restoreSlots.any((slot) => previous[slot] is! bool)) {
    throw const FullBackupException('恢复 journal 原件清单不完整');
  }
  final stage = Directory('$root/${decoded['staging']}');
  if (_type(stage.path) != FileSystemEntityType.directory ||
      _type('${stage.path}/old') != FileSystemEntityType.directory) {
    throw const FullBackupException('恢复暂存原件缺失，已停止自动处理');
  }
  final commitType = _type('${stage.path}/committed');
  if (commitType == FileSystemEntityType.file) {
    if (_type('$root/hengya.db') != FileSystemEntityType.file ||
        (_type('$root/corpus') == FileSystemEntityType.directory) !=
            decoded['hasNewCorpus']) {
      throw const FullBackupException('已提交恢复的数据不完整，已保留旧件');
    }
  } else {
    if (commitType != FileSystemEntityType.notFound) {
      throw const FullBackupException('恢复 commit 标志不合法');
    }
    // 先检查所有旧件至少还在原位或 old/，再做任何破坏性清理。
    for (final slot in _restoreSlots) {
      if (previous[slot] == true &&
          _type('${stage.path}/old/$slot') == FileSystemEntityType.notFound &&
          _type('$root/$slot') == FileSystemEntityType.notFound) {
        throw const FullBackupException('中断恢复的原件缺失，无法安全回滚');
      }
    }
    for (final slot in _restoreSlots) {
      final oldPath = '${stage.path}/old/$slot';
      final currentPath = '$root/$slot';
      if (previous[slot] == true) {
        if (_type(oldPath) != FileSystemEntityType.notFound) {
          _deleteSlot(currentPath);
          _moveSlot(oldPath, currentPath);
        }
        // old 不在但 current 在：尚未挪旧件，或上一次回滚已完成此件。
      } else {
        _deleteSlot(currentPath);
      }
    }
  }
  journal.deleteSync();
  _tryDeleteDirectory(stage);
}
