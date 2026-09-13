// 新建课程全生命周期 E2E（#7，2026-09-13）：一镜到底验证「新科目像已有
// 课程一样正常工作」——创建（含黑名单/非法短码/重名重码守卫）→ 立即可用
// → 收件箱关键词入箱 → 导卡→批准→评分→统计 bySubject → 题库检索命中
// → 罗盘 404 守卫（无教材树）→ 复习队列空态 → 导出往返新科目数据完整。
//
// 与 e2e_local_journey_test.dart 互补：那份旅程第④步创建的新科目之后零
// 使用（审计确认的最大测试盲区），本文件专测新科目自身的主链路连续性。
//
// 宿主基建：同 e2e_local_journey_test——Windows 显式加载 test/sqlite3.dll；
// AI key 注入 InMemoryVault。
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/ai_key_vault.dart';
import 'package:hengya/services/local/data_manager.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
        () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  late Directory tmp;
  final be = LocalBackend.instance;
  final dm = DataManager.instance;

  setUp(() async {
    AiKeyVault.instance = InMemoryVault();
    tmp = await Directory.systemTemp.createTemp('hengya_new_subject_');
    await be.resetForTest();
    be.init(tmp.path);
  });

  tearDown(() async {
    AiKeyVault.instance = null;
    await be.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('新建课程守卫矩阵：黑名单/非法短码 400、重码/重名 409、自动短码、立即可用', () async {
    // 正常手填短码
    final ok = await be.post('/subjects', {'name': '口腔解剖生理学', 'id': 'anatomy2'});
    expect(ok['ok'], true);
    expect(ok['id'], 'anatomy2');

    // 保留短码黑名单（#7）：真题树 exam / 大纲占位 med / 大纲上传 dagang /
    // 考站专题码 shijuan —— 全部 400 拒绝
    for (final reserved in ['exam', 'med', 'dagang', 'shijuan']) {
      await expectLater(
        be.post('/subjects', {'name': '保留字课程 $reserved', 'id': reserved}),
        throwsA(isA<ApiException>()
            .having((e) => e.statusCode, 'status', 400)
            .having((e) => e.message, 'message', contains('系统保留'))),
        reason: '保留短码 $reserved 必须被拒绝',
      );
    }

    // 非法短码（大写/连字符/超长）→ 400 逐字
    await expectLater(
      be.post('/subjects', {'name': 'X', 'id': 'BadCode'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 400)
          .having((e) => e.message, 'message', contains('非法'))),
    );
    await expectLater(
      be.post('/subjects', {'name': 'X', 'id': 'has-dash'}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 400)),
    );

    // 重码 / 重名 → 409
    await expectLater(
      be.post('/subjects', {'name': '另一门课', 'id': 'anatomy2'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 409)
          .having((e) => e.message, 'message', contains('短码'))),
    );
    await expectLater(
      be.post('/subjects', {'name': '口腔解剖生理学'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 409)
          .having((e) => e.message, 'message', contains('已存在'))),
    );

    // 自动短码：留空生成合法短码且唯一
    final auto = await be.post('/subjects', {'name': '自动短码课'});
    expect((auto['id'] as String), matches(RegExp(r'^[a-z0-9]{2,16}$')));

    // 立即可用：科目列表含全部新科目，dueCount 均为 0
    final subs = await be.get('/subjects');
    final list = (subs['subjects'] as List).cast<Map<String, dynamic>>();
    expect(list.map((s) => s['id']), containsAll(['anatomy2', auto['id']]));
    expect(list.every((s) => s['dueCount'] == 0), true);
  });

  test('新科目全链路：关键词入箱 → 导卡→批准→评分→统计→题库检索 → 罗盘 404 → 复习队列空态', () async {
    // ① 创建（自动短码——最常见路径）
    final created = await be.post('/subjects', {'name': '口腔内科学'});
    final sid = created['id'] as String;

    // ② 收件箱关键词入箱（subjectExists 守卫对新科目通过）
    final kw = await be.post('/inbox/keywords', {
      'subjectId': sid,
      'keyword': '龋病四联因素',
    });
    expect(kw['ok'], true, reason: '新科目关键词必须能入箱');
    final inbox = await be.get('/inbox/pending');
    expect(
      ((inbox as Map)['list'] as List).where(
        (k) => (k as Map)['subjectId'] == sid,
      ),
      isNotEmpty,
    );

    // ③ 导入新科目的待审卡（importCards 的 subjectExists 守卫通过）
    final imp = await LocalBackend.instance.importCards([
      {
        'id': '$sid-life-001',
        'subjectId': sid,
        'type': 'basic',
        'front': '新科目测试卡题干：龋病四联因素是哪四个？',
        'back': '细菌、食物、宿主、时间。',
        'anchor': '新科目 1.1 PPT',
        'source': '口腔内科学 PPT',
        'status': 'pending',
      },
    ]);
    expect(imp['inserted'], 1, reason: '新科目的卡必须能入库');

    // ④ 批准 → active → 评分 → 统计 bySubject 出现新科目
    final approved = await be.post('/cards/$sid-life-001/approve', null);
    expect((approved as Map)['ok'], true);
    final due = await be.get('/cards/queue?subject=$sid');
    expect(((due as Map)['cards'] as List), isNotEmpty,
        reason: '批准后新科目卡进复习队列');
    final ans = await be.post('/review/answer', {
      'cardId': '$sid-life-001',
      'subjectId': sid,
      'rating': 'good',
    });
    expect((ans as Map)['ok'] ?? ans['applied'] != null, true);
    final summary = await be.get('/stats/summary');
    expect(
      ((summary as Map)['bySubject'] as List)
          .map((r) => (r as Map)['subjectId']),
      contains(sid),
      reason: '统计 bySubject 必须出现新科目',
    );

    // ⑤ 题库检索命中新科目卡
    final bank = await be.get('/cards/search?subject=$sid');
    final bankList = ((bank as Map)['cards'] as List?) ?? (bank['list'] as List? ?? []);
    expect(bankList, isNotEmpty, reason: '题库必须能检索到新科目卡');

    // ⑥ 罗盘 404 守卫：无教材树的新科目不在进度库——章节管理 404（文案
    // 不带内部 id），主 /progress 不渲染该科目（设计：不进罗盘）
    await expectLater(
      be.put('/progress/$sid/chapters', {'learned_through': 1}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'status', 404)
          .having((e) => e.message, 'message', contains('不在进度库'))),
    );
    final progress = await be.get('/progress');
    expect(
      (progress['subjects'] as List).where((s) => (s as Map)['id'] == sid),
      isEmpty,
      reason: '无罗盘条目的新科目不进学习罗盘（设计使然）',
    );

    // ⑦ 收件箱条目消费守卫：未拆卡前关键词仍在池中（consumed_at 空）
    final inboxAfter = await be.get('/inbox/pending');
    final kwRow = ((inboxAfter as Map)['list'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((k) => k['subjectId'] == sid);
    expect(kwRow['consumedAt'] ?? kwRow['consumed_at'], anyOf(isNull, ''),
        reason: '未跑拆卡前关键词不消费');
  });

  test('导出往返：新科目（科目行/卡/收件箱关键词）随主库迁移完整', () async {
    final created = await be.post('/subjects', {'name': '口腔预防医学', 'id': 'prevent2'});
    final sid = created['id'] as String;
    await be.post('/inbox/keywords', {'subjectId': sid, 'keyword': '窝沟封闭时机'});
    await LocalBackend.instance.importCards([
      {
        'id': '$sid-life-002',
        'subjectId': sid,
        'type': 'basic',
        'front': '窝沟封闭的最佳时机是什么？',
        'back': '牙面完全萌出且龋齿未发生时（第一磨牙 6-8 岁）。',
        'anchor': '口腔预防医学 PPT',
        'source': '口腔预防医学 PPT',
        'status': 'pending',
      },
    ]);
    // 批准（题库检索不显示 pending 卡——质量闸门；active 才可被检索断言）
    await be.post('/cards/$sid-life-002/approve', null);

    // 导出 → 换目录导入 → 新科目数据完整
    final out = dm.exportDatabase(tmp.path);
    expect(File(out).existsSync(), true);
    final tmp2 = await Directory.systemTemp.createTemp('hengya_new_subject_restore_');
    addTearDown(() async {
      try {
        await tmp2.delete(recursive: true);
      } catch (_) {}
    });
    await dm.importDatabase(tmp2.path, out);
    await be.resetForTest();
    be.init(tmp2.path);

    final subs = await be.get('/subjects');
    expect((subs['subjects'] as List).map((s) => (s as Map)['id']), contains(sid));
    final bank = await be.get('/cards/search?subject=$sid');
    final bankList = ((bank as Map)['cards'] as List?) ?? (bank['list'] as List? ?? []);
    expect(bankList.map((c) => (c as Map)['id']), contains('$sid-life-002'),
        reason: '新科目卡必须随主库迁移');
    final inbox = await be.get('/inbox/pending');
    expect(
      ((inbox as Map)['list'] as List).where(
        (k) => (k as Map)['subjectId'] == sid,
      ),
      isNotEmpty,
      reason: '新科目收件箱关键词必须随主库迁移',
    );
  });
}
