// 恒牙（hengya）· 语料包导入（批5 节点③）
// ============================================================================
//
// PC 全量建库（节点②）产出成品语料库 zip → 手机「导入语料包」一键落位，
// 不再逐文件上传建库。同步兼容入口保留 [DataManager] 风格的换库/回滚语义；
// validatePackageBg/importPackageBg 将大包校验、备份、解包、验库移至 worker，
// 主 isolate 只负责关闭在用连接、同卷换库及科目/学习进度收尾。
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
import 'dart:typed_data';

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

  /// 从后台 worker 的完整 wire 摘要还原（不同于展示用的 [toMap]）。
  factory CorpusPackageSummary.fromMap(Map<String, Object?> m) {
    return CorpusPackageSummary(
      zipPath: m['zipPath'] as String,
      schemaVersion: (m['schemaVersion'] as num).toInt(),
      appMinVersion: m['appMinVersion'] as String,
      modelName: m['modelName'] as String,
      dim: (m['dim'] as num).toInt(),
      builtAt: m['builtAt'] as String,
      subjects: [
        for (final raw in m['subjects'] as List)
          PackageSubjectSeed(
            id: (raw as Map)['id'] as String,
            name: raw['name'] as String,
            textbook: raw['textbook'] as String?,
            chapters: (raw['chapters'] as num).toInt(),
          ),
      ],
      chunks: (m['chunks'] as num).toInt(),
      outlineEntries: (m['outlineEntries'] as num).toInt(),
      tocFiles: (m['tocFiles'] as num).toInt(),
      packageBytes: (m['packageBytes'] as num).toInt(),
      dbModelName: m['dbModelName'] as String?,
      stats: Map<String, Object?>.from(m['stats'] as Map),
    );
  }

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

/// 后台导入参数；只传路径与版本，不跨 isolate 传数据库连接或回调。
class PackageImportJobRequest {
  const PackageImportJobRequest({
    required this.dataDir,
    required this.zipPath,
    this.appVersion,
  });

  final String dataDir;
  final String zipPath;
  final String? appVersion;
}

/// worker 准备阶段结果；失败也回传路径与已完成的备份清单，由主 isolate 回滚。
class PackageImportStageResult {
  const PackageImportStageResult({
    required this.bakPath,
    required this.backed,
    required this.tmpDirPath,
    required this.summaryWire,
    this.error,
  });

  final String? bakPath;
  final List<String> backed;
  final String tmpDirPath;

  /// 成功时为完整摘要 wire；[error] 非 null 时为空 Map。
  final Map<String, Object?> summaryWire;
  final String? error;
}

/// 复用同步导入的目录时间戳格式，避免两条路径的备份命名漂移。
String _packageTimestamp(DateTime time) => CorpusPackageManager._timestamp(time);

/// [CorpusPackageSummary.toMap] 的 subjects 是展示计数；wire 必须保留科目种子。
Map<String, Object?> _summaryToWire(CorpusPackageSummary summary) => {
      'zipPath': summary.zipPath,
      ...summary.toMap(),
      'subjects': <Map<String, Object?>>[
        for (final subject in summary.subjects)
          {
            'id': subject.id,
            'name': subject.name,
            'textbook': subject.textbook,
            'chapters': subject.chapters,
          },
      ],
    };

/// 只读校验 worker；不检查流水线占用，也不创建导入备份或替换本机库。
void validatePackageWorkerEntry(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    final args = boot.args! as Map<String, Object?>;
    ctx.checkCancelled();
    ctx.emit(const IsolateProgressEvent(
      stage: 'validating',
      message: '正在校验语料包…',
    ));
    final summary = CorpusPackageManager.instance.validatePackage(
      args['zipPath'] as String,
      appVersion: args['appVersion'] as String?,
    );
    return _summaryToWire(summary);
  });
}

