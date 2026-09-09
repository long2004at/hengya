// FSRS-4.5 调度器实现 —— 恒牙的间隔重复引擎
// 数学模型：open-spaced-repetition FSRS-4.5（17 参数），公式与 ts-fsrs/py-fsrs 逐条对齐
// 状态机：Anki 语义（new / learning / review / relearning），算法插件化可替换
//
// 【0-based 权重对照表】（17 参数，官方默认）
//   w[0..3]  = S0(G)：again/hard/good/easy 的初始稳定性
//   w[4]     = D0(3)：good 首评的初始难度
//   w[5]     = 初始难度斜率：D0(G) = w[4] − w[5]·(G−3)
//   w[6]     = 难度更新斜率：ΔD = −w[6]·(G−3)
//   w[7]     = 难度均值回归权重：D'' = w[7]·w[4] + (1−w[7])·D'
//   w[8..10] = 成功后稳：S'r = S·(1 + e^{w[8]}·(11−D)·S^{−w[9]}·(e^{(1−R)·w[10]}−1)·hardMod·easyMod)
//   w[11..14]= 遗忘后稳：S'f = w[11]·D^{−w[12]}·((S+1)^{w[13]} − 1)·e^{w[14]·(1−R)}
//   w[15]    = hard 惩罚乘数（0.2272，<1）
//   w[16]    = easy 加成乘数（2.8755，>1）
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
const int _learningStep1Min = 1; // again → 1 分钟后重现
const int _learningStepMidMin = 5; // hard → 中间步
const int _relearningStepMin = 10; // relearning 步长

/// FsrsScheduler：FSRS-4.5 公式 + Anki 状态机
///
/// 状态流转：
///   newCard     --again--> learning(1min)  --hard/good/easy--> review（间隔=S0 系）
///   learning    --again--> learning(1min) / --hard--> learning(5min)
///                --good|easy--> review（毕业，间隔 ≥ 1 天）
///   review      --again--> relearning(10min)，S←S'f，lapse+1
///                --hard|good|easy--> review，S←S'r
///   relearning  --again|hard--> relearning(10min)
///                --good|easy--> review（毕业，间隔 ≥ 1 天）
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
    final g = rating.index + 1; // again=1 hard=2 good=3 easy=4
    final reps = current.reps + 1;

    // ---------- 新卡：首次评分初始化 ----------
    if (current.state == SchedulingState.newCard) {
      final s0 = _clampS(w[g - 1]);
      final d0 = _clampD(w[4] - w[5] * (g - 3));
      if (rating == ReviewRating.again) {
        return ScheduleResult(
          state: SchedulingState.learning,
          dueAt: t.add(const Duration(minutes: _learningStep1Min)),
          lastReviewedAt: t,
          stability: s0,
          difficulty: d0,
          reps: reps,
          lapses: current.lapses,
          intervalDays: _learningStep1Min / (24 * 60),
        );
      }
      // hard/good/easy 直接毕业进 review，间隔 = I(0.9, S0) = S0
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
      switch (rating) {
        case ReviewRating.again:
          final step = current.state == SchedulingState.relearning
              ? _relearningStepMin
              : _learningStep1Min;
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
        case ReviewRating.hard:
          final step = current.state == SchedulingState.relearning
              ? _relearningStepMin
              : _learningStepMidMin;
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
        case ReviewRating.good:
        case ReviewRating.easy:
          // 毕业进 review：间隔由当前稳定性决定，最小 1 天
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
    }

    // ---------- review：FSRS-4.5 核心 ----------
    final s = current.stability ?? w[2];
    final d = current.difficulty ?? w[4];

    // R 计算基准：真实 elapsed = now − lastReviewedAt；无记录按「如期复习」≈ S 天
    final elapsedDays = current.lastReviewedAt == null
        ? s.toDouble()
        : t.difference(current.lastReviewedAt!).inMinutes / (24 * 60);
    final r = retrievability(s, elapsedDays).clamp(0.01, 0.99);

    if (rating == ReviewRating.again) {
      // 遗忘：post-lapse stability → relearning，lapse+1
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
    final hardMod = rating == ReviewRating.hard ? w[15] : 1.0;
    final easyMod = rating == ReviewRating.easy ? w[16] : 1.0;
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

  /// 难度更新（FSRS-4.5）：
  ///   D' = D − w[6]·(G−3)；均值回归 D'' = w[7]·w[4] + (1−w[7])·D'，夹在 [1,10]
  double _updateD(double d, List<double> w, int g) {
    final dNext = d - w[6] * (g - 3);
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
