// 综合设置页（M3）：统计页底部设置栏进入
// 模块：每日提醒（开关+时间）· 通知权限 · 离线队列 · 数据同步 · 服务器状态
//       · 自动化拆卡（强制开始拆卡 / 改卡，server 0.4.1+）
//       · AI 服务配置（M5：生卡 LLM / 向量模型；重排序模型 Phase 4 检索引擎用）
//       · 知识库（M5：状态+上传课件；App 内建库：待处理清单→开始建库→
//         进度→完成摘要，local 模式）· 关于
//       · 数据管理（Phase 2 local 模式：导入 hengya.db 迁移 / 导入语料包
//         （批5 节点③） / 一键导出分享）· AI 配置区含 instruct 前缀开关（节点③）
//       · 应用内更新（batch3 node1：云直链单通道——检查/下载/SHA-256/唤起安装器）
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';

import '../services/api/api_client.dart';
import '../services/api/demo_backend.dart';
import '../services/local/corpus/exam_topics.dart' show examTopicByCode;
import '../services/local/corpus/run_llm.dart' show llmListModels;
import '../services/local/corpus_package.dart';
import '../services/local/data_manager.dart';
import '../services/local/local_backend.dart';
import '../services/notification/daily_reminder.dart';
import '../services/update/update_service.dart';
import '../widgets/top_toast.dart';
import 'subject_picker.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// 版本号动态来源（package_info）：读取构建时写入的 versionName，永不需手动同步
  late final Future<PackageInfo> _pkgInfo = PackageInfo.fromPlatform();

  bool _reminderEnabled = true;
  TimeOfDay _reminderTime = const TimeOfDay(
    hour: DailyReminder.defaultHour,
    minute: DailyReminder.defaultMinute,
  );
  bool _reminderLoaded = false;
  bool _notiGranted = true;

  int _pendingCount = 0;

  bool _syncing = false;
  bool _checking = false;
  bool _triggering = false; // 强制拆卡触发中（防重复点击）

  bool? _serverOk; // null = 未检测

  // ---------------- M5：AI 服务配置 ----------------
  AiSettings? _ai;
  bool _aiLoading = true;
  bool _aiUnsupported = false; // 旧服务器（0.2.0）404 → 需 0.3.0+

  // ---------------- M5：知识库 ----------------
  CorpusStatus? _corpus;
  bool _corpusLoading = true;
  bool _corpusUnsupported = false;

  /// #3（2026-09-07）：语料变更信号（ValueNotifier 自增计数）。上传成功 /
  /// 「刷新语料状态」时自增 → 建库面板监听并重拉——上传后立即变蓝，无需
  /// 退出重进（用户实锤旧版须退出重进面板重建才变蓝）。
  final ValueNotifier<int> _corpusRev = ValueNotifier(0);

  // ---------------- Phase 2：数据管理（local 模式） ----------------
  bool _importing = false;
  bool _exporting = false;
  int _backupCount = -1; // -1 = 未读取（非 local 模式不展示）

  // ---------------- 语料包导入（批5 节点③，local 模式） ----------------
  bool _pkgImporting = false;

  // ---------------- instruct 前缀开关（批5 节点③，local 模式） ----------------
  // settings embedding.instructQuery：'0' = 关（queryInstruct=''）；
  // 缺省/'1' = 开（null = 内置 kQueryInstruct）。默认开 = 保持旧行为。
  bool _instructOn = true;
  bool _instructLoaded = false;

  // ---------------- 应用内更新（batch3 node1，云直链单通道） ----------------
  // 状态机/文案全在 UpdateService（UpdateUiPhase / UpdateMessages）；此处只持
  // 渲染态。源 URL 持久化 db settings（update.source），检查前先把输入框值落库。
  final TextEditingController _updateSourceCtrl = TextEditingController();
  final FocusNode _updateSourceFocus = FocusNode(); // 「国内线路」清空后聚焦
  UpdateUiPhase _updatePhase = UpdateUiPhase.idle;
  UpdateManifest? _updateManifest;
  String _updateVersionName = ''; // 当前版本（Kotlin getPackageInfo）
  double? _updateProgress; // null = 不确定进度（服务器未给长度）
  int _updateReceived = 0;
  int? _updateTotal;
  String _updateError = ''; // failed/verifyFailed 相位的消息
  int _updateLastPct = -1; // 进度渲染节流（避免逐 chunk setState 刷屏）

  @override
  void initState() {
    super.initState();
    _loadAll();
    _loadAi();
    _loadCorpus();
    _loadBackups();
    _loadUpdateState();
    _loadInstructFlag();
  }

  @override
  void dispose() {
    _updateSourceCtrl.dispose();
    _updateSourceFocus.dispose();
    _corpusRev.dispose();
    super.dispose();
  }

  /// Phase 2：备份状态行（local 模式显示）
  void _loadBackups() {
    final dir = LocalBackend.instance.dataDir;
    if (dir == null || kBackendMode != BackendMode.local) return;
    setState(() {
      _backupCount = DataManager.instance.backupsOf(dir).length;
    });
  }

  // ---------------- 应用内更新（batch3 node1）：状态机驱动 ----------------

  /// 区块首载：回显持久化的源 URL + 当前版本（通道取不到不炸页，静默降级）
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
    try {
      final info = await UpdateService.instance.currentPackageInfo();
      if (!mounted) return;
      setState(() => _updateVersionName = info.versionName);
    } catch (_) {
      // 版本取不到 → 副标题显示「当前版本未知」
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

  /// 导入数据库（迁移主通道）：选文件 → 只读预览 → 二次确认 → 原子替换。
  /// 失败不碰原库（DataManager.importDatabase 语义）。
  Future<void> _importDatabase() async {
    final dir = LocalBackend.instance.dataDir;
    if (dir == null) return;
    final picked = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: '数据库', extensions: const ['db']),
      ],
    );
    if (picked == null) return; // 用户取消
    setState(() => _importing = true);
    try {
      // 只读预览（不动任何数据）
      final stats = DataManager.instance.validateSource(picked.path);
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('确认导入？'),
          content: Text(
            '将导入 ${stats['cards']} 张卡片、${stats['reviewLogs']} 条复习记录、'
            '${stats['subjects']} 个科目（数据版本 ${stats['dataVersion']}）。\n\n'
            '本机当前数据将被替换，此操作不可撤销。',
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
      if (ok != true) return;
      await DataManager.instance.importDatabase(
        dir,
        picked.path,
        onBeforeSwap: () => LocalBackend.instance.reload(),
      );
      if (mounted) {
        TopToast.show(
          context,
          '导入成功：${stats['cards']} 张卡已就位，切回「科目」页即可查看',
          type: TopToastType.success,
          stayDuration: kToastStayImportant,
        ); // #5：一次性关键结果
      }
    } on DataManagerException catch (e) {
      if (mounted) TopToast.show(context, '导入失败：${e.message}');
    } catch (e) {
      if (mounted) TopToast.show(context, '导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  /// 一键导出并分享（完整单文件库，可直接在新手机导入）
  Future<void> _exportDatabase() async {
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

  /// 导入语料包（批5 节点③）：SAF 选 zip → validatePackage 摘要预览 →
  /// 二次确认（模型名对暗号不符时明确警示但不阻断）→ importPackage
  /// （备份+原子替换+补科目行+进度只补不改+失败回滚）。
  Future<void> _importCorpusPackage() async {
    final dir = LocalBackend.instance.dataDir;
    if (dir == null) return;
    final picked = await openFile(
      acceptedTypeGroups: [
        XTypeGroup(label: '语料包', extensions: const ['zip']),
      ],
    );
    if (picked == null) return; // 用户取消
    setState(() => _pkgImporting = true);
    try {
      final appVersion =
          _updateVersionName.isEmpty ? null : _updateVersionName;
      // 只读预览（不动任何数据）
      final summary = CorpusPackageManager.instance
          .validatePackage(picked.path, appVersion: appVersion);
      if (!mounted) return;
      // 模型名对暗号预检（确认框内警示；导入结果会再核一次）
      final curModel = _ai?.embedding.model ?? '';
      final modelWarn = curModel.isNotEmpty &&
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
      if (ok != true) return;
      final result = await CorpusPackageManager.instance.importPackage(
        dir,
        picked.path,
        appVersion: appVersion,
        onBeforeSwap: () => LocalBackend.instance.reload(),
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
      if (mounted) setState(() => _pkgImporting = false);
    }
  }

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

  Future<void> _loadAll() async {
    final reminder = await DailyReminder.instance.loadSettings();
    final granted = await _checkNotiPermission();
    if (!mounted) return;
    setState(() {
      _reminderEnabled = reminder.enabled;
      _reminderTime = TimeOfDay(hour: reminder.hour, minute: reminder.minute);
      _reminderLoaded = true;
      _notiGranted = granted;
      _pendingCount = ApiClient.instance.pendingAnswerCount;
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
      return true; // 检测失败不阻塞设置页
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

  // ---------------- M5：AI 服务配置 ----------------

  /// 拉取两套 AI 配置（掩码态）；旧服务器 404 → 降级提示「需 0.3.0+」
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
      builder: (_) => _AiServiceEditSheet(
        service: service,
        config: _ai!.of(service),
        onSaved: _loadAi, // 保存成功后重拉掩码
      ),
    );
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
          // ---------------- 每日提醒 ----------------
          _SectionHeader(title: '每日提醒'),
          Card(
            elevation: 0,
            color: scheme.surfaceContainerLow,
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
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
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  enabled: _reminderEnabled,
                  title: const Text('提醒时间'),
                  trailing: Text(
                    _reminderTime.format(context),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: _reminderEnabled ? scheme.primary : scheme.outline,
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

          // ---------------- 数据管理（Phase 2，仅 local 模式） ----------------
          if (kBackendMode == BackendMode.local) ...[
            _SectionHeader(title: '数据管理'),
            Card(
              elevation: 0,
              color: scheme.surfaceContainerLow,
              child: Column(
                children: [
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text(
                      '导入数据库（迁移）',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      '选择完整备份的 hengya.db 文件（本机「一键导出并分享」产物均可），'
                      '替换本机数据（卡片 / 复习记录 / 科目全部随迁）',
                      style: TextStyle(fontSize: 12),
                    ),
                    trailing: _importing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_rounded),
                    onTap: _importing ? null : _importDatabase,
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text(
                      '导入语料包（成品语料库）',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      '选择 PC 端打包的语料包 zip（成品语料库+章节目录），替换本机语料库；'
                      '卡片、复习记录与学习进度分毫不动，旧库自动备份',
                      style: TextStyle(fontSize: 12),
                    ),
                    trailing: _pkgImporting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.folder_zip_rounded),
                    onTap: _pkgImporting ? null : _importCorpusPackage,
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text(
                      '一键导出并分享',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      _backupCount >= 0
                          ? '导出完整数据库（可传到新手机再导入，不含 API Key）；'
                                '本机已自动备份 $_backupCount 份（每 48 小时滚动）'
                          : '导出完整数据库（可传到新手机再导入，不含 API Key）',
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: _exporting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.ios_share_rounded),
                    onTap: _exporting ? null : _exportDatabase,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],

          // ---------------- 自动化拆卡（server 0.4.1+ / Phase 4 端上） ----------------
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

          // ---------------- AI 服务配置（M5） ----------------
          _SectionHeader(title: 'AI 服务配置'),
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
            _NeedUpgradeCard(
              message: _aiUnsupported ? '需服务器 0.3.0+，暂未部署' : '加载失败',
              onRetry: _loadAi,
            )
          else
            Column(
              children: [
                _AiServiceCard(
                  scheme: scheme,
                  title: '生卡 LLM',
                  desc: '每晚自动拆卡用',
                  config: _ai!.llm,
                  onEdit: () => _editAiService('llm'),
                ),
                const SizedBox(height: 8),
                _AiServiceCard(
                  scheme: scheme,
                  title: '向量模型',
                  desc: '知识库检索用',
                  config: _ai!.embedding,
                  onEdit: () => _editAiService('embedding'),
                ),
                const SizedBox(height: 8),
                _AiServiceCard(
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
                onChanged: _instructLoaded ? (v) => _setInstructFlag(v) : null,
              ),
            ),
          ],

          const SizedBox(height: 20),

          // ---------------- 知识库（M5） ----------------
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
            _NeedUpgradeCard(
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

          const SizedBox(height: 20),

          // ---------------- 应用内更新（batch3 node1，云直链单通道；local 模式） ----------------
          // 源 URL db 持久化（update.source）；remote/demo 无本地库不展示（克制口径）
          if (kBackendMode == BackendMode.local) ...[
            _SectionHeader(title: '应用内更新'),
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
                  // 更新线路预设：海外一键填入 GitHub raw；国内只清空聚焦
                  // （ECS 直链不入 APK 二进制——token 会被解包提取）
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
                  _updateStatusView(scheme),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],

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

  // ---------------- 应用内更新（batch3 node1）：状态区渲染 ----------------

  /// 更新区块状态行：图标 + 文案（行内 Padding，其余区块同款视觉）
  Widget _updateStatusRow(
    ColorScheme scheme,
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

  /// 下载进度文案：「正在下载… 42%（32.1 MB / 76.8 MB）」；未知大小转「已下载 X MB」
  String _updateDownloadingText() {
    final total = _updateTotal;
    if (total != null && total > 0) {
      // 直接用 received/total 算：首个进度回调前 _updateProgress 尚为 null
      final pct = (_updateReceived * 100 ~/ total).toString();
      return UpdateMessages.downloadingKnown
          .replaceFirst('{pct}', pct)
          .replaceFirst('{got}', (_updateReceived / 1048576).toStringAsFixed(1))
          .replaceFirst('{total}', (total / 1048576).toStringAsFixed(1));
    }
    return UpdateMessages.downloadingUnknown(_updateReceived);
  }

  /// 状态机全相位渲染（idle 不占位）。文案全部来自 UpdateMessages（测试逐字断言）
  Widget _updateStatusView(ColorScheme scheme) {
    switch (_updatePhase) {
      case UpdateUiPhase.idle:
        return const SizedBox.shrink();
      case UpdateUiPhase.checking:
        return _updateStatusRow(
          scheme,
          Icons.sync_rounded,
          UpdateMessages.checking,
          scheme.outline,
        );
      case UpdateUiPhase.upToDate:
        return _updateStatusRow(
          scheme,
          Icons.check_circle,
          UpdateMessages.upToDate(_updateVersionName),
          const Color(0xFF2BA471),
        );
      case UpdateUiPhase.available:
        final m = _updateManifest!;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                UpdateMessages.foundNew(m.versionName),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF2BA471),
                ),
              ),
              if (m.notes.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  m.notes,
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
              const SizedBox(height: 4),
              Text(
                UpdateMessages.sizeOf(m),
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _downloadAndInstall,
                child: const Text(UpdateMessages.downloadButton),
              ),
            ],
          ),
        );
      case UpdateUiPhase.downloading:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _updateDownloadingText(),
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(value: _updateProgress, minHeight: 4),
            ],
          ),
        );
      case UpdateUiPhase.verifyFailed:
        return _updateStatusRow(
          scheme,
          Icons.error_outline,
          UpdateMessages.verifyFailed,
          const Color(0xFFD54941),
        );
      case UpdateUiPhase.needPermission:
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.error_outline,
                size: 14,
                color: Color(0xFFD54941),
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  UpdateMessages.needPermission,
                  style: TextStyle(fontSize: 12, color: Color(0xFFD54941)),
                ),
              ),
              TextButton(
                onPressed: _openInstallPermission,
                child: const Text(UpdateMessages.goGrantPermission),
              ),
            ],
          ),
        );
      case UpdateUiPhase.installHandoff:
        return _updateStatusRow(
          scheme,
          Icons.check_circle,
          UpdateMessages.installHandoff,
          const Color(0xFF2BA471),
        );
      case UpdateUiPhase.failed:
        return _updateStatusRow(
          scheme,
          Icons.error_outline,
          _updateError,
          const Color(0xFFD54941),
        );
    }
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

