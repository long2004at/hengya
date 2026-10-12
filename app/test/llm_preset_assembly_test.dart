// P3.2 拆卡侧 LLM 预设档案接线验证（pipeline_runner.resolveLlmCfg 对拍硬门）：
// resolveLlmCfg(db, req) 是拆卡主通道的**组装点**（worker 内消费；公开仅为
// 可单测）。覆盖：
//   1. llm.presetId 非空且档案存在 + key 随请求下发 → 读
//      preset.<id>.baseUrl/model/温度 + req.aiKeys['preset.<id>']
//   2. llm.presetId 空（默认）→ 读 llm.*（默认行为零变化——生卡流水线默认
//      档案不变）
//   3. 档案被删 → 引用清空 → 自动回退 llm.*
//   4. presetId 指向不存在档案 → 回退 llm.*
//   5. 档案存在但 key 未随请求下发 → 回退 llm.*（不拿空 key 硬跑）
//   6. 档案无温度键 → 用 LlmConfig 默认温度（kLlmTemperature）
// 外加 presets 路由端到端：路由写入的键位与组装点读取契约一致（键位即契约）。
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/local/ai_key_vault.dart';
import 'package:hengya/services/local/corpus/run_llm.dart'
    show kLlmTemperature;
import 'package:hengya/services/local/db.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/pipeline_runner.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => DynamicLibrary.open(dll));
  }

  late Directory tmp;

  setUp(() async {
    AiKeyVault.instance = InMemoryVault();
    tmp = await Directory.systemTemp.createTemp('hengya_llm_preset_test_');
  });

  tearDown(() async {
    AiKeyVault.instance = null;
    await LocalBackend.instance.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  PipelineCatchupRequest req(Map<String, String> keys) =>
      PipelineCatchupRequest(
        dataDir: tmp.path,
        prompts: const {},
        aiKeys: keys,
        promptNotes: const [],
      );

  // ---------------- resolveLlmCfg 组装点单测（真实临时库） ----------------

  group('resolveLlmCfg 组装点（presetId 切换生效 / 默认 llm.* 直读）', () {
    late Db db;

    setUp(() {
      db = Db.openSync('${tmp.path}${Platform.pathSeparator}hengya.db');
    });

    tearDown(() => db.close());

    test('llm.presetId 非空 + 档案存在 + key 在场 → 读档案字段', () {
      db.settingSet('llm.presetId', 'p1');
      db.settingSet('preset.p1.name', '官方通道');
      db.settingSet('preset.p1.baseUrl', 'https://api.deepseek.com/v1');
      db.settingSet('preset.p1.model', 'deepseek-chat');
      db.settingSet('preset.p1.temperature', '0.9');

      final cfg = resolveLlmCfg(db, req({'preset.p1': 'sk-preset-key'}));
      expect(cfg.baseUrl, 'https://api.deepseek.com/v1');
      expect(cfg.model, 'deepseek-chat');
      expect(cfg.apiKey, 'sk-preset-key');
      expect(cfg.temperature, 0.9);
    });

    test('llm.presetId 缺省（默认）→ 读 llm.* 直读（默认行为零变化）', () {
      db.settingSet('llm.baseUrl', 'https://official.example.com/v1');
      db.settingSet('llm.model', 'official-model');
      // 即便 preset 键误留也不读（presetId 为空）
      db.settingSet('preset.p1.name', 'x');
      db.settingSet('preset.p1.baseUrl', 'https://x.cn/v1');

      final cfg = resolveLlmCfg(db, req({'llm': 'sk-official'}));
      expect(cfg.baseUrl, 'https://official.example.com/v1');
      expect(cfg.model, 'official-model');
      expect(cfg.apiKey, 'sk-official');
      expect(cfg.temperature, kLlmTemperature, reason: '未指定温度 → 用默认');
    });

    test('presetId 指向不存在档案 → 回退 llm.*', () {
      db.settingSet('llm.presetId', 'ghost');
      db.settingSet('llm.baseUrl', 'https://official.example.com/v1');
      db.settingSet('llm.model', 'official-model');

      final cfg = resolveLlmCfg(db, req({'llm': 'sk-official'}));
      expect(cfg.baseUrl, 'https://official.example.com/v1');
      expect(cfg.model, 'official-model');
    });

    test('档案存在但 key 未随请求下发 → 回退 llm.*（不拿空 key 硬跑）', () {
      db.settingSet('llm.presetId', 'p1');
      db.settingSet('preset.p1.name', '官方通道');
      db.settingSet('preset.p1.baseUrl', 'https://api.deepseek.com/v1');
      db.settingSet('preset.p1.model', 'deepseek-chat');
      db.settingSet('llm.baseUrl', 'https://official.example.com/v1');
      db.settingSet('llm.model', 'official-model');

      final cfg = resolveLlmCfg(db, req({'llm': 'sk-official'}));
      expect(cfg.baseUrl, 'https://official.example.com/v1');
      expect(cfg.model, 'official-model');
    });

    test('档案无温度键 → 用 LlmConfig 默认温度', () {
      db.settingSet('llm.presetId', 'p1');
      db.settingSet('preset.p1.name', '无温度');
      db.settingSet('preset.p1.baseUrl', 'https://api.deepseek.com/v1');
      db.settingSet('preset.p1.model', 'deepseek-chat');

      final cfg = resolveLlmCfg(db, req({'preset.p1': 'sk-preset-key'}));
      expect(cfg.baseUrl, 'https://api.deepseek.com/v1');
      expect(cfg.temperature, kLlmTemperature);
    });
  });

  // ---------------- presets 路由端到端：键位即契约 ----------------

  test('presets 路由写入的键位与拆卡组装点读取契约一致（presetId 选定场景）',
      () async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    final be = LocalBackend.instance;
    await be.put('/settings/presets/p1', {
      'name': '官方通道',
      'baseUrl': 'https://api.deepseek.com/v1',
      'model': 'deepseek-chat',
      'temperature': 0.9,
      'apiKey': 'sk-preset-abc12345678',
    });
    await be.post('/settings/presets/p1/use?scope=llm', {});

    final db = await Db.open('${tmp.path}/hengya.db');
    addTearDown(db.close);

    // 组装点输入契约：presetId 在场、档案四键齐、key 随请求下发
    expect(db.settingGet('llm.presetId'), 'p1');
    expect(db.settingGet('preset.p1.baseUrl'), 'https://api.deepseek.com/v1');
    expect(db.settingGet('preset.p1.model'), 'deepseek-chat');
    expect(db.settingGet('preset.p1.temperature'), '0.9');

    // 真实组装点读路由写入的键位 → 生效
    final cfg = resolveLlmCfg(
      db,
      PipelineCatchupRequest(
        dataDir: tmp.path,
        prompts: const {},
        aiKeys: const {'preset.p1': 'sk-preset-abc12345678'},
        promptNotes: const [],
      ),
    );
    expect(cfg.baseUrl, 'https://api.deepseek.com/v1');
    expect(cfg.model, 'deepseek-chat');
    expect(cfg.apiKey, 'sk-preset-abc12345678');
    expect(cfg.temperature, 0.9);
  });

  test('llm.presetId 缺省（默认）→ 组装点回退 llm.* 直读键位（默认行为不变）',
      () async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    final db = await Db.open('${tmp.path}/hengya.db');
    addTearDown(db.close);
    db.settingSet('llm.baseUrl', 'https://official.example.com/v1');
    db.settingSet('llm.model', 'official-model');

    // 默认态：llm.presetId 不存在（组装点读 llm.*；preset 键即便误留也不读）
    expect(db.settingGet('llm.presetId'), isNull);
    expect(db.settingGet('llm.baseUrl'), 'https://official.example.com/v1');
    expect(db.settingGet('llm.model'), 'official-model');

    final cfg = resolveLlmCfg(db, req({'llm': 'sk-official'}));
    expect(cfg.baseUrl, 'https://official.example.com/v1');
    expect(cfg.model, 'official-model');
    expect(cfg.apiKey, 'sk-official');
  });

  test('档案被删除 → llm.presetId 引用被清空（组装点自动回退 llm.*）', () async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    final be = LocalBackend.instance;
    await be.put('/settings/presets/p1', {
      'name': 'x',
      'baseUrl': 'https://x.cn/v1',
      'model': 'm',
    });
    await be.post('/settings/presets/p1/use?scope=llm', {});
    await be.delete('/settings/presets/p1');
    final s = await be.get('/settings/presets');
    expect((s as Map)['llmPresetId'], '', reason: '引用清空 → 回退传统直读');
  });
}
