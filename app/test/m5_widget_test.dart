// M5 组件级测试：
// 设置页 AI 配置/知识库区块（404 降级 → 「需服务器 0.3.0+」不崩溃；正常态渲染；
// 编辑层保存把 apiKey 送进 PUT 请求体并弹已保存提示）
// 关键词录入栏（科目拉取失败 → 回退内置 7 科 + 内联新建入口；新建对话框名称必填）
// 科目选择弹层（动态列表 + 内置标注 + 选中返回）
//
// 测试基建：TestWidgetsFlutterBinding 会把 HttpClient mock 成恒 400，且 widget
// 测试的 fake-async 环境里真实 socket 不可靠（实测会挂起）——改经
// [ApiClient.debugInjectHttpClient] 注入本文件实现的假 HttpClient：
// 按契约路由应答、录制请求（方法/路径/体），可精确模拟 404/拒连，全程微任务即答。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hengya/pages/inbox_sheet.dart';
import 'package:hengya/pages/settings_page.dart';
import 'package:hengya/pages/subject_picker.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/corpus/run_llm.dart'
    show llmListModelsOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------- AI 编辑层输入框定位 ----------------

/// AI 编辑层（showModalBottomSheet）内三输入框的定位器。
/// 2026-09-07 batch3 node1：设置页新增「应用内更新」源输入框（页内常驻
/// TextField），全树 find.byType(TextField) 不再恰好等于编辑层三字段——
/// 收窄到 BottomSheet 子树，保持本套件既有意图（编辑层三字段驱动）不变。
Finder aiSheetFields() => find.descendant(
    of: find.byType(BottomSheet), matching: find.byType(TextField));

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
  }) =>
      Stream.fromIterable([utf8.encode(bodyText)]).listen(onData,
          onError: onError, onDone: onDone, cancelOnError: cancelOnError);

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

/// 契约路由：录制全部请求，按 path+method 应答；all404 模拟旧服务器（0.2.0），
/// refused 模拟断网（getUrl/postUrl 直接抛 SocketException）。
class _FakeRouter {
  final requests = <Map<String, dynamic>>[];
  bool all404 = false;
  bool refused = false;

  static const _settingsAi = {
    'llm': {
      'baseUrl': 'https://a.cn/v1',
      'model': 'm1',
      'keySet': true,
      'keyMasked': 'sk-****xy',
      'encrypted': true,
    },
    'embedding': {
      'baseUrl': 'https://b.cn/v1',
      'model': 'bge-m3',
      'keySet': true,
      'keyMasked': 'emb-****99',
      'encrypted': true,
    },
  };

  /// reranker 节点：null = 模拟旧服务器响应（缺节点 → App 防御式回退 empty，
  /// 编辑层预填 SiliconFlow 默认值）；默认给已配置态供正常断言。
  Map<String, dynamic>? rerankerCfg = const {
    'baseUrl': 'https://r.cn/v1/rerank',
    'model': 'Qwen/Qwen3-Reranker-8B',
    'keySet': true,
    'keyMasked': 'rr-****88',
    'encrypted': true,
  };

  /// `POST /api/v1/settings/ai/reranker/test` 应答体（成功/失败按用例覆写）
  Map<String, dynamic> rerankerTestResponse = const {
    'ok': true,
    'status': 200,
    'latencyMs': 77,
    'message': '',
  };

  static const _subjects = {
    'subjects': [
      {'id': 'oms', 'name': '口腔颌面外科学', 'dueCount': 2},
      {'id': 'perio', 'name': '牙周病学', 'dueCount': 0},
    ],
  };

  static const _corpus = {
    'totalChunks': 42,
    'subjects': {'oms': 18},
    'lastBuild': null,
    'pendingFiles': 2,
    'storageMB': 3.2,
  };

  _FakeHttpClientRequest open(String method, Uri url) {
    if (refused) {
      throw const SocketException('connection refused (假路由：模拟断网)');
    }
    return _FakeHttpClientRequest(method, url, this);
  }