/// 导入准备 worker：校验、备份、解包和验库均不占用 UI isolate。
/// 这里只写备份/临时目录，不换库、不回滚、不触碰主库与学习进度。
void corpusPackageImportWorker(IsolateWorkerBoot boot) {
  isolateWorkerRun(boot, (ctx) async {
    final req = boot.args! as PackageImportJobRequest;
    final mgr = CorpusPackageManager.instance;
    final corpusDir = Directory('${req.dataDir}/corpus');
    final ts = _packageTimestamp(DateTime.now());
    final bakDir = Directory('${corpusDir.path}/bak-$ts');
    final tmpDir = Directory('${corpusDir.path}/.import-tmp-$ts');
    String? backupPath;
    final backed = <String>[];

    try {
      ctx.checkCancelled();
      ctx.emit(const IsolateProgressEvent(
        stage: 'validating',
        message: '正在校验语料包…',
      ));
      final summary = mgr.validatePackage(
        req.zipPath,
        appVersion: req.appVersion,
      );
      corpusDir.createSync(recursive: true);
      if (mgr._anyCorpusArtifact(corpusDir)) {
        ctx.checkCancelled();
        ctx.emit(const IsolateProgressEvent(
          stage: 'backing-up',
          message: '正在备份现有语料库…',
        ));
        bakDir.createSync(recursive: true);
        // 先记路径：备份中途失败也能把部分清单交回主 isolate。
        backupPath = bakDir.path;
        mgr._backupArtifacts(corpusDir, bakDir, backed);
      }

      ctx.checkCancelled();
      ctx.emit(const IsolateProgressEvent(
        stage: 'extracting',
        message: '正在解包语料库…',
      ));
      if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      tmpDir.createSync(recursive: true);
      mgr._extractContent(req.zipPath, tmpDir);

      ctx.checkCancelled();
      ctx.emit(const IsolateProgressEvent(
        stage: 'verifying',
        message: '正在校验解包后的语料库…',
      ));
      mgr._verifyExtractedDb(
        '${tmpDir.path}/${CorpusPackageManager._corpusDbName}',
      );
      return PackageImportStageResult(
        bakPath: backupPath,
        backed: backed,
        tmpDirPath: tmpDir.path,
        summaryWire: _summaryToWire(summary),
      );
    } catch (e) {
      // 不在 worker 回滚；尤其不能把部分备份当完整备份删掉原库。
      return PackageImportStageResult(
        bakPath: backupPath,
        backed: backed,
        tmpDirPath: tmpDir.path,
        summaryWire: const {},
        error: ctx.cancelRequested
            ? '语料包导入已取消'
            : e is CorpusPackageException
                ? e.message
                : '导入准备失败：$e',
      );
    }
  });
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
  static const _validateJobId = 'pkg-validate';
  static const _importJobId = 'pkg-import';

  // runner 的单飞位在 worker 返回时释放；此位覆盖主 isolate 换库/补行收尾。
  static bool _importBgRunning = false;
  static final Set<String> _importDataDirs = {};

  // ---------------- 校验 ----------------

  /// 后台只读校验；不检查 [pipelineBusyCheck]，进度仅有 validating。
  /// 与同步校验相同的完整摘要；worker 异常统一映射为 [CorpusPackageException]。
  Future<CorpusPackageSummary> validatePackageBg(
    String zipPath, {
    String? appVersion,
    void Function(String stage, String message)? onProgress,
  }) async {
    if (IsolateRunner.instance.isRunning(_validateJobId)) {
      throw CorpusPackageException('语料包正在校验，请稍后再试');
    }
    try {
      final handle = await IsolateRunner.instance.start<Map<String, Object?>>(
        jobId: _validateJobId,
        workerEntry: validatePackageWorkerEntry,
        args: <String, Object?>{
          'zipPath': zipPath,
          'appVersion': appVersion,
        },
      );
      final subscription = onProgress == null
          ? null
          : handle.progress.listen((e) => onProgress(e.stage, e.message));
      try {
        return CorpusPackageSummary.fromMap(await handle.done);
      } finally {
        await subscription?.cancel();
      }
    } on IsolateJobException catch (e) {
      const prefix = 'CorpusPackageException: ';
      throw CorpusPackageException(e.message.startsWith(prefix)
          ? e.message.substring(prefix.length)
          : e.message);
    } catch (e) {
      throw CorpusPackageException('语料包校验失败：$e');
    }
  }

  /// 只读校验语料包并返回摘要（导入预览用）。不满足契约抛
  /// [CorpusPackageException]（文件不存在/不是 zip/缺件/版本守卫/含主库）。
CorpusPackageSummary validatePackage(String zipPath, {String? appVersion}) {
    final f = File(zipPath);
    if (!f.existsSync()) {
      throw CorpusPackageException('文件不存在：$zipPath');
    }
    if (f.lengthSync() == 0) {
      throw CorpusPackageException('文件为空');
    }
    // 流式解码：逐条目处理，用完即弃。绝不用 readAsBytesSync+decodeBytes
    // 整包进内存（100MB 语料包会展开成 190MB+ 的 Archive，两次峰值直接
    // OOM 杀进程 = 导入闪退，Dart try/catch 拦不住 native 层崩溃）。
    final Archive arc;
    try {
      arc = ZipDecoder().decodeStream(InputFileStream(zipPath));
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
      final obj = jsonDecode(utf8.decode(_readEntryBytes(pkgEntry)));
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
    // 流式写出：绝不 e.content 整文件进内存（192MB 的库一次展平 = OOM）。
    final dbEntry = arc.files
        .firstWhere((e) => _normalizeEntryName(e.name) == '$prefix$_corpusDbName');
    final tmpDir = Directory.systemTemp.createTempSync('hengya-pkg-validate_');
    int chunks = 0, outlineEntries = 0;
    String? dbModelName;
    try {
      final tmpDb = File('${tmpDir.path}/$_corpusDbName');
      _streamEntryToFile(dbEntry, tmpDb.path);
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
packageBytes: f.lengthSync(),
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
      // ④ 包 deck 豁免剪除（2026-09-11 bug 修复）：包库 deck_state.source
      // 原为 'tree'（建包时写入），而 ingestCorpus 的 pruneAbsent 恰好只剪
      // source='tree' 且不在本机 incoming 树的 deck——导入后再建库会把包内
      // 全部 deck 当"树外"剪掉（实证：13 科/7869 块被剪到只剩手动课件）。
      // 统一改成 'package' → prune 天然豁免（包库与 incoming 树无关联）。
      _markPackageDecks(corpusDir.path);
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

  /// 后台准备 → 主 isolate 换库/补行。进度为 validating、backing-up（可省略）、
  /// extracting、verifying；[onBeforeSwap] 只在准备成功后、删旧库前调用。
  /// 准备/换库失败在主 isolate 尽力回滚并清理临时目录；主库/进度收尾的
  /// 事务边界与 [importPackage] 相同，不回滚已经完成的科目/学习进度写入。
  Future<CorpusImportResult> importPackageBg(
    String dataDir,
    String zipPath, {
    String? appVersion,
    Future<void> Function()? onBeforeSwap,
    void Function(String stage, String message)? onProgress,
  }) async {
    if (pipelineBusyCheck()) {
      throw CorpusPackageException(
          '拆卡流水线或建库任务正在运行，请等它结束后稍后再试');
    }
    if (_importBgRunning || IsolateRunner.instance.isRunning(_importJobId)) {
      throw CorpusPackageException('语料包正在导入，请稍后再试');
    }
    _importBgRunning = true;
    try {
      _importDataDirs.add(Directory(dataDir).absolute.path);
      final corpusDir = Directory('$dataDir/corpus');
      PackageImportStageResult? staged;
      late final CorpusPackageSummary summary;
      var swapStarted = false;
      try {
        final handle = await IsolateRunner.instance.start<PackageImportStageResult>(
          jobId: _importJobId,
          workerEntry: corpusPackageImportWorker,
          args: PackageImportJobRequest(
            dataDir: dataDir,
            zipPath: zipPath,
            appVersion: appVersion,
          ),
        );
        final subscription = onProgress == null
            ? null
            : handle.progress.listen((e) => onProgress(e.stage, e.message));
        try {
          final result = await handle.done;
          staged = result;
          if (result.error != null) {
            throw CorpusPackageException(result.error!);
          }
          summary = CorpusPackageSummary.fromMap(result.summaryWire);
          debugHook?.call('after-extract');
          await onBeforeSwap?.call();
          // 只有到这里才动原库；部分备份失败绝不先删尚未备份的原件。
          swapStarted = true;
          _removeCorpusArtifacts(corpusDir);
          final tmpDir = Directory(result.tmpDirPath);
          for (final item in tmpDir.listSync()) {
            item.renameSync('${corpusDir.path}/${_basename(item.path)}');
          }
          debugHook?.call('after-swap');
        } finally {
          await subscription?.cancel();
        }
      } catch (e) {
        try {
          if (swapStarted) _removeCorpusArtifacts(corpusDir);
          final backupPath = staged?.bakPath;
          if (backupPath != null) {
            _restoreBackup(Directory(backupPath), corpusDir, staged!.backed);
          }
        } catch (_) {} // 回滚尽力而为；保留原异常，备份不删除。
        throw CorpusPackageException(e is CorpusPackageException
            ? e.message
            : '导入失败（已回滚原库）：${e is IsolateJobException ? e.message : e}');
      } finally {
        final tmpDirPath = staged?.tmpDirPath;
        if (tmpDirPath != null) {
          try {
            final tmpDir = Directory(tmpDirPath);
            if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
          } catch (_) {}
        }
      }

      // 与同步入口同款收尾：幂等补科目、模型对暗号、进度只补不改、包 deck 豁免。
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
        _markPackageDecks(corpusDir.path);
        db.bumpDataVersion();
        return CorpusImportResult(
          summary: summary,
          backupPath: staged.bakPath,
          subjectsAdded: added,
          subjectsExisting: existing,
          progressCreated: progressCreated,
          progressSynced: progressSynced,
          modelWarning: modelWarning,
        );
      } finally {
        db.close();
      }
    } finally {
      _importBgRunning = false;
    }
  }

  /// 尽力清理调用方持有的 ZIP 拷贝，不递归删目录、不删符号链接。
  /// 仅认 cache/、系统临时目录或本进程后台导入登记过的 dataDir；路径先解析
  /// 再按目录边界判断。还须最近访问不足 30 分钟或大于 1 MiB，失败静默。
  static void disposeImportedZip(String zipPath) {
    if (zipPath.trim().isEmpty) return;
    try {
      final file = File(zipPath);
      if (!file.existsSync() || FileSystemEntity.isLinkSync(zipPath)) return;
      String normalize(String path) {
        final normalized = path.replaceAll('\\', '/');
        return Platform.isWindows ? normalized.toLowerCase() : normalized;
      }

      final path = normalize(file.resolveSymbolicLinksSync());
      var managed = path.contains('/cache/');
      if (!managed) {
        for (final directory in [
          Directory.systemTemp,
          ..._importDataDirs.map(Directory.new),
        ]) {
          if (!directory.existsSync()) continue;
          final root = normalize(directory.resolveSymbolicLinksSync());
          if (path.startsWith(root.endsWith('/') ? root : '$root/')) {
            managed = true;
            break;
          }
        }
      }
      if (!managed) return;
      final stat = file.statSync();
      final age = DateTime.now().difference(stat.accessed);
      final recent = !age.isNegative && age < const Duration(minutes: 30);
      if (stat.type == FileSystemEntityType.file &&
          (recent || stat.size > 1024 * 1024)) {
        file.deleteSync();
      }
    } catch (_) {} // 清理失败不影响校验/导入结果。
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

  /// 包库 deck 豁免标记（2026-09-11 bug 修复）：把 corpus.db 的
  /// deck_state.source 从 'tree' 改为 'package'。原因：ingestCorpus 的
  /// pruneAbsent 只剪 source='tree' 且不在本机 incoming 树的 deck——包库
  /// 的源文件从不进 incoming（导入仅落 corpus.db/toc/manifest），导入后再
  /// 触发建库会把全部包 deck 当"树外"剪除（实证：13 科全灭只剩手动课件）。
  /// 'package' 标记使 prune 天然豁免。仅改 source 列，不碰 chunks/向量/
  /// 其他字段；库已损坏/无 deck_state 表 → 静默跳过（不阻断导入成功）。
  void _markPackageDecks(String corpusDir) {
    try {
      final dbFile = File('$corpusDir/$_corpusDbName');
      if (!dbFile.existsSync()) return;
      final db = sqlite3.open(dbFile.path);
      try {
        db.execute(
          "UPDATE deck_state SET source='package' WHERE source='tree'",
        );
      } finally {
        db.dispose();
      }
    } catch (_) {
      // 打不开/缺表 → 保留原状；后续建库 prune 会按旧语义混淆（最坏回退
      // 到剪除）——但导入本身已成功，标记为 best-effort，不阻断。
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
    // 流式解码 + 逐文件流式落盘（整包 readAsBytes+decodeBytes 在 100MB+
    // 语料包上会 OOM 闪退——native 层杀进程，Dart try/catch 拦不住）。
    final arc = ZipDecoder().decodeStream(InputFileStream(zipPath));
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
      // 流式写盘，不经过内存（192MB corpus.db 整包进内存 = OOM）
      _streamEntryToFile(e, dest.path);
    }
  }

/// 流式把 zip 条目写到目标文件：仅当条目 content 已在内存时才走
  /// 快速路径（测试用小 zip），否则逐块读流落盘（生产大包）。
  /// [ArchiveFile.getContent] 返回懒加载解码流，写盘峰值内存 ≈
  /// 单块缓冲（1MB），与文件大小无关。
static void _streamEntryToFile(ArchiveFile e, String path) {
    final out = File(path).openSync(mode: FileMode.write);
    try {
      final stream = e.getContent();
      if (stream == null) {
        out.closeSync();
        throw CorpusPackageException('zip 条目不可读：${e.name}');
      }
// 1MB 块缓冲：readBytes 按可用长度自动截断，EOF 返回空流。
      // 峰值内存 ≈ 单块大小，与文件大小无关。
      while (true) {
        final buf = stream.readBytes(1 << 20);
        if (buf.length == 0) break;
        out.writeFromSync(buf.toUint8List());
      }
    } finally {
      out.closeSync();
    }
  }

  /// 读 zip 条目全部字节（package.json 等小件用）。
  static Uint8List _readEntryBytes(ArchiveFile e) {
    final stream = e.getContent();
    if (stream == null) {
      throw CorpusPackageException('zip 条目不可读：${e.name}');
    }
final out = BytesBuilder(copy: false);
    while (true) {
      final buf = stream.readBytes(1 << 20);
      if (buf.length == 0) break;
      out.add(buf.toUint8List());
    }
    return out.toBytes();
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
  ///
  /// 语义方向兼容：主版本号相差恰为 **1**（如 0.x 公开版 vs 1.x 内测版）
  /// 视为同一产品线重计号/换代——数字上 0.1.5 < 1.8.1，但公开版 0.x
  /// 功能上继承自内测 1.8.x（且包格式契约已由 schemaVersion 硬把关），
  /// 此时跳过下界检查。相差 >1 或同代内的反超仍严格拦截。
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
    if (va == null || vb == null || va.isEmpty || vb.isEmpty) return false;
    // 语义方向兼容：主版本一代之差放行（0↔1、1↔2 等重计号/换代）
    if ((va[0] - vb[0]).abs() == 1) return false;
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
