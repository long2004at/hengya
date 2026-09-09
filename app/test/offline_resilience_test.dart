// 离线韧性组件级测试（问1+5）：
//   · 复习会话断网冷启动：缓存队列续背 + 「离线数据」提示条 + 评分入既有离线队列
//   · 首页断网：三路缓存回退渲染 + 离线条 + 流彩氛围层仍在位（上游兼容锚点）
//   · 统计页断网：五路缓存回退 + 离线条 + 设置入口可达（验收条款）
//   · 题库/进度页断网：最近一次搜索结果 / 罗盘缓存渲染 + 离线条
//   · 收件箱断网提交：写操作不缓存——TopToast 明确「未能入箱」
//   · review 页错误态（无缓存）：RefreshIndicator 补实「下拉刷新」交互
//
// 测试基建：同 progress_page_test.dart——经 [ApiClient.debugInjectHttpClient] 注入
// 假 HttpClient（契约路由应答、微任务即答）；refused 模拟断网（SocketException）。
// 缓存持久层注入 InMemoryCacheStore（main() 生产注入 SharedPrefs 版）。
// 注意：首页流彩氛围层是永续 repeat 动画 → pumpAndSettle 永不 settle，
// 全部用固定时长 pump 推进；测试收尾 pumpWidget 卸载页面让 Ticker 注销。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hengya/pages/bank_page.dart';
import 'package:hengya/pages/home_page.dart';
import 'package:hengya/pages/inbox_sheet.dart';
import 'package:hengya/pages/progress_page.dart';
import 'package:hengya/pages/review_page.dart';
import 'package:hengya/pages/stats_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/api/local_cache.dart';
import 'package:hengya/services/review/session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

// ---------------- 假 HttpClient 栈（最小实现 + noSuchMethod 兜底） ----------------

