// 科目选择器 + 新建课程（M5 动态科目）：
// 关键词录入栏 / 课件上传共用的动态科目来源——列表来自服务端（缓存+刷新），
// 拉取失败 → 空态 + 右上角刷新重试（0.3.1 起无内置科目兜底）；内联
//「＋新建课程」，创建成功立即可选。
import 'package:flutter/material.dart';

import '../services/api/api_client.dart';
import '../services/local/corpus/exam_topics.dart';
import '../widgets/top_toast.dart';

/// 新建课程对话框：名称必填、短码可选（留空服务端自动生成）。
/// 返回创建成功的科目；取消/失败返回 null。
Future<SubjectInfo?> showCreateSubjectDialog(BuildContext context) {
  final nameCtrl = TextEditingController();
  final idCtrl = TextEditingController();
  // 状态放闭包外层：StatefulBuilder 的 builder 每次重建会执行，
  // 局部变量写在 builder 里会被重置（测试抓到：错误提示一闪即失）
  String? error;
  bool sending = false;

  return showDialog<SubjectInfo>(
    context: context,
    builder: (dlgCtx) => StatefulBuilder(
      builder: (dlgCtx, setDlgState) {
        Future<void> submit() async {
          final name = nameCtrl.text.trim();
          if (name.isEmpty) {
            setDlgState(() => error = '课程名称必填');
            return;
          }
          setDlgState(() {
            sending = true;
            error = null;
          });
          try {
            final created = await ApiClient.instance.createSubject(
              name: name,
              id: idCtrl.text,
            );
            if (dlgCtx.mounted) Navigator.of(dlgCtx).pop(created);
          } on ApiException catch (e) {
            setDlgState(() {
              sending = false;
              // 409 有两种冲突（重名/短码重复）——本地与服务端的 message 均为可直接
              // 展示的裸中文（API 错误契约），直接透传；旧版一律提示「短码已被占用」
              // 会误导重名场景（2026-09-06 五问专项整改）
              error = e.statusCode == 409
                  ? e.message
                  : (e.statusCode == 0
                        ? '连不上服务器，请检查网络'
                        : '创建失败（${e.statusCode}）');
            });
          }
        }

        return AlertDialog(
          title: const Text('新建课程'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '课程名称（必填）',
                  hintText: '如：世界历史',
                ),
                onSubmitted: (_) => submit(),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: idCtrl,
                decoration: const InputDecoration(
                  labelText: '短码（可选）',
                  hintText: '如 hist，留空自动生成',
                  helperText: '笔记本语料目录将用此短码命名',
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(
                  error!,
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(dlgCtx).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dlgCtx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: sending ? null : submit,
              child: sending
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('创建'),
            ),
          ],
        );
      },
    ),
  );
}

/// 新建成功提示：展示短码 + 语料目录命名约定（用户明确要求的提示语）。
/// 2026-09-06 用户拍板：轻提示统一走顶部气泡（快速淡化 + 底色随机氛围），
/// 替换默认灰色 SnackBar。
void announceSubjectCreated(BuildContext context, SubjectInfo created) {
  TopToast.show(
    context,
    '已创建「${created.name}」，短码 ${created.id} · 笔记本语料目录请用此短码命名',
    type: TopToastType.success,
    stayDuration: const Duration(milliseconds: 1600),
  );
}

/// 科目选择弹层（上传课件用）：动态列表 + 刷新 + 内联「＋新建课程」。
/// 返回选中的科目；取消返回 null。（内部与上传弹层共用一张弹层：恒弹
/// [UploadTarget] 记录，此处解包科目——旧签名/旧行为零变化。）
Future<SubjectInfo?> showSubjectPickerSheet(
  BuildContext context, {
  String? title,
}) async {
  final r = await showModalBottomSheet<UploadTarget>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SubjectPickerSheet(title: title),
  );
  return r?.subject;
}

