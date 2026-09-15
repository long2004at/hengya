// FSRS-4.5 调度器实现 —— 恒牙的间隔重复引擎
// 数学模型：open-spaced-repetition FSRS-4.5（17 参数），公式与 ts-fsrs/py-fsrs 逐条对齐
// 状态机：Anki 语义（new / learning / review / relearning），算法插件化可替换
//
// 【0-based 权重对照表】（17 参数，官方默认；6 级评分下 g=1..6）
//   w[0..3]  = S0(G)：初始稳定性锚点。6 级通过 _s0() 分段插值映射到这 4 个锚点：
//              g=1(blackout)→w[0]，g=2(foggy)→lerp(w[0],w[1],0.5)，
//              g=3(struggled)→w[1]，g=4(hesitant)→w[2]，
//              g=5(smooth)→lerp(w[2],w[3],0.5)，g=6(instant)→w[3]
//   w[4]     = D0 中心难度：D0(G) = w[4] − w[5]·(G−3.5)（6 级中心点 3.5）
//   w[5]     = 初始难度斜率
//   w[6]     = 难度更新斜率：ΔD = −w[6]·(G−3.5)
//   w[7]     = 难度均值回归权重：D'' = w[7]·w[4] + (1−w[7])·D'
//   w[8..10] = 成功后稳：S'r = S·(1 + e^{w[8]}·(11−D)·S^{−w[9]}·(e^{(1−R)·w[10]}−1)·hardMod·easyMod)
//   w[11..14]= 遗忘后稳：S'f = w[11]·D^{−w[12]}·((S+1)^{w[13]} − 1)·e^{w[14]·(1−R)}
//   w[15]    = hard 惩罚乘数（0.2272，<1）— g=3(struggled) 时生效
//   w[16]    = easy 加成乘数（2.8755，>1）— g=6(instant) 时生效
//
// 【其他公式】DECAY=−0.5，FACTOR=19/81：
//   遗忘曲线 R(t,S) = (1 + FACTOR·t/S)^DECAY      （保证 R(S,S)=0.9）
//   间隔     I(r,S)  = S/FACTOR·(r^{1/DECAY} − 1)  （r=目标保留率）
//
// 【间隔策略】与 ts-fsrs 一致：间隔只由结果稳定性决定（hard/easy 的差异已内含在 S'r 中），
//   毕业后最小 1 天，上限 36500 天。
import 'dart:math' as math;

import 'review.dart';

/// FSRS-4.5 风格的 17 参数（默认值取官方 fsrs4anki 社区默认，可调参）
class FsrsParams {
  const FsrsParams({
    this.w = const [
      0.4872, 1.4003, 3.7145, 13.8206, // w0..w3: S0(G)
      5.1618, // w4: D0(good)
      1.2298, // w5: 初始难度斜率
      0.8975, // w6: 难度更新斜率
      0.031, // w7: 难度均值回归权重
      1.6474, 0.1367, 1.0461, // w8..w10: 成功后稳
      2.1072, 0.0793, 0.3246, 1.587, // w11..w14: 遗忘后稳
      0.2272, // w15: hard 惩罚
      2.8755, // w16: easy 加成
    ],
    this.requestedRetention = 0.9,
    this.maxIntervalDays = 36500,
  });

  final List<double> w;

  /// 目标保留率 0.9 ≈ 每日到期量与长期记忆的平衡点
  final double requestedRetention;

  /// 间隔上限（天），ts-fsrs 标准 36500
  final double maxIntervalDays;
}

/// 一次复习后的调度结果
class ScheduleResult {
  const ScheduleResult({
    required this.state,
    required this.dueAt,
    required this.stability,
    required this.difficulty,
    required this.reps,
    required this.lapses,
    this.lastReviewedAt,
    this.intervalDays,
  });

  final SchedulingState state;
  final DateTime dueAt;

  /// 本次评分时刻（供上层写回 memory_state.last_reviewed_at）
  final DateTime? lastReviewedAt;

  final double stability;
  final double difficulty;

  /// 累计复习次数（+1）
  final int reps;

  /// 遗忘计数（review 态按 again 时 +1）
  final int lapses;

  /// 调度出的间隔（天）——供展示「下次 X 天后见」
  final double? intervalDays;
}

/// 调度器抽象（插件化：日后可换 SM-2 / 任意实现，不动上层）
abstract class Scheduler {
  ScheduleResult schedule(CardMemoryState current, ReviewRating rating,
      {DateTime? now});
}

// ---------- 常量 ----------
const double _decay = -0.5; // FSRS-4.5 遗忘曲线指数
const double _factor = 19 / 81; // 保证 R(S,S)=0.9

