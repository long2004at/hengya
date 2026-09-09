// 语料包导入 · 设置页区块 UI 测试（批5 节点③）
// ============================================================================
//
// testWidgets 假异步纪律（同 update_settings_ui_test.dart / corpus_build_
// panel_test.dart）：
//   - setUp/tearDown 100% 同步；boot() 放用例体首行；
//   - 用例体内文件操作全 Sync 变体；Windows 宿主显式加载 test/sqlite3.dll；
//   - SharedPreferences.setMockInitialValues({})（设置页 initState 读提醒配置）；
//   - file_selector 平台通道在测试宿主不存在（真机验证项）——点击入口走
//     失败 Toast 路径不炸；
//   - 面板 pump()+pump(450ms)；Toast 展示 3000ms 纪律。
//
// 覆盖：数据管理区「导入语料包」入口渲染 + 点击失败路径 / instruct 前缀
// 开关渲染（默认开=保持旧行为）+ 开关落库回读 + 接线断言（settings →
// assembleEmbedConfig）。
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/pages/settings_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/pipeline_runner.dart'
    show assembleEmbedConfig;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
        () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_pkg_ui_');
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
  }

  /// 打开设置页并等首屏异步加载落地（视口调高：ListView 惰性构建）。
  Future<void> openSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// instruct 开关 tile（按标题定位——页面还有提醒开关等多枚 SwitchListTile）
  SwitchListTile instructTile(WidgetTester tester) {
    final tile = find.ancestor(
      of: find.text('检索查询 instruct 前缀'),
      matching: find.byType(SwitchListTile),
    );
    return tester.widget<SwitchListTile>(tile.first);
  }

  testWidgets('数据管理区「导入语料包」入口渲染 + 点击不炸（通道真机验证项）',
      (tester) async {
    await boot();
    await openSettings(tester);

    expect(find.text('导入语料包（成品语料库）'), findsOneWidget);
    expect(find.text('导入数据库（迁移）'), findsOneWidget); // 既有入口不挤掉

    // 点击：file_selector 通道在测试宿主不可用 → 取消/失败路径不炸
    //（通道行为是返回 null（静默取消）或抛 MissingPluginException（失败
    // Toast）——两者都不该弹确认框或炸页；真机验证项）
    await tester.tap(find.text('导入语料包（成品语料库）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 450));
    expect(find.text('确认导入语料包？'), findsNothing); // 未进确认流
    expect(find.text('导入语料包（成品语料库）'), findsOneWidget); // 页面健在
  });

  testWidgets('instruct 开关：默认开=保持旧行为；点按落库回读 + 装配接线',
      (tester) async {
    await boot();
    await openSettings(tester);

    // 默认渲染：开（保持旧行为）
    expect(instructTile(tester).value, isTrue);
    // 说明文案（Gitee/模力方舟通道建议关闭）
    expect(find.textContaining('Gitee/模力方舟通道建议关闭'), findsOneWidget);

    // 关 → settings embedding.instructQuery='0' + 装配 queryInstruct=''
    await tester.tap(find.text('检索查询 instruct 前缀'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(instructTile(tester).value, isFalse);
    final db = await LocalBackend.instance.sharedDb;
    expect(db.settingGet('embedding.instructQuery'), '0');

    // 再点 → 回 '1'
    await tester.tap(find.text('检索查询 instruct 前缀'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(instructTile(tester).value, isTrue);
    expect(db.settingGet('embedding.instructQuery'), '1');

    // 接线：设置 '0' 后装配层 queryInstruct=''（禁用前缀）
    db.settingSet('embedding.apiKey', 'sk-ui-test');
    db.settingSet('embedding.model', 'M');
    db.settingSet('embedding.instructQuery', '0');
    expect(assembleEmbedConfig(db)!.queryInstruct, '');
  });
}
