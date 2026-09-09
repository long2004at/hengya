// §7.5 学习进度页组件级测试：
//   正常态：罗盘总览 + 「今天该复习什么」联动（含 derm 排除验收条款）+ 各科行
//   404 降级：旧服务器（0.2.0）→「需服务器 0.3.0+，暂未部署」不崩溃
//   空态：subjects 空（progress.json 未推送）→ 引导文案
//   断网：ApiException(0) →「连不上服务器」
//   关动效：系统 disableAnimations → 气泡氛围层静止（无 AnimatedBuilder），
//          信息完整可读（信息明确硬约束的回归锚点）
//
// 测试基建：同 m5_widget_test.dart——经 [ApiClient.debugInjectHttpClient] 注入
// 假 HttpClient（契约路由应答、微任务即答、可模拟 404/断网）。
// 注意：气泡氛围层是永续 repeat 动画 → pumpAndSettle 永不 settle，
// 全部用固定时长 pump 推进；测试收尾 pumpWidget 卸载页面让 Ticker 注销。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hengya/pages/progress_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// 契约路由：录制全部请求，按 path+method 应答。
/// all404 模拟旧服务器（0.2.0）；emptyProgress 模拟 progress.json 未推送；
/// refused 模拟断网。
class _FakeRouter {
  final requests = <Map<String, dynamic>>[];
  bool all404 = false;
  bool emptyProgress = false;
  bool refused = false;

  /// 罗盘三态子集（在学 / 学完 / 无罗盘 derm）；anatomy 不入 /subjects
  /// → 覆盖 subjectNameOf 的「未知 id 原样显示」兜底分支
  static const _progress = {
    'subjects': [
      {
        'id': 'endo',
        'textbook': '世界通史-第2版',
        'learned_through': 4,
        'total': 8,
        'next_chapter': {'no': 5, 'title': '第二篇 工业文明的扩展', 'page': 58},
      },
      {
        'id': 'anatomy',
        'textbook': '口腔解剖生理学-第8版',
        'learned_through': 11,
        'total': 11,
        'next_chapter': null,
      },
      {
        'id': 'derm',
        'textbook': null,
        'learned_through': 0,
        'total': 0,
        'next_chapter': null,
      },
    ],
    'updated_at': '2026-09-05T14:07:01',
  };

  /// derm 故意给 dueCount=5：验收条款「derm 不出现在任何复习提示」的排除依据
  static const _subjects = {
    'subjects': [
      {'id': 'endo', 'name': '世界历史', 'dueCount': 3},
      {'id': 'derm', 'name': '有机化学', 'dueCount': 5},
    ],
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
    final key = '$method ${url.path}';
    if (all404) {
      return _FakeHttpClientResponse(404, jsonEncode({'error': 'not found'}));
    }
    switch (key) {
      case 'GET /api/v1/progress':
        return _ok(
          emptyProgress
              ? {'subjects': const <dynamic>[], 'updated_at': null}
              : _progress,
        );
      case 'GET /api/v1/subjects':
        return _ok(_subjects);
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
    ApiClient.instance.debugInjectHttpClient(_FakeHttpClient(router));
    ApiClient.instance.resetSubjectCaches();
  });

  tearDown(() {
    debugBackendMode = null; // 置回 null：跨用例/跨文件零污染
    ApiClient.instance.debugInjectHttpClient(null); // 恢复默认链路
    ApiClient.instance.baseUrl = 'http://10.0.2.2:8080';
    ApiClient.instance.resetSubjectCaches();
  });

