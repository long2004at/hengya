// 海浪氛围层 —— 首页 Hero 背景「多波向 × 多倍频海浪涌动」（2026-09-07
// 节点⑧首版为单正弦四层；2026-10-11 重构：用户反馈「涟漪为一条直线」——
// 单正弦 + 波长 0.9~1.5 屏宽（一屏不足一个波形）读起来就是缓慢起伏的直线，
// 且传播方向只有水平左右两种 → 改为每层多波分量叠加的真实海浪场）。
//
// 波形数学模型（每层 4 个波分量 [WaveComponent] 叠加）：
//   y(x,t) = 水位·h + 倾斜·h·(x/w − 0.5)
//            + 振幅·h · Σ_i amp_i·v_i(t)·[ sin(u_i) + asym_i·sin(2u_i) ]
//   u_i(x,t) = cos(θ_i)·k_i·x + 2π(φ_i − speed_i·t)
//   k_i = 2π/(λ_i·w)，θ_i ∈ [0, 2π) 任意角波向（x 向投影 cos θ 可正可负，
//   传播方向不再局限水平左右）；amp_i 归一（Σ=1，层振幅守恒可静态审计）；
//   sin(2u) 二次谐波让波峰陡、波谷缓（非对称，|sin2u| ≤ 1 → 贡献 ≤ 1+asym）。
//   v_i(t) = 0.55 + 0.45·cos(2π(speed_i·t − φ_i))：波向量在纵向的投影近似
//   （屏是横向剖面，ky 项退化为逐分量振幅调制）——同一层不同时刻波形
//   自然消长，多分量相互干涉导致不规则波面（非周期性重复感）。
//   频率按深水波色散关系 ω ∝ sqrt(k) 定标：波长每减半（倍频）速度周期
//   数翻倍（长涌 36s 一轮 ↔ 碎浪 4.5s 一轮），所有 speed 均为 36s 主循环
//   的整数分之一 → 回卷无缝。
//   波长跨倍频铺开：0.9~1.2 / 0.45~0.6 / 0.22~0.30 / 0.12~0.16 屏宽——
//   长短波共存（大涌 + 细碎涟漪），一屏内必有多个完整短波 → 不再是直线感。
//
// 浪尖泡沫：每层在「合成波包络」（Σ amp_i·v_i > 0.75，即多分量同相堆高
// 的真实浪尖）处描一条更亮的白色窄 stroke（随机相位微光呼吸），模拟
// 浪尖泛白；泡沫相位按段起点摇定，呼吸频率 6s（≥4s 低频闸门，36s 的
// 6 整数分之一）——确定性正弦，绝非逐帧随机频闪。
//
// 设计取舍（随机 × 稳定 × 优雅三向平衡）：
//  · 随机可变：各层各分量的波向角/波长/速度/相位/谐波陡度在实例创建时
//    按随机源摇定（默认真随机——实例生命周期内恒定，重建焕新；seed 可
//    注入 → 测试可复现）。受控区间而非全自由随机，杜绝突兀摆动。
//  · 缓慢自然：四层海浪自纵深（水位高、节奏缓）向近景（水位低、灵动）
//    层叠；振幅/水位再叠 36s 潮汐呼吸、色相按正弦极慢呼吸（±7°~±12°）。
//  · 优雅克制：波面峰值 alpha 合计 ≤ 0.15（沿「信息明确」硬约束口径，
//    含泡沫在内，审计式见 [AuroraWaveLayer.peakAlphas]），配色沿用受控
//    色池（[AuroraPalette]，高明度低灰度柔彩色，波面向下渐隐）。
//
// 「信息明确」硬约束落地（同进度页/首页既有口径）：
//   1. 纯装饰 CustomPainter 画在 Stack 最底层，信息 Widget 全在其上，
//      不参与命中测试（IgnorePointer），不遮挡任何文字；
//   2. 波面峰值 alpha 合计 ≤ 0.15（含泡沫，最坏全叠加不超帽）；
//   3. RepaintBoundary 隔离重绘（动画帧不外溢到信息层）；
//   4. MediaQuery.disableAnimations（系统「移除动画」/低性能模式）→
//      静止一帧（不启动控制器），信息层完全不受影响。
//
// 性能口径：单 AnimationController（36s repeat 永续）+ CustomPainter
// 确定性渲染（无逐帧随机）；采样闸门从 41 点/层提升到 93 点/层
// （samples=92，≤96 闸门内；2026-10-11 审计修正：原 81 点/层摊在 1.6 屏宽
// 越界采样范围上实际只有 ~6 点/波长，与注释声称的 ≥10 不符——现采样范围
// 收窄为 1.1 屏宽（margin 0.05 屏宽）× 92 段，最短波 0.12 屏宽实得
// ≥10 点/波长）——理由：≥10 点/波长才不丢波峰，且泡沫分段需要足够密
// 的波峰折线；每帧分配 ≤ 4 个填充 Path + ≤16 个泡沫 stroke Path（每层
// 泡沫段硬闸门 4 段，见 [AuroraFlowPainter.paint]）+ 4 个填充渐变 +
// ≤16 个泡沫段渐变 shader 量级。
// 永续动画——测试里禁用 pumpAndSettle，一律固定时长 pump。

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 一组流彩配色（波层循环取色）。色池为受控常量表：全部为高明度柔和色，
/// 组内成对色相差 ≥ 25°——「随机」只在池内发生，不会摇出刺眼组合。
class AuroraPalette {
  const AuroraPalette(this.name, this.colors);

