// M5 契约测试：本地假 HTTP 服务器逐条核验 api_client 新方法的请求形状
// （方法/路径/query/请求体/Content-Type），并验证旧服务器 404 → ApiException(404)。
// 契约（与服务端同一契约）：
//   GET  /api/v1/settings/ai                    → {llm:{...}, embedding:{...}, reranker:{...}}
//   PUT  /api/v1/settings/ai/{llm|embedding|reranker}   body {baseUrl, model, apiKey}
//   POST /api/v1/settings/ai/{llm|embedding|reranker}/test body 同上
//   GET  /api/v1/corpus/status
//   POST /api/v1/corpus/upload?subject=..&filename=..（octet-stream 原始字节）
//   GET  /api/v1/subjects                       → {subjects:[...]}
//   POST /api/v1/subjects                       body {name, id?}
//   GET  /api/v1/progress                       → {subjects:[...], updated_at}
//   POST /api/v1/pipeline/trigger（0.4.1+）     → {ok, triggered, note}
import 'dart:convert';
import 'dart:io';

import 'package:hengya/services/api/api_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  final requests = <Map<String, dynamic>>[];
  var all404 = false; // 模拟旧服务器（0.2.0）：新增端点全部 404
  var triggerCount = 0; // pipeline/trigger：首次 triggered=true，重复排队 false

  Future<void> handle(HttpRequest req) async {
    final body = await utf8.decoder.bind(req).join();
    requests.add({
      'method': req.method,
      'path': req.uri.path,
      'query': req.uri.queryParameters,
      'body': body,
      'contentType': req.headers.value('content-type'),
    });
    final res = req.response;
    res.headers.contentType = ContentType.json;

    if (all404) {
      res.statusCode = 404;
      res.write(jsonEncode({'error': 'not found'}));
      await res.close();
      return;
    }

    final path = req.uri.path;
    if (path == '/api/v1/settings/ai' && req.method == 'GET') {
      res.write(
        jsonEncode({
          'llm': {
            'baseUrl': 'https://a.cn/v1',
            'model': 'm1',
            'keySet': true,
            'keyMasked': 'sk-****xy',
            'encrypted': true,
          },
          'embedding': {
            'baseUrl': '',
            'model': '',
            'keySet': false,
            'keyMasked': '',
            'encrypted': false,
          },
          'reranker': {
            'baseUrl': 'https://api.siliconflow.cn/v1/rerank',
            'model': 'Qwen/Qwen3-Reranker-8B',
            'keySet': true,
            'keyMasked': 'rr-****88',
            'encrypted': true,
          },
        }),
      );
    } else if (path == '/api/v1/settings/ai/llm' && req.method == 'PUT') {
      res.write(
        jsonEncode({'ok': true, 'keySet': true, 'keyMasked': 'sk-****zz'}),
      );
    } else if (path == '/api/v1/settings/ai/reranker' && req.method == 'PUT') {
      res.write(
        jsonEncode({'ok': true, 'keySet': true, 'keyMasked': 'rr-****zz'}),
      );
    } else if (path == '/api/v1/settings/ai/embedding/test' &&
        req.method == 'POST') {
      res.write(
        jsonEncode({
          'ok': true,
          'status': 200,
          'latencyMs': 88,
          'message': 'ok',
        }),
      );
    } else if (path == '/api/v1/settings/ai/reranker/test' &&
        req.method == 'POST') {
      res.write(
        jsonEncode({
          'ok': false,
          'status': 401,
          'latencyMs': 120,
          'message': 'Invalid token',
        }),
      );
    } else if (path == '/api/v1/corpus/status' && req.method == 'GET') {
      res.write(
        jsonEncode({
          'totalChunks': 42,
          'subjects': {'oms': 18},
          'lastBuild': null,
          'pendingFiles': 2,
          'reworkPending': 3,
          'storageMB': 3.2,
        }),
      );
    } else if (path == '/api/v1/corpus/upload' && req.method == 'POST') {
      res.write(
        jsonEncode({'ok': true, 'received': body.length, 'pending': 3}),
      );
    } else if (path == '/api/v1/subjects' && req.method == 'GET') {
      res.write(
        jsonEncode({
          'subjects': [
            {'id': 'oms', 'name': '口腔颌面外科学', 'dueCount': 2},
            {'id': 'perio', 'name': '牙周病学', 'dueCount': 0},
          ],
        }),
      );
    } else if (path == '/api/v1/subjects' && req.method == 'POST') {
      res.write(jsonEncode({'ok': true, 'id': 'perio', 'name': '牙周病学'}));
    } else if (path == '/api/v1/progress' && req.method == 'GET') {
      // §7.5 学习罗盘三态子集：在学（有下一章）/ 学完（next=null）/ 无罗盘（derm）
      res.write(
        jsonEncode({
          'subjects': [
            {
              'id': 'endo',
              'textbook': '世界通史-第2版',
              'learned_through': 4,
              'total': 8,
              'next_chapter': {'no': 5, 'title': '第二篇 工业文明的扩展', 'page': 58},
            },
            {
              'id': 'anatomy',
              'textbook': '口腔解剖生理学-第8版',
              'learned_through': 11,
              'total': 11,
              'next_chapter': null,
            },
            {
              'id': 'derm',
              'textbook': null,
              'learned_through': 0,
              'total': 0,
              'next_chapter': null,
            },
          ],
          'updated_at': '2026-09-05T14:07:01',
        }),
      );
    } else if (path == '/api/v1/progress/endo/chapters' && req.method == 'GET') {
      // ⑨ 章节管理单科视图（与 local 实装同构）
      res.write(
        jsonEncode({
          'id': 'endo',
          'textbook': '世界通史-第2版',
          'learned_through': 2,
          'skipped': [4],
          'total': 5,
          'effective_total': 4,
          'effective_learned': 2,
          'next_chapter': {'no': 3, 'title': '第一章 绪论', 'page': 14},
          'chapters': [
            {'no': 1, 'title': '目录', 'page_start': 3, 'learned': true, 'skipped': false},
            {'no': 2, 'title': '前言', 'page_start': 8, 'learned': true, 'skipped': false},
            {'no': 3, 'title': '第一章 绪论', 'page_start': 14, 'learned': false, 'skipped': false},
            {'no': 4, 'title': '第二章 龋病', 'page_start': 20, 'learned': false, 'skipped': true},
            {'no': 5, 'title': '附录', 'page_start': 60, 'learned': false, 'skipped': false},
          ],
        }),
      );
    } else if (path == '/api/v1/progress/endo/chapters' && req.method == 'PUT') {
      // ⑨ 章节管理写：回显请求态（ok/note + 写后视图）
      res.write(
        jsonEncode({
          'ok': true,
          'note': '推进 2 → 4，不学章 1 个',
          'id': 'endo',
          'textbook': '世界通史-第2版',
          'learned_through': 4,
          'skipped': [4],
          'total': 5,
          'effective_total': 4,
          'effective_learned': 3,
          'next_chapter': null,
          'chapters': const [],
        }),
      );
    } else if (path == '/api/v1/pipeline/trigger' && req.method == 'POST') {
      // server 0.4.1 契约：首次排队 triggered=true；标志已存在 → 幂等排队中
      triggerCount++;
      res.write(
        triggerCount == 1
            ? jsonEncode({
                'ok': true,
                'triggered': true,
                'note': '已触发，约 1 分钟内开跑',
              })
            : jsonEncode({'ok': true, 'triggered': false, 'note': '已有任务排队中'}),
      );
    } else {
      res.statusCode = 404;
      res.write(jsonEncode({'error': 'not found'}));
    }
    await res.close();
  }

  Map<String, dynamic> lastOf(String method, String path) =>
      requests.lastWhere((r) => r['method'] == method && r['path'] == path);

  setUp(() async {
    // kBackendMode 缺省已定 local（开源定稿）；本套件逐条核验远程 HTTP 请求
    // 形状（真 HttpServer 只走 remote 分支），显式钉住 remote。
    debugBackendMode = BackendMode.remote;
    requests.clear();
    all404 = false;
    triggerCount = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(handle);
    ApiClient.instance.baseUrl = 'http://127.0.0.1:${server.port}';
    ApiClient.instance.resetSubjectCaches();
  });

  tearDown(() async {
    debugBackendMode = null; // 置回 null：跨用例/跨文件零污染
    await server.close(force: true);
    ApiClient.instance.baseUrl = 'http://10.0.2.2:8080';
    ApiClient.instance.resetSubjectCaches();
  });

  test('fetchAiSettings：GET /api/v1/settings/ai，解析两套配置', () async {
    final ai = await ApiClient.instance.fetchAiSettings();
    expect(ai.llm.baseUrl, 'https://a.cn/v1');
    expect(ai.llm.keyDisplay, 'sk-****xy');
    expect(ai.embedding.keyDisplay, '未配置');
    final r = lastOf('GET', '/api/v1/settings/ai');
    expect(r['query'], isEmpty);
  });

  test(
    'updateAiService：PUT /api/v1/settings/ai/{svc}，body 三字段（空串 key 原样上送）',
    () async {
      final res = await ApiClient.instance.updateAiService(
        'llm',
        baseUrl: 'https://b.cn/v1',
        model: 'm2',
        apiKey: '', // 契约：空串=不改 key
      );
      expect(res.ok, isTrue);
      expect(res.keyMasked, 'sk-****zz');
      final r = lastOf('PUT', '/api/v1/settings/ai/llm');
      expect(jsonDecode(r['body'] as String), {
        'baseUrl': 'https://b.cn/v1',
        'model': 'm2',
        'apiKey': '',
      });
      expect(r['contentType'], 'application/json; charset=utf-8');
    },
  );

  test('testAiService：POST /api/v1/settings/ai/{svc}/test，延迟/状态可读', () async {
    final res = await ApiClient.instance.testAiService(
      'embedding',
      baseUrl: 'https://c.cn/v1',
      model: 'bge-m3',
      apiKey: 'sk-live-key',
    );
    expect(res.ok, isTrue);
    expect(res.display, '连接正常 · 88 ms');
    final r = lastOf('POST', '/api/v1/settings/ai/embedding/test');
    expect(jsonDecode(r['body'] as String), {
      'baseUrl': 'https://c.cn/v1',
      'model': 'bge-m3',
      'apiKey': 'sk-live-key',
    });
  });

  test(
    'reranker 契约：GET 节点解析掩码态 / PUT·POST 三字段请求体（与 llm/embedding 同形）',
    () async {
      // GET：reranker 节点 → 掩码态解析（明文 key 永不出服务端）
      final ai = await ApiClient.instance.fetchAiSettings();
      expect(ai.reranker.baseUrl, 'https://api.siliconflow.cn/v1/rerank');
      expect(ai.reranker.model, 'Qwen/Qwen3-Reranker-8B');
      expect(ai.reranker.keyDisplay, 'rr-****88');
      expect(ai.of('reranker').keySet, isTrue);

      // PUT：三字段（apiKey 空串 = 不改 key，原样上送）
      final u = await ApiClient.instance.updateAiService(
        'reranker',
        baseUrl: ApiClient.kRerankerDefaultUrl,
        model: ApiClient.kRerankerDefaultModel,
        apiKey: '',
      );
      expect(u.ok, isTrue);
      expect(u.keyMasked, 'rr-****zz');
      final rp = lastOf('PUT', '/api/v1/settings/ai/reranker');
      expect(jsonDecode(rp['body'] as String), {
        'baseUrl': ApiClient.kRerankerDefaultUrl,
        'model': ApiClient.kRerankerDefaultModel,
        'apiKey': '',
      });
      expect(rp['contentType'], 'application/json; charset=utf-8');

      // POST test：同形请求体；上游失败（HTTP 200 + ok=false）不抛异常
      final t = await ApiClient.instance.testAiService(
        'reranker',
        baseUrl: 'https://api.siliconflow.cn/v1/rerank',
        model: 'Qwen/Qwen3-Reranker-8B',
        apiKey: 'rr-fake-c1',
      );
      expect(t.ok, isFalse);
      expect(t.status, 401);
      expect(t.display, '失败：Invalid token'); // 裸 message 透传进展示层
      final rt = lastOf('POST', '/api/v1/settings/ai/reranker/test');
      expect(jsonDecode(rt['body'] as String), {
        'baseUrl': 'https://api.siliconflow.cn/v1/rerank',
        'model': 'Qwen/Qwen3-Reranker-8B',
        'apiKey': 'rr-fake-c1',
      });
    },
  );

  test('fetchCorpusStatus：GET /api/v1/corpus/status，全字段解析', () async {
    final s = await ApiClient.instance.fetchCorpusStatus();
    expect(s.totalChunks, 42);
    expect(s.subjects, {'oms': 18});
    expect(s.lastBuild, isNull);
    expect(s.pendingFiles, 2);
    expect(s.reworkPending, 3, reason: '⑦ 回炉待重造计数解析');
    expect(s.storageMB, 3.2);
    lastOf('GET', '/api/v1/corpus/status');
  });

  test(
    'uploadCourseware：POST 原始字节流 + query 双参数 + octet-stream（中文文件名 URL 编码）',
    () async {
      final bytes = [80, 75, 3, 4, 99, 100]; // 伪 zip 头
      final res = await ApiClient.instance.uploadCourseware(
        'endo',
        '世界史 第一章.pptx',
        bytes,
      );
      expect(res.ok, isTrue);
      expect(res.received, bytes.length);
      expect(res.pending, 3);
      final r = lastOf('POST', '/api/v1/corpus/upload');
      // query：subject 短码原样、中文文件名按 URL 编码传输
      expect(r['query']['subject'], 'endo');
      expect(r['query']['filename'], '世界史 第一章.pptx'); // Uri 解码后等值
      // 请求体是原始字节，不是 JSON
      expect(r['contentType'], 'application/octet-stream');
      expect((r['body'] as String).codeUnits, bytes);
    },
  );

  test(
      'uploadCourseware 语料类型标注：source 参数仅 textbook/exam/outline 携带（默认请求零变化）',
      () async {
    final bytes = [80, 75, 3, 4]; // 伪 zip 头
    // 缺省 = 课件：不携带 source（请求形状与 0.3.0 契约字节一致）
    await ApiClient.instance.uploadCourseware('endo', 'a.pptx', bytes);
    var r = lastOf('POST', '/api/v1/corpus/upload');
    expect((r['query'] as Map).containsKey('source'), isFalse,
        reason: '默认课件不带 source——remote 旧服务器零感知');

    // source=textbook：query 追加 source=textbook（local 落 -textbook 教材树）
    await ApiClient.instance.uploadCourseware('endo', 'b.pdf', bytes,
        source: 'textbook');
    r = lastOf('POST', '/api/v1/corpus/upload');
    expect(r['query']['source'], 'textbook');

    // source='ppt' 显式课件：等价缺省 → 仍不携带
    await ApiClient.instance.uploadCourseware('endo', 'c.pptx', bytes,
        source: 'ppt');
    r = lastOf('POST', '/api/v1/corpus/upload');
    expect((r['query'] as Map).containsKey('source'), isFalse,
        reason: "词表 'ppt'=课件默认，等价缺省不带参数");

    // source='exam'（节点③真题专题上传）：query 追加 source=exam
    //（local 落 <短码>-exam 真题树；subject = 12 考站专题短码之一）
    await ApiClient.instance.uploadCourseware('bingshi', 'd.pdf', bytes,
        source: 'exam');
    r = lastOf('POST', '/api/v1/corpus/upload');
    expect(r['query']['subject'], 'bingshi');
    expect(r['query']['source'], 'exam');

    // source='outline'（节点④大纲上传）：query 追加 source=outline
    //（local 落 dagang-outline 大纲树；subject 固定 dagang）
    await ApiClient.instance.uploadCourseware('dagang', 'e.docx', bytes,
        source: 'outline');
    r = lastOf('POST', '/api/v1/corpus/upload');
    expect(r['query']['subject'], 'dagang');
    expect(r['query']['source'], 'outline');

    // 其他值（未知类型）：不携带（remote 未知 query 静默忽略口径）
    await ApiClient.instance.uploadCourseware('endo', 'f.pptx', bytes,
        source: 'whatever');
    r = lastOf('POST', '/api/v1/corpus/upload');
    expect((r['query'] as Map).containsKey('source'), isFalse,
        reason: '未知 source 值不携带——词表外值零感知');
  });

  test(
    'fetchSubjectCatalog：GET /api/v1/subjects 解析科目目录，并刷新名称缓存',
    () async {
      final subs = await ApiClient.instance.fetchSubjectCatalog();
      expect(subs.length, 2);
      expect(subs[0].name, '口腔颌面外科学');
      expect(subs[1].name, '牙周病学');
      // 展示名缓存被刷新 → 库内科目名优先
      expect(ApiClient.instance.subjectNameOf('oms'), '口腔颌面外科学');
      expect(ApiClient.instance.subjectNameOf('perio'), '牙周病学');
    },
  );

  test('createSubject：POST /api/v1/subjects，id 留空不传键、非空 trim 上送', () async {
    final created = await ApiClient.instance.createSubject(
      name: '牙周病学',
      id: ' perio ',
    );
    expect(created.id, 'perio'); // 服务端回显
    expect(created.name, '牙周病学');
    expect(jsonDecode(lastOf('POST', '/api/v1/subjects')['body'] as String), {
      'name': '牙周病学',
      'id': 'perio',
    }); // trim 后上送

    // id 留空 → 请求体只有 name（服务端自动生成短码）
    await ApiClient.instance.createSubject(name: '口腔正畸学');
    expect(jsonDecode(lastOf('POST', '/api/v1/subjects')['body'] as String), {
      'name': '口腔正畸学',
    });
  });

  test('fetchProgress：GET /api/v1/progress，解析在学/学完/无罗盘三态', () async {
    final p = await ApiClient.instance.fetchProgress();
    expect(p.updatedAt, DateTime.parse('2026-09-05T14:07:01'));
    expect(p.subjects.length, 3);
    // 在学科目：教材/已学/总数/下一章（no/title/page）全解析
    final endo = p.subjects[0];
    expect(endo.id, 'endo');
    expect(endo.textbook, '世界通史-第2版');
    expect(endo.hasTextbook, isTrue);
    expect(endo.learnedThrough, 4);
    expect(endo.total, 8);
    expect(endo.nextChapter!.no, 5);
    expect(endo.nextChapter!.title, '第二篇 工业文明的扩展');
    expect(endo.nextChapter!.page, 58);
    expect(endo.nextChapter!.display, '第二篇 工业文明的扩展 p58');
    expect(endo.completed, isFalse);
    expect(endo.fraction, closeTo(0.5, 0.001));
    // 学完态：next_chapter=null → completed，比例 1.0
    final anatomy = p.subjects[1];
    expect(anatomy.nextChapter, isNull);
    expect(anatomy.completed, isTrue);
    expect(anatomy.fraction, 1.0);
    // 无罗盘（derm 占位）：textbook=null → hasTextbook=false（复习提示排除依据）
    final derm = p.subjects[2];
    expect(derm.hasTextbook, isFalse);
    expect(derm.fraction, 0); // total=0 防除零
    final r = lastOf('GET', '/api/v1/progress');
    expect(r['query'], isEmpty);
  });

  test(
    'triggerPipeline：POST /api/v1/pipeline/trigger，首次 triggered=true、重复幂等排队中',
    () async {
      final first = await ApiClient.instance.triggerPipeline();
      expect(first.ok, isTrue);
      expect(first.triggered, isTrue);
      expect(first.note, '已触发，约 1 分钟内开跑');
      // 重复触发：标志已存在 → triggered=false + 后端 note
      final again = await ApiClient.instance.triggerPipeline();
      expect(again.ok, isTrue);
      expect(again.triggered, isFalse);
      expect(again.note, '已有任务排队中');
      lastOf('POST', '/api/v1/pipeline/trigger');
    },
  );

  test('subjectFullNameOf：与 subjectNameOf 同链——库内科目名优先，未拉到时原样 id', () async {
    // 服务端目录在缓存里（前一组用例可能未拉取）→ 先拉一次刷新名称缓存
    await ApiClient.instance.fetchSubjectCatalog();
    // 库内科目名优先
    expect(ApiClient.instance.subjectFullNameOf('oms'), '口腔颌面外科学');
    // 不在 subjects 表的科目 → 原样 id（0.3.1 起罗盘 13 科全名兜底已随内置科目移除）
    expect(ApiClient.instance.subjectFullNameOf('ortho'), 'ortho');
    expect(ApiClient.instance.subjectFullNameOf('anatomy'), 'anatomy');
    expect(ApiClient.instance.subjectFullNameOf('pedo'), 'pedo');
    // 未知 id 仍原样显示
    expect(ApiClient.instance.subjectFullNameOf('zzz'), 'zzz');
  });

  test(
    '⑨ fetchSubjectChapters：GET /api/v1/progress/{subject}/chapters，'
    '全章状态/原始指针/有效统计/跳过感知下一章全解析',
    () async {
      final v = await ApiClient.instance.fetchSubjectChapters('endo');
      expect(v.id, 'endo');
      expect(v.textbook, '世界通史-第2版');
      expect(v.learnedThrough, 2, reason: '原始前缀指针');
      expect(v.skipped, [4]);
      expect(v.total, 5);
      expect(v.effectiveTotal, 4, reason: '有效总量 = total − 跳过数');
      expect(v.effectiveLearned, 2);
      expect(v.nextChapter!.no, 3, reason: '跳过感知：4 已标不学 → 下一章 3');
      expect(v.fraction, closeTo(0.5, 0.001));
      // 全章列表：状态三态（已学/待学/不学）
      expect(v.chapters.length, 5);
      expect(v.chapters[0].title, '目录');
      expect(v.chapters[0].learned, isTrue);
      expect(v.chapters[2].learned, isFalse);
      expect(v.chapters[3].skipped, isTrue);
      expect(v.chapters[3].page, 20);
      final r = lastOf('GET', '/api/v1/progress/endo/chapters');
      expect(r['query'], isEmpty);
    },
  );

  test(
    '⑨ updateSubjectChapters：PUT 请求体只带所传字段（缺省字段不动语义）',
    () async {
      final u = await ApiClient.instance.updateSubjectChapters(
        'endo',
        learnedThrough: 4,
        skipped: [4],
      );
      expect(u.ok, isTrue);
      expect(u.note, '推进 2 → 4，不学章 1 个');
      expect(u.chapters.learnedThrough, 4);
      expect(u.chapters.effectiveLearned, 3, reason: '指针区间内跳过章不计已学');
      var r = lastOf('PUT', '/api/v1/progress/endo/chapters');
      expect(jsonDecode(r['body'] as String), {
        'learned_through': 4,
        'skipped': [4],
      });
      expect(r['contentType'], 'application/json; charset=utf-8');
      // 只带 skipped → 请求体无 learned_through（不动流水线刚推进的指针）
      await ApiClient.instance.updateSubjectChapters('endo', skipped: [1, 2]);
      r = lastOf('PUT', '/api/v1/progress/endo/chapters');
      expect(jsonDecode(r['body'] as String), {
        'skipped': [1, 2],
      });
      // 只带 learnedThrough → 请求体无 skipped
      await ApiClient.instance.updateSubjectChapters('endo', learnedThrough: 0);
      r = lastOf('PUT', '/api/v1/progress/endo/chapters');
      expect(jsonDecode(r['body'] as String), {
        'learned_through': 0,
      });
    },
  );

  test('404 降级：旧服务器（0.2.0）新增端点全 404 → ApiException(404)，不崩溃', () async {
    all404 = true;
    await expectLater(
      ApiClient.instance.fetchAiSettings(),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
    await expectLater(
      ApiClient.instance.fetchCorpusStatus(),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
    await expectLater(
      ApiClient.instance.createSubject(name: '植物学'),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
    await expectLater(
      ApiClient.instance.uploadCourseware('oms', 'a.pptx', [1, 2, 3]),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
    await expectLater(
      ApiClient.instance.fetchProgress(),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
    await expectLater(
      ApiClient.instance.triggerPipeline(),
      throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'statusCode', 404),
      ),
    );
  });
}
