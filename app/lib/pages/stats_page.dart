// 统计页（M3）：今日复习进度 + streak + 打卡热力图 + 保留率 + 未来 7 天到期预测 + leech 弱卡榜
// 数据源：/api/v1/stats/today + /api/v1/stats/{streak,heatmap,retention,forecast} + /cards/leech
// 离线韧性（问1+5）：五路历史读端点带缓存回退——断网时整页可用（含底部设置入口），
// 并显示「离线数据 · 更新于 HH:mm」提示条。
// 口径注记（与每日计划对齐）：/stats/today 是「实时任务口径」（goal/done/dueTotal/
// remainingToday，随每张评分即时变化，不走离线缓存），五路历史统计是「历史回顾口径」
// （streak/热力图/保留率/到期预测，可离线回退旧帧）。两者同屏并存、各司其职：
// 今日任务看今日卡，历史趋势看下方各卡，任何数字不得互相换算或混用。
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:shared/hengya_shared.dart';

import '../services/api/api_client.dart';
import '../services/api/local_cache.dart';
import '../services/notification/daily_reminder.dart';
import '../theme.dart';
import '../widgets/offline_data_bar.dart';
import 'settings_page.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  bool _loading = true;
  String? _error;
  int _streak = 0;
  Map<String, int> _heatmap = {};
  RetentionStats _retention = RetentionStats(windows: const []);
  List<DueForecastDay> _forecast = [];
  List<FlashCard> _leech = [];
  DateTime? _cacheAt; // 非 null = 有端点走了离线缓存回退

  /// 今日进度（每日计划唯一口径 GET /stats/today）：null = 尚未取到 /
  /// 端点不可用（remote 老服务器 404）→ 今日区块不渲染，绝不阻断整页。
  /// 刻意不参与离线缓存回退——今日进度与队列同属实时任务口径（api_client
  /// fetchTodayStats 注释），断网/旧帧不回退，显示上次成功值即可。
  TodayProgress? _today;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // 并发拉取五路数据；失败则显示错误 + 重试按钮。
      // 各路独立带离线缓存回退：断网时只要有缓存，整页（含设置入口）仍可用。
      // 热力图请求 365 天（服务端钳制上限）——时间轴从第一天学习到今天
      final results = await Future.wait([
        ApiClient.instance.fetchStreak(),
        ApiClient.instance.fetchHeatmap(days: 365),
        ApiClient.instance.fetchRetention(),
        ApiClient.instance.fetchForecast(),
        ApiClient.instance.fetchLeechCards(),
      ]);
      // 今日进度单独拉取、不进 Future.wait 主链路：端点不可用时（remote 老
      // 服务器 404 / 断网）只影响今日区块自身（不渲染或保留旧值），绝不把
      // 整页拖入错误态——历史五路与今日任务两条数据面互不阻断。
      try {
        _today = await ApiClient.instance.fetchTodayStats();
      } on ApiException catch (e) {
        // 首拉即失败（404/断网）：区块不渲染；刷新时保留旧值，不闪没
        if (_today == null) debugPrint('stats/today 不可用，今日区块隐藏：${e.message}');
      }
      setState(() {
        _streak = results[0] as int;
        _heatmap = results[1] as Map<String, int>;
        _retention = results[2] as RetentionStats;
        _forecast = results[3] as List<DueForecastDay>;
        _leech = results[4] as List<FlashCard>;
        _cacheAt = ApiClient.instance.latestCacheHitAmong([
          CacheKeys.streak,
          CacheKeys.heatmap(365),
          CacheKeys.retention,
          CacheKeys.forecast(7),
          CacheKeys.leech(4),
        ]);
        _loading = false;
      });
    } on ApiException catch (e) {
      setState(() {
        _error = currentBackendMode == BackendMode.local
            ? '本地数据加载失败：${e.message}'
            : (e.statusCode == 0 ? '连不上服务器' : '加载失败（${e.statusCode}）');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('统计'),
        actions: [
          IconButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => const ReminderSettingsSheet(),
            ),
            icon: const Icon(Icons.notifications_outlined),
            tooltip: '每日提醒设置',
          ),
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorView(message: _error!, onRetry: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_cacheAt != null) ...[
                    OfflineDataBar(savedAt: _cacheAt),
                    const SizedBox(height: 16),
                  ],
                  // 今日任务是本页主角（实时任务口径），历史统计是陪衬：
                  // streak 卡下移一层、配色改 surface 版本以拉开视觉层级
                  if (_today != null) ...[
                    _TodayCard(progress: _today!),
                    const SizedBox(height: 16),
                  ],
                  _StreakCard(streak: _streak, scheme: scheme),
                  const SizedBox(height: 16),
                  HeatmapCard(data: _heatmap, scheme: scheme),
                  const SizedBox(height: 16),
                  _RetentionCard(retention: _retention, scheme: scheme),
                  const SizedBox(height: 16),
                  _ForecastCard(data: _forecast, scheme: scheme),
                  const SizedBox(height: 16),
                  _LeechCard(leech: _leech, scheme: scheme),
                  const SizedBox(height: 16),
                  _SettingsEntry(scheme: scheme),
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }
}