  /// 搭配名（注释/测试报告用）
  final String name;

  /// 三色搭配（[AuroraFlowPainter.layers] 按 i % 3 循环取色）
  final List<Color> colors;

  /// 受控色池：六组三色搭配，全部高明度低灰度柔彩色（在品牌蓝底上呈现）。
  static const List<AuroraPalette> pool = [
    AuroraPalette('极光', [
      Color(0xFF7FF2E0), // 水绿 · 远层涌浪
      Color(0xFFC8B6FF), // 紫丁香 · 中层涌浪
      Color(0xFFFFE9C4), // 香槟金 · 近层涟漪
    ]),
    AuroraPalette('晨曦', [
      Color(0xFFFFD9C8), // 蜜桃 · 远层涌浪
      Color(0xFFFFC4D6), // 蔷薇粉 · 中层涌浪
      Color(0xFFA8F0E4), // 浅碧 · 近层涟漪
    ]),
    AuroraPalette('暮霭', [
      Color(0xFFC8B6FF), // 紫丁香 · 远层涌浪
      Color(0xFFCFE8FF), // 冰蓝 · 中层涌浪
      Color(0xFFFFC4D6), // 蔷薇粉 · 近层涟漪
    ]),
    AuroraPalette('湖屿', [
      Color(0xFFB9F0D0), // 薄荷 · 远层涌浪
      Color(0xFFFFE9C4), // 香槟金 · 中层涌浪
      Color(0xFFCFE8FF), // 冰蓝 · 近层涟漪
    ]),
    AuroraPalette('霜花', [
      Color(0xFFCFE8FF), // 冰蓝 · 远层涌浪
      Color(0xFFFFD9C8), // 蜜桃 · 中层涌浪
      Color(0xFFB9F0D0), // 薄荷 · 近层涟漪
    ]),
    AuroraPalette('鎏金', [
      Color(0xFFFFE9C4), // 香槟金 · 远层涌浪
      Color(0xFFFFC4D6), // 蔷薇粉 · 中层涌浪
      Color(0xFFB9F0D0), // 薄荷 · 近层涟漪
    ]),
  ];

  /// 会话级随机取一组：首次访问时摇定（static final），此后整个进程内
  /// 恒定同一组——「每次冷启动随机焕新，同一会话内稳定可识别」。
  static final AuroraPalette session = pick(math.Random());

  /// 按随机源取组（供 [session] 与测试注入确定性随机源）
  static AuroraPalette pick(math.Random rng) => pool[rng.nextInt(pool.length)];

  /// 恒等相等：色池为常量表，会话随机取组返回的是池内同一实例，
  /// 恒等即「同组配色」的精确语义（[AuroraFlowPainter.shouldRepaint] 用）。
  @override
  bool operator ==(Object other) => identical(other, this);

  @override
  int get hashCode => identityHashCode(this);
}

