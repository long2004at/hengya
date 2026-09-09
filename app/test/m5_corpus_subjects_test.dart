// M5 知识库 + 动态科目测试：
// CorpusStatus/UploadResult 解析 · 演示后端语料状态与上传计数 ·
// 新建科目（自动短码/重复 409/名称必填）· 展示名缓存链（库名 → 原样 id）
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/api/demo_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ---------------- CorpusStatus / CorpusUploadResult 解析 ----------------

  test('CorpusStatus.fromJson：全字段解析（含科目分布与构建时间）', () {
    final s = CorpusStatus.fromJson({
      'totalChunks': 42,
      'subjects': {'oms': 18, 'endo': 24},
      'lastBuild': '2026-09-01T22:55:00',
      'pendingFiles': 2,
      'storageMB': 3.2,
    });
    expect(s.totalChunks, 42);
    expect(s.subjects['endo'], 24);
    expect(s.lastBuild, DateTime.parse('2026-09-01T22:55:00'));
    expect(s.pendingFiles, 2);
    expect(s.storageMB, 3.2);
    // 展示行：按 nameOf 渲染科目分布（identity 直出即原始 id）
    expect(
      s.subjectLine((id) => id),
      'oms 18 · endo 24',
    );
  });

  test('CorpusStatus.fromJson：空态/缺字段（lastBuild null、无 subjects）', () {
    final s = CorpusStatus.fromJson({'totalChunks': 0, 'pendingFiles': 0});
    expect(s.subjects, isEmpty);
    expect(s.lastBuild, isNull);
    expect(s.subjectLine((id) => id), '');
    expect(s.reworkPending, 0, reason: '⑦ 旧服务端无 reworkPending 字段 → 回退 0');
  });

  test('CorpusUploadResult.fromJson', () {
    final r = CorpusUploadResult.fromJson({'ok': true, 'received': 512, 'pending': 3});
    expect(r.ok, isTrue);
    expect(r.received, 512);
    expect(r.pending, 3);
  });

  // ---------------- 演示后端：语料状态 + 上传 ----------------

  test('演示后端：corpus status 结构完整（含 subjects/lastBuild/pending）', () async {
    final s = await DemoBackend.instance.get('/api/v1/corpus/status');
    expect(s['totalChunks'], greaterThan(0));
    expect((s['subjects'] as Map), isNotEmpty);
    expect(s['lastBuild'], isNull);
    expect(s['pendingFiles'], 0); // 初始无待处理
    expect(s['reworkPending'], 0, reason: '⑦ 演示态初始无回炉登记（口径=队列 pending 行）');
    final parsed = CorpusStatus.fromJson(s);
    expect(parsed.storageMB, greaterThan(0));
  });

  test('演示后端：上传字节流 → received=字节数，pendingFiles 递增', () async {
    final bytes = List<int>.filled(1024, 7);
    final r1 = await DemoBackend.instance
        .upload('/api/v1/corpus/upload?subject=chem&filename=%E7%AC%AC%E4%B8%80%E7%AB%A0.pptx', bytes);
    expect(r1['ok'], isTrue);
    expect(r1['received'], 1024);
    expect(r1['pending'], 1);

    final r2 = await DemoBackend.instance
        .upload('/corpus/upload?subject=hist&filename=ch2.pptx', List<int>.filled(2048, 1));
    expect(r2['pending'], 2);

    final s = await DemoBackend.instance.get('/corpus/status');
    expect(s['pendingFiles'], 2); // 状态可见待处理队列
  });

  // ---------------- 演示后端：新建科目（POST /subjects） ----------------

  test('演示后端：新建科目 → 列表立即可见；响应为白名单形状（无内置标记）', () async {
    final r = await DemoBackend.instance.post('/api/v1/subjects', {
      'name': '牙周病学',
      'id': 'perio',
    });
    expect(r['ok'], isTrue);
    expect(r['id'], 'perio');
    expect(r['name'], '牙周病学');

    final list = await DemoBackend.instance.get('/subjects');
    final subjects = (list['subjects'] as List).cast<Map<String, dynamic>>();
    final created =
        subjects.firstWhere((s) => s['id'] == 'perio');
    expect(created['name'], '牙周病学');
    // 0.3.1 开源去内置：科目条目字段为白名单形状
    expect(created.keys.toSet(), {'id', 'name', 'isExamSubject', 'dueCount'});
    // 演示种子科目照常在列（世界历史）
    expect(
        subjects.any((s) => s['id'] == 'hist' && s['name'] == '世界历史'),
        isTrue);
  });

  test('演示后端：短码留空 → 自动生成；重复短码 → 409', () async {
    final r = await DemoBackend.instance
        .post('/api/v1/subjects', {'name': '口腔正畸学'});
    expect(r['ok'], isTrue);
    expect(r['id'], isNotEmpty); // 自动生成的短码
    expect(r['name'], '口腔正畸学');

    // 重复短码 → 409
    expectLater(
      DemoBackend.instance.post('/api/v1/subjects', {'name': '再来一个', 'id': 'perio'}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 409)
          .having((e) => e.message, 'message', contains('短码已存在'))),
    );
    // 名称必填 → 400
    expectLater(
      DemoBackend.instance.post('/api/v1/subjects', {'name': ''}),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 400)),
    );
  });

  // ---------------- 展示层：subjectNameOf 缓存链 ----------------

  test('subjectNameOf：库内科目名缓存优先，未拉到时原样 id（无内置兜底）', () {
    final client = ApiClient.instance;
    client.resetSubjectCaches();

    // 1. 无缓存：原样 id（0.3.1 开源去内置——不再回退内置短名）
    expect(client.subjectNameOf('oms'), 'oms');
    expect(client.subjectNameOf('perio'), 'perio');
    // 2. 缓存刷新后：库内科目名优先（含新建科目）
    client.subjectNames['oms'] = '世界历史';
    client.subjectNames['perio'] = '牙周病学';
    expect(client.subjectNameOf('oms'), '世界历史');
    expect(client.subjectNameOf('perio'), '牙周病学');

    client.resetSubjectCaches();
    expect(client.subjectNameOf('oms'), 'oms'); // 重置后回到原样 id
  });

  test('SubjectInfo.fromJson 防御式：缺 isExamSubject/dueCount 也能解析', () {
    final legacy = SubjectInfo.fromJson({'id': 'hist', 'name': '世界历史'});
    expect(legacy.isExamSubject, isFalse);
    expect(legacy.dueCount, 0);

    final full = SubjectInfo.fromJson(
        {'id': 'perio', 'name': '牙周病学', 'isExamSubject': true, 'dueCount': 3});
    expect(full.isExamSubject, isTrue);
    expect(full.dueCount, 3);
  });
}
