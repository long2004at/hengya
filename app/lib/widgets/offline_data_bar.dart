// 「离线数据 · 更新于 HH:mm」内联提示条 —— 离线缓存回退的统一轻提示（问1+5）
//
// 使用方式：页面在数据来自本地缓存（ApiClient 旁路元信息命中）时，把本条
// 插入页面布局的常规流（内联小条，非弹层——不频繁打扰）：
//   OfflineDataBar(savedAt: data.cacheAt)   // savedAt == null 时不渲染
//
// 信息明确硬约束：
//   · 文案恒定含「离线数据」+ 缓存时间——数据可能过时这件事对用户始终可见；
//   · 跨天的缓存自动带上日期（「更新于 9月4日 14:32」），不误导为今天的最新值；
//   · 纯展示，IgnorePointer 包裹，不遮挡任何交互。
import 'package:flutter/material.dart';

import '../theme.dart';

class OfflineDataBar extends StatelessWidget {
  const OfflineDataBar({super.key, required this.savedAt});

  /// 缓存落盘时间；null = 数据新鲜 → 本条不渲染（SizedBox.shrink）
  final DateTime? savedAt;

  /// 提示文案：今天 → 「离线数据 · 更新于 HH:mm」；更早 → 带上日期
  @visibleForTesting
  static String labelOf(DateTime at) {
    final hh = at.hour.toString().padLeft(2, '0');
    final mm = at.minute.toString().padLeft(2, '0');
    final now = DateTime.now();
    final isToday =
        at.year == now.year && at.month == now.month && at.day == now.day;
    return isToday
        ? '离线数据 · 更新于 $hh:$mm'
        : '离线数据 · 更新于 ${at.month}月${at.day}日 $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    final at = savedAt;
    if (at == null) return const SizedBox.shrink();
    return IgnorePointer(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: HengyaColors.warning.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: HengyaColors.warning.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_outlined,
              size: 14,
              color: HengyaColors.warning,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                labelOf(at),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: HengyaColors.warning,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
