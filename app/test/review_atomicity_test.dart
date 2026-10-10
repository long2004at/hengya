import 'dart:ffi';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:shared/hengya_shared.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/local/local_backend.dart';

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }
  late Directory temp;
  late Database inspect;
  final backend = LocalBackend.instance;
  ReviewLog log([String id = 'audit-card']) => ReviewLog(
    cardId: id,
    subjectId: 'math',
    rating: ReviewRating.smooth,
    reviewedAt: DateTime(2026, 10, 9, 10),
  );
  setUp(() async {
    await backend.resetForTest();
    temp = Directory.systemTemp.createTempSync('hengya-review-atomic-');
    backend.init(temp.path);
    debugBackendMode = BackendMode.local;
    await backend.post('/subjects', {'id': 'math', 'name': '数学'});
    await backend.importCards([
      {
        'id': 'audit-card',
        'subjectId': 'math',
        'front': '题目',
        'back': '答案',
        'source': '资料',
        'anchor': 'p1',
        'type': 'basic',
        'status': 'pending',
      },
    ]);
    await backend.post('/cards/audit-card/approve', null);
    inspect = sqlite3.open('${temp.path}/hengya.db');
  });
  tearDown(() async {
    inspect.dispose();
    await backend.resetForTest();
    debugBackendMode = null;
    temp.deleteSync(recursive: true);
  });
  Map<String, Object?> state() => Map<String, Object?>.from(
    inspect.select("SELECT * FROM cards WHERE id='audit-card'").single,
  );
  test('同一作答重复补传只记录一次，不重复计算记忆状态', () async {
    final client = ApiClient.instance;
    expect(await client.submitAnswer(log()), true);
    final after = state();
    expect(await client.submitAnswer(log()), true);
    expect(state(), after);
    expect(inspect.select('SELECT COUNT(*) n FROM review_logs').first['n'], 1);
  });
  test('日志写入失败时调度状态和数据版本都回滚', () async {
    final before = state();
    final version = inspect
        .select("SELECT value FROM meta WHERE key='data_version'")
        .first['value'];
    inspect.execute(
      "CREATE TRIGGER fail_audit_review BEFORE INSERT ON review_logs BEGIN SELECT RAISE(ABORT,'simulated disk failure'); END;",
    );
    await expectLater(
      backend.post('/review/answer', log().toJson()),
      throwsA(isA<SqliteException>()),
    );
    expect(state(), before);
    expect(inspect.select('SELECT COUNT(*) n FROM review_logs').first['n'], 0);
    expect(
      inspect
          .select("SELECT value FROM meta WHERE key='data_version'")
          .first['value'],
      version,
    );
  });
  test('批量外壳 ok=true 但单条被拒绝时，客户端必须返回未受理', () async {
    expect(await ApiClient.instance.submitAnswer(log('missing-card')), false);
    expect(inspect.select('SELECT COUNT(*) n FROM review_logs').first['n'], 0);
  });
}