/// 保留率卡（近1天 / 近7天 / 近30天三档窗口）
/// 口径：窗口内 rating 不属于遗忘档（blackout/foggy，含旧库 'again'）的复习占比
class _RetentionCard extends StatelessWidget {
  const _RetentionCard({required this.retention, required this.scheme});

  final RetentionStats retention;
  final ColorScheme scheme;

  static const _windowLabels = {1: '近1天', 7: '近7天', 30: '近30天'};

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '保留率',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              '回忆成功（非"重来"档）占复习总数的比例',
              style: TextStyle(fontSize: 11, color: scheme.outline),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final d in const [1, 7, 30]) ...[
                  Expanded(
                    child: _RetentionWindowCell(
                      label: _windowLabels[d]!,
                      window: retention.window(d),
                      scheme: scheme,
                    ),
                  ),
                  if (d != 30) const SizedBox(width: 12),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RetentionWindowCell extends StatelessWidget {
  const _RetentionWindowCell({
    required this.label,
    required this.window,
    required this.scheme,
  });

  final String label;
  final RetentionWindow? window;
  final ColorScheme scheme;

  Color get _rateColor {
    final r = window?.rate;
    if (r == null) return scheme.outline;
    if (r >= 0.85) return const Color(0xFF2BA471); // 成功绿
    if (r >= 0.70) return const Color(0xFFE37318); // 警示橙
    return const Color(0xFFD54941); // 警示红
  }

  @override
  Widget build(BuildContext context) {
    final w = window;
    final hasData = w != null && w.rate != null;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: scheme.outline)),
          const SizedBox(height: 6),
          Text(
            hasData ? '${(w.rate! * 100).toStringAsFixed(0)}%' : '—',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w800,
              color: _rateColor,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            hasData ? '${w.retained}/${w.total} 次' : '暂无数据',
            style: TextStyle(fontSize: 11, color: scheme.outline),
          ),
        ],
      ),
    );
  }
}

/// 打卡热力图 · 时间轴（M5 改造，用户明确要求，替代旧版固定 84 天窗口）：
///   ① 第一格 = 第一天学习（数据中最早有复习记录的日期）
///   ② 从左到右时间严格递增、到今天为止
///   ③ 横向流式滚动，初始定位到最右（今天）
///   ④ 按日复习量配色强度（沿用旧版色阶）
/// 数据侧：fetchHeatmap(days: 365)（服务端钳制 1..365）；
/// 空历史（如刚还原复习记录后）显示引导空态而非空白错乱。
///
/// 口径注记：热力图是**历史回顾口径**（每日复习量的逐日存档，断网可回退缓存
/// 旧帧），与顶部「今日复习」卡的 /stats/today **实时任务口径**并存不混用——
/// 热力图最后一格（今天）的颜色在断网时可能滞后于今日卡的实际进度，属预期：
/// 今日任务以今日卡为准，历史趋势以热力图为准。两者日界同为本地自然日
/// （heatmapDays 按 reviewed_at 日期前缀聚合，today.done 同规则），不存在
/// 同一天归属歧义。

/// 时间轴格序列：首格 = 最早学习日，逐日递增到今天；无记录返回空
/// （调用方显示空态）。坏日期键自动忽略；未来记录（时钟偏移）收敛为今天单格。
List<DateTime> heatmapCellsFor(Map<String, int> data, DateTime today) {
  final days = [
    for (final k in data.keys)
      if (DateTime.tryParse(k) != null) DateTime.parse(k),
  ]..sort();
  final end = DateTime(today.year, today.month, today.day);
  if (days.isEmpty) return const [];
  final first = DateTime(days.first.year, days.first.month, days.first.day);
  if (!first.isBefore(end)) return [end];
  return [
    for (var d = first; !d.isAfter(end); d = d.add(const Duration(days: 1))) d,
  ];
}

