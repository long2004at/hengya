// 日志页（AppLog tail -f 查看器）：倒序列表 + 实时刷新 + 复制 / 导出分享 /
// 清空 三操作。文本全中文；等宽小字号。由设置页 / 聚合页导航进入
// （AppLogPage() 无必选构造参数）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/local/app_log.dart';
import '../widgets/top_toast.dart';

/// 日志查看页：AppBar 标题「日志」+ 操作栏（复制全部 / 导出分享 / 清空）。
class AppLogPage extends StatefulWidget {
  const AppLogPage({super.key});

  @override
  State<AppLogPage> createState() => _AppLogPageState();
}

class _AppLogPageState extends State<AppLogPage> {
  /// 倒序（最新在前）行列表；[initState] 先读 [AppLog.readTail] 全量铺底，
  /// 之后 [AppLog.onWrite] 新行插到顶部（tail -f 效果）。
  final List<_LogRow> _rows = [];

  StreamSubscription<String>? _sub;

  /// 导出分享防重入。
  bool _sharing = false;

  @override
  void initState() {
    super.initState();
    _sub = AppLog.instance.onWrite.listen(_onNewWrite);
    _loadTail();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _onNewWrite(String line) {
    if (!mounted) return;
    setState(() => _rows.insert(0, _LogRow.fromLine(line)));
  }

  /// 铺底加载（readTail 已按时间倒序返回）。
  Future<void> _loadTail() async {
    final text = await AppLog.instance.readTail();
    if (!mounted) return;
    setState(() {
      _rows
        ..clear()
        ..addAll([
          for (final line in text.split('\n'))
            if (line.trim().isNotEmpty) _LogRow.fromLine(line),
        ]);
    });
  }

  /// 全量日志文本（复制 / 分享共用来源；readTail 大上限即"全量"）。
  Future<String> _allText() => AppLog.instance.readTail(maxLines: 100000);

  Future<void> _copyAll() async {
    final text = await _allText();
    if (!mounted) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    TopToast.show(context, '已复制全部日志', type: TopToastType.success);
  }

  Future<void> _exportShare() async {
    if (_sharing) return;
    setState(() => _sharing = true);
    try {
      final text = await _allText();
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/hengya-log-${_stamp(DateTime.now())}.log');
      await file.writeAsString(text, flush: true);
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'text/plain')],
          text: '恒牙日志',
        ),
      );
    } catch (e) {
      if (mounted) TopToast.show(context, '导出失败：$e');
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  Future<void> _confirmClear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空日志？'),
        content: const Text('将删除今日及轮转的全部日志文件，此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    AppLog.instance.clear(); // 清空后落一条「日志已清空」留痕（breadcrumb）
    await _loadTail();
    if (mounted) {
      TopToast.show(context, '日志已清空', type: TopToastType.info);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        actions: [
          IconButton(
            tooltip: '复制全部',
            icon: const Icon(Icons.copy_all),
            onPressed: _copyAll,
          ),
          IconButton(
            tooltip: '导出分享',
            icon: const Icon(Icons.ios_share),
            onPressed: _exportShare,
          ),
          IconButton(
            tooltip: '清空',
            icon: const Icon(Icons.delete_outline),
            onPressed: _confirmClear,
          ),
        ],
      ),
      body: _rows.isEmpty
          ? const Center(child: Text('暂无日志'))
          : ListView.builder(
              itemCount: _rows.length,
              itemBuilder: (context, index) => _LogRowTile(row: _rows[index]),
            ),
    );
  }
}

/// 一行日志：可解析 → 结构化展示；解析失败（续行/脏数据）→ 灰原样。
class _LogRow {
  _LogRow.fromLine(String line)
    : entry = AppLogEntry.fromLine(line),
      raw = line;

  final AppLogEntry? entry;
  final String raw;
}

class _LogRowTile extends StatelessWidget {
  const _LogRowTile({required this.row});

  final _LogRow row;

  static const Map<AppLogLevel, String> _levelLabels = {
    AppLogLevel.debug: '调试',
    AppLogLevel.info: '信息',
    AppLogLevel.warn: '警告',
    AppLogLevel.error: '错误',
  };

  static const Map<AppLogLevel, Color> _levelColors = {
    AppLogLevel.debug: Color(0xFF607D8B), // 蓝灰
    AppLogLevel.info: Color(0xFF212121), // 近黑
    AppLogLevel.warn: Color(0xFFEF6C00), // 橙
    AppLogLevel.error: Color(0xFFD32F2F), // 红
  };

  @override
  Widget build(BuildContext context) {
    final entry = row.entry;
    final Color color;
    final String text;
    if (entry == null) {
      color = const Color(0xFF757575); // 灰：续行/无法解析原样
      text = row.raw;
    } else {
      color = _levelColors[entry.level]!;
      text =
          '${_clock(entry.time)} | ${_levelLabels[entry.level]} | '
          '${entry.tag} | ${entry.message}';
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 12,
          height: 1.35,
          color: color,
        ),
      ),
    );
  }
}

/// HH:mm:ss.SSS。
String _clock(DateTime t) {
  String p(int v, [int width = 2]) => v.toString().padLeft(width, '0');
  return '${p(t.hour)}:${p(t.minute)}:${p(t.second)}.${p(t.millisecond, 3)}';
}

/// yyyyMMdd-HHmmss（分享文件名时间戳）。
String _stamp(DateTime t) {
  String p(int v, [int width = 2]) => v.toString().padLeft(width, '0');
  return '${t.year}${p(t.month)}${p(t.day)}-${p(t.hour)}${p(t.minute)}${p(t.second)}';
}