/// 一层海浪内的单个波分量（谐波）：独立的二维波向量 + 倍频速度 + 二次
/// 谐波陡度。实例创建时按随机源摇定，生命周期内恒定。
class WaveComponent {
  const WaveComponent({
    required this.angle,
    required this.wavelength,
    required this.speed,
    required this.phase,
    required this.amp,
    required this.asym,
  });

  /// 波向角（rad，[0, 2π) 均匀随机）：波向量 (kx, ky) = k·(cos θ, sin θ)，
  /// 传播方向任意角度（不再局限于水平左右）；水平剖面取 kx 投影。
  final double angle;

  /// 波长（屏宽占比）：跨倍频铺开（长涌 ↔ 碎浪），见
  /// [AuroraWaveLayer.generate] 的波长表
  final double wavelength;

  /// 时间频率：一个 36s 主循环内的完整周期数（1~5）。按深水色散关系
  /// ω ∝ sqrt(k) 随波长倍频递增（每减半波长 +1 周期 ≈ sqrt 缩放的离散
  /// 近似），整数倍保证主循环回卷时波面相位无缝衔接。
  final int speed;

  /// 空间相位（0~1，随机错开层间/分量间波峰位置；同时充当纵向投影
  /// 调制 v_i(t) 的初相）
  final double phase;

  /// 相对振幅（层内归一 Σ amp = 1 → 层总振幅守恒、alpha 帽可静态审计）
  final double amp;

  /// 二次谐波陡度（0~0.35）：sin(u) + asym·sin(2u) 让波峰陡、波谷缓
  /// （非对称波形，更像真实浪）
  final double asym;

  /// 值相等：同 seed 重放的同分量参数逐字段相等（测试复现性锚点）。
  @override
  bool operator ==(Object other) =>
      other is WaveComponent &&
      other.angle == angle &&
      other.wavelength == wavelength &&
      other.speed == speed &&
      other.phase == phase &&
      other.amp == amp &&
      other.asym == asym;

  @override
  int get hashCode =>
      Object.hash(angle, wavelength, speed, phase, amp, asym);
}

/// 一层海浪的几何/呼吸参数（实例创建时按随机源摇定，生命周期内恒定；
/// 「缓慢漂移」由 [AuroraFlowPainter] 用相位 t 调制实现，不改本参数）。
class AuroraWaveLayer {
  const AuroraWaveLayer({
    required this.amplitude,
    required this.level,
    required this.tilt,
    required this.alpha,
    required this.hueDrift,
    required this.driftSeed,
    required this.components,
  });

  /// 层总振幅（屏高占比 0.035~0.08）：由各分量按 [WaveComponent.amp]
  /// 归一分摊（Σ amp_i = 1 → 总位移 ≤ 振幅·(1 + max asym) ≤ 1.35 振幅）
  final double amplitude;

  /// 基线水位（屏高占比；远层高、近层低，错开形成纵深）
  final double level;

  /// 基线倾斜（±0.05 屏高）：波面带小角度，非水平机械线
  final double tilt;

  /// 本层峰值 alpha 预算（含填充 + 泡沫，见 [peakAlphas] 审计式）
  final double alpha;

  /// 色相呼吸幅度（度，同旧版柔光带口径）
  final double hueDrift;

  /// 潮汐呼吸相位种子（振幅/水位的 36s 慢漂移逐层错相）
  final double driftSeed;

  /// 本层波分量（[WaveComponent.harmonicsPerLayer] 个，多波向多倍频叠加）
  final List<WaveComponent> components;

  /// 层数（index 0 = 最远 … count-1 = 最近）
  static const int count = 4;

  /// 每层波分量数（多波向 × 多倍频：长涌 → 细碎涟漪四个倍频档）
  static const int harmonicsPerLayer = 4;

