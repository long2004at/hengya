// 节点④：大纲 DOCX 解析 / outline_entries 入库 / 细目打标 单元测试。
//
// 不依赖 D:\hengya\content（真机路径）——fixture 自造小 DOCX（内存表格
// 注入：Archive ZipEncoder 只放 word/document.xml，解析器与真实大纲同构：
// 单格部分/学科标题行、三列/四列数据行、vMerge restart/cont 纵向合并、
// 「单元|细目|要点(要求)」表头行）。
//
// 宿主纪律：纯 Dart 单测不调 TestWidgetsFlutterBinding.ensureInitialized；
// DB 用例（ensureOutlineSchema/ingestOutlineFiles/loadZhiyeSubtopicIndex）
// 显式加载 test/sqlite3.dll（overrideForAll，与 local_backend_test 同款）。
import 'dart:convert' as convert;
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:hengya/services/local/corpus/extract_all.dart'
    show
        CorpusEmbedConfig,
        buildCorpus,
        ensureCorpusSchema,
        extractAllCorpus,
        openCorpusDb;
import 'package:hengya/services/local/corpus/extract_pptx.dart'
    show splitSubjectSource;
import 'package:hengya/services/local/corpus/outline_docx.dart' as outline;
import 'package:hengya/services/local/corpus/progress_db.dart'
    show loadProgress, progressEntryOf;
import 'package:hengya/services/local/corpus/run_engine.dart' show examDeckOk;
import 'package:hengya/services/local/corpus_build_job.dart'
    show ensureMedSubjectPlaceholder;
