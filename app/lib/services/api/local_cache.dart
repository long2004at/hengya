// 本地缓存服务 —— 离线韧性（问1+5：断网/服务器故障时的只读数据回退）
//
// 职能：按端点键保存「最近一次成功响应 + 时间戳」（SharedPreferences JSON
// 字符串，体积克制：科目/统计/进度 ~1-11KB，复习队列与题库搜索各 ~20-50KB
// 上限，全部端点合计 <100KB）。
//
// 配合 api_client 的透明回退：
//   · 读端点请求成功   → 异步写缓存（fire-and-forget，不阻塞读路径）；
//   · 网络级失败（ApiException.statusCode==0）→ 命中缓存则透明回退，
//     并在旁路元信息里标记「来自缓存」（页面显示「离线数据 · 更新于 HH:mm」）；
//   · 无缓存 → 维持既有错误分支；HTTP 4xx/5xx 不回退（真实错误语义）。
//
// 安全红线（ADR-0001）：只存服务器响应正文的解码 JSON（只读 GET 端点数据），
// 不存任何请求头/token/Authorization——token 编译期注入，永不入缓存、不落盘。
//
// 持久层可注入（同 OfflineAnswerStore 模式）：生产 SharedPrefsCacheStore
// （main() 注入 SharedPreferences 实例），测试 InMemoryCacheStore（无插件
// 依赖）；未注入时 save/load 静默跳过——既有测试零感知、行为零变化。
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

/// 端点缓存键（单一事实源：api_client 写入/回退用，页面查旁路元信息用）。
/// 参数化端点把实参拼进键，防止不同参数的缓存互相污染。
abstract final class CacheKeys {
  /// GET /api/v1/subjects（fetchSubjects / fetchSubjectCatalog 共用同一份）
  static const String subjects = 'subjects';

  /// GET /api/v1/stats/streak
  static const String streak = 'stats-streak';

  /// GET /api/v1/stats/summary?days=
  static String summary(int days) => 'stats-summary-$days';

  /// GET /api/v1/stats/forecast?days=
  static String forecast(int days) => 'stats-forecast-$days';

  /// GET /api/v1/stats/heatmap?days=
  static String heatmap(int days) => 'stats-heatmap-$days';

  /// GET /api/v1/stats/retention
  static const String retention = 'stats-retention';

  /// GET /api/v1/cards/leech?threshold=
  static String leech(int threshold) => 'cards-leech-$threshold';

  /// GET /api/v1/cards/search（只存最近一次搜索结果，随新搜索覆盖）
  static const String bankSearch = 'bank-search';

  /// GET /api/v1/progress
  static const String progress = 'progress';

  /// GET /api/v1/cards/queue（复习队列持久化：按科目隔离，断网冷启动可继续背）
  static String queue(String subjectId, int limit) => 'queue-$subjectId-$limit';
}

/// 一条缓存记录：解码后的响应 JSON + 落盘时间。
/// [data] 是响应正文的解码结果（Map/List/标量）——不含任何请求头/token。
class CachedEntry {
  const CachedEntry({required this.data, required this.savedAt});

  final Object data;
  final DateTime savedAt;

  Map<String, dynamic> toRaw() => {
    'savedAt': savedAt.millisecondsSinceEpoch,
    'data': data,
  };

  static CachedEntry? fromRaw(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return null;
    }
    final ms = raw['savedAt'];
    if (ms is! int) return null;
    if (!raw.containsKey('data')) return null;
    return CachedEntry(
      data: raw['data'],
      savedAt: DateTime.fromMillisecondsSinceEpoch(ms),
    );
  }
}

/// 缓存持久层抽象：生产 [SharedPrefsCacheStore]，测试 [InMemoryCacheStore]。
abstract class LocalCacheStore {
  Future<void> write(String key, CachedEntry entry);
  Future<CachedEntry?> read(String key);
  Future<void> remove(String key);
  Future<void> clear();
}

/// 生产实现：SharedPreferences 单键 JSON 字符串（`hengya.cache.<key>`）。
/// 坏数据一律按「无缓存」静默处理（不让磁盘坏数据卡死页面）。
class SharedPrefsCacheStore implements LocalCacheStore {
  SharedPrefsCacheStore(this._prefs);

  final SharedPreferences _prefs;

  static const _prefix = 'hengya.cache.';

  static String prefKeyOf(String key) => '$_prefix$key';

  @override
  Future<void> write(String key, CachedEntry entry) =>
      _prefs.setString(prefKeyOf(key), jsonEncode(entry.toRaw()));

  @override
  Future<CachedEntry?> read(String key) async {
    final raw = _prefs.getString(prefKeyOf(key));
    if (raw == null || raw.isEmpty) return null;
    try {
      return CachedEntry.fromRaw(jsonDecode(raw));
    } catch (_) {
      return null; // 磁盘坏数据 → 当作无缓存
    }
  }

  @override
  Future<void> remove(String key) => _prefs.remove(prefKeyOf(key));

  @override
  Future<void> clear() async {
    for (final k in _prefs.getKeys().toList()) {
      if (k.startsWith(_prefix)) {
        await _prefs.remove(k);
      }
    }
  }
}

/// 测试实现：纯内存
class InMemoryCacheStore implements LocalCacheStore {
  final Map<String, CachedEntry> _entries = {};

  @override
  Future<void> write(String key, CachedEntry entry) async =>
      _entries[key] = entry;

  @override
  Future<CachedEntry?> read(String key) async => _entries[key];

  @override
  Future<void> remove(String key) async => _entries.remove(key);

  @override
  Future<void> clear() async => _entries.clear();
}

/// 缓存门面：单例，生产由 main() 注入持久层；未注入时全部静默跳过。
class LocalCache {
  LocalCache._();

  static final LocalCache instance = LocalCache._();

  LocalCacheStore? _store;

  bool get isAttached => _store != null;

  /// 生产接线：main() 在拿到 SharedPreferences 后注入
  void attach(LocalCacheStore store) => _store = store;

  /// 测试隔离：卸下持久层（save/load 变为无操作）
  @visibleForTesting
  void detach() => _store = null;

  /// 写：fire-and-forget（读路径不阻塞）；失败静默（缓存不可用不致命，
  /// 下次成功拉取会重写）。
  Future<void> save(String key, Object payload) async {
    final store = _store;
    if (store == null) return;
    try {
      await store.write(
        key,
        CachedEntry(data: payload, savedAt: DateTime.now()),
      );
    } catch (_) {
      // 落盘失败（磁盘满等）→ 忽略
    }
  }

  Future<CachedEntry?> load(String key) async {
    final store = _store;
    if (store == null) return null;
    try {
      return await store.read(key);
    } catch (_) {
      return null;
    }
  }

  /// 坏缓存自清（解析失败时由 api_client 调用，下次重新拉取覆盖）
  Future<void> remove(String key) async {
    final store = _store;
    if (store == null) return;
    try {
      await store.remove(key);
    } catch (_) {
      // 忽略
    }
  }

  Future<void> clear() async {
    final store = _store;
    if (store == null) return;
    try {
      await store.clear();
    } catch (_) {
      // 忽略
    }
  }
}
