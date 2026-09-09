// 科目模型 —— 与 schedule/schedule.json 的 subjects 对应
// 考试课（高优）vs 考查课（常规）影响拆卡优先级与 App 展示排序

class Subject {
  const Subject({
    required this.id,
    required this.name,
    required this.isExamSubject,
    this.teacher,
  });

  final String id;

  /// 完整名称，如「口腔颌面外科学」
  final String name;

  /// 考试课 = true（口腔颌面外科学/牙体牙髓病学/口腔修复学）
  /// 考查课 = false
  final bool isExamSubject;

  final String? teacher;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'isExamSubject': isExamSubject,
        if (teacher != null) 'teacher': teacher,
      };

  factory Subject.fromJson(Map<String, dynamic> json) => Subject(
        id: json['id'] as String,
        name: json['name'] as String,
        isExamSubject: json['isExamSubject'] as bool? ?? false,
        teacher: json['teacher'] as String?,
      );
}
