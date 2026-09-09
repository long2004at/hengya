// 首页流彩氛围层 + 罗盘表盘按钮组件级测试（信息明确硬约束的回归锚点）：
//   正常态：流彩层在位且被驱动（AnimatedBuilder）+ 配色来自受控色池
//           （会话级随机——session 必为池内成员）+ Hero 信息完整
//   关动效：系统 disableAnimations → 流彩层静止（无 AnimatedBuilder →
//           静态一帧），信息完整可读
//   罗盘表盘：第四路 GET /progress 尽力而为接入（进度弧/指针数据到位）；
//             404（旧服务器）/ 拉不到 → 空表盘在位仍可点击
//
// 测试基建：同 progress_page_test.dart——经 [ApiClient.debugInjectHttpClient]
// 注入假 HttpClient（契约路由应答、微任务即答）。
// 注意：流彩氛围层是永续 repeat 动画 → pumpAndSettle 永不 settle，
// 全部用固定时长 pump 推进；测试收尾 pumpWidget 卸载页面让 Ticker 注销。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hengya/pages/home_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/widgets/aurora_ambient.dart';
import 'package:hengya/widgets/compass_dial_button.dart';
import 'package:hengya/widgets/hero_shimmer.dart';
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

/// 契约路由：首页四路并发（subjects / streak / summary / progress 尽力而为）
/// 微任务即答。progress 由 [progressMissing] 模拟旧服务器 404（降级路径）。
class _FakeRouter {
  final requests = <Map<String, dynamic>>[];

  /// true → GET /api/v1/progress 回 404（旧服务器降级路径）
  bool progressMissing = false;

  /// 两科到期 3+5 → totalDue = 8（Hero 大数字断言依据）
  static const _subjects = {
    'subjects': [
      {'id': 'endo', 'name': '世界历史', 'dueCount': 3},
      {'id': 'derm', 'name': '有机化学', 'dueCount': 5},
    ],
  };

