// 应用内更新 · 关于页（AboutPage）区块 UI smoke 测试（batch3 node1；v0.1.9
// 应用内更新区块自设置页迁入 AboutPage，测试随之改打「关于页」）
// ============================================================================
//
// testWidgets 假异步纪律全套（同 corpus_build_panel_test.dart）：
//   - setUp/tearDown 100% 同步（任何 await 永挂）；boot() 放用例体首行；
//   - 用例体内文件操作全 Sync 变体；Windows 宿主显式加载 test/sqlite3.dll；
//   - SharedPreferences.setMockInitialValues({})（设置页 initState 读提醒配置）；
//   - 真实 HTTP 绝不在 testWidgets 内触发（宿主 HttpClient 为恒 400 假实现）：
//     检查链路经 UpdateService.debugFetchOverride 注入 fake latest.json，
//     当前版本经 UpdateService.debugChannelOverride 注入假 getPackageInfo；
//   - 文案逐字断言（UpdateMessages 为准绳）。
//
// 覆盖：区块渲染 / 空源 / 已是最新 / 发现新版本 / 网络失败 / 源 URL 落库回显
//（安全修复 B：fake 清单均带合法 Ed25519 签名，公钥经
//  UpdateService.debugPublicKeyOverride 注入固定测试密钥对）
import 'dart:convert' as convert;
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/pages/about_page.dart';
import 'package:hengya/pages/settings_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/update/update_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