import 'package:hengya/services/local/db.dart';
import 'package:hengya/services/local/pipeline_runner.dart'
    show applyOutlineTags;
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  if (Platform.isWindows) {
    sqlite_open.open
        .overrideForAll(() => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('node4_outline_test_');
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  // ---------------------------------------------------- fixture 构造 ----

  String esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  String pXml(String text) =>
      '<w:p><w:r><w:t xml:space="preserve">${esc(text)}</w:t></w:r></w:p>';

  /// 单元格：[vmerge] 'restart'|'cont'（cont = 无 val 属性，Word 语义）。
  String tc(String text, {String? vmerge, int? gridSpan}) {
    final props = <String>[
      if (vmerge == 'restart') '<w:vMerge w:val="restart"/>',
      if (vmerge == 'cont') '<w:vMerge/>',
      if (gridSpan != null) '<w:gridSpan w:val="$gridSpan"/>',
    ].join();
    return '<w:tc>${props.isEmpty ? '' : '<w:tcPr>$props</w:tcPr>'}${pXml(text)}</w:tc>';
  }

  /// 单格标题行（部分/学科/说明——gridSpan 不影响解析：cells.length==1）。
  String tr1(String text) => '<w:tr>${tc(text, gridSpan: 3)}</w:tr>';

  /// 三列数据行（执业版）。
  String tr3(String u, String s, String p,
      {bool uCont = false, bool sCont = false}) {
    return '<w:tr>'
        '${tc(u, vmerge: uCont ? 'cont' : null)}'
        '${tc(s, vmerge: sCont ? 'cont' : null)}'
        '${tc(p)}'
        '</w:tr>';
  }

  /// 四列数据行（助理版：第 4 列「要求」解析忽略）。
  String tr4(String u, String s, String p, String req,
      {bool uCont = false, bool sCont = false}) {
    return '<w:tr>'
        '${tc(u, vmerge: uCont ? 'cont' : null)}'
        '${tc(s, vmerge: sCont ? 'cont' : null)}'
        '${tc(p)}'
        '${tc(req)}'
        '</w:tr>';
  }

  File buildDocx(String path, List<String> rows) {
    final doc = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document '
        'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body><w:tbl>${rows.join()}</w:tbl></w:body></w:document>';
    final bytes = convert.utf8.encode(doc);
    final archive = Archive()
      ..add(ArchiveFile('word/document.xml', bytes.length, bytes));
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(ZipEncoder().encode(archive));
    return f;
  }

  /// 五级树 fixture：人文（含学科）→ 临床（无学科，直接单元）→
  /// 口腔（牙体牙髓病学 + 无映射学科口腔正畸学）。
  List<String> treeRows({bool zhuli = false}) {
    String d(String u, String s, String p,
        {bool uCont = false, bool sCont = false}) {
      return zhuli
          ? tr4(u, s, p, '掌握', uCont: uCont, sCont: sCont)
          : tr3(u, s, p, uCont: uCont, sCont: sCont);
    }

    final header = zhuli
        ? tr4('单  元', '细  目', '要  点', '要  求')
        : tr3('单  元', '细  目', '要    点');
    return [
      tr1('第一部分  医学人文综合'),
      tr1('主要包括口腔医师必须掌握的医学心理、医学伦理等医学人文学科的基础知识'),
      tr1('一、医学心理学'),
      header,
      d('一、医学心理学总论', '1．医学心理学的概述', '（1）医学心理学的概念与性质'),
      d('', '', '（2）医学模式的转化', uCont: true, sCont: true),
      d('', '2．认识过程', '（1）感觉与知觉的概念', uCont: true),
      tr1('第三部分  临床医学综合'),
      tr1('主要包括口腔医师必须掌握的相关临床理论与知识'),
      header,
      d('一、诊断学', '1．症状', '（1）发热'),
      d('', '', '（2）胸痛', uCont: true, sCont: true),
      tr1('第五部分  口腔医学综合'),
      tr1('主要包括口腔医师必须掌握的口腔医学专业理论与知识'),
      tr1('三、牙体牙髓病学'),
      header,
      d('一、龋病', '1．概述', '（1）定义、病因和发病机制'),
      d('', '', '（2）牙髓牙本质复合体', uCont: true, sCont: true),
      d('', '2．临床表现及诊断', '（1）分类', uCont: true),
      tr1('四、口腔正畸学'),
      header,
      d('一、错𬌗畸形', '1．概述', '（1）病因'),
    ];
  }

  // ---------------------------------------------------- A. 解析 ----

  group('A. 五级条目树 + vMerge 重建', () {
    test('vMerge cont 跨行继承单元/细目；五级字段与 path 落位', () {
      final f = buildDocx('${tmp.path}/执业大纲.docx', treeRows());
      final r = outline.parseOutlineDocx(f.path,
          level: outline.kOutlineLevelZhiye);

      // 入库条目：人文 3 + 临床 2 + endo 3 + 正畸 1（skipped）→ 8 减正畸 = 7?
      // 正畸属口腔部分且无映射 → 跳过；其余 3+2+3 = 8。
      expect(r.entries.length, 8, reason: '正畸（无映射）跳过');
      expect(r.skippedSubjects, ['口腔正畸学']);

      final e0 = r.entries[0];
      expect(e0.part, '第一部分 医学人文综合');
      expect(e0.subject, outline.kMedSubjectCode); // 非口腔部分 → med
      expect(e0.subjectName, '医学心理学');
      expect(e0.unit, '一、医学心理学总论');
      expect(e0.subtopic, '1．医学心理学的概述');
      expect(e0.point, '（1）医学心理学的概念与性质');
      expect(e0.seq, 1);
      expect(
        e0.path,
        '第一部分 医学人文综合＞医学心理学＞一、医学心理学总论＞'
        '1．医学心理学的概述＞（1）医学心理学的概念与性质',
      );

      // vMerge 继承：第 2 行单元/细目均为 cont → 沿用
      final e1 = r.entries[1];
      expect(e1.unit, '一、医学心理学总论');
      expect(e1.subtopic, '1．医学心理学的概述');
      expect(e1.point, '（2）医学模式的转化');
      // 第 3 行：细目 restart、单元 cont
      final e2 = r.entries[2];
      expect(e2.unit, '一、医学心理学总论');
      expect(e2.subtopic, '2．认识过程');

      // 临床部分（无学科级）：subject=med、subject_name 空、path 无学科段
      final e3 = r.entries[3];
      expect(e3.part, '第三部分 临床医学综合');
      expect(e3.subject, 'med');
      expect(e3.subjectName, '');
      expect(e3.unit, '一、诊断学');
      expect(
        e3.path,
        '第三部分 临床医学综合＞一、诊断学＞1．症状＞（1）发热',
      );

      // 口腔部分：学科短码映射
      final e5 = r.entries[5];
      expect(e5.part, '第五部分 口腔医学综合');
      expect(e5.subject, 'endo');
      expect(e5.subjectName, '牙体牙髓病学');
      expect(e5.unit, '一、龋病');
      expect(e5.subtopic, '1．概述');
      final e7 = r.entries[7];
      expect(e7.subtopic, '2．临床表现及诊断');
      expect(e7.unit, '一、龋病');

      // 统计：部分 3 / 学科 3 / 说明 3 / 表头 4 / 数据行 9（含正畸 1 行）
      final s = r.stats;
      expect(s.partRows, 3);
      expect(s.subjectRows, 3);
      expect(s.descRows, 3);
      expect(s.headerRows, 4);
      expect(s.dataRows, 9);
      expect(s.entries, 8);
      expect(s.medEntries, 5); // 人文 3 + 临床 2
    });

    test('助理版四列表（第 4 列「要求」忽略）同构解析', () {
      final f = buildDocx('${tmp.path}/助理大纲.docx', treeRows(zhuli: true));
      final r = outline.parseOutlineDocx(f.path,
          level: outline.kOutlineLevelZhuli);
      expect(r.entries.length, 8);
      expect(r.stats.headerRows, 4); // 「…|要  求」表头也被识别跳过
      expect(r.entries.first.point, '（1）医学心理学的概念与性质');
      expect(r.entries.last.subject, 'endo');
    });

    test('坏 docx：缺 word/document.xml 抛 FormatException', () {
      final archive = Archive()
        ..add(ArchiveFile('unrelated.txt', 3, convert.utf8.encode('abc')));
      final f = File('${tmp.path}/bad.docx')
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      expect(
        () => outline.parseOutlineDocx(f.path, level: 'zhiye'),
        throwsFormatException,
      );
    });
  });

  group('C. 学科→短码映射与版本识别', () {
    test('映射表：10 学科 + 影像双拼写', () {
      expect(outline.kOutlineSubjectCodes['口腔组织病理学'], 'patho');
      expect(outline.kOutlineSubjectCodes['口腔解剖生理学'], 'anatomy');
      expect(outline.kOutlineSubjectCodes['牙体牙髓病学'], 'endo');
      expect(outline.kOutlineSubjectCodes['牙周病学'], 'peri');
      expect(outline.kOutlineSubjectCodes['口腔黏膜病学'], 'mucosa');
      expect(outline.kOutlineSubjectCodes['口腔颌面外科学'], 'oms');
      expect(outline.kOutlineSubjectCodes['口腔修复学'], 'prostho');
      expect(outline.kOutlineSubjectCodes['口腔颌面医学影像学'], 'imaging');
      // 真实 2024 大纲全名（规格名与实测名两种拼写都收）
      expect(outline.kOutlineSubjectCodes['口腔颌面医学影像诊断学'], 'imaging');
      expect(outline.kOutlineSubjectCodes['儿童口腔医学'], 'pedo');
      expect(outline.kOutlineSubjectCodes['口腔预防医学'], 'prevent');
    });

    test('文件名识别版本：含「助理」→ zhuli，否则 zhiye', () {
      expect(outline.outlineLevelOfFilename('6-口腔执业助理医师资格考试大纲.docx'),
          outline.kOutlineLevelZhuli);
      expect(outline.outlineLevelOfFilename('2-口腔执业医师资格考试大纲.docx'),
          outline.kOutlineLevelZhiye);
      expect(outline.outlineLevelOfFilename('随便什么大纲.docx'),
          outline.kOutlineLevelZhiye);
      // 路径形态（取末段文件名）
      expect(outline.outlineLevelOfFilename(r'D:\x\6-助理大纲.docx'),
          outline.kOutlineLevelZhuli);
    });
  });

  // ---------------------------------------------------- F/G. 路由与隔离 ----

  group('G. -outline 路由', () {
    test('splitSubjectSource：-outline 尾缀 → (短码, outline)', () {
      final r = splitSubjectSource('dagang-outline');
      expect(r.subject, 'dagang');
      expect(r.sourceType, 'outline');
      // 大小写不敏感（lower 匹配、原大小写截取）
      final r2 = splitSubjectSource('DAGANG-Outline');
      expect(r2.subject, 'DAGANG');
      expect(r2.sourceType, 'outline');
      // 既有词表不回归
      expect(splitSubjectSource('endo').sourceType, 'ppt');
      expect(splitSubjectSource('endo-textbook').sourceType, 'textbook');
      expect(splitSubjectSource('bingshi-exam').sourceType, 'exam');
      expect(splitSubjectSource('exam').sourceType, 'exam');
      expect(splitSubjectSource(null).subject, 'unknown');
    });

    test('F. 证据隔离：extractAllCorpus 跳过 -outline 树（0 chunks、'
        '不进 manifest、outlineFiles 上报）', () {
      buildDocx('${tmp.path}/incoming/dagang-outline/2-口腔执业医师资格考试大纲.docx',
          treeRows());
      final out = '${tmp.path}/out/chunks.jsonl';
      final stats = extractAllCorpus('${tmp.path}/incoming', out);
      expect(stats.chunks, 0, reason: '大纲正文绝不进常规语料块');
      expect(stats.outlineFiles.length, 1);
      expect(stats.outlineFiles.single, contains('dagang-outline'));
      // chunks.jsonl 落盘为空（无行，仅换行骨架）+ manifest 无文件条目
      expect(File(out).readAsStringSync().trim(), '');
      final manifest =
          convert.jsonDecode(File('$out.manifest.json').readAsStringSync())
              as Map<String, dynamic>;
      expect((manifest['files'] as Map).isEmpty, true);
      // toJson 携带 outline_files（进度事件契约）
      expect((stats.toJson()['outline_files'] as List).length, 1);
    });
  });

  // ---------------------------------------------------- B. 入库 ----

  group('B. outline_entries 入库', () {
    test('ensureCorpusSchema 一并建表；ingest 幂等（parsed → unchanged）',
        () {
      final db = openCorpusDb('${tmp.path}/corpus.db');
      try {
        ensureCorpusSchema(db);
        final tables = [
          for (final r in db.select(
              "SELECT name FROM sqlite_master WHERE type='table' AND name='outline_entries'"))
            r.columnAt(0),
        ];
        expect(tables, ['outline_entries']);

        final f =
            buildDocx('${tmp.path}/2-口腔执业医师资格考试大纲.docx', treeRows());
        final s1 = outline.ingestOutlineFiles(db, [f.path]);
        expect(s1.files.single.status, 'parsed');
        expect(s1.entries, 8);
        expect(outline.outlineEntryCount(db, 'zhiye'), 8);
        // med 归属：非口腔部分（人文 3 + 临床 2）
        final medN = db.select(
            "SELECT COUNT(*) FROM outline_entries WHERE subject='med'")[0]
            .columnAt(0);
        expect(medN, 5);

        // 重跑（同文件）→ md5 未变 → unchanged（不重插）
        final s2 = outline.ingestOutlineFiles(db, [f.path]);
        expect(s2.files.single.status, 'unchanged');
        expect(outline.outlineEntryCount(db, 'zhiye'), 8);

        // 文件变化 → 重新 parsed（按 level 整体替换，不叠行）
        File(f.path).writeAsBytesSync(f.readAsBytesSync()); // mtime 变但 md5 同
        final f2 = buildDocx('${tmp.path}/6-口腔执业助理医师资格考试大纲.docx',
            treeRows(zhuli: true));
        final s3 = outline.ingestOutlineFiles(db, [f2.path]);
        expect(s3.files.single.status, 'parsed');
        expect(s3.files.single.level, 'zhuli');
        expect(outline.outlineEntryCount(db, 'zhuli'), 8);
        expect(outline.outlineEntryCount(db), 16); // 两版本并存

        // 非 .docx → error（status 如实上报，不炸批）
        final bad = File('${tmp.path}/大纲.pdf')..writeAsBytesSync([1, 2, 3]);
        final s4 = outline.ingestOutlineFiles(db, [bad.path]);
        expect(s4.files.single.status, 'error');
      } finally {
        db.dispose();
      }
    });

    test('loadZhiyeSubtopicIndex：执业树细目索引（学科 → (单元, 细目) 去重）',
        () {
      final db = openCorpusDb('${tmp.path}/corpus2.db');
      try {
        final f = buildDocx('${tmp.path}/zhiye.docx', treeRows());
        outline.ingestOutlineFiles(db, [f.path]);
        final idx = outline.loadZhiyeSubtopicIndex(db);
        expect(idx.keys.toSet(), {'med', 'endo'});
        expect(idx['endo'], [
          ('一、龋病', '1．概述'),
          ('一、龋病', '2．临床表现及诊断'),
        ]);
        expect(idx['med']!.length, 3); // 人文 2 + 临床 1（(单元,细目) 去重后）
      } finally {
        db.dispose();
      }
    });

    test('buildCorpus 编排：大纲树 → outline_entries（0 chunks 不做语料入库）',
        () async {
      buildDocx('${tmp.path}/incoming/dagang-outline/2-口腔执业医师资格考试大纲.docx',
          treeRows());
      final dbPath = '${tmp.path}/corpus/corpus.db';
      final (ex, ing) = await buildCorpus(
        inputPath: '${tmp.path}/incoming',
        dbPath: dbPath,
        embed: const CorpusEmbedConfig.offline(),
      );
      expect(ex.chunks, 0);
      expect(ex.outlineFiles.length, 1);
      expect(ing, isNull, reason: '0 chunks → 不做语料块入库（仅大纲）');
      final db = openCorpusDb(dbPath);
      try {
        expect(outline.outlineEntryCount(db, 'zhiye'), 8);
        // 打标索引可载（下游 pipeline worker 同路）
        expect(outline.loadZhiyeSubtopicIndex(db).keys.toSet(), {'med', 'endo'});
      } finally {
        db.dispose();
      }
    });

    test('D. ensureMedSubjectPlaceholder：subjects 行 + progress.json 无罗盘占位（幂等）',
        () async {
      final dataDir = '${tmp.path}/data';
      Directory('$dataDir/corpus').createSync(recursive: true);
      final corpusDbPath = '$dataDir/corpus/corpus.db';
      await ensureMedSubjectPlaceholder(corpusDbPath);
      final db = await Db.open('$dataDir/hengya.db');
      try {
        expect(db.subjectExists('med'), isTrue);
        final subs = db.subjects();
        expect(subs.single.id, 'med');
        expect(subs.single.name, outline.kMedSubjectName);
        expect(subs.single.isExamSubject, isTrue);
      } finally {
        db.close();
      }
      final e = progressEntryOf(
          loadProgress('$dataDir/corpus/progress.json'), 'med');
      expect(e, isNotNull);
      expect(e!['textbook'], isNull, reason: 'derm 同款：无罗盘不参与复习提示');
      expect(e['learned_through'], 0);
      expect((e['history'] as List).single['source'], 'outline');
      // 幂等：再跑不动（history 仍 1 条、subjects 仍单行）
      await ensureMedSubjectPlaceholder(corpusDbPath);
      final e2 = progressEntryOf(
          loadProgress('$dataDir/corpus/progress.json'), 'med');
      expect((e2!['history'] as List).length, 1);
      final db2 = await Db.open('$dataDir/hengya.db');
      try {
        expect(db2.subjects().length, 1);
      } finally {
        db2.close();
      }
    });
  });

  // ---------------------------------------------------- E. 打标 ----

  group('E. 细目打标（词面强命中，宁缺勿滥）', () {
    final index = <String, List<(String, String)>>{
      'endo': [
        ('一、龋病', '1．概述'),
        ('一、龋病', '2．临床表现及诊断'),
        ('一、龋病', '3．治疗'),
        ('二、牙发育异常', '1．牙釉质发育不全'),
      ],
      'peri': [
        ('二、牙龈病', '1．慢性龈炎'),
      ],
    };

    test('stripOutlineOrdinal：剥「一、」「1．」「12．」序号前缀', () {
      expect(outline.stripOutlineOrdinal('一、龋病'), '龋病');
      expect(outline.stripOutlineOrdinal('12．肺炎'), '肺炎');
      expect(outline.stripOutlineOrdinal('1．概述'), '概述');
      expect(outline.stripOutlineOrdinal('（1）定义'), '（1）定义'); // 要点序号不剥
      expect(outline.stripOutlineOrdinal('无前缀'), '无前缀');
    });

    test('长细目名包含命中 → 「大纲：单元＞细目」（全角＞、序号剥除）', () {
      final tags = outline.outlineTagsFor(
        subjectId: 'endo',
        keyword: '龋病的临床表现及诊断',
        subtopics: const [],
        index: index,
      );
      expect(tags, ['大纲：龋病＞临床表现及诊断']);
    });

    test('短细目名（如「概述/治疗」）须单元名佐证才命中', () {
      // 关键词含「龋病」（单元）+「概述」（2 字细目）→ 命中
      expect(
        outline.outlineTagsFor(
            subjectId: 'endo', keyword: '龋病概述', subtopics: const [], index: index),
        ['大纲：龋病＞概述'],
      );
      // 只含「概述」不含任何单元名 → 不强推（跨单元歧义）
      expect(
        outline.outlineTagsFor(
            subjectId: 'endo', keyword: '概述一下', subtopics: const [], index: index),
        isEmpty,
      );
      // 「治疗」2 字 + 单元「龋病」在 → 命中 3．治疗
      expect(
        outline.outlineTagsFor(
            subjectId: 'endo', keyword: '龋病的治疗原则', subtopics: const [], index: index),
        ['大纲：龋病＞治疗'],
      );
    });

    test('子考点文本（plan 结构）参与匹配；未命中返回空', () {
      // 关键词不命中，子考点「牙釉质发育不全」命中（≥4 字长细目名）
      expect(
        outline.outlineTagsFor(
          subjectId: 'endo',
          keyword: '牙发育异常',
          subtopics: const ['牙釉质发育不全的定义和病因'],
          index: index,
        ),
        ['大纲：牙发育异常＞牙釉质发育不全'],
      );
      expect(
        outline.outlineTagsFor(
            subjectId: 'endo', keyword: '毫不相关xyz', subtopics: const [], index: index),
        isEmpty,
      );
    });

    test('未知科目 → 全树回退；命中 ≤kMaxOutlineTagsPerCard（按细目名长降序）',
        () {
      // derm 不在索引 → 回退全树（endo + peri）
      final tags = outline.outlineTagsFor(
        subjectId: 'derm',
        keyword: '龋病临床表现及诊断与慢性龈炎',
        subtopics: const [],
        index: index,
      );
      expect(tags.length, 2);
      expect(tags, contains('大纲：龋病＞临床表现及诊断'));
      expect(tags, contains('大纲：牙龈病＞慢性龈炎'));

      // 多命中截 3
      final many = outline.outlineTagsFor(
        subjectId: 'endo',
        keyword: '龋病概述治疗临床表现及诊断牙釉质发育不全',
        subtopics: const [],
        index: index,
      );
      expect(many.length, outline.kMaxOutlineTagsPerCard);
      // 优先长细目名：临床表现及诊断(7) / 牙釉质发育不全(7) / 概述(2)或治疗(2)
      expect(many, contains('大纲：龋病＞临床表现及诊断'));
      expect(many, contains('大纲：牙发育异常＞牙釉质发育不全'));
    });

    test('F. deck 排除：source_type=outline 一并剔除（kExamDeckExclude 语义保留）',
        () {
      // 既有语义：deck 名含「大纲」剔除
      expect(examDeckOk({'deck': '2-口腔执业医师资格考试大纲'}), isFalse);
      expect(examDeckOk({'deck': '2021年口腔执业医师资格试题（网友回忆版）'}), isTrue);
      expect(examDeckOk({'deck': null}), isTrue);
      // 节点④加固：拼音 deck 名不含「大纲」字面，但 source_type=outline → 剔除
      expect(
        examDeckOk({'deck': 'dagang-outline-x', 'source_type': 'outline'}),
        isFalse,
      );
      expect(examDeckOk({'deck': '外科课件', 'source_type': 'ppt'}), isTrue);
    });

    test('applyOutlineTags：该关键词全部卡追加 tags，≤3 上限，note 可观测',
        () {
      final kwres = <Map<String, Object?>>[
        {
          'keyword': '龋病的临床表现及诊断',
          'subjectId': 'endo',
          'subtopics': const ['临床表现及诊断'],
          'notes': <String>[],
          'cards': <Map<String, Object?>>[
            {
              'id': 'endo-a-001',
              'tags': <String>['待补原文'], // 占位卡也打标
            },
            {
              'id': 'endo-a-002',
              'tags': <String>[], // exam 卡（无 tags 机制差异同构）
            },
          ],
        },
        {
          'keyword': '毫不相关',
          'subjectId': 'endo',
          'subtopics': null,
          'notes': <String>[],
          'cards': <Map<String, Object?>>[
            {'id': 'endo-b-001', 'tags': <String>[]},
          ],
        },
      ];
      var calls = 0;
      final n = applyOutlineTags(kwres, (sid, kw, subs) {
        calls++;
        if (kw == '龋病的临床表现及诊断') {
          return ['大纲：龋病＞临床表现及诊断', '大纲：龋病＞概述', '大纲：龋病＞治疗',
              '大纲：龋病＞whatever4', '大纲：龋病＞whatever5'];
        }
        return const <String>[];
      });
      expect(n, 1, reason: '只 1 个关键词命中');
      expect(calls, 2, reason: '逐关键词都调 tagger（含未命中）');
      final c0 = (kwres[0]['cards'] as List).first as Map;
      final c0Tags = c0['tags'] as List;
      expect(c0Tags.first, '待补原文', reason: '既有标签保留在前');
      expect(
        c0Tags.whereType<String>().where((t) => t.startsWith('大纲：')).length,
        outline.kMaxOutlineTagsPerCard,
        reason: '每卡大纲标签 ≤3（tagger 给 5 也截 3）',
      );
      expect(c0Tags, contains('大纲：龋病＞临床表现及诊断'));
      final c1 = (kwres[0]['cards'] as List).last as Map;
      expect((c1['tags'] as List).length, 3);
      expect((kwres[0]['notes'] as List).single, '大纲细目打标：5 条');
      // 未命中关键词的卡不动
      final c2 = (kwres[1]['cards'] as List).first as Map;
      expect((c2['tags'] as List), isEmpty);
      expect(kwres[1]['notes'], isEmpty);
    });
  });
}
