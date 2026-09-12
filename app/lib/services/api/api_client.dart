// API 客户端 —— App 与服务器的唯一通道
//
// 打开即自动同步（计划书 13.2）：
//   GET /meta/version → 有变化才拉 /subjects + /cards/pending + /review/queue
// 离线评分补传（13.6）：评分先进本地队列，联网后批量 POST /review/answer
//
// 离线缓存回退（问1+5 离线韧性）：只读 GET 端点经 [_withCache] 透明回退——
//   成功 → 异步写 [LocalCache]；网络级失败（statusCode==0）→ 有缓存则原样解析
//   返回并在旁路元信息标记「来自缓存」（页面显示「离线数据 · 更新于 HH:mm」）；
//   无缓存 → 维持既有错误分支；HTTP 4xx/5xx 不回退（真实错误语义）。
//   写操作（上传/关键词/学习记录/同步/新建科目）一律不缓存、明确失败。
//
// M3：切 https://<服务器IP>:8443（自签证书 pinning）+ Bearer token（ADR-0001）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;
import 'package:shared/hengya_shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'demo_backend.dart';
import '../local/local_backend.dart';
import 'local_cache.dart';

/// 后端模式（local-first，Phase 1）：
///   demo   演示模式（内存模拟数据，零服务器依赖——既有行为不变）
///   local  本地模式（真数据层 SQLite，一人一机一库；生产 hengya.db
///          直接拷贝迁移，服务器退役后独立使用）
///   remote  真实服务器（HTTPS + Bearer）
/// 编译期注入：--dart-define=BACKEND=local|demo|remote（开源定稿 2026-09-06：
/// 缺省 local——裸 build 即 local-first，开箱即用；remote 须显式指定）；
/// 兼容旧 DEMO=1（BACKEND 未设而 DEMO=1 → demo，既有演示构建不变）。
enum BackendMode { demo, local, remote }

/// 编译期模式（常量折叠进构建产物）
final BackendMode kBackendMode = () {
  const env = String.fromEnvironment('BACKEND', defaultValue: '');
  if (env == 'local') return BackendMode.local;
  if (env == 'demo') return BackendMode.demo;
  if (env == 'remote') return BackendMode.remote;
  if (env.isEmpty && const bool.fromEnvironment('DEMO')) {
    return BackendMode.demo;
  }
  return BackendMode.local; // 缺省 local（开源口径：一人一机一库零配置）
}();

/// 测试运行时覆盖（生产代码勿碰）：非 null 时优先于 [kBackendMode]——
/// flutter test 无法改变 String.fromEnvironment，LocalBackend/demo 路由
/// 测试由此切换（测试间须置回 null）。
@visibleForTesting
BackendMode? debugBackendMode;

/// 当前生效模式（分流点统一入口）
BackendMode get currentBackendMode => debugBackendMode ?? kBackendMode;

class ApiException implements Exception {
  ApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'ApiException($statusCode): $message';
}

class SubjectWithDue {
  const SubjectWithDue({required this.subject, required this.dueCount});

  final Subject subject;
  final int dueCount;
}

