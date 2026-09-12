// 恒牙日志基建（v0.1.9）：AppLog 单例——同步落盘 + debugPrint 转发 +
// 实时写入流 + 尾部读取。真机崩溃 / 未捕获异常自查的落盘点
// （main.dart 注入 FlutterError.onError / PlatformDispatcher.onError /
// runZonedGuarded 三处兜底）。
//
// 纪律（调用方与实现共同遵守）：日志内容绝不包含任何 API key / token /
// 敏感值——只传描述性文案（安全修复 C 后明文 key 已全量迁入系统安全存储
// AiKeyVault，日志写入更是红线；建库侧协议同样守卫 key 不进日志/进度/结果）。
//
// 落盘：<dataDir>/logs/app-YYYYMMDD.log（dataDir 取 LocalBackend
// .instance.dataDir；为 null → 仅 debugPrint 转发，不落盘、不报错）。
// 滚动：单文件超 2MB 时轮转到 app-YYYYMMDD-N.log（N=1 为最近一份），
// 保留最近 5 份轮转文件，更旧删除。
//
// 行格式（落盘文本，每行以 '\n' 结尾；同时是 onWrite 流事件负载）：
//   yyyy-MM-dd HH:mm:ss.SSS [level] [tag] message
//   例：2026-09-11 15:49:27.665 [info] [startup] 启动：版本 0.1.8
// 说明：message 可含换行（堆栈等），首行可经 [AppLogEntry.fromLine] 解析，
// 其余行为原始续行。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;

import 'local_backend.dart';

/// 日志级别（file/stream 中按 [AppLogLevel.name] 原样书写）。
enum AppLogLevel { debug, info, warn, error }

/// 单条日志条目（行解析结果）：日志页 / 聚合页 / 测试结构化消费。
/// 解析失败返回 null——调用方回退原始行展示。
class AppLogEntry {
  const AppLogEntry({
    required this.time,
    required this.level,
    required this.tag,
    required this.message,
  });

  /// 发生时刻（含毫秒）。
  final DateTime time;

  final AppLogLevel level;

  /// 来源标签（建议短写：flutter / platform / zone / startup / 各业务域）。
  final String tag;

  /// 描述性文案（纪律：不含任何 key/token/敏感值）。
  final String message;

  static final RegExp _linePattern = RegExp(
    r'^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}\.\d{3}) '
    r'\[(debug|info|warn|error)\] \[([^\]]*)\] ?(.*)$',
  );

  /// 从落盘行解析；非法/续行返回 null（展示侧回退原样文本）。
  static AppLogEntry? fromLine(String line) {
    final m = _linePattern.firstMatch(line);
    if (m == null) return null;
    final time = DateTime.tryParse('${m.group(1)} ${m.group(2)}');
    if (time == null) return null;
    return AppLogEntry(
      time: time,
      level: AppLogLevel.values.firstWhere((e) => e.name == m.group(3)),
      tag: m.group(4)!,
      message: m.group(5) ?? '',
    );
  }
}

/// 内置日志单例。API 自包含、签名稳定（后续缓存治理 / 聚合页 / 测试直接
/// import 调用）：[log] / [onWrite] / [readTail] / [clear]。
class AppLog {
  AppLog._();

  static final AppLog instance = AppLog._();

  /// 单文件滚动上限：2MB。
  static const int kMaxFileBytes = 2 * 1024 * 1024;

  /// 保留最近轮转份数（app-YYYYMMDD-1.log ~ app-YYYYMMDD-5.log）。
  static const int kMaxRotated = 5;

  final StreamController<String> _ctrl = StreamController<String>.broadcast();

  /// 实时写入事件流（broadcast）：每次 [log] 后 emit 该行文本（与落盘同款
  /// 行格式）。无订阅者不缓冲；日志页 tail -f 效果由此驱动。
  Stream<String> get onWrite => _ctrl.stream;

  /// logs 目录（dataDir 未初始化（remote 模式）→ null，此时不落盘）。
  Directory? _logsDir() {
    final dataDir = LocalBackend.instance.dataDir;
    if (dataDir == null || dataDir.isEmpty) return null;
    return Directory('$dataDir/logs');
  }

