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
import 'dart:math';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../services/api/api_client.dart';
import '../services/local/app_log.dart';
import '../services/local/cache_cleaner.dart';
import '../services/local/data_manager.dart';
import '../services/local/full_backup.dart';
import '../services/local/local_backend.dart';
import '../services/notification/daily_reminder.dart';
import '../services/update/update_service.dart';
import '../widgets/top_toast.dart';
import 'app_log_page.dart';
import 'corpus_library_page.dart';
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
  bool get _dataBusy => _importing || _exporting || _backingUp;

  // ---------------- 语料包导入（批5 节点③，local 模式；自设置页迁入） ----------------

  // ---------------- M5：AI 服务配置（自设置页迁入） ----------------
  AiSettings? _ai;
  bool _aiLoading = true;
  bool _aiUnsupported = false; // 旧服务器（0.2.0）404 → 需 0.3.0+

  // ---------------- LLM 预设档案（P3.2，聊天与拆卡共用；local 专属） ----------------
  // GET /settings/presets 的原始 JSON（presets 列表 + chatPresetId/llmPresetId）。
  Map<String, dynamic>? _presets;

  /// 档案列表（safe cast；空 _presets → []）。
  List<Map<String, dynamic>> get _presetList => [
    for (final p in (_presets?['presets'] as List? ?? const []))
      Map<String, dynamic>.from(p as Map),
  ];

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
    _loadPresets();
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
                _cacheLine(ctx, CacheCategory.updateApks, scan, '旧版安装包（update 目录）'),
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

  // ---------------- LLM 预设档案（P3.2，local 模式） ----------------
  //
  // 最小可用 UI：列表弹层（名称/baseUrl/model + 聊天/拆卡使用标记）+
  // 新建/编辑表单（名称/baseUrl/model/温度/key）+ 删除 + 「用于聊天」
  // 「用于拆卡」切换。全走 LocalBackend /settings/presets/* 路由；remote /
  // demo 模式不显示（LocalBackend 路由仅 local 存在）。

  Future<void> _loadPresets() async {
    if (kBackendMode != BackendMode.local) return;
    try {
      final r = await LocalBackend.instance.get('/settings/presets');
      if (!mounted) return;
      setState(() => _presets = r);
    } catch (_) {
      // 加载失败保持空态（弹层内可见空列表，不阻塞页面其余区块）
    }
  }

  void _showPresetsSheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetCtx) => const _PresetsSheet(),
    ).then((_) => _loadPresets()); // 关闭后刷新使用标记（编辑/删除/切换后）
  }

  /// 入口卡副标题用：presetId → 档案名；空/未找到 → 「默认」。
  String _presetUseLabel(String presetId) {
    if (presetId.isEmpty) return '默认';
    for (final p in _presetList) {
      if (p['id'] == presetId) return (p['name'] as String?) ?? presetId;
    }
    return '默认';
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
                        leading: const Icon(Icons.folder_copy_outlined),
                        title: const Text('语料库与资料导入'),
                        subtitle: const Text('统一管理原件与成品语料包，查看内容、建库和删除'),
                        trailing: const Icon(Icons.chevron_right),
                        enabled: !_dataBusy,
                        onTap: _dataBusy
                            ? null
                            : () => Navigator.of(context, rootNavigator: true)
                                  .push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => const CorpusLibraryPage(
                                        initialTab: 1,
                                      ),
                                    ),
                                  ),
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
                    const SizedBox(height: 8),
                    AiServiceCard(
                      scheme: scheme,
                      title: '聊天服务',
                      desc: 'AI 问答（DeepSeek 反代）',
                      config: _ai!.chat,
                      onEdit: () => _editAiService('chat'),
                    ),
                    // 预设档案入口（P3.2，local 专属）：聊天与拆卡共用的
                    // LLM 预设档案池，一键切换各自使用的档案。
                    if (kBackendMode == BackendMode.local) ...[
                      const SizedBox(height: 8),
                      Card(
                        elevation: 0,
                        color: scheme.surfaceContainerLow,
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 4,
                          ),
                          title: const Text(
                            '预设档案',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          subtitle: Text(
                            _presetList.isEmpty
                                ? '聊天/拆卡共用的 LLM 预设档案（未创建）'
                                : '${_presetList.length} 套档案 · '
                                    '聊天：${_presetUseLabel(_presets?['chatPresetId'] as String? ?? '')} · '
                                    '拆卡：${_presetUseLabel(_presets?['llmPresetId'] as String? ?? '')}',
                            style: TextStyle(fontSize: 11, color: scheme.outline),
                          ),
                          trailing: Icon(
                            Icons.tune_rounded,
                            size: 20,
                            color: scheme.primary,
                          ),
                          onTap: _showPresetsSheet,
                        ),
                      ),
                    ],
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
                              : '旧版安装包、导入中断残留、校验临时文件等'),
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