/// 上传目标（科目 + 语料类型）：sourceType 词表对齐建库侧
/// splitSubjectSource——'ppt'=课件（默认）/ 'textbook'=教材（落
/// incoming/<短码>-textbook/ 教材树 → 建库写 toc sidecar → 罗盘自动生成）/
/// 'exam'=真题（落 incoming/<短码>-exam/ 真题树 → source_type='exam'，
/// 不进科目 Tab，仅作周扫真题池）/ 'outline'=大纲（节点④：跳过科目/专题
/// 选择 → 落 incoming/dagang-outline/ 大纲树 → 建库路由 outline 解析器 →
/// outline_entries + med 占位，正文不进常规语料块）。
typedef UploadTarget = ({SubjectInfo subject, String sourceType});

/// 上传链专用弹层：科目 + 「类型」单选一并选择。[pickUploadType] 为 true
/// 时标题下多一块类型区（课件（默认）/ 教材 / 真题 / 大纲 + 一行说明
/// 文案），点科目即确认整组返回（同一次上传只属一种类型）；选「真题」时
/// 科目选择区切换为「专题选择」（[kExamTopics] 12 考站专题，静态清单不
/// 经 /subjects）；选「大纲」时切换为大纲确认项（无需选科目，固定落
/// dagang-outline）；false 时不渲染类型区，sourceType 恒 'ppt'（= 课件，
/// [uploadCourseware] 不携带 source 参数）。
Future<UploadTarget?> showUploadTargetPickerSheet(
  BuildContext context, {
  String? title,
  bool pickUploadType = false,
}) {
  return showModalBottomSheet<UploadTarget>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        _SubjectPickerSheet(title: title, pickUploadType: pickUploadType),
  );
}

/// 类型单选说明文案（逐字，UI 测试锚点）。
const String kUploadTypeHint = '教材：学习罗盘章节目录；课件：拆卡检索；真题：真题池；大纲：考试大纲入库打标';

class _SubjectPickerSheet extends StatefulWidget {
  const _SubjectPickerSheet({this.title, this.pickUploadType = false});

  final String? title;

  /// true → 标题下渲染「类型」单选（课件/教材），弹层返回 [UploadTarget]；
  /// false（缺省）→ 旧形态，返回裸 [SubjectInfo]（既有调用零变化）。
  final bool pickUploadType;

  @override
  State<_SubjectPickerSheet> createState() => _SubjectPickerSheetState();
}

class _SubjectPickerSheetState extends State<_SubjectPickerSheet> {
  List<SubjectInfo> _subjects = [];
  bool _loading = true;
  bool _failed = false; // 拉取失败 → 空态 + 刷新重试（不再回退硬编码清单）
  bool _refreshing = false;

  /// 「类型」单选当前值（仅 [pickUploadType] 弹层渲染）：课件 'ppt'（默认）/
  /// 教材 'textbook' / 真题 'exam' / 大纲 'outline'。词表 =
  /// splitSubjectSource 的 sourceType。
  String _sourceType = 'ppt';

  /// 选中/新建课程后的统一出栈：恒弹 [UploadTarget] 记录（科目 + 当前
  /// 类型），由两个入口函数按各自返回类型消费。
  void _popWith(SubjectInfo s) {
    Navigator.of(
      context,
    ).pop<UploadTarget>((subject: s, sourceType: _sourceType));
  }

  /// 真题专题出栈：无服务端科目——合成 [SubjectInfo]（id=短码、
  /// name=专题中文名）随 sourceType='exam' 整组返回；落盘侧守卫按
  /// [kExamTopics] 短码表校验，绝不进 subjects 表。
  void _popWithExamTopic(ExamTopic t) {
    _popWith(SubjectInfo(id: t.code, name: t.name));
  }