  /// 各层峰值 alpha 常量表（远→近）：合计 0.15（信息明确硬约束）。
  ///
  /// alpha 审计式（2026-10-11 重构后口径，含泡沫）——每层峰值预算
  /// alpha_i 在「填充 + 泡沫」间按 foamShares 分账，逐层恰好用满：
  ///   填充峰值_i = alpha_i · (1 − foamShare_i) · breathe（breathe ≤ 1）
  ///   泡沫峰值_i = alpha_i · foamShare_i · flicker（flicker ≤ 1）
  ///   单点叠加_i ≤ alpha_i·[(1−share)·1 + share·1] = alpha_i
  ///   四层最坏全叠加 = Σ alpha_i = 0.15 ✓ 不超帽
  static const List<double> peakAlphas = [0.06, 0.04, 0.03, 0.02];

  /// 各层泡沫分账占比（远→近：近层浪尖更碎更白）：
  /// Σ (alpha_i·(1−share_i)) + Σ (alpha_i·share_i) = Σ alpha_i = 0.15
  static const List<double> foamShares = [0.30, 0.35, 0.40, 0.45];

  /// 各层色相呼吸幅度（度）
  static const List<double> hueDrifts = [10, 7, 12, 8];

  /// 波长表（屏宽占比，逐分量倍频铺开：长涌 → 碎浪）。
  /// 最短 0.12 屏宽 ≥ 0.10 下限（93 点采样下 ≥ 10 点/波长，波峰不丢）。
  static const List<List<double>> _wavelengthTable = [
    [0.90, 1.20], // 长涌：一屏约一个完整大波
    [0.45, 0.60], // 中涌
    [0.22, 0.30], // 细波
    [0.12, 0.16], // 碎浪涟漪
  ];

  /// 振幅分摊基型（长波主导，短波点缀），生成后归一 → Σ amp = 1 恒成立
  static const List<double> _ampBase = [0.46, 0.28, 0.16, 0.10];

  /// 按随机源摇定全套层参数（index 0 = 最远 … count-1 = 最近）：
  /// 振幅/相位/波向角/谐波陡度落在克制区间随机，波长查倍频表，
  /// 水位沿纵深梯度铺开，alpha/色相查常量表（不随机——保证 ≤0.15 帽
  /// 可静态审计）。随机消耗顺序固定（先层参数后分量序列）→ 同 seed
  /// 重放逐层恒等（测试复现锚点）。
  factory AuroraWaveLayer.generate(math.Random rng, int index) {
    final depth = index / (count - 1); // 0 远 → 1 近
    final components = <WaveComponent>[];
    var rawSum = 0.0;
    final rawAmps = <double>[];
    for (var i = 0; i < harmonicsPerLayer; i++) {
      final raw = _ampBase[i] * (0.7 + 0.6 * rng.nextDouble());
      rawAmps.add(raw);
      rawSum += raw;
    }
    for (var i = 0; i < harmonicsPerLayer; i++) {
      final range = _wavelengthTable[i];
      components.add(WaveComponent(
        angle: rng.nextDouble() * 2 * math.pi,
        wavelength: range[0] + rng.nextDouble() * (range[1] - range[0]),
        // 色散定标：波长每减一档 speed +1（36/5 = 7.2s ≥ 4s 低频闸门）
        speed: 1 + i + rng.nextInt(2),
        phase: rng.nextDouble(),
        amp: rawAmps[i] / rawSum,
        asym: rng.nextDouble() * 0.30,
      ));
    }
    return AuroraWaveLayer(
      amplitude: 0.035 + rng.nextDouble() * 0.045,
      level: (0.32 + 0.5 * depth + (rng.nextDouble() - 0.5) * 0.08)
          .clamp(0.08, 0.92)
          .toDouble(),
      tilt: (rng.nextDouble() - 0.5) * 0.10,
      alpha: peakAlphas[index],
      hueDrift: hueDrifts[index],
      driftSeed: rng.nextDouble(),
      components: components,
    );
  }

  /// 按随机源生成全套层参数（count 层，顺序消耗随机源）。
  /// [AuroraAmbient] 的 State 与测试复现共用同一入口。
  static List<AuroraWaveLayer> generateLayers(math.Random rng) => [
        for (var i = 0; i < count; i++) AuroraWaveLayer.generate(rng, i),
      ];

  /// 值相等：同 seed 重放的同层参数逐字段相等（含全部分量——测试复现
  /// 性锚点必须覆盖新增的分量序列）。
  @override
  bool operator ==(Object other) =>
      other is AuroraWaveLayer &&
      other.amplitude == amplitude &&
      other.level == level &&
      other.tilt == tilt &&
      other.alpha == alpha &&
      other.hueDrift == hueDrift &&
      other.driftSeed == driftSeed &&
      _listEquals(other.components, components);