class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  /// 服务地址：编译期注入（remote 模式示例：--dart-define=API_BASE=https://<服务器地址>:8443；
  /// 地址/端口属部署私有信息，开源库不内置任何真实生产地址）
  /// 未注入时默认模拟器本机 dev 服务器；演示模式（DEMO=1）下不发起任何网络请求
  String baseUrl = const String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://10.0.2.2:8080',
  );

  /// 256-bit token：编译期注入（--dart-define=API_TOKEN=...），不进代码库
  String? token = const String.fromEnvironment('API_TOKEN').isEmpty
      ? null
      : const String.fromEnvironment('API_TOKEN');

  /// 离线评分队列持久层（审计 P0 整改：App 被杀不丢分）
  /// 生产由 main() 注入 SharedPreferences 实现；测试可注入内存假实现
  OfflineAnswerStore? offlineStore;

  /// 队列变化回调（UI 显示"待补传 N 条"）
  void Function(int count)? onQueueChanged;

  /// 科目名称内存缓存（M5 动态科目）：id → 展示名。
  /// 任何一次成功的 /subjects 拉取都会刷新；展示层经 [subjectNameOf]
  /// 取库内科目名（服务端/本地模式同源），未拉到时原样显示 id。
  final Map<String, String> subjectNames = {};

  /// 科目目录缓存（fetchSubjectCatalog 用；refresh=true 强制重拉）
  List<SubjectInfo>? _subjectCatalogCache;

  HttpClient? _http;
  SecurityContext? _pinnedContext;

  /// 测试注入：替换底层 HttpClient（仅测试用；生产勿碰）。
  /// TestWidgetsFlutterBinding 会把 HttpClient mock 成恒 400——组件测试需要
  /// 真实契约语义（404 降级/请求形状）时由此注入假 client。传 null 恢复默认链路。
  @visibleForTesting
  void debugInjectHttpClient(HttpClient? client) {
    _http = client;
  }

  /// M3-5 pinning：main() 启动时经 rootBundle 读 assets/certs/ca.pem 后注入。
  /// 只信自签 CA 链——系统信任库任何 CA（含被劫持的）均无效。
  void pinCaCertificate(List<int> caPem) {
    _pinnedContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificatesBytes(caPem);
    _http = null; // 下次 _client 取用时带新 context 重建
  }

  HttpClient get _client => _http ??=
      (_pinnedContext != null
            ? HttpClient(context: _pinnedContext)
            : HttpClient())
        ..connectionTimeout = const Duration(seconds: 8);

  Map<String, String> get _headers => {
    // 显式声明 charset=utf-8：dart:io 在无 charset 时按 latin1 写 body，
    // 中文（关键词/课程名/卡文）会抛 "Contains invalid characters"（测试实测）
    'Content-Type': 'application/json; charset=utf-8',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  /// remote 模式 HTTPS 门禁（批1 D 加固）：remote 下 [baseUrl] 不以
  /// https:// 开头即抛 [ApiException]——Bearer token 与复习数据绝不走
  /// 明文 HTTP。四个网络路径（_getRaw / _postJson / _putJson /
  /// uploadCourseware 的 remote 分支）统一在进入 try 前调用。
  /// kDebugMode 豁免：保留模拟器 http://10.0.2.2 开发路径
  /// （flutter test 亦运行于 debug → 既有 remote+http 测试不受影响）。
  void _assertRemoteHttps() {
    if (kDebugMode) return; // 开发/测试豁免
    if (currentBackendMode != BackendMode.remote) return;
    if (!baseUrl.startsWith('https://')) {
      throw ApiException(0, 'API_BASE 必须以 https:// 开头（remote 模式禁明文 HTTP）');
    }
  }

  // ---------------- 基础 ----------------

  Future<String> _getRaw(String path) async {
    // 本地分流（M3 演示 / Phase 1 本地 SQLite）：零网络依赖
    switch (currentBackendMode) {
      case BackendMode.demo:
        final data = await DemoBackend.instance.get(path);
        return jsonEncode(data['list'] ?? data);
      case BackendMode.local:
        final data = await LocalBackend.instance.get(path);
        return jsonEncode(data['list'] ?? data);
      case BackendMode.remote:
        break;
    }
    _assertRemoteHttps(); // remote 门禁：禁明文 HTTP
    try {
      final req = await _client.getUrl(Uri.parse('$baseUrl$path'));
      _headers.forEach(req.headers.set);
      final res = await req.close().timeout(const Duration(seconds: 12));
      final body = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) throw ApiException(res.statusCode, body);
      return body;
    } on SocketException catch (e) {
      throw ApiException(0, '网络不可达: $e');
    } on HttpException catch (e) {
      // 服务器故障（连接中途断开等传输层错误）→ 与断网同语义：可走缓存回退
      throw ApiException(0, '连接异常: $e');
    } on TimeoutException {
      throw ApiException(0, '请求超时');
    }
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final body = await _getRaw(path);
    final decoded = jsonDecode(body);
    if (decoded is Map<String, dynamic>) return decoded;
    if (decoded is List) return {'list': decoded};
    throw ApiException(0, '意外响应格式');
  }

  Future<Map<String, dynamic>> _postJson(String path, Object? body) async {
    // 本地分流
    switch (currentBackendMode) {
      case BackendMode.demo:
        return DemoBackend.instance.post(path, body);
      case BackendMode.local:
        return LocalBackend.instance.post(path, body);
      case BackendMode.remote:
        break;
    }
    _assertRemoteHttps(); // remote 门禁：禁明文 HTTP
    try {
      final req = await _client.postUrl(Uri.parse('$baseUrl$path'));
      _headers.forEach(req.headers.set);
      // P0 整改：显式 utf8 编码写入 body（req.write(String) 走 latin1，中文会抛）
      req.add(utf8.encode(body == null ? '' : jsonEncode(body)));
      final res = await req.close().timeout(const Duration(seconds: 12));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) throw ApiException(res.statusCode, text);
      return Map<String, dynamic>.from(jsonDecode(text) as Map);
    } on SocketException catch (e) {
      throw ApiException(0, '网络不可达: $e');
    } on HttpException catch (e) {
      throw ApiException(0, '连接异常: $e');
    } on TimeoutException {
      throw ApiException(0, '请求超时');
    }
  }

  /// PUT 与 `_postJson` 同构（M5：AI 服务配置更新，契约 `PUT /api/v1/settings/ai/<service>`）
  Future<Map<String, dynamic>> _putJson(String path, Object? body) async {
    // 本地分流（put 与 post 分开路由，语义对齐真实服务端）
    switch (currentBackendMode) {
      case BackendMode.demo:
        return DemoBackend.instance.put(path, body);
      case BackendMode.local:
        return LocalBackend.instance.put(path, body);
      case BackendMode.remote:
        break;
    }
    _assertRemoteHttps(); // remote 门禁：禁明文 HTTP
    try {
      final req = await _client.openUrl('PUT', Uri.parse('$baseUrl$path'));
      _headers.forEach(req.headers.set);
      // 同 _postJson：显式 utf8 编码（req.write(String) 对中文会抛 latin1 编码错误）
      req.add(utf8.encode(body == null ? '' : jsonEncode(body)));
      final res = await req.close().timeout(const Duration(seconds: 12));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) throw ApiException(res.statusCode, text);
      return Map<String, dynamic>.from(jsonDecode(text) as Map);
    } on SocketException catch (e) {
      throw ApiException(0, '网络不可达: $e');
    } on HttpException catch (e) {
      throw ApiException(0, '连接异常: $e');
    } on TimeoutException {
      throw ApiException(0, '请求超时');
    }
  }

  // ---------------- 离线缓存回退（问1+5） ----------------

  /// 旁路元信息：cacheKey → 最近一次「缓存回退命中」的时间。
  /// 页面在 await 读取方法返回后立即查询（[cacheServedAt] /
  /// [latestCacheHitAmong]），null/缺席 = 数据来自服务器（新鲜）。
  /// 写操作不缓存，也不在此留痕；Flutter 单线程模型下「await 返回 → 查询」
  /// 之间无插入窗口，并发 Future.wait 各端点键互不相交，无串扰。
  final Map<String, DateTime> _cacheServedAt = {};

  /// 单端点旁路查询：null = 新鲜（或该端点未缓存）
  DateTime? cacheServedAt(String cacheKey) => _cacheServedAt[cacheKey];

  /// 多端点取最近一次缓存命中（Future.wait 并发读后查整体离线态）
  DateTime? latestCacheHitAmong(Iterable<String> cacheKeys) {
    DateTime? latest;
    for (final k in cacheKeys) {
      final at = _cacheServedAt[k];
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return latest;
  }

  /// 读端点统一缓存回退：
  ///   成功 → 异步写缓存（fire-and-forget）→ 返回新鲜数据；
  ///   网络级失败（ApiException.statusCode==0）→ 命中缓存则用同一 parse
  ///     透明回退（记旁路元信息），未命中则原样抛错（维持既有错误分支）；
  ///   HTTP 4xx/5xx → 不回退（真实错误语义：404 降级、400 校验错等）。
  /// [markProvenance]=false 供写流程的辅助拉取（科目目录）使用：可回退缓存
  /// 但不记旁路元信息，避免与页面主体读取互相干扰。
  /// 缓存数据解析失败（磁盘坏数据）→ 自清该键并按「无缓存」处理。
  /// 演示模式不写缓存（避免演示数据进真实磁盘）；演示后端恒应答，回退不触发。
  Future<T> _withCache<T>(
    String cacheKey,
    Future<Object> Function() getJson,
    T Function(Object json) parse, {
    bool markProvenance = true,
  }) async {
    if (markProvenance) _cacheServedAt.remove(cacheKey);
    try {
      final json = await getJson();
      if (currentBackendMode == BackendMode.remote) {
        // 仅远程模式写缓存（demo/local 后端恒应答，缓存无意义还占磁盘）
        unawaited(LocalCache.instance.save(cacheKey, json));
      }
      return parse(json);
    } on ApiException catch (e) {
      if (e.statusCode != 0) rethrow; // 4xx/5xx：真实错误，不回退
      final entry = await LocalCache.instance.load(cacheKey);
      if (entry == null) rethrow; // 无缓存 → 维持既有错误分支（保栈迹）
      try {
        final data = parse(entry.data);
        if (markProvenance) _cacheServedAt[cacheKey] = entry.savedAt;
        return data;
      } catch (_) {
        await LocalCache.instance.remove(cacheKey); // 坏缓存自清，下次重写
        throw e;
      }
    }
  }

  // ---------------- 同步面 ----------------

  /// 健康检查（设置页「服务器连接」）：GET /health，无 /api/v1 前缀、豁免 token
  /// 本地分流恒应答；remote 异常抛 ApiException(0, ...) 由调用方捕获
  Future<Map<String, dynamic>> fetchHealth() async {
    switch (currentBackendMode) {
      case BackendMode.demo:
        return const {'status': 'ok', 'data_version': 'demo'};
      case BackendMode.local:
        return LocalBackend.instance.get('/health');
      case BackendMode.remote:
        break;
    }
    final body = await _getRaw('/health');
    return Map<String, dynamic>.from(jsonDecode(body) as Map);
  }

  /// 服务器数据版本（App 增量同步判断依据）
  Future<String> fetchDataVersion() async {
    final json = await _getJson('/api/v1/meta/version');
    return json['data_version'] as String? ?? '0';
  }

  /// 科目 + 各科到期数（首页角标）；离线时回退最近一次成功响应（[CacheKeys.subjects]）
  Future<List<SubjectWithDue>> fetchSubjects() => _withCache(
    CacheKeys.subjects,
    () => _getJson('/api/v1/subjects'),
    _parseSubjectsWithDue,
  );

  List<SubjectWithDue> _parseSubjectsWithDue(Object json) {
    final list = (json as Map<String, dynamic>)['subjects'] as List<dynamic>;
    final items = list.map((e) {
      final m = Map<String, dynamic>.from(e as Map);
      return SubjectWithDue(
        subject: Subject.fromJson(m),
        dueCount: m['dueCount'] as int? ?? 0,
      );
    }).toList();
    // M5 动态科目：同步刷新展示名缓存（库内科目名优先于裸 id）——
    // 解析函数新鲜/缓存两路共用，离线回退时名称缓存同样生效
    for (final s in items) {
      subjectNames[s.subject.id] = s.subject.name;
    }
    return items;
  }

  /// 待审核池（#15 分页，2026-09-13）：local 模式带 limit/offset 并返回
  /// total（「加载更多」判定）；demo/remote 服务端无分页参数——退化为一次
  /// 全量，total = 列表长度（行为与旧版一致）。
  Future<(List<FlashCard>, int)> fetchPendingCards({
    int limit = 100,
    int offset = 0,
  }) async {
    switch (currentBackendMode) {
      case BackendMode.local:
        final data = await LocalBackend.instance
            .get('/api/v1/cards/pending?limit=$limit&offset=$offset');
        final rawList = data['list'] as List<dynamic>? ?? const [];
        final cards = [
          for (final e in rawList)
            FlashCard.fromJson(Map<String, dynamic>.from(e as Map)),
        ];
        final total = (data['total'] as num?)?.toInt() ?? cards.length;
        return (cards, total);
      case BackendMode.demo:
      case BackendMode.remote:
        final body = await _getRaw('/api/v1/cards/pending');
        final list = jsonDecode(body) as List<dynamic>;
        final cards = list
            .map((e) => FlashCard.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
        return (cards, cards.length);
    }
  }

  /// 复习队列（科目隔离，一次拉一批：地铁弱网也能背完，13.6）。
  /// 队列持久化（问1+5）：拉取成功即落 [CacheKeys.queue]，断网冷启动时
  /// 透明回退同一批卡——离线也能继续背（评分仍走既有离线评分队列补传）。
  Future<List<FlashCard>> fetchQueue(String subjectId, {int limit = 50}) =>
      _withCache(
        CacheKeys.queue(subjectId, limit),
        () => _getJson('/api/v1/cards/queue?subject=$subjectId&limit=$limit'),
        (json) => [
          for (final e in (json as Map)['cards'] as List<dynamic>)
            FlashCard.fromJson(Map<String, dynamic>.from(e as Map)),
        ],
      );

  // ---------------- 审核面 ----------------

  Future<void> approveCard(String id) =>
      _postJson('/api/v1/cards/$id/approve', null);

  // ---------------- 统计面（M3；读端点带离线缓存回退） ----------------

  /// 未来 N 天到期预测（柱状图）；离线时回退最近一次成功响应
  Future<List<DueForecastDay>> fetchForecast({int days = 7}) => _withCache(
    CacheKeys.forecast(days),
    () async => jsonDecode(await _getRaw('/api/v1/stats/forecast?days=$days')),
    (json) => [
      for (final e in json as List<dynamic>)
        DueForecastDay.fromJson(Map<String, dynamic>.from(e as Map)),
    ],
  );

  /// 连续打卡天数；离线时回退最近一次成功响应
  Future<int> fetchStreak() => _withCache(
    CacheKeys.streak,
    () => _getJson('/api/v1/stats/streak'),
    (json) => (json as Map)['streak'] as int? ?? 0,
  );

  /// 热力图：近 N 天每日复习量（默认 12 周）；离线时回退最近一次成功响应
  Future<Map<String, int>> fetchHeatmap({int days = 84}) => _withCache(
    CacheKeys.heatmap(days),
    () => _getJson('/api/v1/stats/heatmap?days=$days'),
    (json) {
      final list = (json as Map)['byDay'] as List<dynamic>? ?? [];
      return {
        for (final e in list) (e as Map)['day'] as String: e['reviews'] as int,
      };
    },
  );

  /// 保留率：近1天/近7天/近30天三档窗口（统计页「保留率」模块）；
  /// 离线时回退最近一次成功响应
  Future<RetentionStats> fetchRetention() => _withCache(
    CacheKeys.retention,
    () => _getJson('/api/v1/stats/retention'),
    (json) => RetentionStats.fromJson(json as Map<String, dynamic>),
  );

  /// 近 7 日聚合（again 率 / 总量 / 积压）；离线时回退最近一次成功响应
  Future<StatsSummary> fetchSummary({int days = 7}) => _withCache(
    CacheKeys.summary(days),
    () => _getJson('/api/v1/stats/summary?days=$days'),
    (json) => StatsSummary.fromJson(json as Map<String, dynamic>),
  );

  /// 弱卡榜（lapse ≥ threshold 的 active 卡）；离线时回退最近一次成功响应
  Future<List<FlashCard>> fetchLeechCards({int threshold = 4}) => _withCache(
    CacheKeys.leech(threshold),
    () => _getJson('/api/v1/cards/leech?threshold=$threshold'),
    (json) => [
      for (final e in (json as Map)['cards'] as List<dynamic>)
        FlashCard.fromJson(Map<String, dynamic>.from(e as Map)),
    ],
  );

  /// 关键词入箱（上课随手记重点；source 区分来源：'app'=App 关键词（默认）、
  /// 'study-log'=三字段表单的章节学习记录（流水线据此走罗盘推进而非拆卡）、
  /// 'chat'=过渡期对话转存）
  Future<void> addKeyword({
    required String subjectId,
    required String keyword,
    String note = '',
    String source = 'app',
  }) {
    return _postJson('/api/v1/inbox/keywords', {
      'subjectId': subjectId,
      'keyword': keyword,
      'note': note,
      'source': source,
    });
  }

  Future<void> rejectCard(String id, {String reason = '', String note = ''}) =>
      _postJson('/api/v1/cards/$id/reject', {
        if (reason.isNotEmpty) 'reason': reason,
        if (note.isNotEmpty) 'note': note,
      });

  Future<void> editPendingCard(
    String id, {
    String? front,
    String? back,
    String? anchor,
  }) {
    return _postJson('/api/v1/cards/$id/edit', {
      'front': front,
      'back': back,
      'anchor': anchor,
    });
  }

  // ---------------- 题库面（M4：02 列表 + 02b 详情） ----------------

  /// 题库检索（全部非 pending 卡）：科目过滤 + 全文匹配 + 分页。
  /// 离线时回退「最近一次搜索结果」（[CacheKeys.bankSearch]，随新搜索覆盖）。
  Future<BankSearchResult> searchBankCards({
    String? subject,
    String? q,
    int offset = 0,
    int limit = 50,
  }) {
    final params = <String>[
      if (subject != null && subject.isNotEmpty) 'subject=$subject',
      if (q != null && q.isNotEmpty) 'q=${Uri.encodeQueryComponent(q)}',
      'offset=$offset',
      'limit=$limit',
    ];
    return _withCache(
      CacheKeys.bankSearch,
      () => _getJson('/api/v1/cards/search?${params.join('&')}'),
      (json) {
        final map = json as Map<String, dynamic>;
        final list = map['cards'] as List<dynamic>;
        return BankSearchResult(
          total: map['total'] as int? ?? 0,
          cards: list
              .map(
                (e) => BankCard.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList(),
        );
      },
    );
  }

  /// 单卡详情（M4.1：题库详情页直取，替代「search 拿卡 id 当全文关键词」的旧方案——
  /// 卡 id 从不出现在正文里，LIKE %id% 必然 0 命中）。
  /// `GET /api/v1/cards/<id>` → 200 裸 JSON 对象（与 search 条目同构，BankCard.fromJson 直接解析）；
  /// 404 → 服务端 {"ok":false,"error":"卡 xxx 不存在"} → _getRaw 抛 ApiException(404, body)；
  /// 演示模式 404 由 DemoBackend 抛 ApiException(404, '卡不存在')。
  Future<BankCard> fetchCardById(String id) async {
    final body = await _getRaw('/api/v1/cards/$id');
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      throw ApiException(0, '意外响应格式');
    }
    return BankCard.fromJson(decoded);
  }

  /// 单卡备注（我的备注；AI 留言入口已移除，服务端 aiNote 字段不再读取）
  Future<CardNotes> fetchCardNotes(String cardId) async {
    final json = await _getJson('/api/v1/cards/$cardId/notes');
    return CardNotes.fromJson(json);
  }

  /// 更新备注（userNote 给自己看；AI 留言已下线，不再写 aiNote）
  Future<void> updateCardNotes(String cardId, {String? userNote}) {
    return _postJson('/api/v1/cards/$cardId/notes', {'userNote': ?userNote});
  }

  // ---------------- 评分面 ----------------

  /// 评分（在线直传；网络不可达自动入离线队列，13.6）
  Future<bool> submitAnswer(ReviewLog log) async {
    final item = log.toJson();
    try {
      final res = await _postJson('/api/v1/review/answer', item);
      return res['ok'] == true;
    } on ApiException catch (e) {
      if (e.statusCode == 0 || e.statusCode >= 500) {
        await _enqueueAnswer({...item, 'offlineQueued': true}); // 持久化入队
        return true; // 已入队，视为"本地成功"
      }
      rethrow; // 4xx：真错误（卡不存在/非 active），不上队列
    }
  }

  Future<void> _enqueueAnswer(Map<String, dynamic> item) async {
    await offlineStore?.append(item);
    onQueueChanged?.call(pendingAnswerCount);
  }

  /// 当前待补传条数（持久层恢复后即为磁盘上的真实条数）
  int get pendingAnswerCount => offlineStore?.count ?? 0;

  /// 启动时恢复：把磁盘上的队列读回内存态（异步，不阻塞 UI）
  Future<void> restorePendingAnswers() async {
    final n = await offlineStore?.restore() ?? 0;
    if (n > 0) onQueueChanged?.call(n);
  }

  /// 联网后批量补传离线评分（启动/恢复联网时调）
  Future<int> flushPendingAnswers() async {
    final store = offlineStore;
    if (store == null || store.isEmpty) return 0;
    final batch = List<Map<String, dynamic>>.from(store.drainPreview());
    try {
      final res = await _postJson('/api/v1/review/answer', batch);
      if (res['ok'] == true) {
        final applied = res['applied'] as int? ?? 0;
        // 批量受理即清空（skipped 项属真错误，不重试）
        await store.clear();
        onQueueChanged?.call(0);
        return applied;
      }
      return 0;
    } on ApiException {
      return 0; // 仍离线，下轮再传
    }
  }

  // ---------------- 回炉面 ----------------

  /// 回炉重造（选原因 + 自由输入）。
  /// 响应体 `duplicate: true` = 幂等重复提交（该卡已在回炉队列/重造中，
  /// 未再入队、未报错）——调用方据此提示「已在队列」而非「已送进」（#10②：
  /// 重复回炉不再以 400 报错把内部 id 泄给用户）。
  Future<Map<String, dynamic>> reworkCard(
    String cardId, {
    required String reason,
    String note = '',
  }) {
    return _postJson('/api/v1/cards/rework', {
      'cardId': cardId,
      'reason': reason,
      'note': note,
    });
  }

  /// 移除废卡（#15：物理删除，仅已拒绝 rejected 的卡）。
  /// `POST /api/v1/cards/delete` {"cardId":…} → {ok:true, cardId}；
  /// 非 rejected → 400；不存在/已删 → 404「卡片不存在或已被移除」
  /// （重复删除同 id 幂等报 404，文案不带内部 id）。
  /// remote（server cards.dart 未实现本路由）为遗留——App 默认 local 不受影响。
  Future<Map<String, dynamic>> removeCard(String cardId) {
    return _postJson('/api/v1/cards/delete', {'cardId': cardId});
  }

  // ---------------- 流水线（server 0.4.1+） ----------------

  /// 触发服务器拆卡/回炉流水线尽快运行（设置页「强制开始拆卡 / 改卡」入口）。
  /// `POST /api/v1/pipeline/trigger` → `{ok, triggered, note}`：
  /// triggered=true 首次排队成功（约 1 分钟内开跑）；false = 已有任务排队中
  /// （note 为后端说明）。旧服务器（0.4.0-）404 → ApiException，由调用方提示
  /// 「需服务器 0.4.1+」。演示模式走 DemoBackend stub，无真实流水线。
  Future<PipelineTriggerResult> triggerPipeline() async {
    final json = await _postJson('/api/v1/pipeline/trigger', null);
    return PipelineTriggerResult.fromJson(json);
  }

  /// 手动真题周扫（local 0.1.13+：`POST /api/v1/pipeline/weekly`）——
  /// weekly-only 单轮后台执行；自动周扫路径零影响。remote 模式下旧服务器
  /// 无此路由 → 404（调用方提示仅本地模式支持）。
  Future<PipelineTriggerResult> triggerWeeklyScan() async {
    final json = await _postJson('/api/v1/pipeline/weekly', null);
    return PipelineTriggerResult.fromJson(json);
  }

  /// 自动周扫计时状态（local 0.1.13+：`GET /api/v1/pipeline/weekly`）。
  /// [lastRunAt] 为 null = 从未自动扫过（或已被清除）→ due=true。
  Future<WeeklyScanStatus> weeklyScanStatus() async {
    return WeeklyScanStatus.fromJson(
      await _getJson('/api/v1/pipeline/weekly'),
    );
  }

  /// 自动周扫节流时间戳自由调整（local 0.1.13+：`PUT /api/v1/pipeline/weekly`）。
  /// [lastRunAt] 传 null/空 = 清除（下次拆卡收尾立即到期）；传 ISO 时间 =
  /// 任意前调/后调。手动周扫不写此键（两路节奏独立）。
  Future<WeeklyScanStatus> setWeeklyScanSchedule(String? lastRunAt) async {
    return WeeklyScanStatus.fromJson(
      await _putJson('/api/v1/pipeline/weekly', {'lastRunAt': lastRunAt}),
    );
  }

  // ---------------- 动态科目（M5：服务端科目目录 + 新建） ----------------

  /// 科目目录（含 dueCount）：内存缓存，[refresh]=true 强制重拉。
  /// 契约（server 0.3.0+）：`GET /api/v1/subjects`
  /// → {"subjects":[{"id":"…","name":"…","isExamSubject":…,"dueCount":…}]}。
  /// 拉取失败回退最近一次成功缓存（断网时上传/收件箱的科目选择仍可用真实
  /// 目录）；无缓存才抛 ApiException——由调用方展示空态+重试。
  /// 写流程辅助拉取：可回退但不记旁路元信息（markProvenance: false）。
  Future<List<SubjectInfo>> fetchSubjectCatalog({bool refresh = false}) async {
    if (!refresh && _subjectCatalogCache != null) return _subjectCatalogCache!;
    return _withCache(
      CacheKeys.subjects,
      () => _getJson('/api/v1/subjects'),
      _parseSubjectCatalog,
      markProvenance: false,
    );
  }

  List<SubjectInfo> _parseSubjectCatalog(Object json) {
    final list = (json as Map)['subjects'] as List<dynamic>? ?? [];
    final infos = [
      for (final e in list)
        SubjectInfo.fromJson(Map<String, dynamic>.from(e as Map)),
    ];
    _subjectCatalogCache = infos;
    subjectNames
      ..clear()
      ..addAll({for (final s in infos) s.id: s.name});
    return infos;
  }

  /// 新建科目：`POST /api/v1/subjects` body {"name":…,"id":…}（id 可选留空
  /// 服务端自动生成）→ {"ok":true,"id":"perio","name":"牙周病学"}。
  /// 成功后目录缓存失效——下次 fetchSubjectCatalog 能立即看到新科目。
  Future<SubjectInfo> createSubject({required String name, String? id}) async {
    final json = await _postJson('/api/v1/subjects', {
      'name': name,
      if (id != null && id.trim().isNotEmpty) 'id': id.trim(),
    });
    if (json['ok'] != true) throw ApiException(0, '新建科目失败');
    final created = SubjectInfo.fromJson(json);
    _subjectCatalogCache = null; // 失效重拉（新科目立即可选）
    subjectNames[created.id] = created.name;
    return created;
  }

  /// 科目展示名（展示层统一入口）：库内科目名缓存 → 原样 id。
  /// 无内置科目兜底（0.3.1 开源去内置）——未拉到目录时如实显示裸 id。
  String subjectNameOf(String id) => subjectNames[id] ?? id;

  /// 科目全名（学习进度页等全名场景）：与 [subjectNameOf] 同一条链——
  /// 库内科目名缓存 → 原样 id（13 科罗盘全名映射已随内置科目一并移除）。
  String subjectFullNameOf(String id) => subjectNames[id] ?? id;

  /// 导入/恢复数据后清空科目目录、名称及缓存来源标记；测试亦用于隔离。
  void resetSubjectCaches() {
    _subjectCatalogCache = null;
    subjectNames.clear();
    _cacheServedAt.clear();
  }

  // ---------------- 知识库（M5：语料状态 + 课件上传） ----------------

  /// 语料库状态：`GET /api/v1/corpus/status`
  /// → {totalChunks, subjects:{短码:块数}, lastBuild, pendingFiles,
  ///    reworkPending(⑦), storageMB}。
  /// 旧服务器（0.2.0）→ 404，由调用方降级提示「需服务器 0.3.0+」。
  Future<CorpusStatus> fetchCorpusStatus() async {
    final json = await _getJson('/api/v1/corpus/status');
    return CorpusStatus.fromJson(json);
  }

  /// 上传课件：`POST /api/v1/corpus/upload?subject={短码}&filename={URL编码}`，
  /// body=原始字节流（application/octet-stream）→ {ok, received, pending}。
  /// 不定态进度（服务端收完才回包）——上传中请保持 App 前台。
  ///
  /// 语料类型标注：[source] 可选——'textbook' 时 query 追加
  /// `&source=textbook`，local 落盘教材树 `incoming/<短码>-textbook/`
  /// （首层目录 → splitSubjectSource 判 textbook → 建库写 toc sidecar →
  /// #16 罗盘随建库自动生成）；'exam'（节点③真题专题上传）时追加
  /// `&source=exam`，local 落盘真题树 `incoming/<短码>-exam/`（subject
  /// = 12 考站专题短码之一，见 corpus/exam_topics.dart；建库
  /// source_type='exam'，不进 subjects 表）；'outline'（节点④大纲上传）
  /// 时追加 `&source=outline`，local 落盘大纲树 `incoming/dagang-outline/`
  /// （subject 固定 dagang；建库路由到 outline 解析器 → outline_entries，
  /// 仅收 .docx）；缺省/'ppt'/其他值不携带本参数 = 课件树
  /// `incoming/<短码>/`，请求与既有字节零变化。词表对齐
  /// splitSubjectSource 的 sourceType（'ppt'=课件 / 'textbook'=教材 /
  /// 'exam'=真题 / 'outline'=大纲）。remote 服务器暂不识别本参数
  /// （routes/corpus.py 逐键取 query，未知参数静默忽略——教材/真题/大纲
  /// 选择在 remote 落普通课件目录），遗留面不修，见节点 handoff。
  Future<CorpusUploadResult> uploadCourseware(
    String subject,
    String filename,
    List<int> bytes, {
    String? source,
  }) async {
    final path =
        '/api/v1/corpus/upload'
        '?subject=${Uri.encodeQueryComponent(subject)}'
        '&filename=${Uri.encodeQueryComponent(filename)}'
        '${(source == 'textbook' || source == 'exam' || source == 'outline') ? '&source=$source' : ''}';
    // 本地分流（path 已带 /api/v1 前缀，后端归一化剥前缀）：
    // local 模式经校验链后直落本机 incoming/（Phase 3 抽取流水线消费）
    switch (currentBackendMode) {
      case BackendMode.demo:
        return CorpusUploadResult.fromJson(
          await DemoBackend.instance.upload(path, bytes),
        );
      case BackendMode.local:
        return CorpusUploadResult.fromJson(
          await LocalBackend.instance.upload(path, bytes),
        );
      case BackendMode.remote:
        break;
    }
    _assertRemoteHttps(); // remote 门禁：禁明文 HTTP
    try {
      final req = await _client.postUrl(Uri.parse('$baseUrl$path'));
      // 上传是原始字节流，不能用 _headers 的 JSON Content-Type
      req.headers.set('Content-Type', 'application/octet-stream');
      if (token != null) req.headers.set('Authorization', 'Bearer $token');
      req.add(bytes);
      final res = await req.close().timeout(const Duration(seconds: 120));
      final text = await res.transform(utf8.decoder).join();
      if (res.statusCode >= 400) throw ApiException(res.statusCode, text);
      return CorpusUploadResult.fromJson(
        Map<String, dynamic>.from(jsonDecode(text) as Map),
      );
    } on SocketException catch (e) {
      throw ApiException(0, '网络不可达: $e');
    } on HttpException {
      throw ApiException(0, '上传中断，请重试');
    } on TimeoutException {
      throw ApiException(0, '上传超时，请重试');
    }
  }

  // ---------------- 知识库建库（App 内建库接线；local 实装，demo/remote 404） ----------------

  /// 建库状态视图：`GET /api/v1/corpus/build`
  /// → {running, mode, modePreview, pendingFiles,
  ///    pending:[{subject, filename, sizeBytes}],
  ///    progress?{stage, message, counts},
  ///    result?{chunks, embedded, elapsedS, extract, ingest?, notes},
  ///    error?, cancelled}。local 实装；demo/remote → 404（本节 UI 已按
  /// local 模式隐藏，其余调用方自行降级）。
  Future<CorpusBuildStatus> fetchCorpusBuildStatus() async {
    return CorpusBuildStatus.fromJson(await _getJson('/api/v1/corpus/build'));
  }

/// 触发建库：`POST /api/v1/corpus/build`（body {mode?}——缺省服务端按
  /// embedding key 有无自动选路；[mode] 显式指定仅测试/演练用，如 'drill'）。
  /// [resetVectors]=true → 强制向量全量重建（2026-09-11「重建全部向量」：
  /// 清空 vectors + checkpoint 后按当前配置全量重嵌；incoming 无源文件时
  /// 走库内自嵌）。[backfillVectors]=true → 增量补齐（2026-09-12「补齐缺失
  /// 向量」：保留现有向量，断点检查只嵌缺失部分；模型/维度不符被拒）。
  /// 单飞守卫：运行中重复触发 → triggered=false + running=true。
  /// 进度经 `LocalBackend.instance.corpusBuildState` 流订阅（local 专用旁路
  /// ——请求/响应通道装不下 Stream）。
  Future<CorpusBuildTriggerResult> triggerCorpusBuild(
      {String? mode, bool resetVectors = false, bool backfillVectors = false}) async {
    final body = <String, dynamic>{
      if (mode != null && mode.isNotEmpty) 'mode': mode,
      if (resetVectors) 'resetVectors': true,
      if (backfillVectors) 'backfillVectors': true,
    };
    return CorpusBuildTriggerResult.fromJson(
      await _postJson('/api/v1/corpus/build', body),
    );
  }

  // ---------------- 学习进度（§7.5：只读罗盘端点） ----------------

  /// 学习进度一览（§7.5）：`GET /api/v1/progress`
  /// → {"subjects":[{id,textbook,learned_through,total,next_chapter}],
  ///     "updated_at"}。旧服务器（0.2.0）→ 404，由调用方降级提示
  /// 「需服务器 0.3.0+」；服务器无 progress.json → 200 + 空列表（空态）。
  /// 无罗盘科目（textbook=null，如 derm 占位）由 UI 层隐藏或标注。
  Future<ProgressOverview> fetchProgress() => _withCache(
    CacheKeys.progress,
    () => _getJson('/api/v1/progress'),
    (json) => ProgressOverview.fromJson(json as Map<String, dynamic>),
  );

  /// 单科章节管理（⑨）：`GET /api/v1/progress/<subject>/chapters`
  /// → {id, textbook, learned_through(原始指针), skipped:[no], total,
  ///    effective_total, effective_learned, next_chapter,
  ///    chapters:[{no,title,page_start,learned,skipped}]}。
  /// 科目不在进度库 → 404。旧服务器（0.3.x）无此路由 → 404 由调用方降级。
  Future<SubjectChapters> fetchSubjectChapters(String subjectId) async {
    return SubjectChapters.fromJson(
      await _getJson('/api/v1/progress/$subjectId/chapters'),
    );
  }

  /// 章节管理写（⑨）：`PUT /api/v1/progress/<subject>/chapters`
  /// body {learned_through?, skipped?}（缺省字段不动——读-改-写整个
  /// progress.json，与流水线 study-log 推进共存）。回退（目标 < 当前指针）
  /// 由调用方 UI 弹确认后调用。返回写后最新单科视图。
  Future<ProgressChaptersUpdate> updateSubjectChapters(
    String subjectId, {
    int? learnedThrough,
    List<int>? skipped,
  }) async {
    return ProgressChaptersUpdate.fromJson(
      await _putJson('/api/v1/progress/$subjectId/chapters', {
        'learned_through': ?learnedThrough,
        'skipped': ?skipped,
      }),
    );
  }

  // ---------------- AI 服务配置（M5：生卡 LLM / 向量模型；重排序 Phase 4） ----------------

  /// 契约（server 0.3.0+ / local 端上实现；reranker 仅 demo/local 支持时
  /// remote 旧服务器 404 → 调用方降级提示）：
  ///   `GET  /api/v1/settings/ai`          → {llm:{...}, embedding:{...}, reranker:{...}}
  ///   `PUT  /api/v1/settings/ai/<svc>`    body {baseUrl, model, apiKey}（apiKey 空串=不改 key）
  ///   `POST /api/v1/settings/ai/<svc>/test`  body 同上（apiKey 空则用已存 key）
  /// 旧服务器（0.2.0）无此路由 → 404，由调用方降级提示「需服务器 0.3.0+」。
  /// 安全：明文 key 只进请求体（HTTPS+自签 CA pinning），不落 SharedPreferences/日志；
  /// 界面只展示服务端返回的掩码 keyMasked。
  ///
  /// reranker（Phase 4 检索引擎消费契约）：
  ///   · baseUrl = **完整 rerank 端点**（不拼后缀）——最小探测/生产重排均直接
  ///     `POST <baseUrl>`，body {model, query, documents[], top_n}，Bearer key
  ///     （SiliconFlow /rerank 契约，响应 {id, results:[{index, relevance_score}]}）
  ///   · 端上存储（local 模式）：baseUrl/model 存 hengya.db settings 表键
  ///     reranker.baseUrl / reranker.model；apiKey 经 AiKeyVault 存系统安全
  ///     存储（flutter_secure_storage，安全修复 C），不入库不落明文
  ///   · 读取接口：本类 fetchAiSettings().reranker（掩码态）或
  ///     LocalBackend GET /settings/ai；明文 key 仅 LocalBackend 内部经
  ///     AiKeyVault 实例取用
  static const Set<String> kAiServices = {'llm', 'embedding', 'reranker'};

  /// reranker 默认预填（未配置时编辑层回填；用户可改任意）：
  /// URL = SiliconFlow 完整 rerank 端点，模型 = SiliconFlow 实际模型 ID
  /// （官方 /rerank 契约示例同值）。
  static const String kRerankerDefaultUrl =
      'https://api.siliconflow.cn/v1/rerank';
  static const String kRerankerDefaultModel = 'Qwen/Qwen3-Reranker-8B';

  void _checkAiService(String service) {
    if (!kAiServices.contains(service)) {
      throw ArgumentError.value(
        service,
        'service',
        '必须是 llm、embedding 或 reranker',
      );
    }
  }

  /// 拉取三套 AI 服务配置（掩码态）
  Future<AiSettings> fetchAiSettings() async {
    final json = await _getJson('/api/v1/settings/ai');
    return AiSettings.fromJson(json);
  }

  /// #11 查重阈值（GET /api/v1/settings/dup；默认 0.92 由后端兜底）
  Future<double> fetchDupThreshold() async {
    final json = await _getJson('/api/v1/settings/dup');
    return (json['threshold'] as num?)?.toDouble() ?? 0.92;
  }

  /// #11 查重阈值写入（PUT /api/v1/settings/dup；生效于下一轮流水线）
  Future<void> updateDupThreshold(double threshold) async {
    await _putJson('/api/v1/settings/dup', {'threshold': threshold});
  }

  /// 更新一套 AI 服务配置。apiKey 传空串 = 保持已存 key 不变。
  Future<AiServiceUpdateResult> updateAiService(
    String service, {
    required String baseUrl,
    required String model,
    String apiKey = '',
  }) {
    _checkAiService(service);
    return _putJson('/api/v1/settings/ai/$service', {
      'baseUrl': baseUrl,
      'model': model,
      'apiKey': apiKey,
    }).then(AiServiceUpdateResult.fromJson);
  }

  /// 测试连接（服务端真调上游接口）：返回 ok/上游 status/延迟/失败原因。
  /// apiKey 空则服务端用已存 key；上游连不上时 ok=false（HTTP 仍 200），不是异常。
  Future<AiServiceTestResult> testAiService(
    String service, {
    required String baseUrl,
    required String model,
    String apiKey = '',
  }) {
    _checkAiService(service);
    return _postJson('/api/v1/settings/ai/$service/test', {
      'baseUrl': baseUrl,
      'model': model,
      'apiKey': apiKey,
    }).then(AiServiceTestResult.fromJson);
  }
}

/// ---------------- 离线评分队列持久层（审计 P0 整改） ----------------
///
/// 抽象：append 落盘 / restore 启动恢复 / drainPreview 取批 / clear 清空。
/// 生产实现 [SharedPrefsAnswerStore]（shared_preferences）；
/// 测试用 [InMemoryAnswerStore]（无插件依赖）。
abstract class OfflineAnswerStore {
  Future<void> append(Map<String, dynamic> item);
  Future<int> restore();
  List<Map<String, dynamic>> drainPreview();
  Future<void> clear();
  bool get isEmpty;
  int get count;
}

/// 生产实现：SharedPreferences 单键 JSON 数组落盘
class SharedPrefsAnswerStore implements OfflineAnswerStore {
  SharedPrefsAnswerStore(this._prefs);

  final SharedPreferences _prefs;

  static const _key = 'hengya.offline_answers';

  List<Map<String, dynamic>> _cache = [];

  @override
  Future<void> append(Map<String, dynamic> item) async {
    _cache.add(item);
    await _save();
  }

  @override
  Future<int> restore() async {
    final raw = _prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      _cache = [];
      return 0;
    }
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      _cache = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      return _cache.length;
    } catch (_) {
      _cache = []; // 磁盘数据损坏 → 弃掉，不让坏数据卡死评分
      return 0;
    }
  }

  @override
  List<Map<String, dynamic>> drainPreview() => List.from(_cache);

  @override
  Future<void> clear() async {
    _cache = [];
    await _save();
  }

  @override
  bool get isEmpty => _cache.isEmpty;

  @override
  int get count => _cache.length;

  Future<void> _save() async {
    await _prefs.setString(_key, jsonEncode(_cache));
  }
}

