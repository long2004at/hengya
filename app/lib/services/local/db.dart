// SQLite 数据库初始化与迁移（端上移植版：local-first，Phase 1）
// ← 逐字节移植自 server/lib/src/db.dart（2026-09-06 快照）：
// 仅本头注释块不同，其余内容与服务器版保持同步——同为 package:sqlite3
// 直接驱动，生产 hengya.db 可直接拷贝迁移到端上（schema 完全一致）。
// M1：cards / subjects / review_logs / rework_queue 四表 + meta
// 卡片调度状态内嵌 cards 表（m_* 列），避免 join；
// 事实源 = 本机 SQLite（local-first：一人一机一库独立使用）。
// 0.3.0：subjects 扩展 is_builtin + 内置 7 科播种；新增 settings 表
//（AI 服务配置；语料端点不碰本库——corpus.db 由语料管线生成，路由只读）。
// 0.3.1（开源去内置）：内置科目播种与七短码标记迁移移除；新增幂等迁移把
// 既有库 subjects.is_builtin 全部归 0（列保留仅为既有库 schema 兼容，
// 代码不再写 1；新库零科目，科目全部用户自建）。
import 'dart:io';

import 'package:shared/hengya_shared.dart';
import 'package:sqlite3/sqlite3.dart';

class Db {
  Db._(this._db);

  final Database _db;

  static Future<Db> open(String path) {
    final parent = File(path).parent;
    if (parent.path.isNotEmpty && !parent.existsSync()) {
      parent.createSync(recursive: true);
    }
    final db = sqlite3.open(path);
    return Future.sync(() {
      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA foreign_keys = ON;');
      _migrate(db);
      return Db._(db);
    });
  }

  // ---------------- 迁移 ----------------

