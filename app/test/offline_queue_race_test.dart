import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared/hengya_shared.dart';
import 'package:hengya/services/api/api_client.dart';

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
  final started = Completer<void>();
  final response = Completer<HttpClientResponse>();
  int posts = 0;
  _FakeHttpClientRequest open(String method, Uri uri) =>
      _FakeHttpClientRequest(method, uri, this);
  Future<HttpClientResponse> respond(
    String method,
    Uri uri,
    _FakeHttpHeaders headers,
    List<int> bytes,
  ) async {
    posts++;
    if (!started.isCompleted) started.complete();
    return response.future;
  }
}

class _FailingPreferences implements SharedPreferences {
  Map<String, String> disk = {}, cache = {};
  bool fail = false;
  @override
  String? getString(String key) => cache[key];
  @override
  Future<bool> setString(String key, String value) async {
    cache[key] = value;
    if (fail) return false;
    disk[key] = value;
    return true;
  }

  @override
  Future<void> reload() async {
    cache = Map.of(disk);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Map<String, dynamic> item(String id) => {
    'cardId': id,
    'subjectId': 'math',
    'rating': 'smooth',
    'reviewedAt': '2026-10-09T10:00:00',
    'offlineQueued': true,
  };
  late _FakeRouter router;
  setUp(() {
    router = _FakeRouter();
    debugBackendMode = BackendMode.remote;
    ApiClient.instance.baseUrl = 'https://test.invalid';
    ApiClient.instance.debugInjectHttpClient(_FakeHttpClient(router));
    ApiClient.instance.offlineStore = InMemoryAnswerStore();
    ApiClient.instance.onQueueChanged = null;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    if (!router.response.isCompleted) {
      router.response.complete(_FakeHttpClientResponse(503, '{}'));
    }
    ApiClient.instance.debugInjectHttpClient(null);
    ApiClient.instance.offlineStore = null;
    ApiClient.instance.onQueueChanged = null;
    debugBackendMode = null;
    ApiClient.instance.baseUrl = 'http://10.0.2.2:8080';
  });
  test('补传期间新入队的评分保留，并发补传只发一个请求', () async {
    final client = ApiClient.instance;
    final store = client.offlineStore!;
    await store.append(item('old'));
    final notifications = <int>[];
    client.onQueueChanged = notifications.add;
    final first = client.flushPendingAnswers();
    await router.started.future;
    await store.append(item('new'));
    final second = client.flushPendingAnswers();
    expect(identical(first, second), true);
    expect(router.posts, 1);
    router.response.complete(
      _FakeHttpClientResponse(200, '{"ok":true,"applied":1}'),
    );
    expect(await first, 1);
    expect(await second, 1);
    expect(store.count, 1);
    expect(store.drainPreview().single['cardId'], 'new');
    expect(notifications.last, 1);
  });
  test('离线且存储未初始化时不能假装评分已保存', () async {
    ApiClient.instance.offlineStore = null;
    router.response.complete(_FakeHttpClientResponse(503, '{}'));
    final log = ReviewLog(
      cardId: 'a',
      subjectId: 'math',
      rating: ReviewRating.smooth,
      reviewedAt: DateTime(2026, 10, 9),
    );
    await expectLater(
      ApiClient.instance.submitAnswer(log),
      throwsA(isA<ApiException>()),
    );
  });
  test('旧快照不能误删 clear 后新建的同值记录', () async {
    final store = InMemoryAnswerStore();
    await store.append(item('a'));
    final old = store.drainPreview();
    await store.clear();
    await store.append(item('a'));
    await store.acknowledge(old);
    expect(store.count, 1);
  });
  test('生产持久层串行追加与确认，重建 store 后只保留新评分', () async {
    final prefs = await SharedPreferences.getInstance();
    final store = SharedPrefsAnswerStore(prefs);
    await store.append(item('old'));
    final batch = store.drainPreview();
    final append = store.append(item('new'));
    final acknowledge = store.acknowledge(batch);
    await Future.wait([append, acknowledge]);
    final restored = SharedPrefsAnswerStore(prefs);
    expect(await restored.restore(), 1);
    expect(restored.drainPreview().single['cardId'], 'new');
  });
  test('持久化失败不留下内存或磁盘幽灵评分，并且后续写入不被失败锁死', () async {
    final prefs = _FailingPreferences();
    final store = SharedPrefsAnswerStore(prefs);
    await store.append(item('old'));
    prefs.fail = true;
    await expectLater(store.append(item('ghost')), throwsStateError);
    expect(store.count, 1);
    expect(await store.restore(), 1);
    expect(store.drainPreview().single['cardId'], 'old');
    prefs.fail = false;
    await store.append(item('new'));
    expect(store.count, 2);
    expect(store.drainPreview().any((e) => e['cardId'] == 'ghost'), false);
  });
  test('损坏队列不能被下一条评分静默覆盖，修复后才恢复写入', () async {
    final prefs = _FailingPreferences();
    await prefs.setString('hengya.offline_answers', '{broken');
    final store = SharedPrefsAnswerStore(prefs);
    await expectLater(store.restore(), throwsStateError);
    await expectLater(store.append(item('new')), throwsStateError);
    expect(prefs.disk['hengya.offline_answers'], '{broken');
    await prefs.setString('hengya.offline_answers', '[]');
    expect(await store.restore(), 0);
    await store.append(item('new'));
    expect(store.count, 1);
  });
}