/// 测试实现：纯内存
class InMemoryAnswerStore implements OfflineAnswerStore {
  final List<Map<String, dynamic>> _items = [];

  @override
  Future<void> append(Map<String, dynamic> item) async => _items.add(item);

  @override
  Future<int> restore() async => _items.length;

  @override
  List<Map<String, dynamic>> drainPreview() => List.from(_items);

  @override
  Future<void> clear() async => _items.clear();

  @override
  bool get isEmpty => _items.isEmpty;

  @override
  int get count => _items.length;
}

/// ---------------- 统计面数据类（M3） ----------------

class DueForecastDay {
  const DueForecastDay({required this.date, required this.due});

  final String date; // YYYY-MM-DD
  final int due;

  factory DueForecastDay.fromJson(Map<String, dynamic> json) => DueForecastDay(
    date: json['date'] as String,
    due: json['due'] as int? ?? 0,
  );
}

class StatsSummary {
  const StatsSummary({
    required this.totalReviews,
    required this.againRate,
    required this.pendingCards,
    required this.pendingInbox,
  });

  final int totalReviews;
  final double againRate; // 0.0 ~ 1.0
  final int pendingCards;
  final int pendingInbox;

  factory StatsSummary.fromJson(Map<String, dynamic> json) => StatsSummary(
    totalReviews: json['totalReviews'] as int? ?? 0,
    againRate: double.tryParse(json['againRate']?.toString() ?? '0') ?? 0.0,
    pendingCards: json['pendingCards'] as int? ?? 0,
    pendingInbox: json['pendingInbox'] as int? ?? 0,
  );
}