class HeatmapCard extends StatefulWidget {
  const HeatmapCard({super.key, required this.data, required this.scheme});

  final Map<String, int> data;
  final ColorScheme scheme;

  @override
  State<HeatmapCard> createState() => _HeatmapCardState();
}

class _HeatmapCardState extends State<HeatmapCard> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    // 初始定位到最右（今天）：首帧布局完成后一次性跳到时间轴末端
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients && _scroll.position.maxScrollExtent > 0) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  String _key(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}';

  Color _cellColor(int n) => n == 0
      ? widget.scheme.surfaceContainerHighest
      : Color.lerp(
          widget.scheme.primary.withValues(alpha: 0.35),
          widget.scheme.primary,
          (n / 20).clamp(0.3, 1.0),
        )!;

  @override
  Widget build(BuildContext context) {
    final cells = heatmapCellsFor(widget.data, DateTime.now());
    return Card(
      elevation: 0,
      color: widget.scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '打卡热力图',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              cells.isEmpty
                  ? '从第一天学习开始逐日点亮'
                  : '${_key(cells.first)} 开始 · 至今 ${cells.length} 天',
              style: TextStyle(fontSize: 11, color: widget.scheme.outline),
            ),
            const SizedBox(height: 12),
            if (cells.isEmpty)
              // 空态（刚还原记录/新用户）：引导文案而非空白错乱
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Row(
                  children: [
                    Icon(
                      Icons.local_fire_department_outlined,
                      size: 20,
                      color: widget.scheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '暂无复习记录——完成第一次复习后，这里会从那一天开始点亮',
                        style: TextStyle(
                          fontSize: 12,
                          color: widget.scheme.outline,
                        ),
                      ),
                    ),
                  ],
                ),
              )
            else
              // 横向流式时间轴：左端=第一天学习，右端=今天，初始定位最右
              SingleChildScrollView(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final day in cells)
                      Padding(
                        padding: const EdgeInsets.only(right: 3),
                        child: Tooltip(
                          message:
                              '${_key(day)}：${widget.data[_key(day)] ?? 0} 次',
                          child: Container(
                            width: 18,
                            height: 18,
                            decoration: BoxDecoration(
                              color: _cellColor(widget.data[_key(day)] ?? 0),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Spacer(),
                Text(
                  '少 ',
                  style: TextStyle(fontSize: 11, color: widget.scheme.outline),
                ),
                for (final n in [0, 5, 10, 20])
                  Padding(
                    padding: const EdgeInsets.only(left: 3),
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _cellColor(n),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                Text(
                  ' 多',
                  style: TextStyle(fontSize: 11, color: widget.scheme.outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部设置栏：点击进入综合设置页
class _SettingsEntry extends StatelessWidget {
  const _SettingsEntry({required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.settings_outlined,
            size: 22,
            color: scheme.onPrimaryContainer,
          ),
        ),
        title: const Text('设置', style: TextStyle(fontWeight: FontWeight.w600)),
        subtitle: const Text('提醒 · 同步 · 服务器 · 关于'),
        trailing: Icon(Icons.chevron_right_rounded, color: scheme.outline),
        onTap: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage())),
      ),
    );
  }
}

/// 今日复习进度卡（本页主角）：进度条 + 「N/目标 M」+ 三态状态文案
///
/// 数据源：GET /stats/today 唯一口径（goal/done/dueTotal/remainingToday 四字段
/// 照抄 TodayProgress），禁止用热力图当天格或 forecast 今天柱另算 done——
/// 热力图是历史回顾口径（断网时还会回退缓存旧帧），today 是实时任务口径
/// （随每张评分即时变化），同一天数值同源但语义与时效不同，并存不混用。
/// 三态措辞（纯状态播报，无引导动作）：
///   未开始（done==0 且未达目标）「开始今日复习 · 还剩 N 张」
///   进行中（0 < done < goal）  「继续今日复习 · M/目标 K」
///   已完成（done >= goal）      「今日已完成 M/K ✓」
/// 整卡**不可点**：开始/继续复习的入口统一收敛在首页大 CTA（home_today_cta.dart），
/// 本卡降级为纯进度展示，避免双入口功能重复；「还剩 N 张」文案保留为信息播报。
/// remote 老服务器无 /stats/today（404）时外层不渲染本卡，不影响其余区块。
class _TodayCard extends StatelessWidget {
  const _TodayCard({required this.progress});

  final TodayProgress progress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final goal = progress.goal;
    final done = progress.done;
    final reached = goal > 0 && done >= goal;
    final statusText = done <= 0
        ? '开始今日复习 · 还剩 ${progress.remainingToday} 张'
        : reached
        ? '今日已完成 $done/$goal ✓'
        : '继续今日复习 · ${progress.display}';
    return Card(
      key: const ValueKey('stats-today-card'),
      elevation: 0,
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.flag_outlined,
                  size: 20,
                  color: scheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Text(
                  '今日复习',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const Spacer(),
                Text(
                  progress.display,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _RainbowProgressBar(
              value: goal <= 0 ? 0.0 : (done / goal).clamp(0.0, 1.0),
              trackColor: scheme.surfaceContainerHighest,
            ),
            const SizedBox(height: 12),
            Text(
              statusText,
              style: TextStyle(fontSize: 13, color: scheme.onPrimaryContainer),
            ),
          ],
        ),
      ),
    );
  }
}