// 学习/重学阶段的分钟步长（Anki 语义）
const int _learningStep1Min = 1; // g=1 blackout → 1 分钟后重现
const int _learningStepMidMin = 5; // g=2 foggy → 中间步
const int _relearningStepMin = 10; // relearning 步长

/// FsrsScheduler：FSRS-4.5 公式 + Anki 状态机（6 级评分，g=1..6）
///
/// 状态流转：
///   newCard     --g<=2--> learning(1/5min)  --g>=3--> review（间隔=S0 系）
///   learning    --g=1--> learning(1min) / --g=2--> learning(5min)
///                --g>=3--> review（毕业，间隔 ≥ 1 天）
///   review      --g<=2--> relearning(10min)，S←S'f，lapse+1
///                --g=3--> review，S←S'r（hardMod=w[15]）
///                --g=4|5--> review，S←S'r（无修正）
///                --g=6--> review，S←S'r（easyMod=w[16]）
///   relearning  --g<=2--> relearning(10min)  --g>=3--> review（毕业，间隔 ≥ 1 天）
class FsrsScheduler implements Scheduler {
  const FsrsScheduler({this.params = const FsrsParams()});

  final FsrsParams params;

  /// 遗忘曲线：距上次复习 t 天后的可提取率
  double retrievability(double stability, double elapsedDays) {
    if (stability <= 0) return 1.0;
    final t = elapsedDays < 0 ? 0.0 : elapsedDays;
    return math.pow(1 + _factor * t / stability, _decay).toDouble();
  }

  /// 由目标保留率反解理想间隔（天）：I(r,S) = S/FACTOR·(r^(1/DECAY)−1)
  double idealInterval(double stability, [double? retention]) {
    final r = retention ?? params.requestedRetention;
    if (stability <= 0) return 0.0;
    return stability / _factor * (math.pow(r, 1 / _decay) - 1);
  }

  @override
  ScheduleResult schedule(CardMemoryState current, ReviewRating rating,
      {DateTime? now}) {
    final t = now ?? DateTime.now();
    final w = params.w;
    final g = rating.index + 1; // blackout=1 foggy=2 struggled=3 hesitant=4 smooth=5 instant=6
    final reps = current.reps + 1;

    // ---------- 新卡：首次评分初始化 ----------
    if (current.state == SchedulingState.newCard) {
      final s0 = _clampS(_s0(g, w));
      final d0 = _clampD(w[4] - w[5] * (g - 3.5));
      if (g <= 2) {
        // blackout / foggy：不毕业，进 learning 分钟步进（g=1 用 step1，g=2 用 stepMid）
        final step = g == 1 ? _learningStep1Min : _learningStepMidMin;
        return ScheduleResult(
          state: SchedulingState.learning,
          dueAt: t.add(Duration(minutes: step)),
          lastReviewedAt: t,
          stability: s0,
          difficulty: d0,
          reps: reps,
          lapses: current.lapses,
          intervalDays: step / (24 * 60),
        );
      }
      // g>=3 直接毕业进 review，间隔 = I(0.9, S0) = S0
      final days = _clampInterval(idealInterval(s0));
      return ScheduleResult(
        state: SchedulingState.review,
        dueAt: t.add(_days(days)),
        lastReviewedAt: t,
        stability: s0,
        difficulty: d0,
        reps: reps,
        lapses: current.lapses,
        intervalDays: days,
      );
    }

    // ---------- learning / relearning（分钟步进） ----------
    if (current.state == SchedulingState.learning ||
        current.state == SchedulingState.relearning) {
      final s = current.stability ?? w[2];
      final d = _updateD(current.difficulty ?? w[4], w, g);
      if (g <= 2) {
        // 保持 learning/relearning：g=1 用 step1，g=2 用 stepMid（relearning 固定 10min）
        final step = current.state == SchedulingState.relearning
            ? _relearningStepMin
            : (g == 1 ? _learningStep1Min : _learningStepMidMin);
        return ScheduleResult(
          state: current.state,
          dueAt: t.add(Duration(minutes: step)),
          lastReviewedAt: t,
          stability: s,
          difficulty: d,
          reps: reps,
          lapses: current.lapses,
          intervalDays: step / (24 * 60),
        );
      }
      // g>=3 毕业进 review：间隔由当前稳定性决定，最小 1 天
      final days = _clampInterval(idealInterval(s));
      return ScheduleResult(
        state: SchedulingState.review,
        dueAt: t.add(_days(days)),
        lastReviewedAt: t,
        stability: s,
        difficulty: d,
        reps: reps,
        lapses: current.lapses,
        intervalDays: days,
      );
    }

    // ---------- review：FSRS-4.5 核心 ----------
    final s = current.stability ?? w[2];
    final d = current.difficulty ?? w[4];

    // R 计算基准：真实 elapsed = now − lastReviewedAt；无记录按「如期复习」≈ S 天
    final elapsedDays = current.lastReviewedAt == null
        ? s.toDouble()
        : t.difference(current.lastReviewedAt!).inMinutes / (24 * 60);
    final r = retrievability(s, elapsedDays).clamp(0.01, 0.99);

    if (g <= 2) {
      // 遗忘（blackout/foggy）：post-lapse stability → relearning，lapse+1
      final sf = w[11] *
          math.pow(d, -w[12]) *
          (math.pow(s + 1, w[13]) - 1) *
          math.exp(w[14] * (1 - r));
      return ScheduleResult(
        state: SchedulingState.relearning,
        dueAt: t.add(const Duration(minutes: _relearningStepMin)),
        lastReviewedAt: t,
        stability: _clampS(sf),
        difficulty: _updateD(d, w, g),
        reps: reps,
        lapses: current.lapses + 1,
        intervalDays: _relearningStepMin / (24 * 60),
      );
    }

    // 成功复习：S'r = S·(1 + e^{w8}·(11−D)·S^{−w9}·(e^{(1−R)·w10}−1)·hardMod·easyMod)
    // g=3(struggled) → hardMod=w[15]；g=4/5 → 无修正；g=6(instant) → easyMod=w[16]
    final hardMod = g == 3 ? w[15] : 1.0;
    final easyMod = g == 6 ? w[16] : 1.0;
    final inc = math.exp(w[8]) *
        (11 - d) *
        math.pow(s, -w[9]) *
        (math.exp((1 - r) * w[10]) - 1) *
        hardMod *
        easyMod;
    final newS = _clampS(s * (1 + inc));

    return ScheduleResult(
      state: SchedulingState.review,
      dueAt: t.add(_days(_clampInterval(idealInterval(newS)))),
      lastReviewedAt: t,
      stability: newS,
      difficulty: _updateD(d, w, g),
      reps: reps,
      lapses: current.lapses,
      intervalDays: _clampInterval(idealInterval(newS)),
    );
  }

