// 恒牙（hengya）· progress_db 罗盘推进刀测试（progress_db.dart 对拍硬门）
// ============================================================================
//
// Python 金标准：
//   - automation/server-pipeline/progress_db.py --self-test（init 保留/重建、
//     set 单调、advance 三级映射、derm 占位、中文数字解析）
//   - automation/server-pipeline/run.py --self-test 第 15 组（study-log 三重
//     保险 + dry-run + trustworthy 收紧校验六态，全离线 monkeypatch 检索/
//     推进/LLM）
//
// 覆盖：
//   A. progress.json 读写：往返保真（未知顶层键/科目键保留、数字 int 保真）、
//      缺失/损坏/结构非法 → 空库、推进后其他科目原样。
//   B. initProgress：建/刷新/force 清零清史/占位科目保留/chapters 收口
//      （最大 no——effectiveTocChapters 稀疏编号）/坏目录（Python self-test --init 段对拍）。
//   C. findChapterNo：三级策略（章名包含·最长优先·尾缀容错/第X章 token/
//      无法定位）。
//   D. applyChange/setSubjectNo：单调纪律矩阵（推进+history 落盘/seed 来源/
//      倒退/超罗盘/原地 no-op/负数/无罗盘占位/未知科目）。
//   E. progressAdvance：--from-title 核心（保险②定位不到不落盘/保险③倒退
//      拒绝/未知科目）。
//   F. advanceFromTitle（seam 注入）：三重保险全矩阵（前置无科目不检索/
//      保险① floor 未命中/dry-run wouldAdvance/命中推进/保险②/保险③/
//      检索故障降级/trustworthy 开关/检索限定 textbook+k=3）。
//   G. studyLogAdvance：逐 ref 推进 + 倒退 ref 不落盘 + advancedCount。
//   H. compassLocate：当前章名检索/显示名回退/无科目跳过/dry-run。
//   I. trustworthy 六态（跨文件复用确认，本体详测在 run_engine_test）。
//   J. 装配器：progressEntryOf 直连原始 Map/weeklyChapters 正文过滤/
//      subjectDisplayName 三层/legalSubjects 并集/compassSummary/
//      weeklyChapters→runWeekly 协同冒烟（run_engine 留缝闭环）。
//   K. #16 initFromTocSidecar（逐科目建/刷新保留进度/缺失·损坏不动库）+
//      tocSidecarSubjects 清单 + sidecar init → studyLogAdvance 推进端到端
//      （罗盘初始化接线的前置能力：init 后推进链可用，未命中带 note）。
import 'dart:convert';
import 'dart:io';

import 'package:hengya/services/local/corpus/progress_db.dart';
import 'package:hengya/services/local/corpus/run_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// ≈run.py self_test 15c 的 prog15（endo learned_through=2、3 章），
/// 补齐生产同构字段（textbook/updated_at/history——applyChange 真写路径）。
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

/// ≈run.py self_test 15c 的 _fake_search L2232（脚本化检索，零真实网络）。
///
/// 调用方从 [calls] 断言检索限定（source_type=textbook、subject、k=3）。
({Future<Map<String, Object?>> Function(String, {String? subject, String? sourceType, int? k}) fn,
    List<Map<String, Object?>> calls})
    fakeCompassSearch() {
  final calls = <Map<String, Object?>>[];
  Future<Map<String, Object?>> fake(
    String query, {
    String? subject,
    String? sourceType,
    int? k,
  }) async {
    calls.add({'q': query, 'subject': subject, 'type': sourceType, 'k': k});
    if (query == '未命中章') {
      return {
        'results': [
          {'score': 0.29, 'title': '低分'}
        ]
      };
    }
    if (query == '故障章') {
      throw const SearchException('模拟 corpus 故障');
    }
    if (query == '定位不到章') {
      return {
        'results': [
          {'score': 0.90, 'title': '定位不到章序·索引'}
        ]
      };
    }
    if (query == '第三章') {
      // smoke 实测形态：报「第三章」词面误命中跨层大块
      return {
        'results': [
          {'score': 0.90, 'title': '第四篇 口腔检查与术区隔离·第二十九章 世界通史实习教程'}
        ]
      };
    }
    if (query == '第二章 口腔检查') {
      return {
        'results': [
          {'score': 0.90, 'title': '第二章 口腔检查·方法'}
        ]
      };
    }
    return {
      'results': [
        {'score': 0.90, 'title': '第三章 近代变革·概述'}
      ]
    };
  }

  return (fn: fake, calls: calls);
}

Map<String, Object?> endoOf(Map<String, Object?> data) =>
    (data['subjects'] as Map)['endo'] as Map<String, Object?>;

