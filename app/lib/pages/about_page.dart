// 恒牙（hengya）· 「关于」聚合页（v0.1.9）
// ============================================================================
// 设置页「恒牙」版本号栏点入。承载：
//   · 应用内更新（自设置页迁入：检查/下载/验签/安装 + 更新线路）
//   · 日志查看（AppLogPage 入口）
//   · 清除缓存（CacheCleaner 分类扫描 + 手动确认清理）
// 只读展示版本信息；源 URL 持久化走 UpdateService（update.source）。
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/local/app_log.dart';
import '../services/local/cache_cleaner.dart';
import '../services/update/update_service.dart';
import '../widgets/top_toast.dart';
import 'app_log_page.dart';

class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  /// 版本号（package_info，构建时写入；永不需手动同步）
  late final Future<PackageInfo> _pkgInfo = PackageInfo.fromPlatform();

  // ---------------- 应用内更新（自设置页迁入） ----------------
  final TextEditingController _updateSourceCtrl = TextEditingController();
  final FocusNode _updateSourceFocus = FocusNode();
  UpdateUiPhase _updatePhase = UpdateUiPhase.idle;
  UpdateManifest? _updateManifest;
  double? _updateProgress; // null = 不确定进度（服务器未给长度）
  int _updateReceived = 0;
  int? _updateTotal;
  String _updateError = ''; // failed/verifyFailed 相位的消息
  int _updateLastPct = -1; // 进度渲染节流（避免逐 chunk setState 刷屏）
  String _updateVersionName = ''; // 当前版本（Kotlin getPackageInfo）

  // ---------------- 存储（清除缓存） ----------------
  CacheScanResult? _cacheScan; // null = 未扫描/扫描中
  bool _cleaningCache = false;

  @override
  void initState() {
    super.initState();
    _loadUpdateState();
    _loadCurrentVersion();
    _scanCache();
  }

  @override
  void dispose() {
    _updateSourceCtrl.dispose();
    _updateSourceFocus.dispose();
    super.dispose();
  }

  // ---------------- 版本更新：首载 ----------------

  /// 回显持久化的源 URL + 当前版本（通道取不到不炸页，静默降级）
  Future<void> _loadUpdateState() async {
    try {
      final url = await UpdateService.instance.getSourceUrl();
      if (!mounted) return;
      // 未设置源（新装）→ 预填默认海外线路（GitHub raw），零配置可检查更新
      _updateSourceCtrl.text =
          (url == null || url.isEmpty) ? UpdateService.githubSourceUrl : url;
    } catch (_) {
      // db 未初始化（非 local 模式/极端时序）：输入框留空即可
    }
  }

  /// 当前版本（副标题/展示用）
  Future<void> _loadCurrentVersion() async {
    try {
      final info = await UpdateService.instance.currentPackageInfo();
      if (!mounted) return;
      setState(() => _updateVersionName = info.versionName);
    } catch (_) {
      // 版本取不到 → _updateVersionName 保持 ''（副标题显示「当前版本未知」）
    }
  }

  /// 源输入框回车时持久化（检查按钮也会先落库——双保险）
  Future<void> _persistUpdateSource() async {
    try {
      await UpdateService.instance.setSourceUrl(_updateSourceCtrl.text.trim());
    } catch (_) {}
  }

  /// 「海外线路」：一键填入 GitHub raw 默认源并落库（透明可改）
  Future<void> _applyOverseasLine() async {
    _updateSourceCtrl.text = UpdateService.githubSourceUrl;
    await _persistUpdateSource();
  }

  /// 「国内线路」：只清空 + 聚焦，绝不预设 URL
  /// （ECS 直链属私密信息，只在私渠道传播，绝不内置进 APK 二进制）
  void _applyDomesticLine() {
    _updateSourceCtrl.clear();
    _updateSourceFocus.requestFocus();
  }

  /// 检查更新：输入框值先落库 → 检查（检查中锁按钮）→ 状态机相位
  Future<void> _checkUpdate() async {
    if (_updatePhase == UpdateUiPhase.checking ||
        _updatePhase == UpdateUiPhase.downloading) {
      return; // 防重复点击
    }
    final src = _updateSourceCtrl.text.trim();
    if (src.isEmpty) {
      setState(() {
        _updatePhase = UpdateUiPhase.failed;
        _updateError = UpdateMessages.emptySource;
      });
      return;
    }
    try {
      await UpdateService.instance.setSourceUrl(src);
    } catch (_) {}
    setState(() {
      _updatePhase = UpdateUiPhase.checking;
      _updateError = '';
      _updateLastPct = -1;
    });
    try {
      final r = await UpdateService.instance.checkUpdate(sourceUrl: src);
      if (!mounted) return;
      setState(() {
        _updateManifest = r.manifest;
        if (_updateVersionName.isEmpty) {
          _updateVersionName = r.currentVersionName;
        }
        _updatePhase =
            r.available ? UpdateUiPhase.available : UpdateUiPhase.upToDate;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _updatePhase = UpdateUiPhase.failed;
        _updateError =
            e is UpdateException ? e.message : '检查更新失败：$e';
      });
    }
  }

  /// 下载并安装：下载（进度节流渲染）→ SHA-256 校验 → 唤起系统安装器
  Future<void> _downloadAndInstall() async {
    final m = _updateManifest;
    if (m == null || _updatePhase == UpdateUiPhase.downloading) return;
    final src = _updateSourceCtrl.text.trim();
    setState(() {
      _updatePhase = UpdateUiPhase.downloading;
      _updateProgress = null;
      _updateReceived = 0;
      _updateTotal = m.sizeBytes > 0 ? m.sizeBytes : null;
      _updateLastPct = -1;
    });
    try {
      final file = await UpdateService.instance.downloadAndVerify(
        m,
        sourceUrl: src,
        onProgress: (received, total) {
          if (!mounted) return;
          // 节流：百分比变了才 setState（80MB 级包 chunk 极多）
          if (total != null && total > 0) {
            final pct = received * 100 ~/ total;
            if (pct == _updateLastPct) return;
            _updateLastPct = pct;
          } else if ((received - _updateReceived) < 1048576) {
            return; // 未知大小：每 MB 刷一次
          }
          setState(() {
            _updateReceived = received;
            _updateTotal = total;
            _updateProgress = (total != null && total > 0)
                ? received / total
                : null;
          });
        },
      );
      if (!mounted) return;
      final code = await UpdateService.instance.installApk(file.path);
      if (!mounted) return;
      setState(() {
        if (code == null) {
          _updatePhase = UpdateUiPhase.installHandoff;
        } else if (code == 'not_authorized') {
          _updatePhase = UpdateUiPhase.needPermission;
        } else {
          _updatePhase = UpdateUiPhase.failed;
          _updateError = UpdateMessages.installFailed(code);
        }
      });
      if (code == null) {
        TopToast.show(
          context,
          UpdateMessages.installHandoff,
          type: TopToastType.success,
          stayDuration: kToastStayImportant,
        );
      }
    } on UpdateException catch (e) {
      if (!mounted) return;
      setState(() {
        _updatePhase = e.message == UpdateMessages.verifyFailed
            ? UpdateUiPhase.verifyFailed
            : UpdateUiPhase.failed;
        _updateError = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _updatePhase = UpdateUiPhase.failed;
        _updateError = '下载安装失败：$e';
      });
    }
  }

  /// 「去授权」：跳系统「安装未知应用」授权页（Kotlin 兜底跳应用详情）
  Future<void> _openInstallPermission() async {
    await UpdateService.instance.openInstallPermissionSettings();
  }

  // ---------------- 存储：缓存扫描与清理 ----------------

  Future<void> _scanCache() async {
    try {
      final result = await CacheCleaner.scan();
      if (!mounted) return;
      setState(() => _cacheScan = result);
    } catch (e) {
      AppLog.instance.log(AppLogLevel.warn, 'cache', '缓存扫描失败：$e');
      if (!mounted) return;
      setState(() => _cacheScan = CacheScanResult(
            bytes: {for (final c in CacheCategory.values) c: 0},
            count: {for (final c in CacheCategory.values) c: 0},
          ));
    }
  }

  String _mb(int bytes) =>
      bytes <= 0 ? '0 MB' : '${(bytes / 1048576).toStringAsFixed(1)} MB';

  /// 清除缓存确认框：四类占用明细 + bak 备份二次确认 → 清理 → 重扫
  Future<void> _confirmClearCache() async {
    final scan = _cacheScan;
    if (scan == null || _cleaningCache) return;
    if (scan.count.values.every((c) => c == 0)) {
      TopToast.show(context, '当前没有可清理的缓存', type: TopToastType.info);
      return;
    }
    var includeBackups = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('清除缓存？'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('将清理以下缓存（共 ${_mb(scan.totalBytes)}）：'),
                const SizedBox(height: 8),
                _cacheLine(ctx, CacheCategory.importTmp, scan, '导入中断残留'),
                _cacheLine(
                    ctx, CacheCategory.pkgValidate, scan, '校验临时文件'),
                _cacheLine(ctx, CacheCategory.zipCopies, scan, '已选语料包拷贝'),
                _cacheLine(ctx, CacheCategory.backups, scan, '旧语料库备份'),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: includeBackups,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text(
                    '同时删除 bak-* 旧库备份（不可恢复）',
                    style: TextStyle(fontSize: 13),
                  ),
                  onChanged: scan.count[CacheCategory.backups]! > 0
                      ? (v) => setDialogState(() => includeBackups = v ?? false)
                      : null,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清理'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() => _cleaningCache = true);
    try {
      final result = await CacheCleaner.clean(
        includeBackups: includeBackups,
        onProgress: (msg) {
          AppLog.instance.log(AppLogLevel.info, 'cache', msg);
        },
      );
      if (!mounted) return;
      TopToast.show(
        context,
        result.freedBytes > 0
            ? '已释放 ${_mb(result.freedBytes)} 缓存'
            : '没有可清理的缓存',
        type: TopToastType.success,
      );
    } catch (e) {
      AppLog.instance.log(AppLogLevel.error, 'cache', '缓存清理失败：$e');
      if (mounted) {
        TopToast.show(context, '缓存清理失败：$e', type: TopToastType.error);
      }
    } finally {
      if (mounted) {
        setState(() => _cleaningCache = false);
      }
      await _scanCache();
    }
  }

  Widget _cacheLine(
    BuildContext ctx,
    CacheCategory category,
    CacheScanResult scan,
    String label,
  ) {
    final bytes = scan.bytes[category] ?? 0;
    final count = scan.count[category] ?? 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(Icons.folder_outlined,
              size: 14, color: Theme.of(ctx).hintColor),
          const SizedBox(width: 6),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
          Text(
            count > 0 ? '$count 项 · ${_mb(bytes)}' : '—',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ],
      ),
    );
  }

  // ---------------- 版本更新状态区渲染（与设置页旧实现同款视觉） ----------------

  Widget _updateStatusRow(
    BuildContext ctx,
    IconData icon,
    String text,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
              child: Text(text, style: TextStyle(fontSize: 12, color: color))),
        ],
      ),
    );
  }

  String _updateDownloadingText() {
    final total = _updateTotal;
    if (total != null && total > 0) {
      final pct = (_updateReceived * 100 ~/ total).toString();
      return UpdateMessages.downloadingKnown
          .replaceFirst('{pct}', pct)
          .replaceFirst('{got}', (_updateReceived / 1048576).toStringAsFixed(1))
          .replaceFirst(
              '{total}', (total / 1048576).toStringAsFixed(1));
    }
    return UpdateMessages.downloadingUnknown(_updateReceived);
  }

  /// 状态机全相位渲染（idle 不占位）
  Widget _updateStatusView(BuildContext ctx) {
    final scheme = Theme.of(ctx).colorScheme;
    switch (_updatePhase) {
      case UpdateUiPhase.idle:
        return const SizedBox.shrink();
      case UpdateUiPhase.checking:
        return _updateStatusRow(
            ctx, Icons.sync_rounded, UpdateMessages.checking, scheme.outline);
      case UpdateUiPhase.upToDate:
        return _updateStatusRow(ctx, Icons.check_circle_outline_rounded,
            UpdateMessages.upToDate(_updateVersionName), scheme.primary);
      case UpdateUiPhase.available:
        final m = _updateManifest;
        if (m == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.new_releases_outlined,
                      size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${UpdateMessages.foundNew(m.versionName)} · '
                      '${UpdateMessages.sizeOf(m)}',
                      style: TextStyle(fontSize: 12, color: scheme.primary),
                    ),
                  ),
                ],
              ),
