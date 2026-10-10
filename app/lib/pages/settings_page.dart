// 综合设置页（M3）：统计页底部设置栏进入
// 模块：数据与同步（离线评分队列 / 手动同步 / 服务器状态）
//       · 自动化拆卡（强制开始拆卡 / 改卡，server 0.4.1+）
//       · 知识库（M5：状态+上传课件；App 内建库：待处理清单→开始建库→
//         进度→完成摘要，local 模式）· 关于
//       · 每日提醒 / 数据管理（导入 hengya.db 迁移 / 导入语料包 / 一键导出
//         分享） / AI 服务配置（含 instruct 前缀开关）已整体迁至「恒牙」
//         聚合页（about_page.dart，2026-09-11）
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/api/api_client.dart';
import '../services/api/demo_backend.dart';
import '../widgets/top_toast.dart';
import 'about_page.dart';
import 'corpus_library_page.dart';
import 'rework_workbench_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _fogEnabled = false; // #12 答案雾（复习时擦开显示；默认关）
  bool _fogHug = false; // 纸片大小：false=盖满区域（默认），true=贴答案文字
  /// 版本号动态来源（package_info）：读取构建时写入的 versionName，永不需手动同步
  late final Future<PackageInfo> _pkgInfo = PackageInfo.fromPlatform();

  int _pendingCount = 0;

  bool _syncing = false;
  bool _checking = false;
  bool _triggering = false; // 强制拆卡触发中（防重复点击）
  bool _weeklyTriggering = false; // 手动真题周扫触发中（防重复点击）

  /// 自动周扫计时状态（local 模式加载；GET /pipeline/weekly）。
  WeeklyScanStatus? _weeklyStatus;
  bool _weeklyStatusLoading = false;

  bool? _serverOk; // null = 未检测

  @override
  void initState() {
    _loadFogEnabled();
    super.initState();
    _loadAll();
    if (currentBackendMode == BackendMode.local) _loadWeeklyStatus();
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

  // ---------------- #11 重复卡查重阈值（2026-09-13） ----------------

  /// 阈值调节弹层：拉当前值 → 滑杆 0.80~0.99 → PUT /settings/dup。
  /// 生效于下一轮流水线查重趟次；默认 0.92（宁漏勿误杀，用户实测后自调）。
  Future<void> _editDupThreshold() async {
    double value;
    try {
      value = await ApiClient.instance.fetchDupThreshold();
    } on ApiException catch (e) {
      if (!mounted) return;
      TopToast.show(context, '读取失败：${e.message}', type: TopToastType.error);
      return;
    }
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => StatefulBuilder(
        builder: (dlgCtx, setDlg) => AlertDialog(
          title: const Text('疑似重复相似度阈值'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '新卡的题干与已有卡向量相似度达到该阈值即标记「疑似重复」，'
                '照常进审核区并排对比。调低更敏感（易误报），调高更宽松（易漏）。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              Slider(
                value: value,
                min: 0.80,
                max: 0.99,
                divisions: 19,
                label: value.toStringAsFixed(2),
                onChanged: (v) => setDlg(() => value = v),
              ),
              Text('当前：${value.toStringAsFixed(2)}'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dlgCtx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dlgCtx, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (go != true) return;
    try {
      await ApiClient.instance.updateDupThreshold(
        double.parse(value.toStringAsFixed(2)),
      );
      if (!mounted) return;
      TopToast.show(
        context,
        '已保存：阈值 ${value.toStringAsFixed(2)}（下一轮流水线生效）',
        type: TopToastType.success,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      TopToast.show(
        context,
        '保存失败：${e.message}',
        type: TopToastType.error,
        stayDuration: const Duration(milliseconds: 1800),
      );
    }
  }

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

  // ---------------- 真题周扫（local 0.1.13+：手动触发 + 计时调整） ----------------

  Future<void> _loadWeeklyStatus() async {
    setState(() => _weeklyStatusLoading = true);
    try {
      final s = await ApiClient.instance.weeklyScanStatus();
      if (!mounted) return;
      setState(() => _weeklyStatus = s);
    } on ApiException {
      // 旧版本后端无此路由：状态行显示不支持提示，入口仍可见（点击再报错）
    } finally {
      if (mounted) setState(() => _weeklyStatusLoading = false);
    }
  }

  /// 「自动周扫计时」状态行文案（从未跑 / 已到期 / 距到期剩余天数）。
  String get _weeklyScheduleText {
    if (_weeklyStatusLoading && _weeklyStatus == null) return '读取中…';
    final s = _weeklyStatus;
    if (s == null) return '当前版本不支持（需 0.1.13+）';
    final last = s.lastRunAt;
    if (last == null || last.isEmpty) {
      return '从未自动扫描——下次拆卡收尾即会执行';
    }
    final t = DateTime.tryParse(last);
    if (t == null) return '时间戳异常——点击调整可修复';
    if (s.due) {
      return '已到期（上次：${_fmtDateTime(t)}）——下次拆卡收尾自动执行';
    }
    final remain = t
        .add(Duration(days: s.intervalDays))
        .difference(DateTime.now());
    return '上次：${_fmtDateTime(t)}；约 ${remain.inDays + 1} 天后到期';
  }

  /// 手动真题周扫：先弹确认，确认后 POST /api/v1/pipeline/weekly，
  /// 结果一律 TopToast。weekly-only 单轮（不跑拆卡/回炉/罗盘），不受
  /// 自动路径 7 天节流限制，也不写节流时间戳（两路节奏独立）。
  Future<void> _confirmWeeklyScan() async {
    final go = await showDialog<bool>(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        title: const Text('立即真题周扫？'),
        content: const Text(
          '扫描已学章节与技能专题的真题语料，AI 出题进待审池。\n\n'
          '需已配置生卡 LLM 与真题语料；真题卡按「科目-年份-题号」幂等去重，'
          '重复扫描不会出重复卡。\n\n'
          '手动扫描不影响自动周扫的 7 天节奏（时间戳不变动）。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dlgCtx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dlgCtx, true),
            child: const Text('立即扫描'),
          ),
        ],
      ),
    );
    if (go != true || _weeklyTriggering) return;
    setState(() => _weeklyTriggering = true);
    try {
      final res = await ApiClient.instance.triggerWeeklyScan();
      if (!mounted) return;
      if (res.triggered) {
        TopToast.show(
          context,
          '已触发，真题周扫后台运行中',
          type: TopToastType.success,
          stayDuration: kToastStayImportant,
        );
      } else {
        TopToast.show(context, res.note ?? '已有任务排队中', type: TopToastType.info);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      TopToast.show(
        context,
        e.statusCode == 404
            ? '手动真题周扫仅本地模式支持（需 0.1.13+）'
            : e.statusCode == 409
            ? '拆卡流水线运行中，请稍后再试'
            : '触发失败：${e.message}',
        type: TopToastType.error,
        stayDuration: const Duration(milliseconds: 1800),
      );
    } finally {
      if (mounted) setState(() => _weeklyTriggering = false);
    }
  }

  /// 「自动周扫计时」调整对话框：清除（立即到期）/ 推迟 7 天（设为现在）/
  /// 自定义时间（日期+时间选择器任意设定）。
  // ---------------- #12 答案雾开关（2026-09-13） ----------------

  Future<void> _loadFogEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      setState(() {
        _fogEnabled = prefs.getBool('hengya.review.fog') ?? false;
        _fogHug = prefs.getBool('hengya.review.fog.hug') ?? false;
      });
    } catch (_) {
      // 测试宿主无 prefs 插件/读取失败 → 默认关
    }
  }

  Future<void> _toggleFog(bool v) async {
    setState(() => _fogEnabled = v);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hengya.review.fog', v);
  }

  /// 纸片大小切换（#12 双模式：盖满区域 / 贴答案文字）
  Future<void> _setFogHug(bool hug) async {
    setState(() => _fogHug = hug);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hengya.review.fog.hug', hug);
  }

  Future<void> _editWeeklySchedule() async {
    final status = _weeklyStatus;
    if (status == null) {
      TopToast.show(context, '当前版本不支持调整（需 0.1.13+）', type: TopToastType.error);
      return;
    }
    // #3（2026-09-13）界面同步：与「每日提醒」设置弹层统一为底部面板 +
    // 列表行形态（原居中 AlertDialog 四按钮与全 App 选择器风格不一致）
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (dlgCtx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '调整自动周扫计时',
              style: Theme.of(
                dlgCtx,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              _weeklyScheduleText,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(dlgCtx).colorScheme.outline,
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bolt_outlined),
              title: const Text('立即到期'),
              subtitle: const Text('下次拆卡收尾马上执行真题周扫'),
              onTap: () => Navigator.pop(dlgCtx, 'due'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.schedule_outlined),
              title: const Text('推迟 7 天'),
              subtitle: const Text('以现在为起点重算一周节奏'),
              onTap: () => Navigator.pop(dlgCtx, 'postpone'),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.edit_calendar_outlined),
              title: const Text('自定义时间'),
              subtitle: const Text('选日期与具体时刻'),
              onTap: () => Navigator.pop(dlgCtx, 'custom'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    String? value;
    switch (action) {
      case 'due':
        value = null;
        break;
      case 'postpone':
        value = DateTime.now().toIso8601String();
        break;
      case 'custom':
        final now = DateTime.now();
        final date = await showDatePicker(
          context: context,
          initialDate: now,
          firstDate: now.subtract(const Duration(days: 365)),
          lastDate: now.add(const Duration(days: 365)),
        );
        if (date == null || !mounted) return;
        final time = await showTimePicker(
          context: context,
          initialTime: TimeOfDay.fromDateTime(now),
        );
        if (time == null || !mounted) return;
        value = DateTime(
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        ).toIso8601String();
        break;
      default:
        return;
    }
    try {
      final res = await ApiClient.instance.setWeeklyScanSchedule(value);
      if (!mounted) return;
      setState(() => _weeklyStatus = res);
      TopToast.show(
        context,
        res.note ?? (res.due ? '已调整——自动周扫已到期' : '已调整'),
        type: TopToastType.success,
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      TopToast.show(context, '调整失败：${e.message}', type: TopToastType.error);
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
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text(
                    '答案雾（复习时擦开显示）',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    '翻面后答案被纸雾覆盖：手动擦开逐段看、掀纸角整页显现，'
                    '或直接评分；默认关',
                    style: TextStyle(fontSize: 12),
                  ),
                  value: _fogEnabled,
                  onChanged: _toggleFog,
                ),
                if (_fogEnabled) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: Row(
                      children: [
                        const Text('纸片大小', style: TextStyle(fontSize: 14)),
                        const Spacer(),
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          label: const Text(
                            '盖满区域',
                            style: TextStyle(fontSize: 12),
                          ),
                          selected: !_fogHug,
                          onSelected: (_) => _setFogHug(false),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          visualDensity: VisualDensity.compact,
                          label: const Text(
                            '贴答案文字',
                            style: TextStyle(fontSize: 12),
                          ),
                          selected: _fogHug,
                          onSelected: (_) => _setFogHug(true),
                        ),
                      ],
                    ),
                  ),
                ],
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
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
                const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                  title: const Text(
                    '立即真题周扫',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    currentBackendMode == BackendMode.local
                        ? '扫描已学章节的真题语料，AI 出题进待审池；不影响自动周扫节奏'
                        : '手动真题周扫仅本地模式支持',
                    style: const TextStyle(fontSize: 12),
                  ),
                  trailing: _weeklyTriggering
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.quiz_outlined),
                  onTap: _weeklyTriggering ? null : _confirmWeeklyScan,
                ),
                if (currentBackendMode == BackendMode.local) ...[
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text(
                      '重复卡查重阈值',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: const Text(
                      '生成卡的题干与已有卡向量相似度 ≥ 阈值 → 标记「疑似重复」进审核区；调低更敏感，调高更宽松',
                      style: TextStyle(fontSize: 12),
                    ),
                    trailing: const Icon(Icons.rule_outlined),
                    onTap: _editDupThreshold,
                  ),
                  const Divider(height: 1, indent: 16, endIndent: 16),
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16),
                    title: const Text(
                      '自动周扫计时',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      _weeklyScheduleText,
                      style: const TextStyle(fontSize: 12),
                    ),
                    trailing: _weeklyStatusLoading
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.schedule_outlined),
                    onTap: _editWeeklySchedule,
                  ),
                ],
              ],
            ),
          ),

          const SizedBox(height: 20),
          _SectionHeader(title: '资料与知识库'),
          Card(
            child: ListTile(
              key: const ValueKey('settings-corpus-library'),
              leading: const Icon(Icons.folder_copy_outlined),
              title: const Text('语料库与资料管理'),
              subtitle: const Text('按科目分类 · 查看内容 · 导入建库 · 安全删除'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CorpusLibraryPage(),
                ),
              ),
            ),
          ),

          if (currentBackendMode == BackendMode.local)
            Card(
              child: ListTile(
                leading: const Icon(Icons.build_circle_outlined),
                title: const Text('回炉工作台'),
                subtitle: const Text('改写、拆分、暂缓与排除；草案确认后才应用'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context, rootNavigator: true).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ReworkWorkbenchPage(),
                  ),
                ),
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