void main() {
  // ------------------------------------------------ A. progress.json 读写 ----

  test('loadProgress/saveProgress：往返保真 + 未知键/科目保留 + 坏文件空库', () {
    final tmp = Directory.systemTemp.createTempSync('hengya-progdb-test-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final path = '${tmp.path}${Platform.pathSeparator}progress.json';

    // 缺失 → 空库（≈load_progress L125）
    expect(loadProgress(path), emptyProgress());
    // 坏 JSON → 空库
    File(path).writeAsStringSync('not-json{{{');
    expect(loadProgress(path), emptyProgress());
    // 顶层非对象 → 空库
    File(path).writeAsStringSync('[1,2]');
    expect(loadProgress(path), emptyProgress());
    // subjects 非对象 → 空库
    File(path).writeAsStringSync('{"version":1,"subjects":[]}');
    expect(loadProgress(path)['subjects'], isEmpty);

    // 往返保真：未知顶层键/未知科目键（含未知子字段）/derm 占位/数字 int 保真
    final data = {
      'version': 1,
      'future_top_key': {'a': 1},
      'subjects': {
        'endo': {
          'textbook': '世界通史-第2版',
          'chapters': [
            {'no': 1, 'title': '目录', 'page_start': 3},
            {'no': 2, 'title': '绪论', 'page_start': 5},
            {'no': 3, 'title': '第一篇 龋病学', 'page_start': 9},
          ],
          'learned_through': 2,
          'updated_at': '2026-09-05T14:07:01',
          'history': [
            {'date': '2026-09-05', 'from': 0, 'to': 2, 'evidence': '', 'source': 'seed'}
          ],
        },
        'derm': {
          'textbook': null,
          'chapters': <Object?>[],
          'learned_through': 0,
          'updated_at': '2026-09-05T14:07:01',
          'history': <Object?>[],
        },
        'ortho': {
          // 未知科目带本库不认识的字段——写回时必须原样保留
          'textbook': '口腔正畸学-第8版',
          'unknown_field': '未来版本新增',
          'learned_through': 3,
        },
      },
    };
    saveProgress(path, data);
    final back = loadProgress(path);
    expect(back['version'], 1);
    expect(back['future_top_key'], {'a': 1});
    final subs = back['subjects'] as Map;
    expect(subs.keys.toList(), ['endo', 'derm', 'ortho']);
    expect(subs['endo'], equals((data['subjects'] as Map)['endo']));
    expect(subs['derm'], equals((data['subjects'] as Map)['derm']));
    expect((subs['ortho'] as Map)['unknown_field'], '未来版本新增');
    // 数字 int 保真（不出 4.0 之类浮点漂移）
    expect((subs['endo'] as Map)['learned_through'], isA<int>());
    expect((subs['endo'] as Map)['learned_through'], 2);
    expect(((subs['endo'] as Map)['chapters'] as List).first is Map, true);

    // 推进 endo 后落盘 → 未知顶层键/其他科目原样不动（写时保留口径）
    setSubjectNo(back, 'endo', 3);
    saveProgress(path, back);
    final back2 = loadProgress(path);
    final subs2 = back2['subjects'] as Map;
    expect((subs2['endo'] as Map)['learned_through'], 3);
    expect(back2['future_top_key'], {'a': 1});
    expect(subs2['derm'], equals((data['subjects'] as Map)['derm']));
    expect((subs2['ortho'] as Map)['unknown_field'], '未来版本新增');
    // history 追加且保留旧条目
    final hist = (subs2['endo'] as Map)['history'] as List;
    expect(hist.length, 2);
    expect((hist.first as Map)['source'], 'seed');
    expect((hist.last as Map)['source'], 'manual');
  });

  // --------------------------------------------------------- B. init ----

  test('initProgress：建/刷新/force 清零清史/占位保留/chapters clamp/坏目录', () {
    final tmp = Directory.systemTemp.createTempSync('hengya-progdb-init-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final toc = Directory('${tmp.path}${Platform.pathSeparator}toc')
      ..createSync();
    Map<String, Object?> sidecar(String subject, String textbook,
            List<Map<String, Object?>> chapters) =>
        {
          'version': 1,
          'subject': subject,
          'textbook': textbook,
          'chapters': chapters,
          'sections': <Object?>[],
        };
    // flat 书同构形态：目录是辅文垃圾，绪论/第X章是正文——init 经
    // effectiveTocChapters 过滤后「目录」被剔、幸存条目保留原 no（稀疏）。
    final endoChapters = [
      {'no': 1, 'title': '目录', 'page_start': 3},
      {'no': 2, 'title': '绪论', 'page_start': 5},
      {'no': 3, 'title': '第一章 龋病学', 'page_start': 9},
      {'no': 4, 'title': '第二章 大航海时代', 'page_start': 30},
    ];
    File('${toc.path}${Platform.pathSeparator}endo.json')
        .writeAsStringSync(jsonEncode(
            sidecar('endo', '世界通史-测试版', endoChapters)));
    File('${toc.path}${Platform.pathSeparator}oms.json').writeAsStringSync(
        jsonEncode(sidecar('oms', '口腔颌面外科学-测试版', [
          {'no': 1, 'title': '目录', 'page_start': 3},
          {'no': 2, 'title': '第一章 绪论', 'page_start': 5},
          {'no': 3, 'title': '第二章 麻醉', 'page_start': 8},
          {'no': 4, 'title': '第三章 感染', 'page_start': 20},
        ])));

    // --init：两科目建立、全 0（Python self_test「init 退出码/科目数/全 0/章数复制」）
    final data = emptyProgress();
    final r1 = initProgress(data, toc.path);
    expect(r1.ok, true, reason: r1.note);
    expect(r1.added, 2);
    expect(r1.refreshed, 0);
    final subs = data['subjects'] as Map;
    expect(subs.keys.toList(), ['endo', 'oms']);
    expect((subs['endo'] as Map)['learned_through'], 0);
    final endoCh = ((subs['endo'] as Map)['chapters'] as List)
        .cast<Map<String, Object?>>();
    expect(endoCh.length, 3, reason: '辅文「目录」被 effectiveTocChapters 剔除');
    expect(endoCh.map((c) => c['no']).toList(), [2, 3, 4],
        reason: '幸存条目保留原 no（稀疏编号，不重编）');
    expect((subs['endo'] as Map)['textbook'], '世界通史-测试版');
    expect((subs['oms'] as Map)['history'], isEmpty);

    // set endo 3（seed 段在 D 组详测）+ derm 占位 → 重 init：保留进度与历史
    setSubjectNo(data, 'endo', 3);
    setSubjectNo(data, 'oms', 2, source: 'seed');
    setSubjectNo(data, 'derm', 0, source: 'seed');
    final r2 = initProgress(data, toc.path);
    expect(r2.ok, true);
    expect(r2.added, 0);
    expect(r2.refreshed, 2);
    expect((subs['endo'] as Map)['learned_through'], 3); // 保留进度
    expect(((subs['oms'] as Map)['history'] as List).length, 1); // 保留历史
    expect(subs.containsKey('derm'), true); // 不在 sidecar 的占位科目保留
    expect((subs['derm'] as Map)['textbook'], null);

    // chapters 收口：endo 已学 3，sidecar 变 2 章（目录+绪论）重 init →
    // 过滤后幸存 [绪论]（no=2，稀疏）→ 按最大 no 收口 2（非按条目数 1）
    File('${toc.path}${Platform.pathSeparator}endo.json').writeAsStringSync(
        jsonEncode(sidecar('endo', '世界通史-测试版', endoChapters.take(2).toList())));
    initProgress(data, toc.path);
    expect((subs['endo'] as Map)['learned_through'], 2);
    // sidecar 还原 4 章再 init → 进度不回缩（2 < 4 保持 2）
    File('${toc.path}${Platform.pathSeparator}endo.json')
        .writeAsStringSync(jsonEncode(sidecar('endo', '世界通史-测试版', endoChapters)));
    initProgress(data, toc.path);
    expect((subs['endo'] as Map)['learned_through'], 2);

    // --force：全量重建清零清史；derm 占位保留（不来自 sidecar）
    final r3 = initProgress(data, toc.path, force: true);
    expect(r3.added, 2);
    expect((subs['endo'] as Map)['learned_through'], 0);
    expect((subs['endo'] as Map)['history'], isEmpty);
    expect((subs['endo'] as Map)['updated_at'], isNotEmpty);
    expect(subs.containsKey('derm'), true);

    // 坏目录/空目录/结构异常 → ok=false（Python self_test exit 2 口径）
    expect(initProgress(emptyProgress(), '${tmp.path}${Platform.pathSeparator}nope').ok, false);
    final emptyDir = Directory('${tmp.path}${Platform.pathSeparator}empty')
      ..createSync();
    expect(initProgress(emptyProgress(), emptyDir.path).ok, false);
    File('${toc.path}${Platform.pathSeparator}bad.json')
        .writeAsStringSync('{"nope": 1}');
    expect(initProgress(emptyProgress(), toc.path).ok, false);
    File('${toc.path}${Platform.pathSeparator}bad.json').deleteSync();
  });

  // ------------------------------------------------------- C. 定位 ----

  test('findChapterNo：三级策略（章名包含·最长优先·尾缀容错/token/无法定位）', () {
    final entry = {
      'chapters': [
        {'no': 1, 'title': '目录', 'page_start': 3},
        {'no': 2, 'title': '第一章 绪论 / 1', 'page_start': 11},
        {'no': 3, 'title': '第二章 口腔检查与治疗', 'page_start': 20},
      ],
    };
    // 策略①：章标题（含「 / 1」页码尾缀）包含于命中 title（Python self_test
    // 「章名尾缀容错命中」锚点：title='第一章 绪论·概述' → no=2）
    expect(findChapterNo(entry, '第一章 绪论·概述'), 2);
    // 最长标题优先：命中同时含「第二章」与「第二章 口腔检查与治疗」取后者
    expect(findChapterNo(entry, '第二章 口腔检查与治疗·概述'), 3);
    // 策略②：第X章 token（章名未包含于命中 title 时兜底）
    expect(findChapterNo(entry, '第二章 麻醉·局麻药物'), 3);
    // 无法定位 → null（保险②入口）
    expect(findChapterNo(entry, '不相关的标题'), isNull);
    expect(findChapterNo(entry, ''), isNull);
    expect(findChapterNo(entry, null), isNull);
    expect(findChapterNo(null, '第一章 绪论'), isNull);
    // 策略①③同长保首 + no=0 非法章序继续走策略②（Python `if best_no:` 口径）
    final weird = {
      'chapters': [
        {'no': 0, 'title': '绪论'}, // no=0 非法——不应命中策略①
        {'no': 5, 'title': '第一章 绪论'},
      ],
    };
    expect(findChapterNo(weird, '第一章 绪论·概述'), 5);
  });

  // --------------------------------------------------- D. 单调纪律 ----

  test('applyChange/setSubjectNo：单调纪律矩阵（Python self_test --set 段对拍）', () {
    final data = emptyProgress();
    (data['subjects'] as Map)['endo'] = {
      'textbook': '世界通史-测试版',
      'chapters': [
        {'no': 1, 'title': '目录', 'page_start': 3},
        {'no': 2, 'title': '绪论', 'page_start': 5},
        {'no': 3, 'title': '第一篇 龋病学', 'page_start': 9},
        {'no': 4, 'title': '第二篇 大航海时代', 'page_start': 30},
      ],
      'learned_through': 0,
      'updated_at': '2026-09-05T00:00:00',
      'history': <Object?>[],
    };
    // set 3：推进 + history 落盘 + updated_at 刷新 + note 形态
    final r1 = setSubjectNo(data, 'endo', 3);
    expect(r1.ok, true);
    expect(r1.mutated, true);
    expect(r1.note, contains('endo：0 → 3'));
    final endo = (data['subjects'] as Map)['endo'] as Map;
    expect(endo['learned_through'], 3);
    final hist = endo['history'] as List;
    expect(hist.length, 1);
    expect(hist.last, {
      'date': todayIso(),
      'from': 0,
      'to': 3,
      'evidence': '',
      'source': 'manual',
    });
    expect(endo['updated_at'], isNot('2026-09-05T00:00:00'));
    // seed 来源
    setSubjectNo(data, 'endo', 4, source: 'seed');
    expect(
        (((data['subjects'] as Map)['endo'] as Map)['history'] as List)
            .last,
        predicate<Map>((h) => h['source'] == 'seed'));
    // 倒退 → 拒绝（保险③；Python「set 倒退 exit 2」）
    final r2 = setSubjectNo(data, 'endo', 1);
    expect(r2.ok, false);
    expect(r2.note, contains('倒退'));
    // 超罗盘 → 拒绝
    final r3 = setSubjectNo(data, 'endo', 99);
    expect(r3.ok, false);
    expect(r3.note, contains('超出罗盘'));
    // 原地 no-op：ok=true（Python rc=0）但未变更
    final r4 = setSubjectNo(data, 'endo', 4);
    expect(r4.ok, true);
    expect(r4.mutated, false);
    expect(r4.note, '未变（4）');
    // 负数 → 拒绝
    final r5 = applyChange(data, 'endo', -1);
    expect(r5.ok, false);
    expect(r5.note, contains('不能为负'));
    // derm 无罗盘占位：set 0 --source seed 创建 textbook=null；set 1 → 拒绝
    final r6 = setSubjectNo(data, 'derm', 0, source: 'seed');
    expect(r6.ok, true);
    final derm = (data['subjects'] as Map)['derm'] as Map;
    expect(derm['textbook'], null);
    expect(derm['learned_through'], 0);
    expect((derm['history'] as List).last,
        predicate<Map>((h) => h['source'] == 'seed' && h['to'] == 0));
    final r7 = setSubjectNo(data, 'derm', 1);
    expect(r7.ok, false);
    expect(r7.note, contains('仅接受 0'));
    // 未知科目 allowCreate=false → 拒绝
    final r8 = applyChange(data, 'nobody', 1);
    expect(r8.ok, false);
    expect(r8.note, contains('不在进度库'));
  });

  // ------------------------------------------- E. progressAdvance 核心 ----

  test('progressAdvance：--from-title 定位推进/保险②不落盘/保险③倒退/未知科目', () {
    // 命中 title 定位 → 推进 2→3 + history source=auto evidence=命中标题
    final data = progFixture();
    final r1 = progressAdvance(data, 'endo', '第三章 近代变革·概述');
    expect(r1.ok, true);
    expect(r1.toNo, 3);
    expect(r1.mutated, true);
    final endo = endoOf(data);
    expect(endo['learned_through'], 3);
    final hist = endo['history'] as List;
    expect(hist.last, {
      'date': todayIso(),
      'from': 2,
      'to': 3,
      'evidence': '第三章 近代变革·概述',
      'source': 'auto',
    });

    // 保险②：命中但定位不到章序 → 不落盘（Python exit 2，subjects 完全未动）
    final data2 = progFixture();
    final before = jsonEncode(data2['subjects']);
    final r2 = progressAdvance(data2, 'endo', '定位不到章序·索引');
    expect(r2.ok, false);
    expect(r2.note, contains('无法从 title 定位章节'));
    expect(jsonEncode(data2['subjects']), before);

    // 保险③：倒退拒绝（已学 3 → 命中第二章块）
    final data3 = progFixture();
    progressAdvance(data3, 'endo', '第三章 近代变革·概述');
    final r3 = progressAdvance(data3, 'endo', '第二章 口腔检查');
    expect(r3.ok, false);
    expect(r3.note, contains('倒退'));
    expect((endoOf(data3))['learned_through'], 3);

    // 未知科目 → 拒绝
    final r4 = progressAdvance(progFixture(), 'nobody', '第三章');
    expect(r4.ok, false);
    expect(r4.note, contains('不在进度库'));
  });

  // --------------------------------- F. advanceFromTitle 三重保险矩阵 ----

  test('advanceFromTitle：三重保险全矩阵（Python self_test 15c/15d 对拍）', () async {
    final f = fakeCompassSearch();
    const opts = RunOptions(); // floor 0.30、非 dry-run

    // 保险前置：进度库无科目 → 不检索不推进不阻断（run.py L1229）
    final r0 = await advanceFromTitle(
        runSearch: f.fn,
        subjectId: 'oms',
        query: '第三章',
        progressData: progFixture(),
        opts: opts);
    expect(r0['ok'], false);
    expect((r0['note'] as String), contains('进度库无该科目'));
    expect(f.calls, isEmpty); // 未检索（Python「进度库无科目不检索」）

    // 保险①：floor 0.30 未命中（0.29）→ 不推进、不调推进（数据未动）
    final d1 = progFixture();
    final r1 = await advanceFromTitle(
        runSearch: f.fn,
        subjectId: 'endo',
        query: '未命中章',
        progressData: d1,
        opts: opts);
    expect(r1['ok'], false);
    expect((r1['note'] as String), contains('教材未命中'));
    expect((r1['note'] as String), contains('0.30'));
    expect(endoOf(d1)['learned_through'], 2);
    expect(endoOf(d1)['history'] as List, isEmpty);

    // dry-run：命中也只记 wouldAdvance，不真推进
    final d2 = progFixture();
    final r2 = await advanceFromTitle(
        runSearch: f.fn,
        subjectId: 'endo',
        query: '第三章 近代变革',
        progressData: d2,
        opts: const RunOptions(dryRun: true));
    expect(r2['ok'], false);
    expect(r2['wouldAdvance'], '第三章 近代变革·概述');
    expect((r2['note'] as String), contains('dry-run'));
    expect(endoOf(d2)['learned_through'], 2);

    // 非 dry-run 命中 → 真推进（advanced=true；history evidence=命中标题）
    final d3 = progFixture();
    final r3 = await advanceFromTitle(
        runSearch: f.fn,
        subjectId: 'endo',
        query: '第三章 近代变革',
        progressData: d3,
        opts: opts);
    expect(r3['ok'], true);
    expect(r3['advanced'], true);
    expect(r3['hit'], '第三章 近代变革·概述');
    expect(r3['toNo'], 3);
    expect(endoOf(d3)['learned_through'], 3);
    expect((endoOf(d3)['history'] as List).last,
        predicate<Map>((h) => h['evidence'] == '第三章 近代变革·概述'));

    // 保险②：命中但定位不到章序 → advanced=false 不落盘（Python exit 2 吞掉）
    final r4 = await advanceFromTitle(
        runSearch: f.fn,
        subjectId: 'endo',
        query: '定位不到章',
        progressData: progFixture(),
        opts: opts);
    expect(r4['ok'], false);
    expect(r4['advanced'], false);
    expect((r4['note'] as String), contains('无法从 title 定位章节'));

    // 保险③：倒退拒绝（推进到 3 后命中第二章块 → 不落盘）
    final d5 = progFixture();
    await advanceFromTitle(
        runSearch: f.fn,
        subjectId: 'endo',
        query: '第三章 近代变革',
        progressData: d5,
        opts: opts);
    final r5 = await advanceFromTitle(
        runSearch: f.fn,
        subjectId: 'endo',
        query: '第二章 口腔检查',
        progressData: d5,
        opts: opts);
    expect(r5['ok'], false);
    expect(r5['advanced'], false);
    expect((r5['note'] as String), contains('倒退'));
    expect(endoOf(d5)['learned_through'], 3);

    // 契约 10：检索故障（SearchException）→ 降级记 note 不阻断
    final r6 = await advanceFromTitle(
        runSearch: f.fn,
        subjectId: 'endo',
        query: '故障章',
        progressData: progFixture(),
        opts: opts);
    expect(r6['ok'], false);
    expect((r6['note'] as String), contains('教材检索失败'));

    // 收紧校验（trustworthy 默认 true）：报「第三章」误命中「…第二十九章…」
    // → 拒绝推进（Python self_test out6 端到端）
    final d7 = progFixture();
    final r7 = await advanceFromTitle(
        runSearch: f.fn,
        subjectId: 'endo',
        query: '第三章',
        progressData: d7,
        opts: opts);
    expect(r7['ok'], false);
    expect((r7['note'] as String), contains('命中章节与所报章/篇号不一致'));
    expect(endoOf(d7)['learned_through'], 2);
    expect(endoOf(d7)['history'] as List, isEmpty);

    // trustworthy=false（compass 口径）：放行收紧校验——但该误命中 title
    // 在罗盘上定位不到章序 → 保险②接续挡下（双保险串联可见）
    final r8 = await advanceFromTitle(
        runSearch: f.fn,
        subjectId: 'endo',
        query: '第三章',
        progressData: progFixture(),
        opts: opts,
        trustworthy: false);
    expect(r8['ok'], false);
    expect((r8['note'] as String), contains('无法从 title 定位章节'));

    // 检索限定：source_type=textbook + 科目过滤 + k=3（run.py L1236 口径）
    expect(
        f.calls
            .where((c) => c['type'] == 'textbook' && c['k'] == 3)
            .length,
        greaterThan(0));
    expect(f.calls.where((c) => c['subject'] == 'endo').length,
        greaterThan(0));
    expect(f.calls.every((c) => c['type'] == 'textbook'), true);
  });

  // --------------------------------------------- G. studyLogAdvance ----

  test('studyLogAdvance：逐 ref 推进/倒退 ref 不落盘/未变原地/dry-run/无科目', () async {
    final f = fakeCompassSearch();
    const opts = RunOptions();

    final d = progFixture();
    final out = await studyLogAdvance(
      runSearch: f.fn,
      subjectId: 'endo',
      subjectName: '世界通史',
      refs: ['第三章 近代变革', '第二章 口腔检查', '第三章 近代变革'],
      progressData: d,
      opts: opts,
    );
    expect(out['subjectId'], 'endo');
    expect(out['subjectName'], '世界通史');
    final rows = out['refs'] as List;
    expect(rows.length, 3);
    expect((rows[0] as Map)['ref'], '第三章 近代变革');
    expect((rows[0] as Map)['advanced'], true); // 2 → 3
    expect((rows[1] as Map)['advanced'], false); // 倒退（3 → 2）拒绝不落盘
    expect(((rows[1] as Map)['note'] as String), contains('倒退'));
    expect((rows[2] as Map)['advanced'], true); // 未变（3）原地 rc=0
    expect(((rows[2] as Map)['note'] as String), contains('未变（3）'));
    expect(out['advancedCount'], 2); // ≈st['compassAdvances'] 计数口径
    expect(endoOf(d)['learned_through'], 3);
    expect((endoOf(d)['history'] as List).length, 1); // 仅第一 ref 真推进

    // dry-run：全程不推进、行内 wouldAdvance 预演
    final d2 = progFixture();
    final out2 = await studyLogAdvance(
      runSearch: f.fn,
      subjectId: 'endo',
      subjectName: '世界通史',
      refs: ['第三章 近代变革'],
      progressData: d2,
      opts: const RunOptions(dryRun: true),
    );
    final row2 = (out2['refs'] as List).first as Map;
    expect(row2['advanced'], isNull);
    expect(row2['wouldAdvance'], '第三章 近代变革·概述');
    expect(endoOf(d2)['learned_through'], 2);

    // 无科目：note + refs 空（不检索不推进不阻断）
    final out3 = await studyLogAdvance(
      runSearch: f.fn,
      subjectId: 'nobody',
      subjectName: '',
      refs: ['第三章'],
      progressData: progFixture(),
      opts: opts,
    );
    expect((out3['note'] as String), contains('进度库无该科目'));
    expect(out3['refs'] as List, isEmpty);
    expect(out3['subjectName'], 'nobody'); // 空名回退短码（Python subject_name or sid）
  });

  // ----------------------------------------------- H. compassLocate ----

  test('compassLocate：当前章名检索/显示名回退/无科目跳过/未命中/推进/dry-run', () async {
    final calls = <Map<String, Object?>>[];
    Future<Map<String, Object?>> fake(String query,
        {String? subject, String? sourceType, int? k}) async {
      calls.add({'q': query, 'type': sourceType});
      if (query == '第二章 口腔检查') {
        return {
          'results': [
            {'score': 0.90, 'title': '第三章 近代变革·概述'}
          ]
        };
      }
      return {
        'results': [
          {'score': 0.20, 'title': '低分'}
        ]
      };
    }

    final d = progFixture();
    (d['subjects'] as Map)['oms'] = {
      'textbook': null,
      'chapters': <Object?>[],
      'learned_through': 0,
      'updated_at': '2026-09-05T00:00:00',
      'history': <Object?>[],
    };
    final out = await compassLocate(
      runSearch: fake,
      subjectsToday: ['oms', 'endo', 'nobody'],
      progressData: d,
      subjectDisplay: (sid) => sid == 'oms' ? '口腔外科学' : sid,
      opts: const RunOptions(),
    );
    // 当日科目去重排序（≈sorted(set(...))）
    expect(out.keys.toList(), ['endo', 'nobody', 'oms']);
    // endo：罗盘当前章名（learned 2 → current='第二章 口腔检查'）检索命中 → 推进
    expect(out['endo']!['ok'], true);
    expect(out['endo']!['hit'], '第三章 近代变革·概述');
    expect(endoOf(d)['learned_through'], 3);
    // oms：未开始（learned 0 无当前章）→ 显示名回退检索 → 未命中不推进
    expect(out['oms']!['ok'], false);
    expect((out['oms']!['note'] as String), contains('教材未命中'));
    expect(calls.any((c) => c['q'] == '口腔外科学'), true); // 显示名回退路径已检索
    // endo 检索词=当前章名
    expect(calls.any((c) => c['q'] == '第二章 口腔检查'), true);
    // nobody：不在库 → 跳过（不检索）
    expect((out['nobody']!['note'] as String), contains('进度库无该科目'));
    expect(calls.length, 2); // 只检索 endo + oms，nobody 未检索

    // dry-run：wouldAdvance 预演，不真推进
    final d2 = progFixture();
    final out2 = await compassLocate(
      runSearch: fake,
      subjectsToday: ['endo'],
      progressData: d2,
      subjectDisplay: (sid) => sid,
      opts: const RunOptions(dryRun: true),
    );
    expect(out2['endo']!['wouldAdvance'], '第三章 近代变革·概述');
    expect(endoOf(d2)['learned_through'], 2);
  });

  // ------------------------------------------ I. trustworthy 六态 ----

  test('studyHitTrustworthy：六态跨文件复用确认（本体详测在 run_engine_test）', () {
    expect(studyHitTrustworthy('第三章 近代变革', '第三章 近代变革·概述'), true); // ① 章号一致放行
    expect(
        studyHitTrustworthy(
            '第三章 近代变革', '第四篇 口腔检查与术区隔离·第二十九章 世界通史实习教程'),
        false); // ② 章号不一致拒绝
    expect(studyHitTrustworthy('第3章 临床表现', '第三章 临床表现、诊断与治疗·第一节'),
        true); // ③ 阿拉伯章号归一放行
    expect(studyHitTrustworthy('龋病学', '第一篇 龋病学·概述'), true); // ④ 纯章名不校验
    expect(studyHitTrustworthy('第一篇 龋病学', '第一篇 龋病学·第四章 龋病的治疗计划'),
        true); // ⑤ 篇号一致放行
    expect(studyHitTrustworthy('第三章', '第一篇 龋病学·概述'), false); // ⑥ 报章命中纯篇号拒绝
  });

  // ------------------------------------------------- J. 装配器 ----

  test('装配器：progressEntryOf 直连原始/weeklyChapters 过滤/三层显示名/legalSubjects', () {
    final data = {
      'version': 1,
      'subjects': {
        'endo': {
          'textbook': '世界通史-第2版',
          'chapters': [
            {'no': 1, 'title': '目录', 'page_start': 3},
            {'no': 2, 'title': '绪论', 'page_start': 5},
            {'no': 3, 'title': '第一篇 龋病学', 'page_start': 9},
            {'no': 4, 'title': '索引', 'page_start': 99},
          ],
          'learned_through': 3,
          'updated_at': '2026-09-05T00:00:00',
          'history': <Object?>[],
        },
        'derm': {
          'textbook': null,
          'chapters': <Object?>[],
          'learned_through': 0,
          'updated_at': '2026-09-05T00:00:00',
          'history': <Object?>[],
        },
      },
    };

    // progressEntryOf：直连原始 subjects Map（罗盘函数唯一可用口径——
    // 已知坑：任何 List 视图转换会静默落空）
    final entry = progressEntryOf(data, 'endo');
    expect(entry, isNotNull);
    final rawChapters = ((data['subjects'] as Map)['endo'] as Map)['chapters'];
    expect(entry!['chapters'], same(rawChapters)); // 浅拷贝共享嵌套，非视图转换
    expect(currentChapterTitle(entry), '第一篇 龋病学');
    expect(nextChapterTitle(entry), null); // no=4 是索引（正文章过滤）→ 无下一章
    expect(progressEntryOf(data, 'nobody'), isNull);

    // weeklyChapters：已学正文章（目录/索引过滤）→ [{subject, subjectName, chapter}]
    final chs = weeklyChapters(data, subjectNames: {'derm': '皮肤科学'});
    expect(chs, [
      {'subject': 'endo', 'subjectName': '世界通史', 'chapter': '绪论'},
      {'subject': 'endo', 'subjectName': '世界通史', 'chapter': '第一篇 龋病学'},
    ]); // endo 无课表名 → 教材名去「-第5版」；derm learned 0 无已学章不列

    // subjectDisplayName 三层：课表/DB 名 → 教材名去版次 → 短码
    expect(subjectDisplayName('endo', subjectNames: {'endo': '近代史纲'}, progressData: data), '近代史纲');
    expect(subjectDisplayName('endo', progressData: data), '世界通史'); // 第②层
    expect(subjectDisplayName('zzz', progressData: data), 'zzz'); // 第③层
    expect(subjectDisplayName('derm', subjectNames: {'derm': '皮肤科学'}, progressData: data), '皮肤科学');

    // legalSubjects：课表 ∪ 进度库（∪ extraIds）排序去重
    final legal = legalSubjects(data,
        subjectNames: {'oms': '口腔颌面外科学'}, extraIds: ['zzz']);
    expect(legal.map((s) => s['id']).toList(), ['derm', 'endo', 'oms', 'zzz']);
    expect(legal.firstWhere((s) => s['id'] == 'oms')['name'], '口腔颌面外科学');
    expect(legal.firstWhere((s) => s['id'] == 'endo')['name'], '世界通史');
    expect(legal.firstWhere((s) => s['id'] == 'zzz')['name'], 'zzz');

    // compassSummary：--learned 数据层（learned/total/current/next）
    final sum = compassSummary(entry);
    expect(sum.learnedThrough, 3);
    expect(sum.chapterCount, 4); // 含目录/索引（不重编号）
    expect(sum.learned.map((c) => c.title).toList(), ['绪论', '第一篇 龋病学']);
    expect(sum.current, '第一篇 龋病学');
    expect(sum.next, null);
  });

  test('装配器×runWeekly 协同冒烟：weeklyChapters → runWeekly 出真题卡（留缝闭环）', () async {
    final data = progFixture(); // endo learned 2：已学 [绪论, 第二章 口腔检查]
    final chs = weeklyChapters(data); // runWeekly 的 chapters 唯一供料
    expect(
        chs,
        equals([
          {'subject': 'endo', 'subjectName': '世界通史', 'chapter': '绪论'},
          {'subject': 'endo', 'subjectName': '世界通史', 'chapter': '第二章 口腔检查'},
        ]));
    final legal = legalSubjects(data);

    Future<Map<String, Object?>> fakeSearch(String query,
        {String? subject, String? sourceType, int? k}) async {
      return {
        'results': [
          {
            'chunk_id': 'exam:$query',
            'deck': '2021年口腔执业医师资格试题（网友回忆版）',
            'page_range': '1-2',
            'title': '真题·$query',
            'source_type': 'exam',
            'text': '题干与解析',
            'score': 0.8,
          }
        ]
      };
    }

    Future<String> fakeLlm(String system, String user, {String tag = ''}) async =>
        '{"cards":[{"front":"F","back":"B","subjectId":"endo",'
        '"examMeta":{"year":"2021","no":"7"}}]}';

    final res = await runWeekly(
      runSearch: fakeSearch,
      llmChat: fakeLlm,
      prompts: const {},
      chapters: chs,
      legalSubjects: legal,
      opts: const RunOptions(),
    );
    expect(res['candidates'], 2); // 两章各 1 候选（chunk_id 按章名区分不去重）
    final cards = res['cards'] as List;
    expect(cards.length, 1);
    final card = cards.first as Map;
    expect(card['id'], 'exam-endo-2021-7'); // 通道 B 幂等 id 形态
    expect((card['tags'] as List), contains('真题'));
    final counts = res['counts'] as Map;
    expect(counts['cards'], 1);
  });

  test('⑤ 跳过章=未学协同：weeklyChapters 剔除跳过章 → runWeekly 不为其出真题卡', () async {
    // ⑨ 章节管理模型：learned_through=2 但第 2 章标记不学（skipped=[2]）——
    // 指针虽越过该章，周扫供料仍视同未学（宁少勿多）。
    final data = progFixture();
    ((data['subjects'] as Map)['endo'] as Map)['skipped'] = [2];
    final chs = weeklyChapters(data);
    expect(
      chs.map((c) => c['chapter']).toList(),
      ['绪论'],
      reason: '跳过章（第二章 口腔检查）不进周扫章节池',
    );

    final queries = <String>[];
    final res = await runWeekly(
      runSearch: (query, {subject, sourceType, k}) async {
        queries.add(query);
        return {'results': <Object?>[]};
      },
      llmChat: (system, user, {String tag = ''}) async {
        throw StateError('零候选不应调用 LLM');
      },
      prompts: const {},
      chapters: chs,
      legalSubjects: legalSubjects(data),
      opts: const RunOptions(),
    );
    expect(queries, ['绪论'], reason: '跳过章不检索不出卡（与⑨模型对齐）');
    expect((res['counts'] as Map)['cards'], 0);
  });

  // ------------------------------------ K. #16 罗盘初始化（逐科目形态） ----

  test('initFromTocSidecar：逐科目建/刷新保留进度/缺失损坏不动库/tocSidecarSubjects', () {
    final tmp = Directory.systemTemp.createTempSync('hengya-progdb-init16-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final toc = Directory('${tmp.path}${Platform.pathSeparator}toc')
      ..createSync();
    Map<String, Object?> sidecar(String subject, String textbook,
            List<Map<String, Object?>> chapters) =>
        {
          'version': 1,
          'subject': subject,
          'textbook': textbook,
          'chapters': chapters,
          'sections': <Object?>[],
        };
    final endoChapters = [
      {'no': 1, 'title': '绪论', 'page_start': 1},
      {'no': 2, 'title': '第二章 口腔检查', 'page_start': 8},
      {'no': 3, 'title': '第三章 近代变革', 'page_start': 20},
    ];
    File('${toc.path}${Platform.pathSeparator}endo.json').writeAsStringSync(
        jsonEncode(sidecar('endo', '世界通史-第2版', endoChapters)));

    // tocSidecarSubjects：清单 = stem 排序；缺目录 → null
    expect(tocSidecarSubjects(toc.path), ['endo']);
    expect(tocSidecarSubjects('${tmp.path}/nope'), isNull);

    // ① sidecar → 新条目（字段逐项：全 0 起步）
    final data = emptyProgress();
    final r1 = initFromTocSidecar(data, toc.path, 'endo');
    expect(r1.ok, true, reason: r1.note);
    expect(r1.mutated, true);
    expect(r1.note, contains('新增'));
    final endo = (data['subjects'] as Map)['endo'] as Map<String, Object?>;
    expect(endo['textbook'], '世界通史-第2版');
    expect(endo['chapters'], equals(endoChapters.map(jsonEncode).map(jsonDecode).toList()));
    expect(endo['learned_through'], 0);
    expect(endo['history'], isEmpty);
    expect('${endo['updated_at']}', isNotEmpty);

    // ② 已有条目 → 刷新 textbook/chapters，保留 learned_through 与 history
    setSubjectNo(data, 'endo', 2); // history 追加 1 条（0→2 seed/manual）
    File('${toc.path}${Platform.pathSeparator}endo.json').writeAsStringSync(
        jsonEncode(sidecar('endo', '世界通史-第3版', [
          ...endoChapters,
          {'no': 4, 'title': '第四章 工业革命', 'page_start': 40},
        ])));
    final r2 = initFromTocSidecar(data, toc.path, 'endo');
    expect(r2.ok, true);
    expect(r2.note, contains('保留进度与历史'));
    expect(endo['textbook'], '世界通史-第3版'); // 教材名随 sidecar 刷新
    expect((endo['chapters'] as List).length, 4);
    expect(endo['learned_through'], 2); // 进度不回拨
    expect((endo['history'] as List).length, 1); // 历史保留

    // ③ sidecar 缺失 → 不动进度库（宁缺毋滥）
    final r3 = initFromTocSidecar(data, toc.path, 'oms');
    expect(r3.ok, false);
    expect(r3.mutated, false);
    expect(r3.note, contains('toc sidecar 缺失'));
    expect((data['subjects'] as Map).containsKey('oms'), false);

    // ④ sidecar 损坏（坏 JSON）/结构异常（缺 chapters）→ 不动进度库
    File('${toc.path}${Platform.pathSeparator}bad.json')
        .writeAsStringSync('not-json{{{');
    final r4 = initFromTocSidecar(data, toc.path, 'bad');
    expect(r4.ok, false);
    expect(r4.note, contains('解析失败'));
    expect((data['subjects'] as Map).containsKey('bad'), false);
    File('${toc.path}${Platform.pathSeparator}bad.json')
        .writeAsStringSync('{"nope": 1}');
    final r5 = initFromTocSidecar(data, toc.path, 'bad');
    expect(r5.ok, false);
    expect(r5.note, contains('结构异常'));
    expect((data['subjects'] as Map).containsKey('bad'), false);
    // 既有条目不受坏 sidecar 株连（cmd_init 整目录失败语义外的逐科目容错）
    expect(((data['subjects'] as Map)['endo'] as Map)['learned_through'], 2);
  });

  test('#16 端到端：sidecar init → studyLogAdvance 推进（0→N）；未命中带 note', () async {
    final tmp = Directory.systemTemp.createTempSync('hengya-progdb-init16e2e-');
    addTearDown(() => tmp.deleteSync(recursive: true));
    final toc = Directory('${tmp.path}${Platform.pathSeparator}toc')
      ..createSync();
    File('${toc.path}${Platform.pathSeparator}endo.json').writeAsStringSync(
        jsonEncode({
          'version': 1,
          'subject': 'endo',
          'textbook': '世界通史-第2版',
          'chapters': [
            {'no': 1, 'title': '绪论', 'page_start': 1},
            {'no': 2, 'title': '第二章 口腔检查', 'page_start': 8},
            {'no': 3, 'title': '第三章 近代变革', 'page_start': 20},
          ],
          'sections': <Object?>[],
        }));

    // 进度库空 + sidecar 在 → init 补条目（#16 双接线的公共前置）
    final data = emptyProgress();
    expect(progressEntryOf(data, 'endo'), isNull, reason: 'init 前条目缺失');
    final init = initFromTocSidecar(data, toc.path, 'endo');
    expect(init.ok, true, reason: init.note);
    expect(progressEntryOf(data, 'endo'), isNotNull, reason: 'init 后条目在场——推进链可用');

    // 学习记录「第二章 口腔检查」→ fake 教材检索命中 → learned_through 0→2
    final search = fakeCompassSearch();
    final out = await studyLogAdvance(
      runSearch: search.fn,
      subjectId: 'endo',
      subjectName: '世界史',
      refs: ['第二章 口腔检查'],
      progressData: data,
      opts: const RunOptions(),
    );
    final row = (out['refs'] as List).single as Map<String, Object?>;
    expect(row['ok'], true, reason: '${row['note']}');
    expect(row['advanced'], true);
    expect(row['toNo'], 2);
    final endo = (data['subjects'] as Map)['endo'] as Map<String, Object?>;
    expect(endo['learned_through'], 2, reason: '罗盘 0→2（首章推进可见）');
    expect((endo['history'] as List).length, 1);
    expect(out['advancedCount'], 1);

    // 未命中（低于低分线）→ ok=false 带 note，不推进不落 history
    final out2 = await studyLogAdvance(
      runSearch: search.fn,
      subjectId: 'endo',
      subjectName: '世界史',
      refs: ['未命中章'],
      progressData: data,
      opts: const RunOptions(),
    );
    final row2 = (out2['refs'] as List).single as Map<String, Object?>;
    expect(row2['ok'], false);
    expect(row2['advanced'], isNull);
    expect('${row2['note']}', contains('教材未命中'));
    expect(endo['learned_through'], 2, reason: '未命中不推进');
    expect((endo['history'] as List).length, 1, reason: '未命中不落 history');
    expect(out2['advancedCount'], 0);
  });
}
