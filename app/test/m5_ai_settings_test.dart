// M5 AI 服务配置测试：
// 掩码/未配置展示规则 · 防御式解析 · 演示后端 PUT 语义（留空保持 key）· 测试连接
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/api/demo_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------- 数据类：掩码 / 未配置态 ----------------

  test('AI 配置展示规则：已配置 → 掩码原样；未配置 → 「未配置」', () {
    const configured = AiServiceConfig(
      baseUrl: 'https://api.siliconflow.cn/v1',
      model: 'Qwen/Qwen3-32B',
      keySet: true,
      keyMasked: 'sk-****xy34',
      encrypted: true,
    );
    expect(configured.keyDisplay, 'sk-****xy34'); // 原样展示服务端掩码
    expect(configured.encryptedDisplay, '已加密');

    const unset = AiServiceConfig(
      baseUrl: '',
      model: '',
      keySet: false,
      keyMasked: '',
      encrypted: false,
    );
    expect(unset.keyDisplay, '未配置');
    expect(unset.encryptedDisplay, ''); // 未配置时不展示加密状态

    // keySet=true 但服务端报未加密
    const plain = AiServiceConfig(
      baseUrl: 'x',
      model: 'y',
      keySet: true,
      keyMasked: 'sk-**',
      encrypted: false,
    );
    expect(plain.encryptedDisplay, '未加密');
  });

  test('AiSettings.fromJson 防御式：缺失服务节点回退 empty，of() 取值正确', () {
    final s = AiSettings.fromJson({
      'llm': {
        'baseUrl': 'https://a.cn/v1',
        'model': 'm1',
        'keySet': true,
        'keyMasked': 'sk-****01',
        'encrypted': true,
      },
      // embedding 缺失 → empty
    });
    expect(s.llm.model, 'm1');
    expect(s.llm.keyDisplay, 'sk-****01');
    expect(s.embedding.keyDisplay, '未配置');
    expect(s.of('embedding').baseUrl, '');
    expect(s.of('llm').baseUrl, 'https://a.cn/v1');
  });

  test('更新/测试响应解析：UpdateResult 与 TestResult（含 display 一行式）', () {
    final u = AiServiceUpdateResult.fromJson(
        {'ok': true, 'keySet': true, 'keyMasked': 'sk-****zz'});
    expect(u.ok, isTrue);
    expect(u.keySet, isTrue);
    expect(u.keyMasked, 'sk-****zz');

    final okTest =
        AiServiceTestResult.fromJson({'ok': true, 'status': 200, 'latencyMs': 88, 'message': ''});
    expect(okTest.display, '连接正常 · 88 ms');

    final failTest = AiServiceTestResult.fromJson(
        {'ok': false, 'status': 401, 'latencyMs': 300, 'message': '鉴权失败'});
    expect(failTest.display, '失败：鉴权失败');
    expect(failTest.status, 401);
  });

  test('非法 service 名直接拒绝（llm | embedding 白名单）', () {
    expect(() => ApiClient.instance.updateAiService('chat',
        baseUrl: 'x', model: 'y'), throwsArgumentError);
    expect(() => ApiClient.instance.testAiService('vector',
        baseUrl: 'x', model: 'y'), throwsArgumentError);
  });

  // ---------------- 演示后端：PUT /settings/ai/<svc> ----------------

  test('演示后端：初始 GET /settings/ai 两套均未配置', () async {
    final res = await DemoBackend.instance.get('/api/v1/settings/ai');
    for (final svc in const ['llm', 'embedding']) {
      final cfg = res[svc] as Map<String, dynamic>;
      expect(cfg['keySet'], isFalse);
      expect(cfg['baseUrl'], '');
      expect(cfg['encrypted'], isTrue); // 演示态与服务端语义一致（加密存储）
    }
  });

  test('演示后端：PUT 存 key → keySet + 掩码；再 PUT 空 key → 保持不变', () async {
    // 第一次：带 key 保存
    final r1 = await DemoBackend.instance.put('/api/v1/settings/ai/llm', {
      'baseUrl': 'https://api.x.cn/v1',
      'model': 'qwen-max',
      'apiKey': 'sk-abcdef1234',
    });
    expect(r1['ok'], isTrue);
    expect(r1['keySet'], isTrue);
    expect(r1['keyMasked'], 'sk-****34'); // 掩码不可还原

    // 第二次：apiKey 空串 → 已存 key 保持不变（契约：空串=不改 key）
    final r2 = await DemoBackend.instance.put('/api/v1/settings/ai/llm', {
      'baseUrl': 'https://api.x.cn/v2',
      'model': 'qwen-plus',
      'apiKey': '',
    });
    expect(r2['ok'], isTrue);
    expect(r2['keySet'], isTrue);
    expect(r2['keyMasked'], 'sk-****34'); // 掩码未变 → key 未被清

    // GET 可见：新地址/模型生效 + key 仍是旧掩码
    final cfg = await DemoBackend.instance.get('/api/v1/settings/ai');
    final llm = cfg['llm'] as Map<String, dynamic>;
    expect(llm['baseUrl'], 'https://api.x.cn/v2');
    expect(llm['model'], 'qwen-plus');
    expect(llm['keyMasked'], 'sk-****34');
  });

  test('演示后端：PUT 新 key → 掩码更新；两套服务互不串扰', () async {
    await DemoBackend.instance.put('/api/v1/settings/ai/embedding', {
      'baseUrl': 'https://emb.x.cn/v1',
      'model': 'bge-m3',
      'apiKey': 'emb-999888',
    });
    await DemoBackend.instance.put('/api/v1/settings/ai/embedding', {
      'baseUrl': 'https://emb.x.cn/v1',
      'model': 'bge-m3',
      'apiKey': 'emb-newkey77',
    });
    final cfg = await DemoBackend.instance.get('/settings/ai');
    expect((cfg['embedding'] as Map)['keyMasked'], 'emb****77');
    // llm 不受影响（此前用例已存）
    expect((cfg['llm'] as Map)['model'], 'qwen-plus');
  });

  test('演示后端：POST /settings/ai/<svc>/test 恒连通（演示模式语义）', () async {
    final r = await DemoBackend.instance.post(
        '/api/v1/settings/ai/llm/test', {'baseUrl': 'x', 'model': 'y', 'apiKey': ''});
    expect(r['ok'], isTrue);
    expect(r['status'], 200);
    expect(r['latencyMs'], greaterThan(0));
    final parsed = AiServiceTestResult.fromJson(r);
    expect(parsed.display, startsWith('连接正常'));
  });

  test('演示后端：PUT 未知路径 → 404', () async {
    expectLater(
      DemoBackend.instance.put('/api/v1/settings/nope', {}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404)),
    );
  });
}
