// 恒牙（hengya）· 语料包建库工具（节点①：语料补齐+建库工具+冒烟）
// ============================================================================
//
// PC 端全量建库入口（纯 Dart，不 import Flutter；cwd 必须是 app/——Windows 下
// sqlite3.dll（test/sqlite3.dll）与 pdfium.dll（test/fixtures/pdfium/win-x64/）
// 均按 cwd=app/ 相对解析，同 tool/corpus_build_probe.dart 基建）。
//
// 用法（cwd=app/）：
//   dart run tool/build_corpus_package.dart --staging <dir>
//       [--subjects derm,prevent] [--source <ppt_raw 根>]
//       [--mode online|offline|drill] [--batch N] [--force-full] [--log <file>]
//
//   dart run tool/build_corpus_package.dart --fix-toc --staging <dir>
//       [--zip-dir <目录>] [--zip-name <文件名>] [--log <file>]
//
//   --staging   staging 数据目录（建议全新干净目录；布局 = App dataDir 同构，
//               见下「staging 结构」）
//   --subjects  科目过滤（逗号分隔 13 科短码，如 derm,prevent）——只拷这些科
//               的教材树与课件树，跳过真题专题与大纲（小样本冒烟用；缺省=全量
//               四源全拷）
//   --source    语料树根（默认 D:/hengya/content/ppt_raw；**本工具对其只读**，
//               绝不写 D:/hengya/content 任何内容）
//   --mode      online（默认；Gitee 真实嵌入，需环境变量 GITEE_AI_KEY）|
//               offline（不写向量）| drill（确定性伪向量，零网络）
//   --batch     嵌入批量（默认 32）
//   --force-full无视 manifest 增量，全量重抽
//   --log       输出同时追加落 UTF-8 日志文件（控制台编码与日志解耦）
//
//   --fix-toc   【数据变换模式】不建库、不跑抽取/嵌入，全程零网络零 API key：
//               ① staging corpus/toc/*.json 逐科调 effectiveTocChapters
//               （toc_chapters.dart 唯一口径：真章救援/辅文过滤/标题去
//               「 / 页码」尾）重写 chapters（sections/subject/textbook/
//               version 原样保留，updated_at 刷新）；**原始件先备份到
//               corpus/toc-orig/**（绝不备份成 toc/ 下的 .bak/.json 副本——
//               tocSidecarSubjects 只 glob toc/*.json 会重复计数）；已达标科
//               幂等跳过不落盘（保 mtime）。② 复核：幂等 / 与原始件推导一致 /
//               编号语义（救援=重编 1..N、过滤=原 no 稀疏保位）/ 标题干净。
//               ③ 罗盘 progress.json 重建（initFromTocSidecar 逐科目，
//               learned_through/history 不改写）。④ b 版语料包重打包（白名单
//               =根级 package.json + corpus/{corpus.db,toc/,extract_manifest.
//               json}；package.json 章数取变换后 sidecar）。⑤ 自检：白名单/
//               零密钥字节扫描/包内库 sha256=原库/**corpus.db 开跑前后字节
//               不变（向量库铁律，本模式全程只读）**。与 --subjects/--source/
//               --mode/--batch/--force-full 互斥。
//   --zip-dir   b 版包产出目录（默认 D:/heng/update-dist）
//   --zip-name  b 版包文件名（默认 heng-corpus-1.8.1-20260908b.zip；
//               只允许纯文件名）
//
// 环境变量：GITEE_AI_KEY（--mode online 必填；**仅进程内使用**——绝不下沉到
// staging settings/日志/结果/异常文本，密钥纪律同 App 侧 CorpusBuildRequest）。
//
// staging 结构（产物；节点②打包 zip 直接复用，不含密钥）：
//   <staging>/hengya.db                       主库（settings embedding.model/
//                                              baseUrl 已指 Gitee；apiKey 不落盘）
//   <staging>/corpus/incoming/<短码>-textbook/ 教材树 ×13
//   <staging>/corpus/incoming/<短码>-exam/     真题专题树 ×12
//   <staging>/corpus/incoming/dagang-outline/  大纲 DOCX ×2（人文 PDF 不拷）
//   <staging>/corpus/incoming/<短码>/          课件树（endo/oms）
//   <staging>/corpus/corpus.db                 语料库（chunks/vectors/FTS/
//                                              outline_entries/vec_chunks）
//   <staging>/corpus/chunks.jsonl + extract_manifest.json
//   <staging>/corpus/toc/<短码>.json            教材 toc sidecar（罗盘输入）
//   <staging>/corpus/progress.json             罗盘（toc sidecar 自动初始化 +
//                                              med 占位）
//
// 建库链路照抄 App worker（corpus_build_job.corpusBuildWorkerEntry，同函数同参
// 进程内直跑，不重造）：extractAllCorpus → outline.ingestOutlineFiles →
// ensureMedSubjectPlaceholder → ingestCorpus(pruneAbsent:true) → 罗盘
// initFromTocSidecar（local_backend._initCompassFromToc 同款）。嵌入配置从
// staging hengya.db settings 读取并按 local_backend._selectBuildMode 同款规则
// 补 /embeddings 尾；唯一差异：apiKey 只从环境变量来、不落盘（密钥纪律优先）。
import 'dart:convert' as convert;
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:archive/archive.dart'
    show Archive, ArchiveFile, ZipDecoder, ZipEncoder;
import 'package:hengya/services/local/corpus/exam_topics.dart';
import 'package:hengya/services/local/corpus/extract_all.dart'
    show
        CorpusEmbedConfig,
        CorpusEmbedMode,
        IngestStats,
        atomicWriteText,
        extractAllCorpus,
        ingestCorpus,
        kDefaultBatch,
        nowIso,
        openCorpusDb;
import 'package:hengya/services/local/corpus/extract_pptx.dart' as pptx;
import 'package:hengya/services/local/corpus/outline_docx.dart' as outline;
import 'package:hengya/services/local/corpus/progress_db.dart'
    show initFromTocSidecar, loadProgress, saveProgress, tocSidecarSubjects;
import 'package:hengya/services/local/corpus/run_engine.dart'
    show normChapterTitle, stripChapterPageSuffix;
import 'package:hengya/services/local/corpus/search_engine.dart'
    show kVec0Table;
