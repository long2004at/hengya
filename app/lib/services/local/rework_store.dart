part of 'db.dart';

void ensureReworkTables(Database db) {
  db.execute('''CREATE TABLE IF NOT EXISTS rework_tasks (
    id INTEGER PRIMARY KEY, card_id TEXT NOT NULL, subject_id TEXT NOT NULL,
    action TEXT NOT NULL, status TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1,
    original_json TEXT NOT NULL, issues_json TEXT NOT NULL, instructions TEXT NOT NULL DEFAULT '',
    target_count INTEGER NOT NULL DEFAULT 2, selected_ids_json TEXT NOT NULL DEFAULT '[]',
    evidence_json TEXT NOT NULL DEFAULT '[]', draft_json TEXT,
    stage TEXT NOT NULL DEFAULT 'queued', error TEXT NOT NULL DEFAULT '', attempts INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL
  )''');
  db.execute(
    'CREATE INDEX IF NOT EXISTS idx_rework_task_card ON rework_tasks(card_id,status)',
  );
  db.execute('''CREATE TABLE IF NOT EXISTS rework_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT, task_id INTEGER NOT NULL, revision INTEGER NOT NULL,
    event TEXT NOT NULL, detail TEXT NOT NULL, created_at TEXT NOT NULL
  )''');
  db.execute('''CREATE TABLE IF NOT EXISTS rework_versions (
    task_id INTEGER NOT NULL, revision INTEGER NOT NULL, draft_json TEXT NOT NULL,
    evidence_json TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY(task_id,revision)
  )''');
  db.execute('''CREATE TABLE IF NOT EXISTS rework_card_links (
    task_id INTEGER NOT NULL, parent_id TEXT NOT NULL, child_id TEXT NOT NULL,
    PRIMARY KEY(task_id,child_id)
  )''');
}

extension ReworkWorkbenchStore on Db {
  String _workNow() => DateTime.now().toIso8601String();
  Map<String, Object?> _workOriginal(String id) {
    final rows = _db.select('SELECT * FROM cards WHERE id=?', [id]);
    if (rows.isEmpty) throw StateError('原卡已不存在');
    return Map<String, Object?>.from(rows.first);
  }

  List<Map<String, Object?>> _workList(Object? raw) => [
    for (final e in jsonDecode(raw as String) as List)
      Map<String, Object?>.from(e as Map),
  ];
  Map<String, Object?> _workMap(Row row) {
    final id = row['id'] as int;
    return {
      'id': id,
      'cardId': row['card_id'],
      'subjectId': row['subject_id'],
      'action': row['action'],
      'status': row['status'],
      'revision': row['revision'],
      'original': jsonDecode(row['original_json'] as String),
      'issues': jsonDecode(row['issues_json'] as String),
      'instructions': row['instructions'],
      'targetCount': row['target_count'],
      'selectedIds': jsonDecode(row['selected_ids_json'] as String),
      'evidence': jsonDecode(row['evidence_json'] as String),
      'draft': row['draft_json'] == null
          ? null
          : jsonDecode(row['draft_json'] as String),
      'stage': row['stage'],
      'error': row['error'],
      'attempts': row['attempts'],
      'createdAt': row['created_at'],
      'updatedAt': row['updated_at'],
      'children': [
        for (final r in _db.select(
          'SELECT child_id FROM rework_card_links WHERE task_id=? ORDER BY child_id',
          [id],
        ))
          r['child_id'],
      ],
    };
  }

  Row _workRow(int id, int revision, {Set<String>? allowed}) {
    final rows = _db.select('SELECT * FROM rework_tasks WHERE id=?', [id]);
    if (rows.isEmpty) throw StateError('回炉任务不存在');
    final row = rows.single;
    if (row['revision'] != revision) throw StateError('任务已更新，请刷新后重试');
    if (allowed != null && !allowed.contains(row['status'])) {
      throw StateError('当前任务状态不允许此操作');
    }
    return row;
  }