  /// 页面数据经假路由微任务即答；气泡永续动画 → 固定 pump（勿用 pumpAndSettle）
  Future<void> pumpPage(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    // ListView 懒构建：拉高视口让三张科目卡全部在渲染范围内
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 测试收尾卸载页面：气泡控制器 dispose → Ticker 注销（永续动画不外泄）
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
    await tester.pumpWidget(
      MaterialApp(
        home: disableAnimations
            ? Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: true),
                  child: const ProgressPage(),
                ),
              )
            : const ProgressPage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('正常态：罗盘总览 + 联动卡 + 各科行，服务端科目名优先', (tester) async {
    await pumpPage(tester);

    // 两路请求都发生（/progress 主体 + /subjects 复习队列统计）
    expect(
      router.requests.where((r) => r['path'] == '/api/v1/progress'),
      isNotEmpty,
    );
    expect(
      router.requests.where((r) => r['path'] == '/api/v1/subjects'),
      isNotEmpty,
    );

    // 页头总览：已学合计 4+11=15 / 总章 8+11=19；罗盘 2 科、已开学 2 科
    expect(find.text('学习进度'), findsOneWidget);
    expect(find.text('学习罗盘'), findsOneWidget);
    expect(find.text('15 / 19'), findsOneWidget);
    expect(find.text('章已学'), findsOneWidget);
    expect(find.textContaining('罗盘科目 2 科'), findsOneWidget);
    expect(find.textContaining('已开学 2 科'), findsOneWidget);
    expect(find.text('更新于 9月5日 14:07'), findsOneWidget);

    // 联动卡：世界历史 3 张到期提示（罗盘科目 × dueCount>0）
    expect(find.text('今天该复习什么'), findsOneWidget);
    expect(find.textContaining('3 张卡到期'), findsOneWidget);
    // 验收条款：derm（dueCount=5 但无罗盘）不出现在任何复习提示
    expect(find.textContaining('5 张卡到期'), findsNothing);
    // 下一章预告：世界历史（学完的 anatomy 不预告）
    expect(find.text('下一章预告'), findsOneWidget);
    expect(find.textContaining('世界历史：第二篇 工业文明的扩展 p58'), findsOneWidget);

    // 各科行 × 3：进度数字 + 下一章行内展示（预告与行内同串 → 两处）
    expect(find.text('各科进度'), findsOneWidget);
    expect(find.text('4/8'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.textContaining('第二篇 工业文明的扩展 p58'), findsNWidgets(2));
    // 学完态（anatomy 11/11）
    expect(find.text('11/11'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);
    expect(find.text('已学完'), findsOneWidget);
    expect(find.text('教材正文章已全部学完'), findsOneWidget);
    // 无罗盘科目（derm）：标注「未配置教材」，无数字无进度条无下一章
    expect(find.text('未配置教材'), findsOneWidget);
    expect(find.text('暂无学习罗盘'), findsOneWidget);
    expect(find.text('教材未配置，暂不参与复习提示'), findsOneWidget);
    // anatomy 不在 /subjects → subjectFullNameOf 兜底原样 id
    //（0.3.1 起 13 科中文全名映射已随内置科目移除——缓存未命中如实显示 id）
    expect(find.text('anatomy'), findsOneWidget);

    // 氛围层在位且在动（AnimatedBuilder 驱动）
    final ambient = find.byKey(const ValueKey('progress-bubble-ambient'));
    expect(ambient, findsOneWidget);
    expect(
      find.descendant(of: ambient, matching: find.byType(AnimatedBuilder)),
      findsOneWidget,
    );
  });

  testWidgets('404 降级：旧服务器（0.2.0）→「需服务器 0.3.0+，暂未部署」不崩溃', (tester) async {
    router.all404 = true;
    await pumpPage(tester);
    expect(find.text('需服务器 0.3.0+，暂未部署'), findsOneWidget);
    expect(find.text('当前服务器版本过低，暂无学习进度端点'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('学习进度'), findsOneWidget); // AppBar 照常
  });

  testWidgets('空态：subjects 空（progress.json 未推送）→ 引导文案', (tester) async {
    router.emptyProgress = true;
    await pumpPage(tester);
    expect(find.text('暂无学习进度数据'), findsOneWidget);
    expect(find.textContaining('尚未推送到服务器'), findsOneWidget);
    expect(find.textContaining('首次语料推送后自动生成'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('断网：ApiException(0) →「连不上服务器」+ 重试', (tester) async {
    router.refused = true;
    await pumpPage(tester);
    expect(find.text('连不上服务器'), findsOneWidget);
    expect(find.text('检查网络后重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('关动效（信息明确硬约束）：disableAnimations → 氛围层静止、信息完整', (tester) async {
    await pumpPage(tester, disableAnimations: true);

    // 氛围层存在但不驱动（无 AnimatedBuilder → 静态一帧）
    final ambient = find.byKey(const ValueKey('progress-bubble-ambient'));
    expect(ambient, findsOneWidget);
    expect(
      find.descendant(of: ambient, matching: find.byType(AnimatedBuilder)),
      findsNothing,
    );

    // 信息完整可读：总览 / 联动 / 各科行 / 完成态 / 无罗盘标注 全部在位
    expect(find.text('学习罗盘'), findsOneWidget);
    expect(find.text('15 / 19'), findsOneWidget);
    expect(find.textContaining('3 张卡到期'), findsOneWidget);
    expect(find.textContaining('5 张卡到期'), findsNothing);
    expect(find.text('4/8'), findsOneWidget);
    expect(find.textContaining('第二篇 工业文明的扩展 p58'), findsNWidgets(2));
    expect(find.text('已学完'), findsOneWidget);
    expect(find.text('未配置教材'), findsOneWidget);
  });
}
