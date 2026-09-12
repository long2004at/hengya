// #11 卡片查重单测（2026-09-13）：余弦计算 / 命中标记 / 降级 skipped /
// 下轮自动补查。Db 用临时目录真实开库（迁移含 dup_check/dup_of/card_vectors）。
import 'dart:ffi' show DynamicLibrary;
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/services/local/card_dedup.dart';
import 'package:hengya/services/local/db.dart';
import 'package:shared/hengya_shared.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

Uint8List f32(List<double> v) => Float32List.fromList(v).buffer.asUint8List();

void main() {
  late Directory tmp;
  late Db db;

  setUpAll(() async {
    // Windows 测试宿主：显式加载 test/sqlite3.dll（CWD = 包根 app/）
    if (Platform.isWindows) {
      sqlite_open.open.overrideForAll(
        () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
      );
    }
    tmp = await Directory.systemTemp.createTemp('hengya-dedup-test');
    db = await Db.open('${tmp.path}/hengya.db');
    db.seedSubjects(const [
      Subject(id: 'endo', name: '牙体牙髓', isExamSubject: false),
    ]);
  });

  tearDownAll(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  int insertCard(String id, String front) {
    final ok = db.importCard(
      FlashCard(
        id: id,
        subjectId: 'endo',
        type: CardType.basic,
        front: front,
        back: 'B',
        anchor: 'a',
        source: 's',
        status: CardStatus.pending,
      ),
    );
    return ok ? 1 : 0;
  }

  test('dupCosine：同向=1、正交=0、维度不符=0', () {
    expect(dupCosine(f32([1, 2, 3]), f32([2, 4, 6])), closeTo(1.0, 1e-6));
    expect(dupCosine(f32([1, 0]), f32([0, 1])), 0);
    expect(dupCosine(f32([1, 0]), f32([1, 0, 0])), 0);
  });

  test('runCardDupPass：相似 → dup 指向；不相似 → ok；同批互检', () async {
    // 已有卡「牙菌斑可分为哪两类」预置向量 v1
    insertCard('endo-old-1', '根据所在部位，牙菌斑可分为哪两类？');
    final v1 = List<double>.generate(8, (i) => math.sin(i + 1));
    db.saveCardVector('endo-old-1', 'test-model', 8, f32(v1));

    // 新卡 A：与 v1 相似度高 → dup 指向 endo-old-1；新卡 B：正交向量 → ok
    final nearV1 = [for (var i = 0; i < 8; i++) v1[i] + 0.01];
    final ortho = [
      for (var i = 0; i < 8; i++) (i.isEven ? 1.0 : -1.0) * (i % 3 + 1) / 3,
    ];
    insertCard('endo-new-a', '根据部位，牙菌斑分为哪两型？各有什么特点？');
    insertCard('endo-new-b', '变形链球菌的致龋机制是什么？');

    final logs = <String>[];
    final res = await runCardDupPass(
      db: db,
      model: 'test-model',
      threshold: 0.92,
      embedBatch: (texts) async {
        final out = <List<double>>[];
        for (final t in texts) {
          out.add(t.contains('牙菌斑') ? nearV1 : ortho);
        }
        return out;
      },
      log: (level, tag, msg) => logs.add('[$level][$tag] $msg'),
    );

    expect(res.embedded, 2);
    expect(res.dupMarked, 1);
    final a = db.cardById('endo-new-a')!;
    final b = db.cardById('endo-new-b')!;
    expect(a.dupCheck, 'dup');
    expect(a.dupOf, 'endo-old-1');
    expect(b.dupCheck, 'ok');
    expect(b.dupOf, isNull);
    // 同批嵌入的向量已入表（后续卡可比对）
    expect(db.cardVectors('test-model').length, 3);
    expect(logs.join('\n'), contains('疑似重复'));
  });

  test('runCardDupPass：嵌入失败 → skipped 降级；下轮成功 → 自动补查翻转', () async {
    insertCard('endo-new-c', '龋病四联因素是哪四个？');
    var fail = true;
    final res1 = await runCardDupPass(
      db: db,
      model: 'test-model',
      threshold: 0.92,
      embedBatch: (texts) async =>
          fail ? throw StateError('嵌入 API 不可用') : const [],
      log: (_, _, _) {},
    );
    expect(res1.skipped, 1);
    expect(db.cardById('endo-new-c')!.dupCheck, 'skipped');

    // 下一轮 API 恢复：skipped 卡缺向量 → 自动补查 → ok/dup 翻转
    fail = false;
    final res2 = await runCardDupPass(
      db: db,
      model: 'test-model',
      threshold: 0.92,
      embedBatch: (texts) async => [
        for (final _ in texts) List<double>.filled(8, 0.1),
      ],
      log: (_, _, _) {},
    );
    expect(res2.embedded, 1);
    expect(res2.skipped, 0);
    expect(db.cardById('endo-new-c')!.dupCheck, 'ok');
  });

  test('占位卡不进查重域（缺向量查询排除占位题干）', () async {
    insertCard('endo-ph-1', '【语料未覆盖】请结合课堂笔记/教材补全原文后审核');
    final res = await runCardDupPass(
      db: db,
      model: 'test-model',
      threshold: 0.92,
      embedBatch: (texts) async => [for (final _ in texts) const [0.5]],
      log: (_, _, _) {},
    );
    expect(res.embedded, 0); // 占位卡不在处理域
    expect(db.cardById('endo-ph-1')!.dupCheck, 'ok'); // 保持默认
  });
}
