// P2.4 聊天服务设置路由测试：LocalBackend settings/ai 扩展 svc='chat'——
// PUT 校验（http 拒绝/空 model 拒绝/未知服务 404）、key 空保持原值、
// keyMasked 回显、GET 掩码视图、key 不落 settings 表明文。
// 与 local_backend_test.dart 同姿势（InMemoryVault + 临时 SQLite + 直调路由）。
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/ai_key_vault.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Windows 测试宿主：显式加载 test/sqlite3.dll（与 local_backend_test 同口径）
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory tmp;

  setUp(() async {
    AiKeyVault.instance = InMemoryVault();
    tmp = await Directory.systemTemp.createTemp('hengya_chat_cfg_test_');
  });

  tearDown(() async {
    AiKeyVault.instance = null;
    await LocalBackend.instance.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> boot() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
  }

  test('GET /settings/ai 初始含 chat 节点且未配置', () async {
    await boot();
    final s = await LocalBackend.instance.get('/settings/ai');
    final chat = (s as Map)['chat'] as Map<String, dynamic>;
    expect(chat['baseUrl'], '');
    expect(chat['model'], '');
    expect(chat['keySet'], false);
    expect(chat['keyMasked'], '');
    expect(chat['encrypted'], true);
  });

  test('PUT 校验：http baseUrl 400 / 空 model 400 / 未知服务 404', () async {
    await boot();
    final be = LocalBackend.instance;
    await expectLater(
      be.put('/settings/ai/chat', {'baseUrl': 'http://x.com', 'model': 'm'}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
    await expectLater(
      be.put('/settings/ai/chat', {
        'baseUrl': 'https://x.com/v1',
        'model': '',
      }),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
    await expectLater(
      be.put('/settings/ai/nope', {
        'baseUrl': 'https://x.com/v1',
        'model': 'm',
      }),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
    );
  });

  test('PUT 存 key → keySet + keyMasked；key 不落 settings 表明文', () async {
    await boot();
    final be = LocalBackend.instance;
    final p1 = await be.put('/settings/ai/chat', {
      'baseUrl': 'https://47.100.82.115.nip.io:8443/v1',
      'model': 'v4.1flash',
      'apiKey': 'sk-chatkey-1234567890',
    });
    expect(p1['ok'], true);
    expect(p1['keySet'], true);
    expect(p1['keyMasked'], 'sk-****90');

    final db = await LocalBackend.instance.sharedDb;
    expect(db.settingGet('chat.baseUrl'), 'https://47.100.82.115.nip.io:8443/v1');
    expect(db.settingGet('chat.model'), 'v4.1flash');
    expect(db.settingGet('chat.apiKey'), ''); // 键位保留、值恒空串
  });

  test('PUT apiKey 空 = 保持原 key（keyMasked 回显不变）', () async {
    await boot();
    final be = LocalBackend.instance;
    await be.put('/settings/ai/chat', {
      'baseUrl': 'https://a.cn/v1',
      'model': 'm1',
      'apiKey': 'sk-abcdefgh12345678',
    });
    final p2 = await be.put('/settings/ai/chat', {
      'baseUrl': 'https://b.cn/v1',
      'model': 'm2',
      'apiKey': '',
    });
    expect(p2['keySet'], true);
    expect(p2['keyMasked'], 'sk-****78'); // key 未被清

    // GET 读回：新地址/模型生效 + key 掩码不变
    final s = await be.get('/settings/ai');
    final chat = (s as Map)['chat'] as Map<String, dynamic>;
    expect(chat['baseUrl'], 'https://b.cn/v1');
    expect(chat['model'], 'm2');
    expect(chat['keySet'], true);
    expect(chat['keyMasked'], 'sk-****78');
    expect(chat['encrypted'], true);
  });
}
