// 真正触发 worker 和磁盘备份/恢复；只替代系统文件选择器，不替代备份业务。
import 'dart:convert';
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/pages/about_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/ai_key_vault.dart';
import 'package:hengya/services/local/corpus/extract_all.dart'
    show schemaChunks, schemaVectors, schemaMeta;
import 'package:hengya/services/local/data_maintenance.dart';
import 'package:hengya/services/local/data_manager.dart';
import 'package:hengya/services/local/full_backup.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/pipeline_runner.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }
  const picker = MethodChannel('plugins.flutter.io/file_selector');
  late Directory root;
  String? selectedPath;
  Object? pickerError;
  Map<dynamic, dynamic>? pickerArgs;
  final be = LocalBackend.instance;
  final backups = FullBackupManager.instance;

  setUp(() {
    root = Directory.systemTemp.createTempSync('hengya_full_backup_ui_');
    selectedPath = null;
    pickerError = null;
    pickerArgs = null;
    AiKeyVault.instance = InMemoryVault();
    SharedPreferences.setMockInitialValues({});
    debugBackendMode = BackendMode.local;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, (
      call,
    ) async {
      pickerArgs = call.arguments as Map;
      if (pickerError != null) throw pickerError!;
      return selectedPath == null ? null : [selectedPath];
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(picker, null);
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    AiKeyVault.instance = null;
    be.resetForTest();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> boot() async {
    await be.resetForTest();
    be.init(root.path);
    await be.post('/subjects', {'id': 'oms', 'name': '备份测试科目'});
    await be.importCards([
      {
        'id': 'backup-card',
        'subjectId': 'oms',
        'type': 'basic',
        'front': '备份题干',
        'back': '备份答案',
        'anchor': 'a',
        'source': 's',
        'status': 'pending',
      },
    ]);
    Directory('${root.path}/corpus').createSync();
    final corpus = sqlite3.open('${root.path}/corpus/corpus.db');
    try {
      for (final ddl in [schemaChunks, schemaVectors, schemaMeta]) {
        corpus.execute(ddl);
      }
      corpus.execute(
        "INSERT INTO chunks(chunk_id,subject_id,ppt_id,text) VALUES ('c1','oms','deck','备份语料')",
      );
      corpus.execute('INSERT INTO vectors VALUES (?,?,?,?)', [
        'c1',
        4,
        Uint8List.fromList([1, 2, 3, 4]),
        0.25,
      ]);
      corpus.execute(
        "INSERT INTO meta VALUES ('embedding_model','backup-model')",
      );
    } finally {
      corpus.dispose();
    }
    File('${root.path}/corpus/progress.json').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'subjects': {
          'oms': {
            'learned_through': 3,
            'skipped': [2],
          },
        },
      }),
    );
  }

  Future<void> openAbout(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 4200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: AboutPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> until(WidgetTester tester, bool Function() ready) async {
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 30));
      if (ready()) return;
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
    }
    fail('等待真实备份 worker 完成超时');
  }

  Finder tile(String title) => find.widgetWithText(ListTile, title);

  testWidgets('按钮紧跟导出分享；真正生成含向量的完整包，忙时禁用，48h内可再备', (tester) async {
    await boot();
    await openAbout(tester);
    final button = find.byKey(const ValueKey('backup-now'));
    expect(button, findsOneWidget);
    expect(
      tester.getTopLeft(button).dy,
      greaterThan(tester.getBottomLeft(tile('一键导出并分享')).dy),
    );
    expect(find.textContaining('尚无完整备份'), findsOneWidget);
    final press = tester.widget<ListTile>(button).onTap!;
    press();
    press(); // 同一帧重复点击也只能开一个 worker
    await tester.pump();
    expect(tester.widget<ListTile>(button).onTap, isNull);
    expect(tester.widget<ListTile>(tile('导入数据库（迁移）')).onTap, isNull);
    await until(
      tester,
      () => !DataMaintenance.busy && backups.backupsOf(root.path).length == 1,
    );
    await tester.pump();
    expect(find.textContaining('已有 1 份完整备份'), findsOneWidget);
    expect(find.text('分享最近完整备份'), findsOneWidget);
    final checked = await tester.runAsync(
      () => backups.validateBackup(backups.backupsOf(root.path).single.path),
    );
    expect(checked!.vectors, 1);
    expect(checked.cards, 1);
    expect(checked.hasProgress, isTrue);
    expect(pickerArgs, isNull, reason: '备份不依赖文件选择或分享面板');
    await tester.tap(find.text('立刻备份'));
    await until(
      tester,
      () => !DataMaintenance.busy && backups.backupsOf(root.path).length == 2,
    );
    await tester.pump();
    expect(find.textContaining('已有 2 份完整备份'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('完整zip先预览和确认；取消不改数据，确认后向量、进度和主库一起恢复', (tester) async {
    await boot();
    final saved = await tester.runAsync(() => backups.createBackup(root.path));
    selectedPath = saved!.path;
    await be.post('/subjects', {'id': 'extra', 'name': '恢复前新增科目'});
    final corpus = sqlite3.open('${root.path}/corpus/corpus.db');
    corpus.execute('DELETE FROM vectors');
    corpus.dispose();
    File(
      '${root.path}/corpus/progress.json',
    ).writeAsStringSync('{"version":1,"subjects":{}}');
    await ApiClient.instance.fetchSubjectCatalog(refresh: true);
    await openAbout(tester);
    await tester.tap(find.text('导入数据库（迁移）'));
    await until(tester, () => find.text('恢复完整备份？').evaluate().isNotEmpty);
    expect(pickerArgs!['acceptedTypeGroups'].toString(), contains('zip'));
    expect(find.textContaining('1 条向量'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await be.get('/subjects'))['subjects'], hasLength(2));
    await tester.tap(find.text('导入数据库（迁移）'));
    await until(tester, () => find.text('恢复完整备份？').evaluate().isNotEmpty);
    await tester.tap(find.text('确认恢复'));
    await until(
      tester,
      () =>
          !DataMaintenance.busy &&
          tester.widget<ListTile>(tile('导入数据库（迁移）')).onTap != null,
    );
    expect((await be.get('/subjects'))['subjects'], hasLength(1));
    expect(await ApiClient.instance.fetchSubjectCatalog(), hasLength(1));
    final restored = sqlite3.open('${root.path}/corpus/corpus.db');
    expect(restored.select('SELECT vec FROM vectors').single['vec'], [
      1,
      2,
      3,
      4,
    ]);
    restored.dispose();
    final progress =
        jsonDecode(File('${root.path}/corpus/progress.json').readAsStringSync())
            as Map;
    expect(progress['subjects']['oms']['learned_through'], 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('坏包或文件选择失败明确提示，不改主库且按钮恢复可用', (tester) async {
    await boot();
    final bad = File('${root.path}/bad.zip')..writeAsStringSync('not zip');
    selectedPath = bad.path;
    await openAbout(tester);
    await tester.tap(find.text('导入数据库（迁移）'));
    await until(
      tester,
      () => find.textContaining('导入失败：').evaluate().isNotEmpty,
    );
    expect(find.text('恢复完整备份？'), findsNothing);
    expect((await be.get('/subjects'))['subjects'], hasLength(1));
    expect(tester.widget<ListTile>(tile('立刻备份')).onTap, isNotNull);
    pickerError = PlatformException(code: 'picker-failed');
    await tester.tap(find.text('导入数据库（迁移）'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('picker-failed'), findsOneWidget);
    expect(tester.widget<ListTile>(tile('导入数据库（迁移）')).onTap, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧db导入仍可用，确认框明确说明不含向量和知识库', (tester) async {
    await boot();
    selectedPath = DataManager.instance.exportDatabase(root.path);
    await be.post('/subjects', {'id': 'extra', 'name': '恢复前科目'});
    await openAbout(tester);
    await tester.tap(find.text('导入数据库（迁移）'));
    await until(tester, () => find.text('确认导入？').evaluate().isNotEmpty);
    expect(find.text('确认导入？'), findsOneWidget);
    expect(find.textContaining('仅替换主数据库'), findsOneWidget);
    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    expect((await be.get('/subjects'))['subjects'], hasLength(1));
    final corpus = sqlite3.open('${root.path}/corpus/corpus.db');
    expect(corpus.select('SELECT count(*) n FROM vectors').single['n'], 1);
    corpus.dispose();
    expect(tester.takeException(), isNull);
  });

  test('维护锁阻止路由写入、旧db导入及流水线启动，原数据不变', () async {
    await boot();
    final marker = File(PipelineRunner.markerPath(root.path))
      ..writeAsStringSync('queued');
    final token = DataMaintenance.acquire('完整备份');
    try {
      final blocked = throwsA(
        isA<ApiException>().having((e) => e.statusCode, 'status', 409),
      );
      await expectLater(
        be.post('/subjects', {'id': 'blocked', 'name': '不应写入'}),
        blocked,
      );
      await expectLater(be.put('/subjects/oms', {'name': '不应改名'}), blocked);
      await expectLater(be.upload('/corpus/upload', [1]), blocked);
      await expectLater(be.importCards([]), blocked);
      await expectLater(
        DataManager.instance.importDatabase(
          root.path,
          '${root.path}/hengya.db',
        ),
        throwsA(isA<DataManagerException>()),
      );
      await PipelineRunner.instance.consumeForceRun();
      expect(PipelineRunner.instance.running, isFalse);
      expect(marker.existsSync(), isTrue);
    } finally {
      DataMaintenance.release(token);
    }
    expect((await be.get('/subjects'))['subjects'], hasLength(1));
  });
}