  static bool _listEquals(List<WaveComponent> a, List<WaveComponent> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(amplitude, level, tilt, alpha, hueDrift,
      driftSeed, Object.hashAll(components));
}

/// 海浪氛围层组件：多波向 × 多倍频海浪涌动（受控色池配色 + 层/分量参数
/// 构建时随机 + 潮汐/色相极慢呼吸 + 浪尖泡沫）。永续 repeat 动画——测试里
/// 禁用 pumpAndSettle，一律固定时长 pump。
class AuroraAmbient extends StatefulWidget {
  const AuroraAmbient({super.key, this.palette, this.seed});

  /// 本次会话的流彩配色；null → [AuroraPalette.session]（会话级随机）。
  /// 测试可显式传入池内固定组，断言确定性行为。
  final AuroraPalette? palette;

  /// 波参数随机源种子；null → 真随机（实例生命周期内恒定）。
  /// 注入固定 seed → 层/分量参数（含任意角波向）可复现（测试锚点）。
  final int? seed;

  @override
  State<AuroraAmbient> createState() => _AuroraAmbientState();
}

class _AuroraAmbientState extends State<AuroraAmbient>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    // 36s 主循环：各分量时间频率为其整数分之一（speed 1~5 → 单波周期
    // 7.2~36s，全部 ≥4s 低频闸门；潮汐/色相/泡沫呼吸同为一轮的整数分一）
    duration: const Duration(seconds: 36),
  );

  List<AuroraWaveLayer> _layers = const [];

  @override
  void initState() {
    super.initState();
    final rng = math.Random(widget.seed); // seed null → 真随机
    // 随机消耗顺序固定：generateLayers 独立成序列，与
    // AuroraWaveLayer.generateLayers(Random(seed)) 逐层恒等（测试复现
    // 锚点）。波向角在各分量生成时摇定（任意角度，每次启动随机焕新）。
    _layers = AuroraWaveLayer.generateLayers(rng);
  }

  @override
  void didUpdateWidget(AuroraAmbient oldWidget) {
    super.didUpdateWidget(oldWidget);
    // seed 属「实例创建时摇定」参数：父级以新值重建时重摇一次（保持注入
    // 语义诚实；home_page 使用点为 const，不触发本分支）。
    if (oldWidget.seed != widget.seed) {
      final rng = math.Random(widget.seed);
      _layers = AuroraWaveLayer.generateLayers(rng);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统关闭动效（无障碍「移除动画」/低性能模式）→ 氛围层静止
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose(); // dispose 闸门：随 Widget 卸载必释放，Ticker 不外泄
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.of(context).disableAnimations;
    final palette = widget.palette ?? AuroraPalette.session;
    return IgnorePointer(
      child: RepaintBoundary(
        child: disabled
            ? CustomPaint(
                painter: AuroraFlowPainter(0, palette, _layers),
                size: Size.infinite,
              )
            : AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: AuroraFlowPainter(
                    _controller.value,
                    palette,
                    _layers,
                  ),
                  size: Size.infinite,
                ),
              ),
      ),
    );
  }
}

/// 海浪绘制：四层多分量波面自远而近层叠（确定性渲染，无逐帧随机）。
/// 波形模型见文件头注释；振幅/水位再叠 36s 潮汐呼吸（±25% / ±3%h）、
/// 色相按正弦极慢呼吸——层间速度/相位/水位/波向全部错开形成纵深。
/// 波面以下用「波峰色 → 向下渐隐」的线性渐变填充（纵深下暗，同海水
/// 体感）；合成波包络堆高处（真实浪尖）描白色泡沫窄带。
class AuroraFlowPainter extends CustomPainter {
  AuroraFlowPainter(this.t, this.palette, this.layers);

  /// 0.0~1.0 循环相位（36s 主循环）
  final double t;

  /// 本组流彩配色（波层按 i % 3 循环取色）
  final AuroraPalette palette;

  /// 波层参数（构建时随机摇定，生命周期内恒定）
  final List<AuroraWaveLayer> layers;