  // ---------- 内部工具 ----------

  /// 新卡初始稳定性 S0(G)：6 级（g=1..6）分段插值到 w[0..3] 四个锚点
  ///   g=1(blackout) → w[0]
  ///   g=2(foggy)    → lerp(w[0], w[1], 0.5)
  ///   g=3(struggled)→ w[1]
  ///   g=4(hesitant) → w[2]
  ///   g=5(smooth)   → lerp(w[2], w[3], 0.5)
  ///   g=6(instant)  → w[3]
  double _s0(int g, List<double> w) {
    // 每项 [起点 w 下标, 终点 w 下标, 插值系数 t]：S0 = w[a] + (w[b]−w[a])·t
    final pairs = [
      [0, 0, 0.0], // g=1: w[0]
      [0, 1, 0.5], // g=2: lerp(w[0], w[1], 0.5)
      [1, 1, 0.0], // g=3: w[1]
      [2, 2, 0.0], // g=4: w[2]
      [2, 3, 0.5], // g=5: lerp(w[2], w[3], 0.5)
      [3, 3, 0.0], // g=6: w[3]
    ];
    final p = pairs[g - 1];
    return w[p[0] as int] +
        (w[p[1] as int] - w[p[0] as int]) * (p[2] as double);
  }

  /// 难度更新（FSRS-4.5，6 级中心点 3.5）：
  ///   D' = D − w[6]·(G−3.5)；均值回归 D'' = w[7]·w[4] + (1−w[7])·D'，夹在 [1,10]
  double _updateD(double d, List<double> w, int g) {
    final dNext = d - w[6] * (g - 3.5);
    final reverted = w[7] * w[4] + (1 - w[7]) * dNext;
    return _clampD(reverted);
  }

  /// 毕业后间隔：最小 1 天（四舍五入到整天），上限 maxIntervalDays
  double _clampInterval(double days) {
    final rounded = days.roundToDouble();
    return rounded < 1 ? 1.0 : (rounded > params.maxIntervalDays ? params.maxIntervalDays : rounded);
  }

  static double _clampS(double v) => v.clamp(0.1, 36500).toDouble();
  static double _clampD(double v) => v.clamp(1.0, 10.0).toDouble();

  static Duration _days(double d) =>
      Duration(minutes: (d * 24 * 60).round());
}