/// 今日卡专用动态进度条（2026-10-12 视觉返工）：
///   未开始（p=0） 整体灰面 + 两条灰白雾带极缓慢横移（20s 一轮）；
///   进行中（p>0） 彩虹渐变底 + 一条软边高光带缓慢扫过已填充段。
///
/// 返工缘由（真机反馈）：旧版「粒子光线」在低进度时粒子最多/抖动最大
/// （反向挂钩 14 颗、1.2s 一轮），小白点高频闪烁 = 刺眼；空槽的斑马纹
/// 又被读成「一串灰色椭圆颗粒」，不像一条空进度条。
///
/// 参考实现：GitHub hnvn/flutter_shimmer（BSD-3，1.9k★）——用「一条宽软边
/// 渐变带整体平移」代替离散粒子/闪烁：色标固定、移动边缘柔和，移动边缘对
/// 动效感知的增益远高于同亮度的静态柔光，且没有颗粒感。本组件沿用该手法
/// （单 Controller + 平移 shader 的 CustomPainter，不新增依赖），但把周期
/// 放到 shimmer 默认 1.5s 的 2~3 倍，符合本页克制动效口径。
///
/// 动效参数（数值锚点，真机复查可微调）：
///   填充扫光周期 = lerp(3000, 4600, easeOut(p)) ms —— 保留「低进度略急切」
///                  的旧语义，但整体已比旧版慢 2.5 倍以上；
///   扫光带宽     = max(填充宽 × 0.55, 14) px，峰值白 0.28（低透明度）；
///   雾面周期     = 20s（极缓慢），两条雾带相位错开 0.5、宽度 1.3× / 0.85×、
///                  峰值白 0.12 / 0.08 —— 整体仍是灰面，只有极缓的明暗流动。
///
/// 实现注记：两个 AnimationController（雾带 20s / 扫光 3.0~4.6s）经
/// Listenable.merge 合成一路驱动，CustomPainter 每帧重绘（空态 2 个 shader、
/// 填充态 2 个 shader + 1 次 clip；无 saveLayer、无 MaskFilter 模糊，开销可控）。
class _RainbowProgressBar extends StatefulWidget {
  const _RainbowProgressBar({required this.value, required this.trackColor});

  /// 空态雾带一轮周期：20s（极缓慢；动效数值锚点，真机复查可微调）。
  static const Duration fogPeriod = Duration(seconds: 20);

  /// 进度 0..1；null 或超界一律按 0 处理（与原 LinearProgressIndicator 语义对齐）。
  final double value;
  final Color trackColor;

  @override
  State<_RainbowProgressBar> createState() => _RainbowProgressBarState();
}