class _FakeHttpHeaders implements HttpHeaders {
  final Map<String, String> _raw = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _raw[name.toLowerCase()] = '$value';
  }

  @override
  String? value(String name) => _raw[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientRequest implements HttpClientRequest {
  _FakeHttpClientRequest(this.method, this.uri, this._router);

  @override
  final String method;
  @override
  final Uri uri;
  final _FakeRouter _router;
  @override
  final _FakeHttpHeaders headers = _FakeHttpHeaders();
  final List<int> _bytes = [];

  @override
  void add(List<int> data) => _bytes.addAll(data);

  @override
  void write(Object? obj) => _bytes.addAll(utf8.encode('$obj'));

  @override
  Future<HttpClientResponse> close() async =>
      _router.respond(method, uri, headers, _bytes);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  _FakeHttpClientResponse(this.statusCode, this.bodyText);

  @override
  final int statusCode;
  final String bodyText;
  @override
  final _FakeHttpHeaders headers = _FakeHttpHeaders();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable([utf8.encode(bodyText)]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this._router);

  final _FakeRouter _router;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _router.open('GET', url);

  @override
  Future<HttpClientRequest> postUrl(Uri url) async => _router.open('POST', url);

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      _router.open(method, url);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 契约路由：本文件覆盖的全部读端点 + 两个写端点；refused 模拟断网。
class _FakeRouter {
  final requests = <Map<String, dynamic>>[];
  bool refused = false;

  static const _subjects = {
    'subjects': [
      {'id': 'endo', 'name': '世界历史', 'dueCount': 3},
      {'id': 'derm', 'name': '有机化学', 'dueCount': 5},
    ],
  };

  static const _summary = {
    'totalReviews': 21,
    'againRate': 0.12,
    'pendingCards': 6,
    'pendingInbox': 2,
  };

  static const _heatmap = {
    'byDay': [
      {'day': '2026-09-03', 'reviews': 5},
      {'day': '2026-09-04', 'reviews': 8},
      {'day': '2026-09-05', 'reviews': 3},
    ],
  };

  static const _retention = {
    'windows': [
      {'days': 1, 'total': 10, 'retained': 8, 'rate': '0.8'},
      {'days': 7, 'total': 40, 'retained': 30, 'rate': '0.75'},
      {'days': 30, 'total': 120, 'retained': 90, 'rate': null},
    ],
  };

  static const _forecast = [
    {'date': '2026-09-05', 'due': 8},
    {'date': '2026-09-06', 'due': 2},
    {'date': '2026-09-07', 'due': 0},
    {'date': '2026-09-08', 'due': 5},
    {'date': '2026-09-09', 'due': 1},
    {'date': '2026-09-10', 'due': 4},
    {'date': '2026-09-11', 'due': 1},
  ];

  static const _queue = {
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
  };

  static const _search = {
    'total': 2,
    'cards': [
      {
        'id': 'b1',
        'subjectId': 'oms',
        'type': 'basic',
        'front': '（缓存卡）干槽症定义',
        'back': '拔牙创剧烈疼痛',
        'anchor': 'p.12',
        'source': '口腔颌面外科学 第3章 PPT',
        'status': 'active',
        'userNote': '',
        'aiNote': '',
        'reps': 2,
        'lapses': 0,
        'dueAt': '2026-09-05T00:00:00',
      },
      {
        'id': 'b2',
        'subjectId': 'endo',
        'type': 'cloze',
        'front': '（缓存卡）牙髓炎分类',
        'back': '可复性/不可复性',
        'anchor': 'p.3',
        'source': '世界历史 第2章 PPT',
        'status': 'active',
        'userNote': '',
        'aiNote': '',
        'reps': 1,
        'lapses': 1,
        'dueAt': '',
      },
    ],
  };

  static const _progress = {
    'subjects': [
      {
        'id': 'endo',
        'textbook': '世界通史-第2版',
        'learned_through': 4,
        'total': 8,
        'next_chapter': {'no': 5, 'title': '第二篇 工业文明的扩展', 'page': 58},
      },
    ],
    'updated_at': '2026-09-05T14:07:01',
  };

  _FakeHttpClientRequest open(String method, Uri url) {
    if (refused) {
      throw const SocketException('connection refused (假路由：模拟断网)');
    }
    return _FakeHttpClientRequest(method, url, this);
  }

  HttpClientResponse respond(
    String method,
    Uri url,
    _FakeHttpHeaders headers,
    List<int> bytes,
  ) {
    requests.add({
      'method': method,
      'path': url.path,
      'query': url.queryParameters,
      'body': utf8.decode(bytes),
      'contentType': headers.value('content-type'),
    });
    if (method == 'POST') {
      return _ok({'ok': true, 'applied': 1});
    }
    switch (url.path) {
      case '/api/v1/subjects':
        return _ok(_subjects);
      case '/api/v1/stats/streak':
        return _ok({'streak': 4});
      case '/api/v1/stats/summary':
        return _ok(_summary);
      case '/api/v1/stats/heatmap':
        return _ok(_heatmap);
      case '/api/v1/stats/retention':
        return _ok(_retention);
      case '/api/v1/stats/forecast':
        return _ok(_forecast);
      case '/api/v1/cards/leech':
        return _ok({'cards': const <dynamic>[]});
      case '/api/v1/cards/queue':
        return _ok(_queue);
      case '/api/v1/cards/search':
        return _ok(_search);
      case '/api/v1/progress':
        return _ok(_progress);
      default:
        return _FakeHttpClientResponse(404, jsonEncode({'error': 'not found'}));
    }
  }

  _FakeHttpClientResponse _ok(Object json) =>
      _FakeHttpClientResponse(200, jsonEncode(json));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeRouter router;

  setUp(() {
    // kBackendMode 缺省已定 local（开源定稿）；本套件验证远程 HTTP 契约路径
    //（假 HttpClient 注入只走 remote 分支），显式钉住 remote。
    debugBackendMode = BackendMode.remote;
    router = _FakeRouter();
    LocalCache.instance.attach(InMemoryCacheStore());
    ApiClient.instance.debugInjectHttpClient(_FakeHttpClient(router));
    ApiClient.instance.resetSubjectCaches();
  });

  tearDown(() {
    debugBackendMode = null; // 置回 null：跨用例/跨文件零污染
    ApiClient.instance.debugInjectHttpClient(null); // 恢复默认链路
    ApiClient.instance.baseUrl = 'http://10.0.2.2:8080';
    ApiClient.instance.resetSubjectCaches();
    LocalCache.instance.detach();
    ApiClient.instance.offlineStore = null;
    ApiClient.instance.onQueueChanged = null;
  });

  /// 让 fire-and-forget 的缓存写入落地（假路由微任务即答，一拍足够），
  /// 并断言指定键已写入——防止「在线阶段没写进缓存」导致的假绿。
  Future<void> flushCacheWrites(WidgetTester tester, List<String> keys) async {
    await tester.pumpWidget(const SizedBox.shrink()); // 推进一帧清空微任务
    for (final k in keys) {
      expect(
        await LocalCache.instance.load(k),
        isNotNull,
        reason: '缓存键 $k 未在在线阶段落地',
      );
    }
  }

  testWidgets('复习会话断网冷启动：缓存队列续背 + 离线条 + 评分入既有离线队列', (tester) async {
    // 在线阶段：拉一次队列写缓存（模拟此前联网时打开过该科目）
    final cards = await ApiClient.instance.fetchQueue('oms');
    expect(cards.length, 2);
    await flushCacheWrites(tester, [CacheKeys.queue('oms', 50)]);

    // 断网冷启动：新会话（新页面实例）+ 离线评分队列就位
    router.refused = true;
    final sessionStore = SessionStore();
    final answerStore = InMemoryAnswerStore();
    ApiClient.instance.offlineStore = answerStore;
    ApiClient.instance.onQueueChanged = sessionStore.updatePending;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<SessionStore>.value(
        value: sessionStore,
        child: const MaterialApp(home: ReviewSessionPage(subjectId: 'oms')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 缓存队列可用：第一张卡 + 进度标记 + 离线提示条
    expect(find.text('干槽症的典型临床表现'), findsOneWidget);
    expect(find.text('#1/2'), findsOneWidget);
    expect(find.textContaining('离线数据 · 更新于'), findsOneWidget);

    // 翻面 → 评分（良好）→ 断网 POST 失败 → 入既有离线评分队列
    await tester.tap(find.text('干槽症的典型临床表现'));
    await tester.pump();
    expect(find.text('拔牙创剧烈疼痛向耳颞部放射'), findsOneWidget);
    await tester.tap(find.text('良好'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(answerStore.count, 1); // 评分已入队（断网补传语义保持）
    expect(find.text('待补传 1'), findsOneWidget);
  });

  testWidgets('首页断网冷启动：三路缓存回退渲染 + 离线条 + 流光氛围层仍在位', (tester) async {
    // 在线阶段：三路并发写缓存
    await ApiClient.instance.fetchSubjects();
    await ApiClient.instance.fetchStreak();
    await ApiClient.instance.fetchSummary();
    await flushCacheWrites(tester, [
      CacheKeys.subjects,
      CacheKeys.streak,
      CacheKeys.summary(7),
    ]);

    router.refused = true;
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink()); // 流彩 Ticker 注销
    });
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 缓存数据渲染完整（totalDue = 3 + 5）
    expect(find.text('恒牙'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.textContaining('连续 4 天'), findsOneWidget);
    expect(find.textContaining('7 天复习 21'), findsOneWidget);
    // 离线提示条可见
    expect(find.textContaining('离线数据 · 更新于'), findsOneWidget);
    // 上游兼容锚点：流彩氛围层在位且被驱动（离线条叠加不破坏装饰层）
    final ambient = find.byKey(const ValueKey('home-aurora-ambient'));
    expect(ambient, findsOneWidget);
    expect(
      find.descendant(of: ambient, matching: find.byType(AnimatedBuilder)),
      findsOneWidget,
    );
  });

  testWidgets('统计页断网冷启动：五路缓存回退 + 离线条 + 设置入口可达', (tester) async {
    // 在线阶段：统计页五路写缓存
    await ApiClient.instance.fetchStreak();
    await ApiClient.instance.fetchHeatmap(days: 365);
    await ApiClient.instance.fetchRetention();
    await ApiClient.instance.fetchForecast();
    await ApiClient.instance.fetchLeechCards();
    await flushCacheWrites(tester, [
      CacheKeys.streak,
      CacheKeys.heatmap(365),
      CacheKeys.retention,
      CacheKeys.forecast(7),
      CacheKeys.leech(4),
    ]);

    router.refused = true;
    // 设置入口在列表底部：拉高视口让其进入渲染范围
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: StatsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // 五路缓存回退渲染完整
    expect(find.textContaining('连续打卡 4 天'), findsOneWidget);
    expect(find.text('打卡热力图'), findsOneWidget);
    expect(find.text('保留率'), findsOneWidget);
    expect(find.text('未来 7 天到期'), findsOneWidget);
    expect(find.text('弱卡榜'), findsOneWidget);
    // 离线提示条可见
    expect(find.textContaining('离线数据 · 更新于'), findsOneWidget);
    // 验收条款：统计页有缓存 → 设置入口可达
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('提醒 · 同步 · 服务器 · 关于'), findsOneWidget);
  });

  testWidgets('题库断网冷启动：最近一次搜索结果回退 + 离线条', (tester) async {
    // 在线阶段：搜索 + 科目列表写缓存
    await ApiClient.instance.searchBankCards();
    await ApiClient.instance.fetchSubjects();
    await flushCacheWrites(tester, [CacheKeys.bankSearch, CacheKeys.subjects]);

    router.refused = true;
    await tester.pumpWidget(const MaterialApp(home: BankPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('（缓存卡）干槽症定义'), findsOneWidget);
    expect(find.text('（缓存卡）牙髓炎分类'), findsOneWidget);
    expect(find.textContaining('共 2 张'), findsOneWidget);
    expect(find.textContaining('离线数据 · 更新于'), findsOneWidget);
  });

  testWidgets('进度页断网冷启动：罗盘缓存渲染 + 联动卡到期数 + 离线条', (tester) async {
    // 在线阶段：progress + subjects 写缓存
    await ApiClient.instance.fetchProgress();
    await ApiClient.instance.fetchSubjects();
    await flushCacheWrites(tester, [CacheKeys.progress, CacheKeys.subjects]);

    router.refused = true;
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const MaterialApp(home: ProgressPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('学习罗盘'), findsOneWidget);
    expect(find.text('4 / 8'), findsOneWidget);
    // 联动卡：dueCount 来自缓存 subjects（世界历史 3 张）
    expect(find.textContaining('3 张卡到期'), findsOneWidget);
    expect(find.textContaining('离线数据 · 更新于'), findsOneWidget);
  });

  testWidgets('收件箱断网提交：写操作不缓存——TopToast 明确「未能入箱」', (tester) async {
    // 三字段表单 + 提交按钮在 600 高视口下溢出 → 拉高视口
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => Center(
              child: ElevatedButton(
                onPressed: () => showInboxSheet(ctx),
                child: const Text('打开录入栏'),
              ),
            ),
          ),
        ),
      ),
    );
    // ① 先在线打开：科目目录正常加载（0.3.1 起无内置兜底——空态场景另测）
    await tester.tap(find.text('打开录入栏'));
    await tester.pumpAndSettle();
    // fixture 两科（世界历史/有机化学）→ 两枚 chip，首科预选
    expect(find.byType(ChoiceChip), findsNWidgets(2));

    // ② 断网后再提交：写操作不缓存——网络级失败必须明确告知
    router.refused = true;
    // 填关键词（第 2 个输入框）并提交 → 全部网络级失败
    await tester.enterText(find.byType(TextField).at(1), '工业革命');
    await tester.tap(find.text('存入收件箱'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.textContaining('未能入箱：当前离线/服务器不可达，联网后重试（共 1 条）'),
      findsOneWidget,
    );
  });

  testWidgets('review 页错误态（无缓存）：RefreshIndicator 补实「下拉刷新」交互', (tester) async {
    router.refused = true;
    await tester.pumpWidget(const MaterialApp(home: ReviewPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('连不上服务器'), findsOneWidget);
    expect(find.textContaining('检查网络后下拉刷新'), findsOneWidget);
    // 文案承诺的下拉交互现在真实存在
    expect(find.byType(RefreshIndicator), findsOneWidget);
  });

  testWidgets('复习会话错误态（无缓存）：RefreshIndicator 在位 + 重试可恢复', (tester) async {
    router.refused = true;
    final sessionStore = SessionStore();
    await tester.pumpWidget(
      ChangeNotifierProvider<SessionStore>.value(
        value: sessionStore,
        child: const MaterialApp(home: ReviewSessionPage(subjectId: 'derm')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('连不上服务器'), findsOneWidget);
    expect(find.byType(RefreshIndicator), findsOneWidget);

    // 网络恢复后下拉 → 缓存队列...derm 无缓存队列 → 恢复在线拉取成功
    router.refused = false;
    await tester.fling(find.byType(ListView), const Offset(0, 300), 500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('连不上服务器'), findsNothing);
    expect(find.text('#1/2'), findsOneWidget); // 在线队列已恢复
  });
}