  HttpClientResponse respond(String method, Uri url,
      _FakeHttpHeaders headers, List<int> bytes) {
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
      case 'GET /api/v1/settings/ai':
        return _ok({
          ..._settingsAi,
          if (rerankerCfg != null) 'reranker': rerankerCfg,
        });
      case 'PUT /api/v1/settings/ai/llm':
        return _ok({'ok': true, 'keySet': true, 'keyMasked': 'sk-****zz'});
      case 'PUT /api/v1/settings/ai/reranker':
        return _ok({'ok': true, 'keySet': true, 'keyMasked': 'rr-****zz'});
      case 'POST /api/v1/settings/ai/embedding/test':
        return _ok({'ok': true, 'status': 200, 'latencyMs': 77, 'message': ''});
      case 'POST /api/v1/settings/ai/llm/test':
        // #2：llm 测试连接（连通性 ok；model 在列核对经 llmListModelsOverride
        // 离线注入，不走网络）
        return _ok({'ok': true, 'status': 200, 'latencyMs': 77, 'message': ''});
      case 'POST /api/v1/settings/ai/reranker/test':
        return _ok(rerankerTestResponse);
      case 'GET /api/v1/corpus/status':
        return _ok(_corpus);
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

  setUpAll(() {
    SharedPreferences.setMockInitialValues({});
  });

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
    llmListModelsOverride = null; // #2 注入 seam 用完即清（生产恢复真外呼）
    ApiClient.instance.debugInjectHttpClient(null); // 恢复默认链路
    ApiClient.instance.baseUrl = 'http://10.0.2.2:8080';
    ApiClient.instance.resetSubjectCaches();
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    // 设置页 ListView 懒构建：默认 800×600 视口装不下新增区块（AI/知识库在
    // 数据与同步之后），拉高视口让全页都在渲染范围内（断言/点击都需要）
    tester.view.physicalSize = const Size(800, 2200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pumpAndSettle(); // 假路由即答（微任务）→ settle 即得最终 UI
  }

  testWidgets('设置页 404 降级：AI 配置与知识库区块显示「需服务器 0.3.0+」，不崩溃',
      (tester) async {
    router.all404 = true; // 旧服务器（0.2.0）：新增端点全部 404
    await pumpSettings(tester);
    // 两处新区块（AI 服务配置 + 知识库）都降级提示
    expect(find.textContaining('需服务器 0.3.0+，暂未部署'), findsNWidgets(2));
    // 页面其余部分照常渲染
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('每日提醒'), findsOneWidget);
    expect(find.text('关于'), findsOneWidget);
  });

  testWidgets('设置页正常态：两套 AI 卡片 + 掩码 + 知识库状态可见', (tester) async {
    await pumpSettings(tester);
    expect(find.text('生卡 LLM'), findsOneWidget);
    expect(find.text('向量模型'), findsOneWidget);
    // 服务端掩码原样展示 + 加密态
    expect(find.text('Key：sk-****xy · 已加密'), findsOneWidget);
    expect(find.text('Key：emb-****99 · 已加密'), findsOneWidget);
    // reranker（Phase 4 检索引擎）：第三张卡照常掩码展示
    expect(find.text('重排序模型'), findsOneWidget);
    expect(find.textContaining('知识库检索精排用'), findsOneWidget);
    expect(find.text('Key：rr-****88 · 已加密'), findsOneWidget);
    expect(find.text('地址：https://r.cn/v1/rerank'), findsOneWidget);
    // 知识库状态卡：块数/存储/待处理队列/科目分布（设置页不拉科目目录，
    // 名称缓存未命中 → 原样 id 渲染——0.3.1 起无内置短名兜底）
    expect(find.text('语料库'), findsOneWidget);
    expect(find.textContaining('42 块语料 · 3.2 MB'), findsOneWidget);
    expect(find.textContaining('oms 18'), findsOneWidget);
    expect(find.text('上传课件'), findsOneWidget);
    expect(find.textContaining('当前 2 个'), findsOneWidget);
  });

  testWidgets('AI 编辑层：apiKey 送进 PUT 请求体 → 保存成功弹提示并关闭',
      (tester) async {
    await pumpSettings(tester);
    // 打开生卡 LLM 编辑层
    await tester.tap(find.text('生卡 LLM'));
    await tester.pumpAndSettle();
    expect(find.text('编辑生卡 LLM'), findsOneWidget);
    expect(find.text('当前 Key：sk-****xy · 已加密'), findsOneWidget);
    // baseUrl/model 已预填；向 apiKey 字段（第 3 个输入框）输入明文 key
    final fields = aiSheetFields();
    expect(fields, findsNWidgets(3));
    await tester.enterText(fields.at(2), 'sk-test-123');
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // TopToast 停留(满透明)窗内断言

    // PUT 请求体三字段：baseUrl/model 预填值 + 明文 key（只进请求体，不落本地）
    final put = router.requests.lastWhere(
        (r) => r['method'] == 'PUT' && r['path'] == '/api/v1/settings/ai/llm');
    expect(jsonDecode(put['body'] as String), {
      'baseUrl': 'https://a.cn/v1',
      'model': 'm1',
      'apiKey': 'sk-test-123',
    });
    // 成功提示可见；编辑层已关闭
    expect(find.text('已保存 AI 服务配置'), findsOneWidget);
    expect(find.text('编辑生卡 LLM'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1000)); // 走完气泡生命周期，清移除 Timer
  });

