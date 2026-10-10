// 唯一的资料导入/建库/诊断工具面板；设置与关于页只保留导航入口。
import 'dart:async';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../services/api/api_client.dart';
import '../services/local/local_backend.dart';
import '../services/local/corpus_package.dart';
import '../services/local/corpus/exam_topics.dart' show examTopicByCode;
import '../widgets/top_toast.dart';
import 'hengya_home_parts.dart';
import 'subject_picker.dart';

class CorpusToolsPanel extends StatefulWidget {
  const CorpusToolsPanel({
    super.key,
    this.subjectId,
    this.onChanged,
    this.revision,
    this.selectFile,
  });
  final String? subjectId;
  final VoidCallback? onChanged;
  final ValueListenable<int>? revision;
  final Future<XFile?> Function()? selectFile;
  @override
  State<CorpusToolsPanel> createState() => _CorpusToolsPanelState();
}

class _CorpusToolsPanelState extends State<CorpusToolsPanel> {
  CorpusStatus? _corpus;
  bool _corpusLoading = true, _corpusUnsupported = false;
  bool _pkgImporting = false;
  bool _uploading = false;
  String _pkgPhase = '';
  final ValueNotifier<int> _corpusRev = ValueNotifier(0);
  @override
  void initState() {
    super.initState();
    _loadCorpus();
    widget.revision?.addListener(_externalRefresh);
  }

