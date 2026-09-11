// 语料包导入（批5 节点③）验证：validate 守卫矩阵 / 导入落位 / 进度只补不
// 改（含 derm 占位升级）/ 模型名对暗号警告 / 原子回滚（中途失败不破坏原库）
// / 幂等重复导入 / 流水线占用拒绝 / 双布局（corpus/ 前缀与扁平）。
//
// 纯 Dart 测试纪律：不 TestWidgetsFlutterBinding；Windows 宿主显式加载
// test/sqlite3.dll；临时目录 + 自造小 zip（Archive ZipEncoder）。
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:hengya/services/local/corpus/progress_db.dart'
    show loadProgress, progressEntryOf, saveProgress;
import 'package:hengya/services/local/corpus_package.dart';
import 'package:hengya/services/local/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

void main() {
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
        () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  late Directory tmp;
  final mgr = CorpusPackageManager.instance;
  final defaultBusyCheck = CorpusPackageManager.pipelineBusyCheck;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_pkg_test_');
    CorpusPackageManager.pipelineBusyCheck = defaultBusyCheck;
    CorpusPackageManager.debugHook = null;
  });

  tearDown(() {
    CorpusPackageManager.pipelineBusyCheck = defaultBusyCheck;
    CorpusPackageManager.debugHook = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  // ------------------------------------------------------ 造包工具 ----

/// 最小合成 corpus.db（chunks/meta/outline_entries；model 为空串 =
  /// offline 建库形态，不写 meta.embedding_model）。[deckState] 非空时建
  /// deck_state 表并插入 (subject_id, ppt_id, source) 行——供"导入后
  /// source 打 package 标记"测试（bug 修复：pruneAbsent 不再剪包 deck）。
  void buildMiniCorpusDb(String path,
      {String model = 'TestEmbedModel',
      int chunkCount = 2,
      List<(String, String, String)> deckState = const []}) {
    // 同名旧件先删（同测试内多次造包时路径复用）
    final old = File(path);
    if (old.existsSync()) old.deleteSync();
    final db = sqlite3.open(path);
    db.execute(
      'CREATE TABLE chunks ('
      'chunk_id TEXT PRIMARY KEY, deck TEXT, title TEXT, source_type TEXT,'
      ' subject_id TEXT, page_start INTEGER, page_end INTEGER,'
      " page_range TEXT, text TEXT)",
    );
    db.execute('CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT)');
    db.execute(
      'CREATE TABLE outline_entries ('
      'level TEXT, part TEXT, subject TEXT, subject_name TEXT,'
      ' unit TEXT, subtopic TEXT)',
    );
    if (deckState.isNotEmpty) {
      db.execute(
        'CREATE TABLE deck_state ('
        'subject_id TEXT NOT NULL, ppt_id TEXT NOT NULL, '
        "source TEXT NOT NULL DEFAULT 'tree', file_path TEXT, file_md5 TEXT, "
        'chunk_count INTEGER NOT NULL DEFAULT 0, updated_at TEXT, '
        'PRIMARY KEY (subject_id, ppt_id))',
      );
      for (final (subj, ppt, src) in deckState) {
        db.execute(
          'INSERT INTO deck_state VALUES (?, ?, ?, NULL, NULL, 0, NULL)',
          [subj, ppt, src],
        );
      }
    }
    if (model.isNotEmpty) {
      db.execute("INSERT INTO meta VALUES ('embedding_model', ?)", [model]);
      db.execute("INSERT INTO meta VALUES ('embedding_dim', '1024')");
    }
    for (var i = 0; i < chunkCount; i++) {
      db.execute(
        "INSERT INTO chunks VALUES (?, ?, ?, 'textbook', 'endo', 1, 2, '1-2', ?)",
        ['c$i', '甲单元', '第${i + 1}章 标题', '内容$i'],
      );
    }
    db.execute(
        "INSERT INTO outline_entries VALUES ('zhiye','第一部分','endo','牙体牙髓','龋病','病因')");
    db.dispose();
  }

  Map<String, Object?> sidecar(String subject, String? textbook,
          List<Map<String, Object?>> chapters) =>
      {
        'version': 1,
        'subject': subject,
        'textbook': textbook,
        'chapters': chapters,
        'sections': <Map<String, Object?>>[],
      };

  final endoChapters = [
    {'no': 1, 'title': '第一章 龋病', 'page_start': 1},
    {'no': 2, 'title': '第二章 牙髓疾病', 'page_start': 20},
    {'no': 3, 'title': '第三章 根尖周疾病', 'page_start': 40},
  ];
  final dermChapters = [
    {'no': 1, 'title': '第一章 皮肤的结构与生理功能', 'page_start': 1},
  ];

  ArchiveFile zf(String name, List<int> bytes) =>
      ArchiveFile(name, bytes.length, bytes);

  /// 造测试包 zip。[flat]=true 走无 corpus/ 前缀布局；[rootManifest]=true
  /// 时 manifest 放根级且名 'manifest'（宽容解析验收）；[withCorpusDb]=false
  /// 造缺件包。
String buildPackageZip({
    String model = 'TestEmbedModel',
    String appMinVersion = '1.0.0',
    bool flat = false,
    bool rootManifest = false,
    bool withCorpusDb = true,
    Map<String, Object> pkgOverride = const {},
    Map<String, String> extra = const {},
    List<(String, String, String)> deckState = const [],
  }) {
    final dbPath = '${tmp.path}/pkg-corpus.db';
    buildMiniCorpusDb(dbPath, model: model, deckState: deckState);
    String p(String rel) => flat ? rel : 'corpus/$rel';
    final arc = Archive();
    if (withCorpusDb) {
      arc.add(zf(p('corpus.db'), File(dbPath).readAsBytesSync()));
    }
    arc.add(zf(
        p('toc/endo.json'),
        utf8.encode(
            jsonEncode(sidecar('endo', '《牙体牙髓病学》', endoChapters)))));
    arc.add(zf(
        p('toc/derm.json'),
        utf8.encode(
            jsonEncode(sidecar('derm', '《皮肤性病学（第10版）', dermChapters)))));
    if (rootManifest) {
      arc.add(zf('manifest', utf8.encode('{"files":{}}')));
    } else {
      arc.add(zf(p('extract_manifest.json'), utf8.encode('{"files":{}}')));
    }
    final pkgJson = jsonEncode({
      'schemaVersion': 1,
      'appMinVersion': appMinVersion,
      'modelName': model,
      'dim': 1024,
      'subjects': [
        {
          'id': 'endo',
          'name': '牙体牙髓病学',
          'textbook': '《牙体牙髓病学》',
          'chapters': 3,
        },
        {
          'id': 'derm',
          'name': '皮肤性病学',
          'textbook': '《皮肤性病学（第10版）',
          'chapters': 1,
        },
        {
          'id': 'oms',
          'name': '口腔颌面外科学',
          'textbook': null,
          'chapters': 0,
        },
      ],
      'stats': {'chunks': 2},
      'builtAt': '2026-09-07T12:00:00Z',
      ...pkgOverride,
    });
    arc.add(zf('package.json', utf8.encode(pkgJson)));
    for (final e in extra.entries) {
      arc.add(zf(e.key, utf8.encode(e.value)));
    }
    final zipPath = '${tmp.path}/heng-corpus-test.zip';
    File(zipPath).writeAsBytesSync(ZipEncoder().encode(arc));
    return zipPath;
  }

  /// 造「已在使用中」的本机语料库（marker 行可断言旧库还原）。
  String seedExistingCorpus(String dataDir, {String marker = 'OLD-DB'}) {
    final corpusDir = Directory('$dataDir/corpus')
      ..createSync(recursive: true);
    final dbPath = '${corpusDir.path}/corpus.db';
    buildMiniCorpusDb(dbPath, model: 'OldModel');
    final db = sqlite3.open(dbPath);
    db.execute("INSERT INTO meta VALUES ('marker', ?)", [marker]);
    db.dispose();
    Directory('${corpusDir.path}/toc').createSync();
    File('${corpusDir.path}/toc/old.json').writeAsStringSync('{"subject":"old"}');
    File('${corpusDir.path}/extract_manifest.json')
        .writeAsStringSync('{"old":true}');
    return dbPath;
  }

  List<String> tmpDirs(String dataDir) => Directory('$dataDir/corpus')
      .listSync()
      .whereType<Directory>()
      .map((d) => d.path)
      .toList();

  // ------------------------------------------------------ validate ----

  group('validatePackage（只读校验）', () {
    test('合法包（corpus/ 前缀标准布局）→ 摘要齐全', () {
      final s = mgr.validatePackage(buildPackageZip());
      expect(s.subjects.length, 3);
      expect(s.subjects.first.id, 'endo');
      expect(s.chunks, 2);
      expect(s.outlineEntries, 1);
      expect(s.tocFiles, 2);
      expect(s.modelName, 'TestEmbedModel');
      expect(s.dbModelName, 'TestEmbedModel');
      expect(s.dim, 1024);
      expect(s.packageBytes, greaterThan(0));
      expect(s.builtAt, '2026-09-07T12:00:00Z');
    });

    test('扁平布局（corpus.db 在根）同过校验', () {
      final s = mgr.validatePackage(buildPackageZip(flat: true));
      expect(s.subjects.length, 3);
      expect(s.tocFiles, 2);
    });

    test('非 zip / 空 / 缺 package.json / 缺 corpus.db / 坏 JSON 全拒', () {
      final junk = File('${tmp.path}/junk.zip')..writeAsBytesSync([1, 2, 3]);
      expect(() => mgr.validatePackage(junk.path),
          throwsA(isA<CorpusPackageException>()));
      final empty = File('${tmp.path}/empty.zip')..writeAsBytesSync([]);
      expect(() => mgr.validatePackage(empty.path),
          throwsA(isA<CorpusPackageException>()));
      // 缺 package.json（corpus.db 与 toc 俱全也不行）
      final noPkgDb = '${tmp.path}/no-pkg-corpus.db';
      buildMiniCorpusDb(noPkgDb);
      final noPkgPath = '${tmp.path}/no-pkg.zip';
      final arcNoPkg = Archive()
        ..add(zf('corpus/corpus.db', File(noPkgDb).readAsBytesSync()))
        ..add(zf('corpus/toc/endo.json', utf8.encode('{"subject":"endo"}')));
      File(noPkgPath).writeAsBytesSync(ZipEncoder().encode(arcNoPkg));
      expect(() => mgr.validatePackage(noPkgPath),
          throwsA(isA<CorpusPackageException>()));
      // 缺 corpus.db
      expect(() => mgr.validatePackage(buildPackageZip(withCorpusDb: false)),
          throwsA(isA<CorpusPackageException>()));
      // 坏 JSON
      final bad = File('${tmp.path}/bad-json.zip');
      final arcBad = Archive()
        ..add(zf('package.json', utf8.encode('{not-json')))
        ..add(zf('corpus/corpus.db', [1, 2, 3]));
      bad.writeAsBytesSync(ZipEncoder().encode(arcBad));
      expect(() => mgr.validatePackage(bad.path),
          throwsA(isA<CorpusPackageException>()));
    });

    test('schemaVersion 不受支持 / appMinVersion 高于当前 → 拒', () {
      final sv2 = buildPackageZip(pkgOverride: {'schemaVersion': 2});
      expect(() => mgr.validatePackage(sv2),
          throwsA(isA<CorpusPackageException>()));

final minHigh = buildPackageZip(appMinVersion: '99.0.0');
      expect(() => mgr.validatePackage(minHigh, appVersion: '1.8.0+16'),
          throwsA(isA<CorpusPackageException>()));
      // 语义方向兼容：主版本一代之差（0.x 公开版 vs 1.x 内测重计号）放行
      final renumb = buildPackageZip(appMinVersion: '1.8.1');
      expect(mgr.validatePackage(renumb, appVersion: '0.1.5+24').subjects.length, 3);
      // appVersion 未提供 → 守卫跳过（真机由 UI 传版本）
      expect(mgr.validatePackage(minHigh).subjects.length, 3);
    });

    test('包内含 hengya.db / 路径穿越 → 硬拒', () {
      final withMain = buildPackageZip(extra: {'hengya.db': 'x'});
      expect(() => mgr.validatePackage(withMain),
          throwsA(isA<CorpusPackageException>()));
      final escape = buildPackageZip(extra: {'../evil.txt': 'x'});
      expect(() => mgr.validatePackage(escape),
          throwsA(isA<CorpusPackageException>()));
    });

    test('包自述模型与库内 meta 不一致 → 判包损坏', () {
      final bad = buildPackageZip(pkgOverride: {'modelName': 'AnotherModel'});
      expect(() => mgr.validatePackage(bad),
          throwsA(isA<CorpusPackageException>()));
    });

    test('offline 建库（meta 无模型）→ 放过（dbModelName=null）', () {
      // 包自述模型名非空，但库内 meta 无 embedding_model（offline 建库形态）
      final dbPath = '${tmp.path}/offline-corpus.db';
      buildMiniCorpusDb(dbPath, model: '');
      final pkg = jsonEncode({
        'schemaVersion': 1,
        'appMinVersion': '1.0.0',
        'modelName': 'OfflinePkgModel',
        'dim': 1024,
        'subjects': [
          {
            'id': 'endo',
            'name': '牙体牙髓病学',
            'textbook': '《牙体牙髓病学》',
            'chapters': 3
          }
        ],
        'stats': {},
        'builtAt': '',
      });
      final zipPath = '${tmp.path}/offline-pkg.zip';
      final arc = Archive()
        ..add(zf('corpus/corpus.db', File(dbPath).readAsBytesSync()))
        ..add(zf(
            'corpus/toc/endo.json',
            utf8.encode(
                jsonEncode(sidecar('endo', '《牙体牙髓病学》', endoChapters)))))
        ..add(zf('package.json', utf8.encode(pkg)));
      File(zipPath).writeAsBytesSync(ZipEncoder().encode(arc));
      final s = mgr.validatePackage(zipPath);
      expect(s.dbModelName, isNull);
      expect(s.modelName, 'OfflinePkgModel');
    });
  });

  // ------------------------------------------------------- import ----

  group('importPackage（全新 dataDir）', () {
    test('落位：corpus.db/toc/manifest 就位 + 科目行 + progress 建条目', () async {
      final dataDir = Directory('${tmp.path}/fresh')..createSync();
      final zip = buildPackageZip();
      final r = await mgr.importPackage(dataDir.path, zip);

      expect(r.summary.subjects.length, 3);
      expect(r.backupPath, isNull, reason: '本机原无库可备');
      expect(r.subjectsAdded, 3);
      expect(r.subjectsExisting, 0);
      expect(r.modelWarning, isNull, reason: '本机未配 embedding.model');

      // 语料库落位
      expect(File('${dataDir.path}/corpus/corpus.db').existsSync(), isTrue);
      expect(File('${dataDir.path}/corpus/toc/endo.json').existsSync(), isTrue);
      expect(File('${dataDir.path}/corpus/toc/derm.json').existsSync(), isTrue);
      expect(File('${dataDir.path}/corpus/extract_manifest.json').existsSync(),
          isTrue);

      // 科目行 + data_version
      final db = await Db.open('${dataDir.path}/hengya.db');
      try {
        expect(db.subjectExists('endo'), isTrue);
        expect(db.subjectExists('derm'), isTrue);
        expect(db.subjectExists('oms'), isTrue);
        expect(int.parse(db.dataVersion), greaterThanOrEqualTo(1),
            reason: '导入必须 bumpDataVersion');
      } finally {
        db.close();
      }

      // progress：endo/derm 真罗盘（3 章/1 章）、oms 无罗盘占位
      final prog = loadProgress('${dataDir.path}/corpus/progress.json');
      final endo = progressEntryOf(prog, 'endo')!;
      expect(endo['learned_through'], 0);
      expect((endo['chapters'] as List).length, 3);
      expect(endo['textbook'], '《牙体牙髓病学》');
      final oms = progressEntryOf(prog, 'oms')!;
      expect(oms['learned_through'], 0);
      expect((oms['chapters'] as List), isEmpty);
      expect(oms['textbook'], isNull, reason: 'ppt-only 科目无罗盘占位');
      expect(progressEntryOf(prog, 'derm'), isNotNull);
// 临时目录自清
      expect(tmpDirs(dataDir.path).where((p) => p.contains('.import-tmp')),
          isEmpty);
    });

    test('包 deck 豁免标记：导入后 deck_state.source 全部改 package（不剪除）',
        () async {
      // 2026-09-11 bug 修复：包库 deck_source 原为 'tree'，而建库
      // pruneAbsent 只剪 source='tree' 且不在本机 incoming 树的 deck——
      // 导入后再建库会把包内全部 deck 当"树外"剪掉（实证 13 科全灭）。
      // 导入后应统一标记为 'package'（prune 豁免）。
      final dataDir = Directory('${tmp.path}/pkgdecks')..createSync();
      final zip = buildPackageZip(deckState: const [
        ('endo', 'ppt-endo-1', 'tree'),
        ('derm', 'ppt-derm-1', 'tree'),
      ]);
      final r = await mgr.importPackage(dataDir.path, zip);
      expect(r.backupPath, isNull);

      final db = sqlite3.open('${dataDir.path}/corpus/corpus.db');
      try {
        final rows = db.select(
          'SELECT subject_id, ppt_id, source FROM deck_state ORDER BY subject_id',
        );
        expect(rows.length, 2);
        for (final row in rows) {
          expect(row['source'], 'package',
              reason: '导入后包 deck 必须标记 package（建库 prune 豁免）');
        }
      } finally {
        db.dispose();
      }
    });

    test('根级 manifest 宽容映射成 extract_manifest.json', () async {
      final dataDir = Directory('${tmp.path}/flatman')..createSync();
      await mgr.importPackage(dataDir.path, buildPackageZip(rootManifest: true));
      expect(File('${dataDir.path}/corpus/extract_manifest.json').existsSync(),
          isTrue);
    });
  });

  group('importPackage（已有语料库与进度）', () {
    test('备份 + 进度只补不改：endo 进度/跳过/历史分毫不动，derm 占位升级', () async {
      final dataDir = Directory('${tmp.path}/existing')..createSync();
      final oldDbPath = seedExistingCorpus(dataDir.path);
      final oldBytes = File(oldDbPath).readAsBytesSync();

      // 既有进度：endo 学到第 2 章跳过第 3 章；derm 无罗盘占位
      File('${dataDir.path}/corpus/progress.json').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'subjects': {
            'endo': {
              'textbook': '《牙体牙髓病学》',
              'chapters': endoChapters,
              'learned_through': 2,
              'skipped': [3],
              'updated_at': '2026-09-01T00:00:00',
              'history': [
                {
                  'date': '2026-09-01',
                  'from': 0,
                  'to': 2,
                  'evidence': 'e1',
                  'source': 'manual'
                }
              ],
            },
            'derm': {
              'textbook': null,
              'chapters': <Map<String, Object?>>[],
              'learned_through': 0,
              'updated_at': '2026-09-01T00:00:00',
              'history': <Map<String, Object?>>[],
            },
          },
        }),
      );

      final r = await mgr.importPackage(dataDir.path, buildPackageZip());

      // 备份留存
      expect(r.backupPath, isNotNull);
      expect(File('${r.backupPath}/corpus.db').existsSync(), isTrue);
      expect(File('${r.backupPath}/toc/old.json').existsSync(), isTrue);
      expect(File('${r.backupPath}/extract_manifest.json').existsSync(), isTrue);

      // hengya.db 此刻才建 → 全 3 科新增
      expect(r.subjectsAdded, 3);

      // 进度：endo 分毫不动
      final prog = loadProgress('${dataDir.path}/corpus/progress.json');
      final endo = progressEntryOf(prog, 'endo')!;
      expect(endo['learned_through'], 2);
      expect(endo['skipped'], [3]);
      expect((endo['history'] as List).length, 1);
      // derm 占位升级：真教材 + 章表；learned_through 仍 0、history 仍空
      final derm = progressEntryOf(prog, 'derm')!;
      expect(derm['textbook'], '《皮肤性病学（第10版）');
      expect((derm['chapters'] as List).length, 1);
      expect(derm['learned_through'], 0);
      expect((derm['history'] as List), isEmpty);
      // oms 新建占位
      final oms = progressEntryOf(prog, 'oms')!;
      expect(oms['learned_through'], 0);
      expect(r.progressCreated, 1, reason: '仅 oms 新建');

      // 新 corpus.db 替换旧库（旧 marker 不在新库）
      final newDb = sqlite3.open(oldDbPath, mode: OpenMode.readOnly);
      try {
        expect(newDb.select("SELECT value FROM meta WHERE key = 'marker'"),
            isEmpty,
            reason: '旧库已被包内新库替换');
      } finally {
        newDb.dispose();
      }
      // 旧字节留档在备份里
      expect(File('${r.backupPath}/corpus.db').readAsBytesSync(), oldBytes);
    });

    test('模型名对暗号：本机 embedding.model 不一致 → 警告（不阻断）', () async {
      final dataDir = Directory('${tmp.path}/warn')..createSync();
      final db = await Db.open('${dataDir.path}/hengya.db');
      db.settingSet('embedding.model', 'OtherModel');
      db.close();

      final r = await mgr.importPackage(dataDir.path, buildPackageZip());
      expect(r.modelWarning, isNotNull);
      expect(r.modelWarning!, contains('OtherModel'));
      expect(r.modelWarning!, contains('TestEmbedModel'));

      // 一致（大小写不敏感）→ 无警告
      final dataDir2 = Directory('${tmp.path}/match')..createSync();
      final db2 = await Db.open('${dataDir2.path}/hengya.db');
      db2.settingSet('embedding.model', 'testembedmodel');
      db2.close();
      final r2 = await mgr.importPackage(dataDir2.path, buildPackageZip());
      expect(r2.modelWarning, isNull);
    });

    test('PC staging 整目录打包兼容：包内 progress/incoming/chunks.jsonl 全忽略，手机进度不被包覆盖',
        () async {
      final dataDir = Directory('${tmp.path}/staging')..createSync();
      // 手机既有语料库 + 已学到第 1 章
      seedExistingCorpus(dataDir.path);
      File('${dataDir.path}/corpus/progress.json').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'subjects': {
            'endo': {
              'textbook': 'T',
              'chapters': endoChapters,
              'learned_through': 1,
              'updated_at': 'x',
              'history': [],
            }
          }
        }),
      );

      // 包内夹带 PC staging 的 progress.json（learned_through=99）/incoming/
      // chunks.jsonl——白名单必须全忽略
      final zip = buildPackageZip(extra: {
        'corpus/progress.json': jsonEncode({
          'version': 1,
          'subjects': {
            'endo': {
              'textbook': 'PKG',
              'chapters': <Object>[],
              'learned_through': 99,
              'updated_at': 'pkg',
              'history': <Object>[],
            }
          }
        }),
        'corpus/chunks.jsonl': '{"fake":true}',
        'corpus/incoming/endo/a.pptx': 'x',
      });
      final r = await mgr.importPackage(dataDir.path, zip);
      expect(r.summary.subjects.length, 3);

      // 手机进度不被包内 99 覆盖；教材/章表按 toc 同步、learned 保留
      final prog = loadProgress('${dataDir.path}/corpus/progress.json');
      final endo = progressEntryOf(prog, 'endo')!;
      expect(endo['learned_through'], 1, reason: '包内 progress.json 绝不生效');
      expect(endo['textbook'], '《牙体牙髓病学》'); // toc sidecar 同步

      // staging 夹带件不落地
      expect(File('${dataDir.path}/corpus/chunks.jsonl').existsSync(), isFalse);
      expect(Directory('${dataDir.path}/corpus/incoming').existsSync(), isFalse);
    });

    test('幂等：重复导入成功且科目/进度零变化', () async {
      final dataDir = Directory('${tmp.path}/idem')..createSync();
      final zip = buildPackageZip();
      final r1 = await mgr.importPackage(dataDir.path, zip);
      expect(r1.subjectsAdded, 3);
      // 学一点进度再导一次
      final progPath = '${dataDir.path}/corpus/progress.json';
      final prog = loadProgress(progPath);
      (prog['subjects'] as Map)['endo']['learned_through'] = 2;
      saveProgress(progPath, prog);

      final r2 = await mgr.importPackage(dataDir.path, zip);
      expect(r2.subjectsAdded, 0, reason: '科目行幂等');
      expect(r2.subjectsExisting, 3);
      expect(r2.progressCreated, 0);
      expect(r2.progressSynced, 0, reason: 'textbook/chapters 未变不重写');
      expect(r2.backupPath, isNotNull, reason: '第二次导入备份的是新库');

      final prog2 = loadProgress(progPath);
      expect(progressEntryOf(prog2, 'endo')!['learned_through'], 2,
          reason: '学习进度分毫不动');
      final db = await Db.open('${dataDir.path}/hengya.db');
      try {
        expect(db.subjects().where((s) => s.id == 'endo').length, 1,
            reason: '科目行不重复');
      } finally {
        db.close();
      }
    });
  });

  // ------------------------------------------------------- 回滚 ----

  group('原子回滚（中途失败不破坏原库）', () {
    test('after-extract 钩子炸 → 旧库字节级还原，进度不动', () async {
      final dataDir = Directory('${tmp.path}/rb1')..createSync();
      final oldDbPath = seedExistingCorpus(dataDir.path);
      final oldBytes = File(oldDbPath).readAsBytesSync();
      final progPath = '${dataDir.path}/corpus/progress.json';
      File(progPath).writeAsStringSync(jsonEncode({
        'version': 1,
        'subjects': {
          'endo': {
            'textbook': 'T',
            'chapters': endoChapters,
            'learned_through': 1,
            'updated_at': 'x',
            'history': [],
          }
        }
      }));
      final progBefore = File(progPath).readAsStringSync();

      CorpusPackageManager.debugHook = (phase) {
        if (phase == 'after-extract') throw StateError('boom');
      };
      await expectLater(
        mgr.importPackage(dataDir.path, buildPackageZip()),
        throwsA(isA<CorpusPackageException>()),
      );
      CorpusPackageManager.debugHook = null;

      expect(File(oldDbPath).readAsBytesSync(), oldBytes,
          reason: '旧 corpus.db 字节级还原');
      expect(File('${dataDir.path}/corpus/toc/old.json').existsSync(), isTrue);
      expect(File('${dataDir.path}/corpus/extract_manifest.json').existsSync(),
          isTrue);
      expect(File(progPath).readAsStringSync(), progBefore,
          reason: 'progress.json 不动');
      expect(tmpDirs(dataDir.path).where((p) => p.contains('.import-tmp')),
          isEmpty,
          reason: '临时目录自清');
    });

    test('after-swap 钩子炸 → 换库成果整体撤销，恢复换库前原状', () async {
      final dataDir = Directory('${tmp.path}/rb2')..createSync();
      final oldDbPath = seedExistingCorpus(dataDir.path, marker: 'OLD-2');
      final oldBytes = File(oldDbPath).readAsBytesSync();

      CorpusPackageManager.debugHook = (phase) {
        if (phase == 'after-swap') throw StateError('boom-late');
      };
      await expectLater(
        mgr.importPackage(dataDir.path, buildPackageZip()),
        throwsA(isA<CorpusPackageException>()),
      );
      CorpusPackageManager.debugHook = null;

      // 新库撤下、旧库回位（marker 行还在 = 真旧库）
      expect(File(oldDbPath).readAsBytesSync(), oldBytes);
      final db = sqlite3.open(oldDbPath, mode: OpenMode.readOnly);
      try {
        expect(db.select("SELECT value FROM meta WHERE key = 'marker'"),
            isNotEmpty);
      } finally {
        db.dispose();
      }
      expect(File('${dataDir.path}/corpus/toc/old.json').existsSync(), isTrue);
      // 包内新 toc 不残留
      expect(File('${dataDir.path}/corpus/toc/endo.json').existsSync(), isFalse);
    });
  });

  // ------------------------------------------------------- 守卫 ----

  test('流水线/建库运行中 → 拒绝导入（稍后再试）', () async {
    final dataDir = Directory('${tmp.path}/busy')..createSync();
    CorpusPackageManager.pipelineBusyCheck = () => true;
    await expectLater(
      mgr.importPackage(dataDir.path, buildPackageZip()),
      throwsA(isA<CorpusPackageException>().having(
          (e) => e.message, 'message', contains('稍后再试'))),
    );
  });
}
