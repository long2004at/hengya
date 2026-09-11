// 恒牙（hengya）· Phase 4c · extract_all 建库刀测试（金样驱动对拍硬门）
// ============================================================================
//
// 验收口径（Python 是金标准——与 extract_pptx/pdf/docx 金样测试同款）：
//   1. 树扫描→抽取：临时树（oms pptx + exam 试卷 PDF 两源文件）经
//      extractAllCorpus 产出的 chunks.jsonl，按 deck 切片后与盘上金样
//      （CRLF→LF 归一）逐字节一致（92+19=111 行）；
//   2. 建库（drill 确定性伪向量）：corpus.db schema 契约逐列一致，
//      chunks 行与金样逐字段一致，vectors=int8×1024 每库一 scale，
//      vec_chunks=float32 镜像 4096B/行 + meta 安全闩，chunks_fts 全文索引，
//      meta 口径（embedding_model/fts_mode/corpus_kind）与 Python 契约一致；
//   3. 幂等：重跑 extract（manifest 快速路径全命中）+ ingest（chunk_state
//      续传全跳过）→ 计数收敛、库内容不变；
//   4. 离线检索冒烟：建库产物喂 corpusSearch(offline)——vec_chunks 镜像
//      点积路 + int8 流式回退路两态等价、命中非空；
//   5. 换版/剪除：同名替换→deck 删旧插新（pruned_stale）；删文件→
//      树外 deck 剪除（prune_absent）；
//   6. 同名 stem 去重：同轮两文件 → -2 后缀前缀替换（保留 -sN 拆分后缀）；
//   7. offline 建库：无 key 不写向量（vectors 0 行、镜像表删除），
//      检索词面单路命中非空（模型互斥拦截向量路）。
//
// 宿主基建：Windows 测试宿主 sqlite3.dll override（同 search_engine_test）；
// pdfium.dll 由 pdfium_ffi 惰性加载（cwd=app/ → test/fixtures/pdfium/）。
// 纯 Dart test（非 widget 测试）；await 真实 IO 允许（无假异步坑）。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:hengya/services/local/corpus/extract_all.dart';
import 'package:hengya/services/local/corpus/search_api.dart' show kEmbedModel;
import 'package:hengya/services/local/corpus/search_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

// —— 金样源文件（CWD=app/；与 extract_pptx_golden_test / extract_pdf_smoke_test 同源）——
const srcOmsPptx =
    '../content/ppt_raw/oms/(2.1.2)--第二章口腔颌面外科基本操作与基础知识 (1).pptx';
const srcExamPdf = '../content/ppt_raw/exam/试卷与模拟题/2023年口腔助理医师试题（网友回忆版）.pdf';
const srcOtherExamPdf = '../content/ppt_raw/exam/修复类专题/4.牙列缺失.pdf';
const examPdfName = '2023年口腔助理医师试题（网友回忆版）.pdf';

const goldenOms = 'test/fixtures/golden/oms_ch2_pptx_chunks.jsonl';
const goldenExam = 'test/fixtures/golden/exam_assistant2023_pdf_chunks.jsonl';

/// 盘上金样为 Python Windows 文本模式写出（CRLF）→ LF 归一后对拍。
List<String> goldenLines(String path) => File(path)
    .readAsStringSync(encoding: utf8)
    .replaceAll('\r\n', '\n')
    .split('\n')
    .where((l) => l.isNotEmpty)
    .toList();

List<Map<String, Object?>> jsonlLinesAsMaps(String path) => [
  for (final l in goldenLines(path))
    (jsonDecode(l) as Map<String, dynamic>).cast<String, Object?>(),
];

