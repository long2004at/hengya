import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:hengya/pages/rework_workbench_page.dart';
import 'package:hengya/pages/rework_request_sheet.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/corpus_library.dart';
import 'helpers/rework_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }
  final be = LocalBackend.instance;
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya-rework-ui-');
  });
  tearDown(() async {
    await be.resetForTest();
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    tmp.deleteSync(recursive: true);
  });
  Future<void> boot(WidgetTester tester) async {
    await be.resetForTest();
    be.init(tmp.path);
    debugBackendMode = BackendMode.local;
    ApiClient.instance.resetSubjectCaches();
    SharedPreferences.setMockInitialValues({});
    await be.post('/subjects', {'id': 'endo', 'name': '测试课程'});
    await be.importCards([
      {
        'id': 'parent',
        'subjectId': 'endo',
        'type': 'basic',
        'front': '原始问题',
        'back': '原始答案',
        'anchor': 'p1',
        'source': '课程',
        'status': 'pending',
      },
    ]);
    await be.post('/cards/parent/approve', null);
    tester.view.physicalSize = const Size(900, 1900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  Future<int> task(String action, String reason) async =>
      (await be.post('/rework/tasks', {
            'cardId': 'parent',
            'action': action,
            'reasons': [reason],
            'targetCount': 2,
          }))['taskId']
          as int;
  Future<void> show(WidgetTester tester, int id) async {
    await tester.pumpWidget(MaterialApp(home: ReworkWorkbenchPage(taskId: id)));
    await tester.pumpAndSettle();
  }

  void seed() {
    final path = '${tmp.path}/corpus/corpus.db';
    Directory('${tmp.path}/corpus').createSync(recursive: true);
    final c = sqlite3.open(path);
    seedReworkEvidence(c, id: 'e1');
    c.dispose();
  }

  testWidgets('暂缓必须二次确认并逐项勾选，可从工作台恢复原卡', (tester) async {
    await boot(tester);
    final id = await task('defer', '目前还没学到');
    await show(tester, id);
    await tester.tap(find.text('确认暂缓'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认应用'));
    await tester.pumpAndSettle();
    expect((await be.get('/rework/tasks/$id'))['status'], 'needs_input');
    expect(find.textContaining('请逐项确认所有问题'), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile).last);
    await tester.tap(find.text('确认应用'));
    await tester.pumpAndSettle();
    expect((await be.get('/rework/tasks/$id'))['status'], 'deferred');
    await tester.tap(find.text('恢复原卡'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认恢复'));
    await tester.pumpAndSettle();
    expect((await be.get('/cards/parent'))['status'], 'active');
    expect((await be.get('/rework/tasks/$id'))['status'], 'cancelled');
  });
  testWidgets('修改前后对比可见，草案不自动覆盖，人工确认后应用', (tester) async {
    await boot(tester);
    seed();
    final id = await task('rewrite', '答案有误');
    var t = await be.get('/rework/tasks/$id');
    await be.post('/rework/tasks/$id/configure', {
      'revision': t['revision'],
      'action': 'rewrite',
      'instructions': '纠正定义',
      'targetCount': 2,
      'selectedIds': ['e1'],
    });
    t = await be.get('/rework/tasks/$id');
    await be.post('/rework/tasks/$id/draft', {
      'revision': t['revision'],
      'draft': validReworkDraft(t, front: '修正题干', back: '修正答案'),
    });
    await show(tester, id);
    expect(find.text('原卡快照（不会被草案覆盖）'), findsOneWidget);
    expect(find.text('检查并应用'), findsOneWidget);
    expect((await be.get('/cards/parent'))['front'], '原始问题');
    await tester.tap(find.text('检查并应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckboxListTile, '答案有误'));
    await tester.tap(find.text('确认应用'));
    await tester.pumpAndSettle();
    expect((await be.get('/cards/parent'))['front'], '修正题干');
    expect((await be.get('/rework/tasks/$id'))['status'], 'applied');
  });
  testWidgets('从统一语料库选取原文，并保存为任务固定证据', (tester) async {
    await boot(tester);
    seed();
    final id = await task('rewrite', '答案有误');
    be.corpusLibraryOverride = (operation, args) async {
      if (operation == 'inventory') {
        return CorpusInventory(
          documents: [
            const CorpusDocument(
              id: 'doc',
              kind: 'deck',
              subjectId: 'endo',
              title: '可引用资料',
              types: ['textbook'],
              chunks: 1,
              outlineEntries: 0,
              origin: 'package',
              files: [],
              revision: 'r',
            ),
          ],
          totalChunks: 1,
          totalOutlineEntries: 0,
          warnings: [],
          complete: true,
          pendingDeletion: false,
        ).toMap();
      }
      return {
        'total': 1,
        'items': [
          {
            'id': 'e1',
            'title': '原文段落',
            'text': '修复参考原文',
            'pageStart': 30,
            'pageEnd': 32,
            'type': 'textbook',
          },
        ],
      };
    };
    await show(tester, id);
    await tester.tap(find.text('选择证据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('从语料库添加原文'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('可引用资料'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('引用此段'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存证据（旧草案失效）'));
    await tester.pumpAndSettle();
    final t = await be.get('/rework/tasks/$id');
    expect(t['selectedIds'], ['e1']);
    expect((t['evidence'] as List).single['hash'], isNotEmpty);
    expect((await be.get('/cards/parent'))['front'], '原始问题');
  });
  testWidgets('超出教学范围推荐排除，但创建任务本身不会归档或生成卡片', (tester) async {
    await boot(tester);
    int? created;
    final card = (await be.sharedDb).cardById('parent')!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => FilledButton(
              onPressed: () async {
                created = await requestReworkTask(ctx, card);
              },
              child: const Text('回炉'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('回炉'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilterChip, '超出教学范围'));
    await tester.pumpAndSettle();
    expect(find.text('排除此卡'), findsOneWidget);
    await tester.tap(find.text('创建任务并查看'));
    await tester.pumpAndSettle();
    expect(created, isNotNull);
    final t = await be.get('/rework/tasks/$created');
    expect(t['action'], 'exclude');
    expect(t['status'], 'needs_input');
    expect((await be.get('/cards/parent'))['status'], 'rework');
  });
}