import 'update_sign_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
      () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }

  late Directory tmp;
  // 固定测试密钥对（boot() 内派生——同 seed 恒同 key；纯 Dart 计算无定时器）
  late UpdateSignFixture fx;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_update_ui_');
  });

  tearDown(() {
    UpdateService.debugFetchOverride = null;
    UpdateService.debugChannelOverride = null;
    UpdateService.debugPublicKeyOverride = null;
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
    // 关于页/设置页 initState：DailyReminder.loadSettings 走 SharedPreferences（内存 mock）
    SharedPreferences.setMockInitialValues({});
    // 验签公钥 = 固定测试密钥对公钥（安全修复 B；生产 asset 不在测试宿主）
    fx = await UpdateSignFixture.load();
    UpdateService.debugPublicKeyOverride = fx.publicKeyBytes;
    // 假原生：当前应用版本（真通道在测试宿主不存在）
    UpdateService.debugChannelOverride = (method, [args]) async {
      if (method == 'getPackageInfo') {
        return {'versionName': '1.6.2+14', 'versionCode': 14};
      }
      return null;
    };
  }

  /// 打开设置页并等首屏异步加载落地（同 corpus_build_panel_test 的 settle 姿势；
  /// 视口调高：ListView 惰性构建，默认 600 高度下更新区块整个在折叠线以下）。
  Future<void> openSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: SettingsPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 打开关于页（v0.1.9 应用内更新区块迁入地）并等首屏异步加载落地。
  /// 视口调高：头部卡 + 版本更新卡在折叠线以下时会被 ListView 惰性裁剪。
  Future<void> openAbout(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// 点击「检查更新」后泵到状态落地
  Future<void> tapCheckAndSettle(WidgetTester tester) async {
    await tester.tap(find.text(UpdateMessages.checkButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// fake latest.json 原文（带合法 Ed25519 签名——安全修复 B 后 checkUpdate 必验；
  /// 公钥已在 boot() 注入 fx 公钥）
  Future<String> manifestJson({
    String versionName = '1.7.0+15',
    int versionCode = 15,
    int sizeBytes = 1234567,
    String notes = '修复若干问题',
  }) async {
    const apk = 'heng-1.7.0+15-local-release.apk';
    const sha256 =
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final payload = fx.canonicalPayload(
      versionName: versionName,
      versionCode: versionCode,
      apk: apk,
      sha256: sha256,
      sizeBytes: sizeBytes,
    );
    return convert.jsonEncode({
      'versionName': versionName,
      'versionCode': versionCode,
      'apk': apk,
      'sha256': sha256,
      'sizeBytes': sizeBytes,
      'date': '2026-09-07T12:00:00Z',
      'notes': notes,
      'signature': await fx.sign(payload),
    });
  }

  testWidgets('更新区块渲染：版本行 / 源输入框 / 检查按钮', (tester) async {
    await boot();
    await openAbout(tester);

    expect(find.text('版本更新'), findsOneWidget); // 分组标题
    expect(find.text('检查新版本'), findsOneWidget); // 区块主行
    expect(find.textContaining('当前版本 v1.6.2+14'), findsOneWidget); // 版本号
    expect(find.text(UpdateMessages.sourceLabel), findsOneWidget); // 输入框标签
    expect(
      find.text(UpdateMessages.overseasLineButton),
      findsOneWidget,
    ); // 海外线路按钮
    expect(
      find.text(UpdateMessages.domesticLineButton),
      findsOneWidget,
    ); // 国内线路按钮
    // 新装（db 未设置源）→ 输入框预填 GitHub 默认源（hint 仅空时可见，不再断言）
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, UpdateService.githubSourceUrl);
    expect(find.text(UpdateMessages.checkButton), findsOneWidget); // 按钮
    // idle 相位不渲染状态区（无检查中/已是最新等字样）
    expect(find.text(UpdateMessages.checking), findsNothing);
    expect(find.textContaining('已是最新版本'), findsNothing);
  });

  testWidgets('清空源（国内线路）后点检查 → 「请先填写更新源」', (tester) async {
    await boot();
    await openAbout(tester);

    await tester.tap(find.text(UpdateMessages.domesticLineButton)); // 清空预填
    await tester.pump();
    await tapCheckAndSettle(tester);

    expect(find.text(UpdateMessages.emptySource), findsOneWidget);
  });

  testWidgets('fake 检查：versionCode 相等 → 「已是最新版本（v1.6.2+14）」', (tester) async {
    await boot();
    UpdateService.debugFetchOverride = (url) async =>
        await manifestJson(versionName: '1.6.2+14', versionCode: 14);
    await openAbout(tester);

    await tester.enterText(
      find.byType(TextField),
      'http://127.0.0.1:9999/heng-token/latest.json',
    );
    await tapCheckAndSettle(tester);

    expect(find.text(UpdateMessages.upToDate('1.6.2+14')), findsOneWidget);
    expect(find.textContaining('已是最新版本'), findsOneWidget);
    expect(find.text(UpdateMessages.downloadButton), findsNothing);
  });

  testWidgets('fake 检查：versionCode 更大 → 发现新版本（notes + 大小 + 下载按钮）', (
    tester,
  ) async {
    await boot();
    UpdateService.debugFetchOverride = (url) async => await manifestJson();
    await openAbout(tester);

    await tester.enterText(
      find.byType(TextField),
      'http://127.0.0.1:9999/heng-token/latest.json',
    );
    await tapCheckAndSettle(tester);

    // AboutPage 把 foundNew 与 sizeOf 合并进同一 Text → 用 textContaining
    expect(
      find.textContaining(UpdateMessages.foundNew('1.7.0+15')),
      findsOneWidget,
    );
    expect(find.text('修复若干问题'), findsOneWidget); // notes
    expect(
      find.textContaining('大小 1.2 MB'),
      findsOneWidget,
    ); // 1234567 B → 1.2 MB
    expect(
      find.widgetWithText(FilledButton, UpdateMessages.downloadButton),
      findsOneWidget,
    ); // 页面他处还有 FilledButton，按文本收敛到下载按钮
  });

  testWidgets('fake 检查：源抛错 → 网络失败文案', (tester) async {
    await boot();
    UpdateService.debugFetchOverride = (url) async => throw StateError('boom');
    await openAbout(tester);

    await tester.enterText(
      find.byType(TextField),
      'http://127.0.0.1:9999/heng-token/latest.json',
    );
    await tapCheckAndSettle(tester);

    expect(find.text(UpdateMessages.unreachable), findsOneWidget);
  });

  testWidgets('源 URL 落库 + 重开设置页回显（db settings update.source）', (tester) async {
    await boot();
    UpdateService.debugFetchOverride = (url) async =>
        await manifestJson(versionName: '1.6.2+14', versionCode: 14);
    await openAbout(tester);

    const url = 'http://47.98.1.2:8080/heng-abc123/latest.json';
    await tester.enterText(find.byType(TextField), url);
    await tapCheckAndSettle(tester); // 检查前落库

    // 已持久化到 db settings（直接查真库）
    final db = await LocalBackend.instance.sharedDb;
    expect(db.settingGet(UpdateService.sourceKey), url);

    // 重开设置页 → 回显
    await tester.pumpWidget(const SizedBox());
    await openAbout(tester);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, url);
  });

  testWidgets('海外线路：输入任意值后一键填回 GitHub 默认源并落库', (tester) async {
    await boot();
    await openAbout(tester);

    await tester.enterText(
      find.byType(TextField),
      'http://example.com/other/latest.json',
    );
    await tester.tap(find.text(UpdateMessages.overseasLineButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, UpdateService.githubSourceUrl);
    // 一键填入即落库（db settings update.source）
    final db = await LocalBackend.instance.sharedDb;
    expect(
      db.settingGet(UpdateService.sourceKey),
      UpdateService.githubSourceUrl,
    );
  });

  testWidgets('国内线路：清空输入框并聚焦（不预设任何 URL）', (tester) async {
    await boot();
    await openAbout(tester);

    await tester.tap(find.text(UpdateMessages.domesticLineButton));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, ''); // 不预设 URL（ECS 直链不入 APK）
    expect(field.focusNode!.hasFocus, isTrue); // 聚焦待手动粘贴
  });

  testWidgets('设置页「恒牙」行 → 打开关于页（版本更新 / 诊断 / 存储）', (tester) async {
    await boot();
    await openSettings(tester);

    // 「恒牙」行在设置页长 ListView 深处 → 滚动到可见
    await tester.scrollUntilVisible(
      find.widgetWithText(ListTile, '恒牙'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.widgetWithText(ListTile, '恒牙'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // 关于页三区块均落地
    expect(find.text('版本更新'), findsOneWidget);
    expect(find.text('检查新版本'), findsOneWidget);
    expect(find.text('清除缓存'), findsOneWidget);
    expect(find.text('日志'), findsOneWidget);
  });
}
