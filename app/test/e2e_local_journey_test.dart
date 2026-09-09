// local 模式用户旅程 E2E（2026-09-06）：一镜到底走完产品主流程——
// 冷启动自检 → 导入生产快照（迁移主通道）→ 复习会话评分（FSRS 推进/日志/版本 bump）
// → 新建课程 → 拆卡审批全生命周期（批准→评分→拒绝→回炉→重造→再批→again 循环）
// → 收件箱关键词 → 题库搜索/单卡详情/备注 → 统计五路 → 罗盘与语料边界
// （corpus 空态优雅不炸/课件上传/流水线标志）→ AI 配置掩码往返
// → 导出→换机再导入（往返完整性）→ 48h 自动备份链。
//
// 与 local_backend_test.dart（单用例逐路由）互补：本测试验证「整条旅程」
// 的状态连续性——上一环节的产物是下一环节的输入，任一环节断裂即失败。
// 生产快照基线（开源脱敏 2026-09-06 起为合成库：test/helpers/
// synthetic_snapshot.dart 测试期生成，替代原真实快照二进制）：21 卡
//（13 active/7 rejected/1 rework/0 pending）+ 12 复习日志（日期相对
// now，滑动窗口断言永不失效）+ 8 科（含用户自建风格 demo1234）
// + data_version 78。
//
// 宿主基建：同 local_backend_test.dart——Windows 测试宿主显式加载
// test/sqlite3.dll（sqlite3 2.4.0 + overrideForAll；python 自带 dll 不可用，
// 见该文件头部教训注释）。
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/data_manager.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

