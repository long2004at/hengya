// #12 雾气模式 M1 测试：FogPeel 组件状态机 + 设置开关持久化。
//
// 覆盖：
//   1. 上雾遮盖：雾层在位（控制器 isFogged）、擦雾手势追加笔画
//   2. 拖纸角超阈值松手 → 飞出全清（isCleared，宿主解锁语义）
//   3. 拖纸角未过阈值 → 弹回（phase 回 idle，未清）
//   4. 点纸角（tap）→ 自动掀页动画 → 全清
//   5. reset 重雾 / markCleared 幂等
//   6. 设置开关读写 shared_preferences（键 hengya.review.fog，默认关）
//
// 宿主基建：纯 widget 测试（无 sqlite）——SharedPreferences 注入 mock 初值。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/widgets/fog_reveal.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<FogRevealController> pumpFog(
  WidgetTester tester, {
  Size size = const Size(400, 600),
  FogSheetMode sheetMode = FogSheetMode.fill,
  String answer = 'ANSWER',
}) async {
  final controller = FogRevealController();
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(size: size),
      child: MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: size.width,
              height: size.height,
              child: FogPeel(
                controller: controller,
                sheetMode: sheetMode,
                child: Text(answer),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump(); // 首帧（hugText 下限起步）
  await tester.pump(); // 测量 postFrame 回调落地
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('上雾遮盖：雾层在位，答案文本被盖（雾层命中而非答案），擦雾追加笔画', (tester) async {
    final c = await pumpFog(tester);
    expect(c.isCleared, false); // 初始有雾
    expect(c.isCleared, false);
    // 雾层 opaque：点中心命中雾层手势（非 child 文本）——由 fog 层 Positioned.fill 兜住
    final center = tester.getCenter(find.byType(FogPeel));
    final gesture = await tester.startGesture(center);
    await gesture.moveBy(const Offset(40, 20));
    await gesture.up();
    await tester.pump();
    expect(c.strokes, isNotEmpty, reason: '非纸角区拖动 = 擦雾，必须追加笔画');
    expect(c.isCleared, false, reason: '擦雾不清雾');
    // 擦雾后雾层仍在位（笔画处透出答案，其余仍被雾盖）
    expect(find.byType(CustomPaint), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('拖纸角超阈值松手 → 飞出全清（isCleared）', (tester) async {
    final c = await pumpFog(tester);
    final corner = tester.getBottomRight(find.byType(FogPeel)); // 全局坐标
    // 从纸角热区内起手，向左上拖过 40% 对角线
    final start = corner - const Offset(20, 20);
    final gesture = await tester.startGesture(start);
    await tester.pump();
    // 分步拖动（单次大幅 moveBy 的位移会被手势识别器吞掉——
    // 识别器胜出后才交付 update，真实手指拖动即连续小步）
    for (var i = 0; i < 3; i++) {
      await gesture.moveBy(const Offset(-110, -160));
      await tester.pump();
    }
    expect(c.phase, FogPhase.peeling);
    await gesture.up(); // 松手：超阈值 → 飞出动画（450ms 内完成）
    await tester.pumpAndSettle();
    expect(c.isCleared, true, reason: '拖过阈值必须飞出全清');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('拖纸角未过阈值 → 弹回 idle（未清）', (tester) async {
    final c = await pumpFog(tester);
    final corner = tester.getBottomRight(find.byType(FogPeel)); // 全局坐标
    final gesture = await tester.startGesture(corner - const Offset(20, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(-60, -60)); // 远小于阈值
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(c.isCleared, false, reason: '未过阈值必须弹回重新盖住');
    expect(c.phase, FogPhase.idle);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点纸角 = 自动掀页动画 → 全清', (tester) async {
    final c = await pumpFog(tester);
    final corner = tester.getBottomRight(find.byType(FogPeel)); // 全局坐标
    await tester.tapAt(corner - const Offset(30, 30)); // 热区内点击
    await tester.pumpAndSettle();
    expect(c.isCleared, true, reason: '点纸角必须触发自动掀页至全清');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('擦雾空洞随纸角掀走：掀起渲染不炸、笔画保留、平摊区空洞仍在', (tester) async {
    final c = await pumpFog(tester);
    final size = tester.getSize(find.byType(FogPeel));
    final corner = tester.getBottomRight(find.byType(FogPeel));
    // 先在非纸角区擦两笔（留空洞）
    final gesture = await tester.startGesture(size.center(Offset.zero));
    await tester.pump();
    await gesture.moveBy(const Offset(-60, -30));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(c.strokes, hasLength(1));
    // 再拖纸角小幅掀起（未过阈值 → 弹回）：卷起渲染含空洞冒烟
    final peel = await tester.startGesture(corner - const Offset(20, 20));
    await tester.pump();
    await peel.moveBy(const Offset(-60, -60));
    await tester.pump();
    expect(c.isPeeling, true);
    await peel.up();
    await tester.pumpAndSettle();
    expect(c.phase, FogPhase.idle, reason: '未过阈值弹回');
    expect(c.strokes, hasLength(1), reason: '擦除空洞是纸的一部分，弹回后仍在');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('markCleared 幂等；reset 重雾', (tester) async {
    final c = await pumpFog(tester);
    c.markCleared();
    c.markCleared();
    expect(c.isCleared, true);
    await tester.pump();
    c.reset();
    expect(c.isCleared, false); // reset 重雾
    expect(c.phase, FogPhase.idle);
    expect(c.strokes, isEmpty);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hugText：短答案 → 纸片高度=下限 120dp；长答案 → 钳到可用高度', (tester) async {
    // 短答案：一行字（固有高度 < 120）→ 纸片 = 120 下限
    final c1 = await pumpFog(tester, sheetMode: FogSheetMode.hugText);
    expect(c1.sheetHeight, 120.0, reason: '短答案纸片钳到 120dp 下限');
    await tester.pumpWidget(const SizedBox.shrink());

    // 长答案：文字实际高度超过可用 600 → 纸片 = 600（可用高度上限）
    final long = '长答案。' * 600; // 固有高度远超可用 600
    final c2 = await pumpFog(
      tester,
      sheetMode: FogSheetMode.hugText,
      answer: long,
    );
    expect(c2.sheetHeight, 600.0, reason: '长答案纸片钳到可用高度上限');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('fill：纸片高度恒等于可用区域（与答案长短无关）', (tester) async {
    final c1 = await pumpFog(tester, sheetMode: FogSheetMode.fill);
    expect(c1.sheetHeight, 600.0);
    await tester.pumpWidget(const SizedBox.shrink());
    final c2 = await pumpFog(
      tester,
      answer: '长答案。' * 200,
      sheetMode: FogSheetMode.fill,
    );
    expect(c2.sheetHeight, 600.0, reason: 'fill 模式纸片不随答案缩短');
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('设置开关：shared_preferences 读写（键 hengya.review.fog，默认关）', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('hengya.review.fog') ?? false, false,
        reason: '默认关');
    await prefs.setBool('hengya.review.fog', true);
    final prefs2 = await SharedPreferences.getInstance();
    expect(prefs2.getBool('hengya.review.fog'), true);
  });

  testWidgets('v3 性能策略：静态态保留 BackdropFilter 真模糊，翻页动画态移除', (tester) async {
    final c = await pumpFog(tester);
    // 静态（idle/erasing）：BackdropFilter 在位（真模糊遮盖）
    expect(find.byType(BackdropFilter), findsOneWidget,
        reason: '静态态必须保留真模糊层');

    // 拖纸角进入 peeling → 切换为不透明渐变遮罩，BackdropFilter 移除
    final corner = tester.getBottomRight(find.byType(FogPeel));
    final gesture = await tester.startGesture(corner - const Offset(20, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(-60, -60));
    await tester.pump();
    expect(c.isPeeling, true);
    expect(find.byType(BackdropFilter), findsNothing,
        reason: '翻页动画态不应有 BackdropFilter（每帧重算开销）');

    // 弹回结束回到静态 → BackdropFilter 恢复
    await gesture.up();
    await tester.pumpAndSettle();
    expect(c.phase, FogPhase.idle);
    expect(find.byType(BackdropFilter), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
