// 首页 —— 渐变 Hero 总览 + 六科目渐变卡（M3 视觉对齐设计稿）
// 数据：GET /subjects + /stats/streak + /stats/summary（三路并发）+
//       GET /progress（尽力而为第四路——罗盘表盘按钮进度弧/指针数据源；
//       拉不到 → 空表盘仍可点击，完整错误态由进度页兜底）
// M3：Hero 右上角关键词收件箱入口（上课随手记重点 → 22:55 自动化拆卡）
// 2026-10-11 首页信息架构重构（单一大 CTA 主导 + 次要收纳，参考多邻国/
// 扇贝的「单主导」架构但保留恒牙 Hero 氛围）：
//   1. 顶部行只留「记课堂重点」（核心闭环）+ 罗盘表盘（动效特色）+
//      MoreVert 溢出菜单（收纳「语料库」「回炉工作台」，local 模式才显示）。
//   2. 三玻璃胶囊裁剪：连续天数保留（打卡心智）；待审核 >0 才显示；
//      7 天复习量移除（统计页已有）。
//   3. 大 CTA「开始今日复习」全宽主按钮（信息架构主角，home_today_cta.dart）：
//      数据源 GET /stats/today 四字段唯一口径（禁止另算），三态文案
//      未开始/进行中/已完成；拉不到 → 降级「开始今日复习」仍可点，
//      大数字回退 totalDue。Hero 大数字与 CTA 同口径展示 remainingToday。
//   4. 科目卡移除卡内语料按钮（语料入口已收进溢出菜单）；到期副文案
//      注明「全部到期」，与今日 CTA 的「今日任务」口径区分。
// 动效基调（2026-09-06 用户拍板「随机可变动态色彩」；2026-09-07 节点⑧
// 改版海浪；2026-10-11 重构为多波向多倍频）：Hero 渐变上是「多波向 ×
// 多倍频海浪涌动」（AuroraAmbient）——四层柔彩波面自远而近层叠缓涌，
// 每层 4 个波分量叠加（任意角波向、跨倍频波长、深水色散速度、二次谐波
// 陡峰 + 浪尖泡沫高光），层/分量参数在构建时随机摇定（seed 可注入复现），
// 单波周期 7.2~36s、潮汐/色相极慢呼吸，详见 widgets/aurora_ambient.dart
// 头注释；与进度页「漂浮气泡」刻意区隔。
// 信息明确硬约束（同进度页）：装饰层垫底 + IgnorePointer + 柔光峰值 alpha
// 合计 ≤ 0.15 + RepaintBoundary 隔离重绘 + disableAnimations → 静止一帧。
// #14（P3，2026-09-07 真机反馈「蓝屏观感仍近静态」）：在海浪①之上叠加
// 「shimmer 扫光」②（HeroShimmer，widgets/hero_shimmer.dart）——低透明度
// 白色高光带 6s 一轮沿对角缓慢扫过 Hero（峰值 alpha 0.08，移动边缘对动效
// 感知的增益远高于静态柔光）；仍守「装饰层垫底 + IgnorePointer +
// RepaintBoundary + disableAnimations 光带出屏零残留」口径。动效参数待
// 真机复查微调。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../services/api/api_client.dart';
import '../services/api/demo_backend.dart';
import '../services/api/local_cache.dart';
import '../theme.dart';
import '../widgets/aurora_ambient.dart';
import '../widgets/compass_dial_button.dart';
import '../widgets/hero_shimmer.dart';
import '../widgets/offline_data_bar.dart';
import 'home_today_cta.dart';
import 'inbox_sheet.dart';
import 'corpus_library_page.dart';
import 'rework_workbench_page.dart';
import 'chat_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

/// 学习罗盘总进度（0.0~1.0）：有罗盘科目（textbook 非空）的
/// learned_through/total 汇总——与进度页 Hero「N/M 章已学」同口径；
/// 无罗盘科目（textbook=null，如 derm 占位）不参与；total=0 防除零。
double compassFractionOf(ProgressOverview progress) {
  var learned = 0;
  var total = 0;
  for (final p in progress.subjects) {
    if (!p.hasTextbook) continue;
    // #1：有效口径（与进度页 Hero 一致——原始指针在稀疏编号下可越界）
    learned += p.displayLearned;
    total += p.displayTotal;
  }
  return total > 0 ? (learned / total).clamp(0.0, 1.0).toDouble() : 0.0;
}

/// 首页五路数据快照：数据 + 整体离线态（cacheAt != null = 全部/部分来自缓存）
class _HomeSnapshot {
  const _HomeSnapshot({
    required this.subjects,
    required this.streak,
    required this.summary,
    required this.compassFraction,
    required this.today,
    this.cacheAt,
  });

  final List<SubjectWithDue> subjects;
  final int streak;
  final StatsSummary summary;