/// 保留率统计（近1/7/30天三档窗口）
class RetentionStats {
  const RetentionStats({required this.windows});

  final List<RetentionWindow> windows;

  factory RetentionStats.fromJson(Map<String, dynamic> json) {
    final list = json['windows'] as List<dynamic>? ?? [];
    return RetentionStats(
      windows: [
        for (final e in list)
          RetentionWindow.fromJson(Map<String, dynamic>.from(e as Map)),
      ],
    );
  }

  /// 取指定窗口（days=1/7/30）；无数据返回 null
  RetentionWindow? window(int days) {
    for (final w in windows) {
      if (w.days == days) return w;
    }
    return null;
  }
}

class RetentionWindow {
  const RetentionWindow({
    required this.days,
    required this.total,
    required this.retained,
    required this.rate,
  });

  final int days;
  final int total; // 窗口内总复习次数
  final int retained; // 回忆成功次数（≠ again）
  final double? rate; // 0.0 ~ 1.0；窗口无复习记录时为 null

  factory RetentionWindow.fromJson(Map<String, dynamic> json) =>
      RetentionWindow(
        days: json['days'] as int? ?? 0,
        total: json['total'] as int? ?? 0,
        retained: json['retained'] as int? ?? 0,
        rate: json['rate'] == null
            ? null
            : double.tryParse(json['rate'].toString()),
      );
}

