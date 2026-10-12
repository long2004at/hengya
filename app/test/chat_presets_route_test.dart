// P3.2 LLM 预设档案路由测试（LocalBackend /settings/presets/*）：
// 建/改（必填与 https 校验、温度 0-2、key 空保持原值）、列表掩码态与当前
// 选择、切换 use（scope 校验/404）、删除（404 + 连带清 key + 被引用清引用）。
// 与 chat_settings_route_test.dart 同姿势（InMemoryVault + 临时 SQLite +
// 直调路由）。
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
    tmp = await Directory.systemTemp.createTemp('hengya_presets_test_');
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

  test('PUT 建档案 + GET 列表：字段齐、key 只回掩码、temperature 可选', () async {
    await boot();
    final be = LocalBackend.instance;
    final p = await be.put('/settings/presets/abc123', {
      'name': '我的反代',
      'baseUrl': 'https://47.100.82.115.nip.io:8443/v1',
      'model': 'v4.1flash',
      'temperature': 0.5,
      'apiKey': 'sk-presetkey-1234567890',
    });
    expect(p['ok'], true);
    expect(p['keySet'], true);
    expect(p['keyMasked'], 'sk-****90');

    final s = await be.get('/settings/presets');
    final list = (s as Map)['presets'] as List;
    expect(list, hasLength(1));
    final preset = Map<String, dynamic>.from(list.first as Map);
    expect(preset['id'], 'abc123');
    expect(preset['name'], '我的反代');
    expect(preset['baseUrl'], 'https://47.100.82.115.nip.io:8443/v1');
    expect(preset['model'], 'v4.1flash');
    expect(preset['temperature'], '0.5');
    expect(preset['keySet'], true);
    expect(preset['keyMasked'], 'sk-****90');
    expect(preset['encrypted'], true);
    expect((s as Map)['chatPresetId'], '');
    expect(s['llmPresetId'], '');

    // key 不落 settings 表明文
    final db = await LocalBackend.instance.sharedDb;
    expect(db.settingGet('preset.abc123.name'), '我的反代');
    expect(db.settingKeysWithPrefix('preset.abc123.'), isNot(contains('preset.abc123.apiKey')));
  });

  test('PUT 校验：缺 name / http baseUrl / 缺 model / 温度越界 → 400', () async {
    await boot();
    final be = LocalBackend.instance;
    final base = {
      'name': 'n',
      'baseUrl': 'https://x.com/v1',
      'model': 'm',
    };
    await expectLater(
      be.put('/settings/presets/x1', {...base}..remove('name')),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
    await expectLater(
      be.put('/settings/presets/x1', {
        ...base,
        'baseUrl': 'http://x.com/v1',
      }),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
    await expectLater(
      be.put('/settings/presets/x1', {...base}..remove('model')),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
    await expectLater(
      be.put('/settings/presets/x1', {...base, 'temperature': 2.5}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
    await expectLater(
      be.put('/settings/presets/x1', {...base, 'temperature': -0.1}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
  });

  test('PUT 改档案：apiKey 空 = 保持原 key（掩码回显不变）', () async {
    await boot();
    final be = LocalBackend.instance;
    await be.put('/settings/presets/p1', {
      'name': 'a',
      'baseUrl': 'https://a.cn/v1',
      'model': 'm1',
      'apiKey': 'sk-abcdefgh12345678',
    });
    final p2 = await be.put('/settings/presets/p1', {
      'name': 'a2',
      'baseUrl': 'https://b.cn/v1',
      'model': 'm2',
      'apiKey': '',
    });
    expect(p2['keySet'], true);
    expect(p2['keyMasked'], 'sk-****78');
    final s = await be.get('/settings/presets');
    final preset = Map<String, dynamic>.from(
      ((s as Map)['presets'] as List).first as Map,
    );
    expect(preset['name'], 'a2');
    expect(preset['baseUrl'], 'https://b.cn/v1');
    expect(preset['keyMasked'], 'sk-****78');
  });

  test('POST use：写 chat.presetId / llm.presetId；scope 非法 400 / 档案不存在 404',
      () async {
    await boot();
    final be = LocalBackend.instance;
    await be.put('/settings/presets/p1', {
      'name': 'a',
      'baseUrl': 'https://a.cn/v1',
      'model': 'm1',
    });
    final c = await be.post('/settings/presets/p1/use?scope=chat', {});
    expect(c['ok'], true);
    expect(c['scope'], 'chat');
    final l = await be.post('/settings/presets/p1/use?scope=llm', {});
    expect(l['ok'], true);
    final s = await be.get('/settings/presets');
    expect((s as Map)['chatPresetId'], 'p1');
    expect(s['llmPresetId'], 'p1');

    await expectLater(
      be.post('/settings/presets/p1/use?scope=nope', {}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );
    await expectLater(
      be.post('/settings/presets/ghost/use?scope=chat', {}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
    );
  });

  test('DELETE：删档案 + 连带清 vault key；被引用档案删除 → 清引用', () async {
    await boot();
    final be = LocalBackend.instance;
    await be.put('/settings/presets/p1', {
      'name': 'a',
      'baseUrl': 'https://a.cn/v1',
      'model': 'm1',
      'apiKey': 'sk-abcdefgh12345678',
    });
    await be.post('/settings/presets/p1/use?scope=chat', {});
    await be.post('/settings/presets/p1/use?scope=llm', {});

    final d = await be.delete('/settings/presets/p1');
    expect(d['ok'], true);
    expect((d as Map)['clearedRefs'], containsAll(['chat', 'llm']));

    final s = await be.get('/settings/presets');
    expect(((s as Map)['presets'] as List), isEmpty);
    expect(s['chatPresetId'], '');
    expect(s['llmPresetId'], '');
    // key 缓存已清（aiKeyOf 空）
    expect(LocalBackend.instance.aiKeyOf('preset.p1'), '');

    await expectLater(
      be.delete('/settings/presets/p1'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
    );
  });

  test('DELETE 未被引用的档案 → 不动 chat/llm 选择', () async {
    await boot();
    final be = LocalBackend.instance;
    await be.put('/settings/presets/p1', {
      'name': 'a',
      'baseUrl': 'https://a.cn/v1',
      'model': 'm1',
    });
    await be.put('/settings/presets/p2', {
      'name': 'b',
      'baseUrl': 'https://b.cn/v1',
      'model': 'm2',
    });
    await be.post('/settings/presets/p1/use?scope=chat', {});
    await be.delete('/settings/presets/p2');
    final s = await be.get('/settings/presets');
    expect((s as Map)['chatPresetId'], 'p1');
    expect(((s)['presets'] as List), hasLength(1));
  });
}