  void _workEvent(int id, int revision, String event, String detail) {
    _db.execute(
      'INSERT INTO rework_events(task_id,revision,event,detail,created_at) VALUES (?,?,?,?,?)',
      [id, revision, event, detail, _workNow()],
    );
  }

  int? activeReworkTask(String cardId) {
    final rows = _db.select(
      "SELECT id FROM rework_tasks WHERE card_id=? AND status NOT IN ('applied','cancelled') ORDER BY id DESC LIMIT 1",
      [cardId],
    );
    return rows.isEmpty ? null : rows.single['id'] as int;
  }

  int createReworkTask(
    String cardId, {
    required String action,
    required List<String> reasons,
    String instructions = '',
    int targetCount = 2,
  }) {
    if (!reworkActions.contains(action) ||
        targetCount < 2 ||
        targetCount > 5 ||
        reasons.isEmpty ||
        reasons.length > 8 ||
        reasons.any((s) => s.trim().isEmpty || s.length > 256) ||
        instructions.length > 4000) {
      throw ArgumentError('回炉方案参数无效');
    }
    var id = 0;
    _tx(() {
      final old = activeReworkTask(cardId);
      if (old != null) {
        id = old;
        return;
      }
      final original = _workOriginal(cardId);
      if (original['status'] != 'active' && original['status'] != 'pending') {
        throw StateError('仅在学卡和待审核卡可创建修复任务');
      }
      final reason = reasons.toSet().join('、');
      final fromPending = original['status'] == 'pending';
      _db.execute(
        'INSERT INTO rework_queue(card_id,reason,note,status) VALUES (?,?,?,?)',
        [
          cardId,
          fromPending ? '审核拒绝：$reason' : reason,
          instructions,
          (action == 'rewrite' || action == 'split') ? 'pending' : 'held',
        ],
      );
      id = _db.lastInsertRowId;
      _db.execute(
        'INSERT INTO rework_tasks(id,card_id,subject_id,action,status,original_json,issues_json,instructions,target_count,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)',
        [
          id,
          cardId,
          original['subject_id'],
          action,
          (action == 'rewrite' || action == 'split') ? 'queued' : 'needs_input',
          jsonEncode(original),
          jsonEncode(reworkIssues(reason)),
          instructions,
          targetCount,
          _workNow(),
          _workNow(),
        ],
      );
      _db.execute(
        "UPDATE cards SET status=?,updated_at=datetime('now') WHERE id=?",
        [fromPending ? 'rejected' : 'rework', cardId],
      );
      _workEvent(id, 1, 'created', '已保留原卡快照；处理动作：${reworkActionLabel(action)}');
      bumpDataVersion();
    });
    return id;
  }

  /// 旧待办只做一次迁移；不能伪造已经被历史覆盖的原始版本。
  void adoptLegacyRework() {
    final rows = _db.select(
      "SELECT q.* FROM rework_queue q WHERE q.status='pending' AND NOT EXISTS(SELECT 1 FROM rework_tasks t WHERE t.id=q.id)",
    );
    for (final r in rows) {
      final cards = _db.select('SELECT * FROM cards WHERE id=?', [
        r['card_id'],
      ]);
      if (cards.isEmpty) continue;
      final original = Map<String, Object?>.from(cards.single);
      original['status'] = (r['reason'] as String).startsWith('审核拒绝：')
          ? 'pending'
          : 'active';
      final action = suggestReworkAction(r['reason'] as String);
      final status = (action == 'rewrite' || action == 'split')
          ? 'queued'
          : 'needs_input';
      _tx(() {
        _db.execute(
          'INSERT OR IGNORE INTO rework_tasks(id,card_id,subject_id,action,status,original_json,issues_json,instructions,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?)',
          [
            r['id'],
            r['card_id'],
            original['subject_id'],
            action,
            status,
            jsonEncode(original),
            jsonEncode(reworkIssues(r['reason'] as String)),
            r['note'],
            r['created_at'],
            _workNow(),
          ],
        );
        // 另一连接可能已完成迁移；此时不能覆盖其后续状态或重复写迁移事件。
        if ((_db.select('SELECT changes() n').single['n'] as int) == 0) return;
        if (status != 'queued') {
          _db.execute("UPDATE rework_queue SET status='held' WHERE id=?", [
            r['id'],
          ]);
        }
        _workEvent(r['id'] as int, 1, 'migrated', '历史待办按当前卡片建立快照；未自动生成或应用');
      });
    }
  }

