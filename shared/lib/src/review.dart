// 复习记录与评分模型

/// 6 级评分（SuperMemo 0-5 映射）：
///   0 blackout  — 完全忘记（深红）
///   1 foggy     — 只记得见过（橙红）
///   2 struggled — 费力回忆（橙黄）
///   3 hesitant  — 有点犹豫（黄绿）
///   4 smooth    — 比较顺畅（浅绿）
///   5 instant   — 秒答/完全掌握（翠绿）
enum ReviewRating {
  blackout, foggy, struggled, hesitant, smooth, instant;

  /// 旧 4 级字符串 → 新 6 级映射（DB 兼容）
  static ReviewRating fromLegacyName(String name) => switch (name) {
    'again' => ReviewRating.blackout,
    'hard' => ReviewRating.struggled,
    'good' => ReviewRating.smooth,
    'easy' => ReviewRating.instant,
    _ => ReviewRating.blackout,
  };

  /// 兼容旧字符串：先按新枚举名解析，匹配不到再走 legacy 映射
  static ReviewRating parse(String name) =>
      _tryEnum(ReviewRating.values, name) ?? fromLegacyName(name);
}

/// 安全 enum 解析：未知值返回 null 而非抛 ArgumentError。
T? _tryEnum<T extends Enum>(List<T> values, String? name) {
  if (name == null) return null;
  for (final v in values) {
    if (v.name == name) return v;
  }
  return null;
}

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
        rating: _tryEnum(ReviewRating.values, json['rating'] as String?) ??
            (json['rating'] is String
                ? ReviewRating.fromLegacyName(json['rating'] as String)
                : ReviewRating.blackout),
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