import 'package:hengya/services/local/corpus/toc_chapters.dart'
    show effectiveTocChapters, kTocJunkExact;
import 'package:hengya/services/local/corpus_build_job.dart'
    show ensureMedSubjectPlaceholder;
import 'package:hengya/services/local/db.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

/// 13 科短码（教材树 `<短码>-textbook` / 课件树 `<短码>` 的短码口径）。
const List<String> kSubjectCodes = [
  'anatomy',
  'endo',
  'peri',
  'mucosa',
  'oms',
  'prostho',
  'imaging',
  'pedo',
  'prevent',
  'patho',
  'ortho',
  'implant',
  'derm',
];

/// Gitee AI（模力方舟）嵌入通道（2026-09-07 实测全绿；模型名拍板**无 Qwen/
/// 前缀**，原生 1024 维）。settings 存基址形态（…/v1），装配时补 /embeddings。
const String kGiteeEmbedBase = 'https://ai.gitee.com/v1';
const String kGiteeEmbedModel = 'Qwen3-VL-Embedding-8B';

/// 密钥环境变量名（仅进程内使用；值绝不打印/落盘）。
const String kEnvKey = 'GITEE_AI_KEY';

/// 大纲与考纲源目录名（<source>/exam/ 下）；只拷其中 .docx（两份人文 PDF
/// 不进语料包——拍板口径）。
const String kOutlineSourceDirName = '大纲与考纲';

/// 13 科短码 → 中文名（--fix-toc b 版包 package.json subjects[].name 种子；
/// 与节点② node2_package.py 的 SUBJ_NAMES 逐字一致——App 端 ensureSubjectRow
/// 依赖此名，勿改动拼写）。
const Map<String, String> kSubjectNames = {
  'anatomy': '口腔解剖生理学',
  'endo': '牙体牙髓病学',
  'peri': '牙周病学',
  'mucosa': '口腔黏膜病学',
  'oms': '口腔颌面外科学',
  'prostho': '口腔修复学',
  'imaging': '口腔颌面医学影像诊断学',
  'pedo': '儿童口腔医学',
  'prevent': '口腔预防医学',
  'patho': '口腔组织病理学',
  'ortho': '口腔正畸学',
  'implant': '口腔种植学',
  'derm': '皮肤性病学',
};

/// --fix-toc 模式 b 版包默认产出目录。
const String kFixTocDefaultZipDir = 'D:/heng/update-dist';

/// --fix-toc 模式 b 版包默认产物名（与旧包 heng-corpus-1.8.1-20260908.zip
/// 以 b 后缀区分）。
const String kFixTocDefaultZipName = 'heng-corpus-1.8.1-20260908b.zip';

// ------------------------------------------------------------- 输出 ----

/// stdout + 可选 UTF-8 日志文件双写（追加；密钥永不经过本函数）。
void Function(String) makeOut(String? logPath) {
  IOSink? sink;
  if (logPath != null) {
    final f = File(logPath);
    f.parent.createSync(recursive: true);
    sink = f.openWrite(mode: FileMode.append, encoding: convert.utf8);
  }
  return (String m) {
    stdout.writeln(m);
    sink?.writeln(m);
  };
}

// ------------------------------------------------------------- 工具 ----

/// 规范化路径（小写、反斜杠）供 Windows 包含关系判断。
String _normPath(String p) =>
    File(p).absolute.path.replaceAll('/', '\\').toLowerCase();

/// b 是否等于 a 或位于 a 之下（防 staging 与语料树互相污染）。
bool _isInside(String a, String b) {
  final na = _normPath(a);
  final nb = _normPath(b);
  return nb == na || nb.startsWith('$na\\');
}

/// 递归拷贝目录；filter 可筛扩展名。同尺寸已存在 → 跳过（**保留目标 mtime**，
/// 让 manifest 增量命中——幂等重跑不重抽、不重嵌）。源树缺失 → 计 missing。
({int copied, int skipped, bool missing}) copyTree(
  Directory src,
  Directory dst, {
  bool Function(File f)? filter,
}) {
  if (!src.existsSync()) return (copied: 0, skipped: 0, missing: true);
  var copied = 0;
  var skipped = 0;
  var root = src.path;
  while (root.endsWith('/') || root.endsWith('\\')) {
    root = root.substring(0, root.length - 1);
  }
  for (final e in src.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    if (filter != null && !filter(e)) continue;
    final rel = e.path.substring(root.length);
    final target = File('${dst.path}$rel');
    if (target.existsSync() && target.lengthSync() == e.lengthSync()) {
      skipped++;
      continue;
    }
    target.parent.createSync(recursive: true);
    e.copySync(target.path);
    copied++;
  }
  return (copied: copied, skipped: skipped, missing: false);
}

/// 表行数（表不存在 → -1）。
int _countOf(Database db, String table) {
  try {
    return db.select('SELECT count(*) FROM "$table"').first.columnAt(0) as int;
  } catch (_) {
    return -1;
  }
}

// ------------------------------------------------------------- 主流程 ----

