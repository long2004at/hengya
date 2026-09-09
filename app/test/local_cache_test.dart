// 离线缓存服务与 api_client 透明回退单测（问1+5）：
//   · LocalCache 读写往返（内存/SharedPreferences 两种持久层）+ 坏数据静默
//   · 缓存结构红线：只含 {savedAt, data}，token/Authorization 绝不入缓存
//   · api_client：成功→异步写缓存且旁路元信息为空（新鲜）；断网→缓存命中
//     且旁路元信息标记「来自缓存」；4xx 有缓存也不回退；无缓存维持原错误；
//     坏缓存自清
//   · 复习队列持久化恢复（fetchQueue 断网回退同一批卡）
//
// 测试基建：真实 HttpServer（同 api_contract_test.dart）——断网用「关掉服务器」
// 模拟（连接拒绝 → SocketException），全程可复现。
import 'dart:convert';
import 'dart:io';

import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/api/local_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late HttpServer server;
  late InMemoryCacheStore cacheStore;
  var progress404 = false; // /progress 模拟服务端行为开关

  Future<void> handle(HttpRequest req) async {
    final res = req.response;
    res.headers.contentType = ContentType.json;
    final path = req.uri.path;
    if (path == '/api/v1/subjects' && req.method == 'GET') {
      res.write(
        jsonEncode({
          'subjects': [
            {'id': 'oms', 'name': '世界历史', 'dueCount': 2},
            {'id': 'endo', 'name': '基础化学', 'dueCount': 3},
          ],
        }),
      );
    } else if (path == '/api/v1/stats/streak') {
      res.write(jsonEncode({'streak': 7}));
    } else if (path == '/api/v1/stats/summary') {
      res.write(
        jsonEncode({
          'totalReviews': 12,
          'againRate': 0.1,
          'pendingCards': 4,
          'pendingInbox': 1,
        }),
      );
    } else if (path == '/api/v1/progress') {
      if (progress404) {
        res.statusCode = 404;
        res.write(jsonEncode({'error': 'not found'}));
      } else {
        res.write(
          jsonEncode({
          'subjects': [
            {
              'id': 'endo',
              'textbook': '世界通史-第2版',
              'learned_through': 4,
              'total': 8,
              'next_chapter': {'no': 5, 'title': '第二篇 工业文明的扩展'},
            },
          ],
            'updated_at': '2026-09-05T14:07:01',
          }),
        );
      }
    } else if (path == '/api/v1/cards/queue') {
      res.write(
        jsonEncode({
          'cards': [
            {
              'id': 'c1',
              'subjectId': 'oms',
              'type': 'basic',
              'front': '干槽症的典型临床表现',
              'back': '拔牙创剧烈疼痛向耳颞部放射',
              'anchor': 'p.12',
              'source': '口腔颌面外科学 第3章 PPT',
              'status': 'active',
            },
            {
              'id': 'c2',
              'subjectId': 'oms',
              'type': 'cloze',
              'front': '智齿拔除禁忌证包括（）',
              'back': '急性感染期/血液系统疾病',
              'anchor': 'p.30',
              'source': '口腔颌面外科学 第5章 PPT',
              'status': 'active',
            },
          ],
        }),
      );
    } else {
      res.statusCode = 404;
      res.write(jsonEncode({'error': 'not found'}));
    }
    await res.close();
  }

  setUp(() async {
    // kBackendMode 缺省已定 local（开源定稿）；本套件验证远程只读端点的
    // 缓存回退（真 HttpServer 只走 remote 分支），显式钉住 remote。
    debugBackendMode = BackendMode.remote;
    progress404 = false;
    cacheStore = InMemoryCacheStore();
    LocalCache.instance.attach(cacheStore);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
    ApiClient.instance.baseUrl = 'http://127.0.0.1:${server.port}';
    ApiClient.instance.resetSubjectCaches();
  });

  tearDown(() async {
    debugBackendMode = null; // 置回 null：跨用例/跨文件零污染
    await server.close(force: true);
    ApiClient.instance.baseUrl = 'http://10.0.2.2:8080';
    ApiClient.instance.resetSubjectCaches();
    LocalCache.instance.detach();
  });

  /// api_client 的缓存写是 fire-and-forget（unawaited）——让事件循环转一拍
  Future<void> flushWrites() =>
      Future<void>.delayed(const Duration(milliseconds: 30));

  test('InMemoryCacheStore：save/load 往返 + remove + 时间戳', () async {
    final payload = {'subjects': <dynamic>[]};
    await LocalCache.instance.save('subjects', payload);
    final entry = await LocalCache.instance.load('subjects');
    expect(entry, isNotNull);
    expect(entry!.data, payload);
    expect(
      entry.savedAt.difference(DateTime.now()).inSeconds.abs(),
      lessThan(5),
    );

    await LocalCache.instance.remove('subjects');
    expect(await LocalCache.instance.load('subjects'), isNull);
  });

  test('SharedPrefsCacheStore：往返 + 结构红线（只有 savedAt/data，无 token）', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SharedPrefsCacheStore(prefs);

    await store.write(
      'subjects',
      CachedEntry(
        data: {
          'subjects': [
            {'id': 'oms'},
          ],
        },
        savedAt: DateTime(2026, 9, 5, 10, 30),
      ),
    );

    // 落盘键名前缀 + 原文结构：{"savedAt":…,"data":{…}}，绝无 Authorization/token
    final raw = prefs.getString('hengya.cache.subjects')!;
    expect(raw.startsWith('{"savedAt":'), isTrue);
    expect(raw, isNot(contains('Authorization')));
    expect(raw, isNot(contains('Bearer')));
    expect(raw, isNot(contains('token')));

    final back = await store.read('subjects');
    expect(back, isNotNull);
    expect(back!.savedAt, DateTime(2026, 9, 5, 10, 30));
    expect((back.data as Map)['subjects'], isNotEmpty);

    await store.clear();
    expect(await store.read('subjects'), isNull);
  });

  test('SharedPrefsCacheStore：磁盘坏数据一律按「无缓存」静默处理', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = SharedPrefsCacheStore(prefs);

    await prefs.setString('hengya.cache.subjects', '不是 JSON {{{');
    expect(await store.read('subjects'), isNull);

    await prefs.setString('hengya.cache.subjects', '{"nope":123}');
    expect(await store.read('subjects'), isNull); // 缺 savedAt/data

    await prefs.setString(
      'hengya.cache.subjects',
      '{"savedAt":"abc","data":1}',
    );
    expect(await store.read('subjects'), isNull); // savedAt 非整数
  });

  test('api_client：成功 → 异步写缓存，旁路元信息为空（新鲜）', () async {
    final subs = await ApiClient.instance.fetchSubjects();
    expect(subs.length, 2);
    expect(subs[0].dueCount, 2);
    await flushWrites();

    final entry = await LocalCache.instance.load(CacheKeys.subjects);
    expect(entry, isNotNull);
    expect((entry!.data as Map)['subjects'], isNotEmpty);
    // 新鲜数据不标记「来自缓存」
    expect(ApiClient.instance.cacheServedAt(CacheKeys.subjects), isNull);
  });

  test('api_client：断网（socket 失败）→ 缓存命中 + 旁路元信息标记来自缓存', () async {
    // 在线拉一次写缓存
    await ApiClient.instance.fetchSubjects();
    await flushWrites();

    // 断网：服务器直接关掉 → 连接拒绝（SocketException）
    await server.close(force: true);
    final subs = await ApiClient.instance.fetchSubjects();

    expect(subs.length, 2);
    expect(subs[1].subject.name, '基础化学');
    // 名称缓存经缓存回退同样生效
    expect(ApiClient.instance.subjectNameOf('endo'), '基础化学');
    // 旁路元信息：本次读取来自缓存
    final servedAt = ApiClient.instance.cacheServedAt(CacheKeys.subjects);
    expect(servedAt, isNotNull);
  });

  test('api_client：4xx 不回退——服务器 404 时即使有缓存也抛真实错误', () async {
    // 在线拉一次写缓存（200）
    final p1 = await ApiClient.instance.fetchProgress();
    expect(p1.subjects.single.id, 'endo');
    await flushWrites();
    expect(await LocalCache.instance.load(CacheKeys.progress), isNotNull);

    // 服务器开始对 /progress 回 404（网络仍通）→ 必须抛 ApiException(404)
    progress404 = true;
    await expectLater(
      ApiClient.instance.fetchProgress(),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
  });

  test('api_client：无缓存 + 断网 → 维持既有错误分支（ApiException(0)）', () async {
    await server.close(force: true);
    // 本用例未先在线拉取过 → cacheStore 为空
    await expectLater(
      ApiClient.instance.fetchStreak(),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 0)),
    );
    expect(ApiClient.instance.cacheServedAt(CacheKeys.streak), isNull);
  });

  test('api_client：坏缓存自清——解析失败按「无缓存」处理并删除该键', () async {
    // 在线拉一次 summary 写缓存，然后把缓存污染成坏数据
    await ApiClient.instance.fetchSummary();
    await flushWrites();
    final key = CacheKeys.summary(7);
    expect(await LocalCache.instance.load(key), isNotNull);
    await cacheStore.write(
      key,
      CachedEntry(data: 12345, savedAt: DateTime.now()), // 解析必然抛错
    );

    await server.close(force: true); // 断网 → 走回退 → 解析失败
    await expectLater(
      ApiClient.instance.fetchSummary(),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 0)),
    );
    // 坏缓存已被自清（下次在线拉取会重写）
    expect(await LocalCache.instance.load(key), isNull);
  });

  test('复习队列持久化：断网回退同一批卡，字段完整；未缓存科目不回退', () async {
    // 在线拉队列 → 持久化
    final cards = await ApiClient.instance.fetchQueue('oms');
    expect(cards.length, 2);
    await flushWrites();
    expect(
      await LocalCache.instance.load(CacheKeys.queue('oms', 50)),
      isNotNull,
    );

    // 断网冷启动：同一批卡可用，字段完整
    await server.close(force: true);
    final cached = await ApiClient.instance.fetchQueue('oms');
    expect(cached.length, 2);
    expect(cached[0].id, 'c1');
    expect(cached[0].front, '干槽症的典型临床表现');
    expect(cached[0].anchor, 'p.12');
    expect(cached[1].status.name, 'active');
    expect(
      ApiClient.instance.cacheServedAt(CacheKeys.queue('oms', 50)),
      isNotNull,
    );

    // 未缓存过的科目（endo）断网不回退——维持错误分支
    await expectLater(
      ApiClient.instance.fetchQueue('endo'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 0)),
    );
  });
}
