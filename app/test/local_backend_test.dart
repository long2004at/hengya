// 本地模式后端验证（Phase 1）：真数据层 SQLite 全流程真实流转——
// 语义对照 server/lib/src/routes/*.dart（审核/评分/回炉/科目 409/收件箱
// 校验链/统计/进度/语料状态/上传校验/AI 配置掩码/流水线标志）。
// 与 demo_backend_test.dart 同姿势（直调 LocalBackend.instance.get/post/
// put/upload），但数据经 importCards 种入临时 SQLite 文件，跨用例隔离。
// #16 建库收尾罗盘初始化钩子：corpusBuildJobOverride 假 job 驱动收尾时序
// → toc sidecar → progress.json 条目（幂等刷新保留进度；坏 sidecar 跳过）。
//
// 宿主基建：package:sqlite3 在 Windows 测试宿主需要 sqlite3.dll——
// 生产 Android 由 sqlite3_flutter_libs 打包 .so（无需本 override）；
// flutter test 宿主无插件加载通道 → 由下方 override 显式加载本仓库
// test/sqlite3.dll（1.7MB，simolus3/sqlite3.dart 官方 release 资产
// sqlite3-3.5.2/sqlite3.x64.windows.dll，SQLite 3.53.4）。
// !! 教训：python 自带的 DLLs\sqlite3.dll 在任何非 python 进程里调用
// sqlite3_open_v2 都会 ACCESS_VIOLATION（0xC0000005，加载与查符号正常、
// 首次 open 即崩）——不可用于 FFI 测试宿主。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/corpus/progress_db.dart'
    show loadProgress, progressEntryOf, saveProgress, setSubjectNo;
import 'package:hengya/services/local/corpus_build_job.dart'
    show CorpusBuildResult;