  /// 大纲出栈（节点④）：跳过科目/专题选择——合成 [SubjectInfo]
  /// （id='dagang'、name='考试大纲'）随 sourceType='outline' 整组返回；
  /// 落盘侧守卫固定短码 dagang → incoming/dagang-outline/。
  void _popWithOutline() {
    _popWith(const SubjectInfo(id: 'dagang', name: '考试大纲'));
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool refresh = false}) async {
    if (refresh) {
      if (_refreshing) return;
      setState(() => _refreshing = true);
    }
    try {
      final subs = await ApiClient.instance.fetchSubjectCatalog(
        refresh: refresh,
      );
      if (!mounted) return;
      setState(() {
        _subjects = subs;
        _loading = false;
        _refreshing = false;
        _failed = false;
      });
    } on ApiException {
      // 科目列表拉取失败 → 保留既有列表（可能为空）+ 失败标记，
      // 用户经右上角刷新或「新建课程」走出困境
      if (!mounted) return;
      setState(() {
        _loading = false;
        _refreshing = false;
        _failed = true;
      });
    }
  }

  /// 内联新建：创建成功 → 顶部气泡展示短码 → 立即选中并返回
  Future<void> _create() async {
    final created = await showCreateSubjectDialog(context);
    if (created == null) return;
    if (!mounted) return;
    announceSubjectCreated(context, created);
    setState(() => _subjects = [..._subjects, created]);
    _popWith(created);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title ?? '选择科目',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (_refreshing)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  IconButton(
                    tooltip: '刷新科目列表',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _load(refresh: true),
                    icon: const Icon(Icons.refresh, size: 20),
                  ),
              ],
            ),
            // 「类型」单选（仅上传链弹层渲染）：课件（默认）/ 教材 + 一行说明
            // 文案——同一次上传只属一种类型；点下方科目即按当前类型整组确认。
            //（RadioListTile 弃用的 groupValue/onChanged 不用——组态经
            // RadioGroup 祖先管理，Flutter 3.44 新 API。）
            if (widget.pickUploadType) ...[
              const SizedBox(height: 8),
              const Divider(height: 1),
              RadioGroup<String>(
                groupValue: _sourceType,
                onChanged: (v) => setState(() => _sourceType = v ?? 'ppt'),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '课件',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      value: 'ppt',
                    ),
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '教材',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      value: 'textbook',
                    ),
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '真题',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      value: 'exam',
                    ),
                    RadioListTile<String>(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        '大纲',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      value: 'outline',
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  kUploadTypeHint,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ),
              const Divider(height: 1),
            ],
            const SizedBox(height: 4),
            Text(
              _sourceType == 'exam'
                  ? '专题选择'
                  : (_sourceType == 'outline'
                        ? '大纲（无需选择科目）'
                        : (_failed
                              ? '科目列表读取失败，可点右上角刷新重试'
                              : (currentBackendMode == BackendMode.local
                                    ? '科目列表'
                                    : '来自服务器的课程列表'))),
              style: TextStyle(fontSize: 12, color: scheme.outline),
            ),
            const SizedBox(height: 8),
            Flexible(
              // 真题：科目选择区切换为 12 考站专题（静态常量，不经
              // /subjects；无「新建课程」——专题清单固定，点选即整组确认）。
              // 大纲（节点④）：跳过科目/专题选择——单一确认项，点选即
              // 整组返回（dagang + outline）。
              child: _sourceType == 'exam'
                  ? ListView(
                      shrinkWrap: true,
                      children: [
                        for (final t in kExamTopics)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              t.name,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onTap: () => _popWithExamTopic(t),
                          ),
                      ],
                    )
                  : _sourceType == 'outline'
                  ? ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            '口腔执业/助理医师资格考试大纲',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: const Text(
                            '上传 .docx 大纲文件（执业/助理自动识别）',
                            style: TextStyle(fontSize: 12),
                          ),
                          onTap: _popWithOutline,
                        ),
                      ],
                    )
                  : _loading
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final s in _subjects)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                              s.name,
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            onTap: () => _popWith(s),
                          ),
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(
                            Icons.add_circle_outline,
                            size: 20,
                            color: scheme.primary,
                          ),
                          title: Text(
                            '新建课程',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: scheme.primary,
                            ),
                          ),
                          onTap: _create,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
