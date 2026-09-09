// 恒牙（hengya）· 语料包导入（批5 节点③）
// ============================================================================
//
// PC 全量建库（节点②）产出成品语料库 zip → 手机「导入语料包」一键落位，
// 不再逐文件上传建库。与 [DataManager]（hengya.db 迁移主通道）同款风格：
// 纯同步文件操作 + 毫秒级 SQLite 校验，失败绝不破坏原库。
//
// ── 包格式契约（节点②产出；若②实现有出入以② handoff 为准适配）──
// zip 内部布局（两种形态均认，按 corpus.db 位置自动判定前缀）：
//   形态 A（标准）：corpus/corpus.db + corpus/toc/*.json
//                  + corpus/extract_manifest.json（或根级 manifest）
//                  + package.json（根级）
//   形态 B（扁平）：corpus.db + toc/*.json + extract_manifest.json
//                  + package.json
// package.json：{schemaVersion, appMinVersion, modelName, dim=1024,
//   subjects:[{id,name,textbook,chapters}], stats, builtAt}
// 不含 hengya.db、不含任何密钥（校验硬拒）。
//
// ── 导入流程（importPackage）──
//   0. 流水线/建库运行中 → 拒绝（稍后再试）；
//   1. validatePackage 再校验（文件可能预览后被换）；
//   2. 备份现有 corpus/corpus.db（及 toc/、extract_manifest.json）到
//      corpus/bak-<ts>/（不存在则跳过；progress.json 与 incoming/ 绝不备份
//      也绝不替换——学习进度与上传队列分毫不动）；
//   3. 原子替换：全量解包到 corpus/.import-tmp-<ts>/ → 校验 corpus.db 可开
//      → 删旧 → rename 新到位；任一步失败自动从备份回滚（无备份则恢复
//      「无库」原状）；
//   4. ensureSubjectRow 补科目行（幂等，种子来自 package.json）；
//   5. 进度同步【只补不改】：包内每科 progress.json 无条目 → 按
//      effectiveTocChapters(toc sidecar)（真章救援+辅文过滤，稀疏保 no——
//      见 corpus/toc_chapters.dart；无 sidecar 建无罗盘占位）建初始条目
//      （learned_through=0）；已有条目 → 仅同步 textbook/chapters（同为
//      effectiveTocChapters 形态；derm 旧占位 textbook=null 升级为真教材），
//      learned_through/skipped/history 分毫不动（**不 clamp**——与
//      progress_db._applySidecarEntry 的刷新语义刻意不同，节点③口径）；
//   6. bumpDataVersion；返回导入摘要。
//
// 模型名对暗号：settings embedding.model 与 package.modelName 不一致
// （大小写不敏感精确比对，同 corpusSearch 互斥口径）→ modelWarning 提示
// 「向量检索路不可用」，UI 明确提示但不阻断（词面检索不受影响）。
//
// 旧卡 evidenceChunkId 指向旧库块 id 可能失效——不修（影响面仅「显示出处」
// 层；卡片/复习/评分不受影响，回炉会用新库重检索）。
//
// 路径布局（与 LocalBackend 约定一致）：dataDir/{hengya.db, corpus/
// {corpus.db, toc/, progress.json, incoming/, extract_manifest.json}}。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:sqlite3/sqlite3.dart';

import 'corpus/extract_all.dart' show nowIso;
import 'corpus/progress_db.dart'
    show applyChange, loadProgress, saveProgress, todayIso;
import 'corpus/toc_chapters.dart';
import 'corpus_build_job.dart' show corpusBuildJobId;
import 'db.dart';
import 'isolate_runner.dart';
import 'pipeline_runner.dart' show PipelineRunner;

/// 本 App 支持的语料包格式版本（package.json schemaVersion）。
const int kPackageSchemaVersion = 1;

class CorpusPackageException implements Exception {
  CorpusPackageException(this.message);

  final String message;

  @override
  String toString() => 'CorpusPackageException: $message';
}

// ------------------------------------------------------------- 数据形状 ----

/// package.json subjects[] 单科种子。
class PackageSubjectSeed {
  const PackageSubjectSeed({
    required this.id,
    required this.name,
    this.textbook,
    this.chapters = 0,
  });

  final String id;
  final String name;

  /// 教材名（罗盘条目 textbook 来源之一；ppt-only 科目为 null）。
  final String? textbook;