  @override
  void didUpdateWidget(covariant CorpusToolsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      oldWidget.revision?.removeListener(_externalRefresh);
      widget.revision?.addListener(_externalRefresh);
    }
  }

  void _externalRefresh() {
    _loadCorpus();
    _corpusRev.value++;
  }

  Future<void> _afterBuild() async {
    await _loadCorpus();
    widget.onChanged?.call();
  }

  @override
  void dispose() {
    widget.revision?.removeListener(_externalRefresh);
    _corpusRev.dispose();
    super.dispose();
  }
  // ---------------- M5：知识库 ----------------

  /// 拉取语料库状态；旧服务器 404 → 降级提示「需 0.3.0+」
  Future<void> _loadCorpus() async {
    setState(() => _corpusLoading = true);
    try {
      final status = await ApiClient.instance.fetchCorpusStatus();
      if (!mounted) return;
      setState(() {
        _corpus = status;
        _corpusLoading = false;
        _corpusUnsupported = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _corpusLoading = false;
        _corpusUnsupported = e.statusCode == 404;
      });
    }
  }

  /// 「刷新语料状态」按钮（#3）：父级状态行 + 建库面板（经 [_corpusRev]
  /// 信号）一起重拉——面板无需退出重进即可见到新待处理清单。
  Future<void> _refreshCorpus() async {
    await _loadCorpus();
    if (!mounted) return;
    _corpusRev.value++;
    widget.onChanged?.call();
  }

  /// 知识库上传允许的课件后缀（小写；白名单口径与服务端 corpus upload 一致）
  static const List<String> _kUploadExts = ['.pptx', '.pdf', '.docx'];

  /// 上传课件三步流：选 .pptx/.pdf/.docx → 选科目与类型（local 弹层多一块
  /// 「类型」单选：课件（默认）/ 教材——教材落教材树 incoming/<短码>-textbook/
  /// → 建库写 toc sidecar → 罗盘自动生成；课件维持 incoming/<短码>/，
  /// 既有行为零变化。同一次上传只属一种类型）→ 上传（不定态进度）。
  Future<void> _pickAndUpload() async {
    if (_pkgImporting || _uploading) return;
    setState(() => _uploading = true);
    NavigatorState? navigator;
    DialogRoute<void>? modal;
    void closeProgress() {
      final nav = navigator;
      final route = modal;
      if (nav != null && nav.mounted && route != null && route.isActive) {
        nav.removeRoute(route);
      }
      modal = null;
    }

    try {
      final selector = widget.selectFile;
      final file = selector != null
          ? await selector()
          : await openFile(
              acceptedTypeGroups: const [
                XTypeGroup(
                  label: '课件文档',
                  extensions: ['pptx', 'pdf', 'docx'],
                  mimeTypes: [
                    'application/vnd.openxmlformats-officedocument.presentationml.presentation',
                    'application/pdf',
                    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                  ],
                ),
              ],
            );
      if (!mounted || file == null) return;
      final filename = file.name;
      final lower = filename.toLowerCase();
      if (!_kUploadExts.any((e) => lower.endsWith(e))) {
        TopToast.show(
          context,
          '暂只支持 .pptx / .pdf / .docx 课件',
          type: TopToastType.error,
        );
        return;
      }
      // 必须在 readAsBytes 前拦截超限文件，不能等整份文件读进内存后才拒绝。
      final length = await file.length();
      if (!mounted) return;
      if (length > ApiClient.maxCoursewareBytes) {
        TopToast.show(
          context,
          '文件超过 ${ApiClient.maxCoursewareBytes ~/ 1048576} MB 上限，请先拆分文件',
          type: TopToastType.error,
        );
        return;
      }
      final local = currentBackendMode == BackendMode.local;
      final target = await showUploadTargetPickerSheet(
        context,
        title: local ? '选择科目与类型' : '课件归属科目',
        pickUploadType: local,
        initialSubjectId: widget.subjectId,
      );
      if (!mounted || target == null) return;
      if (target.sourceType == 'outline' && !lower.endsWith('.docx')) {
        TopToast.show(
          context,
          '考试大纲仅支持 .docx，请重新选择文件',
          type: TopToastType.error,
        );
        return;
      }
      final bytes = await file.readAsBytes();
      if (!mounted) return;
      navigator = Navigator.of(context, rootNavigator: true);
      modal = DialogRoute<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: _UploadProgressDialog(
            filename: filename,
            sizeLabel: _fmtSize(bytes.length),
          ),
        ),
      );
      unawaited(navigator.push(modal!));
      final res = await ApiClient.instance.uploadCourseware(
        target.subject.id,
        filename,
        bytes,
        source: target.sourceType,
      );
      closeProgress();
      if (!mounted) return;
      await _loadCorpus();
      if (!mounted) return;
      _corpusRev.value++;
      widget.onChanged?.call();
      TopToast.show(
        context,
        '已接收 ${_fmtSize(res.received)} · 待处理队列 ${res.pending} 个文件',
        type: TopToastType.success,
        stayDuration: kToastStayImportant,
      );
    } on ApiException catch (e) {
      closeProgress();
      if (mounted) {
        TopToast.show(
          context,
          e.statusCode == 404 ? '需服务器 0.3.0+，暂未部署' : '上传失败：${e.message}',
          type: TopToastType.error,
        );
      }
    } catch (e) {
      closeProgress();
      if (mounted) {
        TopToast.show(context, '读取或上传失败：$e', type: TopToastType.error);
      }
    } finally {
      // 磁盘满、权限异常、读取失败、页面退出等路径都必须解除不可关闭的弹窗。
      closeProgress();
      if (mounted) setState(() => _uploading = false);
    }
  }

  /// 字节数展示：KB / MB
  String _fmtSize(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';

  // ---------------- #5 前半 语料库诊断（2026-09-13） ----------------

  String _diagType(String key) => switch (key) {
    'textbook' => '教材',
    'exam' => '真题',
    'ppt' => '课件',
    'outline' => '大纲',
    _ => key,
  };

  /// 诊断弹层：回答「语料包内容还在不在库里」（2026-09-11 剪除事故自查
  /// ——deck 来源分布 + 各类型块数 + 向量完整度，详见 _corpusDiagnostics）。
  Future<void> _showCorpusDiagnostics() async {
    Map<String, dynamic> d;
    try {
      d = await ApiClient.instance.fetchCorpusDiagnostics();
    } on ApiException catch (e) {
      if (!mounted) return;
      TopToast.show(context, '诊断失败：${e.message}', type: TopToastType.error);
      return;
    }
    if (!mounted) return;
    final hasCorpus = d['hasCorpus'] == true;
    final chunks = (d['chunks'] as num?)?.toInt() ?? 0;
    final vectors = (d['vectors'] as num?)?.toInt() ?? 0;
    final types =
        (d['chunkTypes'] as Map?)?.cast<String, dynamic>() ?? const {};
    final deckSources =
        (d['deckSources'] as Map?)?.cast<String, dynamic>() ?? const {};
    final deckChunks =
        (d['deckChunkCounts'] as Map?)?.cast<String, dynamic>() ?? const {};
    final embedModel = (d['embedModel'] as String?) ?? '';
    final lastIngest = (d['lastIngest'] as String?) ?? '';
    final lastBuild = (d['lastBuild'] as String?) ?? '';

    final rows = <Widget>[
      _diagRow('语料库', hasCorpus ? '已找到' : '未找到'),
      _diagRow(
        '语料块',
        '$chunks 块（向量 $vectors 条'
            '${vectors < chunks ? '，缺 ${chunks - vectors} 条向量' : '，完整'}）',
      ),
      if (types.isNotEmpty)
        _diagRow(
          '块来源',
          [
            for (final e in types.entries)
              '${_diagType(e.key)} ${(e.value as num?)?.toInt() ?? 0}',
          ].join(' · '),
        ),
      if (deckSources.isNotEmpty)
        _diagRow(
          'deck 来源',
          [
            if (deckSources['package'] != null)
              '语料包 ${deckSources['package']} 个 deck'
                  '（${deckChunks['package'] ?? 0} 块）',
            if (deckSources['tree'] != null)
              '手动课件 ${deckSources['tree']} 个 deck'
                  '（${deckChunks['tree'] ?? 0} 块）',
          ].where((s) => s.isNotEmpty).join(' · '),
        ),
      _diagRow('嵌入模型', embedModel.isEmpty ? '未配置' : embedModel),
      if (lastBuild.isNotEmpty) _diagRow('上次构建', _fmtTimeOrRaw(lastBuild)),
      if (lastIngest.isNotEmpty) _diagRow('上次入库', _fmtTimeOrRaw(lastIngest)),
    ];

    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('语料库诊断'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rows,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// meta 时间值可解析则本地化展示，否则原样截断（last_ingest 为 JSON 文本）
  String _fmtTimeOrRaw(String raw) {
    final t = DateTime.tryParse(raw);
    return t != null
        ? _fmtDateTime(t)
        : (raw.length > 60 ? '${raw.substring(0, 60)}…' : raw);
  }

  Widget _diagRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
      ],
    ),
  );

  Future<void> _importCorpusPackage() async {
    if (_pkgImporting || _uploading) return;
    final dir = LocalBackend.instance.dataDir;
    if (dir == null) return;
    XFile? picked;
    setState(() {
      _pkgImporting = true;
      _pkgPhase = '';
    });
    try {
      picked = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(label: '语料包', extensions: const ['zip']),
        ],
      );
      if (!mounted || picked == null) return;
      String? appVersion;
      try {
        appVersion = (await PackageInfo.fromPlatform()).version;
      } catch (_) {}
      if (!mounted) return;
      // 只读预览（后台 isolate；进度透传阶段文案，不动任何数据）
      final summary = await CorpusPackageManager.instance.validatePackageBg(
        picked.path,
        appVersion: appVersion,
        onProgress: (stage, msg) {
          if (mounted) setState(() => _pkgPhase = msg);
        },
      );
      if (!mounted) return;
      // 模型名对暗号预检（确认框内警示；导入结果会再核一次）
      var curModel = '';
      try {
        curModel = (await ApiClient.instance.fetchAiSettings()).embedding.model;
      } catch (_) {}
      if (!mounted) return;
      final modelWarn =
          curModel.isNotEmpty &&
          summary.modelName.isNotEmpty &&
          curModel.toLowerCase() != summary.modelName.toLowerCase();
      final sizeMb = (summary.packageBytes / 1048576).toStringAsFixed(1);
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认导入语料包？'),
          content: Text(
            '将导入 ${summary.subjects.length} 个科目的成品语料库'
            '（${summary.chunks} 块、${summary.tocFiles} 份章节目录、'
            '$sizeMb MB，向量模型 ${summary.modelName}）。\n\n'
            '本机卡片、复习记录与学习进度分毫不动；'
            '现有语料库将先备份到 corpus/bak-<时间>/ 再替换。'
            '${modelWarn ? '\n\n注意：本机向量模型「$curModel」与语料包不一致，导入后向量检索路不可用（词面检索不受影响）。' : ''}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (ok != true) {
        setState(() => _pkgPhase = '');
        return;
      }
      final result = await CorpusPackageManager.instance.importPackageBg(
        dir,
        picked.path,
        appVersion: appVersion,
        onBeforeSwap: () => LocalBackend.instance.reload(),
        onProgress: (stage, msg) {
          if (mounted) setState(() => _pkgPhase = msg);
        },
      );
      if (!mounted) return;
      await _refreshCorpus();
      if (!mounted) return;
      TopToast.show(
        context,
        '语料包导入成功：${result.summary.subjects.length} 科、'
        '${result.summary.chunks} 块'
        '${result.backupPath == null ? '' : '，旧库已备份'}'
        '${result.modelWarning == null ? '' : '；${result.modelWarning}'}',
        type: result.modelWarning == null
            ? TopToastType.success
            : TopToastType.info,
        stayDuration: kToastStayImportant,
      );
    } on CorpusPackageException catch (e) {
      if (mounted) TopToast.show(context, '导入语料包失败：${e.message}');
    } catch (e) {
      if (mounted) TopToast.show(context, '导入语料包失败：$e');
    } finally {
      // 终态（成功/失败）务必清理 file_selector 拷贝的 zip 缓存
      if (picked != null) CorpusPackageManager.disposeImportedZip(picked.path);
      if (mounted) {
        setState(() {
          _pkgImporting = false;
          _pkgPhase = '';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Text(
            '导入与建库',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ),
        const Text('原件导入后进入待处理队列；成品语料包会替换当前语料库并备份旧库。'),
        const SizedBox(height: 12),
        if (_corpusLoading)
          const Card(
            elevation: 0,
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          )
        else if (_corpusUnsupported || _corpus == null)
          NeedUpgradeCard(
            message: _corpusUnsupported ? '需服务器 0.3.0+，暂未部署' : '加载失败',
            onRetry: _loadCorpus,
          )
        else
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text(
                    '语料库',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '${_corpus!.totalChunks} 块语料 · ${_corpus!.storageMB} MB'
                    '${_corpus!.lastBuild == null ? ' · 尚未构建索引' : ' · 构建于 ${_fmtDateTime(_corpus!.lastBuild!)}'}',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: IconButton(
                    tooltip: '刷新语料状态',
                    icon: const Icon(Icons.refresh, size: 20),
                    onPressed: _refreshCorpus,
                  ),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text(
                    '语料库诊断',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'deck 来源分布 · 教材/真题/课件块数 · 向量完整度',
                    style: TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.monitor_heart_outlined),
                  onTap: _showCorpusDiagnostics,
                ),
                if (_corpus!.subjects.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.pie_chart_outline,
                          size: 14,
                          color: scheme.outline,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _corpus!.subjectLine(
                              ApiClient.instance.subjectNameOf,
                            ),
                            style: TextStyle(
                              fontSize: 12,
                              color: scheme.outline,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text(
                    '上传课件',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    '支持 .pptx / .pdf / .docx，上传后进入待处理队列（当前 ${_corpus!.pendingFiles} 个）',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.upload_file_outlined),
                  onTap: _pkgImporting || _uploading ? null : _pickAndUpload,
                ),
                // App 内建库（local 专属）：消灭「建库必须用电脑」——上传的
                // 课件在本机后台 isolate 完成抽取入库，语料即时可检索。
                // remote/demo 模式无此链路（服务器建库），不展示。
                if (currentBackendMode == BackendMode.local) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  _CorpusBuildPanel(rev: _corpusRev, onCompleted: _afterBuild),
                ],
              ],
            ),
          ),

        if (currentBackendMode == BackendMode.local)
          Card(
            child: ListTile(
              key: const ValueKey('corpus-import-package'),
              leading: const Icon(Icons.inventory_2_outlined),
              title: const Text('导入语料包（成品语料库）'),
              subtitle: Text(
                _pkgImporting ? _pkgPhase : '导入 zip，校验并确认后替换语料库；卡片与复习记录保留',
              ),
              trailing: _pkgImporting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.chevron_right),
              onTap: _pkgImporting || _uploading ? null : _importCorpusPackage,
            ),
          ),
      ],
    );
  }
}