/// ---------------- M5：需升级 / 加载失败降级卡 ----------------
/// 旧服务器（0.2.0）对新增端点 404 → 显示「需服务器 0.3.0+，暂未部署」，不崩溃；
/// 拉取失败（非 404）→ 显示重试入口。
class _NeedUpgradeCard extends StatelessWidget {
  const _NeedUpgradeCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 20, color: scheme.outline),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$message，点右侧刷新',
                style: TextStyle(fontSize: 13, color: scheme.outline),
              ),
            ),
            IconButton(
              tooltip: '重试',
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// ---------------- M5：单套 AI 服务卡 ----------------
class _AiServiceCard extends StatelessWidget {
  const _AiServiceCard({
    required this.scheme,
    required this.title,
    required this.desc,
    required this.config,
    required this.onEdit,
  });

  final ColorScheme scheme;
  final String title;
  final String desc;
  final AiServiceConfig config;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final keyInfo = config.encryptedDisplay.isEmpty
        ? config.keyDisplay
        : '${config.keyDisplay} · ${config.encryptedDisplay}';
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(desc, style: TextStyle(fontSize: 11, color: scheme.outline)),
            const SizedBox(height: 4),
            Text(
              '地址：${config.baseUrl.isEmpty ? '—' : config.baseUrl}',
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              '模型：${config.model.isEmpty ? '—' : config.model}',
              style: const TextStyle(fontSize: 12),
            ),
            Text('Key：$keyInfo', style: const TextStyle(fontSize: 12)),
          ],
        ),
        isThreeLine: true,
        trailing: Icon(Icons.edit_outlined, size: 20, color: scheme.primary),
        onTap: onEdit,
      ),
    );
  }
}