  /// 章数（package.json 自述；真实章表以 toc sidecar 为准）。
  final int chapters;
}

/// validatePackage 摘要（UI 二次确认展示）。
class CorpusPackageSummary {
  const CorpusPackageSummary({
    required this.zipPath,
    required this.schemaVersion,
    required this.appMinVersion,
    required this.modelName,
    required this.dim,
    required this.builtAt,
    required this.subjects,
    required this.chunks,
    required this.outlineEntries,
    required this.tocFiles,
    required this.packageBytes,
    required this.dbModelName,
    required this.stats,
  });

  final String zipPath;
  final int schemaVersion;
  final String appMinVersion;
  final String modelName;
  final int dim;
  final String builtAt;
  final List<PackageSubjectSeed> subjects;

  /// corpus.db chunks 行数。
  final int chunks;

  /// corpus.db outline_entries 行数（表缺 = 0）。
  final int outlineEntries;

  /// 包内 toc/*.json 份数。
  final int tocFiles;

  /// zip 体积（字节）。
  final int packageBytes;

  /// corpus.db meta.embedding_model 实读值（offline 建库可为 null——此时
  /// 与 package.json modelName 的一致性无从核验，摘要如实透出）。
  final String? dbModelName;

  /// package.json stats 原样透传（人读）。
  final Map<String, Object?> stats;

  Map<String, Object?> toMap() => {
        'subjects': subjects.length,
        'chunks': chunks,
        'outlineEntries': outlineEntries,
        'tocFiles': tocFiles,
        'modelName': modelName,
        'dbModelName': dbModelName,
        'dim': dim,
        'schemaVersion': schemaVersion,
        'appMinVersion': appMinVersion,
        'builtAt': builtAt,
        'packageBytes': packageBytes,
        'stats': stats,
      };
}

/// importPackage 结果摘要。
class CorpusImportResult {
  const CorpusImportResult({
    required this.summary,
    required this.backupPath,
    required this.subjectsAdded,
    required this.subjectsExisting,
    required this.progressCreated,
    required this.progressSynced,
    required this.modelWarning,
  });

  final CorpusPackageSummary summary;

  /// 本次备份目录（null = 本机原无库可备）。
  final String? backupPath;

  /// ensureSubjectRow 新插入科目行数。
  final int subjectsAdded;

  /// 科目行已存在（幂等跳过）数。
  final int subjectsExisting;

  /// progress.json 新建条目数。
  final int progressCreated;

  /// 已有条目实际同步（textbook/chapters 变化）数。
  final int progressSynced;

  /// 模型名对暗号失败警告（null = 一致或本机未配模型）。
  final String? modelWarning;

  Map<String, Object?> toMap() => {
        ...summary.toMap(),
        'backupPath': backupPath,
        'subjectsAdded': subjectsAdded,
        'subjectsExisting': subjectsExisting,
        'progressCreated': progressCreated,
        'progressSynced': progressSynced,
        'modelWarning': modelWarning,
      };
}

// ------------------------------------------------------------- 管理器 ----

class CorpusPackageManager {
  CorpusPackageManager._();

  static final CorpusPackageManager instance = CorpusPackageManager._();

  /// 流水线/建库占用检查（可测试注入；生产 = 拆卡流水线 ∪ 建库 job 单飞位）。
  /// 导入与运行中流水线并发写 corpus 目录会互相破坏——导入前硬拒。
  static bool Function() pipelineBusyCheck = _defaultPipelineBusy;

  static bool _defaultPipelineBusy() =>
      PipelineRunner.instance.running ||
      IsolateRunner.instance.isRunning(corpusBuildJobId);

  /// 测试缝（生产勿碰）：受保护区阶段钩子——'after-extract'（解包完成、
  /// 换库前）/ 'after-swap'（换库完成、科目补行前）。抛异常即触发回滚路径。
  static void Function(String phase)? debugHook;

  static const _corpusDbName = 'corpus.db';
  static const _tocDirName = 'toc';
  static const _manifestName = 'extract_manifest.json';
  static const _pkgJsonName = 'package.json';

  // ---------------- 校验 ----------------