String _fmtDateTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

class _UploadProgressDialog extends StatelessWidget {
  const _UploadProgressDialog({
    required this.filename,
    required this.sizeLabel,
  });

  final String filename;
  final String sizeLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('正在上传', style: TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const LinearProgressIndicator(minHeight: 4), // 不定态进度
          const SizedBox(height: 12),
          Text(
            '$filename（$sizeLabel）',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            '请保持 App 前台，不要切换应用或锁屏',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

/// ---------------- App 内建库面板（local 模式，知识库区内嵌） ----------------
/// 待处理清单（manifest 比对）→「开始建库」确认 → 后台 isolate 执行
/// （进度消费 [LocalBackend.corpusBuildState] 状态流：阶段 / 当前文件 /
/// 计数）→ 完成摘要（统计 + notes + 失败可重试）。运行中可离开本页
/// （job 在 App 级单例上继续跑，回来时按 GET 状态恢复视图）。
///
/// 数据流：初始 GET /corpus/build 全量 → 流帧更新运行态字段（帧不带
/// pending 清单——保留最近一次 GET 的值）；收尾（running 由真转假）时
/// 重拉全量 + [onCompleted] 通知父级刷新语料状态行（pending 清零、
/// chunks/lastBuild 更新）。
class _CorpusBuildPanel extends StatefulWidget {
  const _CorpusBuildPanel({required this.rev, required this.onCompleted});

  /// #3：语料变更信号（父级上传成功 / 「刷新语料状态」自增此计数）→
  /// 面板重拉待处理清单与状态——不退出重进即可变蓝。
  final ValueListenable<int> rev;

  /// 收尾后回调：父级重拉 /corpus/status（语料库状态行对齐新状态）
  final Future<void> Function() onCompleted;

  @override
  State<_CorpusBuildPanel> createState() => _CorpusBuildPanelState();
}

class _CorpusBuildPanelState extends State<_CorpusBuildPanel> {
  CorpusBuildStatus? _st; // 最近一帧（GET 全量 / 流帧状态子集）
  List<PendingCourseware> _pending = const []; // 清单（GET 全量刷新；流帧不带）
  bool _loading = true;
  bool _busyTrigger = false;
  bool _wasRunning = false;
  StreamSubscription<Map<String, Object?>>? _sub;

  @override
  void initState() {
    super.initState();
    _load();
    _sub = LocalBackend.instance.corpusBuildState.listen(_onFrame);
    widget.rev.addListener(_onRevChanged); // #3：上传成功/手动刷新 → 重拉
  }

  @override
  void dispose() {
    widget.rev.removeListener(_onRevChanged);
    unawaited(_sub?.cancel() ?? Future<void>.value());
    super.dispose();
  }

  /// #3：语料变更信号回调（与 initState 同路 [_load]，幂等）
  void _onRevChanged() {
    if (mounted) _load();
  }

  /// #4：待处理清单课程名展示——「课程名（短码）」替代裸短码（样例：
  /// ucbth7fd → 皮肤性病学（ucbth7fd））。课程名走 [subjectNameOf] 同一条
  /// 链（local 模式 = 按短码只读查 db subjects 表，经 /subjects 目录缓存）；
  /// 未拉到科目名时如实回退裸短码（避免「ucbth7fd（ucbth7fd）」复读）。
  /// 教材标注（本节点）：教材树首层目录名 = <短码>-textbook（上传「类型：
  /// 教材」落盘）——剥尾缀查课程名并加「·教材」角标（样例：
  /// ucbth7fd-textbook → 皮肤性病学（ucbth7fd·教材））；查不到名时如实
  /// 回退原目录名。节点④补：大纲树 dagang-outline → 「考试大纲
  /// （dagang·大纲）」；真题树 <短码>-exam（节点③遗留 cosmetic）→ 剥尾缀
  /// 查 12 专题中文名（kExamTopics，真题短码不进 subjects）加「·真题」
  /// 角标。
  static String _subjectLabel(String id) {
    final low = id.toLowerCase();
    if (low.endsWith('-textbook')) {
      final base = id.substring(0, id.length - '-textbook'.length);
      final name = ApiClient.instance.subjectNameOf(base);
      return name == base ? id : '$name（$base·教材）';
    }
    if (low.endsWith('-outline')) {
      return '考试大纲（dagang·大纲）';
    }
    if (low.endsWith('-exam')) {
      final base = id.substring(0, id.length - '-exam'.length);
      final t = examTopicByCode(base);
      return t == null ? id : '${t.name}（$base·真题）';
    }
    final name = ApiClient.instance.subjectNameOf(id);
    return name == id ? id : '$name（$id）';
  }

  Future<void> _load() async {
    // #4 前置：尽力预热科目目录（本面板 local 模式专属 = 按短码直读 db，
    // 微任务即答；有内存缓存则零开销）。失败静默——清单按裸短码回退展示。
    try {
      await ApiClient.instance.fetchSubjectCatalog();
    } catch (_) {}
    try {
      final st = await ApiClient.instance.fetchCorpusBuildStatus();
      if (!mounted) return;
      setState(() {
        _st = st;
        if (st.pendingFiles >= 0) _pending = st.pending;
        _wasRunning = st.running;
        _loading = false;
      });
    } on ApiException {
      // 静默降级：一次拉取失败不挤爆设置页（父级状态卡已有重试入口）
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onFrame(Map<String, Object?> frame) {
    if (!mounted) return;
    final st = CorpusBuildStatus.fromJson(frame);
    final finished = _wasRunning && !st.running;
    setState(() {
      _st = st;
      _wasRunning = st.running;
    });
    if (finished) unawaited(_refreshAfterRun(st));
  }

  /// 收尾后：重拉全量（pending 清零 + 最新结果）→ 气泡反馈 → 父级刷新。
  Future<void> _refreshAfterRun(CorpusBuildStatus st) async {
    await _load();
    if (!mounted) return;
    if (st.error != null) {
      TopToast.show(
        context,
        '建库失败：${st.error}',
        type: TopToastType.error,
        stayDuration: kToastStayImportant,
      ); // #5：失败详情需阅读时间
    } else if (st.cancelled) {
      TopToast.show(context, '建库已取消', type: TopToastType.info);
    } else if (st.result != null) {
      TopToast.show(
        context,
        '建库完成：${st.result!.chunks} 块语料已可检索',
        type: TopToastType.success,
        stayDuration: kToastStayImportant, // #5：建库完成属重要状态
      );
    }
    await widget.onCompleted();
  }

  Future<void> _confirmAndStart() async {
    final st = _st;
    if (st == null || _busyTrigger) return;
    final modeLabel = _modeLabel(st);
    // 失败/取消态 = 续跑：明确告知走断点续传，不是从头重建。
    final resuming = st.error != null || st.cancelled;
    // 教材标注（本节点）：待处理含教材树（<短码>-textbook）时确认框措辞
    // 「课件/教材」，纯课件树维持原文案（零变化）。节点④补：大纲树
    // （-outline）/真题树（-exam）同理并入措辞。
    final kinds = <String>['课件'];
    for (final p in _pending) {
      final s = p.subject.toLowerCase();
      if (s.endsWith('-textbook')) {
        if (!kinds.contains('教材')) kinds.add('教材');
      } else if (s.endsWith('-outline')) {
        if (!kinds.contains('大纲')) kinds.add('大纲');
      } else if (s.endsWith('-exam')) {
        if (!kinds.contains('真题')) kinds.add('真题');
      }
    }
    final kindLabel = kinds.length == 1 ? '待处理课件' : '待处理${kinds.join('/')}';
    final go = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: Text(resuming ? '继续建库？' : '开始建库？'),
        content: Text(
          resuming
              ? '将从上次中断处继续：已抽取/已嵌入的部分自动跳过'
                    '${_pending.isEmpty ? '，无需重新上传或从头重建' : ''}。\n\n'
                    '后台运行，期间可正常使用 App、可离开本页。'
                    '${st.modePreview == 'online' ? '\n在线嵌入会消耗少量 API 额度。' : ''}'
              : '将把 ${_pending.length} 个$kindLabel抽取入库（$modeLabel）。\n\n'
                    '后台运行，期间可正常使用 App、可离开本页。'
                    '${st.modePreview == 'online' ? '\n在线嵌入会消耗少量 API 额度。' : ''}'
                    '${st.replacesForeign ? '\n\n注意：当前语料库含非本机上传语料，本次构建后将以本机课件为准（树外语料将被移除）。' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: const Text('立即开始'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await _start();
  }

  /// 「重建全部向量」确认（2026-09-11 强制重建入口）：清空现有向量 +
  /// checkpoint 后按当前 embedding 配置全量重嵌。incoming 无待处理文件
  /// 也能重建（库内自嵌——从 chunks 表读全部行重算；导入语料包场景）。
  Future<void> _confirmAndResetVectors() async {
    final st = _st;
    if (st == null || _busyTrigger) return;
    final modeLabel = _modeLabel(st);
    final go = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('重建全部向量？'),
        content: Text(
          '将清空全部现有向量并全量重算（$modeLabel），'
          '同时重建全文检索（FTS）词面索引与检索镜像；'
          '语料包来源不受影响，语料文本与卡片数据不丢失。\n\n'
          '适用场景：导入语料包后向量模型不一致、检索不出结果、'
          '或向量疑似损坏。\n'
          '${st.modePreview == 'online' ? '\n在线嵌入会消耗少量 API 额度。' : ''}\n'
          '后台运行，期间可正常使用 App、可离开本页。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: const Text('重建'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await _startResetVectors();
  }

  /// 「补齐缺失向量」确认（2026-09-12 增量补齐入口）：不清空现有向量，
  /// 断点检查（chunk_state + vectors 双确认）自动跳过已嵌行，只对缺失/
  /// 过期部分补嵌。嵌入模型/维度与库内不一致时服务端拒绝（提示走全量
  /// 重建）。无待处理文件也可用（库内自嵌——导入语料包场景）。
  Future<void> _confirmAndBackfillVectors() async {
    final st = _st;
    if (st == null || _busyTrigger) return;
    final modeLabel = _modeLabel(st);
    final go = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('补齐缺失向量？'),
        content: Text(
          '将保留全部现有向量，只对缺失向量的语料块补嵌（$modeLabel）；'
          '已有向量不重算、不重复计费。\n\n'
          '适用场景：建库嵌入中断后补齐剩余部分（增量、省额度）。\n'
          '嵌入模型或维度与库内不一致时本次会被拒绝，'
          '请改用「重建全部向量」。\n'
          '${st.modePreview == 'online' ? '\n在线嵌入会消耗少量 API 额度。' : ''}\n'
          '后台运行，期间可正常使用 App、可离开本页。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: const Text('补齐'),
          ),
        ],
      ),
    );
    if (go != true) return;
    await _startBackfillVectors();
  }

  /// 触发增量补齐（backfillVectors=true）
  Future<void> _startBackfillVectors() async {
    if (_busyTrigger) return;
    setState(() => _busyTrigger = true);
    try {
      final res = await ApiClient.instance.triggerCorpusBuild(
        backfillVectors: true,
      );
      if (!mounted) return;
      if (res.triggered) {
        TopToast.show(
          context,
          res.note ?? '已在后台开始补齐缺失向量',
          type: TopToastType.success,
        );
      } else {
        TopToast.show(context, res.note ?? '建库已在进行中', type: TopToastType.info);
      }
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        TopToast.show(context, '触发失败：${e.message}', type: TopToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busyTrigger = false);
    }
  }

  /// 触发强制重建（resetVectors=true）
  Future<void> _startResetVectors() async {
    if (_busyTrigger) return;
    setState(() => _busyTrigger = true);
    try {
      final res = await ApiClient.instance.triggerCorpusBuild(
        resetVectors: true,
      );
      if (!mounted) return;
      if (res.triggered) {
        TopToast.show(
          context,
          res.note ?? '已在后台开始重建向量',
          type: TopToastType.success,
        );
      } else {
        TopToast.show(context, res.note ?? '建库已在进行中', type: TopToastType.info);
      }
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        TopToast.show(context, '触发失败：${e.message}', type: TopToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busyTrigger = false);
    }
  }

  Future<void> _start() async {
    if (_busyTrigger) return;
    setState(() => _busyTrigger = true);
    try {
      final res = await ApiClient.instance.triggerCorpusBuild();
      if (!mounted) return;
      if (res.triggered) {
        TopToast.show(
          context,
          res.note ?? '已在后台开始建库',
          type: TopToastType.success,
        );
      } else {
        // 单飞守卫交互：已在运行（如离开页面期间自行触发的运行）——不报错
        TopToast.show(context, res.note ?? '建库已在进行中', type: TopToastType.info);
      }
      await _load(); // 立即取运行态 → 渲染进度视图
    } on ApiException catch (e) {
      if (mounted) {
        TopToast.show(context, '触发失败：${e.message}', type: TopToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busyTrigger = false);
    }
  }

  /// 模式人读名（预览优先——确认对话框语境 = 下次运行会怎么跑）
  static String _modeLabel(CorpusBuildStatus st) {
    final m = st.modePreview.isNotEmpty ? st.modePreview : st.mode;
    return switch (m) {
      'online' => '在线嵌入',
      'drill' => '演练（确定性伪向量）',
      _ => '离线词面（未配置向量模型 Key）',
    };
  }

  static String _stageLabel(String stage) => switch (stage) {
    'start' => '准备中',
    'extract' => '抽取课件',
    'ingest' => '入库 / 嵌入',
    _ => '建库',
  };

  /// counts 友好行（最多一条；键 = 上游 ExtractAllStats/IngestStats 契约）
  static String? _countsLine(CorpusBuildStatus st) {
    final c = st.progress?.counts;
    if (c == null) return null;
    final stage = st.progress?.stage ?? '';
    int? n(String k) => (c[k] as num?)?.toInt();
    switch (stage) {
      case 'done':
        return 'chunks ${n('chunks') ?? 0} · 嵌入 ${n('embedded') ?? 0}'
            ' · ${((c['elapsed_s'] as num?)?.toDouble() ?? 0).toStringAsFixed(1)}s';
      case 'extract':
        return 'chunks ${n('chunks') ?? 0} · 新抽 ${n('changed') ?? 0}'
            ' · 跳过 ${n('unchanged') ?? 0} · 移除 ${n('removed') ?? 0}';
      case 'ingest':
        return 'rows ${n('rows') ?? 0} · 嵌入 ${n('embedded') ?? 0}'
            ' · 续传 ${n('resumed') ?? 0}';
      default:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: SizedBox(
          height: 16,
          width: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final st = _st;
    if (st == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(
          '建库状态加载失败，稍后自动重试',
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (st.running) _runningView(scheme, st) else _idleView(scheme, st),
        ],
      ),
    );
  }

  Widget _runningView(ColorScheme scheme, CorpusBuildStatus st) {
    final counts = _countsLine(st);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '正在建库 · ${_modeLabel(st)}',
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const LinearProgressIndicator(minHeight: 4),
        const SizedBox(height: 8),
        Text(
          st.progress == null
              ? '已启动，等待抽取…'
              : '${_stageLabel(st.progress!.stage)} · ${st.progress!.message}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: scheme.outline),
        ),
        if (counts != null) ...[
          const SizedBox(height: 4),
          Text(counts, style: TextStyle(fontSize: 12, color: scheme.outline)),
        ],
        const SizedBox(height: 6),
        Text(
          '后台运行中，可离开本页稍后回来查看',
          style: TextStyle(fontSize: 11, color: scheme.outline),
        ),
      ],
    );
  }

  Widget _idleView(ColorScheme scheme, CorpusBuildStatus st) {
    // 失败/取消态 = 续跑：放行「开始/继续建库」按钮（见按钮区注释）。
    final canResume = st.error != null || st.cancelled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- 待处理清单 ----
        Text(
          _pending.isEmpty
              ? '暂无待处理文件——上传课件后即可在本机构建语料'
              : '待处理 ${_pending.length} 个文件',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        if (_pending.isNotEmpty) ...[
          const SizedBox(height: 4),
          for (final p in _pending.take(5))
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                // #4：课程名（短码）替代裸短码（样例：ucbth7fd →
                // 皮肤性病学（ucbth7fd））
                '${_subjectLabel(p.subject)} / ${p.filename}'
                '（${(p.sizeBytes / 1024).round()} KB）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
          if (_pending.length > 5)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                '… 共 ${_pending.length} 个',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ),
        ],
        const SizedBox(height: 10),
        // ---- 最近一次运行摘要 ----
        if (st.error != null) ...[
          Text(
            '上次建库失败：${st.error}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: scheme.error),
          ),
          const SizedBox(height: 4),
          Text(
            '失败可重试（断点续传——已抽取部分不重做）',
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
          const SizedBox(height: 10),
        ] else if (st.cancelled) ...[
          Text(
            '上次建库已取消，可重新开始',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          const SizedBox(height: 10),
        ] else if (st.result != null) ...[
          _summaryView(scheme, st.result!),
          const SizedBox(height: 10),
        ],
        // ---- 开始/继续建库 ----
        // 正常态：待处理为空时禁用（构建语义 = 消费待处理队列）。
        // 失败/取消态：放行——chunk_state 断点数据仍在，点了自动续传
        // （forceFull=false + 两层断点：manifest 抽取增量 + 嵌入续跑），
        // 而不是从零重建。2026-09-11 修复：嵌入阶段中断后 pending 已空，
        // 原条件把唯一续传入口锁死（按钮灰掉），与「失败可重试（断点
        // 续传）」文案自相矛盾。
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: (_pending.isEmpty && !canResume) || _busyTrigger
                ? null
                : _confirmAndStart,
            icon: const Icon(Icons.construction_rounded, size: 18),
            label: Text(_busyTrigger ? '启动中…' : (canResume ? '继续建库' : '开始建库')),
          ),
        ),
        // ---- 补齐缺失向量 + 重建全部向量（同一行两个次级入口）----
        // 补齐（2026-09-12）：保留现有向量，断点检查只嵌缺失部分——
        // 无待处理也可用（库内自嵌）；导入语料包后向量缺行的首选修复，
        // 模型/维度不符时 ingestCorpus 拒绝并提示走重建。
        // 重建（2026-09-11 强制重建；无待处理也可用——导入语料包后向量
        // 不符/检索无结果的兜底入口，库内自嵌）。
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busyTrigger ? null : _confirmAndBackfillVectors,
                icon: const Icon(Icons.playlist_add_check_rounded, size: 18),
                label: Text(
                  _busyTrigger ? '启动中…' : '补齐缺失向量',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _busyTrigger ? null : _confirmAndResetVectors,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: Text(
                  _busyTrigger ? '启动中…' : '重建全部向量',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _summaryView(ColorScheme scheme, CorpusBuildSummary r) {
    final ex = r.extract;
    final ing = r.ingest;
    final errors = ex?['errors'] as List?;
    final lines = <String>[
      '抽取 ${r.chunks} 块 · 嵌入 ${r.embedded} · ${r.elapsedS.toStringAsFixed(1)}s',
      if (ex != null)
        '课件：新抽 ${ex['changed']} / 跳过 ${ex['unchanged']} / 移除 ${ex['removed']}'
            '${errors != null && errors.isNotEmpty ? ' / 失败 ${errors.length}' : ''}',
      if (ing == null)
        '未入库（0 chunks——检查待处理目录内容）'
      else
        '入库 ${ing['rows']} 行 · 模式 ${ing['mode']} · 续传 ${ing['resumed']}',
      for (final n in r.notes) n,
      '语料已可检索（拆卡流水线与知识库共用）',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '上次建库完成',
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        for (final l in lines)
          Text(l, style: TextStyle(fontSize: 12, color: scheme.outline)),
      ],
    );
  }
}