class _RainbowProgressBarState extends State<_RainbowProgressBar>
    with TickerProviderStateMixin {
  /// 空态雾带控制器：固定 20s 一轮，与进度无关（纯氛围，极缓慢）。
  late final AnimationController _fog;

  /// 填充扫光控制器：周期随进度 3.0s~4.6s（见 _cycleFor）。
  late final AnimationController _sweep;

  /// 两个控制器合并为单一 Listenable（late 惰性求值 → 只建一次，
  /// 不逐帧新建 merge 对象）。
  late final Listenable _ticks = Listenable.merge([_fog, _sweep]);

  double? _lastP;

  @override
  void initState() {
    super.initState();
    _fog = AnimationController(
      vsync: this,
      duration: _RainbowProgressBar.fogPeriod,
    )..repeat();
    _sweep = AnimationController(
      vsync: this,
      duration: _cycleFor(widget.value.clamp(0.0, 1.0)),
    )..repeat();
  }

  @override
  void dispose() {
    _fog.dispose();
    _sweep.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 无障碍/测试静帧（MediaQuery.disableAnimations，如 course_flow_ui_test
    // 的 stillFrame 包装）：动画钉在初始相位——空态是静态灰面（雾带一在
    // 条外、雾带二居中成柔光），填充态是静态彩虹渐变，均不出动态。
    final still = MediaQuery.disableAnimationsOf(context);
    for (final c in [_fog, _sweep]) {
      if (still && c.isAnimating) c.stop();
      if (!still && !c.isAnimating) c.repeat();
    }
    return AnimatedBuilder(
      animation: _ticks,
      builder: (context, _) {
        // 进度变化（评分后刷新）时仅调整扫光流速，不重置动画相位。
        final p = widget.value.clamp(0.0, 1.0);
        if (_lastP != p) {
          _lastP = p;
          _sweep.duration = _cycleFor(p);
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            width: double.infinity,
            child: CustomPaint(
              painter: _RainbowProgressPainter(
                progress: p,
                trackColor: widget.trackColor,
                fogPhase: still ? 0.0 : _fog.value,
                sweepPhase: still ? 0.0 : _sweep.value,
              ),
            ),
          ),
        );
      },
    );
  }

  /// 扫光周期随进度插值：p=0 → 3.0s，p=1 → 4.6s（都远慢于旧版 1.2s 的
  /// 粒子急流，保留「低进度略急切」的旧语义但不刺眼）。变化时只改
  /// duration、不重置相位（评分刷新后不闪跳）。
  Duration _cycleFor(double p) => Duration(
    milliseconds: lerpDouble(3000, 4600, Curves.easeOut.transform(p))!.round(),
  );
}

class _RainbowProgressPainter extends CustomPainter {
  _RainbowProgressPainter({
    required this.progress,
    required this.trackColor,
    required this.fogPhase,
    required this.sweepPhase,
  });

  final double progress;
  final Color trackColor;

  /// 空态雾带相位（0..1，20s 一轮，与进度无关）。
  final double fogPhase;

  /// 填充段扫光相位（0..1，3.0~4.6s 一轮，随进度微调）。
  final double sweepPhase;

  // 类彩虹色谱：沿条长循环取色，红→橙→黄→绿→蓝→紫（HSL 色相环）。
  static Color _rainbow(double t) {
    final hsl = HSLColor.fromAHSL(1, (t % 1) * 360, 0.85, 0.6);
    return hsl.toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    const barRadius = Radius.circular(6);
    final trackRRect = RRect.fromRectAndRadius(Offset.zero & size, barRadius);
    // 空态底：不用 trackColor（浅色主题里偏白，会被读成「透明/缺口」），
    // 统一压成去饱和的中性灰面——对应「整体呈灰色」。
    final trackPaint = Paint()
      ..color = progress <= 0
          ? Color.alphaBlend(Colors.black.withValues(alpha: 0.10), trackColor)
          : trackColor;
    canvas.drawRRect(trackRRect, trackPaint);

    final w = size.width;
    final h = size.height;
    final filledW = w * progress;

    if (progress <= 0) {
      _paintFog(canvas, size);
      return;
    }

    // 已填充段：彩虹渐变底 + 一条软边高光带缓慢扫过（shimmer 手法）。
    canvas.save();
    canvas.clipRRect(
      RRect.fromRectAndRadius(Offset.zero & Size(filledW, h), barRadius),
    );
    final fillRect = Rect.fromLTWH(0, 0, filledW, h);
    final gradient = Paint()
      ..shader = LinearGradient(
        colors: [
          _rainbow(0.00),
          _rainbow(0.17),
          _rainbow(0.33),
          _rainbow(0.50),
          _rainbow(0.67),
          _rainbow(0.83),
          _rainbow(1.00),
        ],
      ).createShader(fillRect);
    canvas.drawRect(fillRect, gradient);
    _paintSweep(canvas, filledW, h);
    canvas.restore();
  }