  /// 写一条日志：同步追加落盘（小写入，append+flush）+ debugPrint 转发 +
  /// onWrite 事件。任何落盘异常静默降级（本类正是兜底录，自身绝不抛）。
  /// [tag] 短标签；[message] 仅描述性文案——绝不包含 key/token/敏感值。
  void log(AppLogLevel level, String tag, String message) {
    final now = DateTime.now();
    final line = _formatLine(now, level, tag, message);
    // debugPrint 转发恒执行（dataDir 为 null / 落盘失败时仍可在控制台看到）
    debugPrint(line);
    try {
      final dir = _logsDir();
      if (dir == null) return;
      dir.createSync(recursive: true);
      final base = 'app-${_date(now)}';
      final file = File('${dir.path}/$base.log');
      if (file.existsSync() && file.lengthSync() >= kMaxFileBytes) {
        _rotate(dir, base);
      }
      // 2026-09-11 fix：原 '$line\n'.codeUnits 按 UTF-16 落盘，readTail/
      // readAsLines（UTF-8）解码失败 → 日志页/读回恒空——改 utf8.encode
      //（文件头注释即声明文本行；readTail 与 AppLogEntry.fromLine 均为 UTF-8）
      File('${dir.path}/$base.log').writeAsBytesSync(
        utf8.encode('$line\n'),
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 落盘失败不报错：debugPrint 已转发（磁盘满/权限异常等场景吞掉）
    } finally {
      if (!_ctrl.isClosed) {
        _ctrl.add(line);
      }
    }
  }

  /// 滚动：当前文件 ≥2MB → 平移编号（N=1 最近一份；保 [kMaxRotated] 份），
  /// 当日文件本体清零（下次写入新建）。
  void _rotate(Directory dir, String base) {
    File px(int n) => File('${dir.path}/$base-$n.log');
    // 先删最旧（保 5 份）：4→5、3→4、2→3、1→2，再 base.log→base-1.log
    if (px(kMaxRotated).existsSync()) px(kMaxRotated).deleteSync();
    for (var n = kMaxRotated - 1; n >= 1; n--) {
      if (px(n).existsSync()) px(n).renameSync(px(n + 1).path);
    }
    File('${dir.path}/$base.log').renameSync(px(1).path);
  }

  /// 读取最近日志（跨当日 + 轮转文件，时间倒序 = 最新在前），默认最近 500 行。
  /// 返回行以 '\n' 连接（无结尾换行）；无日志/未初始化 → 空串。
  ///
  /// 2026-09-13 fix：原实现把整个多文件循环包在一个 try 里，任何一个文件
  /// 解码失败（v0.1.9/10 的 UTF-16 毒文件遗留）就整体返回空串，把其余合法
  /// 日志全部掩盖——日志页「恒空」的真根因。改为逐文件独立容错：单个文件
  /// 读/解码失败只跳过该文件，收集完毕后将其删除（毒文件不可修复且会永久
  /// 连坐后续读取），并写一条清理留痕。
  Future<String> readTail({int maxLines = 500}) async {
    if (maxLines <= 0) return '';
    final collected = <String>[];
    final dir = _logsDir();
    if (dir == null || !dir.existsSync()) return '';
    final poisoned = <File>[]; // 不可解码的遗留文件：先跳过，收口后统一清理
    outer:
    for (final f in _sortedLogFiles(dir)) {
      if (collected.length >= maxLines) break;
      List<String>? lines;
      try {
        lines = await File(f.path).readAsLines();
      } catch (_) {
        poisoned.add(f);
        continue;
      }
      for (final line in lines) {
        if (line.isEmpty) continue;
        collected.add(line);
        // 已远超目标行数：本文件即最新内容（新→旧序），留余量后收口
        if (collected.length >= maxLines * 2) break outer;
      }
    }
    for (final f in poisoned) {
      try {
        f.deleteSync();
        log(AppLogLevel.warn, 'applog',
            '清理不可解码的遗留日志文件：${f.uri.pathSegments.last}');
      } catch (_) {
        // 删除失败静默：下次 readTail 会再次跳过该文件，不影响其余内容
      }
    }
    // 行首 23 字符即 yyyy-MM-dd HH:mm:ss.SSS，字典序 = 时间序；倒序取最近
    collected.sort((a, b) => b.compareTo(a));
    return collected.take(maxLines).join('\n');
  }

  /// 清空今日及轮转日志文件（logs/ 下全部 app-*.log）。完成后写一条
  /// 「日志已清空」信息日志留痕（breadcrumb）；dataDir 为 null 时无操作。
  void clear() {
    try {
      final dir = _logsDir();
      if (dir == null || !dir.existsSync()) return;
      for (final f in _sortedLogFiles(dir)) {
        f.deleteSync();
      }
    } catch (_) {
      return; // 删除失败静默（下次 log 正常重建）
    }
    log(AppLogLevel.info, 'applog', '日志已清空');
  }

  /// logs/ 下日志文件按内容新旧排序（最新在前）：日期降序 → 当日活动文件最前
  /// → 轮转 N=1（最近）在前。返回空列表 = 无日志。
  List<File> _sortedLogFiles(Directory dir) {
    final files = dir
        .listSync()
        .whereType<File>()
        .where(
          (f) => RegExp(
            r'^app-\d{8}(-\d+)?\.log$',
          ).hasMatch(f.uri.pathSegments.last),
        )
        .toList();
    files.sort((a, b) => _fileKey(b.path).compareTo(_fileKey(a.path)));
    return files;
  }

  /// 排序键：日期(8) + 优先级（活动文件 '9' > 轮转 '8'）+ 轮转序倒排
  /// （N=1 最近 → '8-04' > '8-03'…，故编码 6-N）。
  static String _fileKey(String path) {
    final name = path.split(RegExp(r'[/\\]')).last;
    final m = RegExp(r'^app-(\d{8})(?:-(\d+))?\.log$').firstMatch(name);
    if (m == null) return name;
    final idx = m.group(2) == null ? 0 : int.parse(m.group(2)!);
    final prio = idx == 0 ? '9' : '8';
    return '${m.group(1)}$prio${(kMaxRotated + 1 - idx).toString().padLeft(2, '0')}';
  }

  // ---------------- 行格式化 ----------------

  static String _formatLine(
    DateTime now,
    AppLogLevel level,
    String tag,
    String message,
  ) => '${_timestamp(now)} [${level.name}] [$tag] $message';

  /// yyyy-MM-dd HH:mm:ss.SSS（同时是文件行首 23 字符，倒序排序依据）。
  static String _timestamp(DateTime t) =>
      '${_date(t)} ${_hh(t)}:${_mm(t)}:${_ss(t)}.${t.millisecond.toString().padLeft(3, '0')}';

  /// yyyyMMdd（文件名日期段）。
  static String _date(DateTime t) =>
      '${t.year.toString().padLeft(4, '0')}'
      '${t.month.toString().padLeft(2, '0')}'
      '${t.day.toString().padLeft(2, '0')}';

  static String _hh(DateTime t) => t.hour.toString().padLeft(2, '0');
  static String _mm(DateTime t) => t.minute.toString().padLeft(2, '0');
  static String _ss(DateTime t) => t.second.toString().padLeft(2, '0');
}