/// ---------------- 题库面数据类（M4） ----------------

class BankSearchResult {
  const BankSearchResult({required this.total, required this.cards});

  final int total;
  final List<BankCard> cards;
}

/// 题库卡：FlashCard + 备注 + 调度状态摘要（列表显示「今天到期/已掌握/弱卡」）
/// （服务端响应仍含 aiNote 字段，App 留言入口已移除、不再解析）
class BankCard {
  const BankCard({
    required this.card,
    required this.userNote,
    this.dueAt,
    this.reps = 0,
    this.lapses = 0,
  });

  final FlashCard card;
  final String userNote;
  final DateTime? dueAt;
  final int reps;
  final int lapses;

  factory BankCard.fromJson(Map<String, dynamic> json) => BankCard(
    card: FlashCard.fromJson(json),
    userNote: json['userNote'] as String? ?? '',
    dueAt: json['dueAt'] == null || (json['dueAt'] as String).isEmpty
        ? null
        : DateTime.tryParse(json['dueAt'] as String),
    reps: json['reps'] as int? ?? 0,
    lapses: json['lapses'] as int? ?? 0,
  );
}

class CardNotes {
  const CardNotes({required this.userNote});

  final String userNote;

  factory CardNotes.fromJson(Map<String, dynamic> json) =>
      CardNotes(userNote: json['userNote'] as String? ?? '');
}

