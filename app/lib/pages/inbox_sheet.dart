// 关键词收件箱弹层（计划书 §五.6 / §五.8）——三字段结构化表单：
// ① 选科目 → ② 学了哪些章节（每章一行，流水线据此检索教材推进学习进度）
// ③ 重点关键词（拆成卡片，进待审核池）→ 统一提交。
// 拆分规则（已拍板）：章节仅按换行拆（章名可含顿号/逗号如「临床表现、诊断与治疗」，
// 按标点拆会误拆一章为两条）；关键词按 [\n、，,] 拆分。
// 服务端 inbox.source 落位：章节条目='study-log'（罗盘推进，不出卡）、
// 关键词条目='app'（22:55 三级检索→LLM 拆卡→幂等 import）。
// M5 动态科目：科目列表来自服务端（缓存+刷新），拉取失败 → 空态 + 刷新重试
//（0.3.1 起无内置科目兜底）；内联「＋新建课程」——创建成功立即可选，
// TopToast 展示短码。
import 'package:flutter/material.dart';

import '../services/api/api_client.dart';
import '../theme.dart';
import '../widgets/top_toast.dart';
import 'subject_picker.dart';

/// 入箱弹层：选科目 → 章节学习记录（可空）+ 关键词（可空）→ 统一提交
/// [presetSubjectId] 可选：从科目卡进入时预选该科
Future<bool?> showInboxSheet(BuildContext context, {String? presetSubjectId}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _InboxSheet(presetSubjectId: presetSubjectId),
  );
}

class _InboxSheet extends StatefulWidget {
  const _InboxSheet({this.presetSubjectId});

  final String? presetSubjectId;

  @override
  State<_InboxSheet> createState() => _InboxSheetState();
}