// ---------------- LLM 预设档案弹层（P3.2，聊天与拆卡共用） ----------------
//
// 档案池列表（名称 / baseUrl / model + 聊天·拆卡使用标记）+ 新建/编辑表单
// （名称 / baseUrl / model / 温度 / key）+ 删除 + 「用于聊天」「用于拆卡」
// 一键切换。全走 LocalBackend /settings/presets/* 路由（local 专属）。key 明文
// 只存在于表单内存，保存成功即清空；列表只显示服务端掩码。
class _PresetsSheet extends StatefulWidget {
  const _PresetsSheet();

  @override
  State<_PresetsSheet> createState() => _PresetsSheetState();
}

class _PresetsSheetState extends State<_PresetsSheet> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> get _list => [
    for (final p in (_data?['presets'] as List? ?? const []))
      Map<String, dynamic>.from(p as Map),
  ];

  String get _chatId => (_data?['chatPresetId'] as String?) ?? '';
  String get _llmId => (_data?['llmPresetId'] as String?) ?? '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await LocalBackend.instance.get('/settings/presets');
      if (!mounted) return;
      setState(() {
        _data = r;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败（${e.statusCode}）';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载失败';
      });
    }
  }

  /// 新建档案 id（短随机串，与后端路由 [A-Za-z0-9]+ 校验一致）。
  String _newId() {
    final rnd = Random.secure();
    return List.generate(10, (_) => rnd.nextInt(36).toRadixString(36)).join();
  }

  Future<void> _use(String id, String scope) async {
    try {
      await LocalBackend.instance.post('/settings/presets/$id/use?scope=$scope', {});
      if (!mounted) return;
      TopToast.show(
        context,
        scope == 'chat' ? '聊天已切换该档案' : '拆卡已切换该档案',
        type: TopToastType.success,
      );
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      TopToast.show(context, e.message, type: TopToastType.error);
    }
  }

  Future<void> _delete(String id) async {
    try {
      await LocalBackend.instance.delete('/settings/presets/$id');
      if (!mounted) return;
      TopToast.show(context, '已删除档案');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      TopToast.show(context, e.message, type: TopToastType.error);
    }
  }

  Future<void> _edit({Map<String, dynamic>? preset}) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _PresetEditSheet(
        presetId: (preset?['id'] as String?) ?? _newId(),
        isNew: preset == null,
        initial: preset,
      ),
    );
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 4,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '预设档案',
                    style: Theme.of(
                      context,
                    ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _edit(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('新建'),
                ),
              ],
            ),
            Text(
              '聊天与拆卡共用的 LLM 预设档案；key 加密存本机',
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: 13, color: scheme.error),
                ),
              )
            else if (_list.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text('暂无档案，点「新建」创建', style: TextStyle(fontSize: 13)),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [for (final p in _list) _presetTile(scheme, p)],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _presetTile(ColorScheme scheme, Map<String, dynamic> p) {
    final id = (p['id'] as String?) ?? '';
    final name = (p['name'] as String?) ?? '';
    final baseUrl = (p['baseUrl'] as String?) ?? '';
    final model = (p['model'] as String?) ?? '';
    final temp = (p['temperature'] as String?) ?? '';
    final keyMasked = (p['keyMasked'] as String?) ?? '';
    final usedChat = id == _chatId;
    final usedLlm = id == _llmId;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    name.isEmpty ? '（未命名）' : name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '编辑',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () => _edit(preset: p),
                ),
                IconButton(
                  tooltip: '删除',
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => _delete(id),
                ),
              ],
            ),
            Text(baseUrl, style: TextStyle(fontSize: 11, color: scheme.outline)),
            Text(
              'model：$model'
              '${temp.isEmpty ? '' : ' · 温度 $temp'}'
              '${keyMasked.isEmpty ? ' · 未设 key' : ' · $keyMasked'}',
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                OutlinedButton(
                  onPressed: usedChat ? null : () => _use(id, 'chat'),
                  child: Text(usedChat ? '聊天使用中' : '用于聊天'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: usedLlm ? null : () => _use(id, 'llm'),
                  child: Text(usedLlm ? '拆卡使用中' : '用于拆卡'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 新建 / 编辑表单（名称 / baseUrl / model / 温度 / key）；apiKey 留空 = 保持原值。
class _PresetEditSheet extends StatefulWidget {
  const _PresetEditSheet({
    required this.presetId,
    required this.isNew,
    this.initial,
  });

  final String presetId;
  final bool isNew;
  final Map<String, dynamic>? initial;

  @override
  State<_PresetEditSheet> createState() => _PresetEditSheetState();
}

class _PresetEditSheetState extends State<_PresetEditSheet> {
  late final _nameCtrl = TextEditingController(
    text: (widget.initial?['name'] as String?) ?? '',
  );
  late final _baseUrlCtrl = TextEditingController(
    text: (widget.initial?['baseUrl'] as String?) ?? '',
  );
  late final _modelCtrl = TextEditingController(
    text: (widget.initial?['model'] as String?) ?? '',
  );
  late final _tempCtrl = TextEditingController(
    text: (widget.initial?['temperature'] as String?) ?? '',
  );
  final _keyCtrl = TextEditingController();

  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    _tempCtrl.dispose();
    _keyCtrl.dispose(); // 含明文 key 的控制器随弹层销毁
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final baseUrl = _baseUrlCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    final temp = _tempCtrl.text.trim();
    if (name.isEmpty || baseUrl.isEmpty || model.isEmpty) {
      setState(() => _error = '名称 / baseUrl / model 不能为空');
      return;
    }
    if (!baseUrl.startsWith('https://')) {
      setState(() => _error = 'baseUrl 必须以 https:// 开头');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await LocalBackend.instance.put('/settings/presets/${widget.presetId}', {
        'name': name,
        'baseUrl': baseUrl,
        'model': model,
        if (temp.isNotEmpty) 'temperature': temp,
        'apiKey': _keyCtrl.text.trim(), // 空 = 保持原值
      });
      _keyCtrl.clear(); // 安全：保存成功即清空明文 key
      if (!mounted) return;
      TopToast.show(context, '已保存档案', type: TopToastType.success);
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    }
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
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.isNew ? '新建预设档案' : '编辑预设档案',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: '名称',
              hintText: '如 反代 / 官方 DeepSeek',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrlCtrl,
            decoration: const InputDecoration(
              labelText: 'baseUrl',
              hintText: '如 https://api.deepseek.com/v1',
              helperText: 'OpenAI 兼容基址，填到 /v1 即可',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtrl,
            decoration: const InputDecoration(
              labelText: 'model',
              hintText: '服务方模型 ID',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tempCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '温度（可选，0 ~ 2）',
              hintText: '留空用服务端默认',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'apiKey',
              hintText: '留空保持不变',
              helperText: '加密存储在本机，界面只显示掩码',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(fontSize: 12, color: scheme.error)),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
