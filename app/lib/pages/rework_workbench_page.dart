import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api/api_client.dart';
import '../services/review/rework_models.dart';
import '../widgets/top_toast.dart';
import 'corpus_library_page.dart';
import 'bank_page.dart';

class ReworkWorkbenchPage extends StatelessWidget {
  const ReworkWorkbenchPage({super.key, this.taskId});
  final int? taskId;
  @override
  Widget build(BuildContext context) =>
      taskId == null ? const _TaskList() : _TaskDetail(id: taskId!);
}

class _TaskList extends StatefulWidget {
  const _TaskList();
  @override
  State<_TaskList> createState() => _TaskListState();
}

class _TaskListState extends State<_TaskList> {
  final List<Map<String, dynamic>> _tasks = [];
  String _filter = 'open';
  String? _error;
  int _total = 0;
  bool _loading = false;
  Timer? _poll;
  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted &&
          ModalRoute.of(context)?.isCurrent == true &&
          _tasks.any((t) => ['queued', 'generating'].contains(t['status']))) {
        _load();
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load({bool more = false}) async {
    if (_loading || currentBackendMode != BackendMode.local) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final filter = _filter;
    try {
      // 自动刷新保留已经加载的窗口，不把第二页以后的任务截回 40 条。
      final wanted = more ? 40 : (_tasks.length < 40 ? 40 : _tasks.length);
      final refreshed = <Map<String, dynamic>>[];
      var total = _total;
      while (refreshed.length < wanted) {
        final left = wanted - refreshed.length;
        final result = await ApiClient.instance.fetchReworkTasks(
          status: filter,
          offset: (more ? _tasks.length : 0) + refreshed.length,
          limit: left > 200 ? 200 : left,
        );
        final batch = [
          for (final t in result['tasks'] as List)
            Map<String, dynamic>.from(t as Map),
        ];
        refreshed.addAll(batch);
        total = (result['total'] as num).toInt();
        if (batch.isEmpty ||
            (more ? _tasks.length : 0) + refreshed.length >= total) {
          break;
        }
      }
      if (mounted && filter == _filter) {
        setState(() {
          if (!more) _tasks.clear();
          _tasks.addAll(refreshed);
          _total = total;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('回炉工作台'),
      actions: [
        IconButton(
          tooltip: '刷新回炉任务',
          onPressed: _loading ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: currentBackendMode != BackendMode.local
        ? const Center(child: Text('草案式回炉仅本地模式可用'))
        : Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  spacing: 6,
                  children: [
                    for (final pair in const [
                      ('open', '未结束'),
                      ('draft', '待确认'),
                      ('needs_input', '需补充'),
                      ('deferred', '已暂缓'),
                      ('excluded', '已排除'),
                      ('', '全部'),
                    ])
                      ChoiceChip(
                        label: Text(pair.$2),
                        selected: _filter == pair.$1,
                        onSelected: _loading
                            ? null
                            : (_) {
                                setState(() => _filter = pair.$1);
                                _load();
                              },
                      ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '生成的是草案，不会自动替换原卡。暂缓 / 排除只作用于当前卡片。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              if (_loading) const LinearProgressIndicator(),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_error!),
                ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.all(12),
                    itemCount: _tasks.length + 1,
                    itemBuilder: (context, index) {
                      if (index == _tasks.length) {
                        return Padding(
                          padding: const EdgeInsets.all(20),
                          child: Center(
                            child: _tasks.length < _total
                                ? OutlinedButton(
                                    onPressed: _loading
                                        ? null
                                        : () => _load(more: true),
                                    child: Text(
                                      '加载更多（已显示 ${_tasks.length} / $_total）',
                                    ),
                                  )
                                : Text(_tasks.isEmpty ? '这个分类暂无任务' : '已显示全部任务'),
                          ),
                        );
                      }
                      final task = _tasks[index];
                      final original = task['original'] as Map;
                      return Card(
                        child: ListTile(
                          key: ValueKey('rework-task-${task['id']}'),
                          title: Text(
                            original['front']?.toString() ?? '原卡',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            '${reworkActionLabel(task['action'] as String)} · ${reworkStatusLabel(task['status'] as String)}\n${(task['issues'] as List).map((e) => (e as Map)['label']).join('、')}',
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) =>
                                    _TaskDetail(id: task['id'] as int),
                              ),
                            );
                            if (mounted) _load();
                          },
                        ),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
  );
}

Future<void> _editor(
  BuildContext context, {
  required String title,
  required Widget Function(BuildContext, StateSetter) content,
  required Future<dynamic> Function() save,
  Future<void> Function()? reloadVersion,
  String Function()? copyText,
  String button = '保存',
}) async {
  var saving = false, conflict = false;
  String? error;
  final scroll = ScrollController();
  void showFeedback(
    BuildContext ctx,
    StateSetter set,
    String message, {
    bool versionConflict = false,
  }) {
    if (!ctx.mounted) return;
    set(() {
      error = message;
      conflict = versionConflict;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (ctx.mounted && scroll.hasClients) scroll.jumpTo(0);
    });
  }

  try {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => PopScope(
          canPop: !saving,
          child: FractionallySizedBox(
            heightFactor: .92,
            child: Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.viewInsetsOf(ctx).bottom,
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      controller: scroll,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (error != null)
                            Card(
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxHeight: 100,
                                      ),
                                      child: SingleChildScrollView(
                                        child: Text(
                                          error!,
                                          style: TextStyle(
                                            color: Theme.of(
                                              ctx,
                                            ).colorScheme.error,
                                          ),
                                        ),
                                      ),
                                    ),
                                    Wrap(
                                      spacing: 8,
                                      children: [
                                        if (conflict && reloadVersion != null)
                                          TextButton(
                                            onPressed: saving
                                                ? null
                                                : () async {
                                                    final yes = await showDialog<bool>(
                                                      context: ctx,
                                                      builder: (dialog) => AlertDialog(
                                                        title: const Text(
                                                          '保留输入并刷新版本？',
                                                        ),
                                                        content: const Text(
                                                          '你的输入不会被清空。刷新后请重新核对证据，再决定是否保存；保存方案可能作废后台新生成的草案，不会直接应用到原卡。',
                                                        ),
                                                        actions: [
                                                          TextButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                  dialog,
                                                                  false,
                                                                ),
                                                            child: const Text(
                                                              '返回',
                                                            ),
                                                          ),
                                                          FilledButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                  dialog,
                                                                  true,
                                                                ),
                                                            child: const Text(
                                                              '保留输入并刷新',
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                    );
                                                    if (yes != true ||
                                                        !ctx.mounted) {
                                                      return;
                                                    }
                                                    set(() => saving = true);
                                                    try {
                                                      await reloadVersion();
                                                      if (ctx.mounted) {
                                                        showFeedback(
                                                          ctx,
                                                          set,
                                                          '已刷新任务版本并保留输入，请核对后再保存。',
                                                        );
                                                      }
                                                    } catch (e) {
                                                      if (ctx.mounted) {
                                                        showFeedback(
                                                          ctx,
                                                          set,
                                                          '$e',
                                                        );
                                                      }
                                                    } finally {
                                                      if (ctx.mounted) {
                                                        set(
                                                          () => saving = false,
                                                        );
                                                      }
                                                    }
                                                  },
                                            child: const Text('保留输入并刷新版本'),
                                          ),
                                        if (copyText != null)
                                          TextButton(
                                            onPressed: saving
                                                ? null
                                                : () async {
                                                    await Clipboard.setData(
                                                      ClipboardData(
                                                        text: copyText(),
                                                      ),
                                                    );
                                                    if (ctx.mounted) {
                                                      TopToast.show(
                                                        ctx,
                                                        '当前编辑已复制',
                                                      );
                                                    }
                                                  },
                                            child: const Text('复制当前编辑'),
                                          ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          content(ctx, set),
                        ],
                      ),
                    ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          TextButton(
                            onPressed: saving ? null : () => Navigator.pop(ctx),
                            child: const Text('取消'),
                          ),
                          const Spacer(),
                          FilledButton(
                            onPressed: saving
                                ? null
                                : () async {
                                    set(() {
                                      saving = true;
                                      error = null;
                                      conflict = false;
                                    });
                                    try {
                                      await save();
                                      if (ctx.mounted) Navigator.pop(ctx);
                                    } catch (e) {
                                      final stale =
                                          e is ApiException &&
                                          e.statusCode == 409;
                                      if (ctx.mounted) {
                                        showFeedback(
                                          ctx,
                                          set,
                                          '$e${stale && reloadVersion == null ? '\n请关闭此确认框，刷新任务后重新核对。' : ''}',
                                          versionConflict: stale,
                                        );
                                      }
                                    } finally {
                                      if (ctx.mounted) {
                                        set(() => saving = false);
                                      }
                                    }
                                  },
                            child: Text(saving ? '保存中…' : button),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  } finally {
    scroll.dispose();
  }
}

class _TaskDetail extends StatefulWidget {
  const _TaskDetail({required this.id});
  final int id;
  @override
  State<_TaskDetail> createState() => _TaskDetailState();
}

class _TaskDetailState extends State<_TaskDetail> {
  Map<String, dynamic>? _task;
  String? _error;
  bool _loading = false, _busy = false;
  Timer? _poll;
  @override
  void initState() {
    super.initState();
    _load();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted &&
          !_busy &&
          ModalRoute.of(context)?.isCurrent == true &&
          ['queued', 'generating'].contains(_task?['status'])) {
        _load();
      }
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final task = await ApiClient.instance.fetchReworkTask(widget.id);
      if (mounted) {
        setState(() {
          _task = task;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Map<String, Object?> _plan(Map task) => {
    'revision': task['revision'],
    'action': task['action'],
    'instructions': task['instructions'],
    'targetCount': task['targetCount'],
    'selectedIds': task['selectedIds'],
  };
  Future<void> _operate(String operation, Map<String, Object?> payload) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ApiClient.instance.reworkOperation(widget.id, operation, payload);
      await _load();
    } catch (e) {
      if (mounted) TopToast.show(context, '操作未完成：$e', type: TopToastType.error);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, dynamic>> _editableVersion({
    String? action,
    int? count,
  }) async {
    final current = await ApiClient.instance.fetchReworkTask(widget.id);
    if (![
      'queued',
      'generating',
      'needs_input',
      'draft',
    ].contains(current['status'])) {
      throw StateError('任务已经结束，不能覆盖；可复制当前编辑后关闭面板。');
    }
    if (action != null && current['action'] != action) {
      throw StateError('处理动作已经改变，请复制当前编辑后关闭，并重新检查方案。');
    }
    if (count != null && current['targetCount'] != count) {
      throw StateError('拆分数量已经改变，请复制当前编辑后重新打开草案。');
    }
    return current;
  }

  Future<void> _editPlan() async {
    var task = _task!;
    var action = task['action'] as String;
    var count = task['targetCount'] as int;
    final note = TextEditingController(text: task['instructions'] as String);
    try {
      await _editor(
        context,
        title: '修改修复方案',
        reloadVersion: () async {
          task = await _editableVersion();
        },
        copyText: () => '${reworkActionLabel(action)}\n${note.text}',
        content: (ctx, set) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('保存会作废正在生成或待确认的结果；原卡不会因此改变。'),
            DropdownButtonFormField<String>(
              initialValue: action,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '处理动作'),
              items: [
                for (final a in reworkActions)
                  DropdownMenuItem(value: a, child: Text(reworkActionLabel(a))),
              ],
              onChanged: (v) => set(() => action = v!),
            ),
            if (action == 'split')
              DropdownButtonFormField<int>(
                initialValue: count,
                decoration: const InputDecoration(labelText: '子卡数量'),
                items: [
                  for (var n = 2; n <= 5; n++)
                    DropdownMenuItem(value: n, child: Text('$n 张')),
                ],
                onChanged: (v) => set(() => count = v!),
              ),
            TextField(
              controller: note,
              minLines: 3,
              maxLines: 8,
              maxLength: 4000,
              decoration: const InputDecoration(labelText: '修复目标、限制或正确方向'),
            ),
            if (action == 'exclude') const Text('仅排除此卡，不设置全课程的禁出规则。'),
            if (action == 'defer') const Text('暂缓后须在工作台手动恢复，不会修改原记忆参数。'),
          ],
        ),
        save: () => ApiClient.instance.reworkOperation(widget.id, 'configure', {
          ..._plan(task),
          'action': action,
          'targetCount': count,
          'instructions': note.text.trim(),
        }),
      );
    } finally {
      note.dispose();
    }
    if (mounted) await _load();
  }

  Future<void> _editEvidence() async {
    var task = _task!;
    final editingAction = task['action'] as String;
    final choices = [
      for (final e in task['evidence'] as List)
        Map<String, dynamic>.from(e as Map),
    ];
    final selected = (task['selectedIds'] as List)
        .map((e) => e.toString())
        .toSet();
    await _editor(
      context,
      title: '选择固定证据',
      reloadVersion: () async {
        task = await _editableVersion(action: editingAction);
        for (final value in task['evidence'] as List) {
          final e = Map<String, dynamic>.from(value as Map);
          final at = choices.indexWhere(
            (old) => old['chunkId'] == e['chunkId'],
          );
          if (at < 0) {
            choices.add(e);
          } else {
            choices[at] = e;
          }
        }
      },
      copyText: () => selected.join('\n'),
      button: '保存证据（旧草案失效）',
      content: (ctx, set) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('固定证据优先进入模型；未固定的位置由检索补足。最多 12 条，只允许该科课件 / 教材正文。'),
          OutlinedButton.icon(
            onPressed: () async {
              final picked = await Navigator.of(ctx).push<Map<String, dynamic>>(
                MaterialPageRoute(
                  builder: (_) => CorpusLibraryPage(
                    subjectId: task['subjectId'] as String,
                    selectEvidence: true,
                  ),
                ),
              );
              if (picked == null || !ctx.mounted) return;
              if (selected.length >= 12) {
                TopToast.show(ctx, '最多固定 12 条证据');
                return;
              }
              set(() {
                final id = picked['chunkId'].toString();
                if (!choices.any((e) => e['chunkId'] == id)) {
                  choices.add(picked);
                }
                selected.add(id);
              });
            },
            icon: const Icon(Icons.library_books_outlined),
            label: const Text('从语料库添加原文'),
          ),
          for (final evidence in choices)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(reworkAnchor(evidence)),
              subtitle: Text(
                evidence['text']?.toString() ?? '',
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              value: selected.contains(evidence['chunkId']),
              onChanged: (v) => set(() {
                if (v == true) {
                  if (selected.length < 12) {
                    selected.add(evidence['chunkId'].toString());
                  }
                } else {
                  selected.remove(evidence['chunkId']);
                }
              }),
            ),
          if (choices.isEmpty) const Text('还没有证据。可以添加原文，或让第一次生成自动检索。'),
        ],
      ),
      save: () => ApiClient.instance.reworkOperation(widget.id, 'configure', {
        ..._plan(task),
        'selectedIds': selected.toList(),
      }),
    );
    if (mounted) await _load();
  }

  Future<void> _generate() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      var task = _task!;
      if (task['status'] != 'queued') {
        await ApiClient.instance.reworkOperation(
          widget.id,
          'configure',
          _plan(task),
        );
        task = await ApiClient.instance.fetchReworkTask(widget.id);
      }
      await ApiClient.instance.reworkOperation(widget.id, 'generate', {
        'revision': task['revision'],
      });
      await _load();
    } catch (e) {
      if (mounted) TopToast.show(context, '未开始生成：$e', type: TopToastType.error);
      await _load();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editDraft() async {
    var task = _task!;
    final action = task['action'] as String;
    final original = task['original'] as Map;
    final current = task['draft'] as Map?;
    final raw = current?['cards'] as List? ?? [];
    final count = action == 'split' ? task['targetCount'] as int : 1;
    final fronts = [
      for (var i = 0; i < count; i++)
        TextEditingController(
          text: i < raw.length
              ? (raw[i] as Map)['front'] as String
              : action == 'rewrite'
              ? original['front']?.toString() ?? ''
              : '',
        ),
    ];
    final backs = [
      for (var i = 0; i < count; i++)
        TextEditingController(
          text: i < raw.length
              ? (raw[i] as Map)['back'] as String
              : action == 'rewrite'
              ? original['back']?.toString() ?? ''
              : '',
        ),
    ];
    final citations = [
      for (var i = 0; i < count; i++)
        i < raw.length
            ? ((raw[i] as Map)['evidenceChunkIds'] as List)
                  .cast<String>()
                  .toSet()
            : <String>{},
    ];
    final issues = (task['issues'] as List).cast<Map>();
    final checked = <String>{};
    var evidence = (task['evidence'] as List).cast<Map>();
    try {
      await _editor(
        context,
        title: '人工修订草案',
        reloadVersion: () async {
          task = await _editableVersion(
            action: action,
            count: action == 'split' ? count : null,
          );
          evidence = (task['evidence'] as List).cast<Map>();
          checked.clear(); // 新版本须重新确认理由，不能沿用旧证据上的勾选。
          final ids = evidence.map((e) => e['chunkId'].toString()).toSet();
          for (final selected in citations) {
            selected.removeWhere((id) => !ids.contains(id));
          }
        },
        copyText: () => [
          for (var i = 0; i < count; i++)
            '草案 ${i + 1}\n${fronts[i].text}\n${backs[i].text}\n引用：${citations[i].join('、')}',
        ].join('\n\n'),
        content: (ctx, set) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('这仍然只保存草案，不修改正式卡片。每张卡必须选择支撑原文。'),
            for (var i = 0; i < count; i++)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('草案 ${i + 1}'),
                      TextField(
                        controller: fronts[i],
                        minLines: 2,
                        maxLines: 5,
                        decoration: const InputDecoration(labelText: '题干'),
                      ),
                      TextField(
                        controller: backs[i],
                        minLines: 3,
                        maxLines: 8,
                        decoration: const InputDecoration(labelText: '答案'),
                      ),
                      Wrap(
                        spacing: 4,
                        children: [
                          for (final e in evidence)
                            FilterChip(
                              label: Text(reworkAnchor(e)),
                              selected: citations[i].contains(e['chunkId']),
                              onSelected: (v) => set(() {
                                if (v) {
                                  citations[i].add(e['chunkId'].toString());
                                } else {
                                  citations[i].remove(e['chunkId']);
                                }
                              }),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            const Text('逐项确认问题是否已处理：'),
            for (final issue in issues)
              CheckboxListTile(
                title: Text(issue['label'].toString()),
                value: checked.contains(issue['id']),
                onChanged: (v) => set(() {
                  if (v == true) {
                    checked.add(issue['id'].toString());
                  } else {
                    checked.remove(issue['id']);
                  }
                }),
              ),
          ],
        ),
        save: () => ApiClient.instance.reworkOperation(widget.id, 'draft', {
          'revision': task['revision'],
          'draft': {
            'action': action,
            'cards': [
              for (var i = 0; i < count; i++)
                {
                  'front': fronts[i].text.trim(),
                  'back': backs[i].text.trim(),
                  'evidenceChunkIds': citations[i].toList(),
                },
            ],
            'issueResults': [
              for (final issue in issues)
                {
                  'id': issue['id'],
                  'resolved': checked.contains(issue['id']),
                  'explanation': checked.contains(issue['id'])
                      ? '用户已核对并修订'
                      : '用户仍未确认此问题',
                },
            ],
            'summary': '用户手工修订的草案',
          },
        }),
      );
    } finally {
      for (final c in [...fronts, ...backs]) {
        c.dispose();
      }
    }
    if (mounted) await _load();
  }

  Future<void> _apply() async {
    final task = _task!;
    final action = task['action'] as String;
    final issues = (task['issues'] as List).cast<Map>();
    final checked = <String>{};
    var reset = issues.any((i) => i['label'].toString().contains('答案有误'));
    await _editor(
      context,
      title: action == 'defer'
          ? '确认暂缓'
          : action == 'exclude'
          ? '确认排除此卡'
          : '确认应用修复',
      button: '确认应用',
      content: (ctx, set) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            action == 'split'
                ? '旧卡将归档，历史不删除；新子卡独立从新卡开始复习。'
                : action == 'defer'
                ? '这张卡退出复习，之后在工作台手动恢复；原记忆状态保留。'
                : action == 'exclude'
                ? '仅归档当前卡片，不删原文、不设置课程级禁出规则。'
                : '草案将替换当前卡片内容并进入复习。',
          ),
          if (action == 'rewrite')
            CheckboxListTile(
              title: const Text('重置这张卡的记忆状态'),
              subtitle: const Text('答案实质改变时推荐重学；原复习日志始终保留。原卡未审核时将按新卡开始。'),
              value: reset,
              onChanged: (v) => set(() => reset = v ?? false),
            ),
          const Text('请逐项核对：'),
          for (final issue in issues)
            CheckboxListTile(
              title: Text(issue['label'].toString()),
              value: checked.contains(issue['id']),
              onChanged: (v) => set(() {
                if (v == true) {
                  checked.add(issue['id'].toString());
                } else {
                  checked.remove(issue['id']);
                }
              }),
            ),
        ],
      ),
      save: () async {
        if (checked.length != issues.length) throw StateError('请逐项确认所有问题已得到处理');
        await ApiClient.instance.reworkOperation(widget.id, 'apply', {
          'revision': task['revision'],
          'resetMemory': reset,
          'confirmedIssues': checked.toList(),
        });
      },
    );
    if (mounted) await _load();
  }

  Future<void> _cancel() async {
    final task = _task!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复原卡并结束此任务？'),
        content: const Text(
          '原卡恢复到登记前的待审核 / 在学状态；记忆参数不变。正在生成的旧结果会作废，已发出的请求可能仍需等待结束。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('返回'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认恢复'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await _operate('cancel', {'revision': task['revision']});
    }
  }

  @override
  Widget build(BuildContext context) {
    final task = _task;
    return Scaffold(
      appBar: AppBar(
        title: const Text('回炉详情'),
        actions: [
          IconButton(
            tooltip: '刷新任务',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: task == null
          ? Center(
              child: _error == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        TextButton(onPressed: _load, child: const Text('重试')),
                      ],
                    ),
            )
          : _body(task),
    );
  }

  Widget _body(Map<String, dynamic> task) {
    final original = task['original'] as Map;
    final draft = task['draft'] as Map?;
    final cards = draft?['cards'] as List? ?? [];
    final action = task['action'] as String;
    final status = task['status'] as String;
    final editable = [
      'queued',
      'generating',
      'needs_input',
      'draft',
    ].contains(status);
    final ai = ['rewrite', 'split'].contains(action);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_loading || _busy) const LinearProgressIndicator(),
        Text(
          '${reworkActionLabel(action)} · ${reworkStatusLabel(status)}',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        Text(
          '阶段：${reworkStageLabel(task['stage'] as String)} · 版本 ${task['revision']} · 已尝试 ${task['attempts']} 次',
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if ((task['error']?.toString() ?? '').isNotEmpty)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(task['error'].toString()),
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            if (editable)
              OutlinedButton(
                onPressed: _busy ? null : _editPlan,
                child: const Text('编辑方案'),
              ),
            if (editable && ai)
              OutlinedButton(
                onPressed: _busy ? null : _editEvidence,
                child: const Text('选择证据'),
              ),
            if (editable && ai && status != 'generating')
              FilledButton(
                onPressed: _busy ? null : _generate,
                child: Text(status == 'queued' ? '生成草案' : '重新生成'),
              ),
            if (editable && ai && (task['evidence'] as List).isNotEmpty)
              OutlinedButton(
                onPressed: _busy ? null : _editDraft,
                child: const Text('人工修订草案'),
              ),
            if ((editable && !ai) || status == 'draft')
              FilledButton(
                onPressed: _busy ? null : _apply,
                child: Text(
                  ai
                      ? '检查并应用'
                      : action == 'defer'
                      ? '确认暂缓'
                      : '确认排除',
                ),
              ),
            if (editable || ['deferred', 'excluded'].contains(status))
              TextButton(
                onPressed: _busy ? null : _cancel,
                child: Text(
                  ['deferred', 'excluded'].contains(status)
                      ? '恢复原卡'
                      : '撤销任务并恢复原卡',
                ),
              ),
          ],
        ),
        const SizedBox(height: 16),
        const Text('问题与处理目标', style: TextStyle(fontWeight: FontWeight.w700)),
        for (final issue in task['issues'] as List)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text((issue as Map)['label'].toString()),
            subtitle: Text(_issueResult(draft, issue['id'])),
          ),
        if ((task['instructions'] as String).isNotEmpty)
          SelectableText(task['instructions'] as String),
        const SizedBox(height: 16),
        Card(
          child: ExpansionTile(
            initiallyExpanded: true,
            title: const Text('原卡快照（不会被草案覆盖）'),
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(
                      original['front']?.toString() ?? '',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    SelectableText(original['back']?.toString() ?? ''),
                    const SizedBox(height: 8),
                    Text('出处：${original['anchor']?.toString() ?? ''}'),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        const Text('实际采用的证据', style: TextStyle(fontWeight: FontWeight.w700)),
        if ((task['evidence'] as List).isEmpty)
          const Text('尚无证据；生成时可自动检索，也可以手动指定。'),
        for (final ev in task['evidence'] as List)
          Card(
            child: ExpansionTile(
              title: Text(reworkAnchor(ev as Map)),
              subtitle: Text(
                corpusTypeLabelForRework(ev['sourceType']?.toString() ?? '') +
                    ((task['selectedIds'] as List).contains(ev['chunkId'])
                        ? ' · 用户固定'
                        : ''),
              ),
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(ev['text']?.toString() ?? ''),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        const Text('修复前后对比', style: TextStyle(fontWeight: FontWeight.w700)),
        if (cards.isEmpty)
          Text(ai ? '尚无有效草案。失败不会回写原卡。' : '此动作不生成替代卡，确认后直接改变该卡是否参与复习。'),
        for (var i = 0; i < cards.length; i++)
          _draftCard(cards[i] as Map, original, i),
        if (status == 'applied') ...[
          const Text('修复已应用，原卡历史保留。'),
          if (action == 'rewrite')
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      BankDetailPage(cardId: task['cardId'] as String),
                ),
              ),
              child: const Text('查看修复后的卡片'),
            ),
          for (final entry in (task['children'] as List).asMap().entries)
            TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      BankDetailPage(cardId: entry.value.toString()),
                ),
              ),
              child: Text('查看子卡 ${entry.key + 1}'),
            ),
        ],
        const SizedBox(height: 16),
        ExpansionTile(
          title: const Text('处理记录与历史草案'),
          children: [
            for (final e in task['events'] as List)
              ListTile(
                title: Text((e as Map)['detail'].toString()),
                subtitle: Text('${e['created_at']} · v${e['revision']}'),
              ),
            for (final v in task['versions'] as List)
              ExpansionTile(
                title: Text('草案版本 ${(v as Map)['revision']}'),
                children: [
                  for (final c in (v['draft'] as Map)['cards'] as List)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        '${(c as Map)['front']}\n${c['back']}',
                      ),
                    ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  Widget _draftCard(Map card, Map original, int i) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '草案 ${i + 1}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          Text(
            card['front'] == original['front'] ? '题干未改' : '题干已修改',
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
          SelectableText(card['front'].toString()),
          const SizedBox(height: 8),
          Text(
            card['back'] == original['back'] ? '答案未改' : '答案已修改',
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
          SelectableText(card['back'].toString()),
          const SizedBox(height: 8),
          SelectableText('出处：${card['anchor']}'),
        ],
      ),
    ),
  );
  String _issueResult(Map? draft, Object? id) {
    for (final row in draft?['issueResults'] as List? ?? []) {
      if ((row as Map)['id'] == id) {
        return (row['resolved'] == true ? '草案声明已处理：' : '仍未解决：') +
            (row['explanation']?.toString() ?? '');
      }
    }
    return '尚未形成修复结果';
  }
}

String corpusTypeLabelForRework(String type) => type == 'textbook'
    ? '教材'
    : type == 'ppt'
    ? '课件'
    : type;
