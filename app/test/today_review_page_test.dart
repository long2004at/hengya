// 今日复习会话页（跨科目每日任务）UI 层测试：
//   · 空队列 + remainingToday==0 → 直接完成态（不空白）；
//   · 正常评分推进 → 进度乐观累计「N/目标 M」→ 答完进庆祝态；
//   · 跳过 → _deferred 会话内重试、不计进度。
// 与 review_skip_test.dart 同姿势：FakeHttpClient 路由 /cards/queue/today、
// /subjects、POST /review/answer，评分链路真实走 ApiClient 单例（可断言
// cardId 与拒绝语义），故无需另造 mock。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hengya/pages/today_review_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/api/local_cache.dart';
import 'package:hengya/services/review/session_store.dart';
import 'package:hengya/widgets/rating_slider.dart';

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

class _FakeRouter {
  final writes = <Map<String, dynamic>>[];
  bool accepted = true;
  int queueReads = 0;
  int subjectReads = 0;

  /// 今日队列四字段 + 卡片（id c1..cN，两科交叠验证跨科目徽章）
  int goal = 2;
  int doneToday = 0;
  int dueTotal = 2;
  int remainingToday = 2;
  List<String> cardIds = ['c1', 'c2'];

  _FakeHttpClientRequest open(String method, Uri uri) =>
      _FakeHttpClientRequest(method, uri, this);

  HttpClientResponse respond(String method, Uri uri, List<int> bytes) {
    if (method == 'GET' && uri.path.endsWith('/cards/queue/today')) {
      queueReads++;
      return _FakeHttpClientResponse(
        200,
        jsonEncode({
          'cards': [
            for (final id in cardIds)
              {
                'id': id,
                'subjectId': id.startsWith('c1') ? 'study' : 'ana',
                'type': 'basic',
                'front': '$id 题目',
                'back': '$id 答案',
                'anchor': 'p$id',
                'source': '资料',
                'status': 'active',
              },
          ],
          'goal': goal,
          'doneToday': doneToday,
          'dueTotal': dueTotal,
          'remainingToday': remainingToday,
        }),
      );
    }
    if (method == 'GET' && uri.path.endsWith('/subjects')) {
      subjectReads++;
      return _FakeHttpClientResponse(
        200,
        jsonEncode({
          'subjects': [
            {'id': 'study', 'name': '口解', 'isExamSubject': true},
            {'id': 'ana', 'name': '口外', 'isExamSubject': true},
          ],
        }),
      );
    }
    if (method == 'POST' && uri.path.endsWith('/review/answer')) {
      final body = jsonDecode(utf8.decode(bytes));
      writes.add({
        'path': uri.path,
        'body': body is List ? body.first : body,
      });
      return _FakeHttpClientResponse(
        200,
        jsonEncode({
          'ok': accepted,
          'results': [
            {
              'cardId': (body is List ? body.first : body)['cardId'],
              'ok': accepted,
            },
          ],
        }),
      );
    }
    return _FakeHttpClientResponse(404, '{}');
  }
}

