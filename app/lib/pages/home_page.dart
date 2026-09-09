// 首页 —— 渐变 Hero 总览 + 六科目渐变卡（M3 视觉对齐设计稿）
// 数据：GET /subjects + /stats/streak + /stats/summary（三路并发）+
//       GET /progress（尽力而为第四路——罗盘表盘按钮进度弧/指针数据源；
//       拉不到 → 空表盘仍可点击，完整错误态由进度页兜底）
// M3：Hero 右上角关键词收件箱入口（上课随手记重点 → 22:55 自动化拆卡）
// 1.4.0+5：Hero 右上角新增「学习进度」入口（§7.5 学习罗盘 → /progress）
// 2026-09-06：学习进度入口重设计为罗盘表盘按钮（刻度环 + 进度弧 + 指针，
//       widgets/compass_dial_button.dart）——与「进度+罗盘」主题契合。
// 动效基调（2026-09-06 用户拍板「随机可变动态色彩」；2026-09-07 节点⑧
// 改版海浪）：Hero 渐变上是「多层正弦海浪涌动」（AuroraAmbient）——四层
// 柔彩波面自远而近层叠缓涌，传播方向与各层振幅/波长/速度在构建时随机
// 摇定（seed 可注入复现），单波周期 9~36s、潮汐/色相极慢呼吸，详见
// widgets/aurora_ambient.dart 头注释；与进度页「漂浮气泡」刻意区隔。
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
import 'inbox_sheet.dart';

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
    learned += p.learnedThrough;
    total += p.total;
  }
  return total > 0 ? (learned / total).clamp(0.0, 1.0).toDouble() : 0.0;
}

/// 首页四路数据快照：数据 + 整体离线态（cacheAt != null = 全部/部分来自缓存）
class _HomeSnapshot {
  const _HomeSnapshot({
    required this.subjects,
    required this.streak,
    required this.summary,
    required this.compassFraction,
    this.cacheAt,
  });

  final List<SubjectWithDue> subjects;
  final int streak;
  final StatsSummary summary;

  /// 罗盘总进度 0.0~1.0（罗盘表盘按钮数据源；0 = 拉不到 → 空表盘）
  final double compassFraction;
  final DateTime? cacheAt; // null = 新鲜数据；非 null = 有端点走了缓存回退
}

class _HomePageState extends State<HomePage> {
  /// 四路并发数据 future：缓存于 state，FutureBuilder 不再每帧重建 future
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
    ]);
    return _HomeSnapshot(
      subjects: results[0] as List<SubjectWithDue>,
      streak: results[1] as int,
      summary: results[2] as StatsSummary,
      compassFraction: results[3] as double,
      // 罗盘第四路刻意不计入离线态旁路检查：它是装饰性数据源，若只它
      // 命中缓存而三路主数据新鲜，不应误报「离线数据」提示条
      cacheAt: ApiClient.instance.latestCacheHitAmong([
        CacheKeys.subjects,
        CacheKeys.streak,
        CacheKeys.summary(7),
      ]),
    );
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

  /// 下拉刷新：重新发起四路并发并 setState 替换 future → 界面真正更新
  Future<void> _refresh() async {
    final next = _fetch();
    setState(() => _future = next);
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
                        // 引导用户经 Hero 右上「记课堂重点」内联新建第一门课程
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
                                    color:
                                        Theme.of(context).colorScheme.outline,
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

/// 渐变 Hero 头部：问候语 + 今日到期大数字 + 三玻璃胶囊
class _HeroHeader extends StatelessWidget {
  const _HeroHeader({
    required this.totalDue,
    required this.streak,
    required this.summary,
    required this.compassFraction,
  });

  final int totalDue;
  final int streak;
  final StatsSummary summary;

  /// 学习罗盘总进度（表盘按钮的进度弧/指针数据源）
  final double compassFraction;

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
                        // 学习罗盘表盘按钮：刻度环 + 进度弧 + 指针随罗盘
                        // 总进度走（点击整圈旋摆 → /progress）
                        CompassDialButton(
                          fraction: compassFraction,
                          onPressed: () => context.push('/progress'),
                        ),
                        const SizedBox(width: 8),
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
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '$totalDue',
                          style: const TextStyle(
                            fontSize: 42,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            height: 1.1,
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.only(bottom: 5, left: 4),
                          child: Text(
                            '张今日到期',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 10,
                      runSpacing: 8,
                      children: [
                        _GlassPill(
                          icon: Icons.rate_review_outlined,
                          label: '待审核 ${summary.pendingCards}',
                        ),
                        _GlassPill(
                          icon: Icons.local_fire_department_outlined,
                          label: '连续 $streak 天',
                        ),
                        _GlassPill(
                          icon: Icons.done_all_outlined,
                          label: '7 天复习 ${summary.totalReviews}',
                        ),
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
                                  ? HengyaColors.warning.withValues(
                                      alpha: 0.12,
                                    )
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
                      Text(
                        due > 0 ? '有 $due 张卡到期，去巩固一轮' : '暂无到期卡',
                        style: const TextStyle(
                          fontSize: 12,
                          color: HengyaColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
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