/// embedding 卡默认预填（#1/#6②，2026-09-07）：对齐 reranker 卡做法——
/// 未配置时编辑层预填 SiliconFlow 完整 embeddings 端点 + 默认嵌入模型
/// （用户可改任意）。与 corpus/search_api.dart 的 kEmbedApiUrl / kEmbedModel
/// 同值——本页自持常量，不与检索引擎文件耦合。两形态兼容：settings 存
/// 基址（…/v1）或完整端点（…/v1/embeddings）均可，运行时（建库选路 /
/// 检索查询 / 测试连接）见 /embeddings 后缀不再追加。
const String kEmbeddingDefaultUrl = 'https://api.siliconflow.cn/v1/embeddings';
const String kEmbeddingDefaultModel = 'Qwen/Qwen3-VL-Embedding-8B';

/// ---------------- M5：AI 服务编辑层 ----------------
/// 三字段（baseUrl/model/apiKey）+「测试连接」（ok/延迟/失败原因）+「保存」。
/// reranker（重排序）/ embedding（向量）：URL = 完整端点，未配置时预填
/// SiliconFlow 默认端点 + 默认模型（可改任意）；reranker 测试结果额外经
/// TopToast 反馈（失败透传上游裸 message）。
/// llm（生卡）：URL 为 OpenAI 兼容基址（到 /v1），未配置留空（输入框带
/// 示例与常驻说明，#1）；测试连接成功后核对所配 model 是否在服务方
/// /models 列表（#2）——不在列表时橙色警示行提示，不阻断保存。
/// 安全：apiKey 只进请求体；保存成功立即清空 apiKey 控制器，界面只显示服务端掩码。
class _AiServiceEditSheet extends StatefulWidget {
  const _AiServiceEditSheet({
    required this.service,
    required this.config,
    required this.onSaved,
  });