class _InboxSheetState extends State<_InboxSheet> {
  final _chapterCtrl = TextEditingController();
  final _keywordCtrl = TextEditingController();
  List<SubjectInfo> _subjects = [];
  bool _failed = false; // 科目列表拉取失败 → 空态 + 刷新重试
  bool _refreshing = false;
  String? _subjectId;
  bool _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _subjectId = widget.presetSubjectId;
    _loadSubjects();
  }

  Future<void> _loadSubjects({bool refresh = false}) async {
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
        _failed = false;
        _refreshing = false;
        _subjectId ??= subs.isNotEmpty ? subs.first.id : null;
      });
    } on ApiException {
      // 科目列表拉取失败 → 保留既有列表（可能为空）+ 失败标记，
      // 用户经右上角刷新或「新建课程」走出困境
      if (!mounted) return;
      setState(() {
        _failed = true;
        _refreshing = false;
      });
    }
  }

  /// 内联「＋新建课程」：创建成功 → 加入列表立即选中 → 顶部气泡展示短码
  Future<void> _createSubject() async {
    final created = await showCreateSubjectDialog(context);
    if (created == null) return;
    if (!mounted) return;
    announceSubjectCreated(context, created);
    setState(() {
      _subjects = [..._subjects, created];
      _subjectId = created.id; // 创建成功立即可选
    });
  }

  /// 章节字段拆分：仅按换行拆（每章一行；章名可含顿号/逗号，不按标点拆）
  List<String> _splitChapters(String text) => text
      .split(RegExp(r'\r?\n'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  /// 关键词字段拆分：换行/顿号/中英文逗号均可分隔（沿用既有口径）
  List<String> _splitKeywords(String text) => text
      .split(RegExp(r'[\n、，,]'))
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  Future<void> _submit() async {
    final chapters = _splitChapters(_chapterCtrl.text);
    final keywords = _splitKeywords(_keywordCtrl.text);
    if (_subjectId == null) {
      setState(() => _error = '请先选择科目');
      return;
    }
    if (chapters.isEmpty && keywords.isEmpty) {
      setState(() => _error = '请至少填写章节或关键词其中一项');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    // 章节条目 source='study-log'（流水线走罗盘推进）；关键词条目 source='app'（拆卡）
    // 提交是写操作：不缓存、不自动补传——离线失败必须明确告知（问1+5 口径）
    var chOk = 0;
    var kwOk = 0;
    var fail = 0;
    var netFail = 0; // 其中网络级失败（statusCode==0）条数
    for (final ch in chapters) {
      try {
        await ApiClient.instance.addKeyword(
          subjectId: _subjectId!,
          keyword: ch,
          source: 'study-log',
        );
        chOk++;
      } on ApiException catch (e) {
        fail++;
        if (e.statusCode == 0) netFail++;
      }
    }
    for (final kw in keywords) {
      try {
        await ApiClient.instance.addKeyword(
          subjectId: _subjectId!,
          keyword: kw,
        );
        kwOk++;
      } on ApiException catch (e) {
        fail++;
        if (e.statusCode == 0) netFail++;
      }
    }
    if (!mounted) return;
    setState(() => _sending = false);
    final anyOk = chOk + kwOk > 0;
    // TopToast 挂 rootOverlay，先展示再 pop 弹层（pop 后 context 失效）
    if (fail == 0) {
      TopToast.show(
        context,
        '已入箱：章节 $chOk 条 + 关键词 $kwOk 条',
        type: TopToastType.success,
        stayDuration: const Duration(milliseconds: 1600),
      );
    } else if (!anyOk && netFail == fail) {
      // 全部失败且均为网络级 → 明确「需要联网」，不用含糊的「可稍后重试」
      TopToast.show(
        context,
        '未能入箱：'
        '${currentBackendMode == BackendMode.local ? '本地数据写入失败' : '当前离线/服务器不可达，联网后重试'}'
        '（共 $fail 条）',
        type: TopToastType.error,
        stayDuration: const Duration(milliseconds: 2400),
      );
    } else {
      TopToast.show(
        context,
        '入箱：章节 $chOk + 关键词 $kwOk，失败 $fail 条（可稍后重试）',
        type: TopToastType.error,
        stayDuration: const Duration(milliseconds: 2200),
      );
    }
    Navigator.of(context).pop(anyOk);
  }

  @override
  void dispose() {
    _chapterCtrl.dispose();
    _keywordCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: ConstrainedBox(
        // 三字段+键盘可能超高：限制在屏高 85% 内滚动
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '记课堂重点',
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
                      onPressed: () => _loadSubjects(refresh: true),
                      icon: const Icon(Icons.refresh, size: 20),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              // 说明文案：章节与关键词的用途分流（章节推进进度 / 关键词拆卡）
              Text(
                '章节用于推进该科学习进度；关键词今晚 22:55 自动拆成卡片，进待审核池',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
              const SizedBox(height: 16),
              // ① 科目选择（M5：动态科目 + 内置兜底 + 内联新建）
              Text(
                '① 课程',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: HengyaColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in _subjects)
                    ChoiceChip(
                      // M3 chipTheme.labelStyle 非空会整体替换默认状态化样式（含色），
                      // 故 label 显式给色：选中白字配品牌蓝底，未选中深色字
                      label: Text(
                        s.name,
                        style: TextStyle(
                          fontSize: 13,
                          color: _subjectId == s.id
                              ? Colors.white
                              : HengyaColors.textPrimary,
                        ),
                      ),
                      selected: _subjectId == s.id,
                      onSelected: (_) => setState(() => _subjectId = s.id),
                    ),
                  ActionChip(
                    avatar: Icon(Icons.add, size: 16, color: scheme.primary),
                    label: Text(
                      '新建课程',
                      style: TextStyle(fontSize: 13, color: scheme.primary),
                    ),
                    onPressed: _createSubject,
                  ),
                ],
              ),
              if (_failed) ...[
                const SizedBox(height: 6),
                Text(
                  '科目列表读取失败，可点右上角刷新重试',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
              const SizedBox(height: 16),
              // ② 章节学习记录：仅按换行拆分（每章一行）
              Text(
                '② 学了哪些章节（每章一行）',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: HengyaColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _chapterCtrl,
                maxLines: 3,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '每章一行\n如：第三章 新航路的开辟',
                  helperText: '章名可含顿号/逗号，一行就是一章',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // ③ 重点关键词：换行/顿号/逗号分隔均可
              Text(
                '③ 重点关键词',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: HengyaColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _keywordCtrl,
                maxLines: 3,
                textInputAction: TextInputAction.newline,
                decoration: InputDecoration(
                  hintText: '逗号/顿号/换行分隔\n如：文艺复兴、工业革命',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _sending ? null : _submit,
                  child: _sending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('存入收件箱'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