if (m.notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    m.notes,
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
                ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _downloadAndInstall,
                  child: const Text(UpdateMessages.downloadButton),
                ),
              ),
            ],
          ),
        );
      case UpdateUiPhase.downloading:
        final progress = _updateProgress;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.downloading_rounded,
                      size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text(_updateDownloadingText(),
                          style: const TextStyle(fontSize: 12))),
                ],
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: progress,
                minHeight: 3,
                borderRadius: BorderRadius.circular(2),
              ),
            ],
          ),
        );
      case UpdateUiPhase.verifyFailed:
        return _updateStatusRow(
            ctx, Icons.error_outline_rounded, _updateError, scheme.error);
      case UpdateUiPhase.needPermission:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _updateStatusRow(ctx, Icons.shield_outlined,
                  UpdateMessages.needPermission, scheme.error),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  onPressed: _openInstallPermission,
                  child: const Text(UpdateMessages.goGrantPermission),
                ),
              ),
            ],
          ),
        );
      case UpdateUiPhase.installHandoff:
        return _updateStatusRow(ctx, Icons.smartphone_rounded,
            UpdateMessages.installHandoff, scheme.primary);
      case UpdateUiPhase.failed:
        return _updateStatusRow(
            ctx,
            Icons.error_outline_rounded,
            _updateError.isEmpty ? UpdateMessages.unreachable : _updateError,
            scheme.error);
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          // ---- 头部 ----
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Column(
              children: [
                const SizedBox(height: 16),
                const Icon(Icons.health_and_safety_outlined,
                    size: 42, color: Colors.teal),
                const SizedBox(height: 8),
                const Text(
                  '恒牙',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  '口腔医学复习系统 · FSRS 间隔复习',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
                const SizedBox(height: 4),
                FutureBuilder<PackageInfo>(
                  future: _pkgInfo,
                  builder: (context, info) => Text(
                    'v${info.data?.version ?? ''}',
                    style: TextStyle(fontSize: 13, color: scheme.primary),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ---- 版本更新 ----
          const _AboutSectionHeader(title: '版本更新'),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text(
                    '检查新版本',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    _updateVersionName.isEmpty
                        ? '当前版本未知 · 默认海外线路，国内线路可手动填入'
                        : '当前版本 v$_updateVersionName · 默认海外线路，国内线路可手动填入',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: _updatePhase == UpdateUiPhase.checking ||
                          _updatePhase == UpdateUiPhase.downloading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: _checkUpdate,
                          child: const Text(UpdateMessages.checkButton),
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: TextField(
                    controller: _updateSourceCtrl,
                    focusNode: _updateSourceFocus,
                    onSubmitted: (_) => _persistUpdateSource(),
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      labelText: UpdateMessages.sourceLabel,
                      hintText: UpdateMessages.sourceHint,
                      isDense: true,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: _applyOverseasLine,
                        child: const Text(UpdateMessages.overseasLineButton),
                      ),
                      TextButton(
                        onPressed: _applyDomesticLine,
                        child: const Text(UpdateMessages.domesticLineButton),
                      ),
                    ],
                  ),
                ),
                _updateStatusView(context),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ---- 诊断 ----
          const _AboutSectionHeader(title: '诊断'),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Column(
              children: [
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  leading: Icon(Icons.article_outlined,
                      size: 20, color: scheme.primary),
                  title: const Text(
                    '日志',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    '崩溃/错误与关键操作记录，可实时查看与导出',
                    style: TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AppLogPage()),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

          // ---- 存储 ----
          const _AboutSectionHeader(title: '存储'),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(Icons.cleaning_services_outlined,
                  size: 20, color: scheme.primary),
              title: const Text(
                '清除缓存',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                _cleaningCache
                    ? '正在清理…'
                    : (_cacheScan == null
                        ? '正在统计缓存占用…'
                        : '导入中断残留、打包校验临时文件、旧库备份等'),
                style: const TextStyle(fontSize: 12),
              ),
              trailing: _cleaningCache
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      _cacheScan == null ? '…' : _mb(_cacheScan!.totalBytes),
                      style: const TextStyle(fontSize: 13),
                    ),
              onTap: _confirmClearCache,
            ),
          ),
        ],
      ),
    );
  }
}

/// 区块小标题（与设置页 _SectionHeader 同款视觉）。
class _AboutSectionHeader extends StatelessWidget {
  const _AboutSectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: scheme.primary,
        ),
      ),
    );
  }
}