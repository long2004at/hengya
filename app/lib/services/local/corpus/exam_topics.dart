// 真题考站专题常量（节点③：真题专题上传，B1 拍板——12 考站专题各建
// 一棵 -exam 语料树，不进科目 Tab / subjects 表，仅作周扫真题池）。
//
// 词表对齐建库侧 splitSubjectSource（extract_pptx.dart）：首层目录名
// `<短码>-exam` → (subject_id=<短码>, source_type='exam')。
// 节点⑤（周扫真题池）按本常量引用短码与 isSkill 标记。
//
// 中文名→短码与 isSkill 取值为用户逐字拍板（2026-09-07 节点③规格），
// 禁止改动拼写：
//   isSkill=true  → 技能考站类专题（病史采集/病例分析/检查方法/操作技能/急救技术）
//   isSkill=false → 理论知识类专题（其余 7 项）

/// 一个真题考站专题：短码 + 中文名 + 技能考站标记。
class ExamTopic {
  const ExamTopic({
    required this.code,
    required this.name,
    required this.isSkill,
  });

  /// 短码（小写字母）——真题树首层目录名 = `<code>-exam`
  /// （如 bingshi → incoming/bingshi-exam/）。
  final String code;

  /// 中文名（上传弹层「专题选择」显示用）。
  final String name;

  /// 技能考站标记（true = 技能操作类考站；⑤周扫按此分组）。
  final bool isSkill;
}

/// 12 真题考站专题（顺序 = 用户拍板清单原序）。
const List<ExamTopic> kExamTopics = [
  ExamTopic(code: 'bingshi', name: '病史采集类', isSkill: true),
  ExamTopic(code: 'bingli', name: '病例分析类', isSkill: true),
  ExamTopic(code: 'jiancha', name: '检查方法类', isSkill: true),
  ExamTopic(code: 'caozuo', name: '操作技能类', isSkill: true),
  ExamTopic(code: 'jijiu', name: '急救技术类', isSkill: true),
  ExamTopic(code: 'xiufu', name: '修复类专题', isSkill: false),
  ExamTopic(code: 'jibing', name: '口腔疾病专题类', isSkill: false),
  ExamTopic(code: 'kuiyang', name: '口腔黏膜溃疡类', isSkill: false),
  ExamTopic(code: 'bawen', name: '口腔黏膜白色斑纹类', isSkill: false),
  ExamTopic(code: 'zhongliu', name: '肿瘤与囊肿类', isSkill: false),
  ExamTopic(code: 'suzhi', name: '职业素质与医德医风', isSkill: false),
  ExamTopic(code: 'shijuan', name: '试卷与模拟题', isSkill: false),
];

/// 短码 → 专题（上传落盘守卫：source=exam 的 subject 必须在本表内）。
ExamTopic? examTopicByCode(String? code) {
  if (code == null) return null;
  for (final t in kExamTopics) {
    if (t.code == code) return t;
  }
  return null;
}
