// 统计页「今日复习」进度卡测试（每日计划口径对齐）：
//   · 三态渲染（未开始/进行中/已完成）+ 进度数字与 /stats/today mock 一致；
//   · remote 老服务器无 /stats/today（404）→ 今日卡整体不渲染，页面其余
//     区块照常、不崩不报错（容错验收）；
//   · 点击今日卡 push '/review/today'。
// 与 offline_resilience_test.dart 同姿势：FakeHttpClient 契约路由，真实走
// ApiClient 单例。历史五路端点统一回最小数据，今日数据由各用例覆写。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hengya/pages/stats_page.dart';
import 'package:hengya/pages/today_review_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/api/local_cache.dart';
import 'package:hengya/services/review/session_store.dart';

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
      _router.respond(method, uri, _bytes);

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

/// 契约路由：统计页六路读端点（历史五路最小数据 + 可覆写的 /stats/today）。
/// today404=true 模拟 remote 老服务器缺 /stats/today。
class _FakeRouter {
  /// 今日进度四字段（唯一口径 mock，用例逐项覆写后断言渲染一致性）
  int goal = 50;
  int done = 0;
  int dueTotal = 8;
  int remainingToday = 8;
  bool today404 = false;

  _FakeHttpClientRequest open(String method, Uri uri) =>
      _FakeHttpClientRequest(method, uri, this);

  HttpClientResponse respond(String method, Uri uri, List<int> bytes) {
    if (uri.path == '/api/v1/stats/today') {
      if (today404) {
        return _FakeHttpClientResponse(404, jsonEncode({'error': 'not found'}));
      }
      return _FakeHttpClientResponse(
        200,
        jsonEncode({
          'goal': goal,
          'done': done,
          'dueTotal': dueTotal,
          'remainingToday': remainingToday,
        }),
      );
    }
    switch (uri.path) {
      case '/api/v1/stats/streak':
        return _ok({'streak': 4});
      case '/api/v1/stats/heatmap':
        return _ok({
          'byDay': [
            {'day': '2026-09-03', 'reviews': 5},
          ],
        });
      case '/api/v1/stats/retention':
        return _ok({
          'windows': [
            {'days': 1, 'total': 10, 'retained': 8, 'rate': '0.8'},
            {'days': 7, 'total': 40, 'retained': 30, 'rate': '0.75'},
            {'days': 30, 'total': 120, 'retained': 90, 'rate': null},
          ],
        });
      case '/api/v1/stats/forecast':
        // remote 端点返回裸数组（api_client fetchForecast 直接 as List）
        return _ok([
          {'date': '2026-09-05', 'due': 8},
          {'date': '2026-09-06', 'due': 2},
          {'date': '2026-09-07', 'due': 0},
          {'date': '2026-09-08', 'due': 5},
          {'date': '2026-09-09', 'due': 1},
          {'date': '2026-09-10', 'due': 4},
          {'date': '2026-09-11', 'due': 1},
        ]);
      case '/api/v1/cards/leech':
        return _ok({'cards': const <dynamic>[]});
      // 今日复习会话页（点今日卡 push 进来）依赖的两路：最小桩即可
      case '/api/v1/cards/queue/today':
        return _ok({
          'cards': const <dynamic>[],
          'goal': goal,
          'doneToday': done,
          'dueTotal': dueTotal,
          'remainingToday': remainingToday,
        });
      case '/api/v1/subjects':
        return _ok({'subjects': const <dynamic>[]});
      default:
        return _FakeHttpClientResponse(404, jsonEncode({'error': 'not found'}));
    }
  }

  _FakeHttpClientResponse _ok(Object json) =>
      _FakeHttpClientResponse(200, jsonEncode(json));
}

GoRouter _testRouter() => GoRouter(
  initialLocation: '/stats',
  routes: [
    GoRoute(path: '/stats', builder: (context, state) => const StatsPage()),
    GoRoute(
      path: '/review/today',
      builder: (context, state) => const TodayReviewPage(),
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeRouter router;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    debugBackendMode = BackendMode.remote;
    router = _FakeRouter();
    ApiClient.instance.debugInjectHttpClient(_FakeHttpClient(router));
    ApiClient.instance.resetSubjectCaches();
    LocalCache.instance.attach(InMemoryCacheStore());
  });

  tearDown(() {
    ApiClient.instance.debugInjectHttpClient(null);
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    LocalCache.instance.detach();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider<SessionStore>(
        create: (_) => SessionStore(),
        child: MaterialApp.router(routerConfig: _testRouter()),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('未开始态：今日卡渲染「0/目标 50」+「开始今日复习 · 还剩 8 张」', (tester) async {
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('stats-today-card')), findsOneWidget);
    expect(find.text('今日复习'), findsOneWidget);
    expect(find.text('0/目标 50'), findsOneWidget,
        reason: '进度写法沿用「N/目标 M」基线（TodayProgress.display）');
    expect(find.text('开始今日复习 · 还剩 8 张'), findsOneWidget);
    // 数字与 /stats/today mock 一致：done=0、remainingToday=8
    expect(find.text('连续打卡 4 天'), findsOneWidget,
        reason: '历史区块不受今日口径影响，同屏并存');
  });

  testWidgets('进行中态：「12/目标 50」+「继续今日复习 · 12/目标 50」', (tester) async {
    router.done = 12;
    router.remainingToday = 38;
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('stats-today-card')), findsOneWidget);
    expect(find.text('12/目标 50'), findsOneWidget);
    expect(find.text('继续今日复习 · 12/目标 50'), findsOneWidget);
  });

  testWidgets('已完成态：「今日已完成 50/50 ✓」', (tester) async {
    router.done = 50;
    router.remainingToday = 0;
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('stats-today-card')), findsOneWidget);
    expect(find.text('50/目标 50'), findsOneWidget);
    expect(find.text('今日已完成 50/50 ✓'), findsOneWidget);
  });

  testWidgets('点击今日卡 → push /review/today（今日复习会话页）', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('stats-today-card')));
    await tester.pumpAndSettle();
    expect(find.byType(TodayReviewPage), findsOneWidget,
        reason: '跳转 /review/today（已完成态进入也是完成/加练视图）');
  });

  testWidgets('remote 无 /stats/today（404）：今日卡不渲染，其余区块照常不崩', (tester) async {
    router.today404 = true;
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('stats-today-card')), findsNothing,
        reason: '容错验收：端点缺失时区块整体隐藏');
    // 整页其余功能全部在位（不进错误态、不崩）
    expect(find.text('连续打卡 4 天'), findsOneWidget);
    expect(find.text('打卡热力图'), findsOneWidget);
    expect(find.text('保留率'), findsOneWidget);
    expect(find.text('未来 7 天到期'), findsOneWidget);
    expect(find.text('弱卡榜'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });
}
