// 节点⑨ 专项：科目章节总量识别全链路审计（场景 a–e）+ 章节管理
// GET/PUT /progress/<subject>/chapters 端到端（local 实装 + demo 演示态）。
//
// 审计链路（任务 A，结论=正常，证据=下列用例 + 真实数据只读探针
// D:\heng\.snow\node9_audit_probe.dart → node9-audit-probe.log）：
//   progress/progress.json（单一文件，非逐科目 *.json）→ progress_db
//   loadProgress 容错 → local_backend._progressView（routes/progress.dart
//   的 1:1 移植：total=chapters.length 原样含辅文章；next_chapter 9 项
//   精确过滤为 §7.5 拍板）→ api_client SubjectProgress（容错解析）→
//   progress_page Hero fold（hasTextbook 过滤）/ home_page compassFractionOf
//   同口径。
//
// 场景矩阵：
//   a) 正常科目；b) derm 占位（textbook=null）；c) med 占位（大纲入库
//   自动创建，applyChange 同路径生成）；d) -exam/-outline 语料树不污染
//   subjects/progress；e) 脏数据容错（learned>total / 字段类型错 /
//   条目非对象 / json 损坏）。
//
// 宿主基建同 local_backend_test：Windows 显式加载 test/sqlite3.dll。
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/api/demo_backend.dart';
import 'package:hengya/services/local/corpus/extract_pptx.dart'
    show splitSubjectSource;
