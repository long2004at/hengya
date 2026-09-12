// 本地后端（local-first，Phase 1）：ApiClient 的第二条本地分流——真数据层。
//
// 与 [DemoBackend] 同构（get/post/put/upload 四方法 + _normalize 剥 /api/v1
// 前缀），语义对照真实服务端 server/lib/src/routes/*.dart 逐路由移植
// （非演示模拟）：
//   health/meta   data_version（App 增量同步锚）
//   subjects      列表 dueCount + 新建（id 正则/自动短码/重码重名 409）+ 改名
//   cards         状态守卫（approve/reject 仅 pending、edit pending+active、
//                 rework 仅 active）+ 通配 /cards/<id> 居路由末位
//   review/answer 逐条加固（单条脏数据只 skip 不 500，对照 routes/review.dart）
//   inbox         关键词校验链（缺 subjectId/keyword/未知科目 → errors 细目）
//   stats         days clamp（forecast/heatmap 1..365）
//   progress      progress.json + 辅文章过滤（§7.9 九项精确集合，去空白归一）
//   corpus        status 优雅降级 + upload 校验链（科目/清洗/白名单/魔数）+
//                 build 触发/进度/结果（App 内建库：consume 上游 isolate job）
//   settings/ai   掩码态（明文 key 永不出后端；key 存系统安全存储
//                 AiKeyVault——Android Keystore 加密，settings 表只留空
//                 键位；三套服务：llm / embedding / reranker——键名
//                 llm.*/embedding.*/reranker.*，key 经 [LocalBackend.aiKeyOf]
//                 从内存缓存同步取用）
//   pipeline      .force_run 标志 + pipelineKick 后台消费（Phase 4 端上流水线
//
// 响应形状约定（对齐 DemoBackend 与真实服务端）：裸数组端点（pending/
// inbox/forecast）包 {'list': [...]}；裸对象（单卡）直接返回 Map；包裹端点
// 与服务端同形。错误抛 [ApiException]（裸中文消息，UI 直接显示）。
//
// 数据层 = db.dart（server/lib/src/db.dart 逐字节移植，package:sqlite3）。
// 生产 hengya.db 直接拷贝迁移（一人一机一库）。
//
// 初始化：main() 用 getApplicationSupportDirectory() 调 [init]；
// 测试直接 init(临时目录)。未初始化调用 → StateError（首屏挂掉优于静默
// 写错位置）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared/hengya_shared.dart';
import 'package:sqlite3/sqlite3.dart' show OpenMode, sqlite3;

import '../api/api_client.dart';
import 'ai_key_vault.dart';
import 'card_dedup.dart' show dupThresholdOf, kDupThresholdSettingKey;
import 'corpus/extract_all.dart' show CorpusEmbedMode, loadManifest;
import 'corpus/exam_topics.dart';
import 'corpus/outline_docx.dart' show kOutlineUploadCode;
import 'corpus/progress_db.dart'
    show
        initFromTocSidecar,
        loadProgress,
        progressEntryOf,
        saveProgress,
        setSubjectChapters,
        skippedChaptersOf,
        tocSidecarSubjects;
import 'corpus/search_api.dart' show normalizeRerankEndpoint;
import 'corpus_build_job.dart';
import 'data_maintenance.dart';
import 'db.dart';
import 'app_log.dart';
import 'isolate_runner.dart';
import 'pipeline_runner.dart'
    show
        PipelineRunner,
        kWeeklyScanInterval,
        kWeeklyScanSettingKey,
        weeklyScanDue;

class LocalBackend {
  LocalBackend._();

  static final LocalBackend instance = LocalBackend._();

  // ---------------- 初始化 ----------------

  /// 数据根目录（hengya.db 与 corpus/ 均挂其下）。
  String? _dataDir;
  Future<Db>? _opening;

  final Scheduler _scheduler = const FsrsScheduler();

  /// 初始化（幂等：以首次调用为准）。目录由调用方决定——生产
  /// getApplicationSupportDirectory()，测试临时目录。
  void init(String dataDir) => _dataDir ??= dataDir;

  String get _dbPath => '$_dataDir/hengya.db';

  /// 当前数据根目录（Phase 2 数据管理/备份用；未初始化为 null）
  String? get dataDir => _dataDir;

  /// 语料目录（corpus.db / progress.json / incoming/ / .force_run）
  String get _corpusDir => '$_dataDir/corpus';

  Future<Db> get _db {
    final dir = _dataDir;
    if (dir == null) {
      throw StateError('LocalBackend 未初始化：main() 需先 init(<数据目录>)');
    }
    return _opening ??= Db.open(_dbPath);
  }