  final String service; // llm | embedding | reranker
  final AiServiceConfig config;
  final VoidCallback onSaved; // 保存成功后父级刷新掩码

  @override
  State<_AiServiceEditSheet> createState() => _AiServiceEditSheetState();
}

class _AiServiceEditSheetState extends State<_AiServiceEditSheet> {
  bool get _isReranker => widget.service == 'reranker';

  /// 字段预填：已配置回显原值；reranker / embedding 未配置预填 SiliconFlow
  /// 默认值（#6②：对齐 reranker 卡现有做法——完整端点 + 默认模型，可改
  /// 任意），llm 未配置留空（示例引导见输入框 hint/helper，#1）
  late final _baseUrlCtrl = TextEditingController(
    text: widget.config.baseUrl.isNotEmpty
        ? widget.config.baseUrl
        : switch (widget.service) {
            'reranker' => ApiClient.kRerankerDefaultUrl,
            'embedding' => kEmbeddingDefaultUrl,
            _ => '',
          },
  );
  late final _modelCtrl = TextEditingController(
    text: widget.config.model.isNotEmpty
        ? widget.config.model
        : switch (widget.service) {
            'reranker' => ApiClient.kRerankerDefaultModel,
            'embedding' => kEmbeddingDefaultModel,
            _ => '',
          },
  );
  final _keyCtrl = TextEditingController();