  Map<String, Object?> listReworkTasks({
    int offset = 0,
    int limit = 40,
    String status = '',
  }) {
    if (offset < 0 || limit < 1 || limit > 200) throw ArgumentError('分页参数无效');
    final where = status == 'open'
        ? "status NOT IN ('applied','cancelled','deferred','excluded')"
        : status.isEmpty
        ? '1=1'
        : 'status=?';
    final args = <Object?>[if (status.isNotEmpty && status != 'open') status];
    final total = _db
        .select('SELECT COUNT(*) n FROM rework_tasks WHERE $where', args)
        .single['n'];
    final rows = _db.select(
      'SELECT * FROM rework_tasks WHERE $where ORDER BY updated_at DESC,id DESC LIMIT ? OFFSET ?',
      [...args, limit, offset],
    );
    return {
      'total': total,
      'tasks': [for (final r in rows) _workMap(r)],
    };
  }

  Map<String, Object?>? getReworkTask(int id) {
    final rows = _db.select('SELECT * FROM rework_tasks WHERE id=?', [id]);
    if (rows.isEmpty) return null;
    return {
      ..._workMap(rows.single),
      'events': [
        for (final r in _db.select(
          'SELECT * FROM rework_events WHERE task_id=? ORDER BY id',
          [id],
        ))
          Map<String, Object?>.from(r),
      ],
      'versions': [
        for (final r in _db.select(
          'SELECT revision,draft_json,evidence_json,created_at FROM rework_versions WHERE task_id=? ORDER BY revision DESC',
          [id],
        ))
          {
            'revision': r['revision'],
            'draft': jsonDecode(r['draft_json'] as String),
            'evidence': jsonDecode(r['evidence_json'] as String),
            'createdAt': r['created_at'],
          },
      ],
    };
  }

  void configureRework(
    int id,
    int revision, {
    required String action,
    required String instructions,
    required int targetCount,
    required List<Map<String, Object?>> selected,
  }) {
    if (!reworkActions.contains(action) ||
        instructions.length > 4000 ||
        targetCount < 2 ||
        targetCount > 5 ||
        selected.length > 12) {
      throw ArgumentError('回炉方案参数无效');
    }
    _tx(() {
      _workRow(
        id,
        revision,
        allowed: {'queued', 'generating', 'needs_input', 'draft'},
      );
      final status = action == 'rewrite' || action == 'split'
          ? 'queued'
          : 'needs_input';
      _db.execute(
        'UPDATE rework_tasks SET action=?,instructions=?,target_count=?,selected_ids_json=?,evidence_json=?,draft_json=NULL,status=?,stage=?,error=\'\',revision=revision+1,updated_at=? WHERE id=?',
        [
          action,
          instructions,
          targetCount,
          jsonEncode([for (final e in selected) e['chunkId']]),
          jsonEncode(selected),
          status,
          status,
          _workNow(),
          id,
        ],
      );
      _db.execute('UPDATE rework_queue SET status=? WHERE id=?', [
        status == 'queued' ? 'pending' : 'held',
        id,
      ]);
      _workEvent(id, revision + 1, 'configured', '用户更新方案 / 指定证据；旧结果已失效');
      bumpDataVersion();
    });
  }

  Map<String, Object?>? claimReworkTask(int id, int revision) {
    Map<String, Object?>? claimed;
    _tx(() {
      final rows = _db.select(
        "SELECT * FROM rework_tasks WHERE id=? AND revision=? AND status='queued'",
        [id, revision],
      );
      if (rows.isEmpty) return;
      if (!['rewrite', 'split'].contains(rows.single['action'])) return;
      _db.execute(
        "UPDATE rework_tasks SET status='generating',stage='evidence',error='',attempts=attempts+1,updated_at=? WHERE id=?",
        [_workNow(), id],
      );
      _workEvent(id, revision, 'evidence', '正在检索并组装证据');
      claimed = _workMap(
        _db.select('SELECT * FROM rework_tasks WHERE id=?', [id]).single,
      );
    });
    return claimed;
  }

