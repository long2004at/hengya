// 演示模式验证（DEMO=1 编译注入）：
// 内存后端全流程真实流转——审批/评分/回炉在无服务器下闭环
// 注意：flutter test 无法注入 --dart-define，此测试验证 DemoBackend 类本身；
// 端到端由 debug APK 手动验收。
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/api/demo_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('演示后端：科目+到期数+待审池种子完整', () async {
    final subs = await DemoBackend.instance.get('/subjects');
    final list = subs['subjects'] as List;
    expect(list.length, 4);
    final hist = list.firstWhere((s) => (s as Map)['id'] == 'hist');
    expect(hist['dueCount'], 2); // 001/002 到期，003 在 3 天后
    final pending = await DemoBackend.instance.get('/cards/pending');
    expect((pending['list'] as List).length, 3); // 种子待审 3 张
  });

  test('演示后端：审批 → 队列可见；评分 → FSRS 调度推进', () async {
    await DemoBackend.instance
        .post('/cards/demo-new-002/approve', null);
    final q = await DemoBackend.instance.get('/cards/queue?subject=hist');
    final ids =
        ((q['cards'] as List).cast<Map<String, dynamic>>()).map((c) => c['id']);
    expect(ids, contains('demo-new-002'));

    final res = await DemoBackend.instance.post('/review/answer', {
      'cardId': 'demo-new-002',
      'rating': 'good',
      'reviewedAt': DateTime(2026, 9, 4, 11, 0).toIso8601String(),
    });
    final results = (res['results'] as List).cast<Map<String, dynamic>>();
    expect(res['applied'], 1);
    expect(results.first['state'], 'review');
    expect(results.first['intervalDays'], greaterThan(0));
  });

  test('演示后端：回炉登记 → 待审池减员流转', () async {
    final before = await DemoBackend.instance.get('/cards/pending');
    final nBefore = (before['list'] as List).length;

    await DemoBackend.instance.post('/cards/rework', {
      'cardId': 'demo-hist-001',
      'reason': '表述绕',
      'note': '测试',
    });
    final after = await DemoBackend.instance.get('/cards/pending');
    expect((after['list'] as List).length, nBefore); // 回炉的是 active 卡不影响待审数

    final rq = await DemoBackend.instance.get('/cards/rework/pending');
    final items = (rq['queue'] as List).cast<Map<String, dynamic>>();
    expect(items.length, 1);
    expect(items.first['cardId'], 'demo-hist-001');

    // 重造完成 → 回待审池
    await DemoBackend.instance.post('/cards/rework/1/done',
        {'front': '重写后的题干', 'back': '重写后的答案'});
    final after2 = await DemoBackend.instance.get('/cards/pending');
    expect((after2['list'] as List).length, nBefore + 1);
  });

  test('演示后端：统计四路有料（streak/heatmap/forecast/summary）', () async {
    final streak = await DemoBackend.instance.get('/stats/streak');
    expect(streak['streak'], greaterThan(0));

    final heatmap = await DemoBackend.instance.get('/stats/heatmap');
    expect((heatmap['byDay'] as List), isNotEmpty);

    final forecast = await DemoBackend.instance.get('/stats/forecast');
    final days = (forecast['list'] as List).cast<Map<String, dynamic>>();
    expect(days.length, 7);
    expect(days.first['due'], greaterThan(0));

    final summary = await DemoBackend.instance.get('/stats/summary');
    expect(summary['totalReviews'], greaterThan(0));
    expect(summary['pendingInbox'], 2); // 种子收件箱 2 条
  });

  test('演示后端：leech 榜有种子（lapse=4 的病例卡）', () async {
    final res = await DemoBackend.instance.get('/cards/leech');
    final cards = (res['cards'] as List).cast<Map<String, dynamic>>();
    expect(cards.any((c) => c['id'] == 'demo-chem-002'), isTrue);
  });

  test('演示后端：关键词入箱计数递增', () async {
    final before = await DemoBackend.instance.get('/inbox/pending');
    final n = (before['list'] as List).length;
    await DemoBackend.instance.post('/inbox/keywords',
        {'subjectId': 'hist', 'keyword': '演示入箱', 'source': 'app'});
    final after = await DemoBackend.instance.get('/inbox/pending');
    expect((after['list'] as List).length, n + 1);
  });

  test('演示后端：路由前缀归一化（/api/v1/xxx ≡ /xxx）', () async {
    // ApiClient 实际调用形态（带 /api/v1 前缀）必须与裸路径等价
    final viaPrefix = await DemoBackend.instance.get('/api/v1/subjects');
    final bare = await DemoBackend.instance.get('/subjects');
    expect((viaPrefix['subjects'] as List).length,
        (bare['subjects'] as List).length);

    final ok = await DemoBackend.instance.post(
      '/api/v1/inbox/keywords',
      {'subjectId': 'hist', 'keyword': '前缀归一化', 'source': 'app'},
    );
    expect(ok['ok'], isTrue);
  });

  test('演示后端：题库检索只含非 pending，支持全文匹配', () async {
    final r = await DemoBackend.instance.get('/cards/search');
    final cards = r['cards'] as List;
    expect(cards, isNotEmpty);
    // 种子里 pending 的卡不出现在题库
    expect(
      cards.where((c) => (c as Map)['status'] == 'pending'),
      isEmpty,
    );
    // 全文匹配：题干关键词
    final hit = await DemoBackend.instance.get('/cards/search?q=定义');
    expect((hit['cards'] as List), isNotEmpty);
    // 无关词
    final miss = await DemoBackend.instance.get('/cards/search?q=不存在词组');
    expect(miss['total'], 0);
  });

  test('演示后端：备注与 AI 留言 upsert + 拒绝理由入回炉队列', () async {
    final search = await DemoBackend.instance.get('/cards/search');
    final id = ((search['cards'] as List).first as Map)['id'] as String;
    // 更新备注
    final res = await DemoBackend.instance
        .post('/cards/$id/notes', {'userNote': '口诀：外+颌面'});
    expect(res['userNote'], '口诀：外+颌面');
    final got = await DemoBackend.instance.get('/cards/$id/notes');
    expect(got['userNote'], '口诀：外+颌面');
    // AI 留言独立更新
    await DemoBackend.instance
        .post('/cards/$id/notes', {'aiNote': '希望拆细一点'});
    final got2 = await DemoBackend.instance.get('/cards/$id/notes');
    expect(got2['aiNote'], '希望拆细一点');
    expect(got2['userNote'], '口诀：外+颌面'); // 不被覆盖
  });

  // ---------------- M4.1 单卡查询（题库详情页直取） ----------------

  test('演示后端：单卡查询返回同构字段（dueAt/reps/lapses/userNote/aiNote 齐全）', () async {
    final card = await DemoBackend.instance.get('/cards/demo-hist-001');
    expect(card['id'], 'demo-hist-001');
    // FlashCard 同构字段
    expect(card['subjectId'], 'hist');
    expect(card['type'], 'basic');
    expect(card['front'], isNotEmpty);
    expect(card['back'], isNotEmpty);
    expect(card['anchor'], isNotEmpty);
    expect(card['source'], isNotEmpty);
    expect(card['sourceTier'], isNotNull);
    expect(card['status'], isNotNull);
    expect(card['tags'], isA<List<dynamic>>());
    // 与 /cards/search 条目同构的扩展字段（无记录时空串/0）
    expect(card['dueAt'], isA<String>());
    expect(card['reps'], isA<int>());
    expect(card['lapses'], isA<int>());
    expect(card['userNote'], isA<String>());
    expect(card['aiNote'], isA<String>());
  });

  test('演示后端：单卡与 /cards/search 条目深度同构 + 备注联动', () async {
    // demo-chem-001 未被前面用例改状态（仍 active，出现在 search 里）
    await DemoBackend.instance
        .post('/cards/demo-chem-001/notes', {'userNote': '单卡测试备注'});
    final single = await DemoBackend.instance.get('/cards/demo-chem-001');
    expect(single['userNote'], '单卡测试备注'); // 与 notes 写入同一数据源
    final search = await DemoBackend.instance.get('/cards/search');
    final entry = (search['cards'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((c) => c['id'] == 'demo-chem-001');
    expect(single, equals(entry)); // 逐字段深度相等（同构契约）
  });

  test('演示后端：单卡路由不吞具体路径（注册顺序回归）', () async {
    // <id> 通配若排在前面会吞掉这些路由（含 query 段也不含「/」）——全部必须仍走原处理
    final pending = await DemoBackend.instance.get('/cards/pending');
    expect(pending['list'], isA<List<dynamic>>());
    final search = await DemoBackend.instance.get('/cards/search?q=定义');
    expect(search['cards'], isA<List<dynamic>>());
    final queue = await DemoBackend.instance.get('/cards/queue?subject=hist');
    expect(queue['cards'], isA<List<dynamic>>());
    final leech = await DemoBackend.instance.get('/cards/leech');
    expect(leech['cards'], isA<List<dynamic>>());
    final rework = await DemoBackend.instance.get('/cards/rework/pending');
    expect(rework['queue'], isA<List<dynamic>>());
  });

  test('演示后端：单卡查询不存在 → ApiException(404)', () async {
    await expectLater(
      DemoBackend.instance.get('/cards/不存在id'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.message, 'message', '卡不存在')),
    );
  });

  test('演示后端：移除废卡（#15）——/cards/delete 仅 rejected 可删、再删同 id 404；rework 404 文案对齐（不带 id）', () async {
    // 造 rejected：从当前待审池取一张 reject（带理由 → 同步登记回炉队列）
    final before = await DemoBackend.instance.get('/cards/pending');
    final pendingList = (before['list'] as List).cast<Map<String, dynamic>>();
    expect(pendingList, isNotEmpty, reason: '待审池必须有卡可拒绝（种子流转）');
    final target = pendingList.first['id'] as String;
    await DemoBackend.instance.post('/cards/$target/reject', {'reason': '答案有误'});
    // 队列登记 + 备注先行写入：两者都应随卡清除
    await DemoBackend.instance
        .post('/cards/$target/notes', {'userNote': '随卡删除的备注'});
    final rq0 = await DemoBackend.instance.get('/cards/rework/pending');
    final q0 = ((rq0 as Map)['queue'] as List).cast<Map<String, dynamic>>();
    expect(q0.any((r) => r['cardId'] == target), true,
        reason: '拒绝带理由必须登记回炉队列（种子拒绝反馈通道）');

    // rejected → 删除成功
    final res =
        await DemoBackend.instance.post('/cards/delete', {'cardId': target});
    expect(res['ok'], true);
    expect(res['cardId'], target);
    // 队列登记行随卡清出
    final rq1 = await DemoBackend.instance.get('/cards/rework/pending');
    final q1 = ((rq1 as Map)['queue'] as List).cast<Map<String, dynamic>>();
    expect(q1.any((r) => r['cardId'] == target), false,
        reason: '被移除卡的队列登记行必须清除');
    // 卡不可再查（404）
    await expectLater(
      DemoBackend.instance.get('/cards/$target'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 404)),
    );

    // 再删同 id → 404 幂等（文案对齐 local，不带 id）
    await expectLater(
      DemoBackend.instance.post('/cards/delete', {'cardId': target}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.message, 'message', '卡片不存在或已被移除')),
    );

    // 非 rejected → 400 逐字（demo-hist-002 全程未被流转，恒 active）
    await expectLater(
      DemoBackend.instance.post('/cards/delete', {'cardId': 'demo-hist-002'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 400)
          .having((e) => e.message, 'message', '仅已拒绝的废卡可移除')),
    );

    // rework 404 文案对齐 local（不带 id）
    await expectLater(
      DemoBackend.instance
          .post('/cards/rework', {'cardId': 'demo-ghost-404', 'reason': '绕'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.message, 'message', '卡片不存在或已被移除')),
    );
  });
}