  /// 波面横向采样段数（2026-10-11 审计修正后 92：采样范围 1.1 屏宽
  /// （margin 0.05 屏宽）÷ 92 段 ≈ 0.012 屏宽/段 → 最短波分量 0.12 屏宽
  /// 实得 ≥10 点/波长；原 80 段 × 1.6 屏宽范围只有 ~6 点/波长，注释虚报）。
  /// ≤96 闸门内，93 点/层 × 4 层的三角函数量级与 4~20 个 Path 的分配
  /// 量级均受控，见文件头性能口径
  static const int samples = 92;

  /// 每层泡沫 stroke 段硬闸门（最坏 4 层 × 4 段 = 16 个附加 Path，
  /// 性能分配量级可静态审计）
  static const int maxFoamRunsPerLayer = 4;

  /// 泡沫触发阈值：合成波包络（Σ amp_i·v_i，∈[0,1]）超过此值 → 浪尖
  /// 描白。多分量同相堆高才触发 → 泡沫只出现在真实浪尖，稀疏而克制。
  static const double foamThreshold = 0.75;

  /// 泡沫微光呼吸频率（36s 主循环的 6 整数分之一 → 6s 一轮，≥4s 低频
  /// 闸门；正弦确定性，非逐帧随机频闪）
  static const double foamFlickerCycles = 6;

  /// 泡沫呼吸深度（flicker ∈ [1 − 2·0.075, 1] = [0.85, 1]）
  static const double _foamFlickerDepth = 0.075;

  /// 单层波面色：基色色相按正弦极慢漂移（「动态色彩」）。
  /// 高明度柔和基色在低 alpha 下呈薄纱般的淡彩，而非荧光色块。
  Color _waveColor(Color base, double hueDrift, double driftSeed) {
    final hsl = HSLColor.fromColor(base);
    final drift = math.sin(2 * math.pi * (t + driftSeed)) * hueDrift;
    final hue = (hsl.hue + drift).clamp(0.0, 360.0).toDouble();
    return hsl.withHue(hue).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final w = size.width;
    final h = size.height;
    // 两端越界采样：倾斜/波峰永不出可视直角（波面函数在屏外仍连续）；
    // margin 0.05 屏宽即够——屏缘波形连续性由屏外采样点保证，垂直下切
    // 闭合线落在屏外（原 0.3 屏宽属冗余，收窄是为保证最短波 ≥10 点/波长）
    final margin = w * 0.05;
    final x0 = -margin;
    final x1 = w + margin;
    final step = (x1 - x0) / samples;
    final twoPi = 2 * math.pi;
    for (var i = 0; i < layers.length; i++) {
      final layer = layers[i];
      // 潮汐呼吸（36s 周期，逐层错相）：振幅 ±25%、水位 ±3%h 缓慢漂移
      final drift = math.sin(twoPi * (t + layer.driftSeed));
      final amp = layer.amplitude * (0.75 + 0.25 * drift);
      final level = (layer.level + 0.03 * drift).clamp(0.05, 0.95).toDouble();

      // 波面采样：y(x) 与合成波包络 e(x) 同点算出（e = Σ amp_i·v_i，
      // ∈[0,1]——多分量同相堆高的真实浪尖判据，供泡沫分段）
      final ys = List<double>.filled(samples + 1, 0);
      final es = List<double>.filled(samples + 1, 0);
      for (var s = 0; s <= samples; s++) {
        final x = x0 + step * s;
        var y = level * h + layer.tilt * h * (x / w - 0.5);
        var env = 0.0;
        for (final c in layer.components) {
          final k = twoPi / (c.wavelength * w);
          final u =
              math.cos(c.angle) * k * x + twoPi * (c.phase - c.speed * t);
          // 纵向投影近似：波向量 ky 分量退化为逐分量振幅调制（同一层
          // 不同时刻波形自然消长；0.55 底保证分量永不完全消失）
          final vmod = 0.55 + 0.45 * math.cos(twoPi * (c.speed * t - c.phase));
          env += c.amp * vmod;
          // 二次谐波：波峰陡、波谷缓（|sin2u| ≤ 1 → 贡献 ≤ amp·(1+asym)）
          y += amp * h * c.amp * vmod * (math.sin(u) + c.asym * math.sin(2 * u));
        }
        ys[s] = y;
        es[s] = env;
      }

      // 波面 → quadratic 平滑（中点法：控制点=前采样点，端点=中点）+
      // 封闭波面以下区域（填充 Path）
      final path = Path()..moveTo(x0, ys[0]);
      for (var s = 1; s <= samples; s++) {
        path.quadraticBezierTo(
          x0 + step * (s - 1),
          ys[s - 1],
          x0 + step * s - step / 2,
          (ys[s - 1] + ys[s]) / 2,
        );
      }
      path.lineTo(x1, ys[samples]); // 末端采样点（越界屏外）
      path.lineTo(x1, h + margin);
      path.lineTo(x0, h + margin);
      path.close();

      // 填充：波峰色 → 向下渐隐（峰值 alpha 只在波峰带，向下衰减到 0；
      // 分账 (1 − foamShare)，与泡沫合计恰为本层 alpha 帽，见审计式）
      final breathe = 0.8 + 0.2 * math.sin(twoPi * (t + layer.driftSeed) + 1.3);
      final foamShare = AuroraWaveLayer.foamShares[i];
      final fillPeak = layer.alpha * (1 - foamShare) * breathe;
      final tint = _waveColor(
        palette.colors[i % palette.colors.length],
        layer.hueDrift,
        layer.driftSeed,
      );
      final band = Rect.fromLTRB(
        0,
        ((level - amp * 1.35 - 0.02).clamp(0.0, 1.0)).toDouble() * h,
        w,
        h,
      );
      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          tint.withValues(alpha: 0),
          tint.withValues(alpha: fillPeak),
          tint.withValues(alpha: fillPeak * 0.3),
          tint.withValues(alpha: 0),
        ],
        stops: const [0.0, 0.12, 0.55, 1.0],
      );
      canvas.drawPath(path, Paint()..shader = gradient.createShader(band));