  bool _testing = false;
  bool _saving = false;
  AiServiceTestResult? _testResult;
  String? _error;

  /// #2：llm 测试连接成功但所配 model 不在服务方 /models 列表时记下该
  /// model 名（null = 在列表 / 未核对 / 核对通道失败——均按正常成功展示）
  String? _modelMissing;

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose(); // 含明文 key 的控制器随弹层销毁
    super.dispose();
  }

  Future<void> _test() async {
    if (!_validate()) return;
    setState(() {
      _testing = true;
      _testResult = null;
      _modelMissing = null;
    });
    try {
      final r = await ApiClient.instance.testAiService(
        widget.service,
        baseUrl: _baseUrlCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(), // 空则服务端用已存 key
      );
      // #2：llm 连接成功 → 再核对所配 model 是否在服务方 /models 列表
      //（在滚动条期间完成，一次 setState 落结果；核对失败不降级连通性结论）
      final missing = (widget.service == 'llm' && r.ok)
          ? await _checkModelInList()
          : null;
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testResult = r;
        _modelMissing = missing;
      });
      // reranker 专属：结果经 TopToast 反馈（失败透传上游裸 message）
      if (_isReranker) {
        TopToast.show(
          context,
          r.ok ? r.display : r.message,
          type: r.ok ? TopToastType.success : TopToastType.error,
          stayDuration: r.ok
              ? const Duration(milliseconds: 1200)
              : const Duration(milliseconds: 1800),
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.statusCode == 404 ? '需服务器 0.3.0+，暂未部署' : e.message;
      setState(() {
        _testing = false;
        _testResult = AiServiceTestResult(ok: false, message: message);
        _modelMissing = null;
      });
      // reranker 专属：网络/校验层失败同样气泡透传（裸 message）
      if (_isReranker) {
        TopToast.show(
          context,
          message,
          type: TopToastType.error,
          stayDuration: const Duration(milliseconds: 1800),
        );
      }
    }
  }

  /// #2：拉取服务方 /models 列表（run_llm.llmListModels），核对所配 model
  /// 是否在列。key 口径：表单填了用表单；留空且 local 模式读本机系统安全
  /// 存储（AiKeyVault 内存缓存，与流水线同源）；remote 模式 key 在服务端、
  /// 端上拿不到 → 无法核对，静默跳过（保守：不误导、不降级连通性结论）。
  /// 返回 null = 在列表 / 无法核对；非 null = 所配 model 名（不在列表）。
  Future<String?> _checkModelInList() async {
    final baseUrl = _baseUrlCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    if (baseUrl.isEmpty || model.isEmpty) return null;
    var key = _keyCtrl.text.trim();
    if (key.isEmpty && currentBackendMode == BackendMode.local) {
      try {
        await LocalBackend.instance.initAiKeys(); // 幂等预热（main 已接线）
        key = LocalBackend.instance.aiKeyOf('llm');
      } catch (_) {
        key = '';
      }
    }
    if (key.isEmpty) return null;
    try {
      final ids = await llmListModels(baseUrl, key);
      return (ids.isEmpty || ids.contains(model)) ? null : model;
    } catch (_) {
      // 核对通道失败（超时/非 JSON/网关不回列表）→ 视为无法核对
      return null;
    }
  }

  Future<void> _save() async {
    if (!_validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ApiClient.instance.updateAiService(
        widget.service,
        baseUrl: _baseUrlCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(), // 空串=保持已存 key 不变
      );
      // 安全要求：保存成功立即清空明文 key 控制器（不留在任何 UI 态）
      _keyCtrl.clear();
      widget.onSaved(); // 父级重拉掩码
      if (!mounted) return;
      // 2026-09-06：轻提示统一顶部气泡（快速淡化 + 底色随机氛围），替换灰色 SnackBar
      TopToast.show(context, '已保存 AI 服务配置', type: TopToastType.success);
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.statusCode == 404
            ? '需服务器 0.3.0+，暂未部署'
            : (e.statusCode == 0 ? '连不上服务器，请检查网络' : '保存失败（${e.statusCode}）');
      });
    }
  }

  bool _validate() {
    if (_baseUrlCtrl.text.trim().isEmpty || _modelCtrl.text.trim().isEmpty) {
      setState(() => _error = 'baseUrl 与 model 不能为空');
      return false;
    }
    setState(() => _error = null);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = switch (widget.service) {
      'llm' => '编辑生卡 LLM',
      'embedding' => '编辑向量模型',
      _ => '编辑重排序模型',
    };
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
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '当前 Key：${widget.config.keyDisplay}'
            '${widget.config.encryptedDisplay.isEmpty ? '' : ' · ${widget.config.encryptedDisplay}'}',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _baseUrlCtrl,
            decoration: InputDecoration(
              // 示例引导（#1，2026-09-07）：reranker/embedding 的 URL 即完整
              // 端点（不拼后缀）；llm 为 OpenAI 兼容基址——hint 给示例 URL、
              // helper 常驻说明后缀规则（旧版仅 hint 占位，改进项 #1 依据）
              labelText: switch (widget.service) {
                'reranker' => 'rerank 端点 URL',
                'embedding' => 'embeddings 端点 URL',
                _ => 'baseUrl',
              },
              hintText: switch (widget.service) {
                'reranker' => '如 ${ApiClient.kRerankerDefaultUrl}',
                'embedding' => '如 $kEmbeddingDefaultUrl',
                _ => '如 https://api.siliconflow.cn/v1',
              },
              helperText: switch (widget.service) {
                'reranker' => '完整重排序端点，直接 POST 此地址',
                'embedding' => '完整 embeddings 端点；填 …/v1 基址也可（调用时自动补全）',
                _ => 'OpenAI 兼容基址，填到 /v1 即可，无需带 /chat/completions',
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtrl,
            decoration: InputDecoration(
              labelText: 'model',
              // reranker/embedding 未配置时已预填默认模型；hint 提示可改任意
              //（llm 给真实模型 ID 示例，#1）
              hintText: switch (widget.service) {
                'reranker' => '如 ${ApiClient.kRerankerDefaultModel}',
                'embedding' => '如 $kEmbeddingDefaultModel',
                _ => '服务方模型 ID，如 zai-org/GLM-5.3-Flash',
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'apiKey',
              hintText: '留空保持不变',
              // local 模式 key 存本机系统安全存储（AiKeyVault，Android
              // Keystore 加密），非服务器；remote 模式存服务端
              helperText: currentBackendMode == BackendMode.local
                  ? '加密存储在本机，界面只显示掩码'
                  : '加密存储在服务器，界面只显示掩码',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(fontSize: 12, color: scheme.error)),
          ],
          if (_testResult != null) ...[
            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                // #2：llm 连接成功但 model 不在服务方 /models 列表 → 换橙色
                // 警示行（保存不受影响）；其余按原语义（成功绿 / 失败红）
                final warn = _testResult!.ok && _modelMissing != null;
                final icon = _testResult!.ok
                    ? (warn ? Icons.warning_amber_rounded : Icons.check_circle)
                    : Icons.error_outline;
                final color = _testResult!.ok
                    ? (warn ? const Color(0xFFE37318) : const Color(0xFF2BA471))
                    : const Color(0xFFD54941);
                final text = warn
                    ? '连接成功，但 model $_modelMissing 不在服务方模型列表'
                    : _testResult!.display;
                return Row(
                  children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        text,
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _testing ? null : _test,
                  child: _testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('测试连接'),
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
        title: const Text('开始建库？'),
        content: Text(
          '将把 ${_pending.length} 个$kindLabel抽取入库（$modeLabel）。\n\n'
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
        // ---- 开始建库（待处理为空时禁用——构建语义 = 消费待处理队列） ----
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _pending.isEmpty || _busyTrigger
                ? null
                : _confirmAndStart,
            icon: const Icon(Icons.construction_rounded, size: 18),
            label: Text(_busyTrigger ? '启动中…' : '开始建库'),
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
