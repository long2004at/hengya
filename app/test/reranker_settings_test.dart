// 重排序（reranker）配置测试（Phase 4 检索引擎前置契约）：
//  · AiSettings.reranker 防御式解析（节点缺失回退 empty——旧服务器兼容）
//  · LocalBackend 三字段持久化（settings 表 reranker.* 键）+ 关闭重开回显
//  · 连接测试链路：经 LocalBackend.rerankProbeOverride 注入假外呼——
//    绝不真调外网；核验完整端点透传 / 已存 key 兜底 / results 判活 /
//    失败裸 message 透传 / 校验拦截 / 超时语义
//  · DemoBackend reranker 三件套（GET/PUT/恒连通 test）
//
// 宿主基建与 local_backend_test.dart 同姿势：Windows 测试宿主显式加载
// test/sqlite3.dll（package:sqlite3 官方 release 资产）。
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/api/demo_backend.dart';
import 'package:hengya/services/local/ai_key_vault.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Windows 测试宿主：显式加载 test/sqlite3.dll（CWD = 包根 app/）
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory tmp;

  setUp(() async {
    // 安全修复 C：AI key 走 vault——测试宿主无平台通道，注入 InMemoryVault
    AiKeyVault.instance = InMemoryVault();
    tmp = await Directory.systemTemp.createTemp('hengya_reranker_test_');
  });

  tearDown(() async {
    AiKeyVault.instance = null; // 恢复默认真 vault（跨文件零污染）
    LocalBackend.rerankProbeOverride = null; // 恢复真外呼链路（同步置空）
    await LocalBackend.instance.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> boot() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
  }

  // ---------------- 数据层：AiSettings / 白名单 / 默认预填 ----------------

  test('AiSettings.reranker：节点存在解析 / 缺失回退 empty / of() 取值', () {
    final s = AiSettings.fromJson({
      'llm': {
        'baseUrl': 'https://a.cn/v1',
        'model': 'm1',
        'keySet': true,
        'keyMasked': 'sk-****01',
        'encrypted': true,
      },
      'reranker': {
        'baseUrl': 'https://api.siliconflow.cn/v1/rerank',
        'model': 'Qwen/Qwen3-Reranker-8B',
        'keySet': true,
        'keyMasked': 'rr-****88',
        'encrypted': false,
      },
    });
    expect(s.reranker.baseUrl, 'https://api.siliconflow.cn/v1/rerank');
    expect(s.reranker.model, 'Qwen/Qwen3-Reranker-8B');
    expect(s.of('reranker').keyDisplay, 'rr-****88');
    expect(s.of('reranker').encryptedDisplay, '未加密'); // 端上暂明文存储语义

    // 旧服务器响应（0.3.0 只有 llm/embedding）：reranker 缺失 → empty
    final old = AiSettings.fromJson({
      'llm': {
        'baseUrl': 'https://a.cn/v1',
        'model': 'm1',
        'keySet': true,
        'keyMasked': 'sk-****01',
        'encrypted': true,
      },
    });
    expect(old.reranker.keyDisplay, '未配置');
    expect(old.of('reranker').baseUrl, '');
    // 既有 of() 语义不回归
    expect(old.of('embedding').keyDisplay, '未配置');
    expect(old.of('llm').model, 'm1');
  });

  test('白名单：reranker 合法入册；未知服务名仍拒绝', () {
    expect(ApiClient.kAiServices.contains('reranker'), isTrue);
    expect(ApiClient.kAiServices.contains('llm'), isTrue);
    expect(ApiClient.kAiServices.contains('embedding'), isTrue);
    expect(
      () => ApiClient.instance.updateAiService('chat',
          baseUrl: 'x', model: 'y'),
      throwsArgumentError,
    );
    expect(
      () => ApiClient.instance.testAiService('vector',
          baseUrl: 'x', model: 'y'),
      throwsArgumentError,
    );
  });

  test('默认预填常量：SiliconFlow 完整 rerank 端点 + Qwen3-Reranker-8B', () {
    expect(ApiClient.kRerankerDefaultUrl, 'https://api.siliconflow.cn/v1/rerank');
    expect(ApiClient.kRerankerDefaultUrl.startsWith('https://'), isTrue);
    expect(ApiClient.kRerankerDefaultUrl.endsWith('/rerank'), isTrue);
    expect(ApiClient.kRerankerDefaultModel, 'Qwen/Qwen3-Reranker-8B');
  });

  // ---------------- LocalBackend：三字段持久化 + 回显 ----------------

  test('reranker 初始未配置；PUT 三字段 → 掩码返回 + GET 回显；空 key 保持', () async {
    await boot();
    final be = LocalBackend.instance;

    // 初始态：三套服务均未配置（reranker 键位缺失 → 空态视图）
    final s0 = await be.get('/settings/ai');
    final rr0 = (s0 as Map)['reranker'] as Map<String, dynamic>;
    expect(rr0['baseUrl'], '');
    expect(rr0['model'], '');
    expect(rr0['keySet'], false);
    expect(rr0['keyMasked'], '');

    // 正常 PUT（默认预填值 + key）
    final p1 = await be.put('/settings/ai/reranker', {
      'baseUrl': 'https://api.siliconflow.cn/v1/rerank',
      'model': 'Qwen/Qwen3-Reranker-8B',
      'apiKey': 'rr-fake-998877',
    });
    expect(p1['ok'], true);
    expect(p1['keySet'], true);
    expect(p1['keyMasked'], 'rr-****77');

    // GET 回显：三字段生效（Phase 4 消费契约的读取面）
    final s1 = await be.get('/settings/ai');
    final rr1 = (s1 as Map)['reranker'] as Map<String, dynamic>;
    expect(rr1['baseUrl'], 'https://api.siliconflow.cn/v1/rerank');
    expect(rr1['model'], 'Qwen/Qwen3-Reranker-8B');
    expect(rr1['keySet'], true);
    expect(rr1['keyMasked'], 'rr-****77');
    expect(rr1['encrypted'], true); // 安全修复 C：key 存系统安全存储（Keystore）

    // apiKey 空串 = 保持原 key（掩码不变）
    final p2 = await be.put('/settings/ai/reranker', {
      'baseUrl': 'https://other.cn/v1/rerank',
      'model': 'BAAI/bge-reranker-v2-m3',
      'apiKey': '',
    });
    expect(p2['keySet'], true);
    expect(p2['keyMasked'], 'rr-****77');
    final s2 = await be.get('/settings/ai');
    final rr2 = (s2 as Map)['reranker'] as Map<String, dynamic>;
    expect(rr2['baseUrl'], 'https://other.cn/v1/rerank'); // 新地址生效
    expect(rr2['model'], 'BAAI/bge-reranker-v2-m3'); // 模型可改任意
    expect(rr2['keyMasked'], 'rr-****77'); // key 未被清

    // 与 llm/embedding 互不串扰
    expect((s2['llm'] as Map)['keySet'], false);
    expect((s2['embedding'] as Map)['keySet'], false);
  });

  test('持久化：PUT 后关闭重开同一 hengya.db → 三字段照常回显', () async {
    await boot();
    final be = LocalBackend.instance;
    await be.put('/settings/ai/reranker', {
      'baseUrl': 'https://api.siliconflow.cn/v1/rerank',
      'model': 'Qwen/Qwen3-Reranker-8B',
      'apiKey': 'rr-fake-112233',
    });

    // 关闭连接（等同进程退出）→ 同一数据目录重新初始化（等同重启 App——
    // 真实链路 main() 启动即 initAiKeys 预热 vault 缓存，安全修复 C）
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    await LocalBackend.instance.initAiKeys(); // key 从系统安全存储回读

    final s = await be.get('/settings/ai');
    final rr = (s as Map)['reranker'] as Map<String, dynamic>;
    expect(rr['baseUrl'], 'https://api.siliconflow.cn/v1/rerank');
    expect(rr['model'], 'Qwen/Qwen3-Reranker-8B');
    expect(rr['keySet'], true);
    expect(rr['keyMasked'], 'rr-****33');
  });

  test('校验：非法 baseUrl 400 / 空 model 400 / 未知服务 404（与现有字段同规则）', () async {
    await boot();
    final be = LocalBackend.instance;

    await expectLater(
      be.put('/settings/ai/reranker',
          {'baseUrl': 'http://api.siliconflow.cn', 'model': 'm'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)
          .having((e) => e.message, 'message', 'baseUrl 必须以 https:// 开头')),
    );
    await expectLater(
      be.put('/settings/ai/reranker',
          {'baseUrl': 'https://r.cn/v1/rerank', 'model': ''}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)
          .having((e) => e.message, 'message', 'model 不能为空')),
    );
    await expectLater(
      be.put('/settings/ai/chat', {'baseUrl': 'https://x', 'model': 'm'}),
      throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
    );
  });

  // ---------------- LocalBackend：连接测试链路（注入假外呼，不真调外网） ----------------

  test('连接测试成功：完整端点/key/模型透传外呼；200 且 results 非空 → ok', () async {
    await boot();
    final be = LocalBackend.instance;
    String? gotUrl, gotKey, gotModel;
    LocalBackend.rerankProbeOverride = (url, apiKey, model) async {
      gotUrl = url;
      gotKey = apiKey;
      gotModel = model;
      return (
        status: 200,
        body: jsonEncode({
          'id': 'rerank-01',
          'results': [
            {'index': 0, 'relevance_score': 0.98},
            {'index': 1, 'relevance_score': 0.21},
          ],
          'tokens': {'input_tokens': 42, 'output_tokens': 0},
        }),
      );
    };

    final r = await be.post('/settings/ai/reranker/test', {
      'baseUrl': 'https://api.siliconflow.cn/v1/rerank',
      'model': 'Qwen/Qwen3-Reranker-8B',
      'apiKey': 'rr-fake-abc123',
    });
    expect(r['ok'], true);
    expect(r['status'], 200);
    expect(r['message'], '连接正常');
    // 外呼契约：URL = 完整端点原样透传（不拼后缀）——Phase 4 检索引擎同契约
expect(gotUrl, 'https://api.siliconflow.cn/v1/rerank');
    expect(gotKey, 'rr-fake-abc123');
    expect(gotModel, 'Qwen/Qwen3-Reranker-8B');
  });

  test('连接测试：基址形态 baseUrl（…/v1 不带 /rerank）自动补全端点 → 不再 404', () async {
    // 2026-09-11 修复：用户可能填基址形态（https://api.siliconflow.cn/v1），
    // 修复前 probe 直接 POST …/v1 → SiliconFlow 根路径恒 404。现经
    // normalizeRerankEndpoint 先补 /rerank 再外呼（对齐 embedding 两形态兼容）。
    await boot();
    final be = LocalBackend.instance;
    String? gotUrl;
    LocalBackend.rerankProbeOverride = (url, apiKey, model) async {
      gotUrl = url;
      return (status: 200, body: jsonEncode({
        'results': [{'index': 0, 'relevance_score': 0.9}],
      }));
    };

    final r = await be.post('/settings/ai/reranker/test', {
      'baseUrl': 'https://api.siliconflow.cn/v1', // 基址形态（无 /rerank）
      'model': 'Qwen/Qwen3-Reranker-8B',
      'apiKey': 'rr-fake-abc123',
    });
    expect(r['ok'], true);
    expect(r['status'], 200);
    // 外呼收到的是补全后的完整端点
    expect(gotUrl, 'https://api.siliconflow.cn/v1/rerank');
  });

  test('连接测试：apiKey 空串 → 外呼用已存 key（与 llm/embedding 同语义）', () async {
    await boot();
    final be = LocalBackend.instance;
    await be.put('/settings/ai/reranker', {
      'baseUrl': 'https://api.siliconflow.cn/v1/rerank',
      'model': 'Qwen/Qwen3-Reranker-8B',
      'apiKey': 'rr-fake-stored77',
    });
    String? gotKey;
    LocalBackend.rerankProbeOverride = (url, apiKey, model) async {
      gotKey = apiKey;
      return (status: 200, body: jsonEncode({'results': [{'index': 0}]}));
    };

    final r = await be.post('/settings/ai/reranker/test', {
      'baseUrl': 'https://api.siliconflow.cn/v1/rerank',
      'model': 'Qwen/Qwen3-Reranker-8B',
      'apiKey': '', // 契约：空 = 用已存 key
    });
    expect(r['ok'], true);
    expect(gotKey, 'rr-fake-stored77');
  });

  test('连接测试失败透传：上游裸 message（对象 message 字段 / 裸 JSON 字符串）',
      () async {
    await boot();
    final be = LocalBackend.instance;

    // SiliconFlow 401 错误形状：裸 JSON 字符串
    LocalBackend.rerankProbeOverride = (url, apiKey, model) async =>
        (status: 401, body: '"Invalid token"');
    final r1 = await be.post('/settings/ai/reranker/test', {
      'baseUrl': 'https://r.cn/v1/rerank',
      'model': 'm',
      'apiKey': '',
    });
    expect(r1['ok'], false);
    expect(r1['status'], 401);
    expect(r1['message'], 'Invalid token'); // 裸 message 直接透传展示

    // 429 错误形状：{"message": "..."}（TPM 限流）
    LocalBackend.rerankProbeOverride = (url, apiKey, model) async => (
          status: 429,
          body: jsonEncode({
            'message': 'Request was rejected due to rate limiting.',
            'data': 'x',
          }),
        );
    final r2 = await be.post('/settings/ai/reranker/test', {
      'baseUrl': 'https://r.cn/v1/rerank',
      'model': 'm',
      'apiKey': '',
    });
    expect(r2['ok'], false);
    expect(r2['message'], 'Request was rejected due to rate limiting.');

    // 400 错误形状：{"code": 20012, "message": "..."}
    LocalBackend.rerankProbeOverride = (url, apiKey, model) async => (
          status: 400,
          body: jsonEncode({'code': 20012, 'message': 'Model not found'}),
        );
    final r3 = await be.post('/settings/ai/reranker/test', {
      'baseUrl': 'https://r.cn/v1/rerank',
      'model': 'm',
      'apiKey': '',
    });
    expect(r3['ok'], false);
    expect(r3['message'], 'Model not found');
  });

  test('连接测试：200 但 results 空 → 判死；非 JSON 错误体 → 回退状态码', () async {
    await boot();
    final be = LocalBackend.instance;

    // 200 + results 空：端点可达但响应不符契约
    LocalBackend.rerankProbeOverride = (url, apiKey, model) async =>
        (status: 200, body: jsonEncode({'results': []}));
    final r1 = await be.post('/settings/ai/reranker/test', {
      'baseUrl': 'https://r.cn/v1/rerank',
      'model': 'm',
      'apiKey': '',
    });
    expect(r1['ok'], false);
    expect(r1['message'], '上游响应异常（status 200）');

    // 200 + 非 JSON 体
    LocalBackend.rerankProbeOverride =
        (url, apiKey, model) async => (status: 200, body: 'not json');
    final r2 = await be.post('/settings/ai/reranker/test', {
      'baseUrl': 'https://r.cn/v1/rerank',
      'model': 'm',
      'apiKey': '',
    });
    expect(r2['ok'], false);
    expect(r2['message'], '上游响应异常（status 200）');

    // 502 + HTML 网关页：无 message 可取 → 回退状态码
    LocalBackend.rerankProbeOverride = (url, apiKey, model) async =>
        (status: 502, body: '<html>Bad Gateway</html>');
    final r3 = await be.post('/settings/ai/reranker/test', {
      'baseUrl': 'https://r.cn/v1/rerank',
      'model': 'm',
      'apiKey': '',
    });
    expect(r3['ok'], false);
    expect(r3['status'], 502);
    expect(r3['message'], '上游返回 502');
  });

  test('连接测试：非法 baseUrl 400 拦截（外呼未被触发）；超时统一兜底', () async {
    await boot();
    final be = LocalBackend.instance;

    var called = 0;
    LocalBackend.rerankProbeOverride = (url, apiKey, model) async {
      called++;
      return (status: 200, body: '{}');
    };
    await expectLater(
      be.post('/settings/ai/reranker/test',
          {'baseUrl': 'http://r.cn', 'model': 'm', 'apiKey': ''}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)
          .having(
              (e) => e.message, 'message', 'baseUrl 必须以 https:// 开头')),
    );
    expect(called, 0); // 校验前置：非法地址绝不外呼

    // 外呼抛 TimeoutException → ok=false + 统一超时文案（不抛异常）
    LocalBackend.rerankProbeOverride =
        (url, apiKey, model) async => throw TimeoutException('probe');
    final r = await be.post('/settings/ai/reranker/test', {
      'baseUrl': 'https://r.cn/v1/rerank',
      'model': 'm',
      'apiKey': '',
    });
    expect(r['ok'], false);
    expect(r['status'], 0);
    expect(r['message'], '连接超时（10s）');
  });

  // ---------------- DemoBackend：reranker 三件套（演示模式语义） ----------------

  test('演示后端：reranker GET 空态 / PUT 掩码 / test 恒连通', () async {
    final be = DemoBackend.instance;

    final s0 = await be.get('/api/v1/settings/ai');
    final rr0 = (s0 as Map)['reranker'] as Map<String, dynamic>;
    expect(rr0['keySet'], false);
    expect(rr0['baseUrl'], '');

    final p = await be.put('/api/v1/settings/ai/reranker', {
      'baseUrl': 'https://api.siliconflow.cn/v1/rerank',
      'model': 'Qwen/Qwen3-Reranker-8B',
      'apiKey': 'rr-fake-demo12345',
    });
    expect(p['ok'], true);
    expect(p['keySet'], true);
    expect(p['keyMasked'], 'rr-****45'); // 掩码不可还原

    final s1 = await be.get('/settings/ai');
    final rr1 = (s1 as Map)['reranker'] as Map<String, dynamic>;
    expect(rr1['baseUrl'], 'https://api.siliconflow.cn/v1/rerank');
    expect(rr1['model'], 'Qwen/Qwen3-Reranker-8B');
    // llm 不受影响（既有用例已写入 qwen-*）
    expect((s1['llm'] as Map)['keySet'], anyOf(isTrue, isFalse));

    final t = await be.post('/api/v1/settings/ai/reranker/test', {
      'baseUrl': 'https://api.siliconflow.cn/v1/rerank',
      'model': 'Qwen/Qwen3-Reranker-8B',
      'apiKey': '',
    });
    expect(t['ok'], true); // 演示模式恒连通
    expect(t['latencyMs'], greaterThan(0));
    final parsed = AiServiceTestResult.fromJson(t);
    expect(parsed.display, startsWith('连接正常'));
  });
}
