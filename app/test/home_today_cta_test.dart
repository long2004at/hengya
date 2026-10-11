// 首页大 CTA「今日复习」（home_today_cta.dart）专项测试（2026-10-11 首页重构）：
//   · 纯函数：三态判定 / 三态文案 / Hero 大数字口径（含降级回退）；
//   · 点击路由：CTA push /review/today（测试路由用占位页，不进真会话页），
//     pop 返回后重拉 /stats/today（CTA/大数字随评分刷新）；
//   · local 模式：顶部溢出菜单收纳「语料库」「回炉工作台」两项存在
//     （remote 模式整体收起由 home_page_test 断言）。
// 假 HttpClient 栈同 home_page_test.dart（remote 契约应答）；local 用例
// 同 ui_button_sweep_test.dart 的 sqlite3.dll + LocalBackend 临时库姿势
//（空库即可——溢出菜单不依赖数据）。
// 注意：流彩氛围层永续动画 → 固定 pump，勿用 pumpAndSettle。
import 'dart:async';
import 'dart:convert';
// show 限定：dart:ffi 的 Size 与 dart:ui 冲突，只取 DynamicLibrary
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hengya/pages/home_page.dart';
import 'package:hengya/pages/home_today_cta.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

// ---------------- 假 HttpClient 栈（remote 契约应答；同 home_page_test） ----------------

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// remote 契约最小应答：subjects / streak / summary / progress / stats/today
class _FakeRouter {
  final requests = <String>[];

  Map<String, dynamic>? todayStats = const {
    'goal': 10,
    'done': 0,
    'dueTotal': 8,
    'remainingToday': 6,
  };

  _FakeHttpClientRequest open(String method, Uri url) {
    return _FakeHttpClientRequest(method, url, this);
  }

  HttpClientResponse respond(
    String method,
    Uri url,
    _FakeHttpHeaders headers,
    List<int> bytes,
  ) {
    requests.add('$method ${url.path}');
    switch ('$method ${url.path}') {
      case 'GET /api/v1/subjects':
        return _ok(const {
          'subjects': [
            {'id': 'endo', 'name': '世界历史', 'dueCount': 3},
          ],
        });
      case 'GET /api/v1/stats/streak':
        return _ok(const {'streak': 4});
      case 'GET /api/v1/stats/summary':
        return _ok(const {
          'totalReviews': 21,
          'againRate': 0.12,
          'pendingCards': 6,
          'pendingInbox': 2,
        });
      case 'GET /api/v1/progress':
        return _ok(const {'subjects': [], 'updated_at': null});
      case 'GET /api/v1/stats/today':
        final t = todayStats;
        return t != null
            ? _ok(t)
            : _FakeHttpClientResponse(404, jsonEncode({'error': 'not found'}));
      default:
        return _FakeHttpClientResponse(404, jsonEncode({'error': 'not found'}));
    }
  }

  _FakeHttpClientResponse _ok(Object json) =>
      _FakeHttpClientResponse(200, jsonEncode(json));
}

// ---------------- 测试路由：/review/today 用占位页（不进真会话页） ----------------