  /// 罗盘总进度 0.0~1.0（罗盘表盘按钮数据源；0 = 拉不到 → 空表盘）
  final double compassFraction;

  /// 今日进度四字段（/stats/today 唯一口径，大 CTA 与 Hero 大数字数据源；
  /// null = 拉不到 → CTA 与大数字走降级，与罗盘第四路同「尽力而为」）
  final TodayProgress? today;
  final DateTime? cacheAt; // null = 新鲜数据；非 null = 有端点走了缓存回退
}

class _HomePageState extends State<HomePage> {
  /// 五路并发数据 future：缓存于 state，FutureBuilder 不再每帧重建 future
  late Future<_HomeSnapshot> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  Future<_HomeSnapshot> _fetch() async {
    final results = await Future.wait([
      ApiClient.instance.fetchSubjects(),
      ApiClient.instance.fetchStreak(),
      ApiClient.instance.fetchSummary(),
      _fetchCompassFraction(), // 尽力而为第四路：永不抛错
      _fetchToday(), // 尽力而为第五路：大 CTA / Hero 大数字数据源，永不抛错
    ]);
    // 科目卡按剩余待复习数降序（dueCount 多的排前面）；并列时保持 /subjects
    // 接口原序（Dart sort 非稳定，索引兜底保证确定性行为）
    final raw = results[0] as List<SubjectWithDue>;
    final subjects =
        List<(int, SubjectWithDue)>.generate(
            raw.length, (i) => (i, raw[i]),
          )..sort((a, b) {
            final byDue = b.$2.dueCount.compareTo(a.$2.dueCount);
            return byDue != 0 ? byDue : a.$1.compareTo(b.$1);
          });
    return _HomeSnapshot(
      subjects: [for (final (_, s) in subjects) s],
      streak: results[1] as int,
      summary: results[2] as StatsSummary,
      compassFraction: results[3] as double,
      today: results[4] as TodayProgress?,
      // 罗盘/今日两路尽力而为数据刻意不计入离线态旁路检查：装饰性与
      // 增强性数据源，若只它们命中缓存而三路主数据新鲜，不应误报「离线
      // 数据」提示条
      cacheAt: ApiClient.instance.latestCacheHitAmong([
        CacheKeys.subjects,
        CacheKeys.streak,
        CacheKeys.summary(7),
      ]),
    );
  }

  /// 今日进度（尽力而为，仿 [_fetchCompassFraction] 写法）：拉不到（断网 /
  /// 旧服务器 404 / remote 模式未升级）→ null 降级——CTA 退「开始今日
  /// 复习」仍可点击进会话页（页面自会兜底错误态），绝不阻断三路主数据。
  /// 今日两端点刻意不走离线缓存（上游决策：缓存会把旧进度当成今天的事实）。
  Future<TodayProgress?> _fetchToday() async {
    try {
      return await ApiClient.instance.fetchTodayStats();
    } on ApiException {
      return null;
    }
  }

  /// 罗盘总进度（尽力而为）：拉不到（断网且无缓存 / 旧服务器 404 /
  /// progress.json 未推送）→ 0 空表盘——按钮仍可点击进进度页，完整
  /// 错误态由进度页兜底，绝不阻断首页三路主数据。
  Future<double> _fetchCompassFraction() async {
    try {
      return compassFractionOf(await ApiClient.instance.fetchProgress());
    } on ApiException {
      return 0;
    }
  }

  /// 下拉刷新：重新发起五路并发并 setState 替换 future → 界面真正更新
  /// （注意 setState 回调必须块体：箭头体会把 Future 当返回值触发断言）
  Future<void> _refresh() async {
    final next = _fetch();
    setState(() {
      _future = next;
    });
    await next;
  }