Future<void> main(List<String> argv) async {
  if (Platform.isWindows) {
    // Windows 测试宿主同款基建：显式加载 test/sqlite3.dll（cwd=app/）
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => ffi.DynamicLibrary.open(dll));
  }

  // ---- 参数解析 ----
  String? stagingArg;
  String? subjectsArg;
  var sourceArg = 'D:/hengya/content/ppt_raw';
  var mode = 'online';
  var batch = kDefaultBatch;
  var forceFull = false;
  String? logArg;
  var fixToc = false;
  String? zipDirArg;
  String? zipNameArg;
  final seenArgs = <String>{}; // 建库专属 flag 显式传入追踪（--fix-toc 互斥用）
  for (var i = 0; i < argv.length; i++) {
    final a = argv[i];
    if (a == '--staging') {
      stagingArg = argv[++i];
    } else if (a == '--subjects') {
      subjectsArg = argv[++i];
      seenArgs.add('--subjects');
    } else if (a == '--source') {
      sourceArg = argv[++i];
      seenArgs.add('--source');
    } else if (a == '--mode') {
      mode = argv[++i];
      seenArgs.add('--mode');
    } else if (a == '--batch') {
      batch = int.parse(argv[++i]);
      seenArgs.add('--batch');
    } else if (a == '--force-full') {
      forceFull = true;
      seenArgs.add('--force-full');
    } else if (a == '--fix-toc') {
      fixToc = true;
    } else if (a == '--zip-dir') {
      zipDirArg = argv[++i];
    } else if (a == '--zip-name') {
      zipNameArg = argv[++i];
    } else if (a == '--log') {
      logArg = argv[++i];
    } else {
      stderr.writeln('未知参数：$a');
      exitCode = 2;
      return;
    }
  }
  if (stagingArg == null || stagingArg.trim().isEmpty) {
    stderr.writeln('缺少 --staging <目录>（staging 数据目录，建议全新干净目录）');
    exitCode = 2;
    return;
  }

  // ---- 模式分叉：--fix-toc = toc 变换 + 罗盘重建 + b 版重打包（不建库）----
  if (fixToc) {
    final buildOnly = [
      for (final f in const [
        '--subjects',
        '--source',
        '--mode',
        '--batch',
        '--force-full',
      ])
        if (seenArgs.contains(f)) f,
    ];
    if (buildOnly.isNotEmpty) {
      stderr.writeln('--fix-toc 与建库参数互斥：${buildOnly.join(',')}'
          '（数据变换模式不建库、不需要语料树与嵌入配置）');
      exitCode = 2;
      return;
    }
    final zipName = (zipNameArg ?? '').trim();
    if (zipName.contains('/') ||
        zipName.contains('\\') ||
        zipName.contains('..')) {
      stderr.writeln('--zip-name 只允许纯文件名（禁路径分隔/穿越片段）');
      exitCode = 2;
      return;
    }
    final zipDirIn = (zipDirArg ?? '').trim();
    await _runFixToc(
      staging: Directory(stagingArg)..createSync(recursive: true),
      out: makeOut(logArg),
      zipDir: zipDirIn.isEmpty ? kFixTocDefaultZipDir : zipDirIn,
      zipName: zipName.isEmpty ? kFixTocDefaultZipName : zipName,
    );
    return;
  }

  if (mode != 'online' && mode != 'offline' && mode != 'drill') {
    stderr.writeln('未知 --mode：$mode（可用 online|offline|drill）');
    exitCode = 2;
    return;
  }
  final sourceRoot = Directory(sourceArg);
  if (!sourceRoot.existsSync()) {
    stderr.writeln('语料树根不存在：$sourceArg');
    exitCode = 2;
    return;
  }
  Set<String>? subjectFilter;
  if (subjectsArg != null && subjectsArg.trim().isNotEmpty) {
    subjectFilter = {
      for (final s in subjectsArg.split(',')) s.trim().toLowerCase(),
    }..removeWhere((s) => s.isEmpty);
    final unknown = subjectFilter
        .where((s) => !kSubjectCodes.contains(s))
        .toList();
    if (unknown.isNotEmpty) {
      stderr.writeln('未知科目短码：$unknown（可用：$kSubjectCodes）');
      exitCode = 2;
      return;
    }
  }
  // 防污染：staging 与语料树不得互相嵌套（staging 只读源、只写自身）
  if (_isInside(sourceRoot.path, stagingArg) ||
      _isInside(stagingArg, sourceRoot.path)) {
    stderr.writeln('staging 与语料树根不得互相嵌套：'
        '$stagingArg vs ${sourceRoot.path}');
    exitCode = 2;
    return;
  }

  final out = makeOut(logArg);
  final staging = Directory(stagingArg)..createSync(recursive: true);
  final corpusDir = Directory('${staging.path}/corpus')
    ..createSync(recursive: true);
  final incoming = Directory('${corpusDir.path}/incoming')
    ..createSync(recursive: true);
  final corpusDbPath = '${corpusDir.path}/corpus.db';
  final chunksJsonlPath = '${corpusDir.path}/chunks.jsonl';
  final manifestPath = '${corpusDir.path}/extract_manifest.json';

  out('== 恒牙 · 语料包建库工具 ==');
  out('staging：${staging.path}');
  out('语料树：${sourceRoot.path}（只读）');
  out('科目过滤：${subjectFilter == null ? "无（全量四源）" : subjectFilter.join(",")}');
  out('嵌入模式：$mode${forceFull ? " | force-full" : ""} | batch=$batch');

  // ---- ① staging：四源拷贝（incoming/，App 建库树扫描布局）----
  var t = Stopwatch()..start();
  var copyCopied = 0;
  var copySkipped = 0;
  final copyMissing = <String>[];
  for (final code in kSubjectCodes) {
    if (subjectFilter != null && !subjectFilter.contains(code)) continue;
    // 教材树：ppt_raw/<短码>-textbook → incoming/<短码>-textbook
    final r1 = copyTree(
      Directory('${sourceRoot.path}/$code-textbook'),
      Directory('${incoming.path}/$code-textbook'),
    );
    copyCopied += r1.copied;
    copySkipped += r1.skipped;
    if (r1.missing) copyMissing.add('$code-textbook');
    // 课件树：ppt_raw/<短码> → incoming/<短码>（endo/oms；无则自然空转）
    final r2 = copyTree(
      Directory('${sourceRoot.path}/$code'),
      Directory('${incoming.path}/$code'),
    );
    copyCopied += r2.copied;
    copySkipped += r2.skipped;
  }
  if (subjectFilter == null) {
    // 真题 12 专题：ppt_raw/exam/<中文名> → incoming/<短码>-exam
    for (final topic in kExamTopics) {
      final r = copyTree(
        Directory('${sourceRoot.path}/exam/${topic.name}'),
        Directory('${incoming.path}/${topic.code}-exam'),
      );
      copyCopied += r.copied;
      copySkipped += r.skipped;
      if (r.missing) copyMissing.add('${topic.code}-exam');
    }
    // 大纲 2 DOCX：ppt_raw/exam/大纲与考纲 → incoming/dagang-outline（只 .docx）
    final r = copyTree(
      Directory('${sourceRoot.path}/exam/$kOutlineSourceDirName'),
      Directory('${incoming.path}/${outline.kOutlineUploadCode}-outline'),
      filter: (f) => f.path.toLowerCase().endsWith('.docx'),
    );
    copyCopied += r.copied;
    copySkipped += r.skipped;
    if (r.missing) copyMissing.add('dagang-outline');
  }
  out('staging 拷贝：copied=$copyCopied skipped=$copySkipped'
      '${copyMissing.isEmpty ? "" : " | 源缺失：${copyMissing.join(",")}"}'
      '（${(t.elapsedMilliseconds / 1000.0).toStringAsFixed(1)}s）');
  if (copyMissing.any((m) => m.endsWith('-textbook'))) {
    stderr.writeln('教材树缺失：$copyMissing（13 科必须齐全，先补语料）');
    exitCode = 2;
    return;
  }

  // ---- ② staging hengya.db settings：嵌入配置指向 Gitee ----
  // 密钥纪律：embedding.model / embedding.baseUrl 落 settings（App 同款键名）；
  // **embedding.apiKey 不落盘**——GITEE_AI_KEY 仅进程内直传嵌入配置（等价
  // App 侧 CorpusBuildRequest.apiKey 的「key 只进请求不进库文件」纪律）。
  final settingsDb = await Db.open('${staging.path}/hengya.db');
  String modelFromSettings;
  String baseFromSettings;
  try {
    settingsDb.settingSet('embedding.model', kGiteeEmbedModel);
    settingsDb.settingSet('embedding.baseUrl', kGiteeEmbedBase);
    // 读回 + _selectBuildMode 同款补尾（基址 …/v1 → …/v1/embeddings）
    modelFromSettings = settingsDb.settingGet('embedding.model') ?? '';
    baseFromSettings = settingsDb.settingGet('embedding.baseUrl') ?? '';
  } finally {
    settingsDb.close();
  }
  if (baseFromSettings.isNotEmpty &&
      !baseFromSettings.endsWith('/embeddings')) {
    baseFromSettings = '$baseFromSettings/embeddings';
  }
  final apiKey = Platform.environment[kEnvKey] ?? '';
  out('settings：embedding.model=$modelFromSettings '
      'embedding.baseUrl=$baseFromSettings | '
      '$kEnvKey=${apiKey.isEmpty ? "无" : "有（值不显示）"}');
  final CorpusEmbedConfig embed;
  if (mode == 'online') {
    if (apiKey.isEmpty) {
      stderr.writeln('在线嵌入需要环境变量 $kEnvKey（Gitee AI 密钥；'
          '仅环境变量注入，不落盘）');
      exitCode = 2;
      return;
    }
    embed = CorpusEmbedConfig.online(
      apiKey,
      model: modelFromSettings.isEmpty ? kGiteeEmbedModel : modelFromSettings,
      baseUrl: baseFromSettings.isEmpty
          ? '$kGiteeEmbedBase/embeddings'
          : baseFromSettings,
    );
  } else if (mode == 'offline') {
    // offline：不写向量；模型名仍按目标口径落 meta
    embed = CorpusEmbedConfig(
      mode: CorpusEmbedMode.offline,
      model: modelFromSettings.isEmpty ? kGiteeEmbedModel : modelFromSettings,
      baseUrl: baseFromSettings.isEmpty
          ? '$kGiteeEmbedBase/embeddings'
          : baseFromSettings,
    );
  } else {
    embed = const CorpusEmbedConfig.drill();
  }

  // ---- ③ 建库（照抄 corpus_build_job worker 链，同函数同参进程内直跑）----
  final t0 = Stopwatch()..start();
  final ex = extractAllCorpus(
    incoming.path,
    chunksJsonlPath,
    manifestPath: manifestPath,
    maxFileMb: pptx.defaultMaxFileMb,
    forceFull: forceFull,
    progress: (m) => out('  [extract] $m'),
  );
  out('抽取完成：${ex.chunks} chunks（changed=${ex.changed} '
      'unchanged=${ex.unchanged} removed=${ex.removed}）');
  if (ex.errors.isNotEmpty) {
    out('  [extract] 抽取失败 ${ex.errors.length} 个（前 10）：');
    for (final e in ex.errors.take(10)) {
      out('    - $e');
    }
  }
  if (ex.skippedBig.isNotEmpty) {
    out('  [extract] 超限跳过 ${ex.skippedBig.length} 个');
  }

  // 大纲 DOCX → outline_entries（幂等；零网络零嵌入）
  var outlineEntries = -1; // -1 = 本次无大纲源
  if (ex.outlineFiles.isNotEmpty) {
    final odb = openCorpusDb(corpusDbPath);
    try {
      final ostats = outline.ingestOutlineFiles(
        odb,
        ex.outlineFiles,
        progress: (m) => out('  [outline] $m'),
      );
      outlineEntries = ostats.entries;
      out('  [outline] 大纲入库：${ostats.entries} 条（${ostats.entriesByLevel}）');
    } finally {
      odb.dispose();
    }
    if (outlineEntries > 0) {
      try {
        await ensureMedSubjectPlaceholder(corpusDbPath);
        out('  [outline] 已确保 med 占位科目（医学综合）存在');
      } catch (e) {
        out('  [outline] med 占位科目确保失败：$e');
      }
    }
  }

  IngestStats? ing;
  if (ex.chunks > 0) {
    ing = await ingestCorpus(
      corpusDbPath,
      chunksJsonlPath,
      embed: embed,
      batchSize: batch,
      source: 'tree',
      pruneAbsent: true,
      progress: (m) => out('  [ingest] $m'),
    );
    out('入库完成：rows=${ing.rows} embedded=${ing.embedded} '
        'resumed=${ing.resumed} pending=${ing.pending}');
  } else {
    out('入库未执行：抽取 0 chunks${outlineEntries > 0 ? "（仅大纲入库）" : ""}');
  }
  final elapsed = t0.elapsedMilliseconds / 1000.0;

  // ---- ④ 罗盘初始化（local_backend._initCompassFromToc 同款）----
  var compassMutated = 0;
  try {
    final tocSubjects = tocSidecarSubjects('${corpusDir.path}/toc');
    if (tocSubjects != null && tocSubjects.isNotEmpty) {
      final progressPath = '${corpusDir.path}/progress.json';
      final data = loadProgress(progressPath);
      var mutated = false;
      for (final sid in tocSubjects) {
        final r = initFromTocSidecar(data, '${corpusDir.path}/toc', sid);
        if (r.ok && r.mutated) {
          mutated = true;
          compassMutated++;
        }
      }
      if (mutated) saveProgress(progressPath, data);
    }
  } catch (_) {} // 罗盘只是展示元数据，失败不阻断（同 App 侧防御）

  // ---- ⑤ 统计报告（corpus.db 只读复查）----
  final db = sqlite3.open(corpusDbPath, mode: OpenMode.readOnly);
  try {
    final bySubject = <String, int>{};
    for (final r in db.select('SELECT subject_id, count(*) FROM chunks '
        'GROUP BY subject_id ORDER BY subject_id')) {
      bySubject['${r.columnAt(0)}'] = r.columnAt(1) as int;
    }
    final bySource = <String, int>{};
    for (final r in db.select('SELECT source_type, count(*) FROM chunks '
        'GROUP BY source_type ORDER BY source_type')) {
      bySource['${r.columnAt(0)}'] = r.columnAt(1) as int;
    }
    final meta = <String, String>{};
    for (final r in db.select('SELECT key, value FROM meta')) {
      meta['${r.columnAt(0)}'] = '${r.columnAt(1)}';
    }
    final chunksN = _countOf(db, 'chunks');
    final vectorsN = _countOf(db, 'vectors');
    final outlineN = _countOf(db, 'outline_entries');
    final vec0N = _countOf(db, kVec0Table);
    var vecBlobLen = -1;
    var vecDimCol = -1;
    if (vectorsN > 0) {
      final r = db.select('SELECT dim, length(vec) FROM vectors LIMIT 1').first;
      vecDimCol = r.columnAt(0) as int;
      vecBlobLen = r.columnAt(1) as int;
    }
    final tocFiles = Directory('${corpusDir.path}/toc').existsSync()
        ? Directory('${corpusDir.path}/toc')
              .listSync()
              .whereType<File>()
              .where((f) => f.path.toLowerCase().endsWith('.json'))
              .length
        : 0;

    // FTS 可查性冒烟：从首块取 3 个连续汉字做 trigram MATCH（零 CLI 中文）
    String? ftsTerm;
    var ftsHits = -1;
    try {
      final row = db
          .select('SELECT title, text FROM chunks ORDER BY chunk_id LIMIT 1');
      if (row.isNotEmpty) {
        final hay = '${row.first.columnAt(0) ?? ''}${row.first.columnAt(1)}';
        final m = RegExp(r'[\u4e00-\u9fff]{3,}').firstMatch(hay);
        if (m != null) {
          ftsTerm = m.group(0)!.substring(0, 3);
          ftsHits = db
              .select('SELECT count(*) FROM chunks_fts '
                  'WHERE chunks_fts MATCH ?', [ftsTerm])
              .first
              .columnAt(0) as int;
        }
      }
    } catch (_) {
      ftsHits = -1; // FTS 冒烟失败不阻断（诊断信息如实报告）
    }

    out('-----------------------------------------');
    out('建库完成（${elapsed.toStringAsFixed(1)}s）：');
    out('  科目/块数：${bySubject.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
    out('  源分布：${bySource.entries.map((e) => '${e.key}=${e.value}').join(' ')}');
    out('  chunks=$chunksN | vectors=$vectorsN'
        '${vectorsN > 0 ? '（dim=$vecDimCol，BLOB=$vecBlobLen B，int8 量化）' : ''}'
        ' | vec_chunks 镜像=$vec0N');
    out('  大纲条目：$outlineN | toc sidecar 文件：$tocFiles | '
        '罗盘新建条目：$compassMutated');
    out('  meta：embedding_model=${meta['embedding_model']} '
        'embedding_dim=${meta['embedding_dim']}');
    if (ftsTerm != null) {
      out('  FTS 冒烟（trigram "$ftsTerm"）：命中 $ftsHits 块'
          '${ftsHits > 0 ? " [OK]" : " [FAIL]"}');
    } else {
      out('  FTS 冒烟：未取到 3 字探针词 [SKIP]');
    }
    // 口径核对（冒烟验收断言同款，输出 PASS/FAIL 供人工判读）
    final expectModel =
        mode == 'drill' ? 'local-charhash-1024-v1' : kGiteeEmbedModel;
    final modelOk = meta['embedding_model'] == expectModel;
    final okVec = mode == 'offline'
        ? vectorsN == 0
        : vectorsN == chunksN &&
            vecDimCol == 1024 &&
            vecBlobLen == 1024; // int8 量化：BLOB 字节数 = dim（scale 另存列）
    out('  核对：model=${modelOk ? 'PASS' : 'FAIL'}'
        '${modelOk ? '' : '（实际 ${meta['embedding_model']}，期望 $expectModel）'}');
    out('        vectors=${okVec ? 'PASS' : 'FAIL'}'
        '${mode == 'offline' ? '（offline 预期 0）' : '（=chunks 且 1024 维）'}');
  } finally {
    db.dispose();
  }
  out('staging 产物：$corpusDbPath + toc/ + manifest + progress.json'
      '（节点②打包 zip 直接复用；不含密钥）');
}