  /// 填充段扫光（参考 hnvn/flutter_shimmer：平移一条软边渐变带，不用粒子）：
  /// 带宽 = max(填充宽 × 0.55, 14)，透明 → 峰值白 0.28 → 透明；
  /// 从条左外平移到条右外（行程 = 填充宽 + 2×带宽，两端带体完全在段外，
  /// 循环回卷无跳变）。带宽足够大 → 段上任何时刻都有柔和的明暗层次，
  /// 移动边缘柔和，低进度时也不再是「一堆闪烁小白点」。
  void _paintSweep(Canvas canvas, double filledW, double h) {
    final band = math.max(filledW * 0.55, 14.0);
    final cx = -band + sweepPhase * (filledW + band * 2);
    final rect = Rect.fromLTWH(cx - band / 2, 0, band, h);
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: 0.16),
          Colors.white.withValues(alpha: 0.28),
          Colors.white.withValues(alpha: 0.16),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  /// 零进度雾面：整体灰底之上叠两条极宽的灰白雾带，极缓慢横移
  /// （20s 一轮；两条相位错开 0.5、宽度 1.3× / 0.85×，形成纵深层次）。
  /// 峰值白仅 0.12 / 0.08 —— 观感仍是「整体灰」，只有极缓的明暗流动；
  /// 相位取模实现无缝循环（phase=0 时两条带体均在条外，静帧零残留）。
  void _paintFog(Canvas canvas, Size size) {
    _fogBand(canvas, size, phase: fogPhase, scale: 1.3, alpha: 0.12);
    _fogBand(
      canvas,
      size,
      phase: (fogPhase + 0.5) % 1.0,
      scale: 0.85,
      alpha: 0.08,
    );
  }

