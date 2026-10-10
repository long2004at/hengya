import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:hengya/pages/corpus_library_page.dart';
import 'package:hengya/pages/settings_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/local/corpus_library.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }
  late Directory temp;
  late List<CorpusDocument> documents;
  late List<Map<String, Object?>> calls;
  var complete = true;
  CorpusDocument doc(
    String id,
    String subject,
    String type, {
    int chunks = 1,
    String kind = 'deck',
    List<String> related = const [],
  }) => CorpusDocument(
    id: id,
    kind: kind,
    subjectId: subject,
    title: '资料 $id',
    types: [type],
    chunks: kind == 'outline' ? 0 : chunks,
    outlineEntries: kind == 'outline' ? chunks : 0,
    origin: 'package',
    files: const [],
    revision: 'revision-$id',
    relatedSubjects: related,
  );
  setUp(() {
    temp = Directory.systemTemp.createTempSync('hengya-library-ui-');
    calls = [];
    complete = true;
    documents = [
      doc('math', 'math', 'ppt', chunks: 42),
      doc('unknown', 'oldcourse', 'textbook'),
      doc('exam', 'surgery', 'exam'),
      doc('outline', '@outline', 'outline', kind: 'outline', related: ['math']),
    ];
  });
  tearDown(() async {
    await LocalBackend.instance.resetForTest();
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });
  Future<void> boot() async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(temp.path);
    debugBackendMode = BackendMode.local;
    ApiClient.instance.resetSubjectCaches();
    SharedPreferences.setMockInitialValues({});
    await LocalBackend.instance.post('/subjects', {'id': 'math', 'name': '数学'});
    LocalBackend.instance.corpusLibraryOverride = (operation, args) async {
      calls.add({'operation': operation, ...args});
      switch (operation) {
        case 'inventory':
          return CorpusInventory(
            documents: List.of(documents),
            totalChunks: documents.fold(0, (n, d) => n + d.chunks),
            totalOutlineEntries: documents.fold(
              0,
              (n, d) => n + d.outlineEntries,
            ),
            warnings: complete ? [] : ['测试：登记文件损坏'],
            complete: complete,
            pendingDeletion: false,
          ).toMap();
        case 'content':
          final d = documents.firstWhere((d) => d.id == args['id']);
          final offset = args['offset'] as int;
          final query = args['query'] as String;
          final all = [
            for (var i = 0; i < d.entries; i++)
              if (query.isEmpty || '正文 $i'.contains(query))
                {
                  'id': '$i',
                  'title': '标题 $i',
                  'text': '正文 $i',
                  'pageStart': i + 1,
                  'pageEnd': i + 1,
                  'type': d.types.first,
                },
          ];
          return {
            'total': all.length,
            'items': all.skip(offset).take(args['limit'] as int).toList(),
          };
        case 'delete':
          documents.removeWhere((d) => d.id == args['id']);
          return {'ok': true};
        default:
          return {'ok': true};
      }
    };
  }

  Future<void> pump(
    WidgetTester tester, {
    String? subject,
    bool settings = false,
  }) async {
    await boot();
    tester.view.physicalSize = const Size(900, 1900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: settings
            ? const SettingsPage()
            : CorpusLibraryPage(subjectId: subject),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('科目入口包含对应正文和公共大纲，清除筛选可见旧科目和真题', (tester) async {
    await pump(tester, subject: 'math');
    expect(find.text('资料 math'), findsOneWidget);
    expect(find.text('资料 outline'), findsOneWidget);
    expect(find.text('资料 unknown'), findsNothing);
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(find.text('资料 unknown'), findsOneWidget);
    expect(find.text('资料 exam'), findsOneWidget);
  });
  testWidgets('资料详情分页读取后面内容，内容搜索查整份而非当前页', (tester) async {
    await pump(tester);
    await tester.tap(find.text('资料 math'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c['operation'] == 'content').last['offset'], 0);
    await tester.scrollUntilVisible(
      find.text('加载更多内容'),
      650,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 40,
    );
    await tester.tap(find.text('加载更多内容'));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c['operation'] == 'content').last['offset'], 40);
    await tester.scrollUntilVisible(
      find.byType(TextField),
      -650,
      scrollable: find
          .descendant(
            of: find.byType(ListView).last,
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 40,
    );
    await tester.enterText(find.byType(TextField), '正文 41');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(calls.where((c) => c['operation'] == 'content').last['offset'], 0);
    expect(
      calls.where((c) => c['operation'] == 'content').last['query'],
      '正文 41',
    );
    expect(
      find.byWidgetPredicate((w) => w is SelectableText && w.data == '正文 41'),
      findsOneWidget,
    );
  });
  testWidgets('删除必须确认，取消不写数据，确认后刷新统一清单', (tester) async {
    await pump(tester);
    await tester.tap(find.text('资料 unknown'));
    await tester.pumpAndSettle();
    // 详情页点删除后 AppBar 显示进度圈（永续动画）→ 用固定 pump 而非 settle。
    await tester.tap(find.byTooltip('删除整份资料'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('已经生成的卡片'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(calls.where((c) => c['operation'] == 'delete'), isEmpty);
    await tester.tap(find.byTooltip('删除整份资料'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('确认删除资料'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(calls.where((c) => c['operation'] == 'delete'), hasLength(1));
    expect(find.text('资料 unknown'), findsNothing);
  });
  testWidgets('读取不完整明确告警，详情删除不可点击', (tester) async {
    await pump(tester);
    complete = false;
    await tester.tap(find.byTooltip('刷新全部资料'));
    await tester.pumpAndSettle();
    expect(find.text('清单读取不完整，删除已禁用'), findsOneWidget);
    await tester.tap(find.text('资料 unknown'));
    await tester.pumpAndSettle();
    final button = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('清单不完整或清理未完成，不能删除'),
        matching: find.byType(IconButton),
      ),
    );
    expect(button.onPressed, isNull);
  });
  testWidgets('设置入口打开同一工作台，导入与建库只有一个工具页', (tester) async {
    await pump(tester, settings: true);
    await tester.ensureVisible(
      find.byKey(const ValueKey('settings-corpus-library')),
    );
    await tester.tap(find.byKey(const ValueKey('settings-corpus-library')));
    await tester.pumpAndSettle();
    expect(find.byType(CorpusLibraryPage), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, '导入与建库'));
    await tester.pumpAndSettle();
    expect(find.text('上传课件'), findsOneWidget);
    expect(find.byKey(const ValueKey('corpus-import-package')), findsOneWidget);
  });
  testWidgets('旧库科目恰好名为 @all 不与全部选项冲突', (tester) async {
    documents.add(doc('reserved', '@all', 'ppt'));
    await pump(tester);
    expect(tester.takeException(), isNull);
    final dropdown = tester
        .widgetList<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>),
        )
        .first;
    dropdown.onChanged!('@all');
    await tester.pumpAndSettle();
    expect(find.text('资料 reserved'), findsOneWidget);
    expect(find.text('资料 math'), findsNothing);
    await tester.tap(find.text('清除筛选'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
