// 每日计划数据层与后端验证（local-first）：目标存储往返、跨科目今日队列、
// 今日进度唯一口径（goal/done/dueTotal/remainingToday）、目标截断、
// done>=goal 队列空、跨自然日边界（昨天的账本行不计入今天）。
//
// 与 local_backend_test.dart 同姿势：直调 LocalBackend.instance.get/put，
// 数据经 importCards + activateCard 种入临时 SQLite 文件，跨用例隔离；
// 评分日志经 POST /review/answer 真实流转产生（reviewed_at 由用例注入）。
// Windows 测试宿主 sqlite3.dll 加载纪律见 local_backend_test.dart 头注释。
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/services/api/api_client.dart' show ApiException;
import 'package:hengya/services/local/local_backend.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Windows 测试宿主：显式加载 test/sqlite3.dll（CWD = 包根 app/）
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hengya_daily_test_');
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

  /// 两科目 + 每科 N 张 pending 卡 → 审核激活（active 且 m_due_at=now，
  /// 全部立即到期）。卡 id 前缀 <科目>-<序号>。
  Future<void> seedActiveCards(int perSubject) async {
    await LocalBackend.instance.post('/subjects', {'name': '科目A', 'id': 'aa'});
    await LocalBackend.instance.post('/subjects', {'name': '科目B', 'id': 'bb'});
    for (var i = 1; i <= perSubject; i++) {
      final res = await LocalBackend.instance.importCards([
        {
          'id': 'aa-$i',
          'subjectId': 'aa',
          'type': 'basic',
          'front': 'A 科目第 $i 张卡',
          'back': '答案 $i',
          'anchor': '测试锚点 A$i',
          'source': '测试',
          'status': 'pending',
        },
        {
          'id': 'bb-$i',
          'subjectId': 'bb',
          'type': 'basic',
          'front': 'B 科目第 $i 张卡',
          'back': '答案 $i',
          'anchor': '测试锚点 B$i',
          'source': '测试',
          'status': 'pending',
        },
      ]);
      expect(res['inserted'], 2, reason: '每轮两张新卡应插入：$res');
      await LocalBackend.instance.post('/cards/aa-$i/approve', null);
      await LocalBackend.instance.post('/cards/bb-$i/approve', null);
    }
  }

  /// 评分一张卡（真实流转：调度状态 + review_logs 一并写入；
  /// reviewedAt 由调用方注入以控制自然日归属）。
  Future<void> answerCard(
    String cardId, {
    required DateTime reviewedAt,
  }) async {
    final res = await LocalBackend.instance.post('/review/answer', {
      'cardId': cardId,
      'rating': 'smooth',
      'reviewedAt': reviewedAt.toIso8601String(),
    });
    final results = res['results'] as List;
    expect(
      (results.first as Map)['ok'],
      true,
      reason: '评分 $cardId 应成功：$results',
    );
  }

  test('PUT/GET 设置往返：写入读回一致，超界 400，未设置默认 50', () async {
    await boot();
    // 未设置 → 默认 50（范围 10-500 由后端兜底）
    final initial = await LocalBackend.instance.get('/settings/daily');
    expect(initial['goal'], 50);
    expect(initial['min'], 10);
    expect(initial['max'], 500);

    await LocalBackend.instance.put('/settings/daily', {'goal': 120});
    final after = await LocalBackend.instance.get('/settings/daily');
    expect(after['goal'], 120);

    // 超界：契约层硬校验 400
    for (final bad in [9, 501]) {
      await expectLater(
        LocalBackend.instance.put('/settings/daily', {'goal': bad}),
        throwsA(
          isA<ApiException>().having(
            (e) => e.statusCode,
            'statusCode',
            400,
          ),
        ),
      );
    }
  });

  test('/stats/today：四字段唯一口径，今日完成计入 done，昨日不计入', () async {
    await boot();
    await seedActiveCards(10);
    await LocalBackend.instance.put('/settings/daily', {'goal': 10});

    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    // 今天答 2 张 + 昨天答 1 张（跨自然日边界：昨天的不计入 done）
    await answerCard('aa-1', reviewedAt: now);
    await answerCard('aa-2', reviewedAt: now);
    await answerCard('bb-1', reviewedAt: yesterday);

    final today = await LocalBackend.instance.get('/stats/today');
    expect(today['goal'], 10);
    expect(today['done'], 2, reason: '昨天的账本行不计入今天（自然日边界）');
    expect(today['dueTotal'], 17,
        reason: '答过的 3 张卡（smooth 毕业，间隔>0）已移出到期池：20-3');
    expect(today['remainingToday'], 8, reason: 'clamp(10-2, 0, 17) = 8');
  });

  test('/cards/queue/today：跨科目合并全局到期升序，截断为 remainingToday', () async {
    await boot();
    await seedActiveCards(6);
    await LocalBackend.instance.put('/settings/daily', {'goal': 10});

    final res = await LocalBackend.instance.get('/cards/queue/today');
    final cards = (res['cards'] as List).cast<Map<String, dynamic>>();
    expect(cards.length, 10, reason: '目标 10 截断（到期共 12 张）');
    expect(res['goal'], 10);
    expect(res['doneToday'], 0);
    expect(res['dueTotal'], 12);
    expect(res['remainingToday'], 10);

    // 跨科目合并 + 全局 m_due_at 升序：两科 activateCard 用同一 now，
    // 到期时间戳相同 → 允许任一稳定序，但必须是「各科头部卡」而非单科连排
    final ids = cards.map((c) => c['id'] as String).toSet();
    expect(ids, containsAll(['aa-1', 'bb-1']), reason: '两科都应进今日队列');
  });

  test('/cards/queue/today：done>=goal 时队列空（今日已完成计入 doneToday）', () async {
    await boot();
    await seedActiveCards(5);
    await LocalBackend.instance.put('/settings/daily', {'goal': 10});

    final now = DateTime.now();
    for (var i = 1; i <= 5; i++) {
      await answerCard('aa-$i', reviewedAt: now);
      await answerCard('bb-$i', reviewedAt: now);
    }

    final res = await LocalBackend.instance.get('/cards/queue/today');
    expect(res['doneToday'], 10);
    expect(res['remainingToday'], 0, reason: 'clamp(10-10, 0, dueTotal) = 0');
    expect((res['cards'] as List), isEmpty, reason: 'done>=goal 队列空');
  });

  test('/cards/queue/today 优先于 /cards/queue 前缀匹配：不因缺 subject 报 400', () async {
    await boot();
    // 回归哨兵：/cards/queue 的 startsWith 匹配若吞掉 today 路径，
    // 这里会抛「缺少 subject 参数」400 而非返回今日计划视图
    final res = await LocalBackend.instance.get('/cards/queue/today');
    expect(res.containsKey('cards'), true);
    expect(res.containsKey('goal'), true);
    expect(res.containsKey('remainingToday'), true);
  });

  test('跨自然日边界：reviewed_at 为昨天 → 不计入今天 done', () async {
    await boot();
    await seedActiveCards(2);
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    // 三条昨日记录（昨天答满目标）+ 今天零条
    await answerCard('aa-1', reviewedAt: yesterday);
    await answerCard('aa-2', reviewedAt: yesterday);
    await answerCard('bb-1', reviewedAt: yesterday);

    final today = await LocalBackend.instance.get('/stats/today');
    expect(today['done'], 0, reason: '昨日记录不跨入今天（日期前缀边界比较）');
    final queue = await LocalBackend.instance.get('/cards/queue/today');
    expect((queue['cards'] as List).length, queue['remainingToday'],
        reason: '今日额度未被昨天消耗');
  });
}