  /// 只读校验语料包并返回摘要（导入预览用）。不满足契约抛
  /// [CorpusPackageException]（文件不存在/不是 zip/缺件/版本守卫/含主库）。
  CorpusPackageSummary validatePackage(String zipPath, {String? appVersion}) {
    final f = File(zipPath);
    if (!f.existsSync()) {
      throw CorpusPackageException('文件不存在：$zipPath');
    }
    final bytes = f.lengthSync() == 0
        ? throw CorpusPackageException('文件为空')
        : f.readAsBytesSync();
    final Archive arc;
    try {
      arc = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw CorpusPackageException('不是合法的 zip 文件：$e');
    }

    // zip-slip / 非法件守卫：路径穿越、绝对路径、hengya.db 绝不许进包
    final names = <String>[];
    for (final e in arc.files) {
      final n = _normalizeEntryName(e.name);
      if (n == null) {
        throw CorpusPackageException('包内路径非法：${e.name}');
      }
      if (n == 'hengya.db' || n.endsWith('/hengya.db')) {
        throw CorpusPackageException('包内含 hengya.db（非法：语料包不含主库）');
      }
      names.add(n);
    }

    // 前缀判定：corpus/corpus.db（标准）或 corpus.db（扁平）
    final String prefix;
    if (names.contains('corpus/$_corpusDbName')) {
      prefix = 'corpus/';
    } else if (names.contains(_corpusDbName)) {
      prefix = '';
    } else {
      throw CorpusPackageException('包内缺 corpus/corpus.db（不是恒牙齿料包）');
    }

    // package.json：根级或 corpus/ 下均可
    final pkgEntry = arc.files.where((e) {
      final n = _normalizeEntryName(e.name);
      return n == _pkgJsonName || n == 'corpus/$_pkgJsonName';
    }).firstOrNull;
    if (pkgEntry == null) {
      throw CorpusPackageException('包内缺 package.json');
    }
    final Map<String, Object?> pkg;
    try {
      final obj = jsonDecode(utf8.decode(pkgEntry.content));
      if (obj is! Map) throw const FormatException('顶层非对象');
      pkg = Map<String, Object?>.from(obj);
    } catch (e) {
      throw CorpusPackageException('package.json 解析失败：$e');
    }

    // schemaVersion / appMinVersion 守卫
    final sv = pkg['schemaVersion'];
    if (sv is! num || sv.toInt() != kPackageSchemaVersion) {
      throw CorpusPackageException(
          '语料包格式版本不受支持（schemaVersion=$sv，本 App 支持 '
          '$kPackageSchemaVersion）——请升级 App 后重试');
    }
    final minV = (pkg['appMinVersion'] as String?) ?? '';
    final appV = (appVersion ?? '').trim();
    if (minV.isNotEmpty && appV.isNotEmpty && _versionBelow(appV, minV)) {
      throw CorpusPackageException(
          'App 版本过低（语料包要求 ≥ $minV，当前 $appV），请先升级 App');
    }

    // 模型名 / 维度 / 科目种子
    final modelName = ((pkg['modelName'] as String?) ?? '').trim();
    if (modelName.isEmpty) {
      throw CorpusPackageException('package.json 缺 modelName');
    }
    final dim = (pkg['dim'] as num?)?.toInt() ?? 1024;
    final rawSubjects = pkg['subjects'];
    if (rawSubjects is! List || rawSubjects.isEmpty) {
      throw CorpusPackageException('package.json subjects 为空');
    }
    final subjects = <PackageSubjectSeed>[];
    final seen = <String>{};
    for (final s0 in rawSubjects) {
      if (s0 is! Map) {
        throw CorpusPackageException('package.json subjects 条目非对象');
      }
      final s = Map<String, Object?>.from(s0);
      final id = ((s['id'] as String?) ?? '').trim();
      final name = ((s['name'] as String?) ?? '').trim();
      if (id.isEmpty || name.isEmpty) {
        throw CorpusPackageException('package.json 科目缺 id/name');
      }
      if (!seen.add(id)) {
        throw CorpusPackageException('package.json 科目短码重复：$id');
      }
      subjects.add(PackageSubjectSeed(
        id: id,
        name: name,
        textbook: (s['textbook'] as String?)?.trim(),
        chapters: (s['chapters'] as num?)?.toInt() ?? 0,
      ));
    }

    // corpus.db 落临时文件 → 只读校验（表齐全 + meta 可读 + 计数）
    final dbEntry = arc.files
        .firstWhere((e) => _normalizeEntryName(e.name) == '$prefix$_corpusDbName');
    final tmpDir = Directory.systemTemp.createTempSync('hengya-pkg-validate_');
    int chunks = 0, outlineEntries = 0;
    String? dbModelName;
    try {
      final tmpDb = File('${tmpDir.path}/$_corpusDbName');
      tmpDb.writeAsBytesSync(dbEntry.content);
      Database? db;
      try {
        db = sqlite3.open(tmpDb.path, mode: OpenMode.readOnly);
        final tables = {
          for (final r in db
              .select("SELECT name FROM sqlite_master WHERE type='table'"))
            r['name'] as String,
        };
        if (!tables.contains('chunks') || !tables.contains('meta')) {
          throw CorpusPackageException(
              'corpus.db 不是恒牙齿料库（缺 chunks/meta 表）');
        }
        chunks = db.select('SELECT COUNT(*) AS n FROM chunks').first['n'] as int;
        if (tables.contains('outline_entries')) {
          outlineEntries =
              db.select('SELECT COUNT(*) AS n FROM outline_entries').first['n']
                  as int;
        }
        dbModelName = (db
                .select("SELECT value FROM meta WHERE key = 'embedding_model'")
                .firstOrNull?['value']) as String?;
      } on CorpusPackageException {
        rethrow;
      } on SqliteException catch (e) {
        throw CorpusPackageException('corpus.db 无法读取：${e.message}');
      } finally {
        db?.dispose();
      }
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    }
    // 包自述模型与库内 meta 一致性（库内有模型才核；offline 库无模型放过）
    if (dbModelName != null &&
        dbModelName.isNotEmpty &&
        dbModelName.toLowerCase() != modelName.toLowerCase()) {
      throw CorpusPackageException(
          '包自述模型「$modelName」与库内 meta「$dbModelName」不一致（包损坏）');
    }

    final tocFiles = names
        .where((n) => n.startsWith('$prefix$_tocDirName/') && n.endsWith('.json'))
        .length;

    return CorpusPackageSummary(
      zipPath: zipPath,
      schemaVersion: kPackageSchemaVersion,
      appMinVersion: minV,
      modelName: modelName,
      dim: dim,
      builtAt: (pkg['builtAt'] as String?) ?? '',
      subjects: subjects,
      chunks: chunks,
      outlineEntries: outlineEntries,
      tocFiles: tocFiles,
      packageBytes: bytes.length,
      dbModelName: dbModelName,
      stats: pkg['stats'] is Map
          ? Map<String, Object?>.from(pkg['stats'] as Map)
          : const {},
    );
  }