  bool saveReworkEvidence(
    int id,
    int revision,
    List<Map<String, Object?>> evidence,
  ) {
    var ok = false;
    _tx(() {
      if (_db.select(
        "SELECT 1 FROM rework_tasks WHERE id=? AND revision=? AND status='generating'",
        [id, revision],
      ).isEmpty) {
        return;
      }
      _db.execute(
        "UPDATE rework_tasks SET evidence_json=?,stage='generation',updated_at=? WHERE id=?",
        [jsonEncode(evidence), _workNow(), id],
      );
      _workEvent(
        id,
        revision,
        'generation',
        '采用 ${evidence.length} 条证据，等待生成结构化草案',
      );
      ok = true;
    });
    return ok;
  }

  bool failReworkTask(
    int id,
    int revision,
    String error, {
    bool includeQueued = false,
  }) {
    var ok = false;
    _tx(() {
      if (_db.select(
        "SELECT 1 FROM rework_tasks WHERE id=? AND revision=? AND status IN ('generating', ?)",
        [id, revision, includeQueued ? 'queued' : 'generating'],
      ).isEmpty) {
        return;
      }
      _db.execute(
        "UPDATE rework_tasks SET status='needs_input',stage='needs_input',error=?,updated_at=? WHERE id=?",
        [
          error.length > 2000 ? error.substring(0, 2000) : error,
          _workNow(),
          id,
        ],
      );
      _db.execute("UPDATE rework_queue SET status='held' WHERE id=?", [id]);
      _workEvent(
        id,
        revision,
        'needs_input',
        error.length > 2000 ? error.substring(0, 2000) : error,
      );
      ok = true;
    });
    return ok;
  }

  bool saveReworkDraft(int id, int revision, Map raw, {bool manual = false}) {
    var ok = false;
    _tx(() {
      final rows = _db.select(
        'SELECT * FROM rework_tasks WHERE id=? AND revision=?',
        [id, revision],
      );
      if (rows.isEmpty) return;
      final row = rows.single;
      if (!(manual
              ? {'queued', 'generating', 'needs_input', 'draft'}
              : {'generating'})
          .contains(row['status'])) {
        return;
      }
      final evidence = _workList(row['evidence_json']);
      final issues = _workList(row['issues_json']);
      final draft = validateReworkDraft(
        raw: raw,
        action: row['action'] as String,
        targetCount: row['target_count'] as int,
        original: jsonDecode(row['original_json'] as String) as Map,
        evidence: evidence,
        issues: issues,
      );
      final ready = (draft['issueResults'] as List).every(
        (e) => (e as Map)['resolved'] == true,
      );
      final next = revision + 1;
      _db.execute(
        'INSERT INTO rework_versions(task_id,revision,draft_json,evidence_json,created_at) VALUES (?,?,?,?,?)',
        [id, next, jsonEncode(draft), jsonEncode(evidence), _workNow()],
      );
      _db.execute(
        'UPDATE rework_tasks SET draft_json=?,status=?,stage=?,error=?,revision=?,updated_at=? WHERE id=?',
        [
          jsonEncode(draft),
          ready ? 'draft' : 'needs_input',
          ready ? 'review' : 'needs_input',
          ready ? '' : '仍有未解决的理由，请补充证据或人工修订',
          next,
          _workNow(),
          id,
        ],
      );
      _db.execute("UPDATE rework_queue SET status='draft' WHERE id=?", [id]);
      _workEvent(
        id,
        next,
        manual ? 'manual_draft' : 'draft',
        '草案已保存，未修改原卡；${ready ? '等待人工确认' : '仍需补充信息'}',
      );
      bumpDataVersion();
      ok = true;
    });
    return ok;
  }