/// 流水线触发结果（server 0.4.1+：`POST /api/v1/pipeline/trigger`）
class PipelineTriggerResult {
  const PipelineTriggerResult({
    required this.ok,
    required this.triggered,
    this.note,
  });

  final bool ok;
  final bool triggered;
  final String? note;

  factory PipelineTriggerResult.fromJson(Map<String, dynamic> json) =>
      PipelineTriggerResult(
        ok: json['ok'] == true,
        triggered: json['triggered'] == true,
        note: json['note'] as String?,
      );
}

/// 自动周扫计时状态/调整结果（local 0.1.13+：`GET|PUT /api/v1/pipeline/weekly`）。
class WeeklyScanStatus {
  const WeeklyScanStatus({
    required this.ok,
    required this.due,
    this.lastRunAt,
    this.intervalDays = 7,
    this.note,
  });

  final bool ok;

  /// 上次自动周扫时间（ISO；null = 从未/已清除）。
  final String? lastRunAt;

  /// 自动周扫最小间隔（天；当前 7）。
  final int intervalDays;

  /// 距上次 ≥intervalDays（或从未跑过）= 到期——下次 catchup 收尾会自动扫。
  final bool due;

  final String? note;

  factory WeeklyScanStatus.fromJson(Map<String, dynamic> json) =>
      WeeklyScanStatus(
        ok: json['ok'] != false,
        lastRunAt: json['lastRunAt'] as String?,
        intervalDays: (json['intervalDays'] as num?)?.toInt() ?? 7,
        due: json['due'] == true,
        note: json['note'] as String?,
      );
}

/// ---------------- AI 服务配置数据类（M5；reranker Phase 4） ----------------

/// 三套 AI 服务配置：生卡 LLM + 向量模型 + 重排序模型
/// （旧服务器/旧响应缺 reranker 节点 → 防御式回退 empty）
class AiSettings {
  const AiSettings({
    required this.llm,
    required this.embedding,
    this.reranker = AiServiceConfig.empty,
    this.llmBackup = AiServiceConfig.empty,
  });

  final AiServiceConfig llm;
  final AiServiceConfig embedding;
  final AiServiceConfig reranker;

  /// 备用生卡 LLM（local 模式主备 failover；旧后端无此节点 → empty 兜底）。
  final AiServiceConfig llmBackup;

  factory AiSettings.fromJson(Map<String, dynamic> json) {
    final llm = json['llm'];
    final embedding = json['embedding'];
    final reranker = json['reranker'];
    final llmBackup = json['llm_backup'];
    return AiSettings(
      llm: llm is Map
          ? AiServiceConfig.fromJson(Map<String, dynamic>.from(llm))
          : AiServiceConfig.empty,
      embedding: embedding is Map
          ? AiServiceConfig.fromJson(Map<String, dynamic>.from(embedding))
          : AiServiceConfig.empty,
      reranker: reranker is Map
          ? AiServiceConfig.fromJson(Map<String, dynamic>.from(reranker))
          : AiServiceConfig.empty,
      llmBackup: llmBackup is Map
          ? AiServiceConfig.fromJson(Map<String, dynamic>.from(llmBackup))
          : AiServiceConfig.empty,
    );
  }

/// 按服务名取配置（service ∈ llm | llm_backup | embedding | reranker）
  AiServiceConfig of(String service) => switch (service) {
    'embedding' => embedding,
    'reranker' => reranker,
    'llm_backup' => llmBackup,
    _ => llm,
  };
}

/// 单套 AI 服务配置（掩码态——明文 key 永不出服务端）
class AiServiceConfig {
  const AiServiceConfig({
    required this.baseUrl,
    required this.model,
    required this.keySet,
    required this.keyMasked,
    required this.encrypted,
  });