// ----------------------------------------------------------- --fix-toc ----

/// --fix-toc 模式主体：staging toc/*.json 数据变换（effectiveTocChapters 唯一
/// 口径）→ 罗盘 progress.json 重建（initFromTocSidecar 逐科目）→ b 版语料包
/// 重打包（白名单四件套 + 零密钥字节扫描）。
///
/// **铁律：corpus.db 全程只读**（sqlite 只开 readOnly 句柄；开跑/收尾各取
/// sha256 必须一致）——绝不重跑建库、绝不触碰向量，本模式零网络零 API key。
Future<void> _runFixToc({
  required Directory staging,
  required void Function(String) out,
  required String zipDir,
  required String zipName,
}) async {
  final corpusDir = Directory('${staging.path}/corpus');
  final tocDir = Directory('${corpusDir.path}/toc');
  final origDir = Directory('${corpusDir.path}/toc-orig');
  final corpusDbPath = '${corpusDir.path}/corpus.db';
  final progressPath = '${corpusDir.path}/progress.json';
  final manifestPath = '${corpusDir.path}/extract_manifest.json';

  var allPass = true;
  void check(String name, bool ok, [String detail = '']) {
    if (!ok) allPass = false;
    out('  [${ok ? 'PASS' : 'FAIL'}] $name${detail.isEmpty ? '' : ' | $detail'}');
  }

  Map<String, Object?> loadSidecar(String path) {
    final obj = convert.jsonDecode(File(path).readAsStringSync());
    if (obj is! Map) {
      throw FormatException('sidecar 顶层非对象：$path');
    }
    return Map<String, Object?>.from(obj);
  }

  // ---- 前置完整性（缺件即拒，不半途变换）----
  if (!File(corpusDbPath).existsSync()) {
    stderr.writeln('staging 缺 corpus/corpus.db：$corpusDbPath');
    exitCode = 2;
    return;
  }
  if (!File(manifestPath).existsSync()) {
    stderr.writeln('staging 缺 corpus/extract_manifest.json：$manifestPath');
    exitCode = 2;
    return;
  }
  final tocSubjects = tocSidecarSubjects(tocDir.path);
  if (tocSubjects == null || tocSubjects.isEmpty) {
    stderr.writeln('staging 缺 corpus/toc/*.json sidecar：${tocDir.path}');
    exitCode = 2;
    return;
  }
  final missing = [
    for (final c in kSubjectCodes)
      if (!tocSubjects.contains(c)) c,
  ];
  final extra = [
    for (final c in tocSubjects)
      if (!kSubjectCodes.contains(c)) c,
  ];
  if (missing.isNotEmpty || extra.isNotEmpty) {
    stderr.writeln('toc sidecar 短码与 13 科口径不符（缺：$missing 多：$extra）');
    exitCode = 2;
    return;
  }

  out('== 恒牙 · 语料包建库工具（--fix-toc 数据变换模式） ==');
  out('staging：${staging.path}');
  final sizeDb = File(corpusDbPath).lengthSync();
  final shaDbBefore = _sha256Of(File(corpusDbPath).readAsBytesSync());
  out('corpus.db 基线：$sizeDb B sha256=$shaDbBefore（本模式全程只读）');

  // ---- ① sidecar 变换：备份真原始 → effectiveTocChapters 重写 chapters ----
  out('---- ① toc sidecar 变换 ----');
  origDir.createSync(recursive: true);
  var rewritten = 0;
  var idemSkipped = 0;
  for (final sid in tocSubjects) {
    final f = File('${tocDir.path}/$sid.json');
    final Map<String, Object?> sc;
    try {
      final obj = convert.jsonDecode(f.readAsStringSync());
      if (obj is! Map) throw const FormatException('顶层非对象');
      sc = Map<String, Object?>.from(obj);
    } catch (e) {
      stderr.writeln('sidecar 解析失败 $sid：$e（不落盘，中止）');
      exitCode = 2;
      return;
    }
    if (sc['chapters'] is! List) {
      stderr.writeln('sidecar 结构异常 $sid（chapters 非 List，不落盘，中止）');
      exitCode = 2;
      return;
    }
    final oldN = (sc['chapters'] as List).length;
    final fresh = effectiveTocChapters(sc);
    final label = _tocRescueGate(sc) ? '救援' : '过滤';
    final changed =
        convert.jsonEncode(sc['chapters']) != convert.jsonEncode(fresh);
    if (!changed) {
      idemSkipped++;
      out('  $sid：$oldN 章（$label路径）已达标——幂等跳过不落盘（保 mtime）');
      continue;
    }
    // 真原始备份：toc-orig/<sid>.json 已存在则不覆盖（幂等重跑不污染原始件）
    final bak = File('${origDir.path}/$sid.json');
    if (!bak.existsSync()) f.copySync(bak.path);
    final next = Map<String, Object?>.from(sc)
      ..['chapters'] = fresh
      ..['updated_at'] = nowIso();
    atomicWriteText(
        f.path, const convert.JsonEncoder.withIndent(' ').convert(next));
    rewritten++;
    out('  $sid：$oldN → ${fresh.length} 章（$label路径）'
        '｜原始件→toc-orig/｜updated_at 已刷新');
  }
  out('① 收口：改写 $rewritten、幂等跳过 $idemSkipped（共 ${tocSubjects.length}）');

  // ---- ② 变换复核：幂等 / 与原始件推导一致 / 编号语义 / 标题干净 ----
  out('---- ② 变换复核 ----');
  final origFiles = origDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.json'))
      .length;
  check('toc-orig 原始件备份齐全（${tocSubjects.length} 科）',
      origFiles == tocSubjects.length, '实际 $origFiles 个');
  final partRe = RegExp(r'^第[一二三四五六七八九十百零两]+篇');
  var passIdem = 0, passConsist = 0, passNo = 0, passTitle = 0;
  final chapCountBySid = <String, int>{};
  final textbookBySid = <String, String?>{};
  for (final sid in tocSubjects) {
    final scNow = loadSidecar('${tocDir.path}/$sid.json');
    final chaptersNow = scNow['chapters'] as List;
    final freshNow = effectiveTocChapters(scNow);
    final okIdem =
        convert.jsonEncode(freshNow) == convert.jsonEncode(chaptersNow);
    if (okIdem) passIdem++;
    // 真原始件（toc-orig；从未存在则当前即原始形态）
    final bakFile = File('${origDir.path}/$sid.json');
    final scOrig = bakFile.existsSync() ? loadSidecar(bakFile.path) : scNow;
    final fromOrig = effectiveTocChapters(scOrig);
    final okConsist =
        convert.jsonEncode(fromOrig) == convert.jsonEncode(chaptersNow);
    if (okConsist) passConsist++;
    final rescue = _tocRescueGate(scOrig);
    final nos = [
      for (final e in chaptersNow.cast<Map>())
        ((e['no'] as num?) ?? -1).toInt(),
    ];
    chapCountBySid[sid] = chaptersNow.length;
    textbookBySid[sid] = scNow['textbook'] as String?;
    var okNo = nos.length == chaptersNow.length && !nos.contains(-1);
    if (rescue) {
      for (var i = 0; i < nos.length; i++) {
        if (nos[i] != i + 1) okNo = false;
      }
    } else {
      final origNos = <int>{
        for (final e in (scOrig['chapters'] as List).cast<Map>())
          ((e['no'] as num?) ?? -1).toInt(),
      };
      okNo = okNo && nos.every(origNos.contains);
    }
    if (okNo) passNo++;
    var okTitle = true;
    for (final e in chaptersNow.cast<Map>()) {
      final t = e['title'] as String?;
      final k = normChapterTitle(t ?? '');
      if (t == null ||
          stripChapterPageSuffix(t) != t ||
          kTocJunkExact.contains(k) ||
          k.startsWith('附录') ||
          k.startsWith('附表') ||
          partRe.hasMatch(k)) {
        okTitle = false;
        break;
      }
    }
    if (okTitle) passTitle++;
    final span = nos.isEmpty
        ? '-'
        : (nos.length == 1 ? '${nos.first}' : '${nos.first}..${nos.last}');
    out('  $sid：${chaptersNow.length} 章 no=$span '
        '${rescue ? '（救援·重编连续）' : '（过滤·原 no 保位）'}'
        '｜幂等=$okIdem 一致=$okConsist 编号=$okNo 标题干净=$okTitle');
  }
  check('13 科幂等（在库数据再变换零差异）', passIdem == tocSubjects.length,
      '$passIdem/${tocSubjects.length}');
  check('13 科与 toc-orig 原始件推导一致', passConsist == tocSubjects.length,
      '$passConsist/${tocSubjects.length}');
  check('编号语义（救援=1..N / 过滤=原 no 稀疏保位）',
      passNo == tocSubjects.length, '$passNo/${tocSubjects.length}');
  check('标题干净（无「 / 页码」尾、零辅文、零篇级）',
      passTitle == tocSubjects.length, '$passTitle/${tocSubjects.length}');

  // ---- ③ 罗盘 progress.json 重建（initFromTocSidecar 逐科目，同建库收尾④）----
  out('---- ③ 罗盘 progress.json 重建 ----');
  final before = loadProgress(progressPath);
  int ltOf(String sid) {
    final e = (before['subjects'] as Map)[sid];
    if (e is Map) return ((e['learned_through'] as num?) ?? 0).toInt();
    return 0;
  }

  final data = loadProgress(progressPath);
  for (final sid in tocSubjects) {
    final r = initFromTocSidecar(data, tocDir.path, sid);
    out('  [compass] ${r.note}');
    if (!r.ok) {
      stderr.writeln('罗盘初始化失败 $sid：${r.note}');
      exitCode = 2;
      return;
    }
  }
  saveProgress(progressPath, data);
  final after = loadProgress(progressPath);
  final subsAfter = after['subjects'] as Map;
  var passCompass = 0, passLt = 0;
  for (final sid in tocSubjects) {
    final e = subsAfter[sid];
    final scNow = loadSidecar('${tocDir.path}/$sid.json');
    if (e is Map) {
      if (convert.jsonEncode(e['chapters']) ==
          convert.jsonEncode(scNow['chapters'])) {
        passCompass++;
      }
      if (((e['learned_through'] as num?) ?? 0).toInt() == ltOf(sid)) {
        passLt++;
      }
    }
  }
  check('罗盘 13 科章表与变换后 sidecar 逐科一致',
      passCompass == tocSubjects.length, '$passCompass/${tocSubjects.length}');
  check('learned_through 重建不改写（staging 应全 0）',
      passLt == tocSubjects.length, '$passLt/${tocSubjects.length}');

  // ---- ④ b 版重打包（corpus.db 只读；白名单四件套）----
  out('---- ④ b 版重打包 ----');
  final db = sqlite3.open(corpusDbPath, mode: OpenMode.readOnly);
  int chunksN, decksN, zhiyeN, zhuliN;
  String model, dimRaw;
  try {
    chunksN = db.select('SELECT count(*) FROM chunks').first.columnAt(0) as int;
    decksN = db
        .select(
            'SELECT count(*) FROM (SELECT DISTINCT subject_id, deck FROM chunks)')
        .first
        .columnAt(0) as int;
    zhiyeN = db
        .select("SELECT count(*) FROM outline_entries WHERE level = 'zhiye'")
        .first
        .columnAt(0) as int;
    zhuliN = db
        .select("SELECT count(*) FROM outline_entries WHERE level = 'zhuli'")
        .first
        .columnAt(0) as int;
    final meta = <String, String>{
      for (final r in db.select('SELECT key, value FROM meta'))
        '${r.columnAt(0)}': '${r.columnAt(1)}',
    };
    model = meta['embedding_model'] ?? '';
    dimRaw = meta['embedding_dim'] ?? '';
  } finally {
    db.dispose();
  }
  final dim = int.tryParse(dimRaw) ?? 1024;
  // package.json：与节点② node2_package.py 逐字段同构（仅 builtAt 与
  // subjects[].chapters 随本包刷新；章数数据源=变换后 sidecar）。
  final package = <String, Object?>{
    'schemaVersion': 1,
    'kind': 'heng-corpus',
    'name': 'heng-corpus',
    'version': '1.8.1',
    'appMinVersion': '1.8.1',
    'modelName': model,
    'dim': dim,
    'builtAt': '${nowIso()}+08:00',
    'layout': {
      'packageJson': 'package.json（zip 根级）',
      'corpusDb': 'corpus/corpus.db',
      'tocDir': 'corpus/toc/<subject>.json（13 个教材章节表 sidecar）',
      'manifest': 'corpus/extract_manifest.json（App 端 manifest.json 别名同认）',
      'note': 'zip 根级 = package.json + corpus/；不含 progress.json/incoming/'
          'chunks.jsonl/corpus.db.ckpt/hengya.db/任何密钥',
    },
    'subjects': [
      for (final sid in tocSubjects)
        {
          'id': sid,
          'name': kSubjectNames[sid] ?? sid,
          'textbook': textbookBySid[sid] ?? '',
          'chapters': chapCountBySid[sid] ?? 0,
        },
    ],
    'examTopics': [
      for (final t in kExamTopics) {'id': t.code, 'name': t.name},
    ],
    'stats': {
      'chunks': chunksN,
      'decks': decksN,
      'outlineZhiye': zhiyeN,
      'outlineZhuli': zhuliN,
    },
  };
  final pkgBytes = convert.utf8
      .encode(const convert.JsonEncoder.withIndent(' ').convert(package));
  final mfBytes = File(manifestPath).readAsBytesSync();
  final arc = Archive()
    ..add(ArchiveFile('package.json', pkgBytes.length, pkgBytes))
    ..add(ArchiveFile('corpus/corpus.db', File(corpusDbPath).lengthSync(),
        File(corpusDbPath).readAsBytesSync()))
    ..add(ArchiveFile('corpus/extract_manifest.json', mfBytes.length, mfBytes));
  for (final sid in tocSubjects) {
    final b = File('${tocDir.path}/$sid.json').readAsBytesSync();
    arc.add(ArchiveFile('corpus/toc/$sid.json', b.length, b));
  }
  final zipBytes = ZipEncoder().encode(arc);
  final zipPath = '${zipDir.replaceAll('\\', '/')}/$zipName';
  Directory(zipPath.substring(0, zipPath.lastIndexOf('/')))
      .createSync(recursive: true);
  final zipFile = File(zipPath);
  if (zipFile.existsSync()) zipFile.deleteSync();
  zipFile.writeAsBytesSync(zipBytes, flush: true);
  out('zip 写出：$zipPath（${zipBytes.length} B）');

  // ---- ⑤ 产物自检：白名单 / 零密钥 / 章数一致 / 包内库=原库 / corpus.db 不变 ----
  out('---- ⑤ 产物自检 ----');
  final zipOnDisk = zipFile.readAsBytesSync();
  final checkArc = ZipDecoder().decodeBytes(zipOnDisk);
  final names = [for (final e in checkArc.files) e.name];
  final expectedNames = <String>{
    'package.json',
    'corpus/corpus.db',
    'corpus/extract_manifest.json',
    for (final sid in tocSubjects) 'corpus/toc/$sid.json',
  };
  final nameSet = names.toSet();
  check(
      'zip 白名单四件套（${expectedNames.length} 条不多不少；'
      '无 hengya.db/路径穿越）',
      nameSet.length == names.length &&
          nameSet.containsAll(expectedNames) &&
          expectedNames.containsAll(nameSet) &&
          !names.any((n) =>
              n.contains('..') || n.toLowerCase().contains('hengya.db')),
      '实际 ${names.length} 条');

  final envKey = Platform.environment[kEnvKey] ?? '';
  final keyPats = <RegExp>[
    RegExp(r'sk-[A-Za-z0-9]{20,}'),
    RegExp(r'[Bb]earer\s+[A-Za-z0-9_\-\.]{20,}'),
    RegExp(r'api[_-]?key\s*[=:]\s*[A-Za-z0-9_\-\.]{16,}'),
  ];
  final keyHits = <String>[];
  for (final e in checkArc.files) {
    final data = e.content;
    if (envKey.isNotEmpty && _bytesContains(data, convert.utf8.encode(envKey))) {
      keyHits.add('${e.name}（真实密钥串!）');
    }
    final s = convert.latin1.decode(data);
    for (final p in keyPats) {
      final m = p.firstMatch(s);
      if (m != null) {
        final frag = m.group(0)!;
        keyHits.add('${e.name}（${frag.length > 48 ? frag.substring(0, 48) : frag}）');
      }
    }
  }
  check('零密钥字节扫描（精确串+sk-/Bearer/api_key 令牌形态）', keyHits.isEmpty,
      keyHits.isEmpty ? 'CLEAN' : keyHits.take(5).join(' ; '));

  final pkgEntry = checkArc.files.firstWhere((e) => e.name == 'package.json');
  final pkgMap = Map<String, Object?>.from(
      convert.jsonDecode(convert.utf8.decode(pkgEntry.content)) as Map);
  final pkgSubs = (pkgMap['subjects'] as List).cast<Map>();
  var passCount = 0;
  for (final s in pkgSubs) {
    final sid = s['id'] as String;
    if (((s['chapters'] as num?) ?? -1).toInt() == (chapCountBySid[sid] ?? -1)) {
      passCount++;
    }
  }
  check('package.json subjects[].chapters 与新章数一致（数据源=变换后 sidecar）',
      passCount == tocSubjects.length, '$passCount/${tocSubjects.length}');

  final dbEntry = checkArc.files.firstWhere((e) => e.name == 'corpus/corpus.db');
  check('包内 corpus.db 与 staging 原库字节一致（sha256）',
      _sha256Of(dbEntry.content) == shaDbBefore, _sha256Of(dbEntry.content));

  final shaDbAfter = _sha256Of(File(corpusDbPath).readAsBytesSync());
  check('corpus.db 字节不变（开跑前后 sha256 相同）', shaDbAfter == shaDbBefore,
      shaDbAfter);

  out('-----------------------------------------');
  out('新包：$zipPath');
  out('体积：${zipOnDisk.length} B'
      '（${(zipOnDisk.length / 1048576.0).toStringAsFixed(1)} MB）');
  out('sha256：${_sha256Of(zipOnDisk)}');
  out('corpus.db：$shaDbAfter');
  out('---- package.json 全文 ----');
  out(const convert.JsonEncoder.withIndent(' ').convert(package));
  out('== --fix-toc 收口：全部检查 ${allPass ? 'ALL PASS' : '存在 FAIL（exitCode=1）'} ==');
  if (!allPass) exitCode = 1;
}

/// 字节序列 → sha256 十六进制（corpus.db/zip 铁证口径）。
String _sha256Of(List<int> bytes) => crypto.sha256.convert(bytes).toString();

/// 字节级子串包含（密钥精确串扫描用；needle 短，朴素实现即可）。
bool _bytesContains(List<int> hay, List<int> needle) {
  if (needle.isEmpty || hay.length < needle.length) return false;
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// 救援门分型（仅打印口径；数据路径唯一口径 = toc_chapters.dart）：
/// chapters「第X章」< 2 且 sections「第X章」≥ 3。
bool _tocRescueGate(Map<String, Object?> sc) {
  final re = RegExp(r'^第[一二三四五六七八九十百零两]+章');
  int realOf(Object? l) {
    if (l is! List) return 0;
    var n = 0;
    for (final e in l) {
      if (e is Map &&
          re.hasMatch(normChapterTitle((e['title'] as String?) ?? ''))) {
        n++;
      }
    }
    return n;
  }

  return realOf(sc['chapters']) < 2 && realOf(sc['sections']) >= 3;
}