  void recoverInterruptedReworks() {
    final rows = _db.select(
      "SELECT id,revision FROM rework_tasks WHERE status='generating'",
    );
    for (final r in rows) {
      _tx(() {
        _db.execute(
          "UPDATE rework_tasks SET status='needs_input',stage='needs_input',error='上次生成被中断，请检查后重新生成',revision=revision+1,updated_at=? WHERE id=?",
          [_workNow(), r['id']],
        );
        _db.execute("UPDATE rework_queue SET status='held' WHERE id=?", [
          r['id'],
        ]);
        _workEvent(
          r['id'] as int,
          (r['revision'] as int) + 1,
          'interrupted',
          '生成中断；过期响应已作废',
        );
      });
    }
  }

  void _assertReworkOriginal(Row task) {
    final original = jsonDecode(task['original_json'] as String) as Map;
    final current = _workOriginal(task['card_id'] as String);
    final expected = task['status'] == 'excluded'
        ? 'archived'
        : task['status'] == 'deferred'
        ? 'rework'
        : original['status'] == 'pending'
        ? 'rejected'
        : 'rework';
    if (current['status'] != expected) throw StateError('原卡状态已变化，请重新检查任务');
    for (final field in [
      'subject_id',
      'front',
      'back',
      'anchor',
      'source',
      'type',
    ]) {
      if (current[field] != original[field]) {
        throw StateError('原卡内容已变化，不能应用旧草案');
      }
    }
  }

  Map<String, Object?> applyReworkTask(
    int id,
    int revision, {
    required bool resetMemory,
    required List<String> confirmedIssues,
  }) {
    var result = <String, Object?>{};
    _tx(() {
      final any = _db.select('SELECT * FROM rework_tasks WHERE id=?', [id]);
      if (any.isEmpty) throw StateError('任务不存在');
      if ({'applied', 'deferred', 'excluded'}.contains(any.single['status'])) {
        result = {'ok': true, 'alreadyApplied': true};
        return;
      }
      final task = _workRow(
        id,
        revision,
        allowed: {'draft', 'needs_input', 'queued'},
      );
      _assertReworkOriginal(task);
      final issues = _workList(task['issues_json']);
      if (!issues.every((i) => confirmedIssues.contains(i['id']))) {
        throw StateError('请逐项确认拒绝理由已得到处理');
      }
      final action = task['action'] as String;
      final parent = task['card_id'] as String;
      final original = jsonDecode(task['original_json'] as String) as Map;
      var status = 'applied';
      final children = <String>[];
      if (action == 'defer' || action == 'exclude') {
        status = action == 'defer' ? 'deferred' : 'excluded';
        _db.execute(
          "UPDATE cards SET status=?,updated_at=datetime('now') WHERE id=?",
          [action == 'defer' ? 'rework' : 'archived', parent],
        );
      } else {
        if (task['status'] != 'draft' || task['draft_json'] == null) {
          throw StateError('尚无可应用的草案');
        }
        final plan = validateReworkDraft(
          raw: jsonDecode(task['draft_json'] as String) as Map,
          action: action,
          targetCount: task['target_count'] as int,
          original: original,
          evidence: _workList(task['evidence_json']),
          issues: issues,
        );
        if (!(plan['issueResults'] as List).every(
          (e) => (e as Map)['resolved'] == true,
        )) {
          throw StateError('草案仍有未解决理由');
        }
        final cards = (plan['cards'] as List).cast<Map>();
        if (action == 'rewrite') {
          final card = cards.single;
          _db.execute(
            "UPDATE cards SET front=?,back=?,anchor=?,source=?,source_tier=?,status='active',updated_at=datetime('now') WHERE id=?",
            [
              card['front'],
              card['back'],
              card['anchor'],
              card['source'],
              original['source_tier'] == 'exam' ? 'exam' : card['sourceTier'],
              parent,
            ],
          );
          if (resetMemory || original['status'] != 'active') {
            _db.execute(
              "UPDATE cards SET m_state='newCard',m_due_at=?,m_last_review=NULL,m_stability=NULL,m_difficulty=NULL,m_reps=0,m_lapses=0 WHERE id=?",
              [_workNow(), parent],
            );
          }
          if (card['front'] != original['front']) {
            _db.execute('DELETE FROM card_vectors WHERE card_id=?', [parent]);
          }
          children.add(parent);
        } else {
          for (var i = 0; i < cards.length; i++) {
            final card = cards[i];
            final child = '$parent-rw$id-${i + 1}';
            final newCard = FlashCard(
              id: child,
              subjectId: task['subject_id'] as String,
              type: CardType.basic,
              front: card['front'] as String,
              back: card['back'] as String,
              anchor: card['anchor'] as String,
              source: card['source'] as String,
              status: CardStatus.active,
              tags: Db._tagsFromJson(original['tags']?.toString() ?? '[]'),
              examYear: original['exam_year']?.toString(),
              sourceTier: SourceTier.values.firstWhere(
                (s) =>
                    s.name ==
                    (original['source_tier'] == 'exam'
                        ? 'exam'
                        : card['sourceTier']),
                orElse: () => SourceTier.ppt,
              ),
            );
            if (!importCard(newCard)) throw StateError('子卡编号冲突，已撤销整次应用');
            _db.execute('INSERT INTO rework_card_links VALUES (?,?,?)', [
              id,
              parent,
              child,
            ]);
            children.add(child);
          }
          _db.execute(
            "UPDATE cards SET status='archived',updated_at=datetime('now') WHERE id=?",
            [parent],
          );
        }
      }
      _db.execute(
        'UPDATE rework_tasks SET status=?,stage=?,revision=revision+1,updated_at=? WHERE id=?',
        [status, status, _workNow(), id],
      );
      _db.execute('UPDATE rework_queue SET status=? WHERE id=?', [
        action == 'defer' ? 'paused' : 'done',
        id,
      ]);
      _workEvent(
        id,
        revision + 1,
        status,
        '用户确认应用；${reworkActionLabel(action)}。原卡历史与语料保留',
      );
      bumpDataVersion();
      result = {'ok': true, 'status': status, 'children': children};
    });
    return result;
  }

