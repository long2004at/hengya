// 恒牙 App 冒烟测试（M1）：
// App 能启动（离线态）+ 待补传角标（SessionStore 接线）行为
import 'package:hengya/app.dart';
import 'package:hengya/pages/review_page.dart';
import 'package:hengya/services/api/api_client.dart';
import 'package:hengya/services/review/session_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

void main() {
  setUp(() {
    // kBackendMode 缺省已定 local（开源定稿 2026-09-06）；本套件断言的是
    // remote 模式的离线韧性（连不上服务器提示 / 待补传角标），显式钉住 remote。
    debugBackendMode = BackendMode.remote;
  });

  tearDown(() {
    debugBackendMode = null; // 置回 null：跨用例/跨文件零污染
  });

  testWidgets('App 启动：底部导航四 tab 可见（离线不崩溃）', (WidgetTester tester) async {
    await tester.pumpWidget(const HengyaApp());

    // 底部导航四页存在（M4：第二 Tab 改为「题库」）
    expect(find.text('科目'), findsOneWidget);
    expect(find.text('题库'), findsOneWidget);
    expect(find.text('待审核'), findsOneWidget);
    expect(find.text('统计'), findsOneWidget);
    await tester.pumpAndSettle(const Duration(seconds: 1));
  });

  testWidgets('离线态：首页显示离线提示不崩溃', (WidgetTester tester) async {
    await tester.pumpWidget(const HengyaApp());
    await tester.pumpAndSettle(const Duration(seconds: 2));
    // Http 请求会失败（测试环境无服务器）→ 离线提示可见
    expect(find.text('连不上服务器'), findsOneWidget);
  });

  testWidgets('待补传角标：SessionStore 驱动显示/隐藏（0 隐藏，>0 显示）',
      (WidgetTester tester) async {
    final store = SessionStore();
    await tester.pumpWidget(
      ChangeNotifierProvider<SessionStore>.value(
        value: store,
        child: const MaterialApp(home: ReviewSessionPage(subjectId: 'oms')),
      ),
    );
    // 离线：卡片拉取失败 → 错误提示页；pendingCount 0 → 角标不显示
    await tester.pumpAndSettle(const Duration(seconds: 2));
    expect(find.textContaining('待补传'), findsNothing);

    // 离线评分入队（onQueueChanged → store.updatePending）→ AppBar 出现「待补传 3」
    store.updatePending(3);
    await tester.pump();
    expect(find.text('待补传 3'), findsOneWidget);

    // 补传完成队列清空 → 角标消失
    store.updatePending(0);
    await tester.pump();
    expect(find.textContaining('待补传'), findsNothing);
  });

  testWidgets('回炉弹层组件可构建', (WidgetTester tester) async {
    // 直接验证 ReviewPage 空态构建（离线 → 科目选择页）
    await tester.pumpWidget(const MaterialApp(home: ReviewPage()));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('复习'), findsWidgets);
  });
}