  final String baseUrl;
  final String model;
  final bool keySet; // 是否已配置 key
  final String keyMasked; // 服务端返回的掩码，原样展示
  final bool encrypted; // key 在服务端是否加密存储

  static const empty = AiServiceConfig(
    baseUrl: '',
    model: '',
    keySet: false,
    keyMasked: '',
    encrypted: false,
  );

  factory AiServiceConfig.fromJson(Map<String, dynamic> json) =>
      AiServiceConfig(
        baseUrl: json['baseUrl'] as String? ?? '',
        model: json['model'] as String? ?? '',
        keySet: json['keySet'] as bool? ?? false,
        keyMasked: json['keyMasked'] as String? ?? '',
        encrypted: json['encrypted'] as bool? ?? false,
      );

  /// 界面展示规则：已配置 → 掩码原样展示；未配置 → 「未配置」
  String get keyDisplay => keySet ? keyMasked : '未配置';

  /// 加密状态展示（未配置 key 时不展示）
  String get encryptedDisplay => keySet ? (encrypted ? '已加密' : '未加密') : '';
}

/// `PUT /settings/ai/<service>` 响应
class AiServiceUpdateResult {
  const AiServiceUpdateResult({
    required this.ok,
    required this.keySet,
    required this.keyMasked,
  });

  final bool ok;
  final bool keySet;
  final String keyMasked;

  factory AiServiceUpdateResult.fromJson(Map<String, dynamic> json) =>
      AiServiceUpdateResult(
        ok: json['ok'] == true,
        keySet: json['keySet'] as bool? ?? false,
        keyMasked: json['keyMasked'] as String? ?? '',
      );
}

/// `POST /settings/ai/<service>/test` 响应
/// （ok=false 表示上游连不上/鉴权失败，HTTP 仍是 200；网络级错误才走 ApiException）
class AiServiceTestResult {
  const AiServiceTestResult({
    required this.ok,
    this.status = 0,
    this.latencyMs = 0,
    required this.message,
  });

  final bool ok;
  final int status; // 上游 HTTP 状态码
  final int latencyMs;
  final String message;

  factory AiServiceTestResult.fromJson(Map<String, dynamic> json) =>
      AiServiceTestResult(
        ok: json['ok'] == true,
        status: json['status'] as int? ?? 0,
        latencyMs: json['latencyMs'] as int? ?? 0,
        message: json['message'] as String? ?? '',
      );

  /// 界面一行展示：成功带延迟，失败带原因
  String get display => ok ? '连接正常 · $latencyMs ms' : '失败：$message';
}

/// ---------------- 动态科目数据类（M5） ----------------

/// 科目条目（/api/v1/subjects）：id / 名称 / 是否考试课 / 到期数。
/// 0.3.1 开源去内置：内置标记字段随内置科目概念一并移除
///（既有库 is_builtin 列已幂等归零，仅作 schema 兼容保留）。
class SubjectInfo {
  const SubjectInfo({
    required this.id,
    required this.name,
    this.isExamSubject = false,
    this.dueCount = 0,
  });

  final String id;
  final String name;
  final bool isExamSubject;
  final int dueCount;

  factory SubjectInfo.fromJson(Map<String, dynamic> json) => SubjectInfo(
    id: json['id'] as String,
    name: json['name'] as String,
    isExamSubject: json['isExamSubject'] as bool? ?? false,
    dueCount: json['dueCount'] as int? ?? 0,
  );
}

/// ---------------- 知识库数据类（M5） ----------------

/// 语料库状态（`GET /api/v1/corpus/status`）
class CorpusStatus {
  const CorpusStatus({
    required this.totalChunks,
    required this.subjects,
    this.lastBuild,
    required this.pendingFiles,
    this.reworkPending = 0,
    required this.storageMB,
  });

  final int totalChunks; // 语料块总数
  final Map<String, int> subjects; // 科目短码 → 语料块数
  final DateTime? lastBuild; // 最近一次向量构建；null=从未构建
  final int pendingFiles; // 待处理文件数
  final int reworkPending; // ⑦ 回炉待重造卡数（cards status='rework'）；旧服务端无此字段 → 0
  final double storageMB; // 存储占用（MB）

  factory CorpusStatus.fromJson(Map<String, dynamic> json) {
    final raw = json['subjects'];
    return CorpusStatus(
      totalChunks: json['totalChunks'] as int? ?? 0,
      subjects: raw is Map
          ? {
              for (final e in raw.entries)
                e.key: (e.value as num?)?.toInt() ?? 0,
            }
          : const {},
      lastBuild: json['lastBuild'] == null
          ? null
          : DateTime.tryParse(json['lastBuild'].toString()),
      pendingFiles: json['pendingFiles'] as int? ?? 0,
      reworkPending: (json['reworkPending'] as num?)?.toInt() ?? 0,
      storageMB: double.tryParse(json['storageMB']?.toString() ?? '0') ?? 0,
    );
  }

  /// 科目分布展示行：「近代史 18 · 有机化学 24」（无数据返回空串）
  String subjectLine(String Function(String id) nameOf) => [
    for (final e in subjects.entries) '${nameOf(e.key)} ${e.value}',
  ].join(' · ');
}

/// 上传课件响应（`POST /api/v1/corpus/upload`）
class CorpusUploadResult {
  const CorpusUploadResult({
    required this.ok,
    required this.received,
    required this.pending,
  });

  final bool ok;
  final int received; // 服务端收到的字节数
  final int pending; // 上传后的待处理文件数

  factory CorpusUploadResult.fromJson(Map<String, dynamic> json) =>
      CorpusUploadResult(
        ok: json['ok'] == true,
        received: json['received'] as int? ?? 0,
        pending: json['pending'] as int? ?? 0,
      );
}

/// ---------------- 知识库建库数据类（App 内建库接线；local 实装） ----------------

/// 待处理课件清单条目（`GET /api/v1/corpus/build` pending 项）
class PendingCourseware {
  const PendingCourseware({
    required this.subject,
    required this.filename,
    required this.sizeBytes,
  });

  final String subject; // 上传时选择的科目短码（= incoming/ 第一层子目录名；教材树为 <短码>-textbook）
  final String filename; // 清洗后的落盘文件名
  final int sizeBytes;

  factory PendingCourseware.fromJson(Map<String, dynamic> json) =>
      PendingCourseware(
        subject: json['subject'] as String? ?? '',
        filename: json['filename'] as String? ?? '',
        sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      );
}

/// 建库进度帧（最近一条 isolate 进度事件；stage ∈ start/extract/ingest/done）
class CorpusBuildProgress {
  const CorpusBuildProgress({
    required this.stage,
    required this.message,
    this.counts,
  });

  final String stage;
  final String message; // 人读中文（当前文件/批次等；不含 key）
  final Map<String, Object?>? counts;

  factory CorpusBuildProgress.fromJson(Map<String, dynamic> json) =>
      CorpusBuildProgress(
        stage: json['stage'] as String? ?? '',
        message: json['message'] as String? ?? '',
        counts: json['counts'] is Map
            ? Map<String, Object?>.from(json['counts'] as Map)
            : null,
      );
}

/// 最近一次建库结果摘要（CorpusBuildResult 的 JSON 同构视图；
/// extract / ingest 键 = ExtractAllStats / IngestStats toJson 契约）
class CorpusBuildSummary {
  const CorpusBuildSummary({
    required this.chunks,
    required this.embedded,
    required this.elapsedS,
    this.extract,
    this.ingest,
    this.notes = const [],
  });

  final int chunks; // 抽取 chunk 总数
  final int embedded; // 实际嵌入条数（offline 恒 0）
  final double elapsedS; // 总耗时（秒）
  final Map<String, Object?>? extract;
  final Map<String, Object?>? ingest; // null = 抽取 0 chunks 未入库
  final List<String> notes;

  factory CorpusBuildSummary.fromJson(Map<String, dynamic> json) =>
      CorpusBuildSummary(
        chunks: (json['chunks'] as num?)?.toInt() ?? 0,
        embedded: (json['embedded'] as num?)?.toInt() ?? 0,
        elapsedS: (json['elapsedS'] as num?)?.toDouble() ?? 0,
        extract: json['extract'] is Map
            ? Map<String, Object?>.from(json['extract'] as Map)
            : null,
        ingest: json['ingest'] is Map
            ? Map<String, Object?>.from(json['ingest'] as Map)
            : null,
        notes: [for (final n in (json['notes'] as List? ?? const [])) '$n'],
      );
}

/// `GET /api/v1/corpus/build` 响应（建库状态视图）。
/// 流事件帧不带 pending 清单 → [pendingFiles] = -1（UI 保留上一帧的清单值）。
class CorpusBuildStatus {
  const CorpusBuildStatus({
    required this.running,
    required this.mode,
    required this.modePreview,
    required this.pendingFiles,
    this.progress,
    this.result,
    this.error,
    this.cancelled = false,
    this.replacesForeign = false,
    this.pending = const [],
  });

