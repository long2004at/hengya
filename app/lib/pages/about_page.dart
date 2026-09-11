// 恒牙（hengya）· 设置页「恒牙」聚合页（v0.1.9）
// ============================================================================
// 设置页「恒牙」版本号栏点入。承载（区块自设置页迁入的标注见各段注释）：
//   · 应用内更新（自设置页迁入：检查/下载/验签/安装 + 更新线路）
//   · 每日提醒（自设置页迁入：开关 + 提醒时间 + 通知权限状态）
//   · 数据管理（自设置页迁入，local 模式：导入数据库/完整备份、导入语料包、
//     一键导出并分享、立刻完整备份（含向量库）及分享最近完整备份）
//   · AI 服务配置（自设置页迁入：生卡 LLM / 备用生卡 LLM / 向量模型 /
//     重排序模型 + instruct 前缀开关（local 专属））
//   · 日志查看（AppLogPage 入口）
//   · 清除缓存（CacheCleaner 分类扫描 + 手动确认清理）
// 只读展示版本信息；源 URL 持久化走 UpdateService（update.source）。
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../services/api/api_client.dart';
import '../services/local/app_log.dart';
import '../services/local/cache_cleaner.dart';
import '../services/local/corpus_package.dart';
import '../services/local/data_manager.dart';
import '../services/local/full_backup.dart';
import '../services/local/local_backend.dart';
import '../services/notification/daily_reminder.dart';
import '../services/update/update_service.dart';
import '../widgets/top_toast.dart';
import 'app_log_page.dart';
import 'hengya_home_parts.dart';

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

  // ---------------- 每日提醒（自设置页迁入） ----------------
  bool _reminderEnabled = true;
  TimeOfDay _reminderTime = const TimeOfDay(
    hour: DailyReminder.defaultHour,
    minute: DailyReminder.defaultMinute,
  );
  bool _reminderLoaded = false;
  bool _notiGranted = true;

  // ---------------- 数据管理（Phase 2，local 模式；自设置页迁入） ----------------
  bool _importing = false;
  bool _exporting = false;
  bool _backingUp = false;
  String _backupPhase = '';
  String _importPhase = '';
  int _backupCount = -1; // 完整备份包数，不混淆原有自动主库备份
  DateTime? _lastBackupAt;
  String? _latestBackupPath;

  /// 导入会替换数据库，必须与导出/备份互斥（含文件选择和确认阶段）。
  bool get _dataBusy => _importing || _exporting || _backingUp || _pkgImporting;

  // ---------------- 语料包导入（批5 节点③，local 模式；自设置页迁入） ----------------
  bool _pkgImporting = false;
  String _pkgPhase = ''; // 后台校验/导入阶段文案（bg worker onProgress）

  // ---------------- M5：AI 服务配置（自设置页迁入） ----------------
  AiSettings? _ai;
  bool _aiLoading = true;
  bool _aiUnsupported = false; // 旧服务器（0.2.0）404 → 需 0.3.0+

  // ---------------- instruct 前缀开关（批5 节点③，local 模式） ----------------
  // settings embedding.instructQuery：'0' = 关（queryInstruct=''）；
  // 缺省/'1' = 开（null = 内置 kQueryInstruct）。默认开 = 保持旧行为。
  bool _instructOn = true;
  bool _instructLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadUpdateState();
    _loadCurrentVersion();
    _scanCache();
    _loadReminder();
    _loadAi();
    _loadInstructFlag();
    _loadBackups();
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
      _updateSourceCtrl.text = (url == null || url.isEmpty)
          ? UpdateService.githubSourceUrl
          : url;
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
        _updatePhase = r.available
            ? UpdateUiPhase.available
            : UpdateUiPhase.upToDate;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _updatePhase = UpdateUiPhase.failed;
        _updateError = e is UpdateException ? e.message : '检查更新失败：$e';
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
      setState(
        () => _cacheScan = CacheScanResult(
          bytes: {for (final c in CacheCategory.values) c: 0},
          count: {for (final c in CacheCategory.values) c: 0},
        ),
      );
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
                _cacheLine(ctx, CacheCategory.pkgValidate, scan, '校验临时文件'),
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
        result.freedBytes > 0 ? '已释放 ${_mb(result.freedBytes)} 缓存' : '没有可清理的缓存',
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
          Icon(Icons.folder_outlined, size: 14, color: Theme.of(ctx).hintColor),
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

  // ---------------- 每日提醒（自设置页迁入） ----------------

  /// 回显提醒开关/时间 + 通知权限（原设置页 _loadAll 的提醒部分）
  Future<void> _loadReminder() async {
    final reminder = await DailyReminder.instance.loadSettings();
    final granted = await _checkNotiPermission();
    if (!mounted) return;
    setState(() {
      _reminderEnabled = reminder.enabled;
      _reminderTime = TimeOfDay(hour: reminder.hour, minute: reminder.minute);
      _reminderLoaded = true;
      _notiGranted = granted;
    });
  }

  /// Android 13+ 用系统通知权限；iOS 请求后返回是否 granted；其他平台默认 true
  Future<bool> _checkNotiPermission() async {
    try {
      await DailyReminder.instance.ensureInit();
      final plugin = FlutterLocalNotificationsPlugin();
      if (Platform.isAndroid) {
        final android = plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final enabled = await android?.areNotificationsEnabled();
        return enabled ?? true;
      }
      if (Platform.isIOS) {
        final ios = plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        final granted = await ios?.requestPermissions(alert: true, sound: true);
        return granted ?? true;
      }
      return true;
    } catch (_) {
      return true; // 检测失败不阻塞页面
    }
  }

  /// 引导授权：Android 弹系统开关，iOS 弹权限对话框
  Future<void> _requestNotiPermission() async {
    try {
      if (Platform.isAndroid) {
        final plugin = FlutterLocalNotificationsPlugin();
        final android = plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        await android?.requestNotificationsPermission();
      } else if (Platform.isIOS) {
        final granted = await _checkNotiPermission(); // iOS 走 request
        if (mounted) setState(() => _notiGranted = granted);
        return;
      }
      final granted = await _checkNotiPermission();
      if (mounted) setState(() => _notiGranted = granted);
      if (granted && mounted) {
        TopToast.show(context, '通知权限已开启', type: TopToastType.success);
      }
    } catch (_) {
      // 部分 ROM 无系统权限页 → 提示手动去系统设置
      if (mounted) {
        TopToast.show(context, '请在系统设置中允许本应用通知');
      }
    }
  }

  Future<void> _applyReminder({bool? enabled, TimeOfDay? time}) async {
    final e = enabled ?? _reminderEnabled;
    final t = time ?? _reminderTime;
    await DailyReminder.instance.apply(
      enabled: e,
      hour: t.hour,
      minute: t.minute,
    );
    if (!mounted) return;
    setState(() {
      _reminderEnabled = e;
      _reminderTime = t;
    });
  }

  // ---------------- 数据管理（Phase 2，local 模式；自设置页迁入） ----------------

  /// 完整备份包的状态（与自动主库 .db 备份分开计数）。
  void _loadBackups() {
    final dir = LocalBackend.instance.dataDir;
    if (!mounted || dir == null || kBackendMode != BackendMode.local) return;
    try {
      final backups = FullBackupManager.instance.backupsOf(dir);
      final newest = backups.lastOrNull;
      final lastAt = newest?.lastModifiedSync();
      setState(() {
        _backupCount = backups.length;
        _lastBackupAt = lastAt;
        _latestBackupPath = newest?.path;
      });
    } catch (e) {
      AppLog.instance.log(AppLogLevel.warn, 'backup', '备份列表读取失败：$e');
    }
  }

  String get _backupSubtitle {
    if (_backingUp) return _backupPhase.isEmpty ? '正在准备完整备份…' : _backupPhase;
    final date = _lastBackupAt?.toLocal().toString().split('.').first;
    final status = _backupCount < 0
        ? '正在读取备份状态'
        : _backupCount == 0
        ? '尚无完整备份'
        : '已有 $_backupCount 份完整备份；最近：$date';
    return '主库、知识库（含向量及模型信息）、学习进度、章节目录和已保存课件；'
        '不含 API Key、日志与缓存。\n'
        '$status（最多保留 ${FullBackupManager.maxBackups} 份）';
  }

  Future<void> _backupNow() async {
    if (_dataBusy) return;
    final dir = LocalBackend.instance.dataDir;
    if (dir == null) {
      TopToast.show(context, '备份失败：本地数据尚未初始化', type: TopToastType.error);
      return;
    }
    setState(() {
      _backingUp = true;
      _backupPhase = '正在准备完整备份…';
    });
    try {
      await LocalBackend.instance.sharedDb; // 首次使用也先完成主库初始化
      final result = await FullBackupManager.instance.createBackup(
        dir,
        appVersion: _updateVersionName.isEmpty ? null : _updateVersionName,
        onProgress: (message) {
          if (mounted) setState(() => _backupPhase = message);
        },
      );
      AppLog.instance.log(
        AppLogLevel.info,
        'backup',
        '完整备份完成：${result.fileCount} 个文件，${result.vectors} 条向量，${result.sizeBytes} 字节',
      );
      if (!mounted) return;
      _loadBackups();
      TopToast.show(
        context,
        '完整备份已保存：${result.cards} 张卡片、${result.vectors} 条向量',
        type: TopToastType.success,
        stayDuration: kToastStayImportant,
      );
    } catch (e) {
      final message = e is FullBackupException ? e.message : '$e';
      AppLog.instance.log(AppLogLevel.error, 'backup', '完整备份失败：$message');
      if (mounted) {
        TopToast.show(
          context,
          '备份失败：$message',
          type: TopToastType.error,
          stayDuration: kToastStayImportant,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _backingUp = false;
          _backupPhase = '';
        });
      }
    }
  }

  /// 把已落盘的完整包另存/分享出应用目录，便于卸载或换机后恢复。
  Future<void> _shareFullBackup() async {
    if (_dataBusy) return;
    final path = _latestBackupPath;
    if (path == null) return;
    setState(() => _exporting = true);
    try {
      await SharePlus.instance.share(
        ShareParams(files: [XFile(path)], text: '恒牙完整学习数据备份（含向量库）'),
      );
    } catch (e) {
      if (mounted) {
        TopToast.show(context, '分享完整备份失败：$e', type: TopToastType.error);
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// db 保留原迁移能力；完整 zip 经校验、明确确认后恢复整个学习数据集。
  Future<void> _importDatabase() async {
    if (_dataBusy) return;
    final dir = LocalBackend.instance.dataDir;
    if (dir == null) return;
    setState(() => _importing = true);
    try {
      final picked = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(label: '恒牙数据库或完整备份', extensions: const ['db', 'zip']),
        ],
      );
      if (!mounted || picked == null) return;
      if (picked.path.toLowerCase().endsWith('.zip')) {
        void progress(String message) {
          if (mounted) setState(() => _importPhase = message);
        }

        final preview = await FullBackupManager.instance.validateBackup(
          picked.path,
          onProgress: progress,
        );
        if (!mounted) return;
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('恢复完整备份？'),
            scrollable: true,
            content: Text(
              '备份时间：${preview.createdAt.toLocal().toString().split('.').first}\n'
              '${preview.cards} 张卡片、${preview.reviewLogs} 条复习记录、'
              '${preview.subjects} 个科目\n'
              '${preview.chunks} 个语料块、${preview.vectors} 条向量、'
              '${preview.sourceFiles} 份课件\n'
              '向量模型：${preview.modelName.isEmpty ? '未设置' : preview.modelName}\n\n'
              '将替换本机主数据库、知识库（含向量）、学习进度、章节目录和课件，'
              '不是合并导入。备份中没有的知识库/进度也会恢复为无数据状态。\n\n'
              'API Key 不在备份中，本机已有密钥保持不变；换机后需重新配置。'
              '${preview.warnings.isEmpty ? '' : '\n\n注意：${preview.warnings.join('；')}'}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确认恢复'),
              ),
            ],
          ),
        );
        if (ok != true || !mounted) return;
        final restored = await FullBackupManager.instance.restoreBackup(
          dir,
          picked.path,
          onBeforeSwap: () => LocalBackend.instance.reload(),
          onProgress: progress,
        );
        ApiClient.instance.resetSubjectCaches();
        AppLog.instance.log(
          AppLogLevel.info,
          'backup',
          '完整恢复完成：${restored.cards} 张卡片、${restored.vectors} 条向量',
        );
        if (!mounted) return;
        _loadBackups();
        _loadAi();
        _loadInstructFlag();
        _loadUpdateState();
        _scanCache();
        TopToast.show(
          context,
          '完整恢复成功：${restored.cards} 张卡片、${restored.vectors} 条向量；知识库和学习进度已恢复'
          '${restored.warnings.isEmpty ? '' : '。注意：${restored.warnings.join('；')}'}',
          type: restored.warnings.isEmpty
              ? TopToastType.success
              : TopToastType.info,
          stayDuration: kToastStayImportant,
        );
        return;
      }
      final stats = DataManager.instance.validateSource(picked.path);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认导入？'),
          content: Text(
            '将导入 ${stats['cards']} 张卡片、${stats['reviewLogs']} 条复习记录、'
            '${stats['subjects']} 个科目（数据版本 ${stats['dataVersion']}）。\n\n'
            '仅替换主数据库，不含知识库、向量、学习进度和课件。'
            '如需完整恢复，请选择「立刻备份」生成的 zip 包。\n\n'
            '本机当前主库数据将被替换，此操作不可撤销。',
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
      if (ok != true || !mounted) return;
      await DataManager.instance.importDatabase(
        dir,
        picked.path,
        onBeforeSwap: () => LocalBackend.instance.reload(),
      );
      ApiClient.instance.resetSubjectCaches();
      if (mounted) {
        TopToast.show(
          context,
          '导入成功：${stats['cards']} 张卡已就位，切回「科目」页即可查看',
          type: TopToastType.success,
          stayDuration: kToastStayImportant,
        );
      }
    } catch (e) {
      final message = e is FullBackupException
          ? e.message
          : e is DataManagerException
          ? e.message
          : '$e';
      AppLog.instance.log(AppLogLevel.error, 'backup', '数据导入失败：$message');
      if (mounted) {
        TopToast.show(
          context,
          '导入失败：$message',
          type: TopToastType.error,
          stayDuration: kToastStayImportant,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _importing = false;
          _importPhase = '';
        });
      }
    }
  }

  /// 一键导出并分享（完整单文件库，可直接在新手机导入）
  Future<void> _exportDatabase() async {
    if (_dataBusy) return;
    final dir = LocalBackend.instance.dataDir;
    if (dir == null) return;
    setState(() => _exporting = true);
    try {
      final out = DataManager.instance.exportDatabase(dir);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(files: [XFile(out)], text: '恒牙数据库备份'),
      );
      _loadBackups();
    } on DataManagerException catch (e) {
      if (mounted) TopToast.show(context, '导出失败：${e.message}');
    } catch (e) {
      if (mounted) TopToast.show(context, '导出失败：$e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// 导入语料包（批5 节点③）：SAF 选 zip → validatePackageBg 摘要预览（后台 isolate，
  /// 校验临时库在 cache 目录）→ 二次确认（模型名对暗号不符时明确警示但不阻断）→
  /// importPackageBg（后台 isolate 准备 → 主 isolate 换库：备份+原子替换+补科目行
  /// +进度只补不改+失败回滚）→ 终态 disposeImportedZip 清理选文件缓存拷贝。
  Future<void> _importCorpusPackage() async {
    if (_dataBusy) return;
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
      final appVersion = _updateVersionName.isEmpty ? null : _updateVersionName;
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
      final curModel = _ai?.embedding.model ?? '';
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

  // ---------------- M5：AI 服务配置（自设置页迁入） ----------------

  /// 拉取三套 AI 配置（掩码态）；旧服务器 404 → 降级提示「需 0.3.0+」
  Future<void> _loadAi() async {
    setState(() => _aiLoading = true);
    try {
      final ai = await ApiClient.instance.fetchAiSettings();
      if (!mounted) return;
      setState(() {
        _ai = ai;
        _aiLoading = false;
        _aiUnsupported = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _aiLoading = false;
        _aiUnsupported = e.statusCode == 404; // 其余错误走重试态
      });
    }
  }

  /// 编辑入口：弹底部编辑层（baseUrl/model/apiKey + 测试连接 + 保存）
  void _editAiService(String service) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => AiServiceEditSheet(
        service: service,
        config: _ai!.of(service),
        onSaved: _loadAi, // 保存成功后重拉掩码
      ),
    );
  }

  // ---------------- instruct 前缀开关（批5 节点③，local 模式；自设置页迁入） ----------------

  /// instruct 前缀开关回显（settings embedding.instructQuery）
  Future<void> _loadInstructFlag() async {
    if (kBackendMode != BackendMode.local) return;
    try {
      final db = await LocalBackend.instance.sharedDb;
      if (!mounted) return;
      setState(() {
        _instructOn = (db.settingGet('embedding.instructQuery') ?? '') != '0';
        _instructLoaded = true;
      });
    } catch (_) {
      // db 未初始化（极端时序）：保持默认开
    }
  }

  /// instruct 前缀开关落库（不 bump data_version——配置类数据）
  Future<void> _setInstructFlag(bool on) async {
    setState(() => _instructOn = on);
    try {
      final db = await LocalBackend.instance.sharedDb;
      db.settingSet('embedding.instructQuery', on ? '1' : '0');
    } catch (_) {
      if (mounted) setState(() => _instructOn = !on); // 落库失败回弹
    }
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
            child: Text(text, style: TextStyle(fontSize: 12, color: color)),
          ),
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
          .replaceFirst('{total}', (total / 1048576).toStringAsFixed(1));
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
          ctx,
          Icons.sync_rounded,
          UpdateMessages.checking,
          scheme.outline,
        );
      case UpdateUiPhase.upToDate:
        return _updateStatusRow(
          ctx,
          Icons.check_circle_outline_rounded,
          UpdateMessages.upToDate(_updateVersionName),
          scheme.primary,
        );
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
                  Icon(
                    Icons.new_releases_outlined,
                    size: 14,
                    color: scheme.primary,
                  ),
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
                  Icon(
                    Icons.downloading_rounded,
                    size: 14,
                    color: scheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _updateDownloadingText(),
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
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
          ctx,
          Icons.error_outline_rounded,
          _updateError,
          scheme.error,
        );
      case UpdateUiPhase.needPermission:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _updateStatusRow(
                ctx,
                Icons.shield_outlined,
                UpdateMessages.needPermission,
                scheme.error,
              ),
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
        return _updateStatusRow(
          ctx,
          Icons.smartphone_rounded,
          UpdateMessages.installHandoff,
          scheme.primary,
        );
      case UpdateUiPhase.failed:
        return _updateStatusRow(
          ctx,
          Icons.error_outline_rounded,
          _updateError.isEmpty ? UpdateMessages.unreachable : _updateError,
          scheme.error,
        );
    }
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !_dataBusy,
      child: AbsorbPointer(
        absorbing: _dataBusy,
        child: Scaffold(
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
                    const Icon(
                      Icons.health_and_safety_outlined,
                      size: 42,
                      color: Colors.teal,
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '恒牙',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
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
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
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
                      trailing:
                          _updatePhase == UpdateUiPhase.checking ||
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
                            child: const Text(
                              UpdateMessages.overseasLineButton,
                            ),
                          ),
                          TextButton(
                            onPressed: _applyDomesticLine,
                            child: const Text(
                              UpdateMessages.domesticLineButton,
                            ),
                          ),
                        ],
                      ),
                    ),
                    _updateStatusView(context),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ---- 每日提醒（自设置页迁入） ----
              const _AboutSectionHeader(title: '每日提醒'),
              Card(
                elevation: 0,
                color: scheme.surfaceContainerLow,
                child: Column(
                  children: [
                    SwitchListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
                      title: const Text(
                        '开启提醒',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text('到点本地通知，不联网也能提醒'),
                      value: _reminderLoaded ? _reminderEnabled : false,
                      onChanged: _reminderLoaded
                          ? (v) => _applyReminder(enabled: v)
                          : null,
                    ),
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
                      enabled: _reminderEnabled,
                      title: const Text('提醒时间'),
                      trailing: Text(
                        _reminderTime.format(context),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: _reminderEnabled
                              ? scheme.primary
                              : scheme.outline,
                        ),
                      ),
                      onTap: _reminderEnabled
                          ? () async {
                              final picked = await showTimePicker(
                                context: context,
                                initialTime: _reminderTime,
                              );
                              if (picked != null) {
                                await _applyReminder(time: picked);
                              }
                            }
                          : null,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Icon(
                      _notiGranted ? Icons.check_circle : Icons.error_outline,
                      size: 14,
                      color: _notiGranted
                          ? const Color(0xFF2BA471)
                          : const Color(0xFFD54941),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _notiGranted ? '通知权限已开启' : '通知权限未开启，部分手机需手动允许「自启动/通知」',
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                    if (!_notiGranted)
                      TextButton(
                        onPressed: _requestNotiPermission,
                        child: const Text('去开启'),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ---- 数据管理（Phase 2，仅 local 模式；自设置页迁入） ----
              if (kBackendMode == BackendMode.local) ...[
                const _AboutSectionHeader(title: '数据管理'),
                Card(
                  elevation: 0,
                  color: scheme.surfaceContainerLow,
                  child: Column(
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: const Text(
                          '导入数据库（迁移）',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          _importPhase.isEmpty
                              ? '选择「立刻备份」生成的完整 zip，恢复主库、知识库（含向量）、进度和课件；'
                                    '也支持旧版仅主库的 db 文件'
                              : _importPhase,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: _importing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.download_rounded),
                        enabled: !_dataBusy,
                        onTap: _dataBusy ? null : _importDatabase,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: const Text(
                          '导入语料包（成品语料库）',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          _pkgPhase.isEmpty
                              ? '选择 PC 端打包的语料包 zip（成品语料库+章节目录），替换本机语料库；'
                                    '卡片、复习记录与学习进度分毫不动，旧库自动备份'
                              : _pkgPhase,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: _pkgImporting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.folder_zip_rounded),
                        enabled: !_dataBusy,
                        onTap: _dataBusy ? null : _importCorpusPackage,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: const Text(
                          '一键导出并分享',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text(
                          '仅导出主数据库（卡片、复习记录、科目，不含 API Key）；'
                          '需要包含知识库和向量时，请使用下方「立刻备份」',
                          style: TextStyle(fontSize: 12),
                        ),
                        trailing: _exporting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.ios_share_rounded),
                        enabled: !_dataBusy,
                        onTap: _dataBusy ? null : _exportDatabase,
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                      ListTile(
                        key: const ValueKey('backup-now'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                        ),
                        title: const Text(
                          '立刻备份',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          _backupSubtitle,
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: _backingUp
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.backup_rounded),
                        enabled: !_dataBusy,
                        onTap: _dataBusy ? null : _backupNow,
                      ),
                      if (_latestBackupPath != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '备份在应用内保存，卸载会丢失。建议分享另存到应用外；'
                                '恢复时在上方「导入数据库（迁移）」选择完整 zip。',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.outline,
                                ),
                              ),
                              const SizedBox(height: 4),
                              TextButton.icon(
                                onPressed: _dataBusy ? null : _shareFullBackup,
                                icon: const Icon(
                                  Icons.ios_share_rounded,
                                  size: 18,
                                ),
                                label: const Text('分享最近完整备份'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // ---- AI 服务配置（M5；自设置页迁入） ----
              const _AboutSectionHeader(title: 'AI 服务配置'),
              if (_aiLoading)
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
              else if (_aiUnsupported || _ai == null)
                NeedUpgradeCard(
                  message: _aiUnsupported ? '需服务器 0.3.0+，暂未部署' : '加载失败',
                  onRetry: _loadAi,
                )
              else
                Column(
                  children: [
                    AiServiceCard(
                      scheme: scheme,
                      title: '生卡 LLM',
                      desc: '每晚自动拆卡用',
                      config: _ai!.llm,
                      onEdit: () => _editAiService('llm'),
                    ),
                    const SizedBox(height: 8),
                    AiServiceCard(
                      scheme: scheme,
                      title: '备用生卡 LLM',
                      desc: '主 LLM 连续失败自动切换',
                      config: _ai!.of('llm_backup'),
                      onEdit: () => _editAiService('llm_backup'),
                    ),
                    const SizedBox(height: 8),
                    AiServiceCard(
                      scheme: scheme,
                      title: '向量模型',
                      desc: '知识库检索用',
                      config: _ai!.embedding,
                      onEdit: () => _editAiService('embedding'),
                    ),
                    const SizedBox(height: 8),
                    AiServiceCard(
                      scheme: scheme,
                      title: '重排序模型',
                      desc: '知识库检索精排用',
                      config: _ai!.reranker,
                      onEdit: () => _editAiService('reranker'),
                    ),
                  ],
                ),

              // instruct 前缀开关（批5 节点③，仅 local 模式）：查询侧嵌入前缀，
              // 接线 assembleEmbedConfig（pipeline_runner）→ SiliconFlowConfig
              // .queryInstruct（关=''、开=null=内置 kQueryInstruct）。
              if (kBackendMode == BackendMode.local) ...[
                const SizedBox(height: 8),
                Card(
                  elevation: 0,
                  color: scheme.surfaceContainerLow,
                  child: SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text(
                      '检索查询 instruct 前缀',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      '知识库检索的查询向量加 instruct 前缀（Qwen3 向量模型适用）；'
                      'Gitee/模力方舟通道建议关闭',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: _instructLoaded ? _instructOn : true,
                    onChanged: _instructLoaded
                        ? (v) => _setInstructFlag(v)
                        : null,
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // ---- 诊断 ----
              const _AboutSectionHeader(title: '诊断'),
              Card(
                elevation: 0,
                color: scheme.surfaceContainerLow,
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                      ),
                      leading: Icon(
                        Icons.article_outlined,
                        size: 20,
                        color: scheme.primary,
                      ),
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
                  leading: Icon(
                    Icons.cleaning_services_outlined,
                    size: 20,
                    color: scheme.primary,
                  ),
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
                          _cacheScan == null
                              ? '…'
                              : _mb(_cacheScan!.totalBytes),
                          style: const TextStyle(fontSize: 13),
                        ),
                  onTap: _confirmClearCache,
                ),
              ),
            ],
          ),
        ),
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
