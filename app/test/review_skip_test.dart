// 跳卡只能改变本次会话：用 HTTP 契约记录证明不存在评分/调度写请求。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hengya/pages/review_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/api/local_cache.dart';
import 'package:hengya/services/review/session_store.dart';
import 'package:hengya/widgets/rating_slider.dart';
import 'package:hengya/widgets/fog_reveal.dart';

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

class _FakeRouter {
  final writes = <Map<String, dynamic>>[];
  int responseCode = 200;
  bool accepted = true;
  int queueReads = 0;
  String front = '第一张题目';
  String back = '第一张答案';
  _FakeHttpClientRequest open(String method, Uri uri) =>
      _FakeHttpClientRequest(method, uri, this);
  HttpClientResponse respond(
    String method,
    Uri uri,
    _FakeHttpHeaders headers,
    List<int> bytes,
  ) {
    if (method == 'GET' && uri.path.endsWith('/cards/queue')) {
      queueReads++;
      return _FakeHttpClientResponse(
        200,
        jsonEncode({
          'cards': [
            for (var i = 1; i <= 2; i++)
              {
                'id': 'c$i',
                'subjectId': 'study',
                'type': 'basic',
                'front': i == 1 ? front : '第二张题目',
                'back': i == 1 ? back : '第二张答案',
                'anchor': 'p$i',
                'source': '资料',
                'status': 'active',
              },
          ],
        }),
      );
    }
    if (method == 'POST') {
      writes.add({'path': uri.path, 'body': jsonDecode(utf8.decode(bytes))});
      return _FakeHttpClientResponse(
        responseCode,
        jsonEncode({'ok': accepted, 'error': '拒绝评分'}),
      );
    }
    return _FakeHttpClientResponse(404, '{}');
  }
}

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
  Future<void> pumpPage(
    WidgetTester tester, {
    bool fog = false,
    Size size = const Size(400, 850),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({'hengya.review.fog': fog});
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SessionStore(),
        child: const MaterialApp(home: ReviewSessionPage(subjectId: 'study')),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  Future<void> skip(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('review-skip')));
    await tester.pumpAndSettle();
  }

  testWidgets('点跳过：下一张可见，零 POST、零离线评分', (tester) async {
    await pumpPage(tester);
    await skip(tester);
    expect(find.text('第二张题目'), findsOneWidget);
    expect(router.writes, isEmpty);
    expect(ApiClient.instance.pendingAnswerCount, 0);
  });
  testWidgets('全部跳过不算完成，可原序重看且不重拉到期队列', (tester) async {
    await pumpPage(tester);
    await skip(tester);
    await skip(tester);
    expect(find.text('已评分 0 张 · 跳过 2 张'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('review-retry-skipped')));
    await tester.pumpAndSettle();
    expect(find.text('第一张题目'), findsOneWidget);
    expect(router.queueReads, 1);
    expect(router.writes, isEmpty);
    await skip(tester);
    await skip(tester);
    expect(find.text('已评分 0 张 · 跳过 2 张'), findsOneWidget);
  });
  testWidgets('开启雾层时划题干跳过，新卡重新上雾', (tester) async {
    await pumpPage(tester, fog: true);
    final zone = find.byKey(const ValueKey('review-skip-zone'));
    await tester.drag(zone, const Offset(180, 0));
    await tester.pumpAndSettle();
    expect(find.text('第二张题目'), findsOneWidget);
    expect(
      tester.widget<FogPeel>(find.byType(FogPeel)).controller.isCleared,
      false,
    );
    expect(router.writes, isEmpty);
  });
  testWidgets('擦雾不触发翻卡，取消题干拖动不跳过', (tester) async {
    await pumpPage(tester, fog: true);
    await tester.drag(find.byType(FogPeel), const Offset(70, 20));
    await tester.pumpAndSettle();
    expect(find.text('第一张题目'), findsOneWidget);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('review-skip-zone'))),
    );
    await gesture.moveBy(const Offset(40, 0));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(find.text('第一张题目'), findsOneWidget);
    expect(router.writes, isEmpty);
  });
  testWidgets('跳过第一张后评分只提交第二张', (tester) async {
    await pumpPage(tester);
    await skip(tester);
    await tester.tap(find.byType(RatingSlider));
    await tester.pumpAndSettle();
    expect(router.writes, hasLength(1));
    expect((router.writes.single['body'] as Map)['cardId'], 'c2');
    expect(find.text('已评分 1 张 · 跳过 1 张'), findsOneWidget);
  });
  for (final code in [400, 200]) {
    testWidgets('评分拒绝 $code 不丢卡、不前进，可再跳过', (tester) async {
      router.responseCode = code;
      router.accepted = false;
      await pumpPage(tester);
      await tester.tap(find.byType(RatingSlider));
      await tester.pumpAndSettle();
      expect(find.text('第一张题目'), findsOneWidget);
      expect(router.writes, hasLength(1));
      await skip(tester);
      expect(find.text('第二张题目'), findsOneWidget);
      expect(router.writes, hasLength(1));
    });
  }
  testWidgets('快速双点跳过只前进一张；动画中卸载无异常', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('review-skip')));
    await tester.tap(find.byKey(const ValueKey('review-skip')));
    await tester.pumpAndSettle();
    expect(find.text('第二张题目'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('review-skip')));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(router.writes, isEmpty);
  });
  testWidgets('小屏长题干、长答案无布局溢出', (tester) async {
    router.front = '很长的题干。' * 100;
    router.back = '很长的答案。' * 150;
    await pumpPage(tester, fog: true, size: const Size(320, 640));
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const ValueKey('review-reveal')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('横屏可滚动到操作栏并跳卡，不出现卡片高度溢出', (tester) async {
    await pumpPage(tester, fog: true, size: const Size(700, 320));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('review-skip')));
    await tester.pumpAndSettle();
    await skip(tester);
    expect(find.text('第二张题目'), findsOneWidget);
    expect(router.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
