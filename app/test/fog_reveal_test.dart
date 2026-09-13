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

Future<FogPeelController> pumpFog(
  WidgetTester tester, {
  Size size = const Size(400, 600),
}) async {
  final controller = FogPeelController();
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
                child: const Text('ANSWER'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('上雾遮盖：雾层在位，答案文本被盖（雾层命中而非答案），擦雾追加笔画', (tester) async {
    final c = await pumpFog(tester);
    expect(c.isFogged, true);
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

  testWidgets('markCleared 幂等；reset 重雾', (tester) async {
    final c = await pumpFog(tester);
    c.markCleared();
    c.markCleared();
    expect(c.isCleared, true);
    await tester.pump();
    c.reset();
    expect(c.isFogged, true);
    expect(c.phase, FogPhase.idle);
    expect(c.strokes, isEmpty);
    await tester.pump();
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
}
