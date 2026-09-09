import 'package:flutter/material.dart';

/// 恒牙主题（M3 视觉对齐：设计稿 TDesign 品牌蓝体系 → Material 3 映射）
///
/// 设计稿语义变量 → Material 角色：
///   品牌蓝 #0052D9        → primary
///   品牌蓝深 #003CAB       → 渐变 Hero 起点
///   品牌蓝亮 #366EF4       → 渐变 Hero 终点 / 激活强调
///   成功绿 #2BA471         → 批准/掌握
///   警示红 #D54941         → 重来/错误
///   警示橙 #E37318         → 困难评分/考试课标签
///   背景 #F5F6F7           → scaffold background
///   文字主 #18191C         → onSurface
///   文字次 #646466         → outline
class HengyaColors {
  const HengyaColors._();

  // TDesign 品牌色（设计稿 apply_variables 同源）
  static const brand = Color(0xFF0052D9);
  static const brandDeep = Color(0xFF003CAB);
  static const brandLight = Color(0xFF366EF4);
  static const success = Color(0xFF2BA471);
  static const successDeep = Color(0xFF008858);
  static const danger = Color(0xFFD54941);
  static const warning = Color(0xFFE37318);
  static const bg = Color(0xFFF5F6F7);
  static const textPrimary = Color(0xFF18191C);
  static const textSecondary = Color(0xFF646466);
  static const divider = Color(0xFFE4E8EF);

  // 科目渐变色盘（0.3.1 开源去内置：不再按内置短码特化——任意科目 id
  // 经稳定散列从色盘取色，保持科目间的视觉辨识度；同 id 恒同色）
  static const List<List<Color>> _subjectPalette = [
    [Color(0xFF0052D9), Color(0xFF366EF4)], // 品牌蓝
    [Color(0xFF00A870), Color(0xFF2BA471)], // 青绿
    [Color(0xFF7B61FF), Color(0xFF9A82FF)], // 紫罗兰
    [Color(0xFF00A3C8), Color(0xFF26C1E8)], // 青
    [Color(0xFFD5A021), Color(0xFFE8C468)], // 琥珀
    [Color(0xFF3E5AA8), Color(0xFF5C7AC9)], // 靛蓝
    [Color(0xFF8A2BE2), Color(0xFFB06AE8)], // 紫罗兰深
  ];

  /// 科目 id → 稳定散列（同一 id 跨会话/跨端恒定；非加密，仅取色用）
  static int _stableHash(String id) {
    var h = 0;
    for (final c in id.codeUnits) {
      h = (h * 31 + c) & 0x7FFFFFFF;
    }
    return h;
  }

  /// 科目渐变：按科目 id 稳定散列从色盘取色（空 id 兜底品牌蓝）
  static List<Color> gradientOf(String subjectId) => subjectId.isEmpty
      ? [brand, brandLight]
      : _subjectPalette[_stableHash(subjectId) % _subjectPalette.length];
}

/// 科目图标（0.3.1 开源去内置：不再按内置短码特化——按科目 id 稳定散列
/// 从通用学习图标集取用，同 id 恒同图标）
IconData subjectIcon(String subjectId) {
  const icons = [
    Icons.menu_book_outlined,
    Icons.auto_stories_outlined,
    Icons.school_outlined,
    Icons.psychology_outlined,
    Icons.edit_note_outlined,
    Icons.lightbulb_outlined,
    Icons.travel_explore_outlined,
  ];
  if (subjectId.isEmpty) return Icons.menu_book_outlined;
  var h = 0;
  for (final c in subjectId.codeUnits) {
    h = (h * 31 + c) & 0x7FFFFFFF;
  }
  return icons[h % icons.length];
}

/// 卡片柔影（设计稿：黑 7%，y6，r16）
const kCardSoftShadow = <BoxShadow>[
  BoxShadow(
    color: Color(0x12000000),
    offset: Offset(0, 6),
    blurRadius: 16,
  ),
];

/// Hero 渐变（45° 斜向：深→亮）
const kHeroGradient = LinearGradient(
  begin: Alignment(-0.6, -1),
  end: Alignment(0.6, 1),
  colors: [HengyaColors.brandDeep, HengyaColors.brandLight],
);

ThemeData buildHengyaTheme() {
  // 以品牌蓝为种子，但锁死关键色（避免 M3 seed 漂移出灰紫系）
  final scheme = ColorScheme.fromSeed(
    seedColor: HengyaColors.brand,
    brightness: Brightness.light,
  ).copyWith(
    primary: HengyaColors.brand,
    onPrimary: Colors.white,
    primaryContainer: const Color(0xFFE6ECFD), // 品牌浅底（streak 卡等）
    onPrimaryContainer: HengyaColors.brandDeep,
    secondary: HengyaColors.success,
    secondaryContainer: const Color(0xFFE8F5EE),
    onSecondaryContainer: HengyaColors.successDeep,
    error: HengyaColors.danger,
    tertiary: HengyaColors.warning,
    surface: Colors.white,
    onSurface: HengyaColors.textPrimary,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFFAFBFC),
    surfaceContainer: HengyaColors.bg,
    surfaceContainerHigh: const Color(0xFFEFF1F3),
    surfaceContainerHighest: const Color(0xFFE4E8EF),
    outline: HengyaColors.textSecondary,
    outlineVariant: HengyaColors.divider,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: HengyaColors.bg,
    fontFamily: null,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      backgroundColor: HengyaColors.bg,
      foregroundColor: HengyaColors.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleTextStyle: const TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w800,
        color: HengyaColors.textPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.white,
      indicatorColor: HengyaColors.brand,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStatePropertyAll(
        const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? Colors.white // 激活：白图标（配实心品牌蓝指示器）
              : HengyaColors.textSecondary,
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButtonThemeData().style?.copyWith(
        backgroundColor: WidgetStatePropertyAll(HengyaColors.brand),
        foregroundColor: WidgetStatePropertyAll(Colors.white),
        textStyle: const WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
        ),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        padding: const WidgetStatePropertyAll(
          EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.white,
      selectedColor: HengyaColors.brand,
      labelStyle: const TextStyle(
        fontSize: 13,
        color: HengyaColors.textPrimary,
      ),
      side: BorderSide(color: HengyaColors.divider),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: HengyaColors.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: HengyaColors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: HengyaColors.brand, width: 1.6),
      ),
    ),
  );
}