  testWidgets('AI 编辑层：测试连接按钮展示 ok + 延迟', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('向量模型'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接正常 · 77 ms'), findsOneWidget);
  });

  // ---------------- #2（2026-09-07）：llm 测试连接成功后的 model 在列核对 ----------------
  // /models 列表经 run_llm.llmListModelsOverride 离线注入（生产真外呼；
  // testWidgets 假异步真网络必死锁）。remote 模式 + 假 HttpClient 路由
  // POST /settings/ai/llm/test 返回连通 ok → UI 再核对 model。

  testWidgets('LLM 编辑层（#2 分支一）：model 在 /models 列表 → 正常成功行', (tester) async {
    llmListModelsOverride = (baseUrl, apiKey) async => ['m1', 'gpt-4o-mini'];
    await pumpSettings(tester);
    await tester.tap(find.text('生卡 LLM'));
    await tester.pumpAndSettle();
    // 配置已回显（baseUrl=https://a.cn/v1、model=m1）；输入 key 启用在列核对
    //（remote 模式 key 留空时在服务端拿不到 → 跳过核对——分支一必须给 key）
    await tester.enterText(aiSheetFields().at(2), 'sk-llm-key');
    await tester.pump();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(find.text('连接正常 · 77 ms'), findsOneWidget,
        reason: '#2：model 在列表 → 维持正常成功提示');
    expect(find.textContaining('不在服务方模型列表'), findsNothing,
        reason: '在列表时不得出现警示文案');
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing,
        reason: '在列表时不得出现警示图标');
    // 核对请求经注入 seam：入参 = 表单 baseUrl / key（无网络）
    final post = router.requests.lastWhere((r) =>
        r['method'] == 'POST' && r['path'] == '/api/v1/settings/ai/llm/test');
    expect(jsonDecode(post['body'] as String), {
      'baseUrl': 'https://a.cn/v1',
      'model': 'm1',
      'apiKey': 'sk-llm-key',
    });
  });

  testWidgets('LLM 编辑层（#2 分支二）：model 不在列表 → 橙色警示行，不阻断保存', (tester) async {
    llmListModelsOverride = (baseUrl, apiKey) async => ['gpt-4o-mini'];
    await pumpSettings(tester);
    await tester.tap(find.text('生卡 LLM'));
    await tester.pumpAndSettle();
    await tester.enterText(aiSheetFields().at(2), 'sk-llm-key');
    await tester.pump();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();
    expect(
        find.text('连接成功，但 model m1 不在服务方模型列表'), findsOneWidget,
        reason: '#2：连接成功但 model 不在列表 → 逐字警示文案');
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget,
        reason: '警示行用橙色警示图标（区别于成功对勾/失败红）');
    // 不阻断保存：点保存 → PUT 正常发出 → 成功气泡 + 弹层关闭
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // TopToast 停留窗内
    final put = router.requests.lastWhere(
        (r) => r['method'] == 'PUT' && r['path'] == '/api/v1/settings/ai/llm');
    expect(jsonDecode(put['body'] as String), {
      'baseUrl': 'https://a.cn/v1',
      'model': 'm1',
      'apiKey': 'sk-llm-key',
    }, reason: '#2 明确要求不阻断保存——警示只提示');
    expect(find.text('已保存 AI 服务配置'), findsOneWidget);
    expect(find.text('编辑生卡 LLM'), findsNothing);
    await tester.pump(const Duration(milliseconds: 1000)); // 走完气泡生命周期
  });

  testWidgets('重排序编辑层（未配置态）：预填 SiliconFlow 默认端点+模型，保存三字段入 PUT',
      (tester) async {
    router.rerankerCfg = null; // 旧服务器响应缺 reranker 节点 → 未配置态
await pumpSettings(tester);
    // 卡片空态占位（收窄到重排序卡内部——备用生卡 LLM 未配置时也有「地址：—」）
    expect(
      find.descendant(
        of: find.widgetWithText(Card, '重排序模型'),
        matching: find.text('地址：—'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('重排序模型'));
    await tester.pumpAndSettle();
    expect(find.text('编辑重排序模型'), findsOneWidget);
    expect(find.text('当前 Key：未配置'), findsOneWidget);
    // 三字段：URL=完整 rerank 端点 / 模型名 / key（明文只进请求体）
    final fields = aiSheetFields();
    expect(fields, findsNWidgets(3));
    expect(
      tester.widget<TextField>(fields.at(0)).controller?.text,
      ApiClient.kRerankerDefaultUrl,
    );
    expect(
      tester.widget<TextField>(fields.at(1)).controller?.text,
      ApiClient.kRerankerDefaultModel,
    );
    await tester.enterText(fields.at(2), 'rr-fake-w1');
    await tester.pump();

    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500)); // TopToast 停留窗内

    final put = router.requests.lastWhere(
        (r) => r['method'] == 'PUT' && r['path'] == '/api/v1/settings/ai/reranker');
    expect(jsonDecode(put['body'] as String), {
      'baseUrl': ApiClient.kRerankerDefaultUrl,
      'model': ApiClient.kRerankerDefaultModel,
      'apiKey': 'rr-fake-w1',
    });
    expect(find.text('已保存 AI 服务配置'), findsOneWidget);
    expect(find.text('编辑重排序模型'), findsNothing); // 编辑层已关闭
    await tester.pump(const Duration(milliseconds: 1000)); // 走完气泡生命周期
  });

  testWidgets('重排序编辑层：测试连接成功 → 内联结果 + TopToast 双反馈', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('重排序模型'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('测试连接'));
    await tester.pump(); // 微任务应答 + setState + 气泡插入
    await tester.pump(const Duration(milliseconds: 500)); // 进入完成+停留窗内

    // 同文案出现两处：编辑层内联结果行 + 顶部气泡（reranker 专属 TopToast 反馈）
    expect(find.text('连接正常 · 77 ms'), findsNWidgets(2));
    // POST 请求体：已配置值 + 空 key（空 = 用已存 key）
    final post = router.requests.lastWhere((r) =>
        r['method'] == 'POST' && r['path'] == '/api/v1/settings/ai/reranker/test');
    expect(jsonDecode(post['body'] as String), {
      'baseUrl': 'https://r.cn/v1/rerank',
      'model': 'Qwen/Qwen3-Reranker-8B',
      'apiKey': '',
    });
    await tester.pump(const Duration(milliseconds: 2000)); // 走完气泡生命周期
  });

  testWidgets('重排序编辑层：测试连接失败 → TopToast 透传上游裸 message', (tester) async {
    router.rerankerTestResponse = const {
      'ok': false,
      'status': 401,
      'latencyMs': 120,
      'message': 'Invalid token', // 上游裸 message
    };
    await pumpSettings(tester);
    await tester.tap(find.text('重排序模型'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('测试连接'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // 气泡 = 裸 message 原样透传；编辑层内联行 = 失败：前缀
    expect(find.text('Invalid token'), findsOneWidget);
    expect(find.text('失败：Invalid token'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 2500)); // 走完气泡生命周期
  });

  testWidgets('关键词录入栏：科目拉取失败 → 空态 + 重试提示 + 内联「新建课程」入口',
      (tester) async {
    router.refused = true; // 模拟断网：拉取失败 → 不再回退硬编码清单

    await tester.pumpWidget(MaterialApp(
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
    ));
    await tester.tap(find.text('打开录入栏'));
    await tester.pumpAndSettle();

    // 0.3.1 起无内置科目兜底：科目 chip 区为空
    expect(find.byType(ChoiceChip), findsNothing);
    // 内联新建入口仍在 + 失败提示（右上角刷新可重试）
    expect(find.text('新建课程'), findsOneWidget);
    expect(find.text('科目列表读取失败，可点右上角刷新重试'), findsOneWidget);
  });

  testWidgets('新建课程对话框：名称必填（空名称拦截，不发请求）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showCreateSubjectDialog(ctx),
              child: const Text('打开新建'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开新建'));
    await tester.pumpAndSettle();
    expect(find.text('新建课程'), findsOneWidget);

    await tester.tap(find.text('创建')); // 名称留空 → 本地校验拦截
    await tester.pumpAndSettle();
    expect(find.text('课程名称必填'), findsOneWidget);
    expect(find.text('新建课程'), findsOneWidget); // 对话框未关
    expect(router.requests, isEmpty); // 未发任何网络请求
  });

  testWidgets('科目选择弹层（课件上传用）：动态列表 + 选中返回', (tester) async {
    SubjectInfo? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async {
                picked = await showSubjectPickerSheet(ctx, title: '课件归属科目');
              },
              child: const Text('选择科目'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('选择科目'));
    await tester.pumpAndSettle();

    expect(find.text('课件归属科目'), findsOneWidget);
    // 动态科目：服务端两科（含用户自建）+ 内联新建入口；0.3.1 起无「内置」角标
    expect(find.text('口腔颌面外科学'), findsOneWidget);
    expect(find.text('牙周病学'), findsOneWidget);
    expect(find.text('内置'), findsNothing);
    expect(find.text('新建课程'), findsOneWidget);

    // 选中第一科 → 弹层返回该科目
    await tester.tap(find.text('口腔颌面外科学'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'oms');
  });
}