  /// 罗盘进度：endo 有罗盘（learned 2/total 4 → 总进度 0.5），
  /// derm 无罗盘（textbook=null 不参与汇总）
  static const _progress = {
    'subjects': [
      {
        'id': 'endo',
        'textbook': '世界通史-第2版',
        'learned_through': 2,
        'total': 4,
        'next_chapter': {'no': 3, 'title': '第二章 新航路', 'page': 45},
      },
      {'id': 'derm', 'textbook': null, 'learned_through': 0, 'total': 0},
    ],
    'updated_at': '2026-09-05T22:00:00',
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
    requests.add({
      'method': method,
      'path': url.path,
      'query': url.queryParameters,
      'body': utf8.decode(bytes),
      'contentType': headers.value('content-type'),
    });
    final key = '$method ${url.path}';
    switch (key) {
      case 'GET /api/v1/subjects':
        return _ok(_subjects);
      case 'GET /api/v1/stats/streak':
        return _ok({'streak': 4});
      case 'GET /api/v1/stats/summary':
        return _ok({
          'totalReviews': 21,
          'againRate': 0.12,
          'pendingCards': 6,
          'pendingInbox': 2,
        });
      case 'GET /api/v1/progress':
        return progressMissing
            ? _FakeHttpClientResponse(404, jsonEncode({'error': 'not found'}))
            : _ok(_progress);
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

  /// 页面数据经假路由微任务即答；流彩永续动画 → 固定 pump（勿用 pumpAndSettle）
  Future<void> pumpPage(
    WidgetTester tester, {
    bool disableAnimations = false,
  }) async {
    // ListView 懒构建：拉高视口让 Hero 与两张科目卡都在渲染范围内
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 测试收尾卸载页面：流光控制器 dispose → Ticker 注销（永续动画不外泄）
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
                  child: const HomePage(),
                ),
              )
            : const HomePage(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('正常态：流彩氛围层在位且被驱动，Hero 信息完整', (tester) async {
    await pumpPage(tester);

    // 三路并发请求都发生（subjects / streak / summary）
    expect(
      router.requests.where((r) => r['path'] == '/api/v1/subjects'),
      isNotEmpty,
    );
    expect(
      router.requests.where((r) => r['path'] == '/api/v1/stats/streak'),
      isNotEmpty,
    );
    expect(
      router.requests.where((r) => r['path'] == '/api/v1/stats/summary'),
      isNotEmpty,
    );

    // 流彩层在位且在动（AnimatedBuilder 驱动）
    final ambient = find.byKey(const ValueKey('home-aurora-ambient'));
    expect(ambient, findsOneWidget);
    expect(
      find.descendant(of: ambient, matching: find.byType(AnimatedBuilder)),
      findsOneWidget,
    );

    // 配色随机而受控：painter 配色必为受控色池成员（会话级随机 session）
    final paintWidget = tester.widget<CustomPaint>(
      find.descendant(of: ambient, matching: find.byType(CustomPaint)),
    );
    final painter = paintWidget.painter as AuroraFlowPainter;
    expect(
      AuroraPalette.pool.contains(painter.palette),
      isTrue,
      reason: '流彩配色必须来自受控色池（会话级随机不越池）',
    );

    // 信息完整可读：标题 / 问候 / 到期大数字 / 三玻璃胶囊
    expect(find.text('恒牙'), findsOneWidget);
    expect(find.textContaining('今天也要巩固记忆'), findsOneWidget);
    expect(find.text('8'), findsOneWidget); // totalDue = 3 + 5
    expect(find.textContaining('张今日到期'), findsOneWidget);
    expect(find.textContaining('待审核 6'), findsOneWidget);
    expect(find.textContaining('连续 4 天'), findsOneWidget);
    expect(find.textContaining('7 天复习 21'), findsOneWidget);

    // 罗盘表盘按钮在位（进度数据接入见专项用例）
    expect(find.byType(CompassDialButton), findsOneWidget);
    expect(find.byTooltip('学习进度（学习罗盘）'), findsOneWidget);
  });

  testWidgets('关动效（信息明确硬约束）：disableAnimations → 流彩层静止、信息完整', (tester) async {
    await pumpPage(tester, disableAnimations: true);

    // 流彩层存在但不驱动（无 AnimatedBuilder → 静态一帧）
    final ambient = find.byKey(const ValueKey('home-aurora-ambient'));
    expect(ambient, findsOneWidget);
    expect(
      find.descendant(of: ambient, matching: find.byType(AnimatedBuilder)),
      findsNothing,
    );

    // 静态一帧的 painter：相位为 0，配色仍为受控色池成员
    final paintWidget = tester.widget<CustomPaint>(
      find.descendant(of: ambient, matching: find.byType(CustomPaint)),
    );
    final painter = paintWidget.painter as AuroraFlowPainter;
    expect(painter.t, 0);
    expect(AuroraPalette.pool.contains(painter.palette), isTrue);

    // 信息完整可读：Hero 关键信息全部在位
    expect(find.text('恒牙'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.textContaining('张今日到期'), findsOneWidget);
    expect(find.textContaining('待审核 6'), findsOneWidget);
    expect(find.textContaining('连续 4 天'), findsOneWidget);
    expect(find.textContaining('7 天复习 21'), findsOneWidget);
  });

  testWidgets('罗盘表盘：第四路 GET /progress 尽力而为接入，进度弧数据到位', (tester) async {
    await pumpPage(tester);

    // 第四路请求已发出（与三路主数据并发）
    expect(
      router.requests.where((r) => r['path'] == '/api/v1/progress'),
      isNotEmpty,
    );

    // 表盘按钮 + Tooltip 在位
    final dial = find.byType(CompassDialButton);
    expect(dial, findsOneWidget);
    expect(find.byTooltip('学习进度（学习罗盘）'), findsOneWidget);

    // 进度到位：endo 有罗盘 2/4、derm 无罗盘（textbook=null）不计入 → 0.5。
    // Sweep-in（600ms 隐式动画）用固定 pump 推进到收敛后读取。
    // Material(shape:) 自带 _ShapeBorderPainter 的 CustomPaint——按 painter
    // 类型精确定位表盘绘制那一枚
    await tester.pump(const Duration(milliseconds: 700));
    final paintWidget = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is CompassDialPainter,
      ),
    );
    final painter = paintWidget.painter as CompassDialPainter;
    expect(
      painter.fraction,
      closeTo(0.5, 1e-6),
      reason: '表盘进度必须与罗盘汇总口径一致（learned/total，无罗盘科目不计入）',
    );
  });

  testWidgets('罗盘表盘降级：progress 404（旧服务器）→ 空表盘在位、主数据不受影响', (tester) async {
    router.progressMissing = true; // 旧服务器（0.2.0）：/progress 404
    await pumpPage(tester);

    expect(
      router.requests.where((r) => r['path'] == '/api/v1/progress'),
      isNotEmpty,
    );

    // 尽力而为第四路不阻断：首页主数据照常渲染
    expect(find.text('恒牙'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.textContaining('待审核 6'), findsOneWidget);

    // 空表盘：fraction 0（无进度弧），按钮仍可点击进进度页（导航由 sweep 测试覆盖）
    final dial = find.byType(CompassDialButton);
    expect(dial, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 700));
    final paintWidget = tester.widget<CustomPaint>(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is CompassDialPainter,
      ),
    );
    final painter = paintWidget.painter as CompassDialPainter;
    expect(painter.fraction, 0, reason: '404 降级必须落到空表盘而非报错/阻断');
  });

  testWidgets('科目页动效组合（#14）：流彩①渐变流动 + 扫光②同屏在位且被驱动，卸载无泄漏', (tester) async {
    await pumpPage(tester);

    // ①渐变流动（既有 AuroraAmbient）：在位且被驱动
    final ambient = find.byKey(const ValueKey('home-aurora-ambient'));
    expect(ambient, findsOneWidget);
    expect(
      find.descendant(of: ambient, matching: find.byType(AnimatedBuilder)),
      findsOneWidget,
    );

    // ②shimmer 扫光（#14 新增 HeroShimmer）：在位且被驱动（AnimatedBuilder）
    final shimmer = find.byKey(const ValueKey('home-hero-shimmer'));
    expect(shimmer, findsOneWidget);
    expect(
      find.descendant(of: shimmer, matching: find.byType(AnimatedBuilder)),
      findsOneWidget,
    );

    // 相位随固定 pump 推进（6s 一轮，光带必然位移——蓝屏动效可感知）
    double shimmerPhase() {
      final paintWidget = tester.widget<CustomPaint>(
        find.descendant(of: shimmer, matching: find.byType(CustomPaint)),
      );
      return (paintWidget.painter as ShimmerSweepPainter).phase;
    }

    final p0 = shimmerPhase();
    await tester.pump(const Duration(milliseconds: 200));
    final p1 = shimmerPhase();
    expect(p1, greaterThan(p0), reason: '#14：扫光必须被驱动，蓝屏不能观感静止');

    // 有限 pump 若干帧不崩：页面渲染正常、Hero 信息完整可读
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('恒牙'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
    expect(find.textContaining('张今日到期'), findsOneWidget);
    // 卸载收尾在 pumpPage 的 addTearDown：控制器 dispose → Ticker 注销，
    // 若有泄漏框架以「active Ticker」自动判失败（结构性兜底）
  });
}