  // ---------------- 导入 ----------------

  /// 备份 → 原子替换 → 补科目行 → 进度只补不改 → bumpDataVersion。
  /// 失败语义：任何一步失败都抛 [CorpusPackageException] 且不破坏原库
  /// （自动从备份回滚；无备份恢复「无库」原状）。
  Future<CorpusImportResult> importPackage(
    String dataDir,
    String zipPath, {
    String? appVersion,
    Future<void> Function()? onBeforeSwap,
  }) async {
    if (pipelineBusyCheck()) {
      throw CorpusPackageException(
          '拆卡流水线或建库任务正在运行，请等它结束后稍后再试');
    }
    final summary = validatePackage(zipPath, appVersion: appVersion); // 再验一次
    final corpusDir = Directory('$dataDir/corpus')
      ..createSync(recursive: true);
    final ts = _timestamp(DateTime.now());

    // ① 备份现有语料库（corpus.db 及 -wal/-shm、toc/、manifest）
    final bakDir = Directory('${corpusDir.path}/bak-$ts');
    String? backupPath;
    final backed = <String>[]; // 相对 corpusDir 的备份件清单（回滚用）
    if (_anyCorpusArtifact(corpusDir)) {
      bakDir.createSync(recursive: true);
      _backupArtifacts(corpusDir, bakDir, backed);
      backupPath = bakDir.path;
    }

    // ② 原子替换（临时目录先行，任一步失败回滚）
    final tmpDir = Directory('${corpusDir.path}/.import-tmp-$ts');
    try {
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      tmpDir.createSync(recursive: true);
      _extractContent(zipPath, tmpDir);
      debugHook?.call('after-extract');
      _verifyExtractedDb('${tmpDir.path}/$_corpusDbName');
      await onBeforeSwap?.call(); // 调用方关闭在用连接
      // 删旧 → rename 新到位（同卷 rename，DataManager 原子模式）
      _removeCorpusArtifacts(corpusDir);
      for (final item in tmpDir.listSync()) {
        item.renameSync(
            '${corpusDir.path}/${_basename(item.path)}');
      }
      debugHook?.call('after-swap');
    } catch (e) {
      // 回滚：清掉半套新件 → 备份件原样拷回（无备份则恢复「无库」原状）
      try {
        _removeCorpusArtifacts(corpusDir);
        if (backupPath != null) {
          _restoreBackup(bakDir, corpusDir, backed);
        }
      } catch (_) {} // 回滚尽力而为；原异常优先上报
      throw CorpusPackageException(
          e is CorpusPackageException ? e.message : '导入失败（已回滚原库）：$e');
    } finally {
      try {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    }

    // ③ 科目行（幂等）+ 模型对暗号 + bump
    final db = await Db.open('$dataDir/hengya.db');
    int added = 0, existing = 0;
    String? modelWarning;
    try {
      for (final s in summary.subjects) {
        if (db.ensureSubjectRow(s.id, s.name)) {
          added++;
        } else {
          existing++;
        }
      }
      final cur = (db.settingGet('embedding.model') ?? '').trim();
      if (cur.isNotEmpty &&
          summary.modelName.isNotEmpty &&
          cur.toLowerCase() != summary.modelName.toLowerCase()) {
        modelWarning =
            '本机向量模型「$cur」与语料包「${summary.modelName}」不一致，'
                '向量检索路将不可用（词面检索不受影响；可在 AI 服务配置中改一致）';
      }
      final (progressCreated, progressSynced) =
          _syncProgress(corpusDir.path, summary.subjects);
      db.bumpDataVersion();
      return CorpusImportResult(
        summary: summary,
        backupPath: backupPath,
        subjectsAdded: added,
        subjectsExisting: existing,
        progressCreated: progressCreated,
        progressSynced: progressSynced,
        modelWarning: modelWarning,
      );
    } finally {
      db.close();
    }
  }

  // ---------------- 进度同步（只补不改） ----------------

  /// 包内每科：progress.json 无条目 → 建（sidecar 有 → 全 0 真罗盘；无 →
  /// 无罗盘占位，applyChange 同款 history 记录）；已有条目 → 仅同步
  /// textbook/chapters（derm 占位升级），learned_through/skipped/history
  /// **分毫不动（不 clamp）**。chapters 落库前一律经 effectiveTocChapters
  /// 变换（真章救援+辅文过滤，稀疏保 no——与建库端同源；旧库垃圾章列表
  /// 借「已有条目同步」升级为干净列表）。返回 (created, synced实际变化数)。
  (int, int) _syncProgress(String corpusDir, List<PackageSubjectSeed> seeds) {
    final progressPath = '$corpusDir/progress.json';
    final data = loadProgress(progressPath);
    final subs = data['subjects'];
    if (subs is! Map) {
      return (0, 0); // loadProgress 保证存在；防御手工构造数据
    }
    var created = 0;
    var synced = 0;
    var mutated = false;
    for (final s in seeds) {
      final sidecar = _readSidecar('$corpusDir/$_tocDirName/${s.id}.json');
      final e0 = subs[s.id];
      if (e0 is! Map) {
        // 无条目 → 建
        if (sidecar != null) {
          subs[s.id] = <String, Object?>{
            'textbook': (sidecar['textbook'] as String?) ?? s.textbook,
            // 真章救援 + 辅文过滤（稀疏保 no；derm 占位升级为 29 真章）
            'chapters': effectiveTocChapters(sidecar),
            'learned_through': 0,
            'updated_at': nowIso(),
            'history': <Map<String, Object?>>[
              {
                'date': todayIso(),
                'from': 0,
                'to': 0,
                'evidence': '语料包导入创建科目条目',
                'source': 'package-import',
              },
            ],
          };
        } else {
          applyChange(
            data,
            s.id,
            0,
            source: 'package-import',
            allowCreate: true,
            createNote: '语料包导入自动创建占位科目（无罗盘）',
          );
        }
        created++;
        mutated = true;
        continue;
      }
      // 已有条目 → 仅同步 textbook/chapters（其余字段分毫不动；chapters
      // 与建库端同源走 effectiveTocChapters——旧库垃圾章列表借此升级）
      final newTextbook =
          ((sidecar?['textbook'] as String?) ?? s.textbook)?.trim();
      final newChapters =
          sidecar == null ? null : effectiveTocChapters(sidecar);
      var changed = false;
      if (newTextbook != null &&
          newTextbook.isNotEmpty &&
          (e0['textbook'] as String?) != newTextbook) {
        e0['textbook'] = newTextbook;
        changed = true;
      }
      if (newChapters is List && !_jsonEqual(e0['chapters'], newChapters)) {
        e0['chapters'] = newChapters;
        changed = true;
      }
      if (changed) {
        e0['updated_at'] = nowIso();
        synced++;
        mutated = true;
      }
    }
    if (mutated) {
      saveProgress(progressPath, data);
    }
    return (created, synced);
  }

  Map<String, Object?>? _readSidecar(String path) {
    final f = File(path);
    if (!f.existsSync()) return null;
    try {
      final obj = jsonDecode(f.readAsStringSync());
      if (obj is Map && obj['chapters'] is List) {
        return Map<String, Object?>.from(obj);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  bool _jsonEqual(Object? a, Object? b) {
    if (identical(a, b)) return true;
    try {
      return jsonEncode(a) == jsonEncode(b);
    } catch (_) {
      return false;
    }
  }

  // ---------------- 备份 / 换库 / 回滚 ----------------

  static const _walNames = ['corpus.db-wal', 'corpus.db-shm'];

  bool _anyCorpusArtifact(Directory corpusDir) {
    return File('${corpusDir.path}/$_corpusDbName').existsSync() ||
        File('${corpusDir.path}/$_manifestName').existsSync() ||
        Directory('${corpusDir.path}/$_tocDirName').existsSync();
  }

  /// 备份清单（相对名）：corpus.db、-wal/-shm、extract_manifest.json、toc/**。
  void _backupArtifacts(
      Directory corpusDir, Directory bakDir, List<String> backed) {
    void backupFile(String rel) {
      final src = File('${corpusDir.path}/$rel');
      if (src.existsSync()) {
        src.copySync('${bakDir.path}/$rel');
        backed.add(rel);
      }
    }

    backupFile(_corpusDbName);
    for (final w in _walNames) {
      backupFile(w);
    }
    backupFile(_manifestName);
    final toc = Directory('${corpusDir.path}/$_tocDirName');
    if (toc.existsSync()) {
      for (final f in _listFilesRecursive(toc)) {
        final rel = '$_tocDirName/${f.path.substring(toc.path.length + 1)}';
        final dest = File('${bakDir.path}/$rel');
        dest.parent.createSync(recursive: true);
        f.copySync(dest.path);
        backed.add(rel);
      }
    }
  }

  /// 删除现有语料库件（corpus.db/-wal/-shm/manifest/toc——file/dir 通吃）。
  void _removeCorpusArtifacts(Directory corpusDir) {
    void remove(String rel) {
      final p = '${corpusDir.path}/$rel';
      if (FileSystemEntity.typeSync(p) == FileSystemEntityType.directory) {
        Directory(p).deleteSync(recursive: true);
      } else if (FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound) {
        File(p).deleteSync();
      }
    }

    remove(_corpusDbName);
    for (final w in _walNames) {
      remove(w);
    }
    remove(_manifestName);
    remove(_tocDirName);
  }

  /// 回滚：备份件原样拷回 corpusDir（备份含 toc/** 的相对层级）。
  void _restoreBackup(Directory bakDir, Directory corpusDir, List<String> backed) {
    for (final rel in backed) {
      final src = File('${bakDir.path}/$rel');
      final dest = File('${corpusDir.path}/$rel');
      dest.parent.createSync(recursive: true);
      src.copySync(dest.path);
    }
  }

  void _verifyExtractedDb(String path) {
    Database? db;
    try {
      db = sqlite3.open(path, mode: OpenMode.readOnly);
      db.select('SELECT COUNT(*) AS n FROM chunks').first;
    } on SqliteException catch (e) {
      throw CorpusPackageException('解包后 corpus.db 校验失败：${e.message}');
    } finally {
      db?.dispose();
    }
  }

  /// 解包内容件到目标目录。**白名单**：只落 corpus.db、toc/**、
  /// extract_manifest.json（App 运行时数据面）。PC staging 的其余件
  /// （progress.json / incoming/** / chunks.jsonl / last_run.json 等——
  /// 节点②若整目录打包会带上）一概忽略：progress.json 是手机侧「只补不改」
  /// 数据绝不随包覆盖；incoming/ 是手机自有上传队列；chunks.jsonl 为建库
  /// 中间产物。package.json 只作元数据不落盘。
  void _extractContent(String zipPath, Directory outDir) {
    final arc = ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
    final String prefix;
    final names = [for (final e in arc.files) _normalizeEntryName(e.name)];
    if (names.contains('corpus/$_corpusDbName')) {
      prefix = 'corpus/';
    } else {
      prefix = ''; // validatePackage 已保证 corpus.db 在某形态下存在
    }
    for (final e in arc.files) {
      final n = _normalizeEntryName(e.name)!; // validate 已拒非法路径
      if (!e.isFile) continue;
      if (n == _pkgJsonName || n == 'corpus/$_pkgJsonName') continue;
      var rel = n.startsWith(prefix) ? n.substring(prefix.length) : '';
      if (rel.isEmpty) {
        // 前缀外的根级件：仅认 manifest 别名（两种布局都映射成
        // extract_manifest.json），其余（README 等）忽略
        if (n == 'manifest' || n == 'manifest.json') {
          rel = _manifestName;
        } else {
          continue;
        }
      } else if (rel == 'manifest' || rel == 'manifest.json') {
        rel = _manifestName;
      }
      // 白名单：corpus.db / toc/** / extract_manifest.json（其余全忽略）
      if (rel != _corpusDbName &&
          rel != _manifestName &&
          !rel.startsWith('$_tocDirName/')) {
        continue;
      }
      if (_isJunkPath(rel)) continue;
      final dest = File('${outDir.path}/$rel');
      dest.parent.createSync(recursive: true);
      dest.writeAsBytesSync(e.content);
    }
  }

  // ---------------- 小工具 ----------------

  /// 归一化条目名：反斜杠→正斜杠、去 './' 前缀；路径穿越/绝对路径 → null。
  static String? _normalizeEntryName(String raw) {
    var n = raw.replaceAll('\\', '/');
    while (n.startsWith('./')) {
      n = n.substring(2);
    }
    if (n.isEmpty || n.startsWith('/')) return null;
    if (RegExp(r'^[A-Za-z]:').hasMatch(n)) return null;
    for (final seg in n.split('/')) {
      if (seg == '..') return null;
    }
    return n;
  }

  /// 打包器垃圾件（__MACOSX / .DS_Store / ._* 资源叉）静默跳过。
  static bool _isJunkPath(String rel) {
    final base = _basename(rel);
    return rel.contains('__MACOSX/') ||
        base == '.DS_Store' ||
        base.startsWith('._');
  }

  /// 基名（双分隔符：构造路径用 '/'，Windows listSync 回报 '\'——两者都认，
  /// 否则 rename 目标会解析回源路径自身变成 no-op）。
  static String _basename(String p) {
    final i = p.lastIndexOf('/');
    final j = p.lastIndexOf('\\');
    final k = i > j ? i : j;
    return k < 0 ? p : p.substring(k + 1);
  }

  static List<File> _listFilesRecursive(Directory dir) {
    final out = <File>[];
    for (final e in dir.listSync(recursive: true)) {
      if (e is File) out.add(e);
    }
    return out;
  }

  /// 语义化版本下界：a < b（'1.8.0+16' 的 +build 段忽略；非数字段按 0；
  /// 任一不可解析 → false 不拦）。appMinVersion 形如 '1.8.0'。
  static bool _versionBelow(String a, String b) {
    List<int>? parse(String v) {
      final head = v.split('+').first;
      final parts = head.split('.');
      final nums = <int>[];
      for (final p in parts) {
        final n = int.tryParse(p.trim());
        if (n == null) return null;
        nums.add(n);
      }
      return nums;
    }

    final va = parse(a);
    final vb = parse(b);
    if (va == null || vb == null) return false;
    final n = va.length > vb.length ? va.length : vb.length;
    for (var i = 0; i < n; i++) {
      final x = i < va.length ? va[i] : 0;
      final y = i < vb.length ? vb[i] : 0;
      if (x != y) return x < y;
    }
    return false;
  }

  static String _timestamp(DateTime t) =>
      '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
      '-${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}'
      '${t.second.toString().padLeft(2, '0')}-${t.millisecond.toString().padLeft(3, '0')}';
}