GoRouter buildTestRouter() => GoRouter(
  initialLocation: '/review/today',
  routes: [
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
    ApiClient.instance.offlineStore = null;
    ApiClient.instance.resetSubjectCaches();
    LocalCache.instance.attach(InMemoryCacheStore());
  });
  tearDown(() {
    ApiClient.instance.debugInjectHttpClient(null);
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    LocalCache.instance.attach(InMemoryCacheStore());
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SessionStore(),
        child: MaterialApp.router(routerConfig: buildTestRouter()),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('进队即空 + remainingToday==0：直接完成态而非空白，进度口径不变', (tester) async {
    router.doneToday = 3;
    router.remainingToday = 0;
    router.cardIds = const [];
    await pumpPage(tester);
    expect(find.byType(RatingSlider), findsNothing);
    expect(find.byKey(const ValueKey('today-summary')), findsOneWidget);
    expect(find.text('今日目标达成'), findsOneWidget);
    expect(find.text('今日 3/目标 2 张'), findsOneWidget,
        reason: '完成态进度文案沿用「N/目标 M」口径');
    expect(router.queueReads, 1);
  });

  testWidgets('到期清完但未达目标：显示「今日到期已清完」', (tester) async {
    router.doneToday = 1;
    router.goal = 10;
    router.dueTotal = 1;
    router.remainingToday = 0;
    router.cardIds = const [];
    await pumpPage(tester);
    expect(find.byKey(const ValueKey('today-summary')), findsOneWidget);
    expect(find.text('今日到期已清完'), findsOneWidget);
    expect(find.text('今日 1/目标 10 张'), findsOneWidget);
  });

  testWidgets('正常评分推进：进度乐观累计、跨科目徽章、答完进庆祝态', (tester) async {
    await pumpPage(tester);
    // 科目名徽章（fetchSubjects 刷新 subjectNames 映射；堆叠中只有
    // 顶层卡渲染内容 → 首卡为「口解」，第二张翻开后才见「口外」）
    expect(router.subjectReads, 1);
    expect(find.byKey(const ValueKey('today-subject-badge')), findsWidgets);
    expect(find.text('口解'), findsOneWidget);
    // 初始进度 = 接口 doneToday=0：「0/目标 2」+ 还剩 2 张
    expect(find.byKey(const ValueKey('today-progress')), findsOneWidget);
    expect(find.text('0/目标 2'), findsOneWidget);
    expect(find.text('还剩 2 张'), findsOneWidget);

    // 评分第一张：受理成功 → 本地 +1（乐观）
    await tester.tap(find.byType(RatingSlider));
    await tester.pumpAndSettle();
    expect(find.text('c2 题目'), findsOneWidget);
    expect(find.text('口外'), findsOneWidget, reason: '第二张卡的科目徽章');
    expect(find.text('1/目标 2'), findsOneWidget);
    expect(router.writes.single['body']['cardId'], 'c1');

    // 评分第二张 → 队列空 → 庆祝态「今日目标达成」
    await tester.tap(find.byType(RatingSlider));
    await tester.pumpAndSettle();
    expect(router.writes, hasLength(2));
    expect(find.byKey(const ValueKey('today-summary')), findsOneWidget);
    expect(find.text('今日目标达成'), findsOneWidget);
    expect(find.text('今日 2/目标 2 张'), findsOneWidget);
    expect(router.queueReads, 1, reason: '会话内不重拉今日队列');
  });

  testWidgets('评分受理失败：toast + 保留当前卡，进度不虚增', (tester) async {
    router.accepted = false;
    await pumpPage(tester);
    await tester.tap(find.byType(RatingSlider));
    await tester.pumpAndSettle();
    expect(find.text('c1 题目'), findsOneWidget, reason: '未受理不前进');
    expect(find.text('0/目标 2'), findsOneWidget, reason: '未受理不计进度');
    expect(router.writes, hasLength(1));
  });

  testWidgets('跳过后 _deferred 会话内重试，跳过不计进度', (tester) async {
    await pumpPage(tester);
    // 跳过两张（不评分、不写请求）
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byKey(const ValueKey('review-skip')));
      await tester.pumpAndSettle();
    }
    expect(router.writes, isEmpty);
    expect(find.byKey(const ValueKey('today-summary')), findsOneWidget);
    expect(find.text('今日 0/目标 2 张 · 跳过 2 张'), findsOneWidget);

    // 结算页重试跳过的卡 → 原序回到队列，仍不重拉今日队列
    await tester.tap(find.byKey(const ValueKey('review-retry-skipped')));
    await tester.pumpAndSettle();
    expect(find.text('c1 题目'), findsOneWidget);
    expect(router.queueReads, 1);

    // 重试后评分照常累计进度
    await tester.tap(find.byType(RatingSlider));
    await tester.pumpAndSettle();
    expect(find.text('1/目标 2'), findsOneWidget);
    expect(find.text('c2 题目'), findsOneWidget);
  });
}
