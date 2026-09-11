// 综合设置页（M3）：统计页底部设置栏进入
// 模块：数据与同步（离线评分队列 / 手动同步 / 服务器状态）
//       · 自动化拆卡（强制开始拆卡 / 改卡，server 0.4.1+）
//       · 知识库（M5：状态+上传课件；App 内建库：待处理清单→开始建库→
//         进度→完成摘要，local 模式）· 关于
//       · 每日提醒 / 数据管理（导入 hengya.db 迁移 / 导入语料包 / 一键导出
//         分享） / AI 服务配置（含 instruct 前缀开关）已整体迁至「恒牙」
//         聚合页（about_page.dart，2026-09-11）
import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/api/api_client.dart';
import '../services/api/demo_backend.dart';
import '../services/local/local_backend.dart';
import '../services/local/corpus/exam_topics.dart' show examTopicByCode;
import '../widgets/top_toast.dart';
import 'about_page.dart';
import 'hengya_home_parts.dart';
import 'subject_picker.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 版本号动态来源（package_info）：读取构建时写入的 versionName，永不需手动同步
  late final Future<PackageInfo> _pkgInfo = PackageInfo.fromPlatform();

  int _pendingCount = 0;

  bool _syncing = false;
  bool _checking = false;
  bool _triggering = false; // 强制拆卡触发中（防重复点击）

  bool? _serverOk; // null = 未检测

  // ---------------- M5：知识库 ----------------
  CorpusStatus? _corpus;
  bool _corpusLoading = true;
  bool _corpusUnsupported = false;

  /// #3（2026-09-07）：语料变更信号（ValueNotifier 自增计数）。上传成功 /
  /// 「刷新语料状态」时自增 → 建库面板监听并重拉——上传后立即变蓝，无需
  /// 退出重进（用户实锤旧版须退出重进面板重建才变蓝）。
  final ValueNotifier<int> _corpusRev = ValueNotifier(0);

  @override
  void initState() {
    super.initState();
    _loadAll();
    _loadCorpus();
  }

  @override
  void dispose() {
    _corpusRev.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    if (!mounted) return;
    setState(() => _pendingCount = ApiClient.instance.pendingAnswerCount);
  }

  /// 手动同步：先补传离线评分队列，再检查服务器
  Future<void> _syncNow() async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      final applied = await ApiClient.instance.flushPendingAnswers();
      final serverOk = await _pingServer();
      if (!mounted) return;
      setState(() {
        _pendingCount = ApiClient.instance.pendingAnswerCount;
        _serverOk = serverOk;
        _syncing = false;
      });
      if (mounted) {
        // 2026-09-06：轻提示统一顶部气泡（快速淡化 + 底色随机氛围），替换灰色 SnackBar
        TopToast.show(
          context,
          serverOk
              ? '同步完成${applied > 0 ? '，已补传 $applied 条离线评分' : ''}'
              : (applied > 0 ? '已补传 $applied 条，但服务器暂不可达' : '服务器暂不可达，请检查网络'),
          type: serverOk ? TopToastType.success : TopToastType.error,
        );
      }
    } catch (_) {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// 服务器连接检查：GET /health（豁免 token，仅探活）
  Future<bool> _pingServer() async {
    if (DemoBackend.enabled) return true; // 演示模式无真实服务器
    try {
      final json = await ApiClient.instance.fetchHealth();
      return json['status'] == 'ok';
    } on ApiException {
      return false;
    }
  }

  /// 服务器状态行单独刷新
  Future<void> _recheckServer() async {
    if (_checking) return;
    setState(() => _checking = true);
    final ok = await _pingServer();
    if (!mounted) return;
    setState(() {
      _serverOk = ok;
      _checking = false;
    });
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
  }

  /// 知识库上传允许的课件后缀（小写；白名单口径与服务端 corpus upload 一致）
  static const List<String> _kUploadExts = ['.pptx', '.pdf', '.docx'];

  /// 上传课件三步流：选 .pptx/.pdf/.docx → 选科目与类型（local 弹层多一块
  /// 「类型」单选：课件（默认）/ 教材——教材落教材树 incoming/<短码>-textbook/
  /// → 建库写 toc sidecar → 罗盘自动生成；课件维持 incoming/<短码>/，
  /// 既有行为零变化。同一次上传只属一种类型）→ 上传（不定态进度）。
  Future<void> _pickAndUpload() async {
    // 1. 选文件（官方 file_selector；XTypeGroup 尽力过滤三种课件格式）
    XFile? file;
    try {
      file = await openFile(
        acceptedTypeGroups: const [
          // extensions 与 mimeTypes 并给（组内并集）：部分 Android ROM 只认其一
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
    } catch (_) {
      file = null; // 部分平台选择器不可用 → 视为取消
    }
    if (!mounted || file == null) return; // 用户取消
    // 客户端兜底校验（部分 ROM 的选择器不按 MIME 过滤，仍可选到其他类型）
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
    // 2. 科目 + 类型选择（缓存+刷新+内联新建）。local 模式弹层多一块
    //    「类型」单选（课件（默认）/ 教材）；remote/demo 无教材链路
    //    （服务器不识别 source 参数、无本机罗盘/建库），保守不展示单选，
    //    口径同下方建库面板的 local 专属门。
    final isLocal = currentBackendMode == BackendMode.local;
    final target = await showUploadTargetPickerSheet(
      context,
      title: isLocal ? '选择科目与类型' : '课件归属科目',
      pickUploadType: isLocal,
    );
    if (!mounted || target == null) return; // 取消
    // 3. 读字节 → 不定态进度弹窗 → 上传
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final sizeLabel = _fmtSize(bytes.length);
    showDialog<void>(
      context: context,
      barrierDismissible: false, // 提示保持前台，防误触取消
      builder: (_) => PopScope(
        canPop: false, // 上传中防返回键误关
        child: _UploadProgressDialog(filename: filename, sizeLabel: sizeLabel),
      ),
    );
    try {
      final res = await ApiClient.instance.uploadCourseware(
        target.subject.id,
        filename,
        bytes,
        source: target.sourceType,
      );
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // 关进度弹窗
      await _loadCorpus();
      if (!mounted) return;
      // #3：语料变更信号 +1 → 建库面板重拉待处理清单（上传后「开始建库」
      // 立即变蓝，无需退出重进设置页）
      _corpusRev.value++;
      TopToast.show(
        context,
        '已接收 ${_fmtSize(res.received)} · 待处理队列 ${res.pending} 个文件',
        type: TopToastType.success,
        stayDuration: kToastStayImportant, // #5：上传完成属重要状态
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      TopToast.show(
        context,
        e.statusCode == 404
            ? '需服务器 0.3.0+，暂未部署'
            : '上传失败：${e.statusCode == 0 ? '网络不可达' : e.message}',
        type: TopToastType.error,
      );
    }
  }

  /// 字节数展示：KB / MB
  String _fmtSize(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';

  // ---------------- 强制开始拆卡 / 改卡（server 0.4.1+ / Phase 4 端上） ----------------

  /// 触发拆卡流水线尽快运行：先弹确认，确认后 POST /api/v1/pipeline/trigger，
  /// 结果一律 TopToast（成功绿 / 排队中蓝 / 失败红）。local 模式 = 端上流水线
  /// （Phase 4 真实现：后台跑六步总编排）；remote = 服务器流水线
  /// （404 → 需 0.4.1+ 提示）。
  Future<void> _confirmForceRun() async {
    final isLocal = currentBackendMode == BackendMode.local;
    final go = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('强制开始拆卡 / 改卡？'),
        content: Text(
          isLocal
              ? '端上流水线将在后台运行：拆收件箱关键词、重造回炉卡、推进学习罗盘。\n\n'
                    '需已在下方配置生卡 LLM；知识库语料未建时检索降级，'
                    '关键词按失败记录、收件箱保留待补跑。'
              : '让服务器立刻跑一轮拆卡流水线：处理收件箱关键词、重造回炉卡。\n\n'
                    '当前为影子模式：只生成草稿、不改线上卡，会消耗少量服务器 AI 额度。\n'
                    '离线或服务器低于 0.4.1 时会失败。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: const Text('立即触发'),
          ),
        ],
      ),
    );
    if (go != true || _triggering) return;
    setState(() => _triggering = true);
    try {
      final res = await ApiClient.instance.triggerPipeline();
      if (!mounted) return;
      if (res.triggered) {
        TopToast.show(
          context,
          isLocal ? '已触发，端上流水线后台运行中' : '已触发，服务器约 1 分钟内开跑',
          type: TopToastType.success,
          // #5：触发成功属重要状态（用户反馈 2200ms 偏快）
          stayDuration: kToastStayImportant,
        );
      } else {
        TopToast.show(context, res.note ?? '已有任务排队中', type: TopToastType.info);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      TopToast.show(
        context,
        e.statusCode == 404 ? '需服务器 0.4.1+，暂未部署' : '触发失败：${e.message}',
        type: TopToastType.error,
        stayDuration: const Duration(milliseconds: 1800),
      );
    } finally {
      if (mounted) setState(() => _triggering = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 2026-09-06 措辞刀：local 模式无服务器概念（离线评分队列/手动同步/
          // 服务器连接均不适用），整段隐藏——真机问题：远程残留文案误导用户
          if (currentBackendMode != BackendMode.local) ...[
            const SizedBox(height: 20),

            // ---------------- 数据与同步（remote/demo 服务器语义） ----------------
            _SectionHeader(title: '数据与同步'),
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              child: Column(
                children: [
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text(
                      '离线评分队列',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      _pendingCount > 0
                          ? '有 $_pendingCount 条评分待补传，联网后自动/手动同步'
                          : '队列为空，所有评分均已同步',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: _pendingCount > 0
                        ? Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(
                                0xFFE37318,
                              ).withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Text(
                              '待补传',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFFE37318),
                              ),
                            ),
                          )
                        : Icon(
                            Icons.check_circle,
                            size: 18,
                            color: const Color(0xFF2BA471),
                          ),
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text(
                      '手动同步',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      '立即补传离线评分并检查服务器',
                      style: TextStyle(fontSize: 12),
                    ),
                    trailing: _syncing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.sync_rounded),
                    onTap: _syncing ? null : _syncNow,
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text(
                      '服务器连接',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: _serverStatusText(),
                    trailing: _checking
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _serverOk == null
                                    ? Icons.help_outline
                                    : (_serverOk!
                                          ? Icons.cloud_done
                                          : Icons.cloud_off),
                                size: 18,
                                color: _serverOk == null
                                    ? scheme.outline
                                    : (_serverOk!
                                          ? const Color(0xFF2BA471)
                                          : const Color(0xFFD54941)),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '检查',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.primary,
                                ),
                              ),
                            ],
                          ),
                    onTap: _recheckServer,
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 20),
          _SectionHeader(title: '自动化拆卡'),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: const Text(
                '强制开始拆卡 / 改卡',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                currentBackendMode == BackendMode.local
                    ? '让本机立刻跑一轮流水线：拆收件箱关键词、重造回炉卡、推进学习罗盘'
                    : '让服务器立刻跑一轮流水线（当前影子模式只出草稿，消耗少量 AI 额度）',
                style: const TextStyle(fontSize: 12),
              ),
              trailing: _triggering
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_circle_outline),
              onTap: _triggering ? null : _confirmForceRun,
            ),
          ),

          const SizedBox(height: 20),
          _SectionHeader(title: '知识库'),
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
                    onTap: _pickAndUpload,
                  ),
                  // App 内建库（local 专属）：消灭「建库必须用电脑」——上传的
                  // 课件在本机后台 isolate 完成抽取入库，语料即时可检索。
                  // remote/demo 模式无此链路（服务器建库），不展示。
                  if (currentBackendMode == BackendMode.local) ...[
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _CorpusBuildPanel(
                      rev: _corpusRev,
                      onCompleted: _loadCorpus,
                    ),
                  ],
                ],
              ),
            ),

          // ---------------- 关于 ----------------
          _SectionHeader(title: '关于'),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text(
                    '恒牙',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    DemoBackend.enabled
                        ? '口腔医学复习系统 · 演示模式（无服务器依赖）'
                        : '口腔医学复习系统 · FSRS 间隔复习',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: FutureBuilder<PackageInfo>(
                    future: _pkgInfo,
                    builder: (context, info) => Text(
                      'v${info.data?.version ?? ''}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                  onTap: () => Navigator.of(
                    context,
                  ).push(MaterialPageRoute(builder: (_) => const AboutPage())),
                ),
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text(
                    '离线优先设计',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    '评分先进本地队列再补传；地铁弱网也能背完一整轮',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget? _serverStatusText() {
    final scheme = Theme.of(context).colorScheme;
    if (DemoBackend.enabled) {
      return Text(
        '演示模式 · 本地内存后端',
        style: TextStyle(fontSize: 12, color: scheme.outline),
      );
    }
    if (_serverOk == null) {
      return Text(
        '点击右侧「检查」测试连接',
        style: TextStyle(fontSize: 12, color: scheme.outline),
      );
    }
    return Text(
      _serverOk! ? '连接正常（${ApiClient.instance.baseUrl}）' : '无法连接，请检查网络或稍后重试',
      style: TextStyle(
        fontSize: 12,
        color: _serverOk! ? const Color(0xFF2BA471) : const Color(0xFFD54941),
      ),
    );
  }
}

/// 分组标题（小字 + 主色）
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// 本地时间格式化（无 intl 依赖）：yyyy-MM-dd HH:mm
String _fmtDateTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

/// ---------------- M5：上传进度弹窗（不定态） ----------------
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
        // ---- 重建全部向量（2026-09-11 强制重建；无待处理也可用——
        // 导入语料包后向量不符/检索无结果的修复入口，库内自嵌） ----
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _busyTrigger ? null : _confirmAndResetVectors,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(_busyTrigger ? '启动中…' : '重建全部向量'),
          ),
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