/// skip-guard：公开仓库不含 content/ 与金样（课程语料，版权原因）。
/// 依赖真实源文件的用例在缺料环境自动跳过（同 search_engine_test 守卫纪律）。
bool corpusSourcesPresent() =>
    File(srcOmsPptx).existsSync() && File(srcExamPdf).existsSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory root;
  late String treeA; // oms pptx + exam 试卷 PDF（主对拍树）
  late String corpusA; // 树 A 工作区（chunks.jsonl/manifest/corpus.db/toc）
  late String treeB; // 同名 stem 去重树（两份同内容 exam PDF）
  late String corpusB;

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('hengya_extract_all_test_');
    treeA = '${root.path}/treeA';
    corpusA = '${root.path}/corpusA';
    treeB = '${root.path}/treeB';
    corpusB = '${root.path}/corpusB';
    Directory('$treeA/oms').createSync(recursive: true);
    Directory('$treeA/exam/试卷与模拟题').createSync(recursive: true);
    if (corpusSourcesPresent()) {
      File(srcOmsPptx).copySync('$treeA/oms/${pyNameOf(srcOmsPptx)}');
      File(srcExamPdf).copySync('$treeA/exam/试卷与模拟题/$examPdfName');
    }
  });

  tearDownAll(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  // -------------------------------------------------- 0. 纯函数锚点 ----

  test('pyRound/quantize/vec0Normalize/mrlTruncate：Python 语义锚点', () {
    // Python round()：半偶舍入（banker's）
    expect(pyRound(2.5), 2);
    expect(pyRound(3.5), 4);
    expect(pyRound(-0.5), 0);
    expect(pyRound(-2.5), -2);
    expect(pyRound(2.4), 2);
    expect(pyRound(2.6), 3);
    expect(pyRound(-1.5), -2);
    // 量化：clamp(round(v/scale), -127, 127)，小端 int8
    expect(signedInt8(quantizeWithScale([1.0, -2.0, 300.0], 1.0)), [
      1,
      -2,
      127,
    ]);
    expect(signedInt8(quantizeWithScale([0.5, -1.0], 0.5)), [1, -2]);
    // 镜像归一：零向量 → null（skip 同口径）
    final n = vec0Normalize(Int8List.fromList([3, 4]))!;
    expect(n.length, 2);
    expect(n[0], closeTo(0.6, 1e-12));
    expect(n[1], closeTo(0.8, 1e-12));
    expect(vec0Normalize(Int8List.fromList([0, 0])), isNull);
    // MRL：客户端截断 + L2 重归一；维度不足报错
    final m = mrlTruncateRenorm([2.0, 3.0, 9.0], 2);
    expect(m.length, 2);
    var n2 = 0.0;
    for (final x in m) {
      n2 += x * x;
    }
    expect(n2, closeTo(1.0, 1e-9));
    expect(() => mrlTruncateRenorm([1.0], 2), throwsStateError);
    // 内容指纹：md5("v1|model|content") 十六进制 32 位
    expect(contentMd5('local-charhash-1024-v1', '龋病'), hasLength(32));
    expect(contentMd5('m', 'c'), isNot(contentMd5('m', 'd')));
  });

  // --------------------------------------------- 1. 抽取 → 金样逐字节 ----

  test(
    'extractAllCorpus：树扫描分派三抽取器 → chunks.jsonl 与金样逐字节一致',
    () async {
      if (!corpusSourcesPresent()) {
        // ignore: avoid_print
        print('SKIP: 私有语料缺失（content/ 不在公开仓库）');
        return;
      }
      final ex = extractAllCorpus(treeA, '$corpusA/chunks.jsonl');
      expect(ex.errors, isEmpty, reason: '抽取失败：${ex.errors}');
      expect(ex.skippedBig, isEmpty);
      expect(ex.decksTotal, 2);
      expect(ex.changed, 2);
      expect(ex.unchanged, 0);
      expect(ex.removed, 0);
      expect(ex.chunks, 111); // 92 (oms pptx) + 19 (exam pdf)
      expect(ex.bySubject, {'exam': 1, 'oms': 1});

      final out = File('$corpusA/chunks.jsonl')
          .readAsStringSync(encoding: utf8)
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
      expect(out.length, 111);
      // 按 deck 切片（行序 = 扫描序：exam < oms；deck 内 = 抽取序 = 金样序）
      final examLines = [
        for (final l in out)
          if ((jsonDecode(l) as Map)['subject_id'] == 'exam') l,
      ];
      final omsLines = [
        for (final l in out)
          if ((jsonDecode(l) as Map)['subject_id'] == 'oms') l,
      ];
      expect(examLines.length, 19);
      expect(omsLines.length, 92);
      expect(
        '${examLines.join('\n')}\n',
        '${goldenLines(goldenExam).join('\n')}\n',
        reason: 'exam PDF 19 chunks 与金样不一致',
      );
      expect(
        '${omsLines.join('\n')}\n',
        '${goldenLines(goldenOms).join('\n')}\n',
        reason: 'oms pptx 92 chunks 与金样不一致',
      );
      // manifest 原子落盘 + 键 = 相对 posix 路径
      final manifest =
          jsonDecode(
                File('$corpusA/chunks.jsonl.manifest.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(manifest['version'], 1);
      final files = (manifest['files'] as Map<String, dynamic>).keys.toList();
      expect(files, contains('exam/试卷与模拟题/$examPdfName'));
      expect(files, contains('oms/${pyNameOf(srcOmsPptx)}'));
      // 教材源才写 toc sidecar；本树无教材 → toc 目录不产生
      expect(Directory('$corpusA/toc').existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // ------------------------------------------------- 2. 建库 → 契约 ----

  test(
    'ingestCorpus（drill）：schema/行数/关键列与金样一致 + 镜像/FTS/meta',
    () async {
      if (!corpusSourcesPresent()) {
        // ignore: avoid_print
        print('SKIP: 私有语料缺失（content/ 不在公开仓库）');
        return;
      }
      final ing = await ingestCorpus(
        '$corpusA/corpus.db',
        '$corpusA/chunks.jsonl',
        embed: const CorpusEmbedConfig.drill(),
      );
      expect(ing.rows, 111);
      expect(ing.badLines, 0);
      expect(ing.pending, 111);
      expect(ing.embedded, 111);
      expect(ing.resumed, 0);
      expect(ing.prunedStale, 0);
      expect(ing.prunedAbsent, 0);
      expect(ing.batches, greaterThanOrEqualTo(1));
      expect(ing.vec0['ok'], isTrue, reason: '镜像重建失败：${ing.vec0}');
      expect(ing.scale, greaterThan(0));

      final db = sqlite3.open('$corpusA/corpus.db');
      try {
        // schema 契约逐列（corpus_schema.sql 基准）
        expect([
          for (final r in db.select('PRAGMA table_info("chunks")'))
            '${r.columnAt(1)}',
        ], kChunkFields);
        expect(
          [
            for (final r in db.select('PRAGMA table_info("vectors")'))
              '${r.columnAt(1)}',
          ],
          ['chunk_id', 'dim', 'vec', 'scale'],
        );
        expect(
          [
            for (final r in db.select('PRAGMA table_info("chunk_state")'))
              '${r.columnAt(1)}',
          ],
          ['chunk_id', 'content_md5', 'model', 'ts'],
        );
        expect(
          [
            for (final r in db.select('PRAGMA table_info("deck_state")'))
              '${r.columnAt(1)}',
          ],
          [
            'subject_id',
            'ppt_id',
            'source',
            'file_path',
            'file_md5',
            'chunk_count',
            'updated_at',
          ],
        );

        // 行数：chunks/vectors/chunk_state/FTS/镜像
        expect(_count(db, 'chunks'), 111);
        expect(_count(db, 'vectors'), 111);
        expect(_count(db, 'chunk_state'), 111);
        expect(_count(db, 'chunks_fts'), 111);
        expect(_count(db, kVec0Table), 111);
        expect(_count(db, 'deck_state'), 2);

        // 关键列：与两份金样逐字段一致（111 行 × 10 字段）
        final golden = <String, Map<String, Object?>>{};
        for (final m in jsonlLinesAsMaps(
          goldenOms,
        ).followedBy(jsonlLinesAsMaps(goldenExam))) {
          golden['${m['chunk_id']}'] = m;
        }
        expect(golden.length, 111);
        final rows = db.select(
          'SELECT chunk_id, subject_id, ppt_id, deck, page_start, page_end, '
          'title, text, source_type, file_date FROM chunks',
        );
        expect(rows.length, 111);
        for (final r in rows) {
          final g = golden['${r.columnAt(0)}'];
          expect(g, isNotNull, reason: '库内多出金样外 chunk：${r.columnAt(0)}');
          expect(
            [
              '${r.columnAt(1)}',
              '${r.columnAt(2)}',
              '${r.columnAt(3)}',
              r.columnAt(4),
              r.columnAt(5),
              '${r.columnAt(6)}',
              '${r.columnAt(7)}',
              '${r.columnAt(8)}',
              '${r.columnAt(9)}',
            ],
            [
              g!['subject_id'],
              g['ppt_id'],
              g['deck'],
              g['page_start'],
              g['page_end'],
              g['title'],
              g['text'],
              g['source_type'],
              g['file_date'],
            ],
            reason: 'chunk ${r.columnAt(0)} 字段与金样不一致',
          );
        }

        // vectors：int8×1024、每库一 scale、BLOB 长度 = dim
        final scales = <double>{};
        for (final r in db.select('SELECT dim, vec, scale FROM vectors')) {
          expect(r.columnAt(0), 1024);
          expect((r.columnAt(1) as Uint8List).length, 1024);
          scales.add((r.columnAt(2) as num).toDouble());
        }
        expect(scales.length, 1, reason: '每库一 scale 破坏：$scales');

        // vec_chunks 镜像：float32 4096B/行 + 归一化（自点积 = 1）
        final first = db.select('SELECT v FROM $kVec0Table LIMIT 1').first;
        final blob = first.columnAt(0) as Uint8List;
        expect(blob.length, 4096);
        final f = Float32List.view(
          blob.buffer,
          blob.offsetInBytes,
          blob.lengthInBytes ~/ 4,
        );
        var n2 = 0.0;
        for (final x in f) {
          n2 += x * x;
        }
        expect(n2, closeTo(1.0, 1e-5), reason: '镜像向量未归一化');

        final meta = <String, String>{};
        for (final r in db.select('SELECT key, value FROM meta')) {
          meta['${r.columnAt(0)}'] = '${r.columnAt(1)}';
        }
        expect(meta['embedding_model'], kLocalEmbedModel);
        expect(meta['embedding_dim'], '1024');
        expect(meta['fts_mode'], 'fts5_trigram');
        expect(meta['corpus_kind'], 'dryrun-ingest');
        expect(meta['vec0_dim'], '1024');
        expect(meta['vec0_rows'], '111');
        expect(meta['vec0_version'], 'dart-native-blob');
        expect(meta['built_at'], isNotNull);
        expect(meta['updated_at'], isNotNull);
        expect(meta['quant_scale'], scales.first.toString());
        expect(meta['last_ingest'], isNotNull);

        // FTS 功能：金样文本三元组可命中其 chunk_id
        final g0 = jsonlLinesAsMaps(goldenOms).first;
        final m = RegExp(r'[\u4e00-\u9fff]{4}').firstMatch('${g0['text']}')!;
        final ftsHit = db.select(
          'SELECT chunk_id FROM chunks_fts WHERE chunks_fts MATCH ?',
          [m[0]!],
        );
        expect(
          ftsHit.map((r) => '${r.columnAt(0)}'),
          contains('${g0['chunk_id']}'),
        );

        // deck_state：tree 来源 + chunk_count
        final decks = {
          for (final r in db.select(
            'SELECT subject_id, ppt_id, source, chunk_count FROM deck_state',
          ))
            ('${r.columnAt(0)}', '${r.columnAt(1)}'): (
              source: '${r.columnAt(2)}',
              count: r.columnAt(3) as int,
            ),
        };
        expect(decks.length, 2);
        expect(decks[('exam', pyStemOf(examPdfName))]!.source, 'tree');
        expect(decks[('exam', pyStemOf(examPdfName))]!.count, 19);
        expect(decks[('oms', pyStemOf(pyNameOf(srcOmsPptx)))]!.count, 92);
      } finally {
        db.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // ----------------------------------------------------- 3. 幂等收敛 ----

  test(
    '幂等：重跑 extract/ingest 全收敛（跳过/续传/计数不变）',
    () async {
      if (!corpusSourcesPresent()) {
        // ignore: avoid_print
        print('SKIP: 私有语料缺失（content/ 不在公开仓库）');
        return;
      }
      final before = File('$corpusA/chunks.jsonl').readAsBytesSync();
      final ex2 = extractAllCorpus(treeA, '$corpusA/chunks.jsonl');
      expect(ex2.changed, 0, reason: 'manifest 快速路径失效：重抽了文件');
      expect(ex2.unchanged, 2);
      expect(ex2.removed, 0);
      expect(ex2.chunks, 111);
      expect(
        File('$corpusA/chunks.jsonl').readAsBytesSync(),
        before,
        reason: '重跑后 chunks.jsonl 字节级漂移',
      );

      final ing2 = await ingestCorpus(
        '$corpusA/corpus.db',
        '$corpusA/chunks.jsonl',
        embed: const CorpusEmbedConfig.drill(),
      );
      expect(ing2.rows, 111);
      expect(ing2.pending, 0);
      expect(ing2.resumed, 111, reason: 'chunk_state 续传失效：重复嵌入');
      expect(ing2.embedded, 0);
      expect(ing2.prunedStale, 0);
      expect(ing2.prunedAbsent, 0);

      final db = sqlite3.open('$corpusA/corpus.db');
      try {
        expect(_count(db, 'chunks'), 111);
        expect(_count(db, 'vectors'), 111);
        expect(_count(db, kVec0Table), 111);
        expect(_count(db, 'chunks_fts'), 111);
      } finally {
        db.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // ------------------------------------------- 4. 离线检索冒烟 + 两态等价 ----

  test('corpusSearch 离线检索冒烟：镜像点积路 + 流式回退路两态等价命中', () async {
    if (!corpusSourcesPresent()) {
      // ignore: avoid_print
      print('SKIP: 私有语料缺失（content/ 不在公开仓库）');
      return;
    }
    // 动态取查询词：金样 oms 首 chunk 文本的 6 连汉字（词面命中保底）
    final g0 = jsonlLinesAsMaps(goldenOms).first;
    final m = RegExp(r'[\u4e00-\u9fff]{6}').firstMatch('${g0['text']}')!;
    final query = m[0]!;
    final expectedChunkId = '${g0['chunk_id']}';

    final db = sqlite3.open('$corpusA/corpus.db');
    try {
      final res = await corpusSearch(
        db,
        query,
        k: 5,
        offline: true,
        rerank: false,
      );
      final hits = (res['results'] as List).cast<Map<String, Object?>>();
      expect(hits, isNotEmpty, reason: '离线检索零命中');
      expect(
        hits.take(3).map((h) => '${h['chunk_id']}'),
        contains(expectedChunkId),
        reason: '金样来源 chunk 未进 top-3（query=$query）',
      );
      final notes = (res['notes'] as List).join('\n');
      expect(notes, contains('vec0 距离全扫'), reason: '镜像点积路未被消费（notes：$notes）');

      // 两态等价：vec0 off（int8 流式回退）与 on（镜像）同结果集 + 分数容差
      final res2 = await corpusSearch(
        db,
        query,
        k: 5,
        offline: true,
        rerank: false,
        vec0: false,
      );
      final hits2 = (res2['results'] as List).cast<Map<String, Object?>>();
      expect(
        hits2.map((h) => '${h['chunk_id']}'),
        hits.map((h) => '${h['chunk_id']}'),
        reason: '镜像/流式两态结果集不一致',
      );
      final byId = {for (final h in hits) '${h['chunk_id']}': h};
      for (final h2 in hits2) {
        final h1 = byId['${h2['chunk_id']}']!;
        expect(
          ((h2['vec'] as num) - (h1['vec'] as num)).abs(),
          lessThan(1e-3),
          reason: 'cos 两态漂移超容差：${h2['chunk_id']}',
        );
      }
      expect((res2['notes'] as List).join('\n'), contains('流式扫描'));
    } finally {
      db.dispose();
    }
  });

  // --------------------------------------------- 5. 换版覆盖 / 树外剪除 ----

  test('换版：同名替换→删旧插新；删除→树外 deck 剪除', () async {
    if (!corpusSourcesPresent()) {
      // ignore: avoid_print
      print('SKIP: 私有语料缺失（content/ 不在公开仓库）');
      return;
    }
    // ① 换版：同名文件换内容（试卷 PDF ← 牙列缺失 PDF）→ deck 删旧插新
    final replacedFile = File('$treeA/exam/试卷与模拟题/$examPdfName');
    if (replacedFile.existsSync()) replacedFile.deleteSync();
    File(srcOtherExamPdf).copySync(replacedFile.path);

    final ex3 = extractAllCorpus(treeA, '$corpusA/chunks.jsonl');
    expect(ex3.errors, isEmpty);
    expect(ex3.changed, 1);
    expect(ex3.unchanged, 1); // oms pptx 走 manifest 快速路径
    expect(ex3.removed, 0);
    final lines3 = File('$corpusA/chunks.jsonl')
        .readAsStringSync(encoding: utf8)
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
    final newExamIds = <String>{};
    var newCount = 0;
    for (final l in lines3) {
      final r = jsonDecode(l) as Map<String, dynamic>;
      if (r['subject_id'] == 'exam') {
        newCount++;
        newExamIds.add('${r['chunk_id']}');
      }
    }
    expect(newCount, greaterThan(0));
    expect(ex3.chunks, 92 + newCount);
    // 期望剪除数 = 旧 19 中不在新版 chunk_id 集合内的行数（页码区间重叠
    // 时同 id 保留——deck 幂等按 chunk_id 对齐，内容变更由 content_md5 重嵌）
    final oldIds = {
      for (final g in jsonlLinesAsMaps(goldenExam)) '${g['chunk_id']}',
    };
    final overlap = oldIds.intersection(newExamIds).length;
    final expectPrune = 19 - overlap;

    final ing3 = await ingestCorpus(
      '$corpusA/corpus.db',
      '$corpusA/chunks.jsonl',
      embed: const CorpusEmbedConfig.drill(),
      pruneAbsent: true,
    );
    expect(
      ing3.prunedStale,
      expectPrune,
      reason: 'deck 删旧插新剪除数不符（overlap=$overlap）',
    );
    expect(ing3.resumed, 92, reason: 'oms deck 未变却重嵌');
    expect(ing3.embedded, newCount, reason: '换版 deck 应全量重嵌');

    final db = sqlite3.open('$corpusA/corpus.db');
    try {
      expect(_count(db, 'chunks'), 92 + newCount);
      expect(_count(db, 'vectors'), 92 + newCount);
      expect(_count(db, kVec0Table), 92 + newCount);
      expect(_count(db, 'chunks_fts'), 92 + newCount);
      // 旧版独有 chunk_id 已全部消失
      for (final id in oldIds.difference(newExamIds)) {
        expect(
          db.select('SELECT 1 FROM chunks WHERE chunk_id=?', [id]),
          isEmpty,
          reason: '旧版 chunk 未删净：$id',
        );
      }
    } finally {
      db.dispose();
    }

    // ② 删除：文件消失 → 树外 deck 剪除（prune_absent）
    replacedFile.deleteSync();
    final ex4 = extractAllCorpus(treeA, '$corpusA/chunks.jsonl');
    expect(ex4.removed, 1);
    expect(ex4.changed, 0);
    expect(ex4.chunks, 92);
    final ing4 = await ingestCorpus(
      '$corpusA/corpus.db',
      '$corpusA/chunks.jsonl',
      embed: const CorpusEmbedConfig.drill(),
      pruneAbsent: true,
    );
    expect(ing4.prunedAbsent, newCount, reason: '树外 deck 剪除计数不符');
    expect(ing4.rows, 92);

    final db2 = sqlite3.open('$corpusA/corpus.db');
    try {
      expect(_count(db2, 'chunks'), 92);
      expect(_count(db2, 'vectors'), 92);
      expect(_count(db2, kVec0Table), 92);
      expect(_count(db2, 'chunks_fts'), 92);
      expect(_count(db2, 'deck_state'), 1); // 仅剩 oms
    } finally {
      db2.dispose();
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  // ----------------------------------------------- 6. 同名 stem 去重 ----

  test('同名 stem 同轮去重：第二份 -2 后缀 + chunk_id 前缀替换', () async {
    if (!corpusSourcesPresent()) {
      // ignore: avoid_print
      print('SKIP: 私有语料缺失（content/ 不在公开仓库）');
      return;
    }
    Directory('$treeB/exam/sub').createSync(recursive: true);
    File(srcOtherExamPdf).copySync('$treeB/exam/x.pdf');
    File(srcOtherExamPdf).copySync('$treeB/exam/sub/x.pdf');

    final ex = extractAllCorpus(treeB, '$corpusB/chunks.jsonl');
    expect(ex.errors, isEmpty);
    expect(ex.changed, 2);
    expect(ex.bySubject, {'exam': 2});

    final lines = File('$corpusB/chunks.jsonl')
        .readAsStringSync(encoding: utf8)
        .split('\n')
        .where((l) => l.isNotEmpty)
        .toList();
    final deck1 = [
      for (final l in lines)
        if ((jsonDecode(l) as Map)['ppt_id'] == 'x') l,
    ];
    final deck2 = [
      for (final l in lines)
        if ((jsonDecode(l) as Map)['ppt_id'] == 'x-2') l,
    ];
    // 扫描序：exam/sub/x.pdf < exam/x.pdf → sub 份先取 stem，顶层份 -2
    expect(deck1, isNotEmpty);
    expect(deck2, isNotEmpty);
    expect(deck2.length, deck1.length, reason: '同内容两份 chunk 数应一致');
    for (final l in deck2) {
      final r = jsonDecode(l) as Map<String, dynamic>;
      expect(r['ppt_id'], 'x-2');
      expect(
        '${r['chunk_id']}',
        startsWith('exam:x-2:'),
        reason: 'chunk_id 前缀替换失败（拆分后缀 -sN 应保留）',
      );
    }
    // 前缀替换逐行等价：deck2 = deck1 换 ppt_id/chunk_id 前缀（其余字段同）
    for (var i = 0; i < deck1.length; i++) {
      final a = jsonDecode(deck1[i]) as Map<String, dynamic>;
      final b = jsonDecode(deck2[i]) as Map<String, dynamic>;
      for (final f in ['title', 'text', 'page_start', 'page_end', 'deck']) {
        expect(b[f], a[f], reason: '前缀替换破坏了内容字段：$f');
      }
    }
  });

  // -------------------------------------------------- 7. offline 建库 ----

  test(
    'offline 建库：无 key 不写向量 → 词面单路检索命中',
    () async {
      if (!corpusSourcesPresent()) {
        // ignore: avoid_print
        print('SKIP: 私有语料缺失（content/ 不在公开仓库）');
        return;
      }
      final ing = await ingestCorpus(
        '$corpusB/corpus.db',
        '$corpusB/chunks.jsonl',
        embed: const CorpusEmbedConfig.offline(),
      );
      final total = ing.rows;
      expect(total, greaterThan(0));
      expect(ing.embedded, 0);
      expect(ing.resumed, 0);
      expect(ing.vec0['ok'], isFalse, reason: '无向量行时镜像不应 ok');

      final db = sqlite3.open('$corpusB/corpus.db');
      try {
        expect(_count(db, 'chunks'), total);
        expect(_count(db, 'vectors'), 0);
        expect(_count(db, 'chunks_fts'), total);
        expect(_count(db, kVec0Table), -1, reason: '镜像表应保持删除');
        final meta = <String, String>{};
        for (final r in db.select('SELECT key, value FROM meta')) {
          meta['${r.columnAt(0)}'] = '${r.columnAt(1)}';
        }
        expect(
          meta['embedding_model'],
          kEmbedModel,
          reason: 'offline 也按目标模型口径写 meta（后续在线补嵌收敛）',
        );
        expect(meta['embedding_dim'], '1024');
        expect(meta['fts_mode'], 'fts5_trigram');
        expect(meta['corpus_kind'], 'offline-ingest');
        expect(meta.containsKey('vec0_dim'), isFalse);

        // 词面单路检索：offline 查询嵌入与库内 Qwen meta 互斥 → 向量路拦截
        final g = RegExp(
          r'[\u4e00-\u9fff]{6}',
        ).firstMatch(File('$corpusB/chunks.jsonl').readAsStringSync())!;
        final res = await corpusSearch(
          db,
          g[0]!,
          k: 5,
          offline: true,
          rerank: false,
        );
        final hits = (res['results'] as List).cast<Map<String, Object?>>();
        expect(hits, isNotEmpty, reason: '词面单路应命中非空');
        final notes = (res['notes'] as List).join('\n');
        expect(notes, contains('嵌入空间不兼容'), reason: '模型互斥未拦截向量路');
        for (final h in hits) {
          expect((h['vec'] as num) == 0, isTrue);
        }
      } finally {
        db.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  // ------------------------------------------------- 8. resetVectors 彻底重建 ----
  // v0.1.10 修复验收（不依赖私有语料）：「重建全部向量」= 库内全量 ∪ jsonl
  // 新行（chunk_id 去重、jsonl 优先）。v1 缺陷：jsonl 非空时只重建 jsonl 行，
  // 库内语料包导入的 chunks（不在 jsonl）被排除。本用例直接构造「库内 2 chunk
  // + jsonl 1 chunk（同 id 覆盖）」场景：resetVectors=true 后 pending=2，
  // vectors 全量重嵌、旧向量清空后不复现、jsonl 行内容优先。
  test('resetVectors 彻底重建：库内全量 ∪ jsonl 新行合并，非 jsonl 行也重嵌', () async {
    final dir = '${root.path}/resetVec';
    Directory(dir).createSync(recursive: true);
    final dbPath = '$dir/corpus.db';
    final jsonlPath = '$dir/chunks.jsonl';

    // 直接建 schema + 预置「库内有 chunk_b 但 jsonl 无该行」（模拟语料包导入）
    final db = openCorpusDb(dbPath);
    try {
      db.execute(
        'CREATE TABLE IF NOT EXISTS chunks(chunk_id TEXT PRIMARY KEY, '
        'subject_id TEXT, ppt_id TEXT, deck TEXT, page_start INTEGER, '
        'page_end INTEGER, title TEXT, text TEXT, source_type TEXT, '
        'file_date TEXT)',
      );
      db.execute(
        'INSERT INTO chunks(chunk_id, subject_id, ppt_id, deck, '
        'title, text, source_type) VALUES '
        '(\'oms:a:p1\',\'oms\',\'a\',\'a\',\'t1\',\'库内行甲\',\'ppt\'),'
        '(\'oms:b:p1\',\'oms\',\'b\',\'b\',\'t2\',\'库内行乙\',\'ppt\')',
      );
    } finally {
      db.dispose();
    }

    // jsonl 只有 1 行（oms:a:p1，与库内同 id 但 text 不同=最新抽取内容）
    File(jsonlPath).writeAsStringSync(
      '{"chunk_id":"oms:a:p1","subject_id":"oms","ppt_id":"a","deck":"a",'
      '"page_start":1,"page_end":1,"title":"t1new","text":"jsonl新内容",'
      '"source_type":"ppt","file_date":""}\n',
      encoding: utf8,
    );

    final ing = await ingestCorpus(
      dbPath,
      jsonlPath,
      embed: const CorpusEmbedConfig.drill(),
      resetVectors: true,
      preserveDeckSource: true,
    );
    // 库内 2 行全部进入重建（jsonl 1 + 库内独有 1 → 合并 2）
    expect(ing.pending, 2, reason: 'resetVectors 必须重建库内全量而非仅 jsonl 行');
    expect(ing.embedded, 2);
    expect(ing.resumed, 0);

    final db2 = openCorpusDb(dbPath);
    try {
      expect(_count(db2, 'vectors'), 2);
      // 同 id 行以 jsonl 新内容为准（upsert 生效）
      final t = db2
          .select("SELECT text FROM chunks WHERE chunk_id='oms:a:p1'")
          .first
          .columnAt(0);
      expect(t, 'jsonl新内容');
      final tB = db2
          .select("SELECT text FROM chunks WHERE chunk_id='oms:b:p1'")
          .first
          .columnAt(0);
      expect(tB, '库内行乙', reason: '库内独有行不得被重建流程剪除');
      // deck_state 双 deck 均在（未误剪树内/库内行）
      expect(
        db2.select('SELECT count(*) FROM deck_state').first.columnAt(0),
        2,
      );
      // FTS/镜像均重建且含库内独有行
      expect(_count(db2, 'vec_chunks'), 2);
    } finally {
      db2.dispose();
    }
  });
}

// ------------------------------------------------------------ helpers ----

int _count(Database db, String table) {
  try {
    return db.select('SELECT count(*) FROM "$table"').first.columnAt(0) as int;
  } catch (_) {
    return -1; // 表不存在（镜像表在无向量行时保持删除）
  }
}

String pyNameOf(String path) =>
    path.split(Platform.pathSeparator).last.split('/').last;

String pyStemOf(String name) {
  final i = name.lastIndexOf('.');
  return (i > 0 && i < name.length - 1) ? name.substring(0, i) : name;
}
