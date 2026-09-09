// 恒牙（hengya）· Phase 4 检索引擎测试（search_engine.dart 对拍硬门）
// ============================================================================
//
// 覆盖四组：
//   A. pyCrc32 与 zlib.crc32 锚点一致（localEmbed 的 CRC-32 表驱动自实现
//      必须与 Python 逐位一致——2026-09-06 于 Python 3.12.0 实测锚点值）；
//      localEmbed 跨调用确定性与 L2 归一。
//   B. 合成库全链行为（Dart 自造 chunks/vectors(int8)/vec_chunks(镜像)/
//      chunks_fts(trigram)/meta，同 .snow/tmp/make_drill_db.py 行集）：
//      词面+向量+linear 融合、hit_path、subject/source_type 过滤、
//      PPT 乘子、词面单路权重、vec0 两态等价、模型互斥拦截。
//   C. 真库跨引擎对拍（skip-guard：真库与 python 均在场才跑）：
//      Dart corpusSearch vs Python search_corpus.py --offline --json
//      逐字段对照（rank/chunk_id/hit_path 精确、score 容差 1e-4）——
//      与 Phase 3a/3b 金样同款「Python 是金标准」口径。
//
// 宿主基建：Windows 测试宿主 sqlite3.dll override（同 local_backend_test）。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:hengya/services/local/corpus/search_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  // ------------------------------------------------------ A. crc32/localEmbed ----

  test('pyCrc32 与 zlib.crc32 锚点一致（Python 3.12.0 实测）', () {
    const anchors = {
      'u龋': 3686448387,
      'b龋病': 719250144,
      'wabc': 499769321,
      'u牙': 2996453749,
      'b牙髓': 1954322870,
    };
    for (final e in anchors.entries) {
      expect(pyCrc32(utf8.encode(e.key)), e.value, reason: e.key);
    }
  });

  test('localEmbed 确定性 + L2 归一（dim=1024）', () {
    final a = localEmbed('龋病的四联因素学说 Acute pulpitis');
    final b = localEmbed('龋病的四联因素学说 Acute pulpitis');
    expect(a.length, 1024);
    expect(a, b); // 跨调用逐位一致
    var n2 = 0.0;
    for (final x in a) {
      n2 += x * x;
    }
    expect(n2, closeTo(1.0, 1e-9));
    final empty = localEmbed('!!!'); // 无有效字符 → 零向量原样返回
    expect(empty.every((x) => x == 0), isTrue);
  });

  test('extractUnits：分段+三元组+整串+封顶（Python extract_units 同款）', () {
    final units = extractUnits('龋病 定义');
    expect(units, contains('龋病'));
    expect(units, contains('定义'));
    expect(units, contains('龋病定义')); // 去分隔符整串
    expect(extractUnits('!!!'), isEmpty);
    expect(extractUnits(null), isEmpty);
    final long = extractUnits('急性牙髓炎临床表现与诊断治疗原则');
    expect(long.first.length >= long.last.length, isTrue); // 长度降序
    expect(long.length <= kMaxUnits, isTrue);
  });

  // ------------------------------------------------------ B. 合成库全链 ----

  late Directory tmp;
  late Database db;
  const drillRows = [
    ('endo:drill-ppt:p1', 'endo', '龋病四联因素学说',
        '细菌 食物 宿主 时间 是龋病发生的四联因素，缺一不可', 'ppt'),
    ('endo:drill-book:p2', 'endo', '龋病病因',
        '四联因素学说认为龋病需要细菌、食物、宿主与时间共同作用', 'textbook'),
    ('endo:drill-exam:p3', 'endo', '牙髓炎临床表现',
        '急性牙髓炎表现为自发痛、夜间痛加重、冷热刺激痛', 'exam'),
    ('patho:drill-ppt:p4', 'patho', '白斑',
        '口腔白斑属于癌前病变，组织学以上皮过度角化为特征', 'ppt'),
    ('patho:drill-book:p5', 'patho', '白斑的病理',
        '口腔白斑临床表现为白色斑块，不能擦去，需警惕癌变', 'textbook'),
    ('omo:drill-ppt:p6', 'omo', '釉质发育不全',
        '釉质发育不全与成釉细胞受损有关，常见营养障碍因素', 'ppt'),
    ('omo:drill-book:p7', 'omo', '釉质发育障碍的病因',
        '佝偻病、维生素缺乏等营养障碍可导致釉质发育不全', 'textbook'),
    ('exam:drill-ppt:p8', 'exam', '急性牙髓炎试题',
        '题干：急性牙髓炎最典型的表现是夜间痛与冷热刺激加重', 'ppt'),
  ];

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('hengya_search_test_');
    db = sqlite3.open('${tmp.path}${Platform.pathSeparator}corpus.db');
    db.execute('''
      CREATE TABLE chunks (
        chunk_id TEXT PRIMARY KEY, subject_id TEXT NOT NULL, ppt_id TEXT NOT NULL,
        deck TEXT, page_start INTEGER, page_end INTEGER, title TEXT,
        text TEXT NOT NULL, source_type TEXT, file_date TEXT);
      CREATE TABLE vectors (
        chunk_id TEXT PRIMARY KEY REFERENCES chunks(chunk_id),
        dim INTEGER NOT NULL, vec BLOB NOT NULL, scale REAL NOT NULL);
      CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE vec_chunks(chunk_id TEXT PRIMARY KEY, v BLOB NOT NULL) WITHOUT ROWID;
      CREATE VIRTUAL TABLE chunks_fts USING fts5(
        chunk_id UNINDEXED, title, text, tokenize='trigram');
    ''');
    final ps = db.prepare(
        'INSERT INTO chunks(chunk_id, subject_id, ppt_id, deck, page_start,'
        ' page_end, title, text, source_type, file_date)'
        ' VALUES (?,?,?,?,?,?,?,?,?,?)');
    final pv = db.prepare(
        'INSERT INTO vectors(chunk_id, dim, vec, scale) VALUES (?,?,?,?)');
    final pm = db.prepare('INSERT INTO vec_chunks(chunk_id, v) VALUES (?,?)');
    final pf = db.prepare(
        'INSERT INTO chunks_fts(chunk_id, title, text) VALUES (?,?,?)');
    for (var i = 0; i < drillRows.length; i++) {
      final r = drillRows[i];
      ps.execute([r.$1, r.$2, r.$2, r.$2, i + 1, i + 1, r.$3, r.$4, r.$5,
        '2026-09-06']);
      // 建库端联合编码契约：title + "\n" + text；int8 量化 + 归一化镜像
      final vec = localEmbed('${r.$3}\n${r.$4}');
      final scale =
          vec.fold<double>(0, (m, x) => math.max(m, x.abs())) / 127.0;
      final ints = Int8List(vec.length);
      for (var j = 0; j < vec.length; j++) {
        final q = (vec[j] / (scale > 0 ? scale : 1.0)).round();
        ints[j] = q > 127 ? 127 : (q < -127 ? -127 : q);
      }
      pv.execute([r.$1, vec.length, ints.buffer.asUint8List(), scale > 0 ? scale : 1.0]);
      var norm2 = 0.0;
      for (final x in ints) {
        norm2 += x * x.toDouble();
      }
      final norm = norm2 > 0 ? math.sqrt(norm2) : 1.0;
      final f32 = Float32List(vec.length);
      for (var j = 0; j < f32.length; j++) {
        f32[j] = ints[j] / norm;
      }
      pm.execute([r.$1, f32.buffer.asUint8List()]);
      pf.execute([r.$1, r.$3, r.$4]);
    }
    ps.dispose();
    pv.dispose();
    pm.dispose();
    pf.dispose();
    for (final e in {
      'embedding_model': kLocalEmbedModel,
      'embedding_dim': '1024',
      'fts_mode': 'fts5_trigram',
      'vec0_dim': '1024',
      'vec0_rows': '${drillRows.length}',
    }.entries) {
      db.execute("INSERT INTO meta(key, value) VALUES (?,?)", [e.key, e.value]);
    }
  });

  tearDownAll(() {
    db.dispose();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('合成库全链：词面+向量双路融合命中与 hit_path（offline localEmbed）',
      () async {
    final res = await corpusSearch(db, '四联因素学说', offline: true, k: 3);
    final results = (res['results'] as List).cast<Map<String, Object?>>();
    expect(results, isNotEmpty);
    expect(results.first['chunk_id'], 'endo:drill-ppt:p1');
    expect(results.first['hit_path'], 'both'); // 词面命中 + cos>=0.30
    expect(res['boost_ppt'], isTrue);
    expect((res['lex'] as Map)['mode'], 'fts5-trigram');
    expect((res['vec'] as Map)['used'], isTrue);
    expect((res['vec'] as Map)['scanned'], 8);
  });

  test('合成库 subject 过滤（omo）', () async {
    final res = await corpusSearch(db, '釉质发育', subject: 'omo', k: 5);
    final results = (res['results'] as List).cast<Map<String, Object?>>();
    expect(results, isNotEmpty);
    expect(results.every((h) => h['subject'] == 'omo'), isTrue);
  });

  test('合成库 source_type 硬过滤（textbook；无 1.05 乘子；零重叠全保留）', () async {
    // 金标准（2026-09-06 演练库实测 search_corpus.py --offline
    // --source-type textbook --k 5）：'角化' 在 textbook 行集内词面 0 命中、
    // localEmbed 特征零重叠 → cos=0.0，3 条 textbook 行仍全保留输出
    //（hit_path='none'，score=0.0），零分 tie-break 按行序 p2/p5/p7。
    // offline 必须显式传：缺省（false）且未注入 embed → 向量路禁用
    //（等价 Python「无 API key」）→ 词面又 0 命中 → 空结果（该行为
    // 两端等价，但非本用例意图——本用例锁的是 source_type 硬过滤）。
    final res = await corpusSearch(db, '角化',
        sourceType: 'textbook', offline: true, k: 5);
    final results = (res['results'] as List).cast<Map<String, Object?>>();
    expect(results.length, 3);
    expect(results.every((h) => h['source_type'] == 'textbook'), isTrue);
    expect(results.first['chunk_id'], 'endo:drill-book:p2'); // 行序 tie-break
    expect(results.every((h) => h['hit_path'] == 'none'), isTrue);
    expect((results.first['score'] as num).toDouble(), 0.0);
    expect(res['boost_ppt'], isFalse); // 显式 source_type → 乘子关闭
  });

  test('合成库词面单路权重 [1,0]：fused=lex（Python 融合退化同款）', () async {
    final res = await corpusSearch(db, '白斑', weights: [1.0, 0.0], k: 5);
    final results = (res['results'] as List).cast<Map<String, Object?>>();
    expect((results.first['fused'] as num).toDouble(),
        closeTo((results.first['lex'] as num).toDouble(), 1e-6));
  });

  test('合成库 vec0 两态等价：镜像点积 == int8 流式回退', () async {
    final on = await corpusSearch(db, '急性牙髓炎', offline: true, k: 5);
    final off = await corpusSearch(db, '急性牙髓炎',
        offline: true, k: 5, vec0: false);
    final a = (on['results'] as List).cast<Map<String, Object?>>();
    final b = (off['results'] as List).cast<Map<String, Object?>>();
    expect(b.length, a.length);
    for (var i = 0; i < a.length; i++) {
      expect(b[i]['chunk_id'], a[i]['chunk_id']);
      expect(b[i]['score'], closeTo(a[i]['score'] as num, 1e-4));
    }
  });

  test('合成库模型互斥拦截：meta 模型不匹配 → 向量路跳过', () async {
    db.execute(
        "UPDATE meta SET value='other-model' WHERE key='embedding_model'");
    try {
      final res = await corpusSearch(db, '四联因素学说', offline: true, k: 3);
      expect((res['vec'] as Map)['used'], isFalse);
      expect((res['notes'] as List).join(' '), contains('嵌入空间不兼容'));
      final results = (res['results'] as List).cast<Map<String, Object?>>();
      expect((results.first['fused'] as num).toDouble(),
          closeTo((results.first['lex'] as num).toDouble(), 1e-6)); // 融合退化为词面单路
    } finally {
      db.execute("UPDATE meta SET value='local-charhash-1024-v1'"
          " WHERE key='embedding_model'");
    }
  });

  // ------------------------------------------------------ C. 真库跨引擎对拍 ----

  test('真库 offline 跨引擎对拍（Python 金标准，skip-guard）', () async {
    final dbFile = File(
        '..${Platform.pathSeparator}content${Platform.pathSeparator}corpus'
        '${Platform.pathSeparator}corpus.db');
    if (!dbFile.existsSync()) {
      // ignore: avoid_print
      print('SKIP: 真库缺失（${dbFile.path}）');
      return;
    }
    final cases = [
      ('龋病的四联因素学说', null),
      ('急性牙髓炎临床表现', null),
      ('口腔白斑的临床表现', 'patho'),
    ];
    final realDb = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
    try {
      for (final (q, subject) in cases) {
        final env = Map<String, String>.from(Platform.environment)
          ..['PYTHONIOENCODING'] = 'utf-8';
        final args = [
          'automation${Platform.pathSeparator}server-pipeline${Platform.pathSeparator}search_corpus.py',
          '--db',
          'content${Platform.pathSeparator}corpus${Platform.pathSeparator}corpus.db',
          '--q', q, '--offline', '--k', '5', '--json',
          if (subject != null) ...['--subject', subject],
        ];
        final p = Process.runSync('python', args,
            workingDirectory:
                Directory('..${Platform.pathSeparator}').absolute.path,
            environment: env);
        expect(p.exitCode, 0, reason: 'python 侧失败: ${p.stderr}');
        final py = jsonDecode(p.stdout as String) as Map<String, dynamic>;
        final dart = await corpusSearch(realDb, q,
            subject: subject, offline: true, k: 5);
        final dr = (dart['results'] as List).cast<Map<String, Object?>>();
        final pr = (py['results'] as List).cast<Map<String, Object?>>();
        expect(dr.length, pr.length, reason: q);
        for (var i = 0; i < dr.length; i++) {
          expect(dr[i]['chunk_id'], pr[i]['chunk_id'], reason: '$q top${i + 1}');
          expect(dr[i]['hit_path'], pr[i]['hit_path'], reason: '$q top${i + 1}');
          expect((dr[i]['score'] as num).toDouble(),
              closeTo((pr[i]['score'] as num).toDouble(), 1e-4),
              reason: '$q top${i + 1}');
        }
      }
    } finally {
      realDb.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
