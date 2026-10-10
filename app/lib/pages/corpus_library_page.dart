import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
import '../services/api/api_client.dart';
import '../services/local/local_backend.dart';
import '../services/local/corpus_library.dart';
import '../services/local/corpus/exam_topics.dart';
import '../widgets/top_toast.dart';
import 'corpus_tools_panel.dart';

/// 统一资料工作台：全库默认不筛选，科目入口只预设筛选，随时可切回全部。
class CorpusLibraryPage extends StatefulWidget {
  const CorpusLibraryPage({
    super.key,
    this.subjectId,
    this.initialTab = 0,
    this.selectEvidence = false,
  });
  final bool selectEvidence;
  final String? subjectId;
  final int initialTab;
  @override
  State<CorpusLibraryPage> createState() => _CorpusLibraryPageState();
}

class _CorpusLibraryPageState extends State<CorpusLibraryPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final ValueNotifier<int> _revision = ValueNotifier(0);
  final TextEditingController _search = TextEditingController();
  StreamSubscription<Map<String, Object?>>? _buildSub;
  CorpusInventory? _inventory;
  String? _subject;
  String _type = '', _status = 'all', _query = '';
  String? _error;
  bool _loading = false, _deleting = false, _building = false;
  bool _reloadQueued = false;
  bool get _local => currentBackendMode == BackendMode.local;

  @override
  void initState() {
    super.initState();
    _subject = widget.subjectId;
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1),
    );
    _tabs.addListener(() {
      if (_local && _tabs.index == 0 && _inventory == null && !_loading) {
        _load();
      }
    });
    if (_local) {
      if (_tabs.index == 0) _load();
      _building = LocalBackend.instance.corpusBuildRunning;
      _buildSub = LocalBackend.instance.corpusBuildState.listen((frame) {
        final running = frame['running'] == true;
        final finished = _building && !running;
        if (mounted) setState(() => _building = running);
        if (finished) _load();
      });
    }
  }

  @override
  void dispose() {
    _tabs.dispose();
    _revision.dispose();
    _search.dispose();
    _buildSub?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_local || !mounted) return;
    if (_loading) {
      _reloadQueued = true;
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 名称获取失败不能使旧科目、真题专题或未归属资料消失。
      try {
        await ApiClient.instance.fetchSubjects();
      } catch (_) {}
      final data = await ApiClient.instance.fetchCorpusLibrary();
      if (mounted) setState(() => _inventory = data);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_reloadQueued) {
          _reloadQueued = false;
          unawaited(_load());
        }
      }
    }
  }

  String _subjectName(String id) {
    if (id == '@outline') return '公共考试大纲';
    if (id.isEmpty) return '未归属资料';
    return examTopicByCode(id)?.name ?? ApiClient.instance.subjectNameOf(id);
  }

  void _clearFilters() {
    setState(() {
      _subject = widget.selectEvidence ? widget.subjectId : null;
      _type = '';
      _status = 'all';
      _query = '';
      _search.clear();
    });
  }

  List<CorpusDocument> get _filtered {
    final q = _query.trim().toLowerCase();
    return (_inventory?.documents ?? []).where((d) {
      if (widget.selectEvidence &&
          (d.subjectId != widget.subjectId ||
              d.chunks == 0 ||
              !d.types.any((t) => t == 'ppt' || t == 'textbook'))) {
        return false;
      }
      if (_subject != null &&
          d.subjectId != _subject &&
          !d.relatedSubjects.contains(_subject)) {
        return false;
      }
      if (_type.isNotEmpty && !d.types.contains(_type)) return false;
      if (_status == 'pending' && !d.needsBuild) return false;
      if (_status == 'noOriginal' && d.hasOriginal) return false;
      if (_status == 'attention' &&
          d.notes.isEmpty &&
          !d.files.any((f) => f.isLink || !f.supported)) {
        return false;
      }
      return q.isEmpty ||
          [
            d.title,
            _subjectName(d.subjectId),
            d.sourceHint,
            ...d.files.map((f) => f.relativePath),
          ].join(' ').toLowerCase().contains(q);
    }).toList();
  }

  Future<bool> _delete(CorpusDocument doc) async {
    if (_deleting ||
        _inventory?.complete != true ||
        _inventory!.pendingDeletion) {
      return false;
    }
    final originalCount = doc.files.where((f) => f.exists).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除整份资料？'),
        content: SingleChildScrollView(
          child: Text(
            '「${doc.title}」\n\n'
            '将移除 ${doc.chunks} 个正文分块、${doc.outlineEntries} 条大纲条目，以及 $originalCount 个本机原件；相关词面和向量索引也会清理。\n\n'
            '${doc.kind == 'outline' ? '注意：大纲按级别整体删除，该级别全部条目与所列原件都会移除。\n\n' : ''}'
            '已经生成的卡片、复习记录和学习进度保留，但来源可能无法继续查看。\n\n此操作不可撤销；建议先完成备份。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除资料'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    setState(() => _deleting = true);
    try {
      await ApiClient.instance.deleteCorpusDocument(doc);
      if (!mounted) return true;
      TopToast.show(context, '资料已删除；已有卡片和复习记录保留', type: TopToastType.success);
      _revision.value++;
      await _load();
      return true;
    } catch (e) {
      if (mounted) {
        TopToast.show(context, '删除未完成：$e', type: TopToastType.error);
        await _load();
      }
      return false;
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _recover() async {
    if (_deleting) return;
    setState(() => _deleting = true);
    try {
      await ApiClient.instance.recoverCorpusDeletion();
      if (mounted) {
        _revision.value++;
        await _load();
      }
    } catch (e) {
      if (mounted) {
        TopToast.show(context, '清理仍未完成：$e', type: TopToastType.error);
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Future<void> _open(CorpusDocument doc) async {
    final picked = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => _CorpusDocumentPage(
          document: doc,
          canDelete:
              !widget.selectEvidence &&
              _inventory!.complete &&
              !_inventory!.pendingDeletion,
          selectEvidence: widget.selectEvidence,
          onDelete: () => _delete(doc),
          onTools: () {
            _tabs.animateTo(1);
          },
        ),
      ),
    );
    if (widget.selectEvidence && picked != null && mounted) {
      Navigator.of(context).pop(picked);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.selectEvidence ? '选择引用原文' : '语料库'),
      actions: [
        if (_local)
          IconButton(
            tooltip: '刷新全部资料',
            onPressed: _loading || _deleting ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
      ],
      bottom: widget.selectEvidence
          ? null
          : TabBar(
              controller: _tabs,
              tabs: const [
                Tab(text: '资料', icon: Icon(Icons.folder_copy_outlined)),
                Tab(text: '导入与建库', icon: Icon(Icons.add_to_drive_outlined)),
              ],
            ),
    ),
    body: widget.selectEvidence
        ? _libraryBody()
        : TabBarView(
            controller: _tabs,
            children: [
              _local
                  ? _libraryBody()
                  : const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('完整资料管理仅本地模式可用。当前模式仍可使用「导入与建库」中的兼容工具。'),
                      ),
                    ),
              SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: CorpusToolsPanel(
                  subjectId: _subject,
                  onChanged: _load,
                  revision: _revision,
                ),
              ),
            ],
          ),
  );
  Widget _libraryBody() {
    final inventory = _inventory;
    if (inventory == null) {
      if (_loading) return const Center(child: CircularProgressIndicator());
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error ?? '尚未读取资料'),
              const SizedBox(height: 12),
              FilledButton(onPressed: _load, child: const Text('重试')),
            ],
          ),
        ),
      );
    }
    final docs = _filtered;
    final groups = <String, List<CorpusDocument>>{};
    for (final d in docs) {
      groups.putIfAbsent(d.subjectId, () => []).add(d);
    }
    final subjects = groups.keys.toList()
      ..sort((a, b) => _subjectName(a).compareTo(_subjectName(b)));
    final rows = <Object>[
      for (final s in subjects) ...[s, ...groups[s]!],
    ];
    final subjectOptions = <String>{
      ?_subject,
      for (final d in inventory.documents) ...[
        d.subjectId,
        ...d.relatedSubjects,
      ],
    }.toList()..sort((a, b) => _subjectName(a).compareTo(_subjectName(b)));
    final types = <String>{
      'ppt',
      'textbook',
      'exam',
      'outline',
      'other',
      for (final d in inventory.documents) ...d.types,
    };
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    elevation: 0,
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            inventory.complete ? '资料库总览' : '资料库总览 · 待核查',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '${inventory.documents.length} 份资料 / 集合 · ${inventory.totalChunks} 个正文分块 · ${inventory.totalOutlineEntries} 条大纲',
                          ),
                          const SizedBox(height: 6),
                          const Text(
                            '包括语料包、待建库原件、无本机原件及未归属资料。',
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_loading) const LinearProgressIndicator(),
                  if (_building)
                    const ListTile(
                      leading: Icon(Icons.sync),
                      title: Text('建库正在后台进行'),
                      subtitle: Text('清单可能变化，完成后将自动刷新；建库期间不能删除资料。'),
                    ),
                  if (_error != null)
                    ListTile(
                      leading: const Icon(Icons.error_outline),
                      title: const Text('刷新失败，当前显示上次清单'),
                      subtitle: Text(_error!),
                      trailing: IconButton(
                        onPressed: _load,
                        icon: const Icon(Icons.refresh),
                      ),
                    ),
                  if (!inventory.complete || inventory.warnings.isNotEmpty)
                    Card(
                      child: ExpansionTile(
                        initiallyExpanded: !inventory.complete,
                        leading: const Icon(Icons.warning_amber_rounded),
                        title: Text(
                          inventory.complete ? '资料诊断提示' : '清单读取不完整，删除已禁用',
                        ),
                        children: [
                          for (final warning in inventory.warnings)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                              child: SelectableText(warning),
                            ),
                        ],
                      ),
                    ),
                  if (inventory.pendingDeletion)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.pending_actions),
                        title: const Text('上次删除仍需清理'),
                        subtitle: const Text('为防止资料重新出现，完成清理前不能导入或建库。'),
                        trailing: TextButton(
                          onPressed: _deleting ? null : _recover,
                          child: const Text('重试清理'),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      labelText: '搜索资料名称、科目或原件路径',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                              icon: const Icon(Icons.close),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('subject-$_subject-${subjectOptions.length}'),
                    initialValue: _subject,
                    hint: const Text('全部科目与公共资料'),
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '科目 / 专题'),
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('全部科目与公共资料'),
                      ),
                      for (final s in subjectOptions)
                        DropdownMenuItem(
                          value: s,
                          child: Text(_subjectName(s)),
                        ),
                    ],
                    onChanged: widget.selectEvidence
                        ? null
                        : (v) => setState(() => _subject = v),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      ChoiceChip(
                        label: const Text('全部分类'),
                        selected: _type.isEmpty,
                        onSelected: (_) => setState(() => _type = ''),
                      ),
                      for (final t in types)
                        ChoiceChip(
                          label: Text(corpusTypeLabel(t)),
                          selected: _type == t,
                          onSelected: (_) => setState(() => _type = t),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    initialValue: _status,
                    key: ValueKey('status-$_status'),
                    decoration: const InputDecoration(labelText: '处理状态'),
                    items: const [
                      DropdownMenuItem(value: 'all', child: Text('全部状态')),
                      DropdownMenuItem(
                        value: 'pending',
                        child: Text('待建库 / 待更新'),
                      ),
                      DropdownMenuItem(
                        value: 'noOriginal',
                        child: Text('无本机原件'),
                      ),
                      DropdownMenuItem(
                        value: 'attention',
                        child: Text('有诊断提示'),
                      ),
                    ],
                    onChanged: (v) => setState(() => _status = v ?? 'all'),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '显示 ${docs.length} / ${inventory.documents.length} 份资料',
                        ),
                      ),
                      TextButton(
                        onPressed: _clearFilters,
                        child: const Text('清除筛选'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (docs.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  children: [
                    const Icon(Icons.folder_open_outlined, size: 48),
                    const SizedBox(height: 12),
                    Text(
                      inventory.documents.isEmpty ? '还没有导入资料' : '没有匹配当前筛选的资料',
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => _tabs.animateTo(1),
                      icon: const Icon(Icons.add),
                      label: const Text('导入资料'),
                    ),
                  ],
                ),
              ),
            ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            sliver: SliverList.builder(
              itemCount: rows.length,
              itemBuilder: (context, index) {
                final row = rows[index];
                if (row is String) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(2, 12, 2, 6),
                    child: Text(
                      '${_subjectName(row)} · ${groups[row]!.length} 份',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  );
                }
                final d = row as CorpusDocument;
                return Card(
                  child: ListTile(
                    key: ValueKey('corpus-document-${d.id}'),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    leading: Icon(
                      d.kind == 'outline'
                          ? Icons.account_tree_outlined
                          : d.hasOriginal
                          ? Icons.description_outlined
                          : Icons.inventory_2_outlined,
                    ),
                    title: Text(
                      d.title,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${d.types.map(corpusTypeLabel).join(' / ')} · ${d.entries} 条内容',
                          ),
                          const SizedBox(height: 3),
                          Text(d.status),
                          if (d.files.isNotEmpty)
                            Text(
                              '${d.files.length} 个原件 · ${d.files.first.relativePath}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(d),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CorpusDocumentPage extends StatefulWidget {
  const _CorpusDocumentPage({
    required this.document,
    required this.canDelete,
    required this.onDelete,
    required this.onTools,
    this.selectEvidence = false,
  });
  final bool selectEvidence;
  final CorpusDocument document;
  final bool canDelete;
  final Future<bool> Function() onDelete;
  final VoidCallback onTools;
  @override
  State<_CorpusDocumentPage> createState() => _CorpusDocumentPageState();
}

class _CorpusDocumentPageState extends State<_CorpusDocumentPage> {
  final TextEditingController _search = TextEditingController();
  final List<Map<String, dynamic>> _items = [];
  Timer? _debounce;
  int _total = 0, _generation = 0;
  bool _loading = false, _busy = false;
  bool _pendingReset = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) {
      if (reset) {
        _pendingReset = true;
        _generation++;
      }
      return;
    }
    final generation = reset ? ++_generation : _generation;
    final query = _search.text;
    setState(() {
      if (reset) {
        _items.clear();
        _total = 0;
      }
      _loading = true;
      _error = null;
    });
    try {
      final result = await ApiClient.instance.fetchCorpusContent(
        widget.document.id,
        offset: reset ? 0 : _items.length,
        query: query,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _items.addAll([
            for (final row in result['items'] as List)
              Map<String, dynamic>.from(row as Map),
          ]);
          _total = (result['total'] as num).toInt();
        });
      }
    } catch (e) {
      if (mounted && generation == _generation) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        if (_pendingReset) {
          _pendingReset = false;
          unawaited(_load(reset: true));
        }
      }
    }
  }

  void _queryChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 300),
      () => _load(reset: true),
    );
  }

  Future<void> _share(CorpusSourceFile source) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final dir = LocalBackend.instance.dataDir;
      if (dir == null) throw StateError('数据目录尚未初始化');
      final file = CorpusLibrary('$dir/corpus').sourceFile(source.relativePath);
      if (!file.existsSync()) throw StateError('原件已不在本机');
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], title: widget.document.title),
      );
    } catch (e) {
      if (mounted) {
        TopToast.show(context, '导出原件失败：$e', type: TopToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    setState(() => _busy = true);
    final done = await widget.onDelete();
    if (!mounted) return;
    if (done) {
      Navigator.of(context).pop();
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doc = widget.document;
    return Scaffold(
      appBar: AppBar(
        title: const Text('资料内容'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (!widget.selectEvidence)
            IconButton(
              tooltip: widget.canDelete ? '删除整份资料' : '清单不完整或清理未完成，不能删除',
              onPressed: _busy || !widget.canDelete ? null : _delete,
              icon: const Icon(Icons.delete_outline),
            ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length + 2,
        itemBuilder: (context, index) {
          if (index == 0) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  doc.title,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '${doc.types.map(corpusTypeLabel).join(' / ')} · ${doc.status}',
                ),
                Text(
                  '正文 ${doc.chunks} 块 · 大纲 ${doc.outlineEntries} 条；以下按原有页码 / 条目顺序完整分页显示。',
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    '这里展示已抽取的文字，并不代表原件全部信息。图片、扫描页或解析失败的内容，请结合原件核对。',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
                if (doc.kind == 'outline')
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 8),
                    child: Text('这是按考试级别入库的跨科大纲集合，不是可逐文件拆分的正文。'),
                  ),
                for (final note in doc.notes)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(note),
                  ),
                const SizedBox(height: 12),
                if (doc.files.isEmpty)
                  const ListTile(
                    leading: Icon(Icons.info_outline),
                    title: Text('没有本机原件'),
                    subtitle: Text('仍可阅读全部已入库内容；语料包通常只包含正文和索引。'),
                  ),
                for (final source in doc.files)
                  Card(
                    child: ListTile(
                      title: Text(source.relativePath),
                      subtitle: Text(
                        !source.exists
                            ? '原件缺失'
                            : source.isLink
                            ? '链接文件，不允许操作'
                            : '${(source.bytes / 1048576).toStringAsFixed(2)} MB · ${source.supported ? '原件可用' : '暂不支持建库的格式'}',
                      ),
                      trailing: IconButton(
                        tooltip: '导出 / 用其他应用打开原件',
                        onPressed: !source.exists || source.isLink || _busy
                            ? null
                            : () => _share(source),
                        icon: const Icon(Icons.ios_share),
                      ),
                    ),
                  ),
                if (doc.sourceHint.isNotEmpty && !doc.hasOriginal)
                  ExpansionTile(
                    title: const Text('来源登记'),
                    children: [SelectableText(doc.sourceHint)],
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: _search,
                  onChanged: _queryChanged,
                  decoration: InputDecoration(
                    labelText: '在这份资料的全部内容中查找',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _search.text.isEmpty
                        ? null
                        : IconButton(
                            onPressed: () {
                              _search.clear();
                              _queryChanged('');
                            },
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '已显示 ${_items.length} / $_total 条${_search.text.trim().isEmpty ? '' : '（内容筛选）'}',
                  key: const ValueKey('corpus-content-count'),
                ),
              ],
            );
          }
          if (index == _items.length + 1) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Column(
                children: [
                  if (_loading) const CircularProgressIndicator(),
                  if (_error != null) ...[
                    SelectableText(_error!),
                    TextButton(
                      onPressed: () => _load(reset: _items.isEmpty),
                      child: const Text('重试读取'),
                    ),
                  ],
                  if (!_loading && _error == null && _items.length < _total)
                    OutlinedButton(
                      onPressed: _load,
                      child: const Text('加载更多内容'),
                    ),
                  if (!_loading && _error == null && _items.isEmpty) ...[
                    Text(
                      _search.text.trim().isEmpty
                          ? '还没有可阅读的入库内容，请查看原件或进行建库。'
                          : '整份资料中没有匹配内容',
                    ),
                    TextButton(
                      onPressed: () {
                        widget.onTools();
                        Navigator.of(context).pop();
                      },
                      child: const Text('前往导入与建库'),
                    ),
                  ],
                  if (!_loading && _items.isNotEmpty && _items.length == _total)
                    const Text('已显示全部匹配内容'),
                ],
              ),
            );
          }
          final row = _items[index - 1];
          final start = row['pageStart'];
          final end = row['pageEnd'];
          final title = row['title']?.toString() ?? '';
          final text = row['text']?.toString() ?? '';
          return Card(
            margin: const EdgeInsets.only(top: 12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          start == null
                              ? '大纲条目 $index'
                              : '原件第 $start${end != null && end != start ? '—$end' : ''} 页',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      if (widget.selectEvidence &&
                          (row['type'] == 'ppt' || row['type'] == 'textbook'))
                        TextButton.icon(
                          icon: const Icon(Icons.add_link, size: 18),
                          label: const Text('引用此段'),
                          onPressed: () =>
                              Navigator.of(context).pop(<String, dynamic>{
                                'chunkId': row['id'].toString(),
                                'subjectId': doc.subjectId,
                                'deck': doc.title,
                                'title': title,
                                'text': text,
                                'sourceType': row['type'],
                                'pageRange': start == end
                                    ? '$start'
                                    : '$start-$end',
                              }),
                        ),
                      IconButton(
                        tooltip: '复制这一段',
                        onPressed: () async {
                          await Clipboard.setData(
                            ClipboardData(
                              text: title.isEmpty ? text : '$title\n$text',
                            ),
                          );
                          if (context.mounted) TopToast.show(context, '已复制这一段');
                        },
                        icon: const Icon(Icons.copy_outlined, size: 18),
                      ),
                    ],
                  ),
                  if (title.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: SelectableText(
                        title,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  if (row['subject'] != null) Text(row['subject'].toString()),
                  SelectableText(text, style: const TextStyle(height: 1.55)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
