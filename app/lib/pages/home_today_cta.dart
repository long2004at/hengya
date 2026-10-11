// 今日复习大 CTA（2026-10-11 首页重构：单一大 CTA 主导 + 次要收纳）：
//   · 数据源唯一口径 GET /stats/today 四字段（TodayProgress：goal/done/
//     dueTotal/remainingToday），由首页 _fetchToday 尽力而为拉取传入——
//     禁止各处另算今日数（与今日复习会话页、统计页同一口径）。
//   · 三态文案（措辞基线：「今日复习」「N/目标 M」「已完成/还剩」）：
//       未开始  「开始今日复习 · 还剩 N 张」
//       进行中  「继续今日复习 · M/目标 K」
//       已完成  「今日已完成 M/K ✓」——完成后仍可点击进 /review/today 再练
//               剩余到期卡（页面自会落完成态/到期清完态）。
//   · 降级：拉不到 today（断网 / 旧服务器 404）→ null，文案退「开始今日
//     复习」仍可点击；Hero 大数字同步回退 totalDue（见 todayHeroNumber）。
//   · 全宽白底主按钮压在 kHeroGradient 上（品牌深蓝文字），与玻璃胶囊
//     同一视觉家族；Key 'home-today-cta' 供测试定位。
import 'package:flutter/material.dart';

import '../services/api/api_client.dart';
import '../theme.dart';

/// 今日 CTA 三态（口径唯一：TodayProgress.done 对比 goal，禁止另算）
enum TodayCtaState { notStarted, inProgress, done }

TodayCtaState todayCtaStateOf(TodayProgress t) {
  if (t.goal > 0 && t.done >= t.goal) return TodayCtaState.done;
  if (t.done > 0) return TodayCtaState.inProgress;
  return TodayCtaState.notStarted;
}

/// CTA 主文案（三态；措辞与今日复习会话页「N/目标 M」口径一致）。
/// 未开始且无到期（remainingToday==0，如空库/全部清完的次日）→ 只留
/// 「开始今日复习」，不出现「还剩 0 张」的怪文案。
String todayCtaLabel(TodayProgress t) {
  switch (todayCtaStateOf(t)) {
    case TodayCtaState.notStarted:
      return t.remainingToday > 0
          ? '开始今日复习 · 还剩 ${t.remainingToday} 张'
          : '开始今日复习';
    case TodayCtaState.inProgress:
      return '继续今日复习 · ${t.display}';
    case TodayCtaState.done:
      return '今日已完成 ${t.done}/${t.goal} ✓';
  }
}

/// Hero 大数字展示口径（与 CTA 同源，绝不出现「按钮说 5 大数字却是 23」
/// 的割裂）：有 today → remainingToday（今日还剩，goal 用满前 ≤ dueTotal）；
/// 无 today（降级）→ 回退旧口径 totalDue（全部到期存量）。
int todayHeroNumber(TodayProgress? today, int fallbackDue) =>
    today?.remainingToday ?? fallbackDue;

class TodayCtaButton extends StatelessWidget {
  const TodayCtaButton({
    super.key,
    required this.today,
    required this.fallbackDue,
    required this.onPressed,
  });

  /// 今日进度四字段（/stats/today 唯一口径）；null = 降级态
  final TodayProgress? today;

  /// 降级期大数字回退值（科目 dueCount 汇总，旧「今日到期」口径）
  final int fallbackDue;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = today;
    final done = t != null && todayCtaStateOf(t) == TodayCtaState.done;
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: FilledButton.icon(
        key: const ValueKey('home-today-cta'),
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: HengyaColors.brandDeep,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
          textStyle: const TextStyle(
            fontSize: 16.5,
            fontWeight: FontWeight.w800,
          ),
        ),
        onPressed: onPressed,
        icon: Icon(done ? Icons.celebration_outlined : Icons.play_arrow_rounded),
        label: Text(t != null ? todayCtaLabel(t) : '开始今日复习'),
      ),
    );
  }
}
