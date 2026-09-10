// 恒牙（hengya）· App 内建库接线 · 路由层端到端测试
// ============================================================================
//
// 验收主命题：**App 内完成「上传 → 建库 → 检索出结果」全链路，不依赖电脑**。
// 全部走 ApiClient 真实入口（uploadCourseware / triggerCorpusBuild /
// fetchCorpusBuildStatus / fetchCorpusStatus / updateAiService），local 分流
// → LocalBackend 路由 → 上游 isolate job（corpus_build_job.dart 公共契约）。
//
// 纪律：本文件全部是 **plain test()**（非 testWidgets）——假异步下 await
// 真实 isolate 必死锁（仓库测试纪律），真实 IO / await 真实 isolate 允许。
// Windows 宿主 sqlite3.dll 主 isolate override；**worker isolate 的 override
// 由 IsolateRunner.start 自动探测 test/sqlite3.dll 随 boot 下发**（上游基建
// isolate_runner.dart 文件头 ①）。
//
// 覆盖面：
//   1. 上传 → 建库（drill 零网络零计费，语义同探针 --mode drill）→ 检索
//      冒烟（corpusSearch 直接喂建库产物）；单飞守卫：运行中重复触发 →
//      triggered=false + running=true（不报错）；key 纪律：假 key 配置后
//      全部状态帧/结果/响应不含 key 片段；幂等再触发（manifest 快速路径
//      全 unchanged → 续传收敛、pending 仍 0）
//   2. 0 文件建库：0 chunks → notes 提示 + 未入库（ingest=null），不炸
//   3. 嵌入模式自动选路（零网络——只断预览不触发，online 有真实计费）：
//      无 key → offline；配 key → online
//   4. 显式 mode 校验：未知 mode 400；online 无 key 400（不空跑抽取）
import 'dart:ffi';
import 'dart:io';

import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/ai_key_vault.dart';
import 'package:hengya/services/local/corpus/search_engine.dart'
    show corpusSearch;
import 'package:hengya/services/local/corpus_build_job.dart'
    show corpusBuildJobId;
import 'package:hengya/services/local/isolate_runner.dart' show IsolateRunner;
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

// —— 源文件（CWD=app/；与 isolate_runner_test 同源真实语料——pptx 走
// archive 抽取、pdf 顺带验证 pdfium 在 worker isolate 首用自然加载）——
const _srcOmsPptx =
    '../content/ppt_raw/oms/(2.1.2)--第二章口腔颌面外科基本操作与基础知识 (1).pptx';