import 'package:hengya/services/local/db.dart';
import 'package:hengya/services/local/isolate_runner.dart'
    show IsolateProgressEvent;
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/hengya_shared.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Windows 测试宿主：显式加载 test/sqlite3.dll（overrideForAll 全模式覆盖；
  // flutter test 的 CWD = 包根 app/）
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hengya_local_test_');
  });

  tearDown(() async {
    await LocalBackend.instance.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> boot() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
  }

  /// 测试科目 + 三张待审卡种子（两科 + 三卡），供审核/评分/回炉流转。
  /// 0.3.1 开源去内置：新库零科目 → 先自建两科（用户科目）再导卡
  Future<void> seedCards() async {
    await LocalBackend.instance.post('/subjects', {'name': '世界历史', 'id': 'oms'});
    await LocalBackend.instance.post('/subjects', {'name': '基础化学', 'id': 'endo'});
    final res = await LocalBackend.instance.importCards([
      {
        'id': 'local-oms-001',
        'subjectId': 'oms',
        'type': 'basic',
        'front': '文艺复兴运动最早兴起于哪个国家？',
        'back': '意大利（14 世纪，从佛罗伦萨等城市兴起）。',
        'anchor': '近代史·文艺复兴',
        'source': '世界历史 近代史 PPT',
        'status': 'pending',
      },
      {
        'id': 'local-oms-002',
        'subjectId': 'oms',
        'type': 'basic',
        'front': '第二次世界大战全面爆发的标志是什么？',
        'back': '1939 年 9 月德国闪击波兰，英法对德宣战。',
        'anchor': '近代史·二战',
        'source': '世界历史 PPT',
        'status': 'pending',
      },
      {
        'id': 'local-endo-001',
        'subjectId': 'endo',
        'type': 'basic',
        'front': '什么是化学元素？',
        'back': '具有相同质子数（核电荷数）的一类原子的总称。',
        'anchor': '基本概念·元素',
        'source': '基础化学 1.1 PPT',
        'status': 'pending',
      },
    ]);
    expect(res['inserted'], 3);
  }

  test('初始态：新库零科目（0.3.1 无内置播种），零到期零待审，data_version 可读', () async {
    await boot();
    final subs = await LocalBackend.instance.get('/subjects');
    final list = (subs['subjects'] as List).cast<Map<String, dynamic>>();
    expect(list, isEmpty); // 开源版首启零科目，全部用户自建
    expect(list.every((s) => s['dueCount'] == 0), true);

    final pending = await LocalBackend.instance.get('/cards/pending');
    expect((pending['list'] as List), isEmpty);

    final meta = await LocalBackend.instance.get('/meta/version');
    // server 语义：初始 data_version='0'（写入操作才 bump；对照 db.dart 迁移）
    expect(int.parse(meta['data_version'] as String), 0);

    final health = await LocalBackend.instance.get('/health');
    expect(health['status'], 'ok');
  });

  test('导入幂等与未知科目：重复 id skip、未知科目 errors 细目', () async {
    await boot();
    // 0.3.1 新库零科目：先自建科目再导卡
    await LocalBackend.instance
        .post('/subjects', {'name': '世界历史', 'id': 'oms'});
    final res1 = await LocalBackend.instance.importCards([
      {'id': 'dup-1', 'subjectId': 'oms', 'type': 'basic',
       'front': 'f', 'back': 'b', 'anchor': 'a', 'source': 's',
       'status': 'pending'},
      {'id': 'dup-1', 'subjectId': 'oms', 'type': 'basic',
       'front': 'f', 'back': 'b', 'anchor': 'a', 'source': 's',
       'status': 'pending'},
      {'id': 'dup-2', 'subjectId': 'nope', 'type': 'basic',
       'front': 'f', 'back': 'b', 'anchor': 'a', 'source': 's',
       'status': 'pending'},
    ]);
    expect(res1['inserted'], 1);
    expect(res1['skipped'], 1);
    expect((res1['errors'] as List).single, contains('未知科目 nope'));
  });

  test('审核流转：批准→队列可见→评分→FSRS 推进→逾期累计', () async {
    await boot();
    await seedCards();

    // 批准 001/002
    await LocalBackend.instance.post('/cards/local-oms-001/approve', null);
    await LocalBackend.instance.post('/cards/local-oms-002/approve', null);

    // 队列可见（due=now）
    final q = await LocalBackend.instance.get('/cards/queue?subject=oms');
    final ids =
        ((q['cards'] as List).cast<Map<String, dynamic>>()).map((c) => c['id']);
    expect(ids, containsAll(['local-oms-001', 'local-oms-002']));
    // 科目隔离：endo 队列不含 oms 卡
    final qEndo = await LocalBackend.instance.get('/cards/queue?subject=endo');
    expect((qEndo['cards'] as List), isEmpty);

    // 到期角标
    final subs = await LocalBackend.instance.get('/subjects');
    final oms = (subs['subjects'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['id'] == 'oms');
    expect(oms['dueCount'], 2);

    // 评分 good → review 态、间隔 > 0、due 推远
    final res = await LocalBackend.instance.post('/review/answer', {
      'cardId': 'local-oms-001',
      'rating': 'good',
      'reviewedAt': DateTime.now().toIso8601String(),
    });
    expect(res['applied'], 1);
    final first = (res['results'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((r) => r['cardId'] == 'local-oms-001');
    expect(first['ok'], true);
    expect(first['state'], 'review');
    expect((first['intervalDays'] as num), greaterThan(0));

    // 评分后 queue 里 001 应让位（due 推远）
    final q2 = await LocalBackend.instance.get('/cards/queue?subject=oms');
    final ids2 =
        ((q2['cards'] as List).cast<Map<String, dynamic>>()).map((c) => c['id']);
    expect(ids2, isNot(contains('local-oms-001')));
  });

  test('评分加固：批量混脏数据只 skip，不整批失败（对照 routes/review.dart）', () async {
    await boot();
    await seedCards();
    await LocalBackend.instance.post('/cards/local-oms-001/approve', null);

    final res = await LocalBackend.instance.post('/review/answer', [
      '不是对象',
      {'rating': 'good'}, // 缺 cardId
      {'cardId': 'ghost-404', 'rating': 'good'}, // 卡不存在
      {'cardId': 'local-oms-001', 'rating': 'super'}, // 非法 rating
      {'cardId': 'local-endo-001', 'rating': 'good'}, // pending 非 active
      {'cardId': 'local-oms-001', 'rating': 'good'}, // 唯一合法
    ]);
    expect(res['applied'], 1);
    expect(res['skipped'], 5);
    final results = (res['results'] as List).cast<Map<String, dynamic>>();
    expect(results.length, 6);
    expect(results[1]['error'], contains('cardId'));
    expect(results[3]['error'], contains('非法评分'));
    expect(results[4]['error'], contains('非 active'));
  });

  test('状态守卫：approve/reject 仅 pending；edit 放宽 active；rework 仅 active', () async {
    await boot();
    await seedCards();
    final be = LocalBackend.instance;

    // 404：不存在
    await expectLater(
      be.post('/cards/ghost/approve', null),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 404)),
    );
    // 400：pending 才能批；active 再批 → 400
    await be.post('/cards/local-oms-001/approve', null);
    await expectLater(
      be.post('/cards/local-oms-001/approve', null),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)),
    );
    // edit：active 卡可编辑，调度字段不动
    final edit = await be.post('/cards/local-oms-001/edit', {
      'front': '改后的题干',
    });
    expect(edit['ok'], true);
    expect((edit['card'] as Map)['front'], '改后的题干');
    final detail = await be.get('/cards/local-oms-001');
    expect((detail as Map)['front'], '改后的题干');
    // reject 非 pending → 400
    await expectLater(
      be.post('/cards/local-oms-001/reject', {'reason': '测试'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)),
    );
    // rework 仅 active：pending 卡回炉 → 400
    // #15：400 文案去内部 id 化（逐字断言新文案——旧版把「卡 <id> 状态为…」
    // 直接泄给用户）
    await expectLater(
      be.post('/cards/rework', {'cardId': 'local-endo-001', 'reason': '绕'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)
          .having((e) => e.message, 'message',
              '该卡当前状态不支持回炉（仅审核通过的在学卡可回炉）')),
    );
    // rework 404 分支同文案（不带内部 id）
    await expectLater(
      be.post('/cards/rework', {'cardId': 'ghost-404', 'reason': '绕'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 404)
          .having((e) => e.message, 'message', '卡片不存在或已被移除')),
    );
  });

  test('拒绝带理由 → 回炉队列；重造完成 → 回待审池', () async {
    await boot();
    await seedCards();
    final be = LocalBackend.instance;

    await be.post('/cards/local-endo-001/reject',
        {'reason': '答案有误', 'note': '课本第 3 页'});
    final pending = await be.get('/cards/pending');
    // reject 只移除 endo-001；oms 两张 pending 卡照常在池
    final remain = (pending['list'] as List).cast<Map<String, dynamic>>();
    expect(remain.length, 2);
    expect(remain.any((c) => c['id'] == 'local-endo-001'), false);

    final rq = await be.get('/cards/rework/pending');
    final items = (rq['queue'] as List).cast<Map<String, dynamic>>();
    expect(items.single['cardId'], 'local-endo-001');
    expect(items.single['reason'], contains('答案有误'));

    // done → 回 pending（池内 oms 两张 + 重造的 endo-001 共 3 张）
    final done = await be.post(
        '/cards/rework/${items.single['id']}/done',
        {'front': '重写后的题干', 'back': '重写后的答案'});
    expect(done['ok'], true);
    final pending2 = await be.get('/cards/pending');
    final cards = (pending2['list'] as List).cast<Map<String, dynamic>>();
    final reworked =
        cards.firstWhere((c) => c['id'] == 'local-endo-001');
    expect(reworked['front'], '重写后的题干');

    // 再次 done 同队列项 → 400 stale
    await expectLater(
      be.post('/cards/rework/${items.single['id']}/done', null),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)),
    );
  });

  test('题库：search 非 pending + 科目过滤 + 全文 + 单卡详情同构', () async {
    await boot();
    await seedCards();
    final be = LocalBackend.instance;
    // 001/002 都批准（pending 卡不进题库——质量闸门，决策 #9）
    await be.post('/cards/local-oms-001/approve', null);
    await be.post('/cards/local-oms-002/approve', null);

    final s1 = await be
        .get('/cards/search?subject=oms&q=第二次世界大战');
    expect(s1['total'], 1);
    final hit = (s1['cards'] as List).cast<Map<String, dynamic>>().single;
    expect(hit['id'], 'local-oms-002');

    final detail = await be.get('/cards/local-oms-001');
    final d = detail;
    expect(d['id'], 'local-oms-001');
    expect(d.containsKey('dueAt'), true);
    expect(d.containsKey('reps'), true);
    // endo-001 未批（pending）→ 题库不可见
    final s2 = await be.get('/cards/search');
    final visIds = (s2['cards'] as List)
        .cast<Map<String, dynamic>>()
        .map((c) => c['id']);
    expect(visIds, isNot(contains('local-endo-001')));
    // 404
    await expectLater(
      be.get('/cards/ghost'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 404)),
    );
  });

  test('备注：get 空态 → post userNote → 读回；二缺一 400', () async {
    await boot();
    await seedCards();
    final be = LocalBackend.instance;

    final n0 = await be.get('/cards/local-oms-001/notes');
    expect((n0 as Map)['userNote'], '');

    await be.post('/cards/local-oms-001/notes', {'userNote': '我的备注'});
    final n1 = await be.get('/cards/local-oms-001/notes');
    expect((n1 as Map)['userNote'], '我的备注');

    await expectLater(
      be.post('/cards/local-oms-001/notes', {}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)),
    );
  });

  test('动态科目：新建（自动短码/409 重码/409 重名/400 非法 id）+ 改名', () async {
    await boot();
    final be = LocalBackend.instance;

    final created = await be.post('/subjects', {'name': '植物学'});
    expect(created['ok'], true);
    expect((created['id'] as String).length, 8); // 自动 8 位短码

    await expectLater(
      be.post('/subjects', {'name': '植物学'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 409)
          .having((e) => e.message, 'msg', contains('已存在'))),
    );
    await expectLater(
      be.post('/subjects', {'name': '新科目', 'id': created['id'] as String}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 409)),
    );
    await expectLater(
      be.post('/subjects', {'name': '新科目', 'id': '非法的ID!'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)),
    );

    final renamed = await be.put('/subjects/${created['id']}', {'name': '植物学基础'});
    expect(renamed['ok'], true);

    // 新科目出现在目录；0.3.1 起响应字段为白名单形状（无内置标记）
    final subs = await be.get('/subjects');
    final newbie = (subs['subjects'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((s) => s['id'] == created['id']);
    expect(newbie.keys.toSet(), {'id', 'name', 'isExamSubject', 'dueCount'});
    expect(newbie['name'], '植物学基础');
  });

  test('收件箱：入箱校验链 → pending → consume；未知科目 errors', () async {
    await boot();
    final be = LocalBackend.instance;
    // 0.3.1 新库零科目：先自建科目再入箱
    await be.post('/subjects', {'name': '世界历史', 'id': 'oms'});

    final res = await be.post('/inbox/keywords', [
      {'subjectId': 'oms', 'keyword': '工业革命的影响', 'source': 'app'},
      {'subjectId': '', 'keyword': 'x'}, // 缺 subjectId
      {'subjectId': 'oms', 'keyword': '  '}, // 空 keyword
      {'subjectId': 'ghost', 'keyword': 'y'}, // 未知科目
    ]);
    expect(res['inserted'], 1);
    expect((res['errors'] as List).length, 3);

    final pending = await be.get('/inbox/pending');
    final items = (pending['list'] as List).cast<Map<String, dynamic>>();
    expect(items.single['keyword'], '工业革命的影响');

    final consumed =
        await be.post('/inbox/consume', {'ids': [items.single['id']]});
    expect(consumed['consumed'], 1);
    final pending2 = await be.get('/inbox/pending');
    expect((pending2['list'] as List), isEmpty);
  });

  test('统计五路：评分后 streak/heatmap/forecast/summary/retention 全有料', () async {
    await boot();
    await seedCards();
    final be = LocalBackend.instance;
    await be.post('/cards/local-oms-001/approve', null);
    await be.post('/cards/local-oms-002/approve', null);
    await be.post('/review/answer', [
      {'cardId': 'local-oms-001', 'rating': 'good'},
      {'cardId': 'local-oms-002', 'rating': 'again'},
    ]);

    final streak = await be.get('/stats/streak');
    expect(streak['streak'], greaterThanOrEqualTo(1));

    final heatmap = await be.get('/stats/heatmap');
    expect((heatmap['byDay'] as List), isNotEmpty);

    final forecast = await be.get('/stats/forecast?days=7');
    final days = (forecast['list'] as List).cast<Map<String, dynamic>>();
    expect(days.length, 7);
    // again 卡 due 仍在今天（10 分钟内重见）→ 今日列 ≥ 1
    expect(days.first['due'], greaterThanOrEqualTo(1));

    final summary = await be.get('/stats/summary');
    expect(summary['totalReviews'], 2);
    expect(summary['againCount'], 1);
    expect((summary['againRate'] as String), '0.500');

    final retention = await be.get('/stats/retention');
    final win1 = (retention['windows'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((w) => w['days'] == 1);
    expect(win1['total'], 2);
    expect(win1['retained'], 1);
    expect(win1['rate'], '0.500');

    // 超大 days 钳制（不炸）
    final hm2 = await be.get('/stats/heatmap?days=99999');
    expect(hm2['days'], 365);
  });

  test('进度罗盘：progress.json 读 + 辅文章过滤 + 空文件优雅空态', () async {
    await boot();
    final be = LocalBackend.instance;

    // 无文件 → 空态
    final empty = await be.get('/progress');
    expect((empty as Map)['subjects'], isEmpty);
    expect(empty['updated_at'], isNull);

    // 造 progress.json：目录/前言被过滤，next_chapter 落在 no>learned 的首章
    final corpus = Directory('${tmp.path}/corpus')..createSync(recursive: true);
    File('${corpus.path}/progress.json').writeAsStringSync('''
    {
      "subjects": {
        "endo": {
          "textbook": "世界通史-第2版",
          "learned_through": 1,
          "updated_at": "2026-09-01T10:00:00",
          "chapters": [
            {"no": 1, "title": "第一章 绪论", "page_start": 1},
            {"no": 2, "title": "目录", "page_start": 3},
            {"no": 3, "title": "前 言", "page_start": 5},
            {"no": 4, "title": "第二章 新航路", "page_start": 20}
          ]
        }
      }
    }
    ''');
    final view = await be.get('/progress');
    final subjects = (view as Map)['subjects'] as List;
    final endo = subjects.single as Map<String, dynamic>;
    expect(endo['textbook'], '世界通史-第2版');
    expect(endo['learned_through'], 1);
    expect(endo['total'], 4);
    final next = endo['next_chapter'] as Map<String, dynamic>;
    expect(next['no'], 4); // 目录/前言被辅文章过滤跳过
    expect(next['title'], '第二章 新航路');
    expect(view['updated_at'], '2026-09-01T10:00:00');

    // 损坏 JSON → 空态不炸
    File('${corpus.path}/progress.json')
        .writeAsStringSync('{broken json!!');
    final broken = await be.get('/progress');
    expect((broken as Map)['subjects'], isEmpty);
  });

  test('语料状态与上传：无 corpus.db 优雅零值；上传校验链 + 落盘 incoming', () async {
    await boot();
    final be = LocalBackend.instance;
    // 0.3.1 新库零科目：上传校验链需要真实科目（oms 为用户自建）
    await be.post('/subjects', {'name': '世界历史', 'id': 'oms'});

    // 无 corpus.db → 全零 200
    final st0 = await be.get('/corpus/status');
    expect((st0 as Map)['totalChunks'], 0);
    expect(st0['pendingFiles'], 0);

    // 未知科目 400
    await expectLater(
      be.upload('/corpus/upload?subject=ghost&filename=a.pptx', [0x50, 0x4B]),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)),
    );
    // 魔数不符 400
    await expectLater(
      be.upload('/corpus/upload?subject=oms&filename=a.pptx', [1, 2, 3, 4]),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)),
    );
    // 非白名单后缀 400
    await expectLater(
      be.upload('/corpus/upload?subject=oms&filename=a.exe', [0x50, 0x4B]),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)),
    );
    // 路径穿越：取末段清洗（对照 routes/corpus.dart _sanitizeFilename）——
    // `../evil.pptx` 落盘为 evil.pptx（无目录穿越，内容仍在 incoming 内）
    final traversed = await be.upload(
        '/corpus/upload?subject=oms&filename=..%2Fevil.pptx',
        [0x50, 0x4B]);
    expect(traversed['ok'], true);
    final savedEvil = File('${tmp.path}/corpus/incoming/oms/evil.pptx');
    expect(savedEvil.existsSync(), true);
    expect(savedEvil.lengthSync(), 2);

    // 合法 pptx（PK 头）→ 落盘 + pending=2（evil.pptx + 龋病.pptx）
    final ok = await be.upload('/corpus/upload?subject=oms&filename=%E9%BE%8B%E7%97%85.pptx',
        [0x50, 0x4B, 0x03, 0x04, 0x05, 0x06]);
    expect(ok['received'], 6);
    expect(ok['pending'], 2);
    final saved = File('${tmp.path}/corpus/incoming/oms/龋病.pptx');
    expect(saved.existsSync(), true);
    expect(saved.lengthSync(), 6);

    // status 汇总 pending
    final st1 = await be.get('/corpus/status');
    expect((st1 as Map)['pendingFiles'], 2);
    expect(st1['storageMB'], greaterThanOrEqualTo(0));
  });

  test(
      '教材标注 upload：source=textbook 落 -textbook 教材树；'
      '两棵树并存分键；未知 source 值回课件', () async {
    await boot();
    final be = LocalBackend.instance;
    await be.post('/subjects', {'name': '世界历史', 'id': 'oms'});

    final pdf = [0x25, 0x50, 0x44, 0x46]; // %PDF 魔数

    // 教材：query source=textbook → 落教材树 incoming/oms-textbook/
    //（首层目录 → splitSubjectSource 判 textbook → 建库写 toc sidecar →
    // #16 罗盘自动生成——链路见 upload 契约注释）
    final t = await be.upload(
        '/corpus/upload?subject=oms&filename=book.pdf&source=textbook', pdf);
    expect(t['ok'], true);
    final tbFile = File('${tmp.path}/corpus/incoming/oms-textbook/book.pdf');
    expect(tbFile.existsSync(), true, reason: '教材树落 -textbook 首层目录');
    expect(tbFile.lengthSync(), 4);

    // 同名文件再以课件上传 → 两棵树并存（合法场景），各落各树
    final c =
        await be.upload('/corpus/upload?subject=oms&filename=book.pdf', pdf);
    expect(c['ok'], true);
    expect(c['pending'], 2, reason: '课件树 + 教材树各 1 个待处理');
    expect(File('${tmp.path}/corpus/incoming/oms/book.pdf').existsSync(), true,
        reason: '课件树同名文件独立存在（manifest 键 oms/book.pdf 分键）');

    // 防御：非 'textbook'/'exam' 的 source 值（如 'other'）→ 回课件树，
    // 不另开目录（'exam' 自节点③起为合法真题类型，路由见下一用例）
    final u = await be.upload(
        '/corpus/upload?subject=oms&filename=other.pdf&source=other', pdf);
    expect(u['ok'], true);
    expect(File('${tmp.path}/corpus/incoming/oms/other.pdf').existsSync(), true,
        reason: '未知 source 值按课件处理（仅 textbook/exam 触发分支）');
    expect(Directory('${tmp.path}/corpus/incoming/oms-other').existsSync(), false);

    // 待处理清单分键：subject = 首层目录名（oms / oms-textbook）——
    // manifest 按相对路径分键，增量 changed/unchanged/removed 互不干扰
    final st = await be.get('/corpus/status');
    expect((st as Map)['pendingFiles'], 3);
    final build = await be.get('/corpus/build');
    final subjects = ((build as Map)['pending'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => e['subject'] as String)
        .toSet();
    expect(subjects, {'oms', 'oms-textbook'},
        reason: '两棵树并存：清单按首层目录名分键可见');
  });

  test(
      '真题专题 upload（节点③）：source=exam 落 <短码>-exam 真题树；'
      '不进 subjects 表；未知短码 400', () async {
    await boot();
    final be = LocalBackend.instance;
    final pdf = [0x25, 0x50, 0x44, 0x46]; // %PDF 魔数

    // 真题短码未在 subjects 表新建任何科目 → 上传照常成功（B1 拍板：
    // -exam 树不进科目 Tab，仅作周扫真题池；subjectExists 守卫不适用）
    final t = await be.upload(
        '/corpus/upload?subject=bingshi&filename=paper.pdf&source=exam', pdf);
    expect(t['ok'], true);
    final exFile = File('${tmp.path}/corpus/incoming/bingshi-exam/paper.pdf');
    expect(exFile.existsSync(), true, reason: '真题树落 <短码>-exam 首层目录');
    expect(exFile.lengthSync(), 4);
    expect(File('${tmp.path}/corpus/incoming/bingshi/paper.pdf').existsSync(),
        false,
        reason: '不污染课件树（真题与课件同短码互不干扰）');

    // 待处理清单分键：subject = 首层目录名（bingshi-exam）——
    // splitSubjectSource 判 exam → 建库 source_type='exam'（既有路由）
    final st = await be.get('/corpus/status');
    expect((st as Map)['pendingFiles'], 1);
    final build = await be.get('/corpus/build');
    final subjects = ((build as Map)['pending'] as List)
        .cast<Map<String, dynamic>>()
        .map((e) => e['subject'] as String)
        .toSet();
    expect(subjects, {'bingshi-exam'},
        reason: '真题树入待处理清单，按首层目录名分键');

    // 守卫口径：上传真题绝不自动建 subject（GET /subjects 无 bingshi）
    final subs = await be.get('/subjects');
    expect(
      ((subs as Map)['subjects'] as List)
          .where((s) => (s as Map)['id'] == 'bingshi'),
      isEmpty,
      reason: '-exam 树不进 subjects 表（不进科目 Tab）',
    );

    // 防御：source=exam + 未知短码 → 400（仅 12 考站专题合法，见
    // corpus/exam_topics.dart kExamTopics）
    await expectLater(
      be.upload('/corpus/upload?subject=xyz&filename=p.pdf&source=exam', pdf),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 400)),
    );
    expect(Directory('${tmp.path}/corpus/incoming/xyz-exam').existsSync(), false);

    // 防御：合法科目短码 + source=exam → 仍拒（科目短码 ≠ 真题专题短码，
    // 真题池只认 12 考站专题）
    await be.post('/subjects', {'name': '世界历史', 'id': 'oms'});
    await expectLater(
      be.upload('/corpus/upload?subject=oms&filename=p.pdf&source=exam', pdf),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 400)),
    );
    expect(Directory('${tmp.path}/corpus/incoming/oms-exam').existsSync(), false);
  });

  // ---------------- ⑦ 回炉队列统计联动（/corpus/status reworkPending） ----------------

  test(
      '⑦ 回炉待重造计数：/corpus/status reworkPending——零态/拒绝带理由/无理由拒绝/'
      '回炉按钮/混合/重复回炉幂等/reworkDone 回落', () async {
    await boot();
    await seedCards();
    final be = LocalBackend.instance;

    // ① 零态：pending/active 卡不计入（计数只看 rework_queue pending 行）
    var st = await be.get('/corpus/status');
    expect((st as Map)['reworkPending'], 0, reason: '初始零态');

    // ② 待审核区拒绝带理由（用户复现路径）：卡 rejected + 队列行 pending → +1
    await be.post('/cards/local-oms-001/reject', {'reason': '答案有误', 'note': ''});
    st = await be.get('/corpus/status');
    expect((st as Map)['reworkPending'], 1,
        reason: '拒绝带理由登记回炉队列 → 待重造 +1（卡状态 rejected 也计入）');

    // ③ 无理由拒绝：不登记队列 → 计数不动
    await be.post('/cards/local-endo-001/reject', {'reason': ''});
    st = await be.get('/corpus/status');
    expect((st as Map)['reworkPending'], 1, reason: '无理由拒绝不进回炉队列');

    // ④ 审核通过 → active：active 卡不计入
    await be.post('/cards/local-oms-002/approve', null);
    st = await be.get('/corpus/status');
    expect((st as Map)['reworkPending'], 1, reason: 'active 卡不计入');

    // ⑤ 题库/复习页回炉按钮（卡→rework + 队列行）→ 混合态 +1
    await be.post('/cards/rework', {'cardId': 'local-oms-002', 'reason': '表述绕'});
    st = await be.get('/corpus/status');
    expect((st as Map)['reworkPending'], 2,
        reason: '混合态：拒绝带理由（rejected）+ 回炉按钮（rework）各计 1');

    // ⑥ 重复回炉 → duplicate:true 幂等（不重复入队，计数不动）
    final dup = await be.post(
        '/cards/rework', {'cardId': 'local-oms-002', 'reason': '表述绕'});
    expect(dup['duplicate'], true, reason: '回炉幂等语义原样（#10②）');
    st = await be.get('/corpus/status');
    expect((st as Map)['reworkPending'], 2, reason: '幂等重复提交不追加队列行');

    // ⑦ 明细口径交叉验证：/cards/rework/pending 的 queue 长度 = reworkPending
    final rq = await be.get('/cards/rework/pending');
    final queue = (rq as Map)['queue'] as List;
    expect(queue.length, 2, reason: '计数与流水线消费明细（db.reworkPending）一致');

    // ⑧ 重造完成（reworkDone）：队列行置 done + 卡回 pending → 计数回落
    final reworkItemId = (queue
            .cast<Map<String, dynamic>>()
            .firstWhere((r) => r['cardId'] == 'local-oms-002'))['id']
        as int;
    final done = await be.post('/cards/rework/$reworkItemId/done', null);
    expect(done['ok'], true);
    st = await be.get('/corpus/status');
    expect((st as Map)['reworkPending'], 1, reason: 'reworkDone 后待重造回落');

    // ⑨ 剩余项（拒绝带理由登记）同样可被重造完成 → 归零
    final restId = ((await be.get('/cards/rework/pending'))
            as Map)['queue'] as List;
    final lastId =
        (restId.cast<Map<String, dynamic>>().first)['id'] as int;
    await be.post('/cards/rework/$lastId/done', {
      'front': '文艺复兴运动最早兴起于哪个国家？（重造）',
    });
    st = await be.get('/corpus/status');
    expect((st as Map)['reworkPending'], 0, reason: '全部重造完成后归零');
  });

  test('AI 配置：掩码态 GET/PUT（key 空串保持）/非法 baseUrl 400/未知服务 404', () async {
    await boot();
    final be = LocalBackend.instance;

    final s0 = await be.get('/settings/ai');
    final llm0 = (s0 as Map)['llm'] as Map<String, dynamic>;
    expect(llm0['keySet'], false);
    expect(llm0['keyMasked'], '');

    // 非法 baseUrl
    await expectLater(
      be.put('/settings/ai/llm', {'baseUrl': 'http://x.com', 'model': 'gpt'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)),
    );

    // 正常 PUT
    final p1 = await be.put('/settings/ai/llm', {
      'baseUrl': 'https://api.example.com/v1',
      'model': 'gpt-4o-mini',
      'apiKey': 'sk-abcdefgh12345678',
    });
    expect(p1['keySet'], true);
    expect(p1['keyMasked'], 'sk-****78');

    // key 空串 = 保持原 key（掩码不变）
    final p2 = await be.put('/settings/ai/llm', {
      'baseUrl': 'https://api2.example.com/v1',
      'model': 'gpt-4o',
      'apiKey': '',
    });
    expect(p2['keySet'], true);
    expect(p2['keyMasked'], 'sk-****78');

    // GET 读回
    final s1 = await be.get('/settings/ai');
    final llm1 = (s1 as Map)['llm'] as Map<String, dynamic>;
    expect(llm1['baseUrl'], 'https://api2.example.com/v1');
    expect(llm1['model'], 'gpt-4o');
    expect(llm1['keySet'], true);
    expect(llm1['keyMasked'], 'sk-****78');
  });

  test('流水线标志：首次 triggered=true，重复 false；未初始化防护', () async {
    await boot();
    final be = LocalBackend.instance;

    final t1 = await be.post('/pipeline/trigger', null);
    expect(t1['triggered'], true);
    final marker = File('${tmp.path}/corpus/.force_run');
    expect(marker.existsSync(), true);

    final t2 = await be.post('/pipeline/trigger', null);
    expect(t2['triggered'], false);

    // 未初始化 → StateError 防呆
    await LocalBackend.instance.resetForTest();
    expect(
      () => LocalBackend.instance.get('/health'),
      throwsStateError,
    );
  });

  test('通配守卫：/cards/search 不被 /cards/<id> 吞（具体路径优先）', () async {
    await boot();
    await seedCards();
    // /cards/search 若被通配吞掉会 404；正常应返回搜索结果
    final s = await LocalBackend.instance.get('/cards/search?q=龋病');
    expect((s as Map)['total'], greaterThanOrEqualTo(0));
    // /cards/pending 同理
    final p = await LocalBackend.instance.get('/cards/pending');
    expect(p.containsKey('list'), true);
  });

  // ---------------- #15 移除废卡 ----------------

  test('移除废卡 db 层（#15）：deleteCard——rejected 真删（卡行/备注/队列登记全清），active/pending/rework 拒删，不存在 not_found', () async {
    // 直连临时 SQLite（与 LocalBackend 不同的库文件，验证纯 db 契约）
    final db = await Db.open('${tmp.path}/delete-card.db');
    addTearDown(db.close);
    db.insertSubject(id: 'delsubj', name: '移除专项课');

    FlashCard card(String id, CardStatus status) => FlashCard(
          id: id,
          subjectId: 'delsubj',
          type: CardType.basic,
          front: '$id 题干',
          back: '$id 答案',
          anchor: '',
          source: 'delete card test',
          status: status,
        );

    // rejected 卡：拒绝带理由（正常登记 rework_queue）+ 用户备注——两者随卡全清
    db.importCard(card('del-rejected-001', CardStatus.pending));
    db.rejectCardWithReason('del-rejected-001', '答案有误', '');
    db.updateUserNote('del-rejected-001', '我写的备注');
    expect(db.cardById('del-rejected-001')!.status, CardStatus.rejected);
    expect(db.deleteCard('del-rejected-001'), null, reason: 'rejected 卡必须删除成功');
    expect(db.cardById('del-rejected-001'), null, reason: '物理删除后卡行必须消失');
    // cardNotes 契约：行删除后回空态常量（{'userNote':'', 'aiNote':''}）——
    // 备注已被清除（行不在），而非残留旧值
    final notesAfter = db.cardNotes('del-rejected-001');
    expect(notesAfter!['userNote'], '', reason: '备注行必须随卡清除（userNote 回空）');
    expect(notesAfter['aiNote'], '', reason: 'AI 留言行必须随卡清除（aiNote 回空）');
    final rqAfter = db.reworkPending();
    expect(rqAfter.where((r) => r['cardId'] == 'del-rejected-001'), isEmpty,
        reason: '拒绝登记的 rework_queue 行必须随卡删除');

    // 非 rejected 拒删（逐状态）：active / pending / rework
    db.importCard(card('del-active-001', CardStatus.active));
    expect(db.deleteCard('del-active-001'), 'not_rejected',
        reason: 'active 卡不得删除（仍在复习轮转）');
    expect(db.cardById('del-active-001'), isNotNull, reason: '拒删后卡行必须保留');

    db.importCard(card('del-pending-001', CardStatus.pending));
    expect(db.deleteCard('del-pending-001'), 'not_rejected',
        reason: 'pending 卡不得删除（审核池资产）');

    db.importCard(card('del-rework-001', CardStatus.active));
    db.reworkCard('del-rework-001', '表述绕', '');
    expect(db.deleteCard('del-rework-001'), 'not_rejected',
        reason: 'rework 卡不得删除（重造中）');

    // 不存在
    expect(db.deleteCard('ghost-404'), 'not_found');
  });

  test('移除废卡路由（#15）：/cards/delete 全分支——rejected 删除成功+bump、active/pending/rework 400 逐字、404 逐字、重复删除 404 幂等', () async {
    await boot();
    await seedCards();
    final be = LocalBackend.instance;

    // endo-001 拒绝带理由（pending → rejected + 登记队列）
    await be.post('/cards/local-endo-001/reject', {'reason': '答案有误'});
    final v0 = int.parse(
        (await be.get('/meta/version') as Map)['data_version'] as String);

    // rejected → 删除成功（ok + cardId + data_version 递增）
    final res = await be.post('/cards/delete', {'cardId': 'local-endo-001'});
    expect(res['ok'], true, reason: 'rejected 卡删除必须成功');
    expect(res['cardId'], 'local-endo-001');
    final v1 = int.parse(
        (await be.get('/meta/version') as Map)['data_version'] as String);
    expect(v1, v0 + 1, reason: '删除成功必须 bumpDataVersion（列表自动刷新依赖）');

    // 重复删除同 id → 404 同文案（幂等语义：卡行已不在 = 从未存在）
    await expectLater(
      be.post('/cards/delete', {'cardId': 'local-endo-001'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 404)
          .having((e) => e.message, 'message', '卡片不存在或已被移除')),
    );

    // 不存在 → 404 逐字
    await expectLater(
      be.post('/cards/delete', {'cardId': 'ghost-404'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 404)
          .having((e) => e.message, 'message', '卡片不存在或已被移除')),
    );

    // pending → 400 逐字
    await expectLater(
      be.post('/cards/delete', {'cardId': 'local-oms-002'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)
          .having((e) => e.message, 'message', '仅已拒绝的废卡可移除')),
    );

    // active → 400 逐字（approve oms-001 后对照）
    await be.post('/cards/local-oms-001/approve', null);
    await expectLater(
      be.post('/cards/delete', {'cardId': 'local-oms-001'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)
          .having((e) => e.message, 'message', '仅已拒绝的废卡可移除')),
    );

    // rework → 400 逐字（oms-001 回炉成重造中）
    await be.post('/cards/rework', {'cardId': 'local-oms-001', 'reason': '绕'});
    await expectLater(
      be.post('/cards/delete', {'cardId': 'local-oms-001'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)
          .having((e) => e.message, 'message', '仅已拒绝的废卡可移除')),
    );

    // 拒绝登记的队列行随卡删除：回炉队列不再出现该卡（其余卡不受影响）
    final rq = await be.get('/cards/rework/pending');
    final queue = ((rq as Map)['queue'] as List).cast<Map<String, dynamic>>();
    expect(queue.where((r) => r['cardId'] == 'local-endo-001'), isEmpty,
        reason: '被移除卡的拒绝登记行必须随卡清出队列');

    // 移除后的卡不可再回炉（404，文案不带 id）
    await expectLater(
      be.post('/cards/rework', {'cardId': 'local-endo-001', 'reason': '绕'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 404)
          .having((e) => e.message, 'message', '卡片不存在或已被移除')),
    );
  });

  test('#16 建库收尾罗盘初始化钩子：sidecar → progress.json 条目（幂等刷新保留进度）', () async {
    await boot();
    final be = LocalBackend.instance;

    // toc sidecar 预置（建库侧仅教材源 <短码>-textbook 产出；此处直写等效
    // 产物）+ 一个坏 sidecar（逐科目宁缺毋滥）
    final tocDir = Directory('${tmp.path}/corpus/toc')..createSync(recursive: true);
    File('${tocDir.path}/endo.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'subject': 'endo',
      'textbook': '世界通史-第2版',
      'chapters': [
        {'no': 1, 'title': '绪论', 'page_start': 1},
        {'no': 2, 'title': '第二章 启蒙思想', 'page_start': 20},
        {'no': 3, 'title': '第三章 龋病', 'page_start': 40},
      ],
      'sections': <Object?>[],
    }));
    File('${tocDir.path}/bad.json').writeAsStringSync('not-json{{{');

    // 假建库 job（真 spawn 姿势归 corpus_build_route/step04 系列；本钩子只
    // 关心「done 成功 → 收尾」时序——override 与真实链同走 _runCorpusBuildJob）
    addTearDown(() => LocalBackend.corpusBuildJobOverride = null);
    LocalBackend.corpusBuildJobOverride = (req) {
      final c = Completer<CorpusBuildResult>();
      c.complete(CorpusBuildResult(
        extract: const {'chunks': 3},
        ingest: const {'rows': 3},
        notes: const [],
        elapsedS: 0.01,
        inputPath: req.inputPath,
        corpusDbPath: req.corpusDbPath,
      ));
      return (
        progress: const Stream<IsolateProgressEvent>.empty(),
        done: c.future,
      );
    };

    // 触发建库 → 收尾钩子把 sidecar 转成罗盘条目
    final idle = be.corpusBuildState.firstWhere((s) => s['running'] == false);
    final trigger = await be.post('/corpus/build', {'mode': 'offline'});
    expect(trigger['triggered'], true);
    final frame = await idle.timeout(const Duration(seconds: 10));
    expect(frame['error'], isNull, reason: '假 job 成功收尾');

    final progressPath = '${tmp.path}/corpus/progress.json';
    final data = loadProgress(progressPath);
    final entry = progressEntryOf(data, 'endo');
    expect(entry, isNotNull, reason: '建库成功后罗盘条目自动生成（语料入库后自动生成）');
    expect(entry!['textbook'], '世界通史-第2版');
    expect((entry['chapters'] as List).length, 3);
    expect(entry['learned_through'], 0, reason: '新条目全 0 起步');
    expect((entry['history'] as List), isEmpty);
    expect((data['subjects'] as Map).containsKey('bad'), false,
        reason: '坏 sidecar 科目跳过，不株连同目录好科目');

    // 幂等：手动推进后再建库 → 刷新语义保留进度与历史（绝不回拨）
    setSubjectNo(data, 'endo', 2);
    saveProgress(progressPath, data);
    final idle2 = be.corpusBuildState.firstWhere((s) => s['running'] == false);
    await be.post('/corpus/build', {'mode': 'offline'});
    await idle2.timeout(const Duration(seconds: 10));
    final data2 = loadProgress(progressPath);
    final entry2 = progressEntryOf(data2, 'endo');
    expect(entry2!['learned_through'], 2, reason: '刷新保留进度（不回拨）');
    expect((entry2['history'] as List).length, 1, reason: '刷新保留历史');
    expect(entry2['textbook'], '世界通史-第2版');

    // 无 toc 目录环境：钩子静默空转（不炸、不产 progress.json）
    final noTocTmp = Directory.systemTemp.createTempSync('hengya_no_toc_');
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(noTocTmp.path);
    final idle3 =
        LocalBackend.instance.corpusBuildState.firstWhere((s) => s['running'] == false);
    await LocalBackend.instance.post('/corpus/build', {'mode': 'offline'});
    await idle3.timeout(const Duration(seconds: 10));
    expect(File('${noTocTmp.path}/corpus/progress.json').existsSync(), false,
        reason: '无 sidecar → 不产罗盘（宁缺毋滥）');
    // 清理（先关连接再删——addTearDown 时序在套件级 resetForTest 之前，Db
    // 句柄未放会造成 errno 32 删除失败；套件级 tearDown 会再 reset 一次幂等）
    await LocalBackend.instance.resetForTest();
    try {
      await noTocTmp.delete(recursive: true);
    } catch (_) {}
  });
}