      // 浪尖泡沫：包络 e(x) > 阈值的连续段描白色窄 stroke（波峰泛白）。
      // 段数硬闸门 [maxFoamRunsPerLayer]；每段呼吸相位按段起点 x 摇定
      // （确定性正弦，6s 一轮，回卷无缝——|相位差| 为整数圈）。
      final foamPeak = layer.alpha * foamShare;
      final strokeHalf = (amp * h * 0.18 + 1.5).clamp(1.5, 8.0).toDouble();
      final foamPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeHalf * 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      var runs = 0;
      var runStart = -1;
      for (var s = 0; s <= samples + 1 && runs < maxFoamRunsPerLayer; s++) {
        final inRun = s <= samples && es[s] > foamThreshold;
        if (inRun && runStart < 0) {
          runStart = s;
        } else if (!inRun && runStart >= 0) {
          runs++; // 闸门：超出 [maxFoamRunsPerLayer] 段即停（循环条件兜底）
          if (s - runStart >= 2) {
            final flicker = 1 -
                2 * _foamFlickerDepth +
                2 * _foamFlickerDepth *
                    math.sin(twoPi *
                        (foamFlickerCycles * t - (x0 + step * runStart) / w));
            foamPaint.shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                const Color(0xFFFFFFFF).withValues(alpha: 0),
                const Color(0xFFFFFFFF)
                    .withValues(alpha: (foamPeak * flicker).clamp(0.0, 1.0)),
                const Color(0xFFFFFFFF).withValues(alpha: 0),
              ],
            ).createShader(band);
            final foamPath = Path()..moveTo(x0 + step * runStart, ys[runStart]);
            for (var p = runStart + 1; p < s; p++) {
              foamPath.quadraticBezierTo(
                x0 + step * (p - 1),
                ys[p - 1],
                x0 + step * p - step / 2,
                (ys[p - 1] + ys[p]) / 2,
              );
            }
            canvas.drawPath(foamPath, foamPaint);
            if (s >= samples) break;
          }
          runStart = -1;
        }
      }
    }
  }

  @override
  bool shouldRepaint(AuroraFlowPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.palette != palette ||
      !identical(oldDelegate.layers, layers);
}
