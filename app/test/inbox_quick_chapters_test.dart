// #8 章节快捷点选 UI 专项（testWidgets，真 LocalBackend）：
//   1. 有罗盘科目 → 未学正文章以点选芯片呈现（辅文章/已学/不学章不出现）
//   2. 点选 + 提交 → 章节条目（source='study-log'）入箱且章名与教材目录一致
//   3. 无罗盘科目 → 无快捷区，自由输入照常
//   4. 科目切换 → 快捷区随科目刷新
//
// 宿主基建同 chapter_manager_sheet_test：Windows 显式加载 test/sqlite3.dll；
// setUp/tearDown 100% 同步；boot 在用例体首行；debugBackendMode 用后置回。
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/pages/inbox_sheet.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
      () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }

  late Directory tmp;
  final be = LocalBackend.instance;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_inboxquick_');
  });

  tearDown(() {
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    LocalBackend.instance.resetForTest(); // 不 await：真实事件队列 FIFO 自完成
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 用例体首行调用（体内事件循环由 pump 驱动，await 安全）
  Future<void> boot() async {
    await be.resetForTest();
    be.init(tmp.path);
    debugBackendMode = BackendMode.local;
    // 罗盘：endo 两科章（目录 no1 已越过、第一章 no2 未学）+ derm 占位
    final corpus = Directory('${tmp.path}/corpus')..createSync(recursive: true);
    File('${corpus.path}/progress.json').writeAsStringSync(jsonEncode({
      'version': 1,
      'subjects': {
        'endo': {
          'textbook': '牙体牙髓病学-第5版',
          'learned_through': 1,
          'updated_at': '2026-09-13T10:00:00',
          'chapters': [
            {'no': 1, 'title': '目录', 'page_start': 3},
            {'no': 2, 'title': '第一章 绪论', 'page_start': 14},
            {'no': 3, 'title': '第二章 龋病', 'page_start': 20},
          ],
        },
        'derm': {
          'textbook': null,
          'learned_through': 0,
          'updated_at': '2026-09-13T10:00:00',
          'chapters': <Object?>[],
        },
      },
    }));
    await be.post('/subjects', {'name': '牙体牙髓病学', 'id': 'endo'});
    await be.post('/subjects', {'name': '皮肤性病学', 'id': 'derm'});
  }

  Future<void> openSheet(WidgetTester tester, {String? preset}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: FilledButton(
            onPressed: () => showInboxSheet(
              tester.element(find.byType(FilledButton)),
              presetSubjectId: preset,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('有罗盘科目：未学正文章成点选芯片，辅文章不出现', (tester) async {
    await boot();
    await openSheet(tester, preset: 'endo');

    // 未学正文章两章在列；已越过的辅文「目录」不在快捷区
    expect(find.text('第一章 绪论'), findsOneWidget);
    expect(find.text('第二章 龋病'), findsOneWidget);
    expect(find.text('快捷点选（未学章节，点选即报学）'), findsOneWidget);
    expect(find.text('目录'), findsNothing);
  });

  testWidgets('点选提交 → study-log 章节条目入箱（章名与目录一致）', (tester) async {
    await boot();
    await openSheet(tester, preset: 'endo');

    await tester.ensureVisible(find.text('存入收件箱'));
    await tester.pump();
    await tester.tap(find.text('第二章 龋病'));
    await tester.pump();
    await tester.tap(find.text('存入收件箱'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final inbox = await be.get('/inbox/pending');
    final rows = ((inbox as Map)['list'] as List)
        .cast<Map<String, dynamic>>()
        .where((r) => r['subjectId'] == 'endo' && r['source'] == 'study-log')
        .toList();
    expect(rows, hasLength(1), reason: '点选章必须以 study-log 条目入箱');
    expect(rows.single['keyword'], '第二章 龋病',
        reason: '章名必须与教材目录一致（流水线检索依赖）');
  });

  testWidgets('无罗盘科目：无快捷区，手输章节照常入箱', (tester) async {
    await boot();
    await openSheet(tester, preset: 'derm');

    expect(find.text('快捷点选（未学章节，点选即报学）'), findsNothing);

    await tester.enterText(
      find.byType(TextField).first,
      '第一章 总论',
    );
    await tester.ensureVisible(find.text('存入收件箱'));
    await tester.pump();
    await tester.tap(find.text('存入收件箱'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    final inbox = await be.get('/inbox/pending');
    final rows = ((inbox as Map)['list'] as List)
        .cast<Map<String, dynamic>>()
        .where((r) => r['subjectId'] == 'derm' && r['source'] == 'study-log')
        .toList();
    expect(rows.single['keyword'], '第一章 总论',
        reason: '无罗盘科目自由输入照常');
  });
}
