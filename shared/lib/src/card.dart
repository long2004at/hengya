// FlashCard 数据模型 —— 与 docs/卡片编写规范.md 的 JSON schema 一一对应
// 状态流转：pending(待审核) → active(复习中) → archived(拒绝/精熟退场)
//           pending → rejected；active → rework(回炉重造) → pending

/// 卡型（规范 §三：六种卡型）
enum CardType {
  basic, // 基础问答（含定义/列举/对比，靠 tags 区分）
  cloze, // 填空
  caseChain, // 病例卡链
  image, // 图像辨识（v1 预留）
}

/// 审核与生命周期状态
enum CardStatus { pending, active, rejected, archived, rework }

/// 答案来源层级（规范 §六：来源三级体系）
/// ppt = 课程PPT（答案主体） > exam = 考纲/真题（权重与问法校准） > textbook = 教材（拓展，需确认）
enum SourceTier { ppt, exam, textbook, user }

class FlashCard {
  const FlashCard({
    required this.id,
    required this.subjectId,
    required this.type,
    required this.front,
    required this.back,
    required this.anchor,
    required this.source,
    required this.status,
    this.sourceTier = SourceTier.ppt,
    this.tags = const [],
    this.examYear,
    this.dupCheck = 'ok',
    this.dupOf,
    this.createdAt,
    this.updatedAt,
  });

  final String id;

  /// 所属科目（科目隔离，决策 #8）
  final String subjectId;
  final CardType type;

  /// 题干（自包含，规范五条硬性原则之一）
  final String front;

  /// 答案（单卡单考点，答案事件数 ≤ 1，规范 v1.1）
  final String back;

  /// 锚点：PPT 页码/章节，答案可追溯
  final String anchor;

  /// 来源描述，如「口腔颌面外科学 第1章 PPT p.12」
  final String source;
  final SourceTier sourceTier;
  final CardStatus status;
  final List<String> tags;

  /// 真题卡：保留年份元数据（规范 §六，统计页单看真题卡正确率）
  final String? examYear;

  /// 查重状态（#11，2026-09-13）：
  /// ok = 已查无重复；dup = 疑似重复（dupOf 指向已有卡）；
  /// skipped = 未查重（嵌入 API 不可用降级，审核区带「未查重」徽标）。
  final String dupCheck;

  /// dupCheck=dup 时指向的疑似重复已有卡 id（其余为 null）。
  final String? dupOf;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'subjectId': subjectId,
        'type': type.name,
        'front': front,
        'back': back,
        'anchor': anchor,
        'source': source,
        'sourceTier': sourceTier.name,
        'status': status.name,
        'tags': tags,
        if (examYear != null) 'examYear': examYear,
        'dupCheck': dupCheck,
        if (dupOf != null) 'dupOf': dupOf,
        if (createdAt != null) 'createdAt': createdAt!.toIso8601String(),
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
      };

  factory FlashCard.fromJson(Map<String, dynamic> json) => FlashCard(
        id: json['id'] as String,
        subjectId: json['subjectId'] as String,
        type: CardType.values.byName(json['type'] as String),
        front: json['front'] as String,
        back: json['back'] as String,
        anchor: json['anchor'] as String,
        source: json['source'] as String,
        sourceTier:
            SourceTier.values.byName(json['sourceTier'] as String? ?? 'ppt'),
        status:
            CardStatus.values.byName(json['status'] as String? ?? 'pending'),
        tags: (json['tags'] as List<dynamic>? ?? const [])
            .map((e) => e as String)
            .toList(),
        examYear: json['examYear'] as String?,
        dupCheck: json['dupCheck'] as String? ?? 'ok',
        dupOf: json['dupOf'] as String?,
        createdAt: json['createdAt'] == null
            ? null
            : DateTime.parse(json['createdAt'] as String),
        updatedAt: json['updatedAt'] == null
            ? null
            : DateTime.parse(json['updatedAt'] as String),
      );
}
