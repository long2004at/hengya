// 统计页（M3）：streak + 打卡热力图 + 保留率 + 未来 7 天到期预测 + leech 弱卡榜
// 数据源：/api/v1/stats/{streak,heatmap,retention,forecast} + /cards/leech
// 离线韧性（问1+5）：五路读端点带缓存回退——断网时整页可用（含底部设置入口），
// 并显示「离线数据 · 更新于 HH:mm」提示条。
import 'package:flutter/material.dart';
import 'package:shared/hengya_shared.dart';

import '../services/api/api_client.dart';
import '../services/api/local_cache.dart';
import '../services/notification/daily_reminder.dart';
import '../theme.dart';
import '../widgets/offline_data_bar.dart';
import '../widgets/pipeline_queue_card.dart';
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

  /// #13：队列面板刷新信号（_load / pull-to-refresh 时自增——面板重读
  /// 「卡生成队列」当前态；与设置页 _corpusRev 同一模式）。
  final _queueRev = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _queueRev.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    _queueRev.value++; // #13：队列面板随本页刷新一起重读
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
                  _StreakCard(streak: _streak, scheme: scheme),
                  const SizedBox(height: 16),
                  // #13：卡生成队列面板（local 模式显示——流水线为端上
                  // local-first 链路，demo/remote 无此数据面）
                  if (currentBackendMode == BackendMode.local) ...[
                    PipelineQueueCard(rev: _queueRev),
                    const SizedBox(height: 16),
                  ],
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
/// 口径：窗口内 rating ≠ again 的复习占比（again 视为遗忘）
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

/// 头部 streak 卡（参考设计稿：大数字 + 火焰）
class _StreakCard extends StatelessWidget {
  const _StreakCard({required this.streak, required this.scheme});

  final int streak;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            const Text('🔥', style: TextStyle(fontSize: 36)),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '连续打卡 $streak 天',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: scheme.onPrimaryContainer,
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
                      color: scheme.onPrimaryContainer,
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