  /// 数据文件被替换后重载连接（Phase 2 导入/恢复后由调用方调用：
  /// 关闭旧连接 → 下次访问重新 open 当前文件）。
  Future<void> reload() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) {
      final db = await opening;
      db.close();
    }
  }

  /// 测试辅助：关闭底层连接并重置单例（跨用例隔离；须 await）。
  /// 建库运行态在首个 await 之前同步清零——widget 假异步 tearDown 不 await
  /// 也立即生效（真实 job 由自身 finally 收尾；测试内不应遗留真实 job）。
  Future<void> resetForTest() async {
    _resetCorpusBuildState();
    _aiKeys.clear(); // AI key 缓存随单例重置（vault 状态由测试自行注入/清理）
    _aiKeysInit = null;
    await reload();
    _dataDir = null;
  }

  /// Phase 4：流水线等上层服务共用连接（与路由同源单写者，WAL）。
  Future<Db> get sharedDb => _routeDb;

  void _ensureDataAvailable() {
    if (DataMaintenance.busy) {
      throw ApiException(409, '正在${DataMaintenance.operation}，请稍后再试');
    }
    final dir = _dataDir;
    if (dir != null && File('$dir/.full-restore-journal.json').existsSync()) {
      throw ApiException(409, '上次恢复尚未完成，请重启应用修复后再使用');
    }
  }

  Future<Db> get _routeDb async {
    _ensureDataAvailable();
    final db = await _db;
    _ensureDataAvailable(); // 初始化 await 期间也可能进入备份/恢复
    return db;
  }

  // ---------------- AI key 安全存储（安全修复 C：vault + 内存缓存） ----------------

  /// AI 服务 key 内存缓存（svc → key）：vault 读写是异步平台通道调用，
  /// 而消费方（路由 / 建库选路 / 掩码视图）多为同步上下文——启动时
  /// [initAiKeys] 一次性预热，运行期经 [aiKeyOf] 同步取用（写路径见
  /// settings/ai PUT：同步更新缓存 + vault 异步落盘）。
  final Map<String, String> _aiKeys = {};

  /// [initAiKeys] 单飞 memo（幂等；失败置 null，下次调用重试）。
  Future<void>? _aiKeysInit;

  /// 三把 AI key 从 [AiKeyVault] 预热入缓存（幂等；main() 启动接线 +
  /// settings/ai PUT 首用兜底）。先经 [AiKeyVault.migrateFromDb] 把旧库
  /// settings 表明文 key 一次性迁入 vault（键位保留、值清空），再读 vault。
  Future<void> initAiKeys() {
    final pending = _aiKeysInit;
    if (pending != null) return pending;
    final init = _loadAiKeys();
    _aiKeysInit = init;
    return init;
  }

  Future<void> _loadAiKeys() async {
    try {
      final db = await _db;
      await AiKeyVault.instance.migrateFromDb(db);
      for (final svc in kAiKeyServices) {
        _aiKeys[svc] = await AiKeyVault.instance.read(svc);
      }
    } catch (_) {
      _aiKeysInit = null; // 失败不缓存失败态：下次调用重试
      rethrow;
    }
  }

  /// 运行期同步取 AI key（缓存未命中返回 ''；写入见 settings/ai PUT 路径）。
  String aiKeyOf(String svc) => _aiKeys[svc] ?? '';

  // ---------------- Phase 4：流水线后台执行接线 ----------------

  /// /pipeline/trigger 的后台执行回调：main() 装配
  /// `PipelineRunner.instance.consumeForceRun`；未装配（测试/CLI）只落标志
  /// ——与服务端「.force_run 标志 + cron 消费」同构。触发/排队两分支都
  /// kick（幂等）：排队分支的标志若为上次失败遗留，重复触发即重试消费。
  /// consumeForceRun 单飞自旋，重复 kick 无并发风险；本回调绝不抛。
  static Future<void> Function()? pipelineKick;

  /// /pipeline/weekly（手动真题周扫）的后台执行回调：main() 装配
  /// `PipelineRunner.instance.consumeWeeklyRun`。无标志文件语义——kick 即
  /// 执行；weekly-only 轮与 catchup 共用 [_spinning] 单飞互斥；本回调绝不抛。
  static Future<void> Function()? weeklyKick;

  // ---------------- 卡片导入（拆卡流水线入库） ----------------

  /// 批量导入卡片（对照 server `POST /cards/import` 语义：FlashCard.fromJson
  /// 逐条解析，未知科目 → errors 细目、id 已存在幂等 skip；插入成功 bump
  /// data_version）。Phase 4 端上拆卡流水线与本文件测试共用。
  Future<Map<String, dynamic>> importCards(List<dynamic> rawCards) async {
    final db = await _routeDb;
    _ensureDataAvailable();
    var inserted = 0, skipped = 0;
    final errors = <String>[];
    for (var i = 0; i < rawCards.length; i++) {
      try {
        final card = FlashCard.fromJson(
          Map<String, dynamic>.from(rawCards[i] as Map),
        );
        if (!db.subjectExists(card.subjectId)) {
          errors.add('#$i 未知科目 ${card.subjectId}');
          continue;
        }
        if (db.importCard(card)) {
          inserted++;
        } else {
          skipped++; // 幂等：id 已存在
        }
      } catch (e) {
        errors.add('#$i 解析失败: $e');
      }
    }
    if (inserted > 0) db.bumpDataVersion();
    return {
      'ok': true,
      'inserted': inserted,
      'skipped': skipped,
      if (errors.isNotEmpty) 'errors': errors,
    };
  }

  // ---------------- 路由归一化（与 DemoBackend 同构） ----------------

  String _normalize(String path) {
    const prefix = '/api/v1';
    if (path == prefix) return '/';
    return path.startsWith('$prefix/') ? path.substring(prefix.length) : path;
  }

  Map<String, String> _parseQuery(String path) =>
      Uri.parse(path).queryParameters;

  // ---------------- GET ----------------

  Future<Map<String, dynamic>> get(String path) async {
    final db = await _routeDb;
    _ensureDataAvailable();
    path = _normalize(path);

    // /health（无 /api/v1 前缀也直达——ApiClient fetchHealth 特例）
    if (path == '/health') {
      return {'status': 'ok', 'data_version': db.dataVersion};
    }

    // /meta/version
    if (path.startsWith('/meta/version')) {
      return {'data_version': db.dataVersion};
    }

    // /subjects（列表 + 各科 dueCount；对照 routes/subjects.dart）
    if (path.startsWith('/subjects')) {
      final dueCounts = db.dueCounts();
      return {
        'subjects': [
          for (final s in db.subjectRows())
            {...s, 'dueCount': dueCounts[s['id']] ?? 0},
        ],
      };
    }

// /settings/ai（掩码态；四套：llm / llm_backup / embedding / reranker）
    if (path == '/settings/ai') {
      return {
        'llm': _serviceView(db, 'llm'),
        'llm_backup': _serviceView(db, 'llm_backup'),
        'embedding': _serviceView(db, 'embedding'),
        'reranker': _serviceView(db, 'reranker'),
      };
    }

    // /corpus/status（对照 routes/corpus.dart _status：corpus.db 只读 + 优雅降级；
    // ⑦ 附带 cards 表 rework 计数——hengya.db 同连接读取，与语料降级无关）
    if (path == '/corpus/status') {
      return _corpusStatus(db);
    }

    // /corpus/build（App 内建库状态视图：运行态/模式选路/最近结果/待处理清单）
    if (path == '/corpus/build') {
      return _corpusBuildView(db);
    }

    // /corpus/diagnostics（#5 前半：语料库诊断——deck 来源分布 / 各类型
    // 块数 / 向量完整度 / 上次建库与嵌入模型。语料缺失/损坏 → 零值不炸）
    if (path == '/corpus/diagnostics') {
      return _corpusDiagnostics(db);
    }

    // /pipeline/weekly（自动周扫计时状态：节流时间戳 + 到期判定；清除后
    // settings 存的是空串——对外归一为 null，「从未跑过」单一表示）
    if (path == '/pipeline/weekly') {
      final lastRunAt = db.settingGet(kWeeklyScanSettingKey);
      return {
        'lastRunAt': (lastRunAt == null || lastRunAt.isEmpty)
            ? null
            : lastRunAt,
        'intervalDays': kWeeklyScanInterval.inDays,
        'due': weeklyScanDue(lastRunAt, DateTime.now()),
      };
    }

    // /settings/dup（#11 查重阈值状态；写入见 PUT）
    if (path == '/settings/dup') {
      return {'threshold': dupThresholdOf(db)};
    }

    // /cards/pending?limit=&offset=（server 裸数组 → {'list': [...]} 约定形状）
    // #15（2026-09-13）：分页 + total——审核区加载更多（原 100 张硬截断
    // 会淹掉 created_at 较旧的回炉完成卡）。limit/offset 缺省行为不变。
    // （query 版路径须显式 startsWith 匹配——精确匹配会落到 /cards/<id> 通配）
    if (path == '/cards/pending' || path.startsWith('/cards/pending?')) {
      final q = _parseQuery(path);
      final limit = int.tryParse(q['limit'] ?? '') ?? 100;
      final offset = int.tryParse(q['offset'] ?? '') ?? 0;
      return {
        'list': [
          for (final c in db.pendingCards(limit: limit, offset: offset))
            c.toJson(),
        ],
        'total': db.pendingCardsCount(),
      };
    }

    // /cards/queue?subject=xx&limit=50（科目隔离，决策 #8）
    if (path.startsWith('/cards/queue')) {
      final q = _parseQuery(path);
      final subject = q['subject'];
      if (subject == null || subject.isEmpty) {
        throw ApiException(400, '缺少 subject 参数（科目隔离，决策 #8）');
      }
      final limit = int.tryParse(q['limit'] ?? '') ?? 50;
      return {
        'cards': [
          for (final c in db.dueCards(subject, limit: limit)) c.toJson(),
        ],
      };
    }

    // /cards/leech?threshold=4
    if (path.startsWith('/cards/leech')) {
      final q = _parseQuery(path);
      final threshold = int.tryParse(q['threshold'] ?? '') ?? 4;
      return {
        'cards': [
          for (final c in db.leechCards(threshold: threshold)) c.toJson(),
        ],
      };
    }

    // /cards/search?subject=&q=&offset=&limit=（limit clamp 1..200）
    if (path.startsWith('/cards/search')) {
      final q = _parseQuery(path);
      final subject = q['subject'];
      final (cards, total) = db.searchCards(
        subject: (subject != null && subject.isEmpty) ? null : subject,
        q: q['q'],
        offset: int.tryParse(q['offset'] ?? '') ?? 0,
        limit: (int.tryParse(q['limit'] ?? '') ?? 50).clamp(1, 200),
      );
      return {'cards': cards, 'total': total};
    }

    // /cards/<id>/notes
    final notesGet = RegExp(r'^/cards/([^/]+)/notes$').firstMatch(path);
    if (notesGet != null) {
      final id = notesGet.group(1)!;
      if (db.cardById(id) == null) throw ApiException(404, '卡 $id 不存在');
      return db.cardNotes(id) ?? const {'userNote': '', 'aiNote': ''};
    }

    // /cards/rework/pending（queue + 未读学生留言）
    if (path == '/cards/rework/pending') {
      return {'queue': db.reworkPending(), 'aiNotes': db.unreadAiNotes()};
    }

    // /cards/<id>（通配居末位：search/queue/leech 等具体路径已在前面消化）
    final cardGet = RegExp(r'^/cards/([^/]+)$').firstMatch(path);
    if (cardGet != null) {
      final detail = db.cardDetail(cardGet.group(1)!);
      if (detail == null) throw ApiException(404, '卡 ${cardGet.group(1)} 不存在');
      return detail;
    }

    // /inbox/pending
    if (path == '/inbox/pending') {
      return {'list': db.inboxPending()};
    }

    // /stats/*（days clamp 对照 routes/stats.dart）
    if (path.startsWith('/stats/streak')) {
      return {'streak': db.streakDays()};
    }
    if (path.startsWith('/stats/heatmap')) {
      final days = (int.tryParse(_parseQuery(path)['days'] ?? '') ?? 84).clamp(
        1,
        365,
      );
      return {'days': days, 'byDay': db.heatmapDays(days: days)};
    }
    if (path.startsWith('/stats/forecast')) {
      final days = (int.tryParse(_parseQuery(path)['days'] ?? '') ?? 7).clamp(
        1,
        365,
      );
      return {'list': db.dueForecast(days: days)};
    }
    if (path.startsWith('/stats/summary')) {
      final days = int.tryParse(_parseQuery(path)['days'] ?? '') ?? 7;
      return db.statsSummary(days: days);
    }
    if (path.startsWith('/stats/retention')) {
      return db.retentionStats();
    }

    // /progress（progress.json + 辅文章过滤，对照 routes/progress.dart）
    if (path == '/progress') {
      return _progressView();
    }

    // /progress/<subject>/chapters（⑨ 章节管理：单科全章列表 + 手动推进/
    // 回退/跳过状态；对照 §7.5 只读契约的写扩展——仅 local 模式实装）
    final chapterGet = RegExp(r'^/progress/([^/]+)/chapters$').firstMatch(path);
    if (chapterGet != null) {
      return _subjectChaptersView(chapterGet.group(1)!);
    }

    throw ApiException(404, '本地模式不支持: $path');
  }

  // ---------------- POST ----------------

  Future<Map<String, dynamic>> post(String path, Object? body) async {
    final db = await _routeDb;
    _ensureDataAvailable();
    path = _normalize(path);
    final m = body is Map
        ? Map<String, dynamic>.from(body)
        : const <String, dynamic>{};

    // /cards/<id>/approve（守卫：仅 pending，对照 routes/cards.dart）
    final approve = RegExp(r'^/cards/([^/]+)/approve$').firstMatch(path);
    if (approve != null) {
      final id = approve.group(1)!;
      final card = db.cardById(id);
      if (card == null) throw ApiException(404, '卡 $id 不存在');
      if (card.status != CardStatus.pending) {
        throw ApiException(400, '卡 $id 状态为 ${card.status.name}，仅 pending 可批准');
      }
      db.activateCard(id);
      db.bumpDataVersion();
      return {'ok': true, 'id': id, 'status': 'active'};
    }

    // /cards/<id>/reject（有理由 → 登记回炉队列，柔性反馈通道）
    final reject = RegExp(r'^/cards/([^/]+)/reject$').firstMatch(path);
    if (reject != null) {
      final id = reject.group(1)!;
      final card = db.cardById(id);
      if (card == null) throw ApiException(404, '卡 $id 不存在');
      if (card.status != CardStatus.pending) {
        throw ApiException(400, '卡 $id 状态为 ${card.status.name}，仅 pending 可拒绝');
      }
      final reason = ((m['reason'] as String?) ?? '').trim();
      final note = ((m['note'] as String?) ?? '').trim();
      if (reason.isEmpty) {
        db.rejectCard(id);
      } else {
        db.rejectCardWithReason(id, reason, note);
      }
      db.bumpDataVersion();
      // #2 埋点：审核拒绝（回炉循环入口事件）
      AppLog.instance.log(AppLogLevel.info, 'review',
          '审核拒绝：${_head(card.front, 30)}；理由=$reason${note.isEmpty ? '' : '；留言=$note'}');
      return {'ok': true, 'id': id, 'status': 'rejected'};
    }

    // /cards/<id>/notes（userNote/aiNote 至少其一；trim 后落库）
    final notesPost = RegExp(r'^/cards/([^/]+)/notes$').firstMatch(path);
    if (notesPost != null) {
      final id = notesPost.group(1)!;
      if (db.cardById(id) == null) throw ApiException(404, '卡 $id 不存在');
      final userNote = m['userNote'] as String?;
      final aiNote = m['aiNote'] as String?;
      if (userNote == null && aiNote == null) {
        throw ApiException(400, '至少传 userNote 或 aiNote 之一');
      }
      if (userNote != null) db.updateUserNote(id, userNote.trim());
      if (aiNote != null) db.updateAiNote(id, aiNote.trim());
      db.bumpDataVersion();
      return {
        'ok': true,
        'id': id,
        ...(db.cardNotes(id) ?? const {'userNote': '', 'aiNote': ''}),
      };
    }

    // /cards/<id>/edit（契约放宽：pending 与 active 均可编辑）
    final edit = RegExp(r'^/cards/([^/]+)/edit$').firstMatch(path);
    if (edit != null) {
      final id = edit.group(1)!;
      final card = db.cardById(id);
      if (card == null) throw ApiException(404, '卡 $id 不存在');
      if (card.status != CardStatus.pending &&
          card.status != CardStatus.active) {
        throw ApiException(
          400,
          '卡 $id 状态为 ${card.status.name}，仅 pending/active 可编辑',
        );
      }
      db.editPendingCard(
        id,
        front: m['front'] as String?,
        back: m['back'] as String?,
        anchor: m['anchor'] as String?,
      );
      db.bumpDataVersion();
      return {'ok': true, 'id': id, 'card': db.cardById(id)!.toJson()};
    }

    // /cards/rework（守卫：仅 active）
    // #10② 幂等：重造中的重复提交不再抛 400——旧文案
    // 「卡 <内部id> 状态为 rework，仅 active 可回炉」经 UI 前缀「提交失败：」
    // 直接把内部 id 泄给用户；现返回 duplicate:true 幂等成功（不重复入队），
    // UI 据此提示「已在回炉队列，无需重复提交」。
    // #15：余下分支（rejected/archived 等非 active 且非重造中）的 400/404
    // 文案同样去内部 id 化——用户侧只需知道「这张卡不能回炉」。
    if (path == '/cards/rework') {
      final cardId = m['cardId'] as String?;
      if (cardId == null || cardId.isEmpty) throw ApiException(400, '缺少 cardId');
      final card = db.cardById(cardId);
      if (card == null) throw ApiException(404, '卡片不存在或已被移除');
      if (card.status != CardStatus.active) {
        if (db.cardInReworkQueue(cardId)) {
          return {'ok': true, 'cardId': cardId, 'duplicate': true};
        }
        throw ApiException(400, '该卡当前状态不支持回炉（仅审核通过的在学卡可回炉）');
      }
      db.reworkCard(
        cardId,
        (m['reason'] as String?) ?? '',
        (m['note'] as String?) ?? '',
      );
      db.bumpDataVersion();
      // #2 埋点：回炉登记（题库/复习页入口）
      AppLog.instance.log(AppLogLevel.info, 'rework',
          '回炉登记：${_head(card.front, 30)}；理由=${(m['reason'] as String?) ?? ''}；留言=${(m['note'] as String?) ?? ''}');
      return {'ok': true, 'cardId': cardId};
    }

    // /cards/delete（#15 移除废卡：物理删除，仅 rejected）
    // 文案不带内部 id（对齐 #10② 泄露整改）；重复删除同 id → 404
    // 「卡片不存在或已被移除」——卡行已不在、与「从未存在」不可区分，
    // 幂等语义由 404 承载（客户端重复提交不会产生半删状态）。
    if (path == '/cards/delete') {
      final cardId = m['cardId'] as String?;
      if (cardId == null || cardId.isEmpty) throw ApiException(400, '缺少 cardId');
      final err = db.deleteCard(cardId);
      if (err == 'not_found') throw ApiException(404, '卡片不存在或已被移除');
      if (err == 'not_rejected') throw ApiException(400, '仅已拒绝的废卡可移除');
      db.bumpDataVersion();
      // #2 埋点：物理删除属不可逆操作，必须留痕
      AppLog.instance.log(AppLogLevel.warn, 'review', '移除废卡（物理删除）：$cardId');
      return {'ok': true, 'cardId': cardId};
    }

    // /cards/rework/<queueId>/done（回炉完成 → 回 pending；stale 400 / not_found 404）
    final done = RegExp(r'^/cards/rework/(\d+)/done$').firstMatch(path);
    if (done != null) {
      final queueId = int.parse(done.group(1)!);
      final err = db.reworkDone(
        queueId,
        front: m['front'] as String?,
        back: m['back'] as String?,
        anchor: m['anchor'] as String?,
      );
      if (err == 'not_found') throw ApiException(404, '回炉队列项 $queueId 不存在');
      if (err == 'stale') throw ApiException(400, '队列项 $queueId 已处理过');
      db.bumpDataVersion();
      final cardId = db.reworkQueueCardId(queueId);
      if (cardId != null) db.markAiNoteSeen(cardId);
      // #2 埋点：回炉完成 → 卡回待审核区
      AppLog.instance.log(AppLogLevel.info, 'rework',
          '回炉重造完成（队列 #$queueId${cardId == null ? '' : '，卡 $cardId'}）→ 卡回待审核区');
      return {
        'ok': true,
        'queueId': queueId,
        'card': cardId == null ? null : db.cardById(cardId)?.toJson(),
      };
    }

    // /review/answer（单条/批量；逐条加固对照 routes/review.dart M4.1：
    // 单条脏数据只 skip，绝不因单条让整批失败）
    if (path == '/review/answer') {
      final items = body is List ? body : [m];
      if (items.isEmpty) throw ApiException(400, '空评分列表');
      var applied = 0, skipped = 0;
      final results = <Map<String, dynamic>>[];

      for (final raw in items) {
        if (raw is! Map) {
          skipped++;
          results.add({
            'cardId': null,
            'ok': false,
            'error': '评分条目必须是 JSON 对象',
          });
          continue;
        }
        final item = Map<String, dynamic>.from(raw);
        final rawCardId = item['cardId'];
        if (rawCardId is! String || rawCardId.isEmpty) {
          skipped++;
          results.add({
            'cardId': rawCardId is String ? rawCardId : null,
            'ok': false,
            'error': '缺少或非法 cardId',
          });
          continue;
        }
        final cardId = rawCardId;
        final card = db.cardById(cardId);
        final mem = db.memoryStateOf(cardId);
        if (card == null || mem == null) {
          skipped++;
          results.add({'cardId': cardId, 'ok': false, 'error': '卡不存在'});
          continue;
        }
        if (card.status != CardStatus.active) {
          skipped++;
          results.add({
            'cardId': cardId,
            'ok': false,
            'error': '卡状态 ${card.status.name} 非 active，评分忽略',
          });
          continue;
        }
        final rawRating = item['rating'];
        final ratingMatches = ReviewRating.values.where(
          (e) => e.name == rawRating,
        );
        if (ratingMatches.isEmpty) {
          skipped++;
          results.add({
            'cardId': cardId,
            'ok': false,
            'error': '非法评分 $rawRating',
          });
          continue;
        }
        final rating = ratingMatches.first;
        final rawReviewedAt = item['reviewedAt'];
        final reviewedAt = rawReviewedAt is String
            ? (DateTime.tryParse(rawReviewedAt) ?? DateTime.now())
            : DateTime.now();
        final rawLatency = item['latencyMs'];
        final int? latencyMs = rawLatency is num ? rawLatency.toInt() : null;
        final offlineQueued = item['offlineQueued'] == true;

        final result = _scheduler.schedule(mem, rating, now: reviewedAt);
        db.applySchedule(cardId, result);
        db.insertReviewLog(
          cardId: cardId,
          subjectId: card.subjectId,
          rating: rating,
          reviewedAt: reviewedAt,
          latencyMs: latencyMs,
          offlineQueued: offlineQueued,
          stateBefore: mem.state,
          stateAfter: result.state,
          stabilityAfter: result.stability,
          intervalDays: result.intervalDays,
        );
        applied++;
        results.add({
          'cardId': cardId,
          'ok': true,
          'state': result.state.name,
          'dueAt': result.dueAt.toIso8601String(),
          'intervalDays': result.intervalDays,
        });
      }
      if (applied > 0) db.bumpDataVersion();
      return {
        'ok': true,
        'applied': applied,
        'skipped': skipped,
        'results': results,
      };
    }

    // /inbox/keywords（校验链：缺字段/未知科目 → errors 细目，对照 routes/inbox.dart）
    if (path == '/inbox/keywords') {
      final items = body is List ? body : [m];
      if (items.isEmpty) throw ApiException(400, '空关键词列表');
      var inserted = 0;
      final errors = <String>[];
      for (var i = 0; i < items.length; i++) {
        final item = Map<String, dynamic>.from(items[i] as Map);
        final subjectId = item['subjectId'] as String?;
        final keyword = item['keyword'] as String?;
        if (subjectId == null || subjectId.isEmpty) {
          errors.add('#$i 缺少 subjectId');
          continue;
        }
        if (keyword == null || keyword.trim().isEmpty) {
          errors.add('#$i 缺少 keyword');
          continue;
        }
        if (!db.subjectExists(subjectId)) {
          errors.add('#$i 未知科目 $subjectId');
          continue;
        }
        db.insertKeyword(
          subjectId: subjectId,
          keyword: keyword.trim(),
          source: item['source'] as String? ?? 'app',
          note: item['note'] as String? ?? '',
        );
        inserted++;
      }
      if (inserted > 0) db.bumpDataVersion();
      return {
        'ok': true,
        'inserted': inserted,
        if (errors.isNotEmpty) 'errors': errors,
      };
    }

    // /inbox/consume（拆卡导入成功后回调；防重复拆卡）
    if (path == '/inbox/consume') {
      final ids =
          ((m['ids'] as List<dynamic>?)
              ?.map((e) => e is int ? e : int.tryParse(e.toString()) ?? -1)
              .where((e) => e > 0)
              .toList()) ??
          const <int>[];
      if (ids.isEmpty) throw ApiException(400, '缺少 ids 数组');
      final consumed = db.consumeKeywords(ids);
      if (consumed > 0) db.bumpDataVersion();
      return {'ok': true, 'consumed': consumed};
    }

    // /subjects（新建：name 必填；id 可选 [a-z0-9]{2,16}；重码/重名 409）
    if (path == '/subjects') {
      final name = _str(m['name']).trim();
      if (name.isEmpty) throw ApiException(400, '缺少科目名称（name）');
      var id = _str(m['id']).trim();
      if (id.isEmpty) {
        id = _generateSubjectId(db);
      } else if (!_subjectIdPattern.hasMatch(id)) {
        throw ApiException(400, '科目短码 $id 非法（仅小写字母+数字，2-16 位）');
      }
      if (db.subjectExists(id)) throw ApiException(409, '科目短码 $id 已存在');
      if (db.subjectNameExists(name)) throw ApiException(409, '科目名称「$name」已存在');
      db.insertSubject(id: id, name: name);
      db.bumpDataVersion();
      return {'ok': true, 'id': id, 'name': name};
    }

    // /settings/ai/<svc>/test（真外呼：llm GET /models；embedding POST
    // /embeddings；reranker POST <完整端点>，外呼可注入 mock）
final aiTest = RegExp(
      r'^/settings/ai/(llm_backup|llm|embedding|reranker)/test$',
    ).firstMatch(path);
    if (aiTest != null) {
      return _testAiService(aiTest.group(1)!, m);
    }

    // /pipeline/trigger（标志 + pipelineKick 后台消费；契约见 _triggerPipeline）
    if (path == '/pipeline/trigger') {
      return _triggerPipeline();
    }

    // /pipeline/weekly（手动真题周扫 kickoff；weekly-only 单轮后台执行）
    if (path == '/pipeline/weekly') {
      return _triggerWeeklyScan();
    }

    // /corpus/build（App 内建库触发；单飞守卫返回进行中状态而非报错）
    if (path == '/corpus/build') {
      return _triggerCorpusBuild(db, m);
    }

    throw ApiException(404, '本地模式不支持: $path');
  }

  // ---------------- PUT ----------------

  Future<Map<String, dynamic>> put(String path, Object? body) async {
    final db = await _routeDb;
    _ensureDataAvailable();
    path = _normalize(path);
    final m = body is Map
        ? Map<String, dynamic>.from(body)
        : const <String, dynamic>{};

    // /settings/dup（#11 查重阈值写入：body {threshold} ∈ [0.5, 0.999]；
    // 生效于下一轮流水线查重趟次）
    if (path == '/settings/dup') {
      final t = (m['threshold'] as num?)?.toDouble();
      if (t == null || t < 0.5 || t > 0.999) {
        throw ApiException(400, 'threshold 须在 0.5 ~ 0.999 之间');
      }
      db.settingSet(kDupThresholdSettingKey, t.toStringAsFixed(3));
      db.bumpDataVersion();
      return {'ok': true, 'threshold': t};
    }

    // /settings/ai/<svc>（baseUrl 必须 https://、model 非空；apiKey 空=保持；
    // 键名 <svc>.baseUrl / <svc>.model（settings 表），<svc>.apiKey 只留空
    // 键位——key 本体存系统安全存储 AiKeyVault，svc ∈ llm|embedding|reranker）
final aiPut = RegExp(
      r'^/settings/ai/(llm_backup|llm|embedding|reranker)$',
    ).firstMatch(path);
    if (aiPut != null) {
      final svc = aiPut.group(1)!;
      final baseUrl = _str(m['baseUrl']).trim();
      final model = _str(m['model']).trim();
      final apiKey = _str(m['apiKey']); // 空/缺省 = 保持原 key
      if (!baseUrl.startsWith('https://')) {
        throw ApiException(400, 'baseUrl 必须以 https:// 开头');
      }
      if (model.isEmpty) throw ApiException(400, 'model 不能为空');
      // 安全修复 C：key 存系统安全存储（vault）+ 内存缓存；settings 表该键
      // 只保留键位、值恒空串（兼容 data_manager 导出剥离与旧版导入）。
      await initAiKeys();
      _ensureDataAvailable();
      final oldKey = aiKeyOf(svc);
      final effectiveKey = apiKey.isEmpty ? oldKey : apiKey;
      db.settingSet('$svc.baseUrl', baseUrl);
      db.settingSet('$svc.model', model);
      if (apiKey.isNotEmpty) {
        _aiKeys[svc] = apiKey; // 同步更新缓存（回显/test 兜底立即可见）
        db.settingSet('$svc.apiKey', ''); // 键位保留、值清空（key 在 vault）
        // 异步落盘；失败不回滚缓存（Keystore 写实践中不失败；失败时下次
        // PUT 重写即可——绝不把明文 key 留回 settings 表）。
        unawaited(
          AiKeyVault.instance.save(svc, apiKey).catchError((Object _) {}),
        );
      }
      return {
        'ok': true,
        'keySet': effectiveKey.isNotEmpty,
        'keyMasked': effectiveKey.isEmpty ? '' : maskApiKey(effectiveKey),
      };
    }

    // /subjects/<id>（改名；重名 409 / 不存在 404）
    final subjectPut = RegExp(r'^/subjects/([^/]+)$').firstMatch(path);
    if (subjectPut != null) {
      final id = subjectPut.group(1)!;
      if (!db.subjectExists(id)) throw ApiException(404, '科目 $id 不存在');
      final name = _str(m['name']).trim();
      if (name.isEmpty) throw ApiException(400, '缺少科目名称（name）');
      if (db.subjectNameExists(name, excludeId: id)) {
        throw ApiException(409, '科目名称「$name」已存在');
      }
      db.renameSubject(id, name);
      db.bumpDataVersion();
      return {'ok': true, 'id': id, 'name': name};
    }

    // /progress/<subject>/chapters（⑨ 章节管理写：body
    // {learned_through?: int, skipped?: [int]}——缺省字段不动；读-改-写整个
    // progress.json，与流水线 study-log 推进共存不丢字段）
    final chapterPut = RegExp(r'^/progress/([^/]+)/chapters$').firstMatch(path);
    if (chapterPut != null) {
      final id = chapterPut.group(1)!;
      final lt = m['learned_through'];
      final sk = m['skipped'];
      if (lt != null && lt is! int) {
        throw ApiException(400, 'learned_through 须为整数章序');
      }
      if (lt != null && lt < 0) {
        throw ApiException(400, '章序不能为负：$lt');
      }
      if (sk != null && sk is! List) {
        throw ApiException(400, 'skipped 须为章序（int）列表');
      }
      final skipped = sk == null
          ? null
          : [for (final v in sk) if (v is int && v > 0) v];
      final progressPath = '$_corpusDir/progress.json';
      // 读-改-写整个 json（非字段级覆盖）：后写不静默丢流水线刚推进的
      // learned_through，亦不丢本端刚写的 skipped
      final data = loadProgress(progressPath);
      if (progressEntryOf(data, id) == null) {
        throw ApiException(404, '科目 $id 不在进度库——章节管理仅面向已有科目');
      }
      final r = setSubjectChapters(
        data,
        id,
        learnedThrough: lt,
        skipped: skipped,
        source: 'manual',
      );
      if (!r.ok) {
        throw ApiException(400, r.note);
      }
      if (r.mutated) {
        saveProgress(progressPath, data);
        // #2 埋点：章节进度变更（手动章节管理）
        AppLog.instance.log(AppLogLevel.info, 'progress',
            '章节管理变更：科目 $id learned_through=$lt skipped=${skipped?.length ?? 0}处（${r.note}）');
      }
      return {..._subjectChaptersView(id), 'ok': true, 'note': r.note};
    }

    // /pipeline/weekly（自动周扫节流时间戳自由调整；body
    // {lastRunAt: ISO | null}——null/空 = 清除，下次 catchup 立即到期）
    if (path == '/pipeline/weekly') {
      return _setWeeklyScanSchedule(db, m);
    }

    throw ApiException(404, '本地模式不支持: $path');
  }

  // ---------------- upload（课件字节流） ----------------

  /// 原始字节流上传（契约 `POST /api/v1/corpus/upload`；对照 routes/corpus.dart：
  /// 科目存在 → 文件名清洗 → 后缀白名单 → 魔数头 → 落盘 incoming/）。
  /// 端上 bytes 已在内存，无需服务器侧流式处理；大小上限同 200MB。
  Future<Map<String, dynamic>> upload(String path, List<int> bytes) async {
    final db = await _routeDb;
    _ensureDataAvailable();
    path = _normalize(path);

    if (path.startsWith('/corpus/upload')) {
      final q = _parseQuery(path);
      final subject = q['subject'] ?? '';
      final filename = q['filename'] ?? '';
      // 语料类型标注契约：query `source=textbook`（上传弹层「类型：教材」
      // 经 ApiClient.uploadCourseware 携带）→ 落教材树
      // `incoming/<短码>-textbook/`——首层目录名带 -textbook 尾缀 → 建库侧
      // splitSubjectSource 判 source=textbook → extract_all 写 toc sidecar →
      // #16 罗盘随建库自动生成。`source=exam`（节点③真题专题上传）→ 落真题
      // 树 `incoming/<短码>-exam/`（建库 source_type='exam'，仅作周扫真题
      // 池）——**不走 subjectExists 守卫**：真题短码不进 subjects 表（不进
      // 科目 Tab），守卫改为 kExamTopics 12 专题短码表校验。`source=
      // outline`（节点④大纲上传）→ 落大纲树 `incoming/dagang-outline/`
      // （固定短码 dagang；建库路由到 outline 解析器 → outline_entries，
      // 正文绝不进常规语料块/出卡证据；仅收 .docx）。缺省/其他值 = 课件
      // 树 `incoming/<短码>/`（既有行为与请求字节零变化）。同短码
      // 「课件树+教材树+真题树+大纲树」多棵并存合法：建库照常扫树，
      // manifest 按相对路径（首层目录/文件名）分键，增量
      // changed/unchanged/removed 互不干扰（同名文件各属各树、各抽各的）。
      final isTextbook = q['source'] == 'textbook';
      final isExam = q['source'] == 'exam';
      final isOutline = q['source'] == 'outline';
      if (subject.isEmpty) throw ApiException(400, '缺少 subject 参数');
      if (filename.isEmpty) throw ApiException(400, '缺少 filename 参数');
      if (!_subjectCodePattern.hasMatch(subject)) {
        throw ApiException(400, '科目短码 $subject 非法');
      }
      if (isExam) {
        // 真题专题守卫：短码必须在 12 考站专题表内（B1 拍板清单），
        // 绝不自动建 subject——真题树与科目 Tab 完全解耦。
        if (examTopicByCode(subject) == null) {
          throw ApiException(400, '未知真题专题 $subject（仅支持 12 个考站专题）');
        }
      } else if (isOutline) {
        // 大纲守卫（节点④）：固定短码 dagang——大纲树与科目选择完全
        // 解耦（上传弹层选「大纲」即跳过科目/专题选择）。
        if (subject != kOutlineUploadCode) {
          throw ApiException(400, '大纲上传短码固定为 dagang（收到 $subject）');
        }
      } else if (!db.subjectExists(subject)) {
        throw ApiException(400, '科目 $subject 不存在，请先新建该科目后再上传');
      }
      final clean = _sanitizeFilename(filename);
      if (clean == null) throw ApiException(400, '文件名 $filename 非法（不支持路径穿越）');
      final ext = _extOf(clean);
      if (ext == null) throw ApiException(400, '仅支持 .pptx / .docx / .pdf 课件');
      if (isOutline && ext != '.docx') {
        throw ApiException(400, '大纲仅支持 .docx（考试大纲 Word 文档）');
      }
      final magic = _allowedMagic[ext]!;
      if (bytes.length < magic.length || !_startsWithMagic(bytes, magic)) {
        throw ApiException(400, '文件头与后缀 $ext 不符（魔数校验失败）');
      }
      if (bytes.length > _maxUploadBytes) {
        throw ApiException(
          413,
          '文件超过 ${_maxUploadBytes ~/ (1024 * 1024)}MB 上限',
        );
      }
      final String destDir;
      if (isTextbook) {
        destDir = '$_corpusDir/incoming/$subject-textbook';
      } else if (isExam) {
        destDir = '$_corpusDir/incoming/$subject-exam';
      } else if (isOutline) {
        destDir = '$_corpusDir/incoming/$kOutlineUploadCode-outline';
      } else {
        destDir = '$_corpusDir/incoming/$subject';
      }
      final dest = Directory(destDir)..createSync(recursive: true);
      File('${dest.path}/$clean').writeAsBytesSync(bytes, flush: true);
      return {
        'ok': true,
        'received': bytes.length,
        'pending': _countPendingIncoming(),
      };
    }

    throw ApiException(404, '本地模式不支持: $path');
  }

  // ---------------- App 内建库（consume 上游 isolate job） ----------------
  // 公共契约见 corpus_build_job.dart（P1-3 交付）：runCorpusBuild 单飞键
  // corpusBuildJobId、进度事件协议（start/extract/ingest/done）、结果与
  // notes。本段做三件事：①路由面（GET/POST /corpus/build）；②进度二次
  // 转发（handle.progress → broadcast 状态流——上游指引「拿到 handle 立即
  // listen，或经自己的 StreamController 二次转发」）；③成功后补写
  // meta.last_build（对照 server 管线契约；Dart ingest 写的是 updated_at）。

  /// 建库状态广播流（broadcast）：触发 / 每条进度 / 收尾各发一帧视图 Map
  /// （形状 = GET /corpus/build 响应的状态子集，无 pending 键）。UI 直接
  /// 订阅渲染（设置页建库面板）；帧内容绝不携带 key。
  final StreamController<Map<String, Object?>> _corpusBuildStateCtrl =
      StreamController<Map<String, Object?>>.broadcast();

  /// 建库 job 装配缝（生产 = 真实 [runCorpusBuild]；widget 测试注入假实现
  /// ——testWidgets 假异步纪律：用例体内 await 真实 isolate 必死锁，只能以
  /// 假 Stream / Completer 方式消费，见 corpus_build_panel_test）。
  static ({
    Stream<IsolateProgressEvent> progress,
    Future<CorpusBuildResult> done,
  })
  Function(CorpusBuildRequest request)?
  corpusBuildJobOverride;

  bool _corpusBuildActive = false; // 触发 → 收尾的运行窗口（真实/假链同语义）
  IsolateProgressEvent? _lastBuildEvent;
  CorpusBuildResult? _lastBuildResult;
  String? _lastBuildError;
  bool _lastBuildCancelled = false;
  String _lastBuildMode = ''; // 本次（或最近一次）运行的嵌入模式名
  DateTime? _buildStartedAt;
  DateTime? _buildFinishedAt;

  /// 建库状态流（UI 订阅面；帧 = [_corpusBuildStateView]）。
  Stream<Map<String, Object?>> get corpusBuildState =>
      _corpusBuildStateCtrl.stream;

  /// 建库是否在运行（内部窗口 ∪ 上游单飞位——CLI 探针直连占用也可见）。
  bool get _corpusBuildRunning =>
      _corpusBuildActive || IsolateRunner.instance.isRunning(corpusBuildJobId);

  /// 完整备份/恢复须等待建库（包括 worker 返回后的主库/进度收尾）。
  bool get corpusBuildRunning => _corpusBuildRunning;

  // ---- 嵌入模式自动选路（用户拍板：UI 不做任何 API key 引导） ----

  /// 嵌入模式自动选路规则（语义同探针 --mode；探针读 .env，App 读本机
  /// 配置——key 在系统安全存储 AiKeyVault（经 [aiKeyOf] 内存缓存），
  /// model/baseUrl 在 settings 表）：
  ///   1. embedding key 已配置（非空）→ **online**：真实嵌入
  ///      （有计费）；model/baseUrl 取 settings 的 `embedding.model` /
  ///      `embedding.baseUrl`（空回退 worker 内默认 kEmbedModel /
  ///      kEmbedApiUrl）。settings 存基址（…/v1，与 /settings/ai test 的
  ///      '$baseUrl/embeddings' 契约一致）→ 此处补 /embeddings 尾成完整端点。
  ///   2. 未配置 key → **offline**：不写向量、检索词面单路；之后配置 key
  ///      再建库即在线补嵌收敛（chunk_state 断点续传，无需 forceFull）。
  ///   3. **drill**（确定性伪向量，零网络零计费）仅测试 / 演练用——生产
  ///      自动选路永不选它；POST /corpus/build 可经 body {'mode':'drill'}
  ///      显式指定（探针 --mode drill 同义）。
  /// key 纪律：key 值只进 [CorpusBuildRequest.apiKey]，绝不进日志 / 进度 /
  /// 结果 / 异常文本（上游协议已守卫）。
  (CorpusEmbedMode, String? apiKey, String? model, String? baseUrl)
  _selectBuildMode(Db db) {
    final key = aiKeyOf('embedding');
    if (key.isEmpty) return (CorpusEmbedMode.offline, null, null, null);
    final model = db.settingGet('embedding.model') ?? '';
    var base = db.settingGet('embedding.baseUrl') ?? '';
    if (base.isNotEmpty && !base.endsWith('/embeddings')) {
      base = '$base/embeddings';
    }
    return (
      CorpusEmbedMode.online,
      key,
      model.isEmpty ? null : model,
      base.isEmpty ? null : base,
    );
  }

  // ---- 状态视图 ----

  /// GET /corpus/build：状态帧 + 模式选路 + incoming 待处理清单。
  Map<String, dynamic> _corpusBuildView(Db db) {
    final pending = _pendingIncomingFiles();
    final preview = _selectBuildMode(db).$1.name;
    return {
      ..._corpusBuildStateView(),
      // mode = 本次/最近一次运行的实际模式；无历史 = 下次触发的自动选路预览
      'mode': _lastBuildMode.isEmpty ? preview : _lastBuildMode,
      'modePreview': preview,
      'pendingFiles': pending.length,
      'pending': pending,
      if (_foreignCorpusChunks() > 0) 'replacesForeign': true,
    };
  }

  /// 建库状态帧（流事件与 GET 共用形状；绝不携带 key）。
  Map<String, Object?> _corpusBuildStateView() => {
    'running': _corpusBuildRunning,
    'mode': _lastBuildMode,
    if (_lastBuildEvent != null)
      'progress': {
        'stage': _lastBuildEvent!.stage,
        'message': _lastBuildEvent!.message,
        'counts': _lastBuildEvent!.counts,
      },
    if (_lastBuildResult != null)
      'result': _corpusBuildResultView(_lastBuildResult!),
    if (_lastBuildError != null) 'error': _lastBuildError,
    'cancelled': _lastBuildCancelled,
    if (_buildStartedAt != null)
      'startedAt': _buildStartedAt!.toIso8601String(),
    if (_buildFinishedAt != null)
      'finishedAt': _buildFinishedAt!.toIso8601String(),
  };

  /// 成功结果视图（CorpusBuildResult → JSON 同构 Map；UI 完成摘要消费）。
  static Map<String, Object?> _corpusBuildResultView(CorpusBuildResult r) => {
    'chunks': r.chunks,
    'embedded': r.embedded,
    'elapsedS': r.elapsedS,
    'extract': r.extract,
    'ingest': r.ingest, // null = 抽取 0 chunks 未入库
    'notes': r.notes,
  };

  // ---- 触发与收尾 ----

  /// POST /corpus/build：触发建库（body 可带 mode 显式指定，缺省自动选路）。
  /// 单飞守卫：运行中重复触发 → 返回进行中状态而非报错（job 照旧跑）。
  Map<String, dynamic> _triggerCorpusBuild(Db db, Map<String, dynamic> m) {
    if (_corpusBuildRunning) {
      return {
        'ok': true,
        'triggered': false,
        'running': true,
        'note': '建库已在进行中',
        ..._corpusBuildStateView(),
      };
    }
final explicit = _str(m['mode']).trim().toLowerCase();
    final resetVectors = m['resetVectors'] == true;
    final backfillVectors = m['backfillVectors'] == true;
    final (autoMode, autoKey, autoModel, autoBase) = _selectBuildMode(db);
    final CorpusEmbedMode mode;
    switch (explicit) {
      case '':
        mode = autoMode;
      case 'offline':
        mode = CorpusEmbedMode.offline;
      case 'drill':
        mode = CorpusEmbedMode.drill;
      case 'online':
        mode = CorpusEmbedMode.online;
      default:
        throw ApiException(400, '未知 mode：$explicit（可用 offline|drill|online）');
    }
    if (mode == CorpusEmbedMode.online && (autoKey ?? '').isEmpty) {
      // 提前拦截（worker 也会拦，但那要空跑完抽取才报错——App 语境提示更清楚）
      throw ApiException(400, '在线嵌入需要向量模型 API Key（设置 → AI 服务配置）');
    }
    // 输入树 = incoming/（上传链落盘布局：第一层子目录 = 科目短码）。文件
    // **永不清出 incoming**——树完整性是 pruneAbsent 的前提（文件消失 →
    // jsonl 删行 → 库剪 deck）；「待处理」= manifest 未覆盖或 size/mtime 已
    // 变的文件，构建成功后自然清零（见 [_pendingIncomingFiles]）。
    Directory('$_corpusDir/incoming').createSync(recursive: true);
    final req = CorpusBuildRequest(
      inputPath: '$_corpusDir/incoming',
      corpusDbPath: '$_corpusDir/corpus.db',
      mode: mode,
      // key 只在 online 进参数；offline 不写向量、drill 忽略——都不携带
      apiKey: mode == CorpusEmbedMode.online ? autoKey : null,
      model: autoModel, // offline/online 落 meta.embedding_model；drill 强制本地款
      baseUrl: mode == CorpusEmbedMode.online ? autoBase : null,
      // 2026-09-11「重建全部向量」：清空向量后全量重嵌（incoming 无源文件
      // 时走库内自嵌——从 chunks 表读全部行重建）
      resetVectors: resetVectors,
      // 2026-09-12「补齐缺失向量」：保留现有向量，断点检查只补缺失部分
      backfillVectors: backfillVectors,
    );
    _corpusBuildActive = true;
    _lastBuildMode = mode.name;
    _lastBuildEvent = null;
    _lastBuildResult = null;
    _lastBuildError = null;
    _lastBuildCancelled = false;
    _buildStartedAt = DateTime.now();
    _buildFinishedAt = null;
    unawaited(_runCorpusBuildJob(req));
    _emitCorpusBuildState();
    return {
      'ok': true,
      'triggered': true,
      'mode': mode.name,
'note': backfillVectors
          ? '已在后台开始补齐缺失向量（保留现有向量，只嵌缺失部分，消耗少量 API 额度）'
          : resetVectors
          ? '已在后台开始重建全部向量（清空后全量重嵌，消耗少量 API 额度）'
          : mode == CorpusEmbedMode.online
              ? '已在后台开始建库（在线嵌入，消耗少量 API 额度）'
              : '已在后台开始建库（后台运行，期间可正常使用 App）',
    };
  }

  /// 建库 job 接线：拿到 handle 立即订阅进度（上游首订阅前缓冲 ≤512 条
  /// 补发）→ done 收尾 → 状态帧广播。
  Future<void> _runCorpusBuildJob(CorpusBuildRequest req) async {
    Stream<IsolateProgressEvent> progress;
    Future<CorpusBuildResult> done;
    final override = corpusBuildJobOverride;
    if (override != null) {
      final w = override(req);
      progress = w.progress;
      done = w.done;
    } else {
      try {
        // runCorpusBuild 同步段已占单飞坑（IsolateRunner.start 先占后 spawn）
        final handle = await runCorpusBuild(req);
        progress = handle.progress;
        done = handle.done;
      } catch (e) {
        _lastBuildError = '$e';
        _finishCorpusBuildJob();
        return;
      }
    }
final sub = progress.listen((e) {
      _lastBuildEvent = e;
      _emitCorpusBuildState();
      // worker 日志事件（stage='log' 经 wire 回流）→ AppLog（worker 内
      // AppLog 无 dataDir 不落盘，必须经事件回流；见 isolate_runner.dart）
      if (e.stage == 'log') {
        AppLog.instance.log(
          _buildLogLevel(e.level) ?? AppLogLevel.debug,
          (e.tag == null || e.tag!.isEmpty) ? 'corpus-build' : e.tag!,
          e.message,
        );
      }
    });
    try {
      _lastBuildResult = await done;
      _lastBuildError = null;
      _stampLastBuild();
      // #16 罗盘初始化（双保险 a）：建库成功收尾把 toc sidecar 转成罗盘条目
      // ——「语料入库后自动生成」（幂等：已有条目走刷新语义保留进度）。
      _initCompassFromToc();
    } on IsolateCancelledException {
      _lastBuildCancelled = true;
      AppLog.instance.log(
          AppLogLevel.warn, 'corpus-build', '建库已取消（收件箱保留）；上次结果键归零');
    } on IsolateJobException catch (e) {
      _lastBuildError = e.message; // 不含 key（上游协议守卫）；堆栈不进 UI 帧
      // 关键失败如实落 AppLog（嵌入 API 连续失败中止等 worker 错误文本）
      AppLog.instance.log(
          AppLogLevel.error, 'corpus-build', '建库失败：${e.message}');
    } catch (e) {
      _lastBuildError = '$e';
      AppLog.instance.log(
          AppLogLevel.error, 'corpus-build', '建库失败：$e');
    } finally {
      unawaited(sub.cancel());
      _finishCorpusBuildJob();
    }
  }

  /// wire 级别字符串 → AppLog 级别（未知值回退 debug，防御性；与
  /// pipeline_runner 侧 _logLevelByName 同款映射，保持日志级口径一致）。
  static AppLogLevel? _buildLogLevel(String? level) => switch (level) {
        'debug' => AppLogLevel.debug,
        'info' => AppLogLevel.info,
        'warn' => AppLogLevel.warn,
        'error' => AppLogLevel.error,
        _ => null,
      };

  /// #2 埋点用：长文本截断（题干等防长文刷屏；换行归一）。
  static String _head(String? text, int n) {
    final t = (text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > n ? '${t.substring(0, n)}…' : t;
  }

  void _finishCorpusBuildJob() {
    _corpusBuildActive = false;
    _buildFinishedAt = DateTime.now();
    _emitCorpusBuildState();
  }

  void _emitCorpusBuildState() {
    if (!_corpusBuildStateCtrl.isClosed) {
      _corpusBuildStateCtrl.add(_corpusBuildStateView());
    }
  }

  /// 建库成功后向 corpus.db meta 补写 last_build（对照 server 管线契约：
  /// routes/corpus.dart「构建于 …」的展示键；Dart ingest 只写 updated_at /
  /// last_ingest）。失败 / 取消 / 0 chunks（无库文件）不写；异常静默——
  /// 只是展示元信息，不阻断收尾。
  void _stampLastBuild() {
    try {
      final dbFile = File('$_corpusDir/corpus.db');
      if (!dbFile.existsSync()) return;
      final db = sqlite3.open(dbFile.path);
      try {
        db.execute('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)', [
          'last_build',
          DateTime.now().toIso8601String(),
        ]);
      } finally {
        db.dispose();
      }
    } catch (_) {}
  }

  /// #16 罗盘初始化（建库收尾，幂等）：建库成功后把 toc sidecar
  /// （`<corpusDir>/toc/<短码>.json`——建库侧仅教材源产出）逐科目转成
  /// progress.json 罗盘条目——兑现进度页「语料入库后自动生成」承诺。
  /// 语义对齐 Python progress_db --init（cmd_init）：条目不存在则建全 0；
  /// 已存在则刷新 textbook/chapters、**保留 learned_through 与 history**
  /// （绝不回拨进度）。单科目 sidecar 缺失/损坏 → 该科目跳过不株连
  /// （宁缺毋滥）；整体异常静默——罗盘只是展示元数据，绝不阻断建库收尾
  /// （同 [_stampLastBuild] 防御风格；漏网由流水线懒初始化双保险 b 兜底）。
  ///
  /// 注意（口径）：App 上传链落盘 `incoming/<短码>/`（首层目录名=短码 →
  /// source=ppt，splitSubjectSource 规则）**不产 sidecar**；sidecar 仅
  /// `<短码>-textbook` 首层目录（教材树约定）产出——上传弹层「类型：教材」
  /// 已补全该入口（upload 契约注释见上），ppt 源语料对本钩子自然空转。
  void _initCompassFromToc() {
    try {
      final tocDir = '$_corpusDir/toc';
      final subjects = tocSidecarSubjects(tocDir);
      if (subjects == null || subjects.isEmpty) {
        return; // 无 sidecar：静默跳过（宁缺毋滥）
      }
      final progressPath = '$_corpusDir/progress.json';
      final data = loadProgress(progressPath);
      var mutated = false;
      for (final sid in subjects) {
        final r = initFromTocSidecar(data, tocDir, sid);
        if (r.ok && r.mutated) {
          mutated = true;
        }
        // ok=false（缺失/损坏）→ 该科目跳过；note 不进 UI（罗盘收尾静默）
      }
      if (mutated) {
        saveProgress(progressPath, data);
      }
    } catch (_) {
      // 初始化失败不影响建库结果（progress.json 下轮流水线懒初始化再补）
    }
  }

  /// 建库运行态同步清零（resetForTest 首个 await 之前调用——见其注释）。
  void _resetCorpusBuildState() {
    _corpusBuildActive = false;
    _lastBuildEvent = null;
    _lastBuildResult = null;
    _lastBuildError = null;
    _lastBuildCancelled = false;
    _lastBuildMode = '';
    _buildStartedAt = null;
    _buildFinishedAt = null;
  }

  // ---- incoming 待处理清单（manifest 比对） ----

  /// incoming 待处理文件清单（过滤口径 = 建库树扫描：.pptx/.pdf/.docx，
  /// 第一层子目录 = 科目短码；相对路径 posix 形态与建库 manifest 键一致）。
  /// 待处理 = manifest 未覆盖 或 size/mtime 与 manifest 条目不符（下一轮
  /// 会重抽/重读的文件）；构建成功后 manifest 覆盖全部 → 清零。文件本身
  /// 永不清理（见 [_triggerCorpusBuild] 注释）。
  List<Map<String, Object?>> _pendingIncomingFiles() {
    final root = Directory('$_corpusDir/incoming');
    if (!root.existsSync()) return const [];
    final files = <File>[];
    for (final e in root.listSync(recursive: true)) {
      if (e is! File) continue;
      final low = _baseNameOf(e.path).toLowerCase();
      if (!low.endsWith('.pptx') &&
          !low.endsWith('.pdf') &&
          !low.endsWith('.docx')) {
        continue;
      }
      files.add(e);
    }
    if (files.isEmpty) return const [];
    final manifestFiles =
        (loadManifest('$_corpusDir/extract_manifest.json')['files'] as Map)
            .cast<String, Object?>();
    final out = <Map<String, Object?>>[];
    for (final f in files) {
      final rel = _relPosixOf(f.path, root.path);
      final prev = manifestFiles[rel];
      var built = false;
      if (prev is Map) {
        try {
          final ids = prev['chunk_ids'];
          built =
              prev['size'] == f.lengthSync() &&
              prev['mtime'] ==
                  f.lastModifiedSync().millisecondsSinceEpoch ~/ 1000 &&
              ids is List &&
              ids.isNotEmpty;
        } catch (_) {
          built = false; // 文件正被删/占用——按待处理展示，下轮自然消失
        }
      }
      if (!built) {
        out.add({
          'subject': _firstDirOfRel(rel),
          'filename': _baseNameOf(f.path),
          'sizeBytes': f.lengthSync(),
        });
      }
    }
    // 与建库树扫描同序（lowercase 路径排序）——UI 清单展示稳定
    out.sort(
      (a, b) => ('${a['subject']}/${a['filename']}').toLowerCase().compareTo(
        ('${b['subject']}/${b['filename']}').toLowerCase(),
      ),
    );
    return out;
  }

  /// 迁移 / 外建语料检测（警示用）：corpus.db 有语料但本地抽取 manifest 为
  /// 空 → 现有库不是由本机 incoming 树构建；此时建库将以本机课件为准，树外
  /// deck 会被剪除（pruneAbsent 契约）。返回其 chunks 数；0 = 无警示。
  int _foreignCorpusChunks() {
    final dbFile = File('$_corpusDir/corpus.db');
    if (!dbFile.existsSync()) return 0;
    final manifestFiles = loadManifest(
      '$_corpusDir/extract_manifest.json',
    )['files'];
    if (manifestFiles is Map && manifestFiles.isNotEmpty) return 0;
    dynamic cdb;
    try {
      cdb = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
      return (cdb.select('SELECT COUNT(*) AS n FROM chunks').first['n']
              as int?) ??
          0;
    } catch (_) {
      return 0;
    } finally {
      (cdb as dynamic)?.dispose();
    }
  }

  // ---------------- settings/ai 视图与外呼 ----------------

  /// 单套 AI 服务配置（掩码态；key 存系统安全存储 AiKeyVault——Android
  /// Keystore 加密，encrypted=true；明文 key 永不出后端）
  Map<String, dynamic> _serviceView(Db db, String svc) {
    final key = aiKeyOf(svc);
    return {
      'baseUrl': db.settingGet('$svc.baseUrl') ?? '',
      'model': db.settingGet('$svc.model') ?? '',
      'keySet': key.isNotEmpty,
      'keyMasked': key.isEmpty ? '' : maskApiKey(key),
      'encrypted': true,
    };
  }

  /// 测试连接（对照 routes/settings.dart：llm GET {baseUrl}/models（Bearer），
  /// HTTP 200 即 ok；embedding POST {baseUrl}/embeddings，200 且含向量数组
  /// 才算 ok；reranker POST `<baseUrl>`（完整端点，SiliconFlow /rerank 契约），
  /// 200 且 results 非空才算 ok。异常不抛：统一 ok=false + message。）
  Future<Map<String, dynamic>> _testAiService(
    String svc,
    Map<String, dynamic> m,
  ) async {
    final baseUrl = _str(m['baseUrl']).trim();
    final model = _str(m['model']).trim();
    // 空 key = 用已存 key（系统安全存储 AiKeyVault 的内存缓存，与 PUT/
    // 流水线同源）；非空 = 表单新 key 直测
    final apiKey = _str(m['apiKey']).isEmpty
        ? aiKeyOf(svc)
        : _str(m['apiKey']);
    if (!baseUrl.startsWith('https://')) {
      throw ApiException(400, 'baseUrl 必须以 https:// 开头');
    }
    final t0 = DateTime.now();
    try {
// reranker：经 [rerankProbeOverride]（测试注入）或 [_rerankProbeReal]
      //（真 HttpClient）发最小探测——不与 llm/embedding 共享 client，便于 mock
      if (svc == 'reranker') {
        // 基址→完整端点补全（对齐 embedding 的 normalize 先例，2026-09-11）：
        // settings 存基址形态（…/v1）时直接 POST …/v1 恒 404（SiliconFlow
        // 根路径无路由）——统一经 normalizeRerankEndpoint 规范成 /v1/rerank。
        final probeUrl = normalizeRerankEndpoint(baseUrl);
        final probe = rerankProbeOverride ?? _rerankProbeReal;
        final r = await probe(probeUrl, apiKey, model);
        var ok = r.status == 200;
        var message = '连接正常';
        if (ok) {
          // SiliconFlow /rerank 200 响应：{id, results:[{index,
          // relevance_score}], tokens}——results 非空才算真连通
          try {
            final decoded = jsonDecode(r.body);
            final results = decoded is Map ? decoded['results'] : null;
            if (results is! List || results.isEmpty) {
              ok = false;
              message = '上游响应异常（status ${r.status}）';
            }
          } catch (_) {
            ok = false;
            message = '上游响应异常（status ${r.status}）';
          }
        } else {
          // 失败透传上游裸 message（SiliconFlow 错误形状：{"message": "..."} /
          // 裸 JSON 字符串 / {"code":...,"message":...}）；不可解析回退状态码
          message = _upstreamMessage(r.body) ?? '上游返回 ${r.status}';
        }
        return {
          'ok': ok,
          'status': r.status,
          'latencyMs': DateTime.now().difference(t0).inMilliseconds,
          'message': message,
        };
      }
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
if (svc == 'llm' || svc == 'llm_backup') {
          final rq = await client
              .getUrl(Uri.parse('$baseUrl/models'))
              .timeout(const Duration(seconds: 10));
          if (apiKey.isNotEmpty) {
            rq.headers.set('Authorization', 'Bearer $apiKey');
          }
          final rs = await rq.close().timeout(const Duration(seconds: 10));
          await rs.drain<void>();
          final ok = rs.statusCode == 200;
          return {
            'ok': ok,
            'status': rs.statusCode,
            'latencyMs': DateTime.now().difference(t0).inMilliseconds,
            'message': ok ? '连接正常' : '上游返回 ${rs.statusCode}',
          };
        }
        // embedding（#6② 两形态兼容，2026-09-07：baseUrl 已带 /embeddings
        // 后缀则不再追加——与 _selectBuildMode / search_api 的规范化同契；
        // 设置页 embedding 卡现预填完整端点，此路由须可直测）
        final embUrl = baseUrl.endsWith('/embeddings')
            ? baseUrl
            : '$baseUrl/embeddings';
        final rq = await client
            .postUrl(Uri.parse(embUrl))
            .timeout(const Duration(seconds: 10));
        if (apiKey.isNotEmpty) {
          rq.headers.set('Authorization', 'Bearer $apiKey');
        }
        rq.headers.contentType = ContentType.json;
        rq.add(
          utf8.encode(
            jsonEncode({
              'model': model,
              'input': ['测试'],
            }),
          ),
        );
        final rs = await rq.close().timeout(const Duration(seconds: 10));
        final text = await rs.transform(utf8.decoder).join();
        var ok = rs.statusCode == 200;
        if (ok) {
          try {
            final decoded = jsonDecode(text);
            final data = decoded is Map ? decoded['data'] : null;
            ok = data is List && data.isNotEmpty;
          } catch (_) {
            ok = false;
          }
        }
        return {
          'ok': ok,
          'status': rs.statusCode,
          'latencyMs': DateTime.now().difference(t0).inMilliseconds,
          'message': ok ? '连接正常' : '上游响应异常（status ${rs.statusCode}）',
        };
      } finally {
        client.close(force: true);
      }
    } on SocketException catch (e) {
      return {'ok': false, 'status': 0, 'latencyMs': 0, 'message': '网络不可达: $e'};
    } on TimeoutException {
      return {'ok': false, 'status': 0, 'latencyMs': 0, 'message': '连接超时（10s）'};
    } on HttpException catch (e) {
      return {'ok': false, 'status': 0, 'latencyMs': 0, 'message': '连接异常: $e'};
    }
  }

  // ---------------- reranker 连接探测（Phase 4 检索引擎同契约） ----------------

  /// rerank 外呼注入点（测试专用；生产勿碰）：入参 =（完整端点 URL /
  /// Bearer key / 模型名），出参 =（上游 status / 响应体文本）。
  /// 默认走 [_rerankProbeReal]（真 HttpClient）；测试注入假实现后绝不真调
  /// 外网，用完置 null 恢复。Phase 4 检索引擎的重排调用可直接复用此契约。
  static Future<({int status, String body})> Function(
    String url,
    String apiKey,
    String model,
  )?
  rerankProbeOverride;

  /// 最小 /rerank 探测（真实外呼）：POST `<url>`（SiliconFlow /rerank 契约：
  /// {model, query, documents[2], top_n}，Bearer key），10s 连接/请求超时。
  static Future<({int status, String body})> _rerankProbeReal(
    String url,
    String apiKey,
    String model,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final rq = await client
          .postUrl(Uri.parse(url))
          .timeout(const Duration(seconds: 10));
      if (apiKey.isNotEmpty) {
        rq.headers.set('Authorization', 'Bearer $apiKey');
      }
      rq.headers.contentType = ContentType.json;
      rq.add(
        utf8.encode(
          jsonEncode({
            'model': model,
            'query': _rerankProbeQuery,
            'documents': _rerankProbeDocs,
            'top_n': 2,
          }),
        ),
      );
      final rs = await rq.close().timeout(const Duration(seconds: 10));
      final body = await rs.transform(utf8.decoder).join();
      return (status: rs.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  /// 最小探测语料：1 条 query + 2 条短 documents（真实相关性无所谓，
  /// 只要上游按契约返回 results 即证明端点/key/模型三者可用）
  static const _rerankProbeQuery = '光合作用的意义';
  static const _rerankProbeDocs = ['光合作用把光能转化为化学能储存起来', '板块构造学说是大地构造的重要理论'];

  /// 上游错误体 → 裸 message 透传：Map 取 message 字段 / 裸 JSON 字符串原样；
  /// 非 JSON 或无 message → null（调用方回退「上游返回 status 码」）。
  static String? _upstreamMessage(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final m = decoded['message'];
        if (m is String && m.trim().isNotEmpty) return m.trim();
      } else if (decoded is String && decoded.trim().isNotEmpty) {
        return decoded.trim();
      }
    } catch (_) {}
    return null;
  }

  // ---------------- progress（progress.json → 罗盘视图） ----------------

  /// 辅文章过滤集合（§7.5 拍板：progress_db.py 的 _NON_CONTENT_EXACT 精确
  /// 9 项；刻意不含「索引」）。比对在去空白归一化后进行。
  static const _nonContentExact = {
    '目录',
    '目录尾',
    '前言',
    '序',
    '序言',
    '附录',
    '附录一',
    '附录二',
    '附录三',
  };

  static final _nonContentNorm = {
    for (final t in _nonContentExact) _normTitle(t),
  };

  Map<String, dynamic> _progressView() {
    final subjects = <Map<String, dynamic>>[];
    String? updatedAt;
    final raw = _loadProgressJson();
    final map = raw == null ? null : raw['subjects'];
    if (map is Map<String, dynamic>) {
      for (final entry in map.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final learnedThrough = value['learned_through'] is int
            ? value['learned_through'] as int
            : 0;
        final chapters = value['chapters'] is List
            ? value['chapters'] as List
            : const [];
        // ⑨ 章节管理：跳过章剔出有效总量/有效已学与「下一章」
        // （无 skipped 字段的旧数据：集合为空，值与原契约逐字段一致）
        final skipped = _validSkipped(
            chapters, skippedChaptersOf(Map<String, Object?>.from(value)));
        final next = _nextChapter(chapters, learnedThrough, skipped);
        final stamp = value['updated_at'];
        if (stamp is String &&
            stamp.isNotEmpty &&
            (updatedAt == null || stamp.compareTo(updatedAt) > 0)) {
          updatedAt = stamp;
        }
        subjects.add({
          'id': entry.key,
          'textbook': value['textbook'],
          // #1 口径对齐：已学/总量均为真实正文章口径（剔辅文与跳过）
          'learned_through': _effectiveLearned(chapters, learnedThrough, skipped),
          'total': _effectiveTotal(chapters, skipped),
          'next_chapter': next,
        });
      }
    }
    return {'subjects': subjects, 'updated_at': updatedAt};
  }

  /// 下一章：编号 no > learnedThrough 的第一条正文章（跳过辅文章与「不学」
  /// 章），page = 该章 page_start；学完 → null
  static Map<String, dynamic>? _nextChapter(
    List<dynamic> chapters,
    int learnedThrough, [
    Set<int> skipped = const {},
  ]) {
    for (final ch in chapters) {
      if (ch is! Map) continue;
      final no = ch['no'];
      if (no is! int || no <= learnedThrough) continue;
      if (skipped.contains(no)) continue;
      final title = ch['title'];
      final norm = title is String ? _normTitle(title) : '';
      if (norm.isEmpty || _nonContentNorm.contains(norm)) continue;
      return {'no': no, 'title': title, 'page': ch['page_start']};
    }
    return null;
  }

  /// skipped 与章列表求交后的有效跳过集（脏数据容错：只统计真实存在于
  /// 章列表的章序；skippedChaptersOf 已过滤非 int / ≤0 元素）。
  static Set<int> _validSkipped(List<dynamic> chapters, List<int> skipped) {
    final nos = <int>{
      for (final ch in chapters)
        if (ch is Map && ch['no'] is int) ch['no'] as int,
    };
    return skipped.where(nos.contains).toSet();
  }

  /// #1（2026-09-13）有效已学口径：**真实正文章**（剔辅文/空标题）中
  /// no ≤ 指针且未跳过的**章数**——不再是「原始序号轴上的指针减跳过」
  /// （稀疏编号/辅文过滤下旧公式会大于有效章数，进度页「已学 > 有效」）。
  static int _effectiveLearned(
    List<dynamic> chapters,
    int learnedThrough,
    Set<int> skipped,
  ) {
    var n = 0;
    for (final ch in chapters) {
      if (ch is! Map) continue;
      final no = ch['no'];
      if (no is! int || no <= 0 || no > learnedThrough) continue;
      if (skipped.contains(no)) continue;
      final title = ch['title'];
      final norm = title is String ? _normTitle(title) : '';
      if (norm.isEmpty || _nonContentNorm.contains(norm)) continue;
      n++;
    }
    return n;
  }

  /// #1 有效总量口径：真实正文章中未跳过的章数（与 [_effectiveLearned]
  /// 同域——恒有 learned ≤ total；章列表含辅文旧数据时同步纠偏）。
  static int _effectiveTotal(List<dynamic> chapters, Set<int> skipped) {
    var n = 0;
    for (final ch in chapters) {
      if (ch is! Map) continue;
      if (ch['no'] is! int) continue;
      final title = ch['title'];
      final norm = title is String ? _normTitle(title) : '';
      if (norm.isEmpty || _nonContentNorm.contains(norm)) continue;
      if (skipped.contains(ch['no'] as int)) continue;
      n++;
    }
    return n;
  }

  /// 单科章节管理视图（⑨ `GET /progress/<subject>/chapters`）：全章列表 +
  /// 每章状态（learned=指针已越过、skipped=不学）+ 原始/有效统计。
  /// learned_through 返回**原始前缀指针**（PUT 直接吃同一语义）；有效统计
  /// 与主 /progress 视图同口径。科目不在进度库 → 404。
  Map<String, dynamic> _subjectChaptersView(String subjectId) {
    final raw = _loadProgressJson();
    final subs = raw == null ? null : raw['subjects'];
    final entry = subs is Map ? subs[subjectId] : null;
    if (entry is! Map) {
      throw ApiException(404, '科目 $subjectId 不在进度库——章节管理仅面向已有科目');
    }
    final learnedThrough =
        entry['learned_through'] is int ? entry['learned_through'] as int : 0;
    final chapters =
        entry['chapters'] is List ? entry['chapters'] as List : const [];
    final skipped = _validSkipped(
        chapters, skippedChaptersOf(Map<String, Object?>.from(entry)));
    final rows = <Map<String, dynamic>>[
      for (final ch in chapters)
        if (ch is Map)
          {
            'no': ch['no'],
            'title': ch['title'],
            'page_start': ch['page_start'],
            'learned':
                ch['no'] is int && ch['no'] as int > 0 && ch['no'] as int <= learnedThrough,
            'skipped': ch['no'] is int && skipped.contains(ch['no']),
          },
    ];
    return {
      'id': subjectId,
      'textbook': entry['textbook'],
      'learned_through': learnedThrough,
      'skipped': skipped.toList()..sort(),
      'total': chapters.length,
      // #1 口径对齐：有效已学/有效总量为真实正文章口径（剔辅文与跳过）
      'effective_total': _effectiveTotal(chapters, skipped),
      'effective_learned': _effectiveLearned(chapters, learnedThrough, skipped),
      'next_chapter': _nextChapter(chapters, learnedThrough, skipped),
      'chapters': rows,
    };
  }

  Map<String, dynamic>? _loadProgressJson() {
    try {
      final decoded = jsonDecode(
        File('$_corpusDir/progress.json').readAsStringSync(),
      );
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return null; // 缺失/损坏 → 调用方落空态（subjects: []）
  }

  static String _normTitle(String s) => s.replaceAll(RegExp(r'\s+'), '');

  // ---------------- corpus status（只读 corpus.db，优雅降级） ----------------

  Map<String, dynamic> _corpusStatus(Db db) {
    var totalChunks = 0;
    final subjects = <String, int>{};
    String? lastBuild;

    final dbFile = File('$_corpusDir/corpus.db');
    final dbBytes = dbFile.existsSync() ? dbFile.lengthSync() : 0;
    if (dbBytes > 0) {
      dynamic cdb;
      try {
        cdb = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
        try {
          totalChunks =
              (cdb.select('SELECT COUNT(*) AS n FROM chunks').first['n']
                  as int?) ??
              0;
        } catch (_) {}
        try {
          for (final row in cdb.select(
            'SELECT subject_id AS s, COUNT(*) AS n FROM chunks GROUP BY subject_id',
          )) {
            subjects[row['s'] as String] = row['n'] as int;
          }
        } catch (_) {}
        try {
          final rows = cdb.select(
            "SELECT value FROM meta WHERE key = 'last_build'",
          );
          if (rows.isNotEmpty) lastBuild = rows.first['value'] as String?;
        } catch (_) {}
      } catch (_) {
        // 打不开/缺表/损坏 → 全量降级（零值），status 仍 200
      } finally {
        (cdb as dynamic)?.dispose();
      }
    }

    final pendingFiles = _countPendingIncoming();
    final incomingBytes = _dirSize(Directory('$_corpusDir/incoming'));
    return {
      'totalChunks': totalChunks,
      'subjects': subjects,
      'lastBuild': lastBuild,
      'pendingFiles': pendingFiles,
      // ⑦ 回炉待重造：rework_queue pending 行数（统计页「卡生成队列」
      // 面板「回炉待重造 N」行；覆盖回炉按钮与拒绝带理由两个登记入口，
      // reworkDone 后回落）
      'reworkPending': db.reworkPendingCount(),
      'storageMB': ((dbBytes + incomingBytes) / (1024 * 1024)).round(),
    };
  }

  /// 待处理数（manifest 比对口径——构建成功后清零；见 _pendingIncomingFiles）。
  int _countPendingIncoming() => _pendingIncomingFiles().length;

  /// #5 前半（2026-09-13）：语料库诊断——回答「语料包内容还在不在库里」：
  /// deck 来源分布（package=语料包豁免剪除 / tree=手动课件）+ 各 source_type
  /// 块数（教材/真题/课件）+ 向量完整度 + 上次入库与嵌入模型。任何查询失败
  /// 单独吞掉（损坏库 → 零值降级，status 仍 200）。
  Map<String, dynamic> _corpusDiagnostics(Db db) {
    final deckSources = <String, int>{};
    final deckChunkCounts = <String, int>{};
    final chunkTypes = <String, int>{};
    final out = <String, dynamic>{
      'hasCorpus': false,
      'chunks': 0,
      'vectors': 0,
      'deckSources': deckSources,
      'deckChunkCounts': deckChunkCounts,
      'chunkTypes': chunkTypes,
      'lastIngest': null,
      'lastBuild': null,
      'embedModel': db.settingGet('embedding.model') ?? '',
    };
    final dbFile = File('$_corpusDir/corpus.db');
    if (!dbFile.existsSync() || dbFile.lengthSync() == 0) return out;
    dynamic cdb;
    try {
      cdb = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
      out['hasCorpus'] = true;
      try {
        out['chunks'] =
            (cdb.select('SELECT COUNT(*) AS n FROM chunks').first['n'] as int?) ??
                0;
      } catch (_) {}
      try {
        out['vectors'] = (cdb
                .select('SELECT COUNT(*) AS n FROM vectors')
                .first['n'] as int?) ??
            0;
      } catch (_) {}
      try {
        for (final row in cdb.select(
          'SELECT source AS s, COUNT(*) AS decks, SUM(chunk_count) AS cs '
          'FROM deck_state GROUP BY source',
        )) {
          deckSources[row['s'] as String] = row['decks'] as int;
          deckChunkCounts[row['s'] as String] = (row['cs'] as int?) ?? 0;
        }
      } catch (_) {}
      try {
        for (final row in cdb.select(
          'SELECT source_type AS t, COUNT(*) AS n FROM chunks GROUP BY source_type',
        )) {
          chunkTypes[row['t'] as String] = row['n'] as int;
        }
      } catch (_) {}
      try {
        for (final row in cdb.select(
          "SELECT key, value FROM meta WHERE key IN ('last_ingest', 'last_build')",
        )) {
          out[row['key'] as String] = row['value'] as String?;
        }
      } catch (_) {}
    } catch (_) {
      // 打不开 → hasCorpus 维持 true/false 按实况，其余零值降级
    } finally {
      (cdb as dynamic)?.dispose();
    }
    return out;
  }

  int _dirSize(Directory dir) {
    if (!dir.existsSync()) return 0;
    return dir
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .fold<int>(0, (sum, f) {
          try {
            return sum + f.lengthSync();
          } catch (_) {
            return sum;
          }
        });
  }

  // ---------------- pipeline（.force_run 标志 + 后台消费） ----------------

  /// /pipeline/trigger 真实现（契约与 ApiClient.triggerPipeline 对齐：
  /// 首次 triggered=true；重复 triggered=false 排队中——标志存在性判定，
  /// 端上单用户单线程足够，与服务端 exclusive-create 同语义）。
  /// 落标志后经 [pipelineKick] 触发后台执行（未装配只落标志——
  /// 与服务端「标志 + cron 消费」同构）。
  Map<String, dynamic> _triggerPipeline() {
    try {
      final marker = File('$_corpusDir/.force_run');
      marker.parent.createSync(recursive: true);
      final kick = pipelineKick;
      if (marker.existsSync()) {
        // 排队中：同样 kick（幂等）——若标志为上次失败遗留，重复触发即重试
        if (kick != null) {
          unawaited(kick());
        }
        return {'ok': true, 'triggered': false, 'note': '已有任务排队中'};
      }
      marker.writeAsStringSync(
        '${DateTime.now().toUtc().toIso8601String()}\n',
        flush: true,
      );
      if (kick != null) {
        unawaited(kick());
      }
      return {'ok': true, 'triggered': true, 'note': '已触发端上拆卡流水线（后台运行中）'};
    } on FileSystemException catch (e) {
      throw ApiException(500, '无法写入流水线触发标志: $e');
    }
  }

  /// /pipeline/weekly 真实现（手动真题周扫）：无 .force_run 标志语义——
  /// 直接经 [weeklyKick] 后台执行 weekly-only 单轮。catchup 运行中 → 409
  /// （consumeWeeklyRun 与 catchup 共用单飞，运行中 kick 会被静默忽略，
  /// 这里显式 409 让 UI 如实反馈）；DataMaintenance 备份/恢复期间已在
  /// _ensureDataAvailable 拒绝（409）。未装配（测试/CLI）→ 503。
  Map<String, dynamic> _triggerWeeklyScan() {
    final kick = weeklyKick;
    if (kick == null) {
      throw ApiException(503, '手动真题周扫未装配');
    }
    if (PipelineRunner.instance.running) {
      throw ApiException(409, '拆卡流水线正在运行，请稍后再试');
    }
    unawaited(kick());
    return {'ok': true, 'triggered': true, 'note': '已触发真题周扫（后台运行中）'};
  }

  /// PUT /pipeline/weekly：自动周扫节流时间戳自由调整。null/空串 = 清除
  /// （weeklyScanDue 对坏值视为「从未跑过」→ 下次 catchup 立即到期）；
  /// 合法 ISO = 任意前调/后调。手动周扫路径不写此键（两路节奏独立）。
  Map<String, dynamic> _setWeeklyScanSchedule(Db db, Map<String, dynamic> m) {
    if (!m.containsKey('lastRunAt')) {
      throw ApiException(400, '缺少 lastRunAt 字段（ISO 时间字符串或 null）');
    }
    final v = m['lastRunAt'];
    if (v == null || (v is String && v.trim().isEmpty)) {
      db.settingSet(kWeeklyScanSettingKey, '');
      return {
        'ok': true,
        'lastRunAt': null,
        'due': true,
        'note': '已清除自动周扫计时——下次拆卡收尾立即到期',
      };
    }
    if (v is! String) {
      throw ApiException(400, 'lastRunAt 必须是 ISO 时间字符串或 null');
    }
    final t = DateTime.tryParse(v.trim());
    if (t == null) {
      throw ApiException(400, 'lastRunAt 不是合法时间');
    }
    final iso = t.toIso8601String();
    db.settingSet(kWeeklyScanSettingKey, iso);
    return {
      'ok': true,
      'lastRunAt': iso,
      'due': weeklyScanDue(iso, DateTime.now()),
    };
  }

  // ---------------- 工具 ----------------

  static final _subjectIdPattern = RegExp(r'^[a-z0-9]{2,16}$');
  static final _subjectCodePattern = RegExp(
    r'^[a-z0-9]{1,32}$',
  ); // upload 短码（对照 routes/corpus.dart）
  static const _idChars = 'abcdefghijklmnopqrstuvwxyz0123456789';
  static final _rng = Random.secure();

  /// 自动生成唯一短码：8 位随机 [a-z0-9]；50 次撞码兜底时间戳 36 进制
  String _generateSubjectId(Db db) {
    for (var attempt = 0; attempt < 50; attempt++) {
      final candidate = List.generate(
        8,
        (_) => _idChars[_rng.nextInt(_idChars.length)],
      ).join();
      if (!db.subjectExists(candidate)) return candidate;
    }
    return 's${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
        .toLowerCase();
  }

  /// 上传白名单：小写后缀 → 魔数头（.pptx/.docx=OOXML ZIP 首字节 PK；.pdf=%PDF）
  static const _allowedMagic = <String, List<int>>{
    '.pptx': [0x50, 0x4B], // PK
    '.docx': [0x50, 0x4B], // PK
    '.pdf': [0x25, 0x50, 0x44, 0x46], // %PDF
  };

  static const _maxUploadBytes = 200 * 1024 * 1024;

  /// 文件名清洗：取末段（兼容 / 与 \ 分隔）、拒绝穿越残留/空名
  String? _sanitizeFilename(String name) {
    final base = name.split(RegExp(r'[/\\]')).last.trim();
    if (base.isEmpty || base == '.' || base == '..' || base.contains('..')) {
      return null;
    }
    return base;
  }

  String? _extOf(String name) {
    final lower = name.toLowerCase();
    for (final ext in _allowedMagic.keys) {
      if (lower.endsWith(ext)) return ext;
    }
    return null;
  }

  /// 末段文件名（兼容 / 与 \ 分隔；待处理清单展示用）。
  static String _baseNameOf(String path) => path.split(RegExp(r'[/\\]')).last;

  /// 相对根目录的 posix 路径（与建库 manifest 键同构——extract_all _relPosix
  /// 的对齐实现）。
  static String _relPosixOf(String path, String rootPath) {
    var rp = rootPath;
    if (rp.endsWith('/') || rp.endsWith('\\')) rp = rp.substring(0, rp.length - 1);
    var p = path;
    if (p.length > rp.length + 1 &&
        (p.startsWith('$rp\\') || p.startsWith('$rp/'))) {
      p = p.substring(rp.length + 1);
    }
    return p.replaceAll('\\', '/');
  }

  /// 第一层目录名（无子目录 → ''；incoming 布局下 = 科目短码）。
  static String _firstDirOfRel(String rel) {
    final i = rel.indexOf('/');
    return i <= 0 ? '' : rel.substring(0, i);
  }

  bool _startsWithMagic(List<int> bytes, List<int> magic) {
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  /// 掩码（与服务端/演示同语义：保留首 3 位 + 尾 2 位，中间 ****）
  static String maskApiKey(String key) => key.length <= 5
      ? '****'
      : '${key.substring(0, 3)}****${key.substring(key.length - 2)}';

  /// 安全取字符串（非字符串一律按空串处理，杜绝 cast 崩 500）
  static String _str(Object? v) => v is String ? v : '';
}
