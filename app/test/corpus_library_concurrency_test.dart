import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/api/api_client.dart';

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }
  late Directory temp;
  final backend = LocalBackend.instance;
  setUp(() async {
    await backend.resetForTest();
    temp = Directory.systemTemp.createTempSync('hengya-corpus-queue-');
    backend.init(temp.path);
    await backend.sharedDb;
  });
  tearDown(() async {
    await backend.resetForTest();
    temp.deleteSync(recursive: true);
  });
  test('列表与详情只读请求按顺序完成，不互相409；写入期间仍受保护', () async {
    final gate = Completer<Map<String, dynamic>>();
    final started = Completer<void>();
    final calls = <String>[];
    addTearDown(() {
      if (!gate.isCompleted) gate.complete({});
    });
    backend.corpusLibraryOverride = (operation, args) async {
      calls.add(operation);
      if (calls.length == 1) {
        started.complete();
        return gate.future;
      }
      return {'order': 2};
    };
    final first = backend.get('/corpus/library');
    await started.future;
    final second = backend.get('/corpus/library/content?id=test');
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['inventory']);
    expect(backend.corpusLibraryRunning, true);
    await expectLater(
      backend.post('/corpus/library/delete', {
        'id': 'test',
        'revision': 'test',
      }),
      throwsA(isA<ApiException>()),
    );
    gate.complete({'order': 1});
    expect((await first)['order'], 1);
    expect((await second)['order'], 2);
    expect(calls, ['inventory', 'content']);
    expect(backend.corpusLibraryRunning, false);
  });
  test('前一个读取失败不会让后续读取永远等待', () async {
    var calls = 0;
    backend.corpusLibraryOverride = (operation, args) async {
      calls++;
      if (calls == 1) throw StateError('failed');
      return {'ok': true};
    };
    final first = backend.get('/corpus/library');
    final second = backend.get('/corpus/library');
    await expectLater(first, throwsStateError);
    expect((await second)['ok'], true);
    expect(backend.corpusLibraryRunning, false);
  });
}
