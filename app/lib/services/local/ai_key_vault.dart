// 恒牙（hengya）· AI 服务 API Key 安全存储（安全修复 C）
// ============================================================================
//
// 职责：llm / embedding / reranker 三套 AI 服务 key 从 hengya.db settings 表
// 明文存储迁入**系统安全存储**（flutter_secure_storage：Android Keystore /
// iOS-macOS Keychain / Windows Credential Manager / Linux libsecret）。
// key 绝不落 SQLite settings 表、绝不随导出件离开本机（data_manager 导出
// 剥离 *.apiKey 的兜底逻辑保留不动）。
//
// ── 同步缓存契约（避免 async 传染）──
// vault 读写是异步平台通道调用，而消费方（本地路由 / 流水线装配）多为同步
// 上下文 → [LocalBackend.initAiKeys] 启动时一次性把三把 key 读入内存缓存，
// 运行期经 [LocalBackend.aiKeyOf] 同步取用；写路径（settings/ai PUT）同步
// 更新缓存 + vault 异步落盘。本文件只做纯 vault 抽象，不持有缓存。
//
// ── 跨 isolate 纪律（isolate_runner.dart 文件头 ③）──
// Flutter 平台通道仅主 isolate 可用 → worker（拆卡流水线 / 建库）**绝不**
// 自读 vault；主 isolate 预读后随 PipelineCatchupRequest 下发（与提示词
// 模板同一模式）。
//
// ── 注入 seam（对齐 debugBackendMode / debugInjectHttpClient 风格）──
// [AiKeyVault.instance] 默认 [SecureStorageVault]（生产）；测试可整体替换
// 为 [InMemoryVault]（flutter_test 宿主无平台通道，真 vault 读会
// MissingPluginException），置回 null 恢复默认。
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'db.dart';

/// 三套 AI 服务名（settings 键前缀 / vault 存储位统一口径）。
const List<String> kAiKeyServices = ['llm', 'llm_backup', 'embedding', 'reranker'];

/// AI key 安全存储抽象。
abstract class AiKeyVault {
  const AiKeyVault();

  static AiKeyVault? _instance;

  /// 可替换实例（注入 seam）：缺省懒建 [SecureStorageVault]；测试可换
  /// [InMemoryVault]，置 null 恢复默认（懒建下一个真 vault）。
  static AiKeyVault get instance => _instance ??= const SecureStorageVault();

  static set instance(AiKeyVault? vault) => _instance = vault;

  /// 写 key（空串 = 清除该服务的 key）。
  Future<void> save(String svc, String key);

  /// 读 key（不存在返回 ''）。
  Future<String> read(String svc);

  /// 删 key。
  Future<void> delete(String svc);

  /// 一次性迁移（幂等）：扫描 settings 表三把 `<svc>.apiKey` 明文 key，
  /// 非空 → 存入本 vault → settings 表该键**写空串**（保留键位：兼容
  /// data_manager 导出剥离逻辑与旧版导入）。空键/缺键跳过——二次运行
  /// 零副作用，跑两次结果一致。
  ///
  /// 由 [LocalBackend.initAiKeys] 在启动时调用（main() 接线），防旧库
  /// 升级后 key 丢失。
  Future<void> migrateFromDb(Db db) async {
    for (final svc in kAiKeyServices) {
      final key = db.settingGet('$svc.apiKey') ?? '';
      if (key.isEmpty) continue;
      await save(svc, key);
      db.settingSet('$svc.apiKey', '');
    }
  }
}

/// flutter_secure_storage 实装（Android Keystore 加密；AndroidOptions 默认
/// 即可——Manifest allowBackup=false 已满足其要求）。
class SecureStorageVault extends AiKeyVault {
  const SecureStorageVault();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// vault 键名（`<svc>` ∈ llm|embedding|reranker）。
  static String storageKey(String svc) => 'hengya.ai.$svc.apiKey';

  @override
  Future<void> save(String svc, String key) => key.isEmpty
      ? _storage.delete(key: storageKey(svc))
      : _storage.write(key: storageKey(svc), value: key);

  @override
  Future<String> read(String svc) async =>
      await _storage.read(key: storageKey(svc)) ?? '';

  @override
  Future<void> delete(String svc) => _storage.delete(key: storageKey(svc));
}

/// 纯内存实装（测试用；flutter_test 宿主无平台通道，真 vault 会
/// MissingPluginException）。键名口径与 [SecureStorageVault] 一致。
class InMemoryVault extends AiKeyVault {
  final Map<String, String> _store = {};

  @override
  Future<void> save(String svc, String key) async {
    final k = SecureStorageVault.storageKey(svc);
    if (key.isEmpty) {
      _store.remove(k);
    } else {
      _store[k] = key;
    }
  }

  @override
  Future<String> read(String svc) async =>
      _store[SecureStorageVault.storageKey(svc)] ?? '';

  @override
  Future<void> delete(String svc) async =>
      _store.remove(SecureStorageVault.storageKey(svc));
}
