// AI key 安全存储（AiKeyVault）单测（安全修复 C）：
//  · InMemoryVault：save/read 往返、不存在返回 ''、delete 清除、save 空串=清除
//  · migrateFromDb：明文迁入 vault + settings 表键位保留值空串；幂等（跑两次一致）
//  · LocalBackend 集成：旧库明文 → initAiKeys 迁移预热 → aiKeyOf 同步取用；
//    PUT 写 vault+缓存+settings 空串；模拟重启（resetForTest → 再预热）key 不丢
//  · instance 注入 seam：可替换、置 null 恢复默认
//
// 宿主基建与 local_backend_test.dart 同姿势：Windows 测试宿主显式加载
// test/sqlite3.dll（package:sqlite3 官方 release 资产）。
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/services/local/ai_key_vault.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Windows 测试宿主：显式加载 test/sqlite3.dll（CWD = 包根 app/）
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory tmp;
  late InMemoryVault vault;

  setUp(() async {
    vault = InMemoryVault();
    AiKeyVault.instance = vault; // 注入 seam（生产默认 SecureStorageVault）
    tmp = await Directory.systemTemp.createTemp('hengya_vault_test_');
  });

  tearDown(() async {
    AiKeyVault.instance = null; // 恢复默认真 vault（跨文件零污染）
    await LocalBackend.instance.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> boot() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
  }

  test('InMemoryVault：save/read 往返；不存在返回空串；delete/save 空串=清除', () async {
    expect(await vault.read('llm'), '');
    await vault.save('llm', 'sk-abc');
    expect(await vault.read('llm'), 'sk-abc');
    // 三套服务位互不串扰
    await vault.save('embedding', 'sk-emb');
    await vault.save('reranker', 'sk-rr');
    expect(await vault.read('llm'), 'sk-abc');
    expect(await vault.read('embedding'), 'sk-emb');
    expect(await vault.read('reranker'), 'sk-rr');
    // delete / save 空串都视为清除；其余不受影响
    await vault.delete('embedding');
    expect(await vault.read('embedding'), '');
    await vault.save('reranker', '');
    expect(await vault.read('reranker'), '');
    expect(await vault.read('llm'), 'sk-abc');
  });

  test('migrateFromDb：明文迁入 vault + settings 键位保留值空串；幂等', () async {
    await boot();
    final db = await LocalBackend.instance.sharedDb;
    // 旧库形态：llm/embedding 明文，reranker 未配置
    db.settingSet('llm.apiKey', 'sk-legacy-llm');
    db.settingSet('embedding.apiKey', 'sk-legacy-emb');

    await AiKeyVault.instance.migrateFromDb(db);

    expect(await vault.read('llm'), 'sk-legacy-llm');
    expect(await vault.read('embedding'), 'sk-legacy-emb');
    expect(await vault.read('reranker'), '');
    // settings 表：键位保留、值空串（兼容 data_manager 导出剥离与旧版导入）
    expect(db.settingGet('llm.apiKey'), '');
    expect(db.settingGet('embedding.apiKey'), '');
    expect(db.settingGet('reranker.apiKey'), isNull); // 未配置不生键

    // 幂等：跑两次结果一致（第二次零副作用——vault 值不变、不报错）
    await AiKeyVault.instance.migrateFromDb(db);
    expect(await vault.read('llm'), 'sk-legacy-llm');
    expect(db.settingGet('llm.apiKey'), '');
  });

  test('LocalBackend 集成：旧库明文 → initAiKeys 迁移预热 → aiKeyOf 同步取用', () async {
    await boot();
    final be = LocalBackend.instance;
    final db = await be.sharedDb;
    db.settingSet('llm.apiKey', 'sk-legacy-llm');

    await be.initAiKeys();
    expect(be.aiKeyOf('llm'), 'sk-legacy-llm');
    expect(db.settingGet('llm.apiKey'), ''); // 明文已迁走
    expect(be.aiKeyOf('embedding'), ''); // 未配置

    // 幂等：重复调用结果一致（单飞 memo）
    await be.initAiKeys();
    expect(be.aiKeyOf('llm'), 'sk-legacy-llm');

    // 模拟「重启」：缓存清零后重预热——vault 持久（InMemory 同实例），
    // key 不丢；settings 表已无明文（迁移不再触发，键值不变）
    await be.resetForTest();
    be.init(tmp.path);
    await be.initAiKeys();
    expect(be.aiKeyOf('llm'), 'sk-legacy-llm');
  });

  test('LocalBackend 集成：PUT 写 vault+缓存+settings 空串；GET 掩码/encrypted 回显', () async {
    await boot();
    final be = LocalBackend.instance;

    final p = await be.put('/settings/ai/llm', {
      'baseUrl': 'https://api.example.com/v1',
      'model': 'gpt-4o-mini',
      'apiKey': 'sk-abcdefgh12345678',
    });
    expect(p['keySet'], true);

    // key 落 vault（PUT 异步落盘；InMemory 即时可见）
    expect(await vault.read('llm'), 'sk-abcdefgh12345678');
    // settings 表只留空键位（key 本体不在 hengya.db）
    final db = await be.sharedDb;
    expect(db.settingGet('llm.apiKey'), '');
    // 缓存同步可读（掩码视图/建库选路/test 兜底同源）
    expect(be.aiKeyOf('llm'), 'sk-abcdefgh12345678');

    final s = await be.get('/settings/ai');
    final llm = (s as Map)['llm'] as Map<String, dynamic>;
    expect(llm['keySet'], true);
    expect(llm['keyMasked'], 'sk-****78');
    expect(llm['encrypted'], true); // key 已在系统安全存储加密

    // 模拟「重启」：PUT 落盘的 key 从 vault 回读（迁移幂等——settings 已空）
    await be.resetForTest();
    be.init(tmp.path);
    await be.initAiKeys();
    expect(be.aiKeyOf('llm'), 'sk-abcdefgh12345678');
  });

  test('instance 注入 seam：可替换、置 null 恢复默认', () async {
    final injected = InMemoryVault();
    AiKeyVault.instance = injected;
    expect(identical(AiKeyVault.instance, injected), isTrue);
    AiKeyVault.instance = null;
    // 恢复默认：懒建 SecureStorageVault（仅类型断言，不触发平台调用）
    expect(AiKeyVault.instance, isA<SecureStorageVault>());
  });
}