  @override
  Widget build(BuildContext context) {
    // Hero 延伸到状态栏后（edge-to-edge）：深蓝底 → 白色状态栏图标
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light, // Android：白图标
        statusBarBrightness: Brightness.dark, // iOS：深底 → 白图标
      ),
      child: Scaffold(
        body: FutureBuilder<_HomeSnapshot>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              // 离线且无缓存也可下拉/点按钮重试
              return RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    const SizedBox(height: 120),
                    _OfflineBanner(onRetry: _refresh, error: snap.error),
                  ],
                ),
              );
            }
            final data = snap.data!;
            final subjects = data.subjects;
            final totalDue = subjects.fold<int>(0, (a, s) => a + s.dueCount);
            return RefreshIndicator(
              onRefresh: _refresh,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: EdgeInsets.zero,
                children: [
                  _HeroHeader(
                    totalDue: totalDue,
                    streak: data.streak,
                    summary: data.summary,
                    compassFraction: data.compassFraction,
                    today: data.today,
                    onReviewReturned: _refresh,
                  ),
                  // 离线缓存回退提示条（数据来自缓存时可见；置于 Hero 与科目卡
                  // 之间的常规列表流，不触碰 Hero 内部的氛围层与信息层级）
                  if (data.cacheAt != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                      child: OfflineDataBar(savedAt: data.cacheAt),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                    child: Column(
                      children: [
                        for (final s in subjects) _SubjectCard(item: s),
                        // 首启空库语义（0.3.1 开源去内置）：新库零科目——
                        // 引导用户经 Hero 顶部「记课堂重点」内联新建第一门课程
                        if (subjects.isEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.menu_book_outlined,
                                  size: 40,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                                const SizedBox(height: 10),
                                const Text(
                                  '还没有课程',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '点右上角「记课堂重点」新建第一门课程',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.outline,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({required this.onRetry, this.error});

  final Future<void> Function() onRetry;

  /// local 模式下展示真实错误（bank 页同款：不掩盖——2026-09-06 真机问题）
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final local = currentBackendMode == BackendMode.local;
    return Center(
      child: Column(
        children: [
          Icon(
            Icons.wifi_off_outlined,
            size: 48,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(height: 12),
          Text(
            local ? '本地数据加载失败' : '连不上服务器',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            local ? '错误信息：$error' : '检查网络后下拉刷新',
            style: const TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 16),
          FilledButton.tonal(
            onPressed: () => onRetry(),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// 渐变 Hero 头部：问候语 + 今日大数字（与 CTA 同口径）+ 大 CTA + 玻璃胶囊。
/// Stateful：大 CTA push 会话页返回后回调 State 的 _refresh 重拉今日数据
/// （评分改变 done → CTA 三态与 Hero 大数字同步刷新）。
class _HeroHeader extends StatefulWidget {
  const _HeroHeader({
    required this.totalDue,
    required this.streak,
    required this.summary,
    required this.compassFraction,
    required this.today,
    required this.onReviewReturned,
  });

  /// 科目到期汇总（旧「今日到期」口径）——today 拉不到时大数字回退值
  final int totalDue;
  final int streak;
  final StatsSummary summary;

  /// 学习罗盘总进度（表盘按钮的进度弧/指针数据源）
  final double compassFraction;

  /// 今日进度四字段（/stats/today 唯一口径）；null = 降级（大数字回退
  /// totalDue，CTA 退「开始今日复习」，见 home_today_cta.dart 注释）
  final TodayProgress? today;

  /// 今日复习会话页 pop 返回后的回调（HomePage._refresh 重拉五路，
  /// 刷新 CTA 三态与 Hero 大数字——评分后的服务端账本已更新）
  final Future<void> Function() onReviewReturned;

  @override
  State<_HeroHeader> createState() => _HeroHeaderState();
}

class _HeroHeaderState extends State<_HeroHeader> {
  String get _greeting {
    final h = DateTime.now().hour;
    if (h < 6) return '夜深了';
    if (h < 12) return '早上好';
    if (h < 18) return '下午好';
    return '晚上好';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: kHeroGradient,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(24)),
      ),
      // 裁剪氛围层：圆角与 decoration 一致（原 child 未裁剪，不影响布局
      // 尺寸与视觉基线；仅装饰层需要被圆角裁掉出血，参考进度页先例）
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
        child: Stack(
          children: [
            // 氛围层垫底（Stack 首位）：信息 Widget 全画其上，不遮挡不干扰
            const Positioned.fill(
              child: AuroraAmbient(key: ValueKey('home-aurora-ambient')),
            ),
            // #14 扫光层（②）：叠于海浪①之上、信息层之下（同垫底口径）——
            // 低透明度白色高光带缓慢扫过蓝屏（单带 6s 一轮，参数与「动效
            // 参数待真机复查微调」注释详见 widgets/hero_shimmer.dart）
            const Positioned.fill(
              child: HeroShimmer(key: ValueKey('home-hero-shimmer')),
            ),
            SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text(
                          '恒牙',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        if (DemoBackend.enabled) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              '演示模式',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                        // 溢出菜单（次要收纳）：语料库 / 回炉工作台——
                        // local 模式专属能力才进菜单（remote 无此二功能）；
                        // 菜单项带图标与文字，样式同右上玻璃圆钮
                        if (currentBackendMode == BackendMode.local)
                          Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              shape: BoxShape.circle,
                            ),
                            child: PopupMenuButton<String>(
                              tooltip: '更多功能',
                              icon: const Icon(
                                Icons.more_vert,
                                color: Colors.white,
                                size: 22,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                              onSelected: (value) =>
                                  Navigator.of(context, rootNavigator: true).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) => value == 'corpus'
                                          ? const CorpusLibraryPage()
                                          : const ReworkWorkbenchPage(),
                                    ),
                                  ),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'corpus',
                                  child: ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.folder_copy_outlined),
                                    title: Text('语料库'),
                                  ),
                                ),
                                PopupMenuItem(
                                  value: 'rework',
                                  child: ListTile(
                                    dense: true,
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(Icons.build_circle_outlined),
                                    title: Text('回炉工作台'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        // 学习罗盘表盘按钮：刻度环 + 进度弧 + 指针随罗盘
                        // 总进度走（点击整圈旋摆 → /progress）
                        CompassDialButton(
                          fraction: widget.compassFraction,
                          onPressed: () => context.push('/progress'),
                        ),
                        const SizedBox(width: 8),
                        // AI 问答入口（P2.3 聊天页）：与收件箱同款玻璃圆钮
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            tooltip: 'AI 问答',
                            icon: const Icon(
                              Icons.forum_outlined,
                              color: Colors.white,
                              size: 22,
                            ),
                            onPressed: () =>
                                Navigator.of(context, rootNavigator: true).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => const ChatPage(),
                                  ),
                                ),
                          ),
                        ),
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.18),
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            tooltip: '记课堂重点（今晚自动拆卡）',
                            icon: const Icon(
                              Icons.edit_note,
                              color: Colors.white,
                              size: 22,
                            ),
                            onPressed: () => showInboxSheet(context),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    Text(
                      '$_greeting · 今天也要巩固记忆',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Hero 大数字（与 CTA 同口径，见 todayHeroNumber 注释）：
                    // 有 today → remainingToday（今日还剩）；降级 → totalDue。
                    // 副文案随口径切换，绝不出现「按钮说 5 大数字却是 23」。
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${todayHeroNumber(widget.today, widget.totalDue)}',
                          style: const TextStyle(
                            fontSize: 42,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1.1,
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(bottom: 5, left: 4),
                          child: Text(
                            widget.today != null ? '张今日还剩' : '张今日到期',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    // 大 CTA（信息架构主角）：三态文案 + 降级由
                    // TodayCtaButton / todayCtaLabel 统一处理；
                    // push 返回后回调 onReviewReturned 重拉五路
                    // （评分改变 done → CTA/大数字刷新）
                    TodayCtaButton(
                      today: widget.today,
                      fallbackDue: widget.totalDue,
                      onPressed: () async {
                        await context.push('/review/today');
                        await widget.onReviewReturned();
                      },
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        // 待审核：仅 >0 才占一胶囊位（0 是常态，不占视觉）
                        if (widget.summary.pendingCards > 0)
                          _GlassPill(
                            icon: Icons.rate_review_outlined,
                            label: '待审核 ${widget.summary.pendingCards}',
                          ),
                        // 连续天数：打卡心智保留显性
                        _GlassPill(
                          icon: Icons.local_fire_department_outlined,
                          label: '连续 ${widget.streak} 天',
                        ),
                        // 7 天复习量胶囊已移除（2026-10-11 重构）：统计页已有
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 玻璃拟态胶囊（白 16% 底 + 白 28% 描边）
class _GlassPill extends StatelessWidget {
  const _GlassPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.white),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 科目卡：六色渐变图标 + 考试课橙标签 + 到期数
class _SubjectCard extends StatelessWidget {
  const _SubjectCard({required this.item});

  final SubjectWithDue item;

  @override
  Widget build(BuildContext context) {
    final s = item.subject;
    final grad = HengyaColors.gradientOf(s.id);
    final due = item.dueCount;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: kCardSoftShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => context.push('/review-home/${s.id}'),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(colors: grad),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(subjectIcon(s.id), color: Colors.white, size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: HengyaColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: s.isExamSubject
                                  ? HengyaColors.warning.withValues(alpha: 0.12)
                                  : HengyaColors.textSecondary.withValues(
                                      alpha: 0.10,
                                    ),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              s.isExamSubject ? '考试课' : '考查课',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: s.isExamSubject
                                    ? HengyaColors.warning
                                    : HengyaColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      // 副文案口径区分（2026-10-11 重构）：这里是「全部到期」
                      // 存量（/subjects 的 dueCount），与大 CTA 的「今日任务」
                      // （/stats/today 的 remainingToday=目标截断后）刻意区分，
                      // 避免两个数字打架
                      Text(
                        due > 0 ? '全部到期 $due 张，去巩固一轮' : '暂无到期卡',
                        style: const TextStyle(
                          fontSize: 12,
                          color: HengyaColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                // 卡内语料按钮已移除（2026-10-11 重构）：语料入口收进顶部
                // 溢出菜单；整卡点击进科目会话不变
                const SizedBox(width: 8),
                if (due > 0)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '$due',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: HengyaColors.brand,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 2, left: 2),
                        child: Text(
                          '张',
                          style: TextStyle(
                            fontSize: 11,
                            color: HengyaColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  const Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: HengyaColors.divider,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