  final bool running; // 建库是否在运行
  final String mode; // 本次/最近一次运行模式；无历史 = 自动选路预览
  final String modePreview; // 自动选路预览（key 有无 → online/offline）
  final int pendingFiles; // -1 = 帧不带清单（流事件）
  final CorpusBuildProgress? progress;
  final CorpusBuildSummary? result;
  final String? error; // 最近一次失败文本（成功后清 null）
  final bool cancelled;
  final bool replacesForeign; // 迁移语料替代警示（确认对话框展示）
  final List<PendingCourseware> pending;

  factory CorpusBuildStatus.fromJson(Map<String, dynamic> json) =>
      CorpusBuildStatus(
        running: json['running'] == true,
        mode: json['mode'] as String? ?? '',
        modePreview:
            json['modePreview'] as String? ?? json['mode'] as String? ?? '',
        pendingFiles: json.containsKey('pendingFiles')
            ? (json['pendingFiles'] as num?)?.toInt() ?? 0
            : -1,
        progress: json['progress'] is Map
            ? CorpusBuildProgress.fromJson(
                Map<String, dynamic>.from(json['progress'] as Map),
              )
            : null,
        result: json['result'] is Map
            ? CorpusBuildSummary.fromJson(
                Map<String, dynamic>.from(json['result'] as Map),
              )
            : null,
        error: json['error'] as String?,
        cancelled: json['cancelled'] == true,
        replacesForeign: json['replacesForeign'] == true,
        pending: [
          for (final e in (json['pending'] as List? ?? const []))
            PendingCourseware.fromJson(Map<String, dynamic>.from(e as Map)),
        ],
      );
}

/// `POST /api/v1/corpus/build` 响应（触发结果）
class CorpusBuildTriggerResult {
  const CorpusBuildTriggerResult({
    required this.ok,
    required this.triggered,
    this.running = false,
    this.mode,
    this.note,
  });

  final bool ok;
  final bool triggered; // false = 已在运行（单飞守卫；不报错）
  final bool running;
  final String? mode;
  final String? note;

  factory CorpusBuildTriggerResult.fromJson(Map<String, dynamic> json) =>
      CorpusBuildTriggerResult(
        ok: json['ok'] == true,
        triggered: json['triggered'] == true,
        running: json['running'] == true,
        mode: json['mode'] as String?,
        note: json['note'] as String?,
      );
}

/// ---------------- 学习进度数据类（§7.5，server 0.3.0+） ----------------

/// 学习罗盘下一章（服务端契约：no > learned_through 的第一条正文章）
class NextChapterInfo {
  const NextChapterInfo({required this.no, required this.title, this.page});

  final int no;
  final String title;
  final int? page; // 教材页码（page_start；缺失为 null）

  factory NextChapterInfo.fromJson(Map<String, dynamic> json) =>
      NextChapterInfo(
        no: json['no'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        page: json['page'] as int?,
      );

  /// 一行展示：「第三章 口腔颌面外科麻醉 p51」
  String get display => page != null ? '$title p$page' : title;
}

/// 单科进度（`GET /api/v1/progress` subjects 条目）
class SubjectProgress {
  const SubjectProgress({
    required this.id,
    this.textbook,
    required this.learnedThrough,
    required this.total,
    this.nextChapter,
  });

  final String id;
  final String? textbook; // 教材名；null = 未配置教材（无罗盘，如 derm 占位）
  final int learnedThrough; // 已学到第几章
  final int total; // 章节总数（原样含目录/索引等辅文章）
  final NextChapterInfo? nextChapter; // 学完 → null（服务端契约）

  /// 有罗盘（textbook 非空）——复习提示/进度条只对罗盘科目生效
  bool get hasTextbook => textbook != null;

  /// 学完态：无下一章即学完（服务端 §7.5 契约，含尾部辅文章读完的情形）
  bool get completed => nextChapter == null;

  /// 进度比例 0.0~1.0（total=0 防除零）
  double get fraction =>
      total > 0 ? (learnedThrough / total).clamp(0.0, 1.0) : 0;

  factory SubjectProgress.fromJson(Map<String, dynamic> json) =>
      SubjectProgress(
        id: json['id'] as String,
        textbook: json['textbook'] as String?,
        learnedThrough: json['learned_through'] as int? ?? 0,
        total: json['total'] as int? ?? 0,
        nextChapter: json['next_chapter'] is Map
            ? NextChapterInfo.fromJson(
                Map<String, dynamic>.from(json['next_chapter'] as Map),
              )
            : null,
      );
}

/// 全量进度一览（`GET /api/v1/progress` 顶层）
class ProgressOverview {
  const ProgressOverview({required this.subjects, this.updatedAt});

  final List<SubjectProgress> subjects; // 服务端 progress.json 原序
  final DateTime? updatedAt; // 各科 updated_at 最大值；无数据 → null

  factory ProgressOverview.fromJson(Map<String, dynamic> json) =>
      ProgressOverview(
        subjects: [
          for (final e in (json['subjects'] as List<dynamic>? ?? const []))
            SubjectProgress.fromJson(Map<String, dynamic>.from(e as Map)),
        ],
        updatedAt: json['updated_at'] == null
            ? null
            : DateTime.tryParse(json['updated_at'].toString()),
      );
}

/// ---------------- 章节管理数据类（⑨） ----------------

/// 单章状态（`GET /api/v1/progress/<subject>/chapters` chapters 条目）
class SubjectChapterStatus {
  const SubjectChapterStatus({
    required this.no,
    required this.title,
    this.page,
    required this.learned,
    required this.skipped,
  });

  final int no; // 章序（原始前缀指针语义的域）
  final String title; // 章名（罗盘数据源：toc sidecar → progress.json）
  final int? page; // 教材页码（page_start；缺失为 null）
  final bool learned; // 指针已越过（no ∈ (0, learned_through]）
  final bool skipped; // 「不学」：剔出有效总量与「下一章」

  factory SubjectChapterStatus.fromJson(Map<String, dynamic> json) =>
      SubjectChapterStatus(
        no: (json['no'] as num?)?.toInt() ?? 0,
        title: json['title'] as String? ?? '',
        page: (json['page_start'] as num?)?.toInt(),
        learned: json['learned'] == true,
        skipped: json['skipped'] == true,
      );
}

/// 单科章节管理视图（`GET /api/v1/progress/<subject>/chapters`）
class SubjectChapters {
  const SubjectChapters({
    required this.id,
    this.textbook,
    required this.learnedThrough,
    required this.skipped,
    required this.total,
    required this.effectiveTotal,
    required this.effectiveLearned,
    required this.chapters,
    this.nextChapter,
  });

  final String id;
  final String? textbook;
  final int learnedThrough; // 原始前缀指针（写端点直接吃同一语义）
  final List<int> skipped; // 「不学」章序（升序）
  final int total; // 原始章数（含目录/索引辅文章与跳过章）
  final int effectiveTotal; // 有效总量 = total − 跳过数
  final int effectiveLearned; // 有效已学 = 指针 − 指针区间内跳过数
  final List<SubjectChapterStatus> chapters; // 全章列表（罗盘原序）
  final NextChapterInfo? nextChapter; // 跳过感知的下一章；学完 → null

  /// 进度比例 0.0~1.0（effectiveTotal=0 防除零）
  double get fraction =>
      effectiveTotal > 0
      ? (effectiveLearned / effectiveTotal).clamp(0.0, 1.0)
      : 0;

  factory SubjectChapters.fromJson(Map<String, dynamic> json) =>
      SubjectChapters(
        id: json['id'] as String,
        textbook: json['textbook'] as String?,
        learnedThrough: json['learned_through'] as int? ?? 0,
        skipped: [
          for (final v in (json['skipped'] as List? ?? const []))
            if (v is int) v,
        ],
        total: json['total'] as int? ?? 0,
        effectiveTotal: json['effective_total'] as int? ?? 0,
        effectiveLearned: json['effective_learned'] as int? ?? 0,
        chapters: [
          for (final e in (json['chapters'] as List? ?? const []))
            SubjectChapterStatus.fromJson(Map<String, dynamic>.from(e as Map)),
        ],
        nextChapter: json['next_chapter'] is Map
            ? NextChapterInfo.fromJson(
                Map<String, dynamic>.from(json['next_chapter'] as Map),
              )
            : null,
      );
}

/// 章节管理写结果（`PUT /api/v1/progress/<subject>/chapters`：
/// 写后最新单科视图 + ok/note）
class ProgressChaptersUpdate {
  const ProgressChaptersUpdate({
    required this.ok,
    this.note,
    required this.chapters,
  });

  final bool ok;
  final String? note; // 概况（「推进 4 → 6，不学章 2 个」/「未变」）
  final SubjectChapters chapters; // 写后最新视图

  factory ProgressChaptersUpdate.fromJson(Map<String, dynamic> json) =>
      ProgressChaptersUpdate(
        ok: json['ok'] == true,
        note: json['note'] as String?,
        chapters: SubjectChapters.fromJson(json),
      );
}