import 'helpers/synthetic_snapshot.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
        () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  late Directory tmp;
  final be = LocalBackend.instance;
  final dm = DataManager.instance;
  // 合成快照路径（setUp 期生成于 tmp 内；开源脱敏，2026-09-06）
  late String snapshotPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hengya_journey_');
    snapshotPath = await writeSyntheticSnapshot(tmp.path);
    await be.resetForTest();
    be.init(tmp.path);
  });

  tearDown(() async {
    await be.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('用户旅程全流程：迁移→复习→审批生命周期→收件箱→题库→统计→导出往返→备份',
      () async {
    // ── ① 冷启动自检：新库零科目（0.3.1 开源去内置），data_version 初始 '0' ──
    final health = await be.get('/health');
    expect((health as Map)['status'], 'ok');
    final subs0 = await be.get('/subjects');
    final fresh = (subs0['subjects'] as List).cast<Map<String, dynamic>>();
    expect(fresh, isEmpty); // 无内置播种：科目全部用户自建
    expect(fresh.every((s) => s['dueCount'] == 0), true);
    final meta0 = await be.get('/meta/version');
    expect((meta0 as Map)['data_version'], '0');

    // ── ② 导入生产快照：先只读预览，再原子替换，生产数据全可见 ──
    final preview = dm.validateSource(snapshotPath);
    expect(preview['cards'], 21);
    expect(preview['activeCards'], 13);
    expect(preview['reviewLogs'], 12);
    expect(preview['subjects'], 8);
    expect(preview['dataVersion'], '78');
    final imported = await dm.importDatabase(
      tmp.path,
      snapshotPath,
      onBeforeSwap: () => be.reload(),
    );
    expect((imported as Map)['cards'], 21);
    final subs1 = await be.get('/subjects');
    final ids1 = (subs1['subjects'] as List)
        .cast<Map<String, dynamic>>()
        .map((s) => s['id']);
    expect(ids1.length, 8);
    expect(ids1, contains('demo1234')); // 用户自建风格科目随迁（合成）
    final bank0 = await be.get('/cards/search?limit=200');
    expect((bank0 as Map)['total'], 21); // search 只排 pending：13+7+1 全可查
    final meta1 = await be.get('/meta/version');
    expect((meta1 as Map)['data_version'], '78'); // data_version 随迁

    // ── ③ 复习会话：评分一张生产到期卡（FSRS 推进 + 日志 + 版本 bump）──
    final q0 = await be.get('/cards/queue?subject=oms');
    final dueCards = (q0['cards'] as List).cast<Map<String, dynamic>>();
    expect(dueCards, isNotEmpty);
    final rated = dueCards.first['id'] as String;
    final ans0 = await be.post('/review/answer', {
      'cardId': rated,
      'rating': 'good',
      'reviewedAt': DateTime.now().toIso8601String(),
    });
    expect((ans0 as Map)['applied'], 1);
    final r0 = (ans0['results'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((r) => r['cardId'] == rated);
    expect(r0['ok'], true);
    expect((r0['intervalDays'] as num), greaterThan(0));
    final q1 = await be.get('/cards/queue?subject=oms');
    final idsQ1 =
        (q1['cards'] as List).cast<Map<String, dynamic>>().map((c) => c['id']);
    expect(idsQ1, isNot(contains(rated))); // 评分后 due 推远，队列让位
    final summary0 = await be.get('/stats/summary');
    expect((summary0 as Map)['totalReviews'], 13); // 12 历史日志 + 本次
    final meta2 = await be.get('/meta/version');
    expect(int.parse((meta2 as Map)['data_version'] as String),
        greaterThan(78)); // 写操作 bump

    // ── ④ 新建课程（用户旅程：自建科目）──
    final created = await be.post('/subjects', {'name': '全流程测试课'});
    expect((created as Map)['ok'], true);
    expect((created['id'] as String).length, 8); // 自动 8 位短码

    // ── ⑤ 拆卡审批全生命周期 ──
    final seeded = await be.importCards([
      {
        'id': 'journey-new-001', 'subjectId': 'oms', 'type': 'basic',
        'front': '旅程新卡题干', 'back': '旅程新卡答案',
        'anchor': 'e2e', 'source': '旅程测试', 'status': 'pending',
      },
      {
        'id': 'journey-rework-001', 'subjectId': 'oms', 'type': 'basic',
        'front': '将被拒绝的原题干', 'back': '原答案',
        'anchor': 'e2e', 'source': '旅程测试', 'status': 'pending',
      },
    ]);
    expect((seeded as Map)['inserted'], 2);
    final pend1 = await be.get('/cards/pending');
    expect((pend1['list'] as List).length, 2); // 生产快照 0 pending
    // 批准 new-001 → 状态守卫（再批 400）→ 评分 good
    await be.post('/cards/journey-new-001/approve', null);
    await expectLater(
      be.post('/cards/journey-new-001/approve', null),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)),
    );
    final ans1 = await be.post('/review/answer', {
      'cardId': 'journey-new-001',
      'rating': 'good',
      'reviewedAt': DateTime.now().toIso8601String(),
    });
    expect((ans1 as Map)['applied'], 1);
    // 拒绝 rework-001 带理由 → 回炉队列（拒绝只移除该卡）
    await be.post('/cards/journey-rework-001/reject',
        {'reason': '答案不完整', 'note': '旅程批注'});
    final pend2 = await be.get('/cards/pending');
    expect((pend2['list'] as List), isEmpty);
    final rq1 = await be.get('/cards/rework/pending');
    final rqItem = (rq1['queue'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((i) => i['cardId'] == 'journey-rework-001');
    expect(rqItem['reason'], contains('答案不完整'));
    // 重造完成 → 回待审池（新内容生效）
    final done = await be.post('/cards/rework/${rqItem['id']}/done',
        {'front': '重写后的题干', 'back': '重写后的答案'});
    expect((done as Map)['ok'], true);
    final pend3 = await be.get('/cards/pending');
    final backCard = (pend3['list'] as List).cast<Map<String, dynamic>>().single;
    expect(backCard['id'], 'journey-rework-001');
    expect(backCard['front'], '重写后的题干');
    // 再批 → 评分 again → 重学步：due 推到 ~10 分钟后的近未来（今日内重见）。
    // 注意：again 后 due 在未来而非当下——queue（due<=now）不含它，
    // 卡详情 dueAt 与今日 forecast 才是正确观察点（对照 FSRS 学习步语义；
    // 2026-09-06 实测：queue 此刻只含未评分的其他生产到期卡）。
    await be.post('/cards/journey-rework-001/approve', null);
    final ans2 = await be.post('/review/answer', {
      'cardId': 'journey-rework-001',
      'rating': 'again',
      'reviewedAt': DateTime.now().toIso8601String(),
    });
    expect((ans2 as Map)['applied'], 1);
    final againDetail = await be.get('/cards/journey-rework-001');
    final dueAt = DateTime.parse((againDetail as Map)['dueAt'] as String);
    final now = DateTime.now();
    expect(dueAt.isAfter(now), true); // 未来：10 分钟级重学步
    expect(dueAt.isBefore(now.add(const Duration(hours: 1))), true);

    // ── ⑥ 收件箱：关键词入箱 → 拉取 → consume 清空 ──
    final inbox = await be.post('/inbox/keywords', [
      {'subjectId': 'oms', 'keyword': '旅程关键词', 'source': 'e2e-journey'},
    ]);
    expect((inbox as Map)['inserted'], 1);
    final ip = await be.get('/inbox/pending');
    final kw = (ip['list'] as List).cast<Map<String, dynamic>>().single;
    expect(kw['keyword'], '旅程关键词');
    final consumed = await be.post('/inbox/consume', {'ids': [kw['id']]});
    expect((consumed as Map)['consumed'], 1);

    // ── ⑦ 题库搜索 + 单卡详情 + 备注 ──
    final bank = await be.get('/cards/search?limit=200');
    expect((bank as Map)['total'], 23); // 21 生产 + 2 旅程，pending 已清零
    final hit = await be.get('/cards/search?q=重写后的题干');
    expect((hit as Map)['total'], 1);
    final detail = await be.get('/cards/journey-new-001');
    expect((detail as Map)['id'], 'journey-new-001');
    expect(detail.containsKey('dueAt'), true);
    await be.post('/cards/journey-new-001/notes', {'userNote': '旅程备注'});
    final note = await be.get('/cards/journey-new-001/notes');
    expect((note as Map)['userNote'], '旅程备注');

    // ── ⑧ 统计五路有料 ──
    final streak = await be.get('/stats/streak');
    expect((streak as Map)['streak'], greaterThanOrEqualTo(1));
    final heatmap = await be.get('/stats/heatmap');
    expect((heatmap as Map)['byDay'], isNotEmpty);
    final forecast = await be.get('/stats/forecast?days=7');
    expect(((forecast as Map)['list'] as List).length, 7);
    final summary = await be.get('/stats/summary');
    expect((summary as Map)['totalReviews'], 15); // 12 + good + good + again
    final retention = await be.get('/stats/retention');
    expect(((retention as Map)['windows'] as List), isNotEmpty);

    // ── ⑨ 罗盘与语料边界：corpus 未导入 → 优雅空态不炸（Phase 3/4 前的预期态）──
    final progress = await be.get('/progress');
    expect((progress as Map)['subjects'], isEmpty);
    expect(progress['updated_at'], isNull);
    final cs0 = await be.get('/corpus/status');
    expect((cs0 as Map)['totalChunks'], 0);
    expect(cs0['pendingFiles'], 0);
    // 课件上传 → incoming 落盘 + pending 计数（PK 魔数校验通过）
    final up = await be.upload(
        '/corpus/upload?subject=oms&filename=%E6%97%85%E7%A8%8B.pptx',
        [0x50, 0x4B, 0x03, 0x04]);
    expect((up as Map)['received'], 4);
    final cs1 = await be.get('/corpus/status');
    expect((cs1 as Map)['pendingFiles'], 1);
    expect(File('${tmp.path}/corpus/incoming/oms/旅程.pptx').existsSync(),
        true);
    // 流水线标志（Phase 4 消费）：首次 true，重复幂等 false
    final trig = await be.post('/pipeline/trigger', null);
    expect((trig as Map)['triggered'], true);
    final trig2 = await be.post('/pipeline/trigger', null);
    expect((trig2 as Map)['triggered'], false);

    // ── ⑩ AI 配置掩码往返 ──
    final put = await be.put('/settings/ai/llm', {
      'baseUrl': 'https://api.journey-test.com/v1',
      'model': 'e2e-model',
      'apiKey': 'sk-journey12345678',
    });
    expect((put as Map)['keySet'], true);
    expect(put['keyMasked'], 'sk-****78');
    final ai = await be.get('/settings/ai');
    final llm = (ai as Map)['llm'] as Map<String, dynamic>;
    expect(llm['baseUrl'], 'https://api.journey-test.com/v1');
    expect(llm['model'], 'e2e-model');
    expect(llm['keyMasked'], 'sk-****78');

    // ── ⑪ 导出 → 换机再导入：往返完整性（用户换机/迁移第二通道）──
    final metaV = await be.get('/meta/version');
    final v = (metaV as Map)['data_version'] as String;
    expect(int.parse(v), greaterThan(78)); // 旅程写入已多次 bump
    final out = dm.exportDatabase(tmp.path);
    expect(File(out).existsSync(), true);
    final exported = dm.validateSource(out);
    expect(exported['cards'], 23);
    expect(exported['reviewLogs'], 15);
    expect(exported['subjects'], 9); // 8 快照（含 demo1234）+ 全流程测试课
    expect(exported['dataVersion'], v);
    final tmp2 = await Directory.systemTemp.createTemp('hengya_journey2_');
    addTearDown(() async {
      await be.resetForTest();
      try {
        await tmp2.delete(recursive: true);
      } catch (_) {}
    });
    await dm.importDatabase(tmp2.path, out);
    await be.resetForTest();
    be.init(tmp2.path);
    final subs2 = await be.get('/subjects');
    final ids2 = (subs2['subjects'] as List)
        .cast<Map<String, dynamic>>()
        .map((s) => s['id']);
    expect(ids2.length, 9);
    expect(ids2, contains('demo1234'));
    final bank2 = await be.get('/cards/search?limit=200');
    expect((bank2 as Map)['total'], 23);
    final metaV2 = await be.get('/meta/version');
    expect((metaV2 as Map)['data_version'], v); // 版本号往返保持
    final streak2 = await be.get('/stats/streak');
    expect((streak2 as Map)['streak'], greaterThanOrEqualTo(1));

    // ── ⑫ 48h 自动备份链（回到原机数据目录；备份按文件 mtime 判断）──
    expect(dm.autoBackupIfNeeded(tmp.path), true); // 首调备份
    expect(dm.backupsOf(tmp.path).length, 1);
    expect(dm.autoBackupIfNeeded(tmp.path), false); // 48h 内二调跳过
  });
}
