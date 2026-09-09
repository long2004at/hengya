// 教材标注（本节点）：上传弹层「类型」单选（课件（默认）/ 教材）UI 断言 +
// 选择结果经与 App 完全同路的 ApiClient.uploadCourseware(source:) 落盘。
// 镜像纪律（同 corpus_build_panel_test / manual_step03_04）：
//   - Windows 测试宿主显式加载 test/sqlite3.dll（overrideForAll）；
//   - setUp/tearDown 100% 同步，boot() 放用例体首行；
//   - 文件选择器是平台通道（F 组，测试宿主不可达）——弹层直开（生产
//     _pickAndUpload 第 2 步的同一入口 showUploadTargetPickerSheet），
//     上传走 ApiClient 同路落盘（→ LocalBackend.upload → 魔数校验）；
//   - 底部面板入场：pump() + pump(450ms)。
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/pages/subject_picker.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
      () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_upload_type_');
  });

  tearDown(() {
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    // 不 await：resetForTest 同步前缀已清运行态（微任务链自完成）
    LocalBackend.instance.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> boot() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    debugBackendMode = BackendMode.local;
    ApiClient.instance.resetSubjectCaches();
    SharedPreferences.setMockInitialValues({});
    // 真科目（弹层动态列表来自 /subjects；local = db subjects 表）
    await LocalBackend.instance
        .post('/subjects', {'name': '口腔颌面外科学', 'id': 'oms'});
  }

  /// 弹层选择结果（openSheet 的按钮回调写入）
  UploadTarget? picked;

  /// 打开上传弹层（生产 _pickAndUpload 第 2 步同一入口；local 模式带
  /// 「类型」单选）并等科目列表落地。
  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () async {
                picked = await showUploadTargetPickerSheet(
                  ctx,
                  title: '选择科目与类型',
                  pickUploadType: true,
                );
              },
              child: const Text('打开上传弹层'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开上传弹层'));
    await tester.pump(); // 弹层入场起始帧
    await tester.pump(const Duration(milliseconds: 450)); // 底部面板入场
    for (var i = 0;
        i < 12 && !tester.any(find.text('口腔颌面外科学'));
        i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  /// 当前类型单选组值（RadioGroup 祖先管理组态——RadioListTile 自身
  /// 的 groupValue 已弃用不读；选中态视觉由本值驱动）。
  String radioGroupValue(WidgetTester tester) => tester
      .widget<RadioGroup<String>>(find.byType(RadioGroup<String>))
      .groupValue!;

  testWidgets(
      '类型单选：默认课件、说明文案逐字；点科目即整组确认（课件落盘不回归）',
      (tester) async {
    await boot();
    picked = null;
    await openSheet(tester);

    // 弹层结构：标题 + 两个单选项 + 内联新建入口
    expect(find.text('选择科目与类型'), findsOneWidget);
    expect(find.text('课件'), findsOneWidget);
    expect(find.text('教材'), findsOneWidget);
    expect(find.text('新建课程'), findsOneWidget);
    // 类型说明文案逐字（锚点 = subject_picker.kUploadTypeHint）
    expect(find.text(kUploadTypeHint), findsOneWidget);

    // 默认 = 课件（RadioGroup 组态；两枚 RadioListTile 的选中视觉由其驱动）
    expect(radioGroupValue(tester), 'ppt');

    // 不动类型直接点科目 → 默认课件随科目一并返回
    await tester.tap(find.text('口腔颌面外科学'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(picked, isNotNull, reason: '点科目即确认整组（科目+类型）');
    expect(picked!.subject.id, 'oms');
    expect(picked!.sourceType, 'ppt');

    // 与 App 同路落盘：uploadCourseware(source: 'ppt') 等价缺省 → 课件树
    final res = await ApiClient.instance.uploadCourseware(
      picked!.subject.id,
      '外科基本操作.pptx',
      [0x50, 0x4B, 0x03, 0x04], // PK 魔数
      source: picked!.sourceType,
    );
    expect(res.ok, true);
    expect(res.pending, 1);
    expect(
      File('${tmp.path}/corpus/incoming/oms/外科基本操作.pptx').existsSync(),
      true,
      reason: '默认课件维持 incoming/<短码>/ 落盘（既有行为零变化）',
    );
    expect(
      Directory('${tmp.path}/corpus/incoming/oms-textbook').existsSync(),
      false,
      reason: '课件上传不得产生教材树',
    );
  });

  testWidgets('选「教材」→ 随科目返回 textbook → 同路落 -textbook 教材树',
      (tester) async {
    await boot();
    picked = null;
    await openSheet(tester);

    // 切换类型 → 组值翻到 textbook（单选互斥；选中视觉随之切换）
    await tester.tap(find.text('教材'));
    await tester.pump();
    expect(radioGroupValue(tester), 'textbook');

    // 点科目确认 → 教材选择必须随科目一并返回（同一次上传只属一种类型）
    await tester.tap(find.text('口腔颌面外科学'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(picked!.subject.id, 'oms');
    expect(picked!.sourceType, 'textbook');

    // 与 App 同路落盘（_pickAndUpload 第 3 步同款调用）→ 教材树
    final res = await ApiClient.instance.uploadCourseware(
      picked!.subject.id,
      '皮肤性病学.pdf',
      [0x25, 0x50, 0x44, 0x46], // %PDF 魔数
      source: picked!.sourceType,
    );
    expect(res.ok, true);
    expect(res.pending, 1);
    expect(
      File('${tmp.path}/corpus/incoming/oms-textbook/皮肤性病学.pdf')
          .existsSync(),
      true,
      reason: '选「教材」必须落 incoming/<短码>-textbook/（教材树约定）',
    );
    expect(
      File('${tmp.path}/corpus/incoming/oms/皮肤性病学.pdf').existsSync(),
      false,
      reason: '课件树不受教材上传污染',
    );

    // 待处理清单分键：subject = 首层目录名（建库面板据此加「·教材」角标）
    final st = await ApiClient.instance.fetchCorpusBuildStatus();
    expect(st.pendingFiles, 1);
    expect(st.pending.single.subject, 'oms-textbook');
    expect(st.pending.single.filename, '皮肤性病学.pdf');
  });

  testWidgets(
      '选「真题」→ 科目区切换「专题选择」（12 考站专题）→ 点专题整组返回 exam → 落 -exam 真题树',
      (tester) async {
    await boot();
    picked = null;
    await openSheet(tester);

    // 三类型单选并存：课件（默认）/ 教材 / 真题
    expect(find.text('真题'), findsOneWidget);
    expect(radioGroupValue(tester), 'ppt');

    // 切「真题」→ 组值翻 exam；科目选择区切换为「专题选择」：
    // 专题清单可见（12 考站静态常量），科目列表/新建课程退出
    await tester.tap(find.text('真题'));
    await tester.pump();
    expect(radioGroupValue(tester), 'exam');
    expect(find.text('专题选择'), findsOneWidget);
    expect(find.text('病史采集类'), findsOneWidget);
    expect(find.text('病例分析类'), findsOneWidget);
    expect(find.text('检查方法类'), findsOneWidget);
    expect(find.text('操作技能类'), findsOneWidget);
    expect(find.text('急救技术类'), findsOneWidget);
    expect(find.text('修复类专题'), findsOneWidget);
    expect(find.text('口腔颌面外科学'), findsNothing,
        reason: '真题模式不展示科目列表（真题树与科目 Tab 解耦）');
    expect(find.text('新建课程'), findsNothing,
        reason: '专题清单固定，无内联新建入口');

    // 12 项完整可滚达：上滚露出尾部专题（列表懒构建，滚过即渲染）
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    expect(find.text('职业素质与医德医风'), findsOneWidget);
    expect(find.text('试卷与模拟题'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();

    // 切回「课件」→ 科目列表回归（联动可逆）
    await tester.tap(find.text('课件'));
    await tester.pump();
    expect(find.text('科目列表'), findsOneWidget);
    expect(find.text('口腔颌面外科学'), findsOneWidget);
    expect(find.text('病史采集类'), findsNothing);

    // 再切「真题」→ 点专题即整组确认（合成 SubjectInfo：短码+中文名）
    await tester.tap(find.text('真题'));
    await tester.pump();
    await tester.tap(find.text('病史采集类'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(picked, isNotNull, reason: '点专题即确认整组（专题+类型）');
    expect(picked!.subject.id, 'bingshi');
    expect(picked!.subject.name, '病史采集类');
    expect(picked!.sourceType, 'exam');

    // 与 App 同路落盘（_pickAndUpload 第 3 步同款调用）→ 真题树
    final res = await ApiClient.instance.uploadCourseware(
      picked!.subject.id,
      '病史采集真题.pdf',
      [0x25, 0x50, 0x44, 0x46], // %PDF 魔数
      source: picked!.sourceType,
    );
    expect(res.ok, true);
    expect(res.pending, 1);
    expect(
      File('${tmp.path}/corpus/incoming/bingshi-exam/病史采集真题.pdf')
          .existsSync(),
      true,
      reason: '选「真题」必须落 incoming/<短码>-exam/（真题树约定）',
    );
    expect(
      File('${tmp.path}/corpus/incoming/bingshi/病史采集真题.pdf').existsSync(),
      false,
      reason: '课件树不受真题上传污染',
    );

    // 守卫：真题短码不进 subjects 表（科目目录仍只有 oms）
    final subs = await ApiClient.instance.fetchSubjectCatalog();
    expect(subs.any((s) => s.id == 'bingshi'), isFalse,
        reason: '上传真题绝不自动建 subject（B1 拍板：不进科目 Tab）');

    // 防御：source=exam + 非 12 专题短码 → 400（无真实网络，local 直调）
    await expectLater(
      ApiClient.instance.uploadCourseware(
        'oms',
        '越权.pdf',
        [0x25, 0x50, 0x44, 0x46],
        source: 'exam',
      ),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 400)),
      reason: '真题池只认 12 考站专题短码（kExamTopics）',
    );
  });

  testWidgets(
      '选「大纲」→ 跳过科目/专题选择（单一确认项）→ 整组返回 outline → 落 dagang-outline 大纲树',
      (tester) async {
    await boot();
    picked = null;
    await openSheet(tester);

    // 四类型单选并存：课件（默认）/ 教材 / 真题 / 大纲
    expect(find.text('大纲'), findsOneWidget);
    expect(radioGroupValue(tester), 'ppt');

    // 切「大纲」→ 组值翻 outline；科目区切换为大纲确认项（无需选科目）
    await tester.tap(find.text('大纲'));
    await tester.pump();
    expect(radioGroupValue(tester), 'outline');
    expect(find.text('大纲（无需选择科目）'), findsOneWidget);
    expect(find.text('口腔执业/助理医师资格考试大纲'), findsOneWidget);
    expect(find.text('口腔颌面外科学'), findsNothing,
        reason: '大纲模式不展示科目列表（大纲树与科目 Tab 解耦）');
    expect(find.text('新建课程'), findsNothing);
    expect(find.text('病史采集类'), findsNothing,
        reason: '大纲模式与真题专题模式互斥');

    // 切回「课件」可逆 → 科目列表回归
    await tester.tap(find.text('课件'));
    await tester.pump();
    expect(find.text('科目列表'), findsOneWidget);

    // 再切「大纲」→ 点确认项即整组返回（合成 SubjectInfo：dagang）
    await tester.tap(find.text('大纲'));
    await tester.pump();
    await tester.tap(find.text('口腔执业/助理医师资格考试大纲'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(picked, isNotNull, reason: '点大纲确认项即整组确认（dagang+outline）');
    expect(picked!.subject.id, 'dagang');
    expect(picked!.sourceType, 'outline');

    // 与 App 同路落盘（_pickAndUpload 第 3 步同款调用）→ 大纲树（仅 .docx）
    final res = await ApiClient.instance.uploadCourseware(
      picked!.subject.id,
      '2-口腔执业医师资格考试大纲.docx',
      [0x50, 0x4B, 0x03, 0x04], // PK 魔数
      source: picked!.sourceType,
    );
    expect(res.ok, true);
    expect(res.pending, 1);
    expect(
      File('${tmp.path}/corpus/incoming/dagang-outline/2-口腔执业医师资格考试大纲.docx')
          .existsSync(),
      true,
      reason: '选「大纲」必须落 incoming/dagang-outline/（大纲树约定）',
    );
    expect(
      Directory('${tmp.path}/corpus/incoming/dagang').existsSync(),
      false,
      reason: '大纲上传不落课件树',
    );

    // 守卫：dagang 不进 subjects 表（科目目录仍只有 oms）
    final subs = await ApiClient.instance.fetchSubjectCatalog();
    expect(subs.any((s) => s.id == 'dagang'), isFalse,
        reason: '上传大纲绝不自动建 subject');

    // 防御 1：source=outline + 非 dagang 短码 → 400
    await expectLater(
      ApiClient.instance.uploadCourseware(
        'oms',
        '越权.docx',
        [0x50, 0x4B, 0x03, 0x04],
        source: 'outline',
      ),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 400)),
      reason: '大纲上传短码固定 dagang',
    );

    // 防御 2：source=outline + 非 .docx → 400（大纲只收 Word）
    await expectLater(
      ApiClient.instance.uploadCourseware(
        'dagang',
        '大纲.pdf',
        [0x25, 0x50, 0x44, 0x46],
        source: 'outline',
      ),
      throwsA(isA<ApiException>()
          .having((e) => e.statusCode, 'statusCode', 400)),
      reason: '大纲仅支持 .docx',
    );
  });
}