  static void _migrate(Database db) {
    db.execute('''
      CREATE TABLE IF NOT EXISTS meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
    db.execute(
      "INSERT OR IGNORE INTO meta (key, value) VALUES ('data_version', '0');",
    );

    db.execute('''
      CREATE TABLE IF NOT EXISTS subjects (
        id              TEXT PRIMARY KEY,
        name            TEXT NOT NULL,
        is_exam_subject INTEGER NOT NULL DEFAULT 0,
        sort_order      INTEGER NOT NULL DEFAULT 0,
        -- is_builtin：历史内置科标记列（0.3.1 开源去内置起恒为 0；
        -- 列保留仅为既有库 schema 兼容，不重建表）
        is_builtin      INTEGER NOT NULL DEFAULT 0,
        created_at      TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');

    // 0.3.0：既有部署的 subjects 表无 is_builtin 列 → ALTER 扩展（幂等）
    _addColumnIfMissing(
      db,
      'subjects',
      'is_builtin',
      'INTEGER NOT NULL DEFAULT 0',
    );

    // 0.3.1（开源去内置）：幂等迁移——既有库 subjects.is_builtin 全部归 0。
    // 内置科目概念退役（新库零科目，科目全部用户自建）；用户科目数据
    // 一行不动，仅标记位归零（列保留，见上方列注释）。
    db.execute('UPDATE subjects SET is_builtin = 0 WHERE is_builtin != 0');

    // 0.3.0 契约一：AI 服务设置（key-value；api_key 由 AiKeyVault 封存后
    // 存入 value——密文 enc:... 或明文回退；键名 llm.*/embedding.*/reranker.*）
    db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key        TEXT PRIMARY KEY,
        value      TEXT,
        updated_at TEXT
      );
    ''');

    db.execute('''
      CREATE TABLE IF NOT EXISTS cards (
        id             TEXT PRIMARY KEY,
        subject_id     TEXT NOT NULL REFERENCES subjects(id),
        type           TEXT NOT NULL,
        front          TEXT NOT NULL,
        back           TEXT NOT NULL,
        anchor         TEXT NOT NULL DEFAULT '',
        source         TEXT NOT NULL DEFAULT '',
        source_tier    TEXT NOT NULL DEFAULT 'ppt',
        status         TEXT NOT NULL DEFAULT 'pending',
        tags           TEXT NOT NULL DEFAULT '[]',
        exam_year      TEXT,
        -- FSRS 调度状态（shared.CardMemoryState 持久化）
        m_state        TEXT NOT NULL DEFAULT 'newCard',
        m_due_at       TEXT NOT NULL,
        m_last_review  TEXT,
        m_stability    REAL,
        m_difficulty   REAL,
        m_reps         INTEGER NOT NULL DEFAULT 0,
        m_lapses       INTEGER NOT NULL DEFAULT 0,
        created_at     TEXT NOT NULL DEFAULT (datetime('now')),
        updated_at     TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_cards_status ON cards(status, subject_id);',
    );
    db.execute(
      "CREATE INDEX IF NOT EXISTS idx_cards_due ON cards(m_due_at) WHERE status = 'active';",
    );

    db.execute('''
      CREATE TABLE IF NOT EXISTS review_logs (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        card_id         TEXT NOT NULL REFERENCES cards(id),
        subject_id      TEXT NOT NULL,
        rating          TEXT NOT NULL,
        reviewed_at     TEXT NOT NULL,
        latency_ms      INTEGER,
        offline_queued  INTEGER NOT NULL DEFAULT 0,
        state_before    TEXT NOT NULL,
        state_after     TEXT NOT NULL,
        stability_after REAL,
        interval_days   REAL
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_logs_card ON review_logs(card_id);',
    );
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_logs_time ON review_logs(reviewed_at);',
    );

    db.execute('''
      CREATE TABLE IF NOT EXISTS rework_queue (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        card_id     TEXT NOT NULL REFERENCES cards(id),
        reason      TEXT NOT NULL,
        note        TEXT NOT NULL DEFAULT '',
        status      TEXT NOT NULL DEFAULT 'pending',
        created_at  TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');

    // M2：关键词收件箱（App 上线前关键词经对话→助手落 content/inbox/；
    // 上线后 App 直接 POST /inbox/keywords。自动化 22:55 拉取拆卡）
    db.execute('''
      CREATE TABLE IF NOT EXISTS inbox (
        id          INTEGER PRIMARY KEY AUTOINCREMENT,
        subject_id  TEXT NOT NULL,
        keyword     TEXT NOT NULL,
        source      TEXT NOT NULL DEFAULT 'chat',
        note        TEXT NOT NULL DEFAULT '',
        consumed_at TEXT,
        created_at  TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');
    db.execute(
      'CREATE INDEX IF NOT EXISTS idx_inbox_pending ON inbox(consumed_at);',
    );

    // M4 题库：卡片备注/留言（App 端 02b 详情页）
    // user_note = 我的备注（学生写给自己）；ai_note = AI 留言（学生写给拆卡 AI，
    // 次日自动化拆卡拉取 /rework/pending 时会读到，柔性反馈通道）
    // ai_note_seen_at：自动化对该卡完成回炉时标记；用户更新留言则清空重新可见
    db.execute('''
      CREATE TABLE IF NOT EXISTS card_notes (
        card_id        TEXT PRIMARY KEY REFERENCES cards(id),
        user_note      TEXT NOT NULL DEFAULT '',
        ai_note        TEXT NOT NULL DEFAULT '',
        ai_note_seen_at TEXT,
        updated_at     TEXT NOT NULL DEFAULT (datetime('now'))
      );
    ''');
  }

  /// 既有表补列（幂等）：列缺失才 ALTER ADD（0.3.0 subjects.is_builtin）
  static void _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String ddl,
  ) {
    final cols = db
        .select('PRAGMA table_info($table)')
        .map((r) => r['name'] as String)
        .toSet();
    if (!cols.contains(column)) {
      db.execute('ALTER TABLE $table ADD COLUMN $column $ddl');
    }
  }

  // ---------------- meta ----------------

  String get dataVersion {
    final row = _db.select("SELECT value FROM meta WHERE key = 'data_version'");
    return row.isEmpty ? '0' : row.first['value'] as String;
  }

  /// 数据版本 +1（任何写入操作后调用；App 增量同步的判断依据 13.2）
  void bumpDataVersion() {
    _db.execute(
      "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'data_version';",
    );
  }

  // ---------------- subjects ----------------

  List<Subject> subjects() => _db
      .select(
        'SELECT id, name, is_exam_subject FROM subjects ORDER BY sort_order, id',
      )
      .map(
        (row) => Subject(
          id: row['id'] as String,
          name: row['name'] as String,
          isExamSubject: (row['is_exam_subject'] as int) == 1,
        ),
      )
      .toList();

  /// 初始化科目（幂等：不存在才插入；与 schedule/schedule.json 同源）
  void seedSubjects(List<Subject> subjects) {
    final existing = {for (var s in this.subjects()) s.id};
    for (var i = 0; i < subjects.length; i++) {
      final s = subjects[i];
      if (existing.contains(s.id)) continue;
      _db.execute(
        'INSERT INTO subjects (id, name, is_exam_subject, sort_order) VALUES (?, ?, ?, ?)',
        [s.id, s.name, s.isExamSubject ? 1 : 0, i],
      );
    }
  }

  bool subjectExists(String id) {
    final row = _db.select('SELECT 1 FROM subjects WHERE id = ?', [id]);
    return row.isNotEmpty;
  }

  /// 幂等补科目行（节点④：大纲入库自动确保占位科目「医学综合」med——
  /// 同款 derm 机制：subjects 一行 + progress.json 无罗盘占位，后者由
  /// 调用方（corpus_build_job.ensureMedSubjectPlaceholder）落）。已存在
  /// 返回 false；新插入排在现有科目之后（sort_order = max+1）。
  bool ensureSubjectRow(String id, String name, {bool isExamSubject = false}) {
    if (subjectExists(id)) return false;
    _db.execute(
      'INSERT INTO subjects (id, name, is_exam_subject, sort_order) '
      'VALUES (?, ?, ?, '
      '(SELECT COALESCE(MAX(sort_order), -1) + 1 FROM subjects))',
      [id, name, isExamSubject ? 1 : 0],
    );
    return true;
  }

  // ---------------- subjects 扩展（0.3.0 契约三：动态科目） ----------------

  /// 全量科目行（GET /subjects 数据源，排序与 subjects() 一致）
  List<Map<String, dynamic>> subjectRows() => _db
      .select(
        'SELECT id, name, is_exam_subject FROM subjects '
        'ORDER BY sort_order, id',
      )
      .map(
        (r) => {
          'id': r['id'] as String,
          'name': r['name'] as String,
          'isExamSubject': (r['is_exam_subject'] as int) == 1,
        },
      )
      .toList();

  /// 科目名是否已被占用（重名 409 判据）；[excludeId] 供改名时排除自身
  bool subjectNameExists(String name, {String? excludeId}) {
    final rows = excludeId == null
        ? _db.select('SELECT 1 FROM subjects WHERE name = ?', [name])
        : _db.select('SELECT 1 FROM subjects WHERE name = ? AND id != ?', [
            name,
            excludeId,
          ]);
    return rows.isNotEmpty;
  }

  /// 下一个 sort_order（新建科目排到队尾，保持列表稳定追加）
  int nextSubjectSortOrder() =>
      _db
              .select(
                'SELECT COALESCE(MAX(sort_order), -1) + 1 AS n FROM subjects',
              )
              .first['n']
          as int;

  /// 新建科目（App 动态科目；is_builtin 恒 0）。唯一性由调用方（路由层）校验
  void insertSubject({required String id, required String name}) {
    _db.execute(
      'INSERT INTO subjects (id, name, is_builtin, sort_order) VALUES (?,?,0,?)',
      [id, name, nextSubjectSortOrder()],
    );
  }

  /// 改名（id 不可改——卡片/关键词/语料全引用它）。
  /// 返回 false = 科目不存在
  bool renameSubject(String id, String name) {
    _db.execute('UPDATE subjects SET name = ? WHERE id = ?', [name, id]);
    return _db.updatedRows > 0;
  }

  // ---------------- settings（0.3.0 契约一：AI 服务配置） ----------------

  /// 读配置项（不存在返回 null）；键名约定：llm.* / embedding.* / reranker.*
  String? settingGet(String key) {
    final rows = _db.select('SELECT value FROM settings WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  /// 写配置项（upsert）。注意：配置类数据不 bump data_version——
  /// data_version 是 App 学习数据增量同步的判断依据，AI 设置不参与
  void settingSet(String key, String value) {
    _db.execute(
      "INSERT INTO settings (key, value, updated_at) "
      "VALUES (?, ?, datetime('now')) "
      'ON CONFLICT(key) DO UPDATE SET '
      "value = excluded.value, updated_at = datetime('now')",
      [key, value],
    );
  }

  // ---------------- cards ----------------

  FlashCard? cardById(String id) {
    final rows = _db.select('SELECT * FROM cards WHERE id = ?', [id]);
    return rows.isEmpty ? null : _rowToCard(rows.first);
  }

  /// 待审核卡（新导入/重造完成）。
  /// #15（2026-09-13）：支持分页——原默认 100 张硬截断会把 created_at 较旧
  /// 的回炉完成卡挤出待审池（它又不进题库列表），形成「审核区/题库两端都
  /// 找不到」的假性丢卡；配合路由层返回 total 供 UI 加载更多。
  List<FlashCard> pendingCards({int limit = 100, int offset = 0}) {
    final rows = _db.select(
      "SELECT * FROM cards WHERE status = 'pending' "
      'ORDER BY created_at LIMIT ? OFFSET ?',
      [limit, offset],
    );
    return rows.map(_rowToCard).toList();
  }

  /// 待审核总数（#15 分页配套：审核区「加载更多」判定与总数展示）。
  int pendingCardsCount() {
    final rows = _db.select(
      "SELECT COUNT(*) AS n FROM cards WHERE status = 'pending'",
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// 复习队列：active 且到期（含超期），按到期时间升序；科目隔离（决策 #8）
  List<FlashCard> dueCards(String subjectId, {int limit = 50}) {
    final rows = _db.select(
      "SELECT * FROM cards WHERE subject_id = ? AND status = 'active' "
      'AND m_due_at <= ? ORDER BY m_due_at ASC LIMIT ?',
      [subjectId, DateTime.now().toIso8601String(), limit],
    );
    return rows.map(_rowToCard).toList();
  }

  /// 各科到期数（首页角标）
  Map<String, int> dueCounts() {
    final rows = _db.select(
      "SELECT subject_id, COUNT(*) AS n FROM cards "
      "WHERE status = 'active' AND m_due_at <= ? GROUP BY subject_id",
      [DateTime.now().toIso8601String()],
    );
    return {for (var r in rows) r['subject_id'] as String: r['n'] as int};
  }

  /// 插入（导入用）；幂等：已存在的 id 跳过。
  /// 返回 true=新插入，false=已存在跳过
  bool importCard(FlashCard card) {
    if (cardById(card.id) != null) return false;
    _db.execute(
      'INSERT INTO cards (id, subject_id, type, front, back, anchor, source, '
      'source_tier, status, tags, exam_year, m_due_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        card.id,
        card.subjectId,
        card.type.name,
        card.front,
        card.back,
        card.anchor,
        card.source,
        card.sourceTier.name,
        card.status.name,
        _tagsToJson(card.tags),
        card.examYear,
        DateTime.now().toIso8601String(),
      ],
    );
    return true;
  }

  /// 审核通过：pending → active（进入复习队列，调度状态重置为 newCard）
  void activateCard(String id) {
    _db.execute(
      "UPDATE cards SET status = 'active', m_state = 'newCard', "
      "m_due_at = ?, m_reps = 0, m_lapses = 0, updated_at = datetime('now') "
      'WHERE id = ?',
      [DateTime.now().toIso8601String(), id],
    );
  }

  /// 审核拒绝：pending → rejected（保留在库，可查）
  void rejectCard(String id) {
    _db.execute(
      "UPDATE cards SET status = 'rejected', updated_at = datetime('now') WHERE id = ?",
      [id],
    );
  }

  /// 审核编辑：改题干/答案/锚点。
  /// 契约放宽（M4.1）：pending 或 active 均可编辑（App 题库详情页「编辑」
  /// 按钮对 active 卡开放）；其余状态 SQL 条件不命中、不生效。
  /// active 卡编辑后状态保持 active，调度字段（m_* 列）完全不动
  ///（本方法只 UPDATE front/back/anchor + updated_at）。
  void editPendingCard(
    String id, {
    String? front,
    String? back,
    String? anchor,
  }) {
    final sets = <String>["updated_at = datetime('now')"];
    final args = <Object>[];
    if (front != null) {
      sets.add('front = ?');
      args.add(front);
    }
    if (back != null) {
      sets.add('back = ?');
      args.add(back);
    }
    if (anchor != null) {
      sets.add('anchor = ?');
      args.add(anchor);
    }
    args.add(id);
    _db.execute(
      "UPDATE cards SET ${sets.join(', ')} WHERE id = ? "
      "AND status IN ('pending', 'active')",
      args,
    );
  }

  /// 回炉重造：active → rework（出复习队列），并登记原因。
  /// #15（2026-09-13）：双写包事务——原实现两条 execute 无事务，第二条
  /// （INSERT rework_queue）失败时卡会卡死在 rework 状态且队列无行，
  /// 永不重造、永不回 pending（题库里只剩「重造中」徽标的僵尸卡）。
  void reworkCard(String id, String reason, String note) {
    _tx(() {
      _db.execute(
        "UPDATE cards SET status = 'rework', updated_at = datetime('now') WHERE id = ?",
        [id],
      );
      _db.execute(
        'INSERT INTO rework_queue (card_id, reason, note) VALUES (?,?,?)',
        [id, reason, note],
      );
    });
  }

  /// 事务包裹（#15）：BEGIN IMMEDIATE / COMMIT / ROLLBACK——与
  /// extract_all.dart tx 同款形态（写锁碰撞由调用方 busy 重试吸收）。
  void _tx(void Function() body) {
    _db.execute('BEGIN IMMEDIATE');
    try {
      body();
      _db.execute('COMMIT');
    } catch (e) {
      try {
        _db.execute('ROLLBACK');
      } catch (_) {}
      rethrow;
    }
  }

  /// 回炉队列（自动化拉取 GET /rework/pending）
  List<Map<String, dynamic>> reworkPending({int limit = 50}) {
    return _db
        .select(
          'SELECT r.id, r.card_id, r.reason, r.note, r.created_at, '
          'c.front, c.back, c.subject_id FROM rework_queue r '
          "JOIN cards c ON c.id = r.card_id WHERE r.status = 'pending' LIMIT ?",
          [limit],
        )
        .map(
          (r) => {
            'id': r['id'],
            'cardId': r['card_id'],
            'reason': r['reason'],
            'note': r['note'],
            'createdAt': r['created_at'],
            'front': r['front'],
            'back': r['back'],
            'subjectId': r['subject_id'],
          },
        )
        .toList();
  }

  /// 回炉队列项对应的卡 id（路由层响应用）
  String? reworkQueueCardId(int queueId) {
    final rows = _db.select('SELECT card_id FROM rework_queue WHERE id = ?', [
      queueId,
    ]);
    return rows.isEmpty ? null : rows.first['card_id'] as String;
  }

  /// ⑦ 回炉待重造计数：rework_queue 中 status='pending' 的行数——下次流水线
  /// 将要重造的积压量（统计页「卡生成队列」面板「回炉待重造 N」行 /
  /// /corpus/status 的 reworkPending 字段）。覆盖两个登记入口：
  /// · 题库/复习页回炉按钮（[reworkCard]：卡→rework + 队列行 pending）；
  /// · 待审核区拒绝带理由（[rejectCardWithReason]：卡→rejected + 队列行
  ///   pending，理由即重造反馈通道）——该入口卡状态是 rejected 而非
  ///   rework，只数 cards.status='rework' 会漏掉它们。
  /// [reworkDone] 完成后行置 done → 计数回落。与 [reworkPending]（同表
  /// 同条件明细清单，流水线消费口径）一致。
  int reworkPendingCount() {
    final rows = _db.select(
      "SELECT COUNT(*) AS n FROM rework_queue WHERE status = 'pending'",
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  /// 回炉幂等预检（#10②）：该卡是否已在回炉队列（重造中）。
  /// 判据取卡状态 == 'rework'：[reworkCard] 原子地「置状态 + 登记 rework_queue」，
  /// [reworkDone] 完成时同步「拨回 pending + 队列项置 done」——状态即队列在位
  /// 的充要投影。不能只查 rework_queue：审核拒绝带理由
  /// （[rejectCardWithReason]）也登记队列但卡状态是 rejected，仅查队列会把
  /// 拒绝卡误判成重造中。提交链路据此把重复回炉降级为幂等成功而非报错。
  bool cardInReworkQueue(String cardId) {
    return _db.select(
      "SELECT 1 FROM cards WHERE id = ? AND status = 'rework' LIMIT 1",
      [cardId],
    ).isNotEmpty;
  }

  /// 回炉重造完成（自动化 `POST /rework/<queueId>/done`）：
  /// 重写 front/back/anchor（未传的字段保留原值）→ 卡回 pending 待审核池
  /// → 队列项标记 done。返回 null 成功；'not_found' / 'stale'
  String? reworkDone(
    int queueId, {
    String? front,
    String? back,
    String? anchor,
  }) {
    final rows = _db.select(
      "SELECT card_id, status FROM rework_queue WHERE id = ?",
      [queueId],
    );
    if (rows.isEmpty) return 'not_found';
    if (rows.first['status'] != 'pending') return 'stale';
    final cardId = rows.first['card_id'] as String;
    final sets = <String>["status = 'pending'", "updated_at = datetime('now')"];
    final args = <Object>[];
    if (front != null && front.isNotEmpty) {
      sets.add('front = ?');
      args.add(front);
    }
    if (back != null && back.isNotEmpty) {
      sets.add('back = ?');
      args.add(back);
    }
    if (anchor != null && anchor.isNotEmpty) {
      sets.add('anchor = ?');
      args.add(anchor);
    }
    args.add(cardId);
    // #15（2026-09-13）：两写包事务——卡回 pending 与队列置 done 必须原子，
    // 中断（如进程被杀）会造成「卡已回 pending 但队列仍 pending」的状态漂移
    // （下轮重复重造）或反向漂移。
    _tx(() {
      _db.execute('UPDATE cards SET ${sets.join(', ')} WHERE id = ?', args);
      _db.execute("UPDATE rework_queue SET status = 'done' WHERE id = ?", [
        queueId,
      ]);
    });
    return null;
  }

  /// 移除废卡（#15）：物理删除——守卫卡存在且 status == rejected。
  ///
  /// 审计结论（2026-09-07）：rejected 卡的产生路径只有 [rejectCard] /
  /// [rejectCardWithReason]（均从 pending 转入），pending 卡不进复习轮转
  /// （[dueCards] 只查 active），故 rejected 卡理论上绝无 review_logs 账本
  /// 行。但 Db.open 启用了 PRAGMA foreign_keys=ON：若历史脏数据真有账本行，
  /// 「保留账本行 + 删卡行」会被外键以 FOREIGN KEY constraint failed 挡住
  /// ——因此防御性先清该卡账本行（正常路径 0 行删除；统计/热力图/连续打卡
  /// 聚合全部按 review_logs 自身字段统计，零影响）。拒绝带理由
  /// （[rejectCardWithReason]）登记的 rework_queue 行是正常存在的（次日
  /// 自动化拉取的拒绝反馈通道），随卡一并删除；card_notes（用户备注 + AI
  /// 留言）同删。
  ///
  /// 返回 null=删除成功；'not_found'=卡不存在；'not_rejected'=非 rejected
  /// 拒删（路由层据此给 404/400，文案不带内部 id）。同步 execute 风格与
  /// [reworkCard] 等一致；bumpDataVersion 由路由层负责（同既有写方法）。
  String? deleteCard(String cardId) {
    final rows = _db.select('SELECT status FROM cards WHERE id = ?', [cardId]);
    if (rows.isEmpty) return 'not_found';
    if (rows.first['status'] != 'rejected') return 'not_rejected';
    _db.execute('DELETE FROM review_logs WHERE card_id = ?', [cardId]);
    _db.execute('DELETE FROM rework_queue WHERE card_id = ?', [cardId]);
    _db.execute('DELETE FROM card_notes WHERE card_id = ?', [cardId]);
    _db.execute('DELETE FROM cards WHERE id = ?', [cardId]);
    return null;
  }

  /// 痛觉卡（leech）：lapse ≥ 4 的 active 卡（自动化 GET /cards/leech）
  List<FlashCard> leechCards({int threshold = 4, int limit = 50}) {
    final rows = _db.select(
      "SELECT * FROM cards WHERE status = 'active' AND m_lapses >= ? LIMIT ?",
      [threshold, limit],
    );
    return rows.map(_rowToCard).toList();
  }

  // ---------------- 题库（M4：App 端 02 屏） ----------------

  /// 题库检索：全部非 pending 卡（active/rework/rejected/archived 均可查），
  /// 可选科目过滤 + 全文 LIKE（front/back/tags）。排除 pending：
  /// 未过审核的卡不进学习视野（质量闸门，决策 #9）。
  /// 返回 (cards, total)，支持分页。
  (List<Map<String, dynamic>>, int) searchCards({
    String? subject,
    String? q,
    int offset = 0,
    int limit = 50,
  }) {
    final where = <String>["c.status != 'pending'"];
    final args = <Object>[];
    if (subject != null && subject.isNotEmpty) {
      where.add('c.subject_id = ?');
      args.add(subject);
    }
    if (q != null && q.isNotEmpty) {
      where.add("(c.front LIKE ? OR c.back LIKE ? OR c.tags LIKE ?)");
      final pat = '%$q%';
      args
        ..add(pat)
        ..add(pat)
        ..add(pat);
    }
    final whereSql = where.join(' AND ');
    final total =
        _db
                .select(
                  'SELECT COUNT(*) AS n FROM cards c WHERE $whereSql',
                  args,
                )
                .first['n']
            as int;
    final rows = _db.select(
      'SELECT c.*, n.user_note, n.ai_note FROM cards c '
      'LEFT JOIN card_notes n ON n.card_id = c.id '
      'WHERE $whereSql '
      "ORDER BY CASE c.status WHEN 'active' THEN 0 ELSE 1 END, "
      'c.m_due_at ASC, c.updated_at DESC '
      'LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    final cards = rows.map((r) {
      final card = _rowToCard(r);
      return {
        ...card.toJson(),
        // 调度摘要（题库列表状态徽标：今天到期/已掌握/弱卡）
        'dueAt': (r['m_due_at'] ?? '') as String,
        'reps': (r['m_reps'] ?? 0) as int,
        'lapses': (r['m_lapses'] ?? 0) as int,
        'userNote': (r['user_note'] ?? '') as String,
        'aiNote': (r['ai_note'] ?? '') as String,
      };
    }).toList();
    return (cards, total);
  }

  /// 单卡详情（M4.1：App 02b 题库详情页）：按 id 查单卡，
  /// 返回与 searchCards 单卡条目完全同构的对象（含 dueAt/reps/lapses/
  /// userNote/aiNote 联表字段），不存在返回 null。
  Map<String, dynamic>? cardDetail(String id) {
    final rows = _db.select(
      'SELECT c.*, n.user_note, n.ai_note FROM cards c '
      'LEFT JOIN card_notes n ON n.card_id = c.id WHERE c.id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    final card = _rowToCard(r);
    return {
      ...card.toJson(),
      // 调度摘要（详情页状态徽标，与 /search 单卡条目同构）
      'dueAt': (r['m_due_at'] ?? '') as String,
      'reps': (r['m_reps'] ?? 0) as int,
      'lapses': (r['m_lapses'] ?? 0) as int,
      'userNote': (r['user_note'] ?? '') as String,
      'aiNote': (r['ai_note'] ?? '') as String,
    };
  }

  /// 卡片备注：我的备注 + AI 留言（单卡 get）
  Map<String, dynamic>? cardNotes(String cardId) {
    final rows = _db.select(
      'SELECT user_note, ai_note FROM card_notes WHERE card_id = ?',
      [cardId],
    );
    if (rows.isEmpty) {
      return const {'userNote': '', 'aiNote': ''};
    }
    return {
      'userNote': (rows.first['user_note'] ?? '') as String,
      'aiNote': (rows.first['ai_note'] ?? '') as String,
    };
  }

  /// 更新我的备注（upsert；传 null 不动，传空串清空）
  void updateUserNote(String cardId, String note) {
    _db.execute(
      'INSERT INTO card_notes (card_id, user_note, updated_at) '
      "VALUES (?, ?, datetime('now')) "
      'ON CONFLICT(card_id) DO UPDATE SET '
      "user_note = excluded.user_note, updated_at = datetime('now')",
      [cardId, note],
    );
  }

  /// 更新 AI 留言（upsert；写入即清空 seen 标记 → 自动化次日重读）
  void updateAiNote(String cardId, String note) {
    _db.execute(
      'INSERT INTO card_notes (card_id, ai_note, updated_at) '
      "VALUES (?, ?, datetime('now')) "
      'ON CONFLICT(card_id) DO UPDATE SET '
      'ai_note = excluded.ai_note, ai_note_seen_at = NULL, '
      "updated_at = datetime('now')",
      [cardId, note],
    );
  }

  /// 未读 AI 留言（自动化拉取：GET /rework/pending 一并返回，
  /// 次日拆卡时读到留言，柔性改进这张卡）
  List<Map<String, dynamic>> unreadAiNotes({int limit = 50}) {
    return _db
        .select(
          'SELECT n.card_id, n.ai_note, c.front, c.subject_id '
          'FROM card_notes n JOIN cards c ON c.id = n.card_id '
          "WHERE n.ai_note != '' AND n.ai_note_seen_at IS NULL LIMIT ?",
          [limit],
        )
        .map(
          (r) => {
            'cardId': r['card_id'],
            'aiNote': r['ai_note'],
            'front': r['front'],
            'subjectId': r['subject_id'],
          },
        )
        .toList();
  }

  /// 自动化处理完某卡（读留言/回炉）后标记已读
  void markAiNoteSeen(String cardId) {
    _db.execute(
      "UPDATE card_notes SET ai_note_seen_at = datetime('now') WHERE card_id = ?",
      [cardId],
    );
  }

  /// 审核拒绝带理由（设计稿 03b）：reject 时把理由塞进 rework_queue，
  /// 让次日自动化看到（功能等同回炉重造的反馈通道）
  void rejectCardWithReason(String id, String reason, String note) {
    _db.execute(
      "UPDATE cards SET status = 'rejected', updated_at = datetime('now') WHERE id = ?",
      [id],
    );
    _db.execute(
      'INSERT INTO rework_queue (card_id, reason, note) VALUES (?,?,?)',
      [id, '审核拒绝：$reason', note],
    );
  }

  // ---------------- inbox（M2 关键词收件箱） ----------------

  /// 关键词入箱（source: chat=对话转存 / app=App 直发）
  int insertKeyword({
    required String subjectId,
    required String keyword,
    String source = 'chat',
    String note = '',
  }) {
    _db.execute(
      'INSERT INTO inbox (subject_id, keyword, source, note) VALUES (?,?,?,?)',
      [subjectId, keyword, source, note],
    );
    return _db.lastInsertRowId;
  }

  /// 未消费关键词（自动化拉取 GET /inbox/pending）
  List<Map<String, dynamic>> inboxPending({int limit = 100}) {
    return _db
        .select(
          'SELECT id, subject_id, keyword, source, note, created_at '
          'FROM inbox WHERE consumed_at IS NULL ORDER BY created_at LIMIT ?',
          [limit],
        )
        .map(
          (r) => {
            'id': r['id'],
            'subjectId': r['subject_id'],
            'keyword': r['keyword'],
            'source': r['source'],
            'note': r['note'],
            'createdAt': r['created_at'],
          },
        )
        .toList();
  }

  /// 标记关键词已消费（导入成功后自动化回调 POST /inbox/consume）
  /// 返回实际标记条数
  int consumeKeywords(List<int> ids) {
    if (ids.isEmpty) return 0;
    final placeholders = List.filled(ids.length, '?').join(',');
    _db.execute(
      'UPDATE inbox SET consumed_at = ? WHERE id IN ($placeholders) '
      'AND consumed_at IS NULL',
      [DateTime.now().toIso8601String(), ...ids],
    );
    return _db.updatedRows;
  }

  /// 近 7 日学习统计（自动化上下文 + App 统计页数据源）
  Map<String, dynamic> statsSummary({int days = 7}) {
    final since = DateTime.now()
        .subtract(Duration(days: days))
        .toIso8601String();
    final byDay = _db.select(
      "SELECT substr(reviewed_at, 1, 10) AS day, COUNT(*) AS n, "
      "SUM(CASE WHEN rating = 'again' THEN 1 ELSE 0 END) AS again_n "
      'FROM review_logs WHERE reviewed_at >= ? GROUP BY day ORDER BY day',
      [since],
    );
    final bySubject = _db.select(
      'SELECT subject_id, COUNT(*) AS n, '
      "SUM(CASE WHEN rating = 'again' THEN 1 ELSE 0 END) AS again_n "
      'FROM review_logs WHERE reviewed_at >= ? GROUP BY subject_id',
      [since],
    );
    final totalRow = _db.select(
      'SELECT COUNT(*) AS n, '
      "SUM(CASE WHEN rating = 'again' THEN 1 ELSE 0 END) AS again_n "
      'FROM review_logs WHERE reviewed_at >= ?',
      [since],
    ).first;
    final pendingN =
        _db
                .select(
                  "SELECT COUNT(*) AS n FROM cards WHERE status = 'pending'",
                )
                .first['n']
            as int;
    final reworkN =
        _db
                .select(
                  "SELECT COUNT(*) AS n FROM rework_queue WHERE status = 'pending'",
                )
                .first['n']
            as int;
    final inboxN =
        _db
                .select(
                  'SELECT COUNT(*) AS n FROM inbox WHERE consumed_at IS NULL',
                )
                .first['n']
            as int;

    final total = totalRow['n'] as int? ?? 0;
    final again = totalRow['again_n'] as int? ?? 0;
    return {
      'days': days,
      'totalReviews': total,
      'againCount': again,
      'againRate': total == 0 ? 0.0 : (again / total).toStringAsFixed(3),
      'pendingCards': pendingN,
      'pendingRework': reworkN,
      'pendingInbox': inboxN,
      'byDay': byDay
          .map(
            (r) => {'day': r['day'], 'reviews': r['n'], 'again': r['again_n']},
          )
          .toList(),
      'bySubject': bySubject
          .map(
            (r) => {
              'subjectId': r['subject_id'],
              'reviews': r['n'],
              'again': r['again_n'],
            },
          )
          .toList(),
    };
  }

  /// 未来 N 天到期预测（App 统计页柱状图 + 自动化决策上下文）
  /// 返回 [{date, due}]，date 为 YYYY-MM-DD，due 为该日到期 active 卡数
  List<Map<String, dynamic>> dueForecast({int days = 7}) {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day); // 今日零点
    final rows = _db.select(
      "SELECT substr(m_due_at, 1, 10) AS d, COUNT(*) AS n "
      "FROM cards WHERE status = 'active' "
      "AND m_due_at < ? GROUP BY d",
      [start.add(Duration(days: days)).toIso8601String()],
    );
    final byDate = {for (final r in rows) r['d'] as String: r['n'] as int};
    // 逾期（due < 今日零点）计入今日
    final overdue =
        _db.select(
              "SELECT COUNT(*) AS n FROM cards "
              "WHERE status = 'active' AND m_due_at < ?",
              [start.toIso8601String()],
            ).first['n']
            as int;
    return [
      for (var i = 0; i < days; i++)
        () {
          final day = start.add(Duration(days: i));
          final key = _dayKey(day);
          final due = i == 0
              ? (byDate[key] ?? 0) + overdue
              : (byDate[key] ?? 0);
          return {'date': key, 'due': due};
        }(),
    ];
  }

  static String _dayKey(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-'
      '${t.month.toString().padLeft(2, '0')}-'
      '${t.day.toString().padLeft(2, '0')}';

  /// 保留率统计（App 统计页「保留率」模块数据源）
  ///
  /// 口径：近 N 天窗口内全部复习记录中，"当场回忆成功"（rating ≠ again）
  /// 的比例 = (total - again) / total。FSRS 语境下 again 表示遗忘，
  /// 其余三档（hard/good/easy）均视为保留成功。
  /// 窗口固定 [近1天, 近7天, 近30天]；无复习记录时 rate 为 null（App 显示"暂无数据"）。
  Map<String, dynamic> retentionStats() {
    return {
      'windows': [
        for (final d in const [1, 7, 30])
          () {
            final since = DateTime.now()
                .subtract(Duration(days: d))
                .toIso8601String();
            final row = _db.select(
              'SELECT COUNT(*) AS total, '
              "SUM(CASE WHEN rating = 'again' THEN 1 ELSE 0 END) AS again_n "
              'FROM review_logs WHERE reviewed_at >= ?',
              [since],
            ).first;
            final total = row['total'] as int? ?? 0;
            final again = row['again_n'] as int? ?? 0;
            return {
              'days': d,
              'total': total,
              'retained': total - again,
              'rate': total == 0
                  ? null
                  : ((total - again) / total).toStringAsFixed(3),
            };
          }(),
      ],
    };
  }

  /// 连续打卡天数（streak）：从今天往回数，有复习日志的连续天数
  /// 今日未复习不打断昨日 streak（显示当前 streak 时由 App 端处理"今日待续"）
  int streakDays() {
    final days = _db
        .select(
          "SELECT DISTINCT substr(reviewed_at, 1, 10) AS d FROM review_logs "
          'ORDER BY d DESC LIMIT 400',
        )
        .map((r) => r['d'] as String)
        .toSet();
    if (days.isEmpty) return 0;
    final today = DateTime.now();
    var streak = 0;
    for (var i = 0; i < 400; i++) {
      final day = today.subtract(Duration(days: i));
      if (days.contains(_dayKey(day))) {
        streak++;
      } else if (i == 0) {
        continue; // 今天还没复习：跳过，从昨天起算
      } else {
        break;
      }
    }
    return streak;
  }

  /// 热力图数据：近 N 天每日复习量（默认 84 天 = 12 周）
  List<Map<String, dynamic>> heatmapDays({int days = 84}) {
    final since = DateTime.now()
        .subtract(Duration(days: days))
        .toIso8601String();
    return _db
        .select(
          "SELECT substr(reviewed_at, 1, 10) AS day, COUNT(*) AS n "
          'FROM review_logs WHERE reviewed_at >= ? GROUP BY day',
          [since],
        )
        .map((r) => {'day': r['day'], 'reviews': r['n']})
        .toList();
  }

  /// 卡片当前调度状态（评分调度入口）
  CardMemoryState? memoryStateOf(String id) {
    final rows = _db.select(
      'SELECT m_state, m_due_at, m_last_review, m_stability, m_difficulty, '
      'm_reps, m_lapses FROM cards WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return CardMemoryState(
      state: SchedulingState.values.byName(row['m_state'] as String),
      dueAt: DateTime.parse(row['m_due_at'] as String),
      reps: row['m_reps'] as int,
      lapses: row['m_lapses'] as int,
      lastReviewedAt: row['m_last_review'] == null
          ? null
          : DateTime.tryParse(row['m_last_review'] as String),
      stability: row['m_stability'] == null
          ? null
          : (row['m_stability'] as double),
      difficulty: row['m_difficulty'] == null
          ? null
          : (row['m_difficulty'] as double),
    );
  }

  /// 应用调度结果（评分后写回调度状态）
  void applySchedule(String cardId, ScheduleResult result) {
    _db.execute(
      'UPDATE cards SET m_state = ?, m_due_at = ?, m_last_review = ?, '
      'm_stability = ?, m_difficulty = ?, m_reps = ?, m_lapses = ?, '
      "updated_at = datetime('now') WHERE id = ?",
      [
        result.state.name,
        result.dueAt.toIso8601String(),
        (result.lastReviewedAt ?? DateTime.now()).toIso8601String(),
        result.stability,
        result.difficulty,
        result.reps,
        result.lapses,
        cardId,
      ],
    );
  }

  // ---------------- review logs ----------------

  void insertReviewLog({
    required String cardId,
    required String subjectId,
    required ReviewRating rating,
    required DateTime reviewedAt,
    int? latencyMs,
    required bool offlineQueued,
    required SchedulingState stateBefore,
    required SchedulingState stateAfter,
    double? stabilityAfter,
    double? intervalDays,
  }) {
    _db.execute(
      'INSERT INTO review_logs (card_id, subject_id, rating, reviewed_at, '
      'latency_ms, offline_queued, state_before, state_after, stability_after, interval_days) '
      'VALUES (?,?,?,?,?,?,?,?,?,?)',
      [
        cardId,
        subjectId,
        rating.name,
        reviewedAt.toIso8601String(),
        latencyMs,
        offlineQueued ? 1 : 0,
        stateBefore.name,
        stateAfter.name,
        stabilityAfter,
        intervalDays,
      ],
    );
  }

  // ---------------- 行映射 ----------------

  static String _tagsToJson(List<String> tags) =>
      '[${tags.map((t) => '"$t"').join(',')}]';

  static List<String> _tagsFromJson(String json) {
    if (json == '[]' || json.isEmpty) return const [];
    return json
        .substring(1, json.length - 1)
        .split(',')
        .map((s) => s.trim().replaceAll('"', ''))
        .where((s) => s.isNotEmpty)
        .toList();
  }

  FlashCard _rowToCard(Row row) => FlashCard(
    id: row['id'] as String,
    subjectId: row['subject_id'] as String,
    type: CardType.values.byName(row['type'] as String),
    front: row['front'] as String,
    back: row['back'] as String,
    anchor: (row['anchor'] ?? '') as String,
    source: (row['source'] ?? '') as String,
    sourceTier: SourceTier.values.byName(
      (row['source_tier'] ?? 'ppt') as String,
    ),
    status: CardStatus.values.byName(row['status'] as String),
    tags: _tagsFromJson((row['tags'] ?? '[]') as String),
    examYear: row['exam_year'] as String?,
    createdAt: DateTime.tryParse((row['created_at'] ?? '') as String),
    updatedAt: DateTime.tryParse((row['updated_at'] ?? '') as String),
  );

  void close() => _db.dispose(); // sqlite3 2.x API（与 server 端一致）
}
