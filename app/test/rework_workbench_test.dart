import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/db.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'helpers/rework_fixture.dart';

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }
  final be = LocalBackend.instance;
  late Directory tmp;
  late Db db;
  late Database inspect;
  setUp(() async {
    await be.resetForTest();
    tmp = Directory.systemTemp.createTempSync('hengya-rework-workbench-');
    be.init(tmp.path);
    await be.post('/subjects', {'id': 'endo', 'name': '课程'});
    await be.importCards([
      {
        'id': 'parent',
        'subjectId': 'endo',
        'type': 'basic',
        'front': '原始题干',
        'back': '原始答案',
        'anchor': '旧出处',
        'source': '课程讲义',
        'status': 'pending',
        'tags': ['原标签'],
      },
    ]);
    await be.post('/cards/parent/approve', null);
    await be.post('/review/answer', {
      'cardId': 'parent',
      'rating': 'smooth',
      'reviewedAt': '2026-10-10T10:00:00',
    });
    db = await be.sharedDb;
    inspect = sqlite3.open('${tmp.path}/hengya.db');
  });
  tearDown(() async {
    inspect.dispose();
    await be.resetForTest();
    tmp.deleteSync(recursive: true);
  });
  List<Object?> memory([String id = 'parent']) => inspect
      .select(
        'SELECT m_state,m_due_at,m_last_review,m_stability,m_difficulty,m_reps,m_lapses FROM cards WHERE id=?',
        [id],
      )
      .single
      .values
      .toList();
  int logs() =>
      inspect.select('SELECT COUNT(*) n FROM review_logs').single['n'] as int;
  Future<int> create(
    String action, {
    String reason = '答案有误',
    String card = 'parent',
  }) async =>
      (await be.post('/rework/tasks', {
            'cardId': card,
            'action': action,
            'reasons': [reason],
            'targetCount': 2,
          }))['taskId']
          as int;
  Future<Map<String, dynamic>> draft(int id, {bool resolved = true}) async {
    var task = await be.get('/rework/tasks/$id');
    final file = File('${tmp.path}/corpus/corpus.db');
    file.parent.createSync(recursive: true);
    final corpus = sqlite3.open(file.path);
    seedReworkEvidence(corpus, id: 'e1');
    corpus.dispose();
    await be.post('/rework/tasks/$id/configure', {
      'revision': task['revision'],
      'action': task['action'],
      'targetCount': 2,
      'instructions': '按原文修复',
      'selectedIds': ['e1'],
    });
    task = await be.get('/rework/tasks/$id');
    final plan = validReworkDraft(
      task,
      cards: [
        for (var i = 0; i < (task['action'] == 'split' ? 2 : 1); i++)
          {
            'front': '新考点 $i',
            'back': '新答案 $i',
            'evidenceChunkIds': ['e1'],
          },
      ],
    );
    if (!resolved) {
      for (final r in plan['issueResults'] as List) {
        (r as Map)['resolved'] = false;
      }
    }
    await be.post('/rework/tasks/$id/draft', {
      'revision': task['revision'],
      'draft': plan,
    });
    return be.get('/rework/tasks/$id');
  }

  Future<Map<String, dynamic>> apply(
    int id,
    Map task, {
    bool reset = false,
    List<String>? confirmed,
  }) => be.post('/rework/tasks/$id/apply', {
    'revision': task['revision'],
    'resetMemory': reset,
    'confirmedIssues':
        confirmed ?? [for (final i in task['issues'] as List) (i as Map)['id']],
  });
  test('草案不覆盖原卡，保留原记忆与日志；确认后才改写', () async {
    final before = memory();
    final id = await create('rewrite');
    final task = await draft(id);
    expect(db.cardById('parent')!.front, '原始题干');
    expect(memory(), before);
    expect(logs(), 1);
    expect(task['status'], 'draft');
    expect(task['versions'] as List, hasLength(1));
    await apply(id, task);
    expect(db.cardById('parent')!.front, '新考点 0');
    expect(db.cardById('parent')!.status.name, 'active');
    expect(memory(), before);
    expect(logs(), 1);
    expect(
      ((await be.get('/rework/tasks/$id'))['original'] as Map)['front'],
      '原始题干',
    );
  });
  test('实质纠错可重学，记忆清零但历史日志保留', () async {
    final id = await create('rewrite');
    final task = await draft(id);
    await apply(id, task, reset: true);
    final m = db.memoryStateOf('parent')!;
    expect(m.state.name, 'newCard');
    expect(m.reps, 0);
    expect(m.stability, isNull);
    expect(m.difficulty, isNull);
    expect(logs(), 1);
  });
  test('一拆多原子应用，子卡独立新调度，原卡归档及历史保留，重复应用幂等', () async {
    final before = memory();
    final id = await create('split', reason: '拆太粗');
    final task = await draft(id);
    final result = await apply(id, task);
    final ids = (result['children'] as List).cast<String>();
    expect(ids, hasLength(2));
    expect(ids.toSet(), hasLength(2));
    expect(db.cardById('parent')!.status.name, 'archived');
    expect(memory(), before);
    expect(logs(), 1);
    for (final child in ids) {
      expect(db.memoryStateOf(child)!.reps, 0);
      expect(db.memoryStateOf(child)!.state.name, 'newCard');
      expect(db.cardById(child)!.tags, contains('原标签'));
    }
    expect((await apply(id, task))['alreadyApplied'], true);
    expect(inspect.select('SELECT COUNT(*) n FROM cards').single['n'], 3);
    expect(
      (await be.get('/rework/tasks/$id'))['children'] as List,
      hasLength(2),
    );
  });
  test('第二张子卡冲突时第一张也回滚，原卡不被停用', () async {
    final id = await create('split', reason: '拆太粗');
    final task = await draft(id);
    await be.importCards([
      {
        'id': 'parent-rw$id-2',
        'subjectId': 'endo',
        'type': 'basic',
        'front': '既有卡',
        'back': '已有内容',
        'anchor': 'p1',
        'source': '课程',
        'status': 'pending',
      },
    ]);
    await expectLater(
      apply(id, task),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
    );
    expect(db.cardById('parent-rw$id-1'), isNull);
    expect(db.cardById('parent-rw$id-2')!.front, '既有卡');
    expect(db.cardById('parent')!.status.name, 'rework');
    expect((await be.get('/rework/tasks/$id'))['status'], 'draft');
    expect(logs(), 1);
  });
  for (final action in ['defer', 'exclude']) {
    test('$action 无需证据或模型，必须明确确认，恢复后记忆不变', () async {
      final before = memory();
      final id = await create(
        action,
        reason: action == 'defer' ? '目前还没学到' : '超出教学范围',
      );
      var task = await be.get('/rework/tasks/$id');
      expect(db.reworkPending(), isEmpty);
      expect(File('${tmp.path}/corpus/corpus.db').existsSync(), false);
      await expectLater(
        be.post('/rework/tasks/$id/generate', {'revision': task['revision']}),
        throwsA(isA<ApiException>()),
      );
      await expectLater(
        apply(id, task, confirmed: []),
        throwsA(isA<ApiException>()),
      );
      await apply(id, task);
      expect(memory(), before);
      expect(logs(), 1);
      task = await be.get('/rework/tasks/$id');
      expect(task['status'], action == 'defer' ? 'deferred' : 'excluded');
      await be.post('/rework/tasks/$id/cancel', {'revision': task['revision']});
      expect(db.cardById('parent')!.status.name, 'active');
      expect(memory(), before);
    });
  }
  test('待审卡暂缓后恢复到待审，不自动获得审核通过权限', () async {
    await be.importCards([
      {
        'id': 'pending',
        'subjectId': 'endo',
        'type': 'basic',
        'front': '未审',
        'back': '未审答案',
        'anchor': 'p1',
        'source': '课程',
        'status': 'pending',
      },
    ]);
    final id = await create('defer', card: 'pending');
    var task = await be.get('/rework/tasks/$id');
    await apply(id, task);
    task = await be.get('/rework/tasks/$id');
    await be.post('/rework/tasks/$id/cancel', {'revision': task['revision']});
    expect(db.cardById('pending')!.status.name, 'pending');
  });
  test('旧生成结果不能覆盖新方案或恢复后的原卡', () async {
    final id = await create('rewrite');
    var task = await be.get('/rework/tasks/$id');
    final revision = task['revision'] as int;
    expect(db.claimReworkTask(id, revision), isNotNull);
    await be.post('/rework/tasks/$id/configure', {
      'revision': revision,
      'action': 'defer',
      'instructions': '改为暂缓',
      'targetCount': 2,
      'selectedIds': [],
    });
    expect(db.saveReworkEvidence(id, revision, []), false);
    expect(db.saveReworkDraft(id, revision, {}), false);
    expect(db.failReworkTask(id, revision, '迟到错误'), false);
    task = await be.get('/rework/tasks/$id');
    expect(task['action'], 'defer');
    expect(task['instructions'], '改为暂缓');
    expect(db.cardById('parent')!.front, '原始题干');
  });
  test('原文变化后拒绝应用旧草案，保留原卡与草案', () async {
    final id = await create('rewrite');
    final task = await draft(id);
    final corpus = sqlite3.open('${tmp.path}/corpus/corpus.db');
    corpus.execute("UPDATE chunks SET text='原文已变' WHERE chunk_id='e1'");
    corpus.dispose();
    await expectLater(
      apply(id, task),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
    );
    expect(db.cardById('parent')!.front, '原始题干');
    expect((await be.get('/rework/tasks/$id'))['status'], 'draft');
  });
  test('未解决理由不能靠应用时勾选绕过，旧 done 接口不可覆盖原卡', () async {
    final id = await create('rewrite');
    final task = await draft(id, resolved: false);
    expect(task['status'], 'needs_input');
    await expectLater(apply(id, task), throwsA(isA<ApiException>()));
    await expectLater(
      be.post('/cards/rework/$id/done', {'front': '绕过审核'}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
    );
    expect(db.cardById('parent')!.front, '原始题干');
  });
  test('异常中断作废旧版本；启动失败也有可见状态，不会永久排队', () async {
    final id = await create('rewrite');
    var task = await be.get('/rework/tasks/$id');
    final revision = task['revision'] as int;
    expect(db.claimReworkTask(id, revision), isNotNull);
    db.recoverInterruptedReworks();
    task = await be.get('/rework/tasks/$id');
    expect(task['status'], 'needs_input');
    expect(task['revision'], greaterThan(revision));
    expect(db.saveReworkEvidence(id, revision, []), false);
    await be.post('/rework/tasks/$id/configure', {
      'revision': task['revision'],
      'action': 'rewrite',
      'instructions': '重试',
      'targetCount': 2,
      'selectedIds': [],
    });
    task = await be.get('/rework/tasks/$id');
    expect(
      db.failReworkTask(
        id,
        task['revision'] as int,
        '启动失败',
        includeQueued: true,
      ),
      true,
    );
    expect((await be.get('/rework/tasks/$id'))['status'], 'needs_input');
    expect(db.reworkPending(), isEmpty);
  });
  test('原卡被其他操作改动后，不能用旧草案覆盖新内容', () async {
    final id = await create('rewrite');
    final t = await draft(id);
    inspect.execute("UPDATE cards SET front='外部新版本' WHERE id='parent'");
    await expectLater(
      apply(id, t),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409)),
    );
    expect(db.cardById('parent')!.front, '外部新版本');
    expect((await be.get('/rework/tasks/$id'))['status'], 'draft');
  });
  test('改写后的来源与引用一致，原来源保留在快照而非错误显示在新卡上',() async {
    final id=await create('rewrite');final t=await draft(id);await apply(id,t);
    final card=db.cardById('parent')!;
    expect(card.source,startsWith('回炉引用：'));expect(card.source,contains('回炉章 p30-32'));
    expect(card.sourceTier.name,'textbook');
    final snapshot=(await be.get('/rework/tasks/$id'))['original'] as Map;
    expect(snapshot['source'],'课程讲义');
  });
  test('拆分后引用来源更新，但原真题属性不被错误抹去',() async {
    inspect.execute("UPDATE cards SET source_tier='exam',exam_year='2025' WHERE id='parent'");
    final id=await create('split',reason:'拆太粗');final t=await draft(id);final result=await apply(id,t);
    for(final child in result['children'] as List){final card=db.cardById(child as String)!;
      expect(card.source,startsWith('回炉引用：'));expect(card.sourceTier.name,'exam');expect(card.examYear,'2025');}
    expect(db.cardById('parent')!.source,'课程讲义');
  });
  test('重复创建明确返回原任务，不默默覆盖已存在的方案',() async {
    final id=await create('rewrite');
    final again=await be.post('/rework/tasks',{'cardId':'parent','action':'exclude','reasons':['超出教学范围'],'instructions':'新填写但不应覆盖'});
    expect(again['taskId'],id);expect(again['alreadyExists'],true);
    final t=await be.get('/rework/tasks/$id');expect(t['action'],'rewrite');expect(t['instructions'],'');
    expect(db.listReworkTasks()['total'],1);
  });
  test('旧待办迁移遇到已插入的新版本时，不改变其队列状态或伪造迁移事件',() async {
    inspect.execute("UPDATE cards SET status='rejected' WHERE id='parent'");
    inspect.execute("INSERT INTO rework_queue(card_id,reason,note,status) VALUES ('parent','审核拒绝：超出教学范围','','pending')");
    final id=inspect.lastInsertRowId;
    // 模拟另一个连接先插入任务：外层 INSERT 没有插入任何行，changes()=0。
    inspect.execute('''CREATE TRIGGER simulate_migration_winner BEFORE INSERT ON rework_tasks WHEN NEW.id=$id BEGIN
      INSERT INTO rework_tasks(id,card_id,subject_id,action,status,revision,original_json,issues_json,instructions,created_at,updated_at)
      VALUES (NEW.id,NEW.card_id,NEW.subject_id,'rewrite','queued',9,NEW.original_json,NEW.issues_json,'新版本方案',NEW.created_at,NEW.updated_at);
      SELECT RAISE(IGNORE);
    END;''');
    db.adoptLegacyRework();
    final t=db.getReworkTask(id)!;expect(t['revision'],9);expect(t['action'],'rewrite');
    expect(inspect.select('SELECT status FROM rework_queue WHERE id=?',[id]).single['status'],'pending');
    expect(inspect.select('SELECT COUNT(*) n FROM rework_events WHERE task_id=?',[id]).single['n'],0);
  });
  test('参数类型错误返回可处理的400，不截断数量或抛出未处理的类型异常',() async {
    for(final body in [
      {'cardId':'parent','action':'split','reasons':['拆太粗'],'targetCount':2.5},
      {'cardId':'parent','action':'rewrite','reasons':'答案有误'},
      {'cardId':'parent','action':'rewrite','reasons':[123]},
    ]) {
      await expectLater(be.post('/rework/tasks',body),throwsA(isA<ApiException>().having((e)=>e.statusCode,'status',400)));
    }
    expect(db.listReworkTasks()['total'],0);expect(db.cardById('parent')!.status.name,'active');
  });

}
