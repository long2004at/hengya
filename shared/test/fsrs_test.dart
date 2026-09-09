// FsrsScheduler 单元测试 —— 验证 FSRS-4.5 数学行为与 Anki 状态机流转
import 'package:shared/hengya_shared.dart';
import 'package:test/test.dart';

void main() {
  final sched = const FsrsScheduler();
  final now = DateTime(2026, 9, 3, 21, 0);

  CardMemoryState card({
    SchedulingState state = SchedulingState.newCard,
    DateTime? dueAt,
    int reps = 0,
    int lapses = 0,
    double? stability,
    double? difficulty,
  }) =>
      CardMemoryState(
        state: state,
        dueAt: dueAt ?? now,
        reps: reps,
        lapses: lapses,
        stability: stability,
        difficulty: difficulty,
      );

  test('新卡首评 good：初始化 S0=w[2]、D0=w[4]，进 review 且间隔 ≈ S0', () {
    final r = sched.schedule(card(), ReviewRating.good, now: now);
    expect(r.state, SchedulingState.review);
    expect(r.stability, closeTo(3.7145, 0.001)); // w[2]
    expect(r.difficulty, closeTo(5.1618, 0.001)); // w[4]
    // I(0.9, S) = S → 到期间隔约 3.7 天
    final intervalDays = r.dueAt.difference(now).inDays;
    expect(intervalDays, inInclusiveRange(3, 4));
    expect(r.lapses, 0);
  });

  test('新卡首评 again：卡在 learning 第一步（分钟级）', () {
    final r = sched.schedule(card(), ReviewRating.again, now: now);
    expect(r.state, SchedulingState.learning);
    expect(r.dueAt.difference(now).inMinutes, 1);
    expect(r.stability, closeTo(0.4872, 0.001)); // w[0] = S0(again)
  });

  test('新卡首评 easy：S0=w[3] 间隔更长', () {
    final rEasy = sched.schedule(card(), ReviewRating.easy, now: now);
    final rGood = sched.schedule(card(), ReviewRating.good, now: now);
    expect(rEasy.stability, closeTo(13.8206, 0.001)); // w[3]
    expect(rEasy.dueAt.isAfter(rGood.dueAt), isTrue);
  });

  test('learning good：毕业进 review，天数级间隔', () {
    final c = card(
      state: SchedulingState.learning,
      dueAt: now.add(const Duration(minutes: 10)),
      stability: 0.4872,
      difficulty: 7.0,
    );
    final r = sched.schedule(c, ReviewRating.good, now: now);
    expect(r.state, SchedulingState.review);
    expect(r.dueAt.difference(now).inDays, greaterThanOrEqualTo(1));
  });

  test('连续 good 复习：stability 单调增长（间隔拉长）', () {
    var c = card(
      state: SchedulingState.review,
      dueAt: now,
      stability: 3.7145,
      difficulty: 5.1618,
      reps: 1,
    );
    final stabilities = <double>[c.stability!];
    var t = now;
    for (var i = 0; i < 5; i++) {
      final r = sched.schedule(c, ReviewRating.good, now: t);
      expect(r.stability, greaterThan(stabilities.last),
          reason: '第 $i 次连续 good 后 S 应增长');
      stabilities.add(r.stability);
      t = r.dueAt; // 按调度到期时间复习
      c = card(
        state: r.state,
        dueAt: r.dueAt,
        stability: r.stability,
        difficulty: r.difficulty,
        reps: c.reps + 1,
        lapses: r.lapses,
      );
    }
    // 五连 good 后间隔应显著长于初始（长期记忆形成）
    expect(stabilities.last, greaterThan(3.7145 * 2));
  });

  test('review 中 again：遗忘 → relearning，lapse+1，stability 回落', () {
    final c = card(
      state: SchedulingState.review,
      dueAt: now,
      stability: 30.0,
      difficulty: 5.0,
      reps: 6,
      lapses: 0,
    );
    final r = sched.schedule(c, ReviewRating.again, now: now);
    expect(r.state, SchedulingState.relearning);
    expect(r.lapses, 1);
    expect(r.stability, lessThan(30.0)); // 遗忘后稳定性大幅回落
    expect(r.dueAt.difference(now).inMinutes, 10); // 重学步长
  });

  test('relearning good：重返 review，lapse 计数保持', () {
    final c = card(
      state: SchedulingState.relearning,
      dueAt: now,
      stability: 2.0,
      difficulty: 7.5,
      lapses: 3,
    );
    final r = sched.schedule(c, ReviewRating.good, now: now);
    expect(r.state, SchedulingState.review);
    expect(r.lapses, 3); // 不再增加
    expect(r.difficulty, greaterThan(7.0)); // 高难度仍保留（回归有限）
  });

  test('lapse 累计到 4 → 调用方可判 leech（数据通路验证）', () {
    final c = card(
      state: SchedulingState.review,
      dueAt: now,
      stability: 5.0,
      lapses: 3, // 已 3 次遗忘
    );
    final r = sched.schedule(c, ReviewRating.again, now: now);
    expect(r.lapses, 4); // ≥4 → leech，进回炉重造（计划书 §四）
  });

  test('easy 间隔 > good 间隔 > hard 间隔（同起点）', () {
    final base = () => card(
          state: SchedulingState.review,
          dueAt: now,
          stability: 5.0,
          difficulty: 5.0,
        );
    final rHard = sched.schedule(base(), ReviewRating.hard, now: now);
    final rGood = sched.schedule(base(), ReviewRating.good, now: now);
    final rEasy = sched.schedule(base(), ReviewRating.easy, now: now);
    expect(rEasy.dueAt.isAfter(rGood.dueAt), isTrue);
    expect(rGood.dueAt.isAfter(rHard.dueAt), isTrue);
  });

  test('难度区间始终 [1,10]，多次 again 不越界', () {
    var d = 5.0;
    for (var i = 0; i < 10; i++) {
      final c = card(
        state: SchedulingState.review,
        dueAt: now,
        stability: 10.0,
        difficulty: d,
        reps: 10,
      );
      final r = sched.schedule(c, ReviewRating.again, now: now);
      d = r.difficulty;
      expect(d, inInclusiveRange(1, 10));
    }
  });

  test('遗忘曲线：t=S 时 R≈0.9；t>S 时 R 下降', () {
    const s = 10.0;
    final rAtS = sched.retrievability(s, s);
    expect(rAtS, closeTo(0.9, 0.001));
    final rLater = sched.retrievability(s, s * 2);
    expect(rLater, lessThan(0.9));
    final rZero = sched.retrievability(s, 0);
    expect(rZero, 1.0);
  });

  test('理想间隔：retention=0.9 时 I(S)=S', () {
    final i = sched.idealInterval(10.0, 0.9);
    expect(i, closeTo(10.0, 0.01));
  });
}