  /// 单条雾带：带宽 = 条宽 × scale（>1 保证条上始终有带体覆盖），
  /// 两端透明、中央峰值 alpha，从条左外平移到条右外。
  void _fogBand(
    Canvas canvas,
    Size size, {
    required double phase,
    required double scale,
    required double alpha,
  }) {
    final band = size.width * scale;
    final cx = -band + (phase % 1.0) * (size.width + band * 2);
    final rect = Rect.fromLTWH(cx - band / 2, 0, band, size.height);
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          Colors.white.withValues(alpha: 0.0),
          Colors.white.withValues(alpha: alpha),
          Colors.white.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_RainbowProgressPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.fogPhase != fogPhase ||
      oldDelegate.sweepPhase != sweepPhase ||
      oldDelegate.trackColor != trackColor;
}

/// 头部 streak 卡（参考设计稿：大数字 + 火焰）
///
/// 视觉层级：每日计划上线后，本页主角是「今日复习」进度卡（_TodayCard），
/// streak 降为历史陪衬——背景从 primaryContainer 改 surfaceContainerLow，
/// 火焰改描边图标弱化。口径注记：streak 与 /stats/today 的 done 同为
/// **本地自然日**口径（db.streakDays 按 reviewed_at 日期前缀从今天往回数，
/// 今日未复习不打断昨日 streak），两者数字不相矛盾、也不互相换算：
/// streak 答「连续多少天有复习」，today.done 答「今天完成多少张」——
/// 同屏并存无割裂（例：连续 4 天 + 今日 0/目标 50 = 昨天之前连着、今天还没开始）。
class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.streak, required this.scheme});

  final int streak;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(
              Icons.local_fire_department_outlined,
              size: 34,
              color: scheme.outline,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '连续打卡 $streak 天',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    streak == 0
                        ? '今天复习一次就开始累计'
                        : streak >= 7
                        ? '稳定习惯中，继续保持'
                        : '坚持 7 天形成习惯',
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.outline,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 未来 7 天到期预测（柱状图）
///
/// 对齐契约：图表区固定高 + Row(stretch) → 每列 = [Expanded 数字区 + 柱条 + 固定间距
/// + 标签]，数字区弹性吸收富余高度 → 柱底与标签行在 7 列严格同一水平线；数字贴柱
/// 顶、FittedBox 缩放兜底，0 值日 / 大数字 / 大字号均不错位、不截断。
/// （旧实现的错位根因：数字标注 + 柱高 + 间距逼近 120 上限时该列 Column 溢出，
/// RenderFlex 溢出后 MainAxisAlignment.end 退化、子项改从顶部排列，溢出列的标签
/// 被推出底边，与正常贴底列高低错开——即「柱状图有显示时下部文字不对齐」。）
class _ForecastCard extends StatelessWidget {
  const _ForecastCard({required this.data, required this.scheme});

  final List<DueForecastDay> data;
  final ColorScheme scheme;

  static const _weekdays = ['一', '二', '三', '四', '五', '六', '日'];

  /// 图表区总高：数字区(弹性，常态≥30) + 柱(≤84) + 间距 4 + 标签(~16)
  static const double _chartHeight = 136.0;
  static const double _barMaxHeight = 84.0;

  @override
  Widget build(BuildContext context) {
    final maxDue = data.fold<int>(0, (m, d) => d.due > m ? d.due : m);
    final total = data.fold<int>(0, (a, d) => a + d.due);
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '未来 7 天到期',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (total > 0)
                  Text(
                    '共 $total 张',
                    style: TextStyle(fontSize: 12, color: scheme.outline),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (data.isEmpty)
              _hint('暂无预测数据')
            else if (maxDue == 0)
              _hint('未来 7 天暂无到期卡，安心学新内容')
            else
              SizedBox(
                height: _chartHeight,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < data.length; i++) ...[
                      Expanded(child: _bar(i, data[i], maxDue)),
                      if (i != data.length - 1) const SizedBox(width: 8),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 空态文案行（固定高度，卡片不塌陷）
  Widget _hint(String text) => SizedBox(
    height: 44,
    child: Center(
      child: Text(text, style: TextStyle(fontSize: 13, color: scheme.outline)),
    ),
  );

  /// 单日柱列。服务端口径 data[0] 必为今天（逾期卡计入今天），故以 index 判定今明。
  Widget _bar(int index, DueForecastDay d, int maxDue) {
    final isToday = index == 0;
    final isTomorrow = index == 1;
    final zero = d.due == 0;
    final label = isToday
        ? '今天'
        : isTomorrow
        ? '明天'
        : _weekdayLabel(d.date);
    final barHeight = (d.due / maxDue * _barMaxHeight).clamp(
      4.0,
      _barMaxHeight,
    );

    return Column(
      children: [
        // 数字区：弹性高度、数字贴柱顶；超宽/超高时 FittedBox 自动缩小，永不截断换行
        Expanded(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${d.due}',
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: isToday ? FontWeight.w700 : FontWeight.w600,
                    color: zero
                        ? scheme.outline
                        : (isToday ? HengyaColors.brand : scheme.onSurface),
                  ),
                ),
              ),
            ),
          ),
        ),
        // 柱条：0 值日浅灰矮柱，非零日统一主色（brand）
        Container(
          height: barHeight,
          decoration: BoxDecoration(
            color: zero ? scheme.surfaceContainerHighest : scheme.primary,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(height: 4),
        // 标签行：各列同 fontSize 同行高 → 柱底严格对齐；今日品牌蓝胶囊仅着色不增高
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          decoration: isToday
              ? BoxDecoration(
                  color: HengyaColors.brand,
                  borderRadius: BorderRadius.circular(6),
                )
              : null,
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isToday
                  ? FontWeight.w700
                  : isTomorrow
                  ? FontWeight.w600
                  : FontWeight.w400,
              color: isToday
                  ? Colors.white
                  : isTomorrow
                  ? HengyaColors.textPrimary
                  : scheme.outline,
            ),
          ),
        ),
      ],
    );
  }

  String _weekdayLabel(String date) {
    final t = DateTime.tryParse(date);
    // 解析失败也要占位：保住标签行高，避免该列柱底与其他列错开
    if (t == null) return '·';
    return '周${_weekdays[t.weekday - 1]}';
  }
}

/// leech 弱卡榜
class _LeechCard extends StatelessWidget {
  const _LeechCard({required this.leech, required this.scheme});

  final List<FlashCard> leech;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  '弱卡榜',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'lapse ≥ 4',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
                const Spacer(),
                Text(
                  '${leech.length} 张',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (leech.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  '暂无痛觉卡，状态很好 👍',
                  style: TextStyle(fontSize: 13, color: scheme.outline),
                ),
              )
            else
              for (final c in leech.take(10))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(top: 2),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.errorContainer,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          // M5 动态科目：服务端/本地库名称优先，兜底原样 id
                          ApiClient.instance.subjectNameOf(c.subjectId),
                          style: TextStyle(
                            fontSize: 10,
                            color: scheme.onErrorContainer,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          c.front,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(message, style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
