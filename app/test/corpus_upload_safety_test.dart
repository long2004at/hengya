import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/open.dart';
import 'package:hengya/pages/corpus_tools_panel.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';

class _OversizedFile extends XFile {
  _OversizedFile() : super('large.pdf');
  bool read = false;
  @override
  Future<int> length() async => ApiClient.maxCoursewareBytes + 1;
  @override
  Future<Uint8List> readAsBytes() async {
    read = true;
    throw StateError('不应读取超限文件');
  }
}

/// 内存假文件：length/readAsBytes 均为微任务，不触碰真实文件系统——
/// widget 测试的 fake-async 区无法驱动真实磁盘 I/O（会永久挂起）。
class _InMemoryFile extends XFile {
  _InMemoryFile() : super('lesson.pdf');
  @override
  Future<int> length() async => 8;
  @override
  Future<Uint8List> readAsBytes() async =>
      Uint8List.fromList('%PDF-1.4'.codeUnits);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }
  late Directory temp;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('hengya-upload-safety-');
  });
  tearDown(() async {
    await LocalBackend.instance.resetForTest();
    debugBackendMode = null;
    ApiClient.instance.resetSubjectCaches();
    temp.deleteSync(recursive: true);
  });
  Future<void> boot(WidgetTester tester, XFile file) async {
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(temp.path);
    debugBackendMode = BackendMode.local;
    ApiClient.instance.resetSubjectCaches();
    SharedPreferences.setMockInitialValues({});
    await LocalBackend.instance.post('/subjects', {'id': 'math', 'name': '数学'});
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CorpusToolsPanel(selectFile: () async => file),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('超限文件在整文件读取前拒绝，取消后上传入口仍可用', (tester) async {
    final file = _OversizedFile();
    await boot(tester, file);
    await tester.tap(find.text('上传课件'));
    await tester.pumpAndSettle();
    expect(file.read, false);
    expect(find.text('选择科目与类型'), findsNothing);
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('上传课件'), matching: find.byType(ListTile)),
    );
    expect(tile.onTap, isNotNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets('底层文件写入异常不会留下不可关闭的上传弹窗', (tester) async {
    // 内存假文件（避免 fake-async 下的真实 I/O 挂起）；写入异常由下方同名
    // 阻塞文件制造（uploadCourseware 的 createSync 会失败）。
    final file = _InMemoryFile();
    await boot(tester, file);
    Directory('${temp.path}/corpus/incoming').createSync(recursive: true);
    File(
      '${temp.path}/corpus/incoming/math',
    ).writeAsStringSync('阻止创建同名目录，模拟写入异常');
    await tester.tap(find.text('上传课件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('数学'));
    await tester.pumpAndSettle();
    expect(find.text('正在上传'), findsNothing);
    expect(tester.takeException(), isNull);
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('上传课件'), matching: find.byType(ListTile)),
    );
    expect(tile.onTap, isNotNull);
  });
}