GoRouter _testRouter() => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (_, _) => const HomePage()),
    GoRoute(
      path: '/review/today',
      builder: (_, _) =>
          const Scaffold(body: Center(child: Text('今日复习会话占位页'))),
    ),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }

  // ---------------- 纯函数：三态判定 / 文案 / 大数字口径 ----------------

  TodayProgress t(int goal, int done, int dueTotal, int remaining) =>
      TodayProgress(
        goal: goal,
        done: done,
        dueTotal: dueTotal,
        remainingToday: remaining,
      );

  test('todayCtaStateOf：done>=goal 完成态优先，done>0 进行中，否则未开始', () {
    expect(todayCtaStateOf(t(10, 0, 8, 6)), TodayCtaState.notStarted);
    expect(todayCtaStateOf(t(10, 2, 8, 6)), TodayCtaState.inProgress);
    expect(todayCtaStateOf(t(10, 10, 8, 0)), TodayCtaState.done);
    // 边界：goal=0（未配置目标）时 done 再大也不算完成态
    expect(todayCtaStateOf(t(0, 5, 8, 0)), TodayCtaState.inProgress);
    // done 已达 goal 但 remainingToday==0：完成态判定只看 done>=goal
    expect(todayCtaStateOf(t(10, 12, 0, 0)), TodayCtaState.done);
  });

  test('todayCtaLabel：三态文案逐字对齐措辞基线（「N/目标 M」「还剩」）', () {
    expect(todayCtaLabel(t(10, 0, 8, 6)), '开始今日复习 · 还剩 6 张');
    expect(todayCtaLabel(t(10, 2, 8, 6)), '继续今日复习 · 2/目标 10');
    expect(todayCtaLabel(t(10, 10, 3, 0)), '今日已完成 10/10 ✓');
    // 边界：零到期（空库/清完的次日）→ 不出现「还剩 0 张」
    expect(todayCtaLabel(t(50, 0, 0, 0)), '开始今日复习');
  });

  test('todayHeroNumber：有 today 用 remainingToday，无 today 回退 totalDue', () {
    expect(todayHeroNumber(t(10, 0, 8, 6), 23), 6);
    expect(todayHeroNumber(null, 23), 23, reason: '降级必须回退 totalDue，大数字不与按钮割裂');
  });

  // ---------------- remote：点击路由 + 返回后刷新 ----------------

  late _FakeRouter router;

  setUp(() {
    debugBackendMode = BackendMode.remote;
    router = _FakeRouter();
    ApiClient.instance.debugInjectHttpClient(_FakeHttpClient(router));
    ApiClient.instance.resetSubjectCaches();
  });

  tearDown(() {
    debugBackendMode = null;
    ApiClient.instance.debugInjectHttpClient(null);
    ApiClient.instance.resetSubjectCaches();
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink()); // Ticker 注销
    });
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: _testRouter()),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('点击 CTA → push /review/today；pop 返回 → 重拉 /stats/today 刷新', (tester) async {
    await pumpPage(tester);
    expect(find.text('开始今日复习 · 还剩 6 张'), findsOneWidget);
    final todayReadsBefore = router.requests
        .where((r) => r == 'GET /api/v1/stats/today')
        .length;

    // 点击大 CTA → 进占位路由（今日复习会话页在真实 app 里）
    await tester.tap(find.byKey(const ValueKey('home-today-cta')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('今日复习会话占位页'), findsOneWidget);

    // pop 返回首页 → onReviewReturned 触发 _refresh → 第五路再拉一次
    final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
    navigator.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('开始今日复习 · 还剩 6 张'), findsOneWidget);
    final todayReadsAfter = router.requests
        .where((r) => r == 'GET /api/v1/stats/today')
        .length;
    expect(todayReadsAfter, greaterThan(todayReadsBefore),
        reason: '返回后必须重拉 /stats/today（评分改变 done → CTA 刷新）');
  });

  // ---------------- local：溢出菜单收纳项存在性 ----------------

  late Directory tmp;

  setUp(() {
    // !! 同 ui_button_sweep_test 的两层假异步坑：setUp/tearDown 必须 100%
    // 同步（体内 await 安全、setup/teardown await 永挂——isolate 桥经
    // SendPort.awaitResponse 等待真实事件循环，测试宿主没有）；后端 boot
    // 在用例体首行。
    tmp = Directory.systemTemp.createTempSync('hengya_cta_local_');
  });

  tearDown(() {
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    // 不 await：微任务链在真实事件队列 FIFO 自完成
    LocalBackend.instance.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('local 模式：顶部溢出菜单在位，收纳「语料库」「回炉工作台」两项（带图标与文字）', (tester) async {
    // local 模式走 LocalBackend 分流（不经假 HttpClient）：空库临时目录即可，
    // 溢出菜单不依赖数据
    LocalBackend.instance.init(tmp.path);
    debugBackendMode = BackendMode.local;

    await pumpPage(tester);

    // 溢出菜单玻璃圆钮在位（remote 下收起，见 home_page_test）
    final menu = find.byTooltip('更多功能');
    expect(menu, findsOneWidget);
    await tester.tap(menu);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 收纳项存在性：语料库 / 回炉工作台两项均带文字可见
    expect(find.text('语料库'), findsOneWidget);
    expect(find.text('回炉工作台'), findsOneWidget);
  });
}