import 'package:hengya/services/local/corpus/progress_db.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Windows 测试宿主：显式加载 test/sqlite3.dll（overrideForAll 全模式覆盖）
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
      () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }

  late Directory tmp;
  final be = LocalBackend.instance;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_node9_');
  });

  tearDown(() async {
    await LocalBackend.instance.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 用例体首行调用（体内事件循环由测试 runner 驱动，await 安全）
  Future<void> boot() async {
    await be.resetForTest();
    be.init(tmp.path);
  }

  Directory corpusDir() =>
      Directory('${tmp.path}/corpus')..createSync(recursive: true);

  String progressPath() => '${corpusDir().path}/progress.json';

  void writeProgress(Map<String, Object?> subjects) {
    File(progressPath()).writeAsStringSync(
      jsonEncode({'version': 1, 'subjects': subjects}),
    );
  }

  /// 正常科目：5 章含目录/前言/附录辅文章，指针 2
  Map<String, Object?> endoEntry({int learned = 2}) => {
        'textbook': '牙体牙髓病学-第5版',
        'chapters': [
          {'no': 1, 'title': '目录', 'page_start': 3},
          {'no': 2, 'title': '前言', 'page_start': 8},
          {'no': 3, 'title': '第一章 绪论', 'page_start': 14},
          {'no': 4, 'title': '第二章 龋病', 'page_start': 20},
          {'no': 5, 'title': '附录', 'page_start': 60},
        ],
        'learned_through': learned,
        'updated_at': '2026-09-05T14:07:01',
        'history': <Object?>[],
      };

  /// 无罗盘占位（derm 同款）
  Map<String, Object?> placeholderEntry() => {
        'textbook': null,
        'chapters': <Object?>[],
        'learned_through': 0,
        'updated_at': '2026-09-05T12:16:15',
        'history': <Object?>[
          {
            'date': '2026-09-05',
            'from': 0,
            'to': 0,
            'evidence': '--set 创建科目条目',
            'source': 'seed',
          },
        ],
      };

  Map<String, dynamic> subjectOf(Map<String, dynamic> view, String id) =>
      (view['subjects'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((s) => s['id'] == id);

  // ============================== 任务 A：审计场景 a–e ==============================

  test('审计 a) 正常科目：total=chapters 原样、learned=指针、next 跳辅文章', () async {
    await boot();
    writeProgress({'endo': endoEntry(learned: 2)});
    final view = await be.get('/progress');
    final subs = (view['subjects'] as List).cast<Map<String, dynamic>>();
    expect(subs.length, 1);
    final e = subs.first;
    expect(e['id'], 'endo');
    expect(e['textbook'], '牙体牙髓病学-第5版');
    expect(e['total'], 5, reason: '原样含目录/前言/附录辅文章（§7.9 拍板）');
    expect(e['learned_through'], 2);
    expect((e['next_chapter'] as Map)['no'], 3, reason: '目录/前言被 9 项集合过滤');
    expect((e['next_chapter'] as Map)['title'], '第一章 绪论');
    // App 端 fold 口径（progress_page Hero / home_page compassFractionOf）：
    // hasTextbook 科目求和——2/5 = 40%
    final learned = subs
        .where((s) => s['textbook'] != null)
        .fold<int>(0, (a, s) => a + (s['learned_through'] as int));
    final total = subs
        .where((s) => s['textbook'] != null)
        .fold<int>(0, (a, s) => a + (s['total'] as int));
    expect(learned, 2);
    expect(total, 5);
  });

  test('审计 b) derm 占位：textbook=null → total 0 / learned 0 / next null，不进 fold', () async {
    await boot();
    writeProgress({'endo': endoEntry(learned: 2), 'derm': placeholderEntry()});
    final view = await be.get('/progress');
    final derm = subjectOf(view, 'derm');
    expect(derm['textbook'], isNull);
    expect(derm['total'], 0, reason: 'chapters 空 → 防除零');
    expect(derm['learned_through'], 0);
    expect(derm['next_chapter'], isNull);
    // fold 口径：derm 被 hasTextbook 过滤——总量识别不受占位科目污染
    final compass = (view['subjects'] as List)
        .cast<Map<String, dynamic>>()
        .where((s) => s['textbook'] != null)
        .toList();
    expect(compass.length, 1);
    expect(compassTotal(compass), 5);
  });

  test('审计 c) med 占位（大纲入库自动创建路径）：与 derm 同款，不污染总量', () async {
    await boot();
    // 与 corpus_build_job.ensureMedSubjectPlaceholder 完全同路径生成
    final data = emptyProgress();
    final r = applyChange(
      data,
      'med',
      0,
      source: 'outline',
      allowCreate: true,
      createNote: '大纲入库自动创建占位科目（医学综合，无罗盘不参与复习提示）',
    );
    expect(r.ok, true);
    expect(r.mutated, true);
    writeProgress({
      ...(data['subjects'] as Map<String, Object?>),
      'endo': endoEntry(),
    });
    final view = await be.get('/progress');
    final med = subjectOf(view, 'med');
    expect(med['textbook'], isNull);
    expect(med['total'], 0);
    expect(med['learned_through'], 0);
    expect(med['next_chapter'], isNull);
    expect(
      (progressEntryOf(loadProgress(progressPath()), 'med')!['history']
              as List)
          .single['source'],
      'outline',
    );
    final compass = (view['subjects'] as List)
        .cast<Map<String, dynamic>>()
        .where((s) => s['textbook'] != null)
        .toList();
    expect(compass.length, 1, reason: '仅 endo 进罗盘口径');
  });

  test('审计 d) -exam/-outline 语料树不污染 subjects/progress', () async {
    await boot();
    // ① 源分类纯函数：-exam/-outline/-textbook/裸目录四态
    expect(splitSubjectSource('endo-exam'),
        (subject: 'endo', sourceType: 'exam'));
    expect(splitSubjectSource('dagang-outline'),
        (subject: 'dagang', sourceType: 'outline'));
    expect(splitSubjectSource('endo-textbook'),
        (subject: 'endo', sourceType: 'textbook'));
    expect(splitSubjectSource('endo'), (subject: 'endo', sourceType: 'ppt'));
    // ② 罗盘唯一数据源 = toc sidecar（仅 textbook 分支写：extractOneCorpusFile
    //    的 writeTocSidecar 门控 source=='textbook'）；exam/outline 树无 sidecar
    //    → initProgress 只见到 textbook sidecar → 罗盘只有 endo
    final toc = Directory('${corpusDir().path}/toc')..createSync(recursive: true);
    File('${toc.path}/endo.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'subject': 'endo',
      'textbook': '牙体牙髓病学-第5版',
      'chapters': [
        {'no': 1, 'title': '第一章 绪论', 'page_start': 1},
      ],
      'sections': <Object?>[],
    }));
    final data = emptyProgress();
    final r = initProgress(data, toc.path);
    expect(r.ok, true);
    expect(r.added, 1);
    expect((data['subjects'] as Map).keys.toList(), ['endo'],
        reason: '无 -exam/-outline/dagang/exam 键混入');
    // ③ 视图层同口径：/progress 的 subjects 来自 progress.json 原序，
    //    不读 subjects 表 / corpus.db——真题树与大纲树不可能经此通道进来
    writeProgress({'endo': endoEntry()});
    final view = await be.get('/progress');
    expect((view['subjects'] as List).length, 1);
    expect(subjectOf(view, 'endo')['total'], 5);
  });

  test('审计 e) 脏数据容错：learned>total / 字段类型错 / 条目非对象 / json 损坏', () async {
    await boot();
    writeProgress({
      'endo': {...endoEntry(learned: 99)}, // learned_through 99 > total 5
      'bad1': {
        'textbook': 'x',
        'learned_through': 'not-a-number', // 非整数 → 按 0
        'chapters': 'not-a-list', // 非 List → 按 []
      },
      'bad2': 'not-a-map', // 条目非对象 → 跳过不 500
    });
    final view = await be.get('/progress');
    final endo = subjectOf(view, 'endo');
    expect(endo['learned_through'], 99); // 原样透传（fraction 层 clamp 100%）
    expect(endo['next_chapter'], isNull, reason: '指针越过全部章 → 学完态');
    final bad1 = subjectOf(view, 'bad1');
    expect(bad1['learned_through'], 0);
    expect(bad1['total'], 0);
    expect(
      (view['subjects'] as List).where((s) => (s as Map)['id'] == 'bad2'),
      isEmpty,
      reason: '非对象条目被跳过',
    );
    // json 损坏 → 优雅空态（subjects: []，不抛）
    File(progressPath()).writeAsStringSync('{broken json');
    final broken = await be.get('/progress');
    expect((broken['subjects'] as List), isEmpty);
    expect(broken['updated_at'], isNull);
  });

  test('审计 e2) progress_db 侧脏数据：advance 对 learned>total 拒绝且不崩，sidecar 刷新自愈 clamp', () async {
    await boot();
    writeProgress({'endo': endoEntry(learned: 99)});
    final data = loadProgress(progressPath());
    // 超罗盘 / 倒退都被拒（不崩、不落盘）
    expect(applyChange(data, 'endo', 6).ok, false);
    expect(applyChange(data, 'endo', 3).ok, false);
    // sidecar 刷新：clamp 到新章数（#16 既有语义自愈）
    final toc = Directory('${corpusDir().path}/toc')..createSync(recursive: true);
    File('${toc.path}/endo.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'subject': 'endo',
      'textbook': '牙体牙髓病学-第5版',
      'chapters': [
        {'no': 1, 'title': '第一章 绪论', 'page_start': 1},
        {'no': 2, 'title': '第二章 龋病', 'page_start': 20},
      ],
      'sections': <Object?>[],
    }));
    final r = initFromTocSidecar(data, toc.path, 'endo');
    expect(r.ok, true);
    expect(progressEntryOf(data, 'endo')!['learned_through'], 2,
        reason: '99 clamp 到新章数 2');
  });

  // ============================== ⑨ 数据模型（progress_db 层） ==============================

  test('skippedChaptersOf：缺失/非 List/非 int/≤0 全容错', () {
    expect(skippedChaptersOf(null), isEmpty);
    expect(skippedChaptersOf({}), isEmpty);
    expect(skippedChaptersOf({'skipped': 'nope'}), isEmpty);
    expect(skippedChaptersOf({'skipped': [3, 'x', 0, -1, 5.5, 2]}), [3, 2],
        reason: '只透传合法 int（>0）；非 int/≤0 丢弃');
  });

  test('setSubjectChapters：推进/回退/校验/history 全矩阵', () {
    final data = progFixture();
    // 推进 2→3：history 落「章节管理推进」+ source manual
    var r = setSubjectChapters(data, 'endo', learnedThrough: 3);
    expect(r.ok, true);
    expect(r.mutated, true);
    expect(r.note, contains('推进'));
    var e = progressEntryOf(data, 'endo')!;
    expect(e['learned_through'], 3);
    final hist = e['history'] as List;
    expect(hist.length, 1);
    expect((hist.last as Map)['source'], 'manual');
    expect((hist.last as Map)['evidence'], '章节管理推进（第三章 近代变革）');
    // 回退 3→1：允许（UI 已确认语义），history 落「章节管理回退」
    r = setSubjectChapters(data, 'endo', learnedThrough: 1);
    expect(r.ok, true);
    expect(r.mutated, true);
    e = progressEntryOf(data, 'endo')!;
    expect(e['learned_through'], 1);
    expect(((e['history'] as List).last as Map)['evidence'],
        '章节管理回退（绪论）');
    // 超罗盘 / 负数拒绝
    expect(setSubjectChapters(data, 'endo', learnedThrough: 4).ok, false);
    expect(setSubjectChapters(data, 'endo', learnedThrough: -1).ok, false);
    // 原地：ok 未变
    r = setSubjectChapters(data, 'endo', learnedThrough: 1);
    expect(r.ok, true);
    expect(r.mutated, false);
    expect(r.note, '未变');
    // 未知科目拒绝（章节管理仅面向已有科目）
    expect(setSubjectChapters(data, 'nope', learnedThrough: 1).ok, false);
    // 无罗盘占位（nMax=0）仅接受 0
    final d2 = progFixture();
    (d2['subjects'] as Map)['derm'] = placeholderEntry();
    expect(setSubjectChapters(d2, 'derm', learnedThrough: 1).ok, false);
    expect(setSubjectChapters(d2, 'derm', learnedThrough: 0).ok, true);
  });

  test('setSubjectChapters：skipped 全量替换/规范化/清空移除字段；跳过切换不落 history', () {
    final data = progFixture();
    // 标记 [2,2,9] → 规范化为 [2]（去重、越界 9>3 丢弃；非 int 容错见
    // skippedChaptersOf 用例——类型层就进不来）
    var r = setSubjectChapters(data, 'endo', skipped: [2, 2, 9]);
    expect(r.ok, true);
    expect(progressEntryOf(data, 'endo')!['skipped'], [2]);
    expect((progressEntryOf(data, 'endo')!['history'] as List), isEmpty,
        reason: '跳过切换不伪造 from==to 历史行');
    // learnedThrough 与 skipped 同请求：单次变更
    r = setSubjectChapters(data, 'endo', learnedThrough: 3, skipped: [1, 2]);
    expect(r.ok, true);
    expect(progressEntryOf(data, 'endo')!['skipped'], [1, 2]);
    expect((progressEntryOf(data, 'endo')!['history'] as List).length, 1);
    // 清空 → 字段移除（旧格式零残留）
    r = setSubjectChapters(data, 'endo', skipped: []);
    expect(r.mutated, true);
    expect(progressEntryOf(data, 'endo')!.containsKey('skipped'), false);
    // skipped=null → 不动该字段
    setSubjectChapters(data, 'endo', skipped: [3]);
    setSubjectChapters(data, 'endo', learnedThrough: 2);
    expect(progressEntryOf(data, 'endo')!['skipped'], [3],
        reason: 'learnedThrough-only 请求不碰 skipped');
    // 落盘往返：旧格式（无 skipped 字段）load 正常、新格式 round-trip 保真
    final rtDir = Directory.systemTemp.createTempSync('node9_rt_');
    addTearDown(() {
      try {
        rtDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final path = '${rtDir.path}/p.json';
    final d3 = progFixture();
    setSubjectChapters(d3, 'endo', learnedThrough: 3, skipped: [1]);
    saveProgress(path, d3);
    final back = loadProgress(path);
    final e3 = progressEntryOf(back, 'endo')!;
    expect(e3['learned_through'], 3);
    expect(e3['skipped'], [1]);
    expect((e3['history'] as List).last['source'], 'manual');
    // 未知键保留（Python 端读改写不丢字段）
    (d3['subjects'] as Map)['unknown'] = {'whatever': 1};
    saveProgress(path, d3);
    expect((loadProgress(path)['subjects'] as Map).containsKey('unknown'), true);
  });

  test('weeklyChapters：跳过章视同未学，不出周扫真题池', () {
    final data = progFixture();
    // learned 2：绪论 + 第二章（fixture 无辅文章，双双入池）
    var rows = weeklyChapters(data);
    expect(rows.map((r) => r['chapter']).toList(),
        containsAll(['绪论', '第二章 口腔检查']));
    // 标记第二章 不学 → 周扫池剔除该章（第一章照出）
    setSubjectChapters(data, 'endo', skipped: [2]);
    rows = weeklyChapters(data);
    expect(rows.map((r) => r['chapter']).toList(), ['绪论'],
        reason: '跳过章=未学，不出真题卡');
    // 恢复 → 回池
    setSubjectChapters(data, 'endo', skipped: []);
    rows = weeklyChapters(data);
    expect(rows.length, 2);
  });

  // ============================== ⑨ 端点（local 实装） ==============================

  test('GET /progress/<subject>/chapters：全章状态 + 原始指针 + 有效统计 + 404', () async {
    await boot();
    writeProgress({'endo': endoEntry(learned: 2)});
    final v = await be.get('/progress/endo/chapters');
    expect(v['id'], 'endo');
    expect(v['learned_through'], 2, reason: '原始前缀指针（PUT 直接吃同一语义）');
    expect(v['total'], 5);
    expect(v['effective_total'], 5);
    expect(v['effective_learned'], 2);
    expect(v['skipped'], isEmpty);
    expect((v['next_chapter'] as Map)['no'], 3);
    final rows = (v['chapters'] as List).cast<Map<String, dynamic>>();
    expect(rows.length, 5);
    expect(rows[0]['learned'], true); // 目录（no=1 ≤ 指针 2）
    expect(rows[1]['learned'], true);
    expect(rows[2]['learned'], false);
    expect(rows[4]['skipped'], false);
    // 未知科目 → 404
    await expectLater(
      be.get('/progress/nope/chapters'),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
    // 无罗盘占位：空章列表照常可读（弹层显示空态而非 404）
    writeProgress({'endo': endoEntry(), 'derm': placeholderEntry()});
    final d = await be.get('/progress/derm/chapters');
    expect(d['total'], 0);
    expect(d['chapters'], isEmpty);
    expect(d['textbook'], isNull);
  });

  test('PUT 推进/回退：落盘 + history + 主 /progress 视图联动', () async {
    await boot();
    writeProgress({'endo': endoEntry(learned: 2)});
    // 推进到 4
    var r = await be.put('/progress/endo/chapters', {'learned_through': 4});
    expect(r['ok'], true);
    expect(r['learned_through'], 4);
    expect(r['note'], contains('推进'));
    var e = progressEntryOf(loadProgress(progressPath()), 'endo')!;
    expect(e['learned_through'], 4);
    expect(((e['history'] as List).single as Map)['source'], 'manual');
    // 主视图联动：no5 是精确「附录」→ 被 9 项集合过滤 → next null
    var view = await be.get('/progress');
    expect(subjectOf(view, 'endo')['learned_through'], 4);
    expect(subjectOf(view, 'endo')['next_chapter'], isNull);
    // 回退到 1：端点允许（确认在 UI 层），history 追加回退行
    r = await be.put('/progress/endo/chapters', {'learned_through': 1});
    expect(r['ok'], true);
    expect(r['learned_through'], 1);
    e = progressEntryOf(loadProgress(progressPath()), 'endo')!;
    expect(e['learned_through'], 1);
    expect((e['history'] as List).length, 2);
    expect(((e['history'] as List).last as Map)['evidence'],
        '章节管理回退（目录）');
  });

  test('PUT skipped：有效总量/下一章剔除跳过章；清空恢复', () async {
    await boot();
    writeProgress({'endo': endoEntry(learned: 2)});
    // 标记 no=3（下一章）不学 → next 跳到 4，有效总量 4
    var r = await be.put('/progress/endo/chapters', {'skipped': [3]});
    expect(r['ok'], true);
    expect(r['skipped'], [3]);
    expect(r['effective_total'], 4);
    expect(r['effective_learned'], 2);
    expect((r['next_chapter'] as Map)['no'], 4, reason: '「下一章」越过不学章');
    var view = await be.get('/progress');
    var e = subjectOf(view, 'endo');
    expect(e['total'], 4, reason: '主视图有效总量 = 原 total − 跳过数');
    expect(e['learned_through'], 2);
    expect((e['next_chapter'] as Map)['no'], 4);
    // GET 章节视图：no=3 行 skipped=true
    var v = await be.get('/progress/endo/chapters');
    expect(((v['chapters'] as List)[2] as Map)['skipped'], true);
    // 再标记指针下方的 no=1（目录）→ 有效已学 2-1=1
    r = await be.put('/progress/endo/chapters', {'skipped': [1, 3]});
    expect(r['effective_learned'], 1);
    view = await be.get('/progress');
    e = subjectOf(view, 'endo');
    expect(e['learned_through'], 1);
    expect(e['total'], 3);
    // 清空恢复：字段移除、值回原
    r = await be.put('/progress/endo/chapters', {'skipped': []});
    expect(r['ok'], true);
    expect(r['effective_total'], 5);
    expect(
      progressEntryOf(loadProgress(progressPath()), 'endo')!
          .containsKey('skipped'),
      false,
    );
    view = await be.get('/progress');
    expect(subjectOf(view, 'endo')['total'], 5);
    expect((subjectOf(view, 'endo')['next_chapter'] as Map)['no'], 3);
  });

  test('PUT 与流水线共存：读-改-写不丢对方字段（双向）', () async {
    await boot();
    writeProgress({'endo': endoEntry(learned: 2)});
    // ① 流水线先推进（study-log 三重保险链的落盘路径：applyChange + save）
    final data = loadProgress(progressPath());
    final adv = applyChange(data, 'endo', 3,
        source: 'auto', evidence: '第一章 绪论');
    expect(adv.mutated, true);
    saveProgress(progressPath(), data);
    // ② 章节管理只带 skipped → 指针 3 保留 + skipped 落盘（不丢流水线刚写的）
    var r = await be.put('/progress/endo/chapters', {'skipped': [3]});
    expect(r['ok'], true);
    var e = progressEntryOf(loadProgress(progressPath()), 'endo')!;
    expect(e['learned_through'], 3);
    expect(e['skipped'], [3]);
    expect((e['history'] as List).length, 1, reason: '跳过切换不加 history 行');
    // ③ 章节管理先标 skipped，流水线后推进 → skipped 保留（读-改-写全量）
    writeProgress({'endo': endoEntry(learned: 2)});
    await be.put('/progress/endo/chapters', {'skipped': [5]});
    final data2 = loadProgress(progressPath());
    applyChange(data2, 'endo', 4, source: 'auto', evidence: '第二章 龋病');
    saveProgress(progressPath(), data2);
    e = progressEntryOf(loadProgress(progressPath()), 'endo')!;
    expect(e['learned_through'], 4);
    expect(e['skipped'], [5]);
  });

  test('PUT 校验与幂等：超罗盘/负数/类型错 → 400；未知科目 → 404；同值不动盘', () async {
    await boot();
    writeProgress({'endo': endoEntry(learned: 2)});
    Future<void> expect400(Object body) => expectLater(
          be.put('/progress/endo/chapters', body),
          throwsA(
            isA<ApiException>().having((e) => e.statusCode, 'statusCode', 400),
          ),
        );
    await expect400({'learned_through': 6}); // 超罗盘
    await expect400({'learned_through': -1}); // 负数
    await expect400({'learned_through': 'x'}); // 非整数
    await expect400({'skipped': 'x'}); // 非列表
    await expectLater(
      be.put('/progress/nope/chapters', {'learned_through': 1}),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
    // 幂等：同值 PUT → ok + 未变 + 盘上文件逐字节不动
    final before = File(progressPath()).readAsStringSync();
    final r = await be.put('/progress/endo/chapters', {'learned_through': 2});
    expect(r['ok'], true);
    expect(r['note'], '未变');
    expect(File(progressPath()).readAsStringSync(), before);
  });

  // ============================== ⑨ demo 演示行为 ==============================

  test('demo：GET 章节底表与 /progress 硬编码初值逐字段一致；PUT 后联动', () async {
    final demo = DemoBackend.instance;
    // 初始（未 PUT）：/progress 硬编码块原样
    var p0 = await demo.get('/progress');
    var hist0 = (p0['subjects'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['id'] == 'hist');
    expect(hist0['learned_through'], 4);
    expect(hist0['total'], 23);
    // GET 章节视图：底表 + 初值（与硬编码块一致）
    var v = await demo.get('/progress/hist/chapters');
    expect(v['learned_through'], 4);
    expect(v['total'], 23);
    expect(v['skipped'], isEmpty);
    expect((v['next_chapter'] as Map)['title'], '第三章 资本主义的兴起');
    expect((v['next_chapter'] as Map)['page'], 51);
    expect((v['chapters'] as List).length, 23);
    // PUT 推进到 10 + 跳过 no=22（索引）
    var r = await demo.put('/progress/hist/chapters', {
      'learned_through': 10,
      'skipped': [22],
    });
    expect(r['ok'], true);
    expect(r['learned_through'], 10);
    expect(r['effective_total'], 22);
    expect((r['next_chapter'] as Map)['no'], 11);
    // 主 /progress 联动（有效口径）
    p0 = await demo.get('/progress');
    hist0 = (p0['subjects'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['id'] == 'hist');
    expect(hist0['learned_through'], 10);
    expect(hist0['total'], 22);
    expect((hist0['next_chapter'] as Map)['no'], 11);
    // 其余科目不受影响（geo 硬编码原样）
    final geo = (p0['subjects'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['id'] == 'geo');
    expect(geo['total'], 13);
    // 回退 + 恢复跳过
    r = await demo.put('/progress/hist/chapters', {
      'learned_through': 4,
      'skipped': [],
    });
    expect(r['learned_through'], 4);
    expect(r['effective_total'], 23);
    // 404 / 400
    await expectLater(
      demo.get('/progress/nope/chapters'),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
    await expectLater(
      demo.put('/progress/hist/chapters', {'learned_through': 24}),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 400),
      ),
    );
  });
}

/// fold 辅助（复刻 progress_page Hero 口径）
int compassTotal(List<Map<String, dynamic>> compass) =>
    compass.fold<int>(0, (a, s) => a + (s['total'] as int));

/// ≈progress_db_test.progFixture（endo learned_through=2、3 章）
Map<String, Object?> progFixture() => {
      'version': 1,
      'subjects': <String, Object?>{
        'endo': {
          'textbook': '世界通史-第2版',
          'chapters': [
            {'no': 1, 'title': '绪论', 'page_start': 1},
            {'no': 2, 'title': '第二章 口腔检查', 'page_start': 8},
            {'no': 3, 'title': '第三章 近代变革', 'page_start': 20},
          ],
          'learned_through': 2,
          'updated_at': '2026-09-05T00:00:00',
          'history': <Object?>[],
        },
      },
    };
