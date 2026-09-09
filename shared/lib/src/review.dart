// 复习记录与评分模型
// 评分四档（Anki 语义）：again 重来 / hard 困难 / good 良好 / easy 简单

enum ReviewRating { again, hard, good, easy }

/// 单次复习记录（App 本地缓存 → 联网补传 POST /review/answer）
class ReviewLog {
  const ReviewLog({
    required this.cardId,
    required this.subjectId,
    required this.rating,
    required this.reviewedAt,
    this.latencyMs,
    this.offlineQueued = false,
  });

  final String cardId;
  final String subjectId;
  final ReviewRating rating;
  final DateTime reviewedAt;

  /// 翻面到评分的耗时（毫秒），可用于统计犹豫度（v2）
  final int? latencyMs;

  /// 是否经离线队列补传（13.6）
  final bool offlineQueued;

  Map<String, dynamic> toJson() => {
        'cardId': cardId,
        'subjectId': subjectId,
        'rating': rating.name,
        'reviewedAt': reviewedAt.toIso8601String(),
        if (latencyMs != null) 'latencyMs': latencyMs,
        'offlineQueued': offlineQueued,
      };

  factory ReviewLog.fromJson(Map<String, dynamic> json) => ReviewLog(
        cardId: json['cardId'] as String,
        subjectId: json['subjectId'] as String,
        rating: ReviewRating.values.byName(json['rating'] as String),
        reviewedAt: DateTime.parse(json['reviewedAt'] as String),
        latencyMs: json['latencyMs'] as int?,
        offlineQueued: json['offlineQueued'] as bool? ?? false,
      );
}

/// 卡片的调度状态（Anki 状态机：new / learning / review / relearning）
enum SchedulingState { newCard, learning, review, relearning }

/// 挂在每张卡上的调度器状态（M1 由 FsrsScheduler 维护）
class CardMemoryState {
  const CardMemoryState({
    required this.state,
    required this.dueAt,
    required this.reps,
    required this.lapses,
    this.lastReviewedAt,
    this.stability,
    this.difficulty,
  });

  final SchedulingState state;
  final DateTime dueAt;

  /// 累计复习次数
  final int reps;

  /// 遗忘次数（lapse ≥ 4 → leech，进回炉重造，计划书 §四）
  final int lapses;

  /// 上次复习时刻 —— FSRS 计算 R（可提取率）的时间基准：t = now − lastReviewedAt
  final DateTime? lastReviewedAt;

  /// FSRS 稳定性（天）：间隔拉长的核心参数
  final double? stability;

  /// FSRS 难度（1-10）
  final double? difficulty;
}