const _srcExamPdf =
    '../content/ppt_raw/exam/试卷与模拟题/2023年口腔助理医师试题（网友回忆版）.pdf';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
        () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  late Directory tmp;

  setUp(() {
    // 安全修复 C：AI key 走 vault——测试宿主无平台通道，注入 InMemoryVault
    //（updateAiService 配假 embedding key → 自动选路 online 预览）
    AiKeyVault.instance = InMemoryVault();
    tmp = Directory.systemTemp.createTempSync('hengya_corpus_route_');
  });

  tearDown(() async {
    AiKeyVault.instance = null; // 恢复默认真 vault（跨文件零污染）
    await LocalBackend.instance.resetForTest();
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> boot() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    debugBackendMode = BackendMode.local;
    ApiClient.instance.resetSubjectCaches();
  }

  /// 先订阅再触发（broadcast 流不重放——订阅时序即无竞态），等到下一帧
  /// running=false（收尾帧：成功/失败/取消都会发）。
  Future<Map<String, Object?>> nextIdleFrame() =>
      LocalBackend.instance.corpusBuildState
          .firstWhere((s) => s['running'] == false);

  test('上传 → 建库（drill 零网络）→ 检索：App 内全链路闭环', () async {
    if (!File(_srcOmsPptx).existsSync() || !File(_srcExamPdf).existsSync()) {
      // skip-guard：公开仓库不含 content/（课程语料，版权原因），本用例仅私有工作区生效
      // ignore: avoid_print
      print('SKIP: 私有语料缺失（$_srcOmsPptx / $_srcExamPdf）');
      return;
    }
    await boot();
    // 配假 embedding key：验证①自动选路预览切 online；②显式 drill 覆盖优先；
    // ③key 纪律——key 绝不出现在任何状态帧/结果/状态响应里
    const fakeKey = 'sk-embed-route-secret-889900';
    await ApiClient.instance.updateAiService('embedding',
        baseUrl: 'https://api.siliconflow.cn/v1',
        model: 'Qwen/Qwen3-VL-Embedding-8B',
        apiKey: fakeKey);

    // 1. 建科目（上传校验链要求科目存在；科目名=用户自建示例，验收门外）
    await ApiClient.instance.createSubject(name: '口腔颌面外科学', id: 'oms');
    await ApiClient.instance.createSubject(name: '世界历史', id: 'hist');

    // 2. 上传（ApiClient 真实入口；local 分流 → 校验链 → 落盘 incoming/）
    final pptxBytes = await File(_srcOmsPptx).readAsBytes();
    final up1 = await ApiClient.instance
        .uploadCourseware('oms', '外科基本操作.pptx', pptxBytes);
    expect(up1.ok, true);
    expect(up1.received, pptxBytes.length);
    expect(up1.pending, 1); // manifest 比对口径：首传必为待处理
    final pdfBytes = await File(_srcExamPdf).readAsBytes();
    final up2 = await ApiClient.instance
        .uploadCourseware('hist', '真题试卷.pdf', pdfBytes);
    expect(up2.pending, 2);

    // 3. 状态视图：待处理清单 + 模式选路（有 key → 预览 online；无历史 →
    //    mode 同预览）
    final st0 = await ApiClient.instance.fetchCorpusBuildStatus();
    expect(st0.running, false);
    expect(st0.modePreview, 'online');
    expect(st0.mode, 'online');
    expect(st0.replacesForeign, false); // 无 corpus.db → 无替代警示
    expect(st0.pendingFiles, 2);
    expect(st0.pending, hasLength(2));
    // 清单排序 = 建库树扫描序（lowercase 路径）：hist/… < oms/…
    expect(st0.pending.first.subject, 'hist');
    expect(st0.pending.first.filename, '真题试卷.pdf');
    expect(st0.pending.first.sizeBytes, pdfBytes.length);

    // 4. 触发（显式 drill 覆盖自动选路——零网络零计费；语义同探针 --mode drill）
    final idle = nextIdleFrame();
    final t1 = await ApiClient.instance.triggerCorpusBuild(mode: 'drill');
    expect(t1.ok, true);
    expect(t1.triggered, true);
    expect(t1.mode, 'drill'); // 显式指定优先于自动 online

    // 4b. 单飞守卫：运行中重复触发 → 进行中状态而非报错（job 照旧跑）
    final t2 = await ApiClient.instance.triggerCorpusBuild(mode: 'drill');
    expect(t2.triggered, false);
    expect(t2.running, true);
    expect(t2.note, contains('进行中'));

    // 4c. 真实建库收尾（plain test 可 await 真实 isolate）
    final frame = await idle;
    expect(frame['running'], false);

    // 5. 收尾帧与结果摘要（ExtractAllStats/IngestStats toJson 契约键）
    final st1 = await ApiClient.instance.fetchCorpusBuildStatus();
    expect(st1.running, false);
    expect(st1.error, isNull);
    expect(st1.cancelled, false);
    final r = st1.result!;
    expect(r.chunks, 111); // 上游 isolate_runner_test 同源语料同值
    expect(r.embedded, 111); // drill 全量伪向量嵌入
    expect(r.ingest, isNotNull);
    expect(r.notes, isEmpty);
    expect(r.elapsedS, greaterThan(0));
    expect((r.extract?['errors'] as List), isEmpty);

    // 6. 语料状态端点反映新状态：pending 清零 + chunks 计数 + lastBuild
    //    （App 侧成功收尾补写——对照 server 管线契约）
    final status = await ApiClient.instance.fetchCorpusStatus();
    expect(status.pendingFiles, 0);
    expect(status.totalChunks, r.chunks);
    expect(status.lastBuild, isNotNull);
    expect(status.subjects['oms'], greaterThan(0));
    expect(status.subjects['hist'], greaterThan(0));

    // 7. 检索冒烟：corpusSearch 检到新语料（App 内建库产物直接可检索）
    final db =
        sqlite3.open('${tmp.path}/corpus/corpus.db', mode: OpenMode.readOnly);
    try {
      final text =
          '${db.select('SELECT text FROM chunks LIMIT 1').first.columnAt(0)}';
      final m = RegExp(r'[\u4e00-\u9fff]{6}').firstMatch(text)!;
      final res =
          await corpusSearch(db, m[0]!, k: 5, offline: true, rerank: false);
      expect((res['results'] as List), isNotEmpty, reason: '离线检索零命中');
    } finally {
      db.dispose();
    }

    // 8. key 纪律：全部帧文本 / 结果 / 状态响应不含 key 片段
    expect('$frame'.contains(fakeKey), isFalse);
    expect('${r.extract}${r.ingest}${r.notes}'.contains(fakeKey), isFalse);
    expect('$status'.contains(fakeKey), isFalse);
    final viewAll = await LocalBackend.instance.get('/corpus/build');
    expect('$viewAll'.contains(fakeKey), isFalse);

    // 9. 幂等再触发：manifest 快速路径全 unchanged → 仍成功、pending 仍 0、
    //    ingest 全续传（断点续传契约——已嵌入部分不重做）
    final idle2 = nextIdleFrame();
    final t3 = await ApiClient.instance.triggerCorpusBuild(mode: 'drill');
    expect(t3.triggered, true);
    await idle2;
    final st2 = await ApiClient.instance.fetchCorpusBuildStatus();
    expect(st2.error, isNull);
    final r2 = st2.result!;
    expect((r2.extract?['unchanged'] as num?)?.toInt(), 2);
    expect((r2.extract?['changed'] as num?)?.toInt(), 0);
    expect((r2.extract?['removed'] as num?)?.toInt(), 0);
    expect(r2.chunks, 111);
    expect((r2.ingest?['resumed'] as num?)?.toInt(), 111);
    expect((r2.ingest?['embedded'] as num?)?.toInt(), 0);
    final status2 = await ApiClient.instance.fetchCorpusStatus();
    expect(status2.pendingFiles, 0);
    expect(status2.totalChunks, 111);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('0 文件建库：0 chunks → notes 提示 + 未入库（ingest=null），不炸', () async {
    await boot();
    final idle = nextIdleFrame();
    final t = await ApiClient.instance.triggerCorpusBuild(mode: 'drill');
    expect(t.triggered, true);
    await idle;
    final st = await ApiClient.instance.fetchCorpusBuildStatus();
    expect(st.error, isNull);
    final r = st.result!;
    expect(r.chunks, 0);
    expect(r.ingest, isNull); // 0 chunks → 不入库（worker 契约）
    expect(r.notes, isNotEmpty);
    expect(r.notes.first, contains('0 chunks'));
    final status = await ApiClient.instance.fetchCorpusStatus();
    expect(status.pendingFiles, 0);
    expect(status.totalChunks, 0);
  });

  test('嵌入模式自动选路（零网络）：无 key → offline；配 key → online（仅预览不触发）', () async {
    await boot();
    final st0 = await ApiClient.instance.fetchCorpusBuildStatus();
    expect(st0.modePreview, 'offline');
    expect(st0.mode, 'offline');
    // 配 key（经真实 PUT 路由）→ 预览切 online；不触发——online 有真实计费，
    // 选路断言经预览（GET /corpus/build modePreview）完成
    await ApiClient.instance.updateAiService('embedding',
        baseUrl: 'https://api.siliconflow.cn/v1',
        model: 'Qwen/Qwen3-VL-Embedding-8B',
        apiKey: 'sk-embed-preview-only-445566');
    final st1 = await ApiClient.instance.fetchCorpusBuildStatus();
    expect(st1.modePreview, 'online');
    expect(IsolateRunner.instance.isRunning(corpusBuildJobId), isFalse);
  });

  test('显式 mode 校验：未知 mode 400；online 无 key 400（不空跑抽取）', () async {
    await boot();
    await expectLater(
      ApiClient.instance.triggerCorpusBuild(mode: 'bogus'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 400)
          .having((e) => e.message, 'message', contains('mode'))),
    );
    await expectLater(
      ApiClient.instance.triggerCorpusBuild(mode: 'online'),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 400)
          .having((e) => e.message, 'message', contains('Key'))),
    );
    // 未触发任何 job（单飞位空闲）
    expect(IsolateRunner.instance.isRunning(corpusBuildJobId), isFalse);
  });
}
