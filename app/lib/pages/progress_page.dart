// 学习进度页（§7.5，App 1.4.0+5）：学习罗盘只读端点的移动端触达
//
// 数据：GET /api/v1/progress（各科 learned_through/total/下一章）+
//       GET /api/v1/subjects（现成复习队列统计 dueCount）——App 端组合，
//       服务端无组合端点（§7.5 拍板）。
// 状态：加载 / 旧服务器 404 →「需服务器 0.3.0+，暂未部署」/ 其他错误 → 重试 /
//       空态（subjects 空 = progress.json 未推送）→ 引导文案。
// UI 基调（用户拍板口径）：契合 HengyaColors 主题；页头渐变底上「一点点」
// 缓慢漂浮的半透明气泡氛围层；**信息明确为硬约束**——动效只做氛围层：
//   1. 气泡是纯装饰 CustomPainter，画在 Stack 最底层（内容之上、气泡之下），
//      不参与命中测试（IgnorePointer），不遮挡任何文字；
//   2. 气泡一律半透明白（alpha ≤ 0.10），对文字对比度影响可忽略；
//   3. MediaQuery.disableAnimations（系统「移除动画」/低性能模式）→ 氛围层
//      静止（不启动控制器，只绘一帧静态气泡），信息层完全不受影响。
// 验收条款：无罗盘科目（textbook=null，如 derm）不出现在任何复习提示。
// 离线韧性（问1+5）：progress/subjects 带缓存回退——断网时罗盘照常可读，
// 并显示「离线数据 · 更新于 HH:mm」提示条。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/api/api_client.dart';
import '../services/api/local_cache.dart';
import '../theme.dart';
import '../widgets/offline_data_bar.dart';
import 'chapter_manager_sheet.dart';

class ProgressPage extends StatefulWidget {
  const ProgressPage({super.key});

