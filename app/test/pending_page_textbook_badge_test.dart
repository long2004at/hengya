// 待审核页「教材」标识专项（批4 节点①）：
// sourceTier=textbook 的卡（ppt 主源未命中 → 教材兜底证据出卡）在待审核池
// 头部显示「教材」徽标；ppt 卡不显示。链路 = 真实 hengya.db（source_tier
// 列写入读出回环）→ LocalBackend /cards/pending → ApiClient → PendingPage
// ——整链透传的可视化验收。
//
// 基建纪律（同 rework_dialog_ui_test）：Windows 显式加载 test/sqlite3.dll
// （overrideForAll；python 自带 dll 跨进程 open_v2 即崩不可用）；setUp/
// tearDown 100% 同步；boot() 放用例体首行；固定 pump 不用 pumpAndSettle。
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/pages/pending_page.dart';
import 'package:hengya/services/api/api_client.dart'
    show ApiClient, BackendMode, debugBackendMode;
import 'package:hengya/services/local/db.dart';
import 'package:hengya/services/local/local_backend.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared/hengya_shared.dart'
    show CardStatus, CardType, FlashCard, SourceTier;
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
    sqlite_open.open.overrideForAll(
        () => ffi.DynamicLibrary.open(File('test/sqlite3.dll').absolute.path));
  }

  late Directory tmp;
  final be = LocalBackend.instance;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_pendbadge_');
  });

  tearDown(() {
    debugBackendMode = null; // 置回 null：跨用例/跨文件零污染
    ApiClient.instance.resetSubjectCaches();
    // 不 await：微任务链在真实事件队列 FIFO 自完成
    LocalBackend.instance.resetForTest();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('sourceTier=textbook 待审卡显示「教材」徽标，ppt 卡不显示', (tester) async {
    // 用例体首行 boot（体内事件循环由 pump 驱动，await 安全）
    await be.resetForTest();
    be.init(tmp.path);
    debugBackendMode = BackendMode.local;

    final db = await Db.open('${tmp.path}/hengya.db');
    db.insertSubject(id: 'endo', name: '牙体牙髓病学');
    db.importCard(
      const FlashCard(
        id: 'endo-tb-101',
        subjectId: 'endo',
        type: CardType.basic,
        front: '教材兜底卡的题干',
        back: '教材兜底卡的答案',
        anchor: '牙体牙髓病学 第5版 p20-23',
        source: '教材',
        sourceTier: SourceTier.textbook,
        status: CardStatus.pending,
        tags: ['龋病'],
      ),
    );
    db.importCard(
      const FlashCard(
        id: 'endo-ppt-102',
        subjectId: 'endo',
        type: CardType.basic,
        front: 'PPT 主源卡的题干',
        back: 'PPT 主源卡的答案',
        anchor: '龋病概述 p12-15',
        source: '课程 PPT',
        status: CardStatus.pending,
      ),
    );

    await tester.pumpWidget(const MaterialApp(home: PendingPage()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('待审核池'), findsOneWidget);
    expect(find.text('2 张待审'), findsOneWidget);
    expect(find.text('教材兜底卡的题干'), findsOneWidget);
    expect(find.text('PPT 主源卡的题干'), findsOneWidget);
    // 「教材」徽标恰一处（textbook 卡）；ppt 卡无徽标
    expect(find.text('教材'), findsOneWidget);

    // 收尾：卸载页面 + 关连接
    await tester.pumpWidget(const SizedBox.shrink());
    db.close();
  });
}