  void cancelReworkTask(int id, int revision) {
    _tx(() {
      final task = _workRow(
        id,
        revision,
        allowed: {
          'queued',
          'generating',
          'needs_input',
          'draft',
          'deferred',
          'excluded',
        },
      );
      _assertReworkOriginal(task);
      final original = jsonDecode(task['original_json'] as String) as Map;
      _db.execute(
        "UPDATE cards SET status=?,updated_at=datetime('now') WHERE id=?",
        [original['status'], task['card_id']],
      );
      _db.execute(
        "UPDATE rework_tasks SET status='cancelled',stage='cancelled',revision=revision+1,updated_at=? WHERE id=?",
        [_workNow(), id],
      );
      _db.execute("UPDATE rework_queue SET status='cancelled' WHERE id=?", [
        id,
      ]);
      _workEvent(id, revision + 1, 'cancelled', '用户撤销任务 / 恢复原卡；未更改原记忆状态');
      bumpDataVersion();
    });
  }

  List<Map<String, dynamic>> queuedReworkTasks({int? onlyId, int limit = 50}) {
    final rows = _db.select(
      "SELECT * FROM rework_tasks WHERE status='queued' AND action IN ('rewrite','split') ${onlyId == null ? '' : 'AND id=?'} ORDER BY id LIMIT ?",
      [?onlyId, limit],
    );
    return [
      for (final row in rows)
        {
          ..._workMap(row),
          'taskRevision': row['revision'],
          'cardId': row['card_id'],
          'front': (jsonDecode(row['original_json'] as String) as Map)['front'],
          'back': (jsonDecode(row['original_json'] as String) as Map)['back'],
          'anchor':
              (jsonDecode(row['original_json'] as String) as Map)['anchor'],
          'reason': _workList(
            row['issues_json'],
          ).map((i) => i['label']).join('、'),
          'note': row['instructions'],
        },
    ];
  }
}