  @override
  State<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends State<ProgressPage> {
  bool _loading = true;
  bool _unsupported = false; // 旧服务器（0.2.0）404 → 需 0.3.0+
  String? _error;
  ProgressOverview? _progress;
  DateTime? _cacheAt; // 非 null = 罗盘/队列统计来自离线缓存回退

  // 复习队列统计（各科 dueCount，尽力而为）：拉不到 → 联动卡降级为仅下一章预告
  Map<String, int> _dueOf = const {};
  bool _queueStatsAvailable = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _unsupported = false;
    });
    try {
      final progress = await ApiClient.instance.fetchProgress();
      var dueOf = const <String, int>{};
      var queueOk = false;
      try {
        final subjects = await ApiClient.instance.fetchSubjects();
        dueOf = {for (final s in subjects) s.subject.id: s.dueCount};
        queueOk = true;
      } on ApiException {
        // 复习队列统计尽力而为：不阻断进度页主体
      }
      if (!mounted) return;
      setState(() {
        _progress = progress;
        _dueOf = dueOf;
        _queueStatsAvailable = queueOk;
        _cacheAt = ApiClient.instance.latestCacheHitAmong([
          CacheKeys.progress,
          CacheKeys.subjects,
        ]);
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _unsupported = e.statusCode == 404;
        _error = currentBackendMode == BackendMode.local
            ? '本地数据加载失败：${e.message}'
            : (e.statusCode == 0 ? '连不上服务器' : '加载失败（${e.statusCode}）');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = _progress;
    return Scaffold(
      appBar: AppBar(
        title: const Text('学习进度'),
        actions: [
          IconButton(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _unsupported
          ? _MessageView(
              icon: Icons.cloud_off_outlined,
              title: '需服务器 0.3.0+，暂未部署',
              subtitle: '当前服务器版本过低，暂无学习进度端点',
              onRetry: _load,
            )
          : _error != null
          ? _MessageView(
              icon: Icons.wifi_off_outlined,
              title: _error!,
              subtitle: currentBackendMode == BackendMode.local
                  ? '数据在本机：重试通常可恢复'
                  : '检查网络后重试',
              onRetry: _load,
            )
          : progress == null || progress.subjects.isEmpty
          ? _MessageView(
              icon: Icons.explore_outlined,
              title: '暂无学习进度数据',
              // local：罗盘数据在本机（files/corpus/progress.json），无「推送
              // 服务器」一说——语料入库后自动生成（2026-09-06 真机问题：远程
              // 残留文案误导用户）
              subtitle: currentBackendMode == BackendMode.local
                  ? '学习罗盘数据尚未在本机生成\n'
                        '语料入库后自动生成，此后随拆卡流水线推进'
                  : '学习罗盘（progress.json）尚未推送到服务器\n'
                        '首次语料推送后自动生成，此后每日随拆卡流水线推进',
              onRetry: _load,
            )
          : _LoadedView(
              progress: progress,
              dueOf: _dueOf,
              queueStatsAvailable: _queueStatsAvailable,
              cacheAt: _cacheAt,
              onRefresh: _load,
            ),
    );
  }
}

/// 正常态：页头罗盘总览（气泡氛围层）→「今天该复习什么」联动卡 → 各科进度行
class _LoadedView extends StatelessWidget {
  const _LoadedView({
    required this.progress,
    required this.dueOf,
    required this.queueStatsAvailable,
    required this.cacheAt,
    required this.onRefresh,
  });

  final ProgressOverview progress;
  final Map<String, int> dueOf;
  final bool queueStatsAvailable;
  final DateTime? cacheAt; // 非 null = 有端点走了离线缓存回退
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    // 全名链：服务端目录 → 13 科中文兜底（罗盘科目可能未进 subjects 表，
    // 此前直出英文 id——2026-09-05 真机问题 2）→ 短名 → id
    final nameOf = ApiClient.instance.subjectFullNameOf;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          if (cacheAt != null) ...[
            OfflineDataBar(savedAt: cacheAt),
            const SizedBox(height: 16),
          ],
          _ProgressHeroCard(progress: progress),
          const SizedBox(height: 16),
          _TodayCard(
            progress: progress,
            dueOf: dueOf,
            queueStatsAvailable: queueStatsAvailable,
            nameOf: nameOf,
          ),
          const SizedBox(height: 16),
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 10),
            child: Text(
              '各科进度',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: HengyaColors.textSecondary,
              ),
            ),
          ),
          for (final p in progress.subjects)
            _SubjectProgressCard(
              p: p,
              nameOf: nameOf,
              onRefresh: onRefresh,
            ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// 页头罗盘总览：品牌渐变底 + 气泡氛围层（下）+ 总览信息（上）
class _ProgressHeroCard extends StatelessWidget {
  const _ProgressHeroCard({required this.progress});

  final ProgressOverview progress;

  @override
  Widget build(BuildContext context) {
    final compass = progress.subjects.where((p) => p.hasTextbook).toList();
    // #1（2026-09-13）：展示用有效口径（正文章计数）——原始指针在稀疏
    // 编号下可越过列表长度（「已学 > 总量」）
    final learned = compass.fold<int>(0, (a, p) => a + p.displayLearned);
    final total = compass.fold<int>(0, (a, p) => a + p.displayTotal);
    final started = compass.where((p) => p.displayLearned > 0).length;

    return Container(
      decoration: const BoxDecoration(
        gradient: kHeroGradient,
        borderRadius: BorderRadius.all(Radius.circular(20)),
        boxShadow: kCardSoftShadow,
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        child: Stack(
          children: [
            // 氛围层垫底：信息 Widget 全部在其上（Stack 顺序），不遮挡
            const Positioned.fill(
              child: _BubbleAmbient(key: ValueKey('progress-bubble-ambient')),
            ),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '学习罗盘',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      _UpdatedChip(updatedAt: progress.updatedAt),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '$learned / $total',
                        style: const TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          height: 1.05,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.only(bottom: 3, left: 6),
                        child: Text(
                          '章已学',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: LinearProgressIndicator(
                      value: total > 0 ? learned / total : 0,
                      minHeight: 8,
                      backgroundColor: Colors.white.withValues(alpha: 0.24),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      _GlassPill(
                        icon: Icons.auto_stories_outlined,
                        label: '罗盘科目 ${compass.length} 科',
                      ),
                      _GlassPill(
                        icon: Icons.school_outlined,
                        label: '已开学 $started 科',
                      ),
                    ],
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

/// 罗盘更新时间胶囊（玻璃拟态，同首页风格）
class _UpdatedChip extends StatelessWidget {
  const _UpdatedChip({required this.updatedAt});

  final DateTime? updatedAt;

  String get _label {
    final at = updatedAt;
    if (at == null) return '尚未更新';
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    return '更新于 ${at.month}月${at.day}日 $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
      ),
      child: Text(
        _label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 玻璃拟态胶囊（白 16% 底 + 白 28% 描边，同首页 _GlassPill）
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

/// 气泡氛围层（§7.5 UI 基调：缓慢漂浮的半透明气泡，纯装饰）。
/// 「信息明确」硬约束的落地见文件头注释；disableAnimations → 静止一帧。
class _BubbleAmbient extends StatefulWidget {
  const _BubbleAmbient({super.key});

  @override
  State<_BubbleAmbient> createState() => _BubbleAmbientState();
}

class _BubbleAmbientState extends State<_BubbleAmbient>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 26), // 一整个循环很慢：速度≤一点点的氛围
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 系统关闭动效（无障碍「移除动画」/低性能模式）→ 氛围层静止
    if (MediaQuery.of(context).disableAnimations) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = MediaQuery.of(context).disableAnimations;
    return IgnorePointer(
      child: RepaintBoundary(
        child: disabled
            ? const CustomPaint(painter: _BubblePainter(0), size: Size.infinite)
            : AnimatedBuilder(
                animation: _controller,
                builder: (context, _) => CustomPaint(
                  painter: _BubblePainter(_controller.value),
                  size: Size.infinite,
                ),
              ),
      ),
    );
  }
}

/// 气泡绘制：固定种子（确定性渲染），白 alpha ≤ 0.10，自下而上缓慢漂浮
class _BubblePainter extends CustomPainter {
  const _BubblePainter(this.t);

  final double t; // 0.0~1.0 循环相位

  static const _bubbles =
      <({double x, double r, double speed, double phase, double alpha})>[
        (x: 0.08, r: 30.0, speed: 0.62, phase: 0.05, alpha: 0.05),
        (x: 0.24, r: 14.0, speed: 0.85, phase: 0.42, alpha: 0.07),
        (x: 0.40, r: 42.0, speed: 0.50, phase: 0.70, alpha: 0.04),
        (x: 0.56, r: 10.0, speed: 1.00, phase: 0.18, alpha: 0.09),
        (x: 0.70, r: 22.0, speed: 0.75, phase: 0.88, alpha: 0.06),
        (x: 0.86, r: 34.0, speed: 0.55, phase: 0.30, alpha: 0.05),
        (x: 0.16, r: 8.0, speed: 0.95, phase: 0.60, alpha: 0.10),
        (x: 0.64, r: 16.0, speed: 0.68, phase: 0.12, alpha: 0.07),
        (x: 0.94, r: 12.0, speed: 0.80, phase: 0.78, alpha: 0.08),
      ];

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final paint = Paint();
    for (final b in _bubbles) {
      final cycle = (t * b.speed + b.phase) % 1.0;
      // 从底部缓浮出顶部（1.12 → -0.16：头尾留缓冲，循环无缝）
      final y = size.height * (1.12 - cycle * 1.28);
      final sway = math.sin(cycle * 2 * math.pi) * size.width * 0.02;
      paint.color = Colors.white.withValues(alpha: b.alpha);
      canvas.drawCircle(Offset(size.width * b.x + sway, y), b.r, paint);
    }
  }

  @override
  bool shouldRepaint(_BubblePainter oldDelegate) => oldDelegate.t != t;
}

/// 「今天该复习什么」联动卡（§7.5 要素 2）：
/// App 端组合罗盘进度 × 复习队列统计（dueCount）——按已学范围给当日提示，
/// 外加下一章预告。硬约束：无罗盘科目（textbook=null）不出现在任何复习提示。
class _TodayCard extends StatelessWidget {
  const _TodayCard({
    required this.progress,
    required this.dueOf,
    required this.queueStatsAvailable,
    required this.nameOf,
  });

  final ProgressOverview progress;
  final Map<String, int> dueOf;
  final bool queueStatsAvailable;
  final String Function(String id) nameOf;

  @override
  Widget build(BuildContext context) {
    // 复习提示：罗盘科目 × 到期数 > 0（derm 等无罗盘科目天然被排除）
    final reviewRows = [
      for (final p in progress.subjects)
        if (p.hasTextbook && (dueOf[p.id] ?? 0) > 0)
          (name: nameOf(p.id), due: dueOf[p.id]!),
    ];
    // 下一章预告：罗盘科目且有下一章（学完的不再预告）
    final previewRows = [
      for (final p in progress.subjects)
        if (p.hasTextbook && p.nextChapter != null)
          (name: nameOf(p.id), chapter: p.nextChapter!.display),
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: kCardSoftShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: HengyaColors.brand.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(
                  Icons.today_outlined,
                  size: 15,
                  color: HengyaColors.brand,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                '今天该复习什么',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: HengyaColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (!queueStatsAvailable)
            const Text(
              '复习队列统计暂不可用，可下拉刷新重试',
              style: TextStyle(
                fontSize: 12.5,
                color: HengyaColors.textSecondary,
              ),
            )
          else if (reviewRows.isEmpty)
            const Row(
              children: [
                Icon(
                  Icons.task_alt_outlined,
                  size: 15,
                  color: HengyaColors.success,
                ),
                SizedBox(width: 6),
                Text(
                  '今天没有到期复习卡',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: HengyaColors.success,
                  ),
                ),
              ],
            )
          else
            for (final r in reviewRows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    const Icon(
                      Icons.adjust,
                      size: 13,
                      color: HengyaColors.brand,
                    ),
                    const SizedBox(width: 7),
                    Text(
                      r.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: HengyaColors.textPrimary,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${r.due} 张卡到期，去巩固一轮',
                      style: const TextStyle(
                        fontSize: 12.5,
                        color: HengyaColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
          if (previewRows.isNotEmpty) ...[
            const Divider(
              height: 22,
              thickness: 1,
              color: HengyaColors.divider,
            ),
            const Text(
              '下一章预告',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: HengyaColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            for (final r in previewRows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.menu_book_outlined,
                      size: 13,
                      color: HengyaColors.brand,
                    ),
                    const SizedBox(width: 7),
                    Flexible(
                      child: Text.rich(
                        TextSpan(
                          text: '${r.name}：',
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: HengyaColors.textPrimary,
                          ),
                          children: [
                            TextSpan(
                              text: r.chapter,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w400,
                                color: HengyaColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// 单科进度行：科目名（subjectNameOf 链）+ 进度条 + 下一章；
/// 学完 → 绿色完成态；textbook=null → 标注「未配置教材」（不出现在复习提示）。
/// ⑨ 章节管理入口：罗盘科目（hasTextbook）行尾常驻按钮 → 弹层手动推进/
/// 回退/标记不学。
class _SubjectProgressCard extends StatelessWidget {
  const _SubjectProgressCard({
    required this.p,
    required this.nameOf,
    required this.onRefresh,
  });

  final SubjectProgress p;
  final String Function(String id) nameOf;
  final Future<void> Function() onRefresh; // 章节管理写后刷新罗盘

  @override
  Widget build(BuildContext context) {
    final grad = HengyaColors.gradientOf(p.id);
    final showNumbers = p.hasTextbook && p.total > 0;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: kCardSoftShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: grad),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(subjectIcon(p.id), color: Colors.white, size: 20),
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
                            nameOf(p.id),
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
                        if (p.hasTextbook && p.completed)
                          _tag('已学完', HengyaColors.success)
                        else if (!p.hasTextbook)
                          _tag('未配置教材', HengyaColors.textSecondary),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      p.textbook ?? '暂无学习罗盘',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11,
                        color: HengyaColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (showNumbers)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      // #1：有效口径展示（指针在稀疏编号下可越过列表长度）
                      '${p.displayLearned}/${p.displayTotal}',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: HengyaColors.brand,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${(p.fraction * 100).round()}%',
                      style: const TextStyle(
                        fontSize: 11,
                        color: HengyaColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              if (p.hasTextbook)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '章节管理',
                  onPressed: () => showChapterManagerSheet(
                    context,
                    p: p,
                    subjectName: nameOf(p.id),
                    onChanged: onRefresh,
                  ),
                  icon: const Icon(
                    Icons.format_list_numbered,
                    size: 20,
                    color: HengyaColors.textSecondary,
                  ),
                ),
            ],
          ),
          if (showNumbers) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: p.fraction,
                minHeight: 6,
                backgroundColor: HengyaColors.divider,
                valueColor: AlwaysStoppedAnimation<Color>(grad[0]),
              ),
            ),
          ],
          const SizedBox(height: 8),
          if (!p.hasTextbook)
            const Text(
              '教材未配置，暂不参与复习提示',
              style: TextStyle(
                fontSize: 12,
                color: HengyaColors.textSecondary,
              ),
            )
          else if (p.completed)
            const Text(
              '教材正文章已全部学完',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: HengyaColors.success,
              ),
            )
          else if (p.nextChapter != null)
            Text.rich(
              TextSpan(
                text: '下一章：',
                style: const TextStyle(
                  fontSize: 12,
                  color: HengyaColors.textSecondary,
                ),
                children: [
                  TextSpan(
                    text: p.nextChapter!.display,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: HengyaColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 小标签（已学完 / 未配置教材）
  static Widget _tag(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.10),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

/// 加载失败 / 404 降级 / 空态的统一视图：图标 + 主文案 + 次文案 + 重试
class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onRetry,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              color: HengyaColors.textSecondary,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}
