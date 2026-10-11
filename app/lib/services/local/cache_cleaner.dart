// 恒牙（hengya）· 缓存分类治理（批5 缓存节点）
// ============================================================================
// 缓存分类统计 + 手动清理，供聚合页「清除缓存」入口调用。
// 纪律（与下游 UI 共同遵守）：
//   · 不自动：绝不在 App 启动 / 页面加载时调用 clean —— 手动按钮专用功能；
//   · 不误删：只删下面五类残留，不碰离线缓存、Flutter/引擎缓存、incoming/、
//     progress.json、corpus.db 本体；当前版本安装包保留（升级失败可重装）；
//   · 不阻断：每项删除独立 try/catch——文件占用 / 不存在 / 权限异常不阻断整体。
//
// 五类残留（与 corpus_package.dart / update_service.dart 路径约定对齐）：
//   a) importTmp    <dataDir>/corpus/.import-tmp-*       导入解压临时目录（异常中断残留）
//   b) pkgValidate  <cacheDir>/hengya-pkg-validate_*     validatePackage 校验临时库（异常中断残留）
//   c) zipCopies    <cacheDir>/*.zip                     file_selector 拷贝的 zip（从不清理）
//   d) backups      <dataDir>/corpus/bak-*               旧库备份（用户数据，仅 includeBackups 时删）
//   e) updateApks   <dataDir>/update/*                   更新下载残留：非当前版本 APK（含
//                                                        .part/.part.json 断点侧车）
//
// cacheDir 默认取 path_provider getTemporaryDirectory（path_provider ^2.1.6
// 已在 pubspec；Android 上 Directory.systemTemp 即应用 cache dir，与
// validatePackage 同源）；获取失败退化为 Directory.systemTemp。
// dataDir 默认取 LocalBackend.instance.dataDir（null = remote 模式，跳过
// importTmp/backups/updateApks 三类 local 残留）。
// currentVersion 缺省取 package_info 构建版本（获取失败视为未知 → update/
// 下 APK 一律按「非当前版本」处理；仅清 update/ 专属目录，风险可控）。
// 生产不传 dataDir/cacheDir 用默认；测试注入假路径（宿主不做真实 App 目录操作）。
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart'
    show PackageInfo;
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;

import 'app_log.dart';
import 'local_backend.dart';

/// 缓存类别（[CacheScanResult]/[CacheCleanResult] 的键）。
enum CacheCategory { importTmp, pkgValidate, zipCopies, backups, updateApks }

/// [CacheCleaner.scan] 的返回：五类残留的字节与条目统计。只读快照，不含任何删除。
class CacheScanResult {
  const CacheScanResult({required this.bytes, required this.count});

  /// 每类残留总字节。键恒含全部五类；无残留 = 0。
  final Map<CacheCategory, int> bytes;

  /// 每类残留条目数（目录 / 文件个数）。键恒含全部五类；无残留 = 0。
  final Map<CacheCategory, int> count;

  /// 五类字节总和（scan 口径）。
  int get totalBytes => bytes.values.fold(0, (a, b) => a + b);
}

/// [CacheCleaner.clean] 的返回：成功删除的条目数与释放字节。
class CacheCleanResult {
  const CacheCleanResult({
    required this.removedCount,
    required this.freedBytes,
  });

  /// 每类成功删除的条目数。键恒含全部五类；未启用/未命中 = 0。
  final Map<CacheCategory, int> removedCount;

  /// 实际释放的字节总数（仅统计删除成功的项；失败项不计入）。
  final int freedBytes;
}

/// 缓存分类统计与手动清理（static 方法集合，无状态、可并发安全调用）。
abstract final class CacheCleaner {
  static const String _importTmpPrefix = '.import-tmp-';
  static const String _pkgValidatePrefix = 'hengya-pkg-validate_';
  static const String _backupPrefix = 'bak-';

  /// 扫描五类残留并统计字节/条目数。只读，不删除任何东西。
  ///
  /// [dataDir] 缺省 = [LocalBackend.instance.dataDir]（null = remote 模式，
  /// 跳过 importTmp/backups/updateApks 三类 local 残留）。[cacheDir] 缺省 =
  /// getTemporaryDirectory()（获取失败退化为 [Directory.systemTemp]）。
  /// [currentVersion] 缺省取 package_info 构建版本；updateApks 只统计
  /// `<dataDir>/update/` 下非当前版本的 APK（含 .part/.part.json 侧车）。
  /// 三参数仅供测试注入假路径/假版本；生产不传。
  static Future<CacheScanResult> scan({
    String? dataDir,
    String? cacheDir,
    String? currentVersion,
  }) async {
    final dir = dataDir ?? LocalBackend.instance.dataDir;
    final cache = cacheDir ?? await _defaultCacheDir();
    final bytes = {for (final c in CacheCategory.values) c: 0};
    final count = {for (final c in CacheCategory.values) c: 0};

    if (dir != null) {
      final corpus = Directory('$dir/corpus');
      await _scanPrefixed(
        parent: corpus,
        prefix: _importTmpPrefix,
        dirsOnly: true,
        category: CacheCategory.importTmp,
        bytes: bytes,
        count: count,
      );
      await _scanPrefixed(
        parent: corpus,
        prefix: _backupPrefix,
        dirsOnly: true,
        category: CacheCategory.backups,
        bytes: bytes,
        count: count,
      );
      await _scanUpdateDir(
        updateDir: Directory('$dir/update'),
        currentVersion: currentVersion ?? await _currentVersion(),
        bytes: bytes,
        count: count,
      );
    }
    final cacheDirObj = Directory(cache);
    await _scanPrefixed(
      parent: cacheDirObj,
      prefix: _pkgValidatePrefix,
      dirsOnly: true,
      category: CacheCategory.pkgValidate,
      bytes: bytes,
      count: count,
    );
await _scanZipCopies(cacheDirObj,
        bytes: bytes, count: count);

    return CacheScanResult(bytes: bytes, count: count);
  }

  /// 清理五类残留：a/b/c/e 恒删；d（backups）仅 [includeBackups] == true 时删
  /// （调用方负责二次确认，默认 false 保用户备份）。e 只删 `<dataDir>/update/`
  /// 下非当前版本的 APK（含 .part/.part.json 侧车）——当前版本安装包保留
  /// （升级失败可重装）。全程 [onProgress] 回传中文进度文案；逐项删除独立
  /// try/catch，单项失败不阻断整体、不抛给调用方。
  /// 每类有实际命中时写一条 AppLog（tag='cache'）：
  ///   `清理 <类别> <数量> 项 <MB>MB`
  /// 返回成功删除的条目数与释放字节（失败项不计入 freedBytes）。
  static Future<CacheCleanResult> clean({
    required bool includeBackups,
    void Function(String message)? onProgress,
    String? dataDir,
    String? cacheDir,
    String? currentVersion,
  }) async {
    final dir = dataDir ?? LocalBackend.instance.dataDir;
    final cache = cacheDir ?? await _defaultCacheDir();
    final removed = {for (final c in CacheCategory.values) c: 0};
    final freedByCat = {for (final c in CacheCategory.values) c: 0};
    void progress(String m) => onProgress?.call(m);

    progress('开始清理缓存…');

    Future<void> sweep(
      Directory parent,
      String prefix,
      bool dirsOnly,
      CacheCategory category,
    ) async {
      final found = await _sweepPrefixed(
        parent: parent,
        prefix: prefix,
        dirsOnly: dirsOnly,
        category: category,
        removed: removed,
        freedByCat: freedByCat,
        progress: progress,
      );
      if (found > 0) {
        AppLog.instance.log(
          AppLogLevel.info,
          'cache',
          '清理 ${_label(category)} ${removed[category]!} 项 '
              '${_mb(freedByCat[category]!)}MB',
        );
      }
    }

    // a) 导入残留（local：dataDir/corpus/.import-tmp-*）
    // d) 旧库备份（local：dataDir/corpus/bak-*，仅 includeBackups）
    // e) 更新下载残留（local：dataDir/update/ 下非当前版本 APK + 断点侧车）
    if (dir != null) {
      final corpus = Directory('$dir/corpus');
      await sweep(corpus, _importTmpPrefix, true, CacheCategory.importTmp);
      if (includeBackups) {
        await sweep(corpus, _backupPrefix, true, CacheCategory.backups);
      } else {
        progress('跳过旧库备份（未开启备份清理）');
      }
      await _sweepUpdateDir(
        updateDir: Directory('$dir/update'),
        currentVersion: currentVersion ?? await _currentVersion(),
        removed: removed,
        freedByCat: freedByCat,
        progress: progress,
      );
      if (removed[CacheCategory.updateApks]! > 0) {
        AppLog.instance.log(
          AppLogLevel.info,
          'cache',
          '清理 ${_label(CacheCategory.updateApks)} '
              '${removed[CacheCategory.updateApks]!} 项 '
              '${_mb(freedByCat[CacheCategory.updateApks]!)}MB',
        );
      }
    }
    // b) 校验残留（cacheDir/hengya-pkg-validate_*）
    // c) zip 拷贝（cacheDir/*.zip；带防误删守卫：仅 cache 根直接子项的
    //    .zip 文件——即 file_selector 拷贝源，绝不递归进子目录）
    final cacheDirObj = Directory(cache);
    await sweep(
      cacheDirObj,
      _pkgValidatePrefix,
      true,
      CacheCategory.pkgValidate,
    );
    await _sweepZipCopies(
      cacheDirObj,
      removed: removed,
      freedByCat: freedByCat,
      progress: progress,
    );
    if (removed[CacheCategory.zipCopies]! > 0) {
      AppLog.instance.log(
        AppLogLevel.info,
        'cache',
        '清理 ${_label(CacheCategory.zipCopies)} '
            '${removed[CacheCategory.zipCopies]!} 项 '
            '${_mb(freedByCat[CacheCategory.zipCopies]!)}MB',
      );
    }

    final freed = freedByCat.values.fold(0, (a, b) => a + b);
    progress('清理完成：释放 ${_mb(freed)}MB');
    return CacheCleanResult(removedCount: removed, freedBytes: freed);
  }

  // ------------------------------------------------------- 内部实现 ----

  /// 生产默认 cache 目录：path_provider getTemporaryDirectory；获取失败
  /// （如测试宿主无插件）退化为 Directory.systemTemp（与 validatePackage 同源）。
  static Future<String> _defaultCacheDir() async {
    try {
      return (await getTemporaryDirectory()).path;
    } catch (_) {
      return Directory.systemTemp.path;
    }
  }

  /// 当前运行版本号（package_info 构建；获取失败 → 空串 = 版本未知）。
  static Future<String> _currentVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return '';
    }
  }

  /// 文件名是否携带当前版本号（宽松匹配：`hengya-v0.1.22-release.apk` /
  /// `hengya-0.1.22-release.apk` / `heng-1.7.0+15-local-release.apk`）。
  /// 版本未知（[currentVersion] 为空）→ 恒 false（无法证明是当前版本 →
  /// update/ 专属目录内一律按残留处理，风险可控）。
  static bool _versionInName(String fileName, String currentVersion) {
    if (currentVersion.isEmpty) return false;
    final escaped = RegExp.escape(currentVersion);
    return RegExp('v?$escaped(?=\\D|\$)').hasMatch(fileName);
  }

  /// 扫描 update/ 专属下载目录（updateApks 类）：非当前版本的 APK 文件 +
  /// .part/.part.json 断点侧车残留。目录不存在 / 无权限 → 整类跳过（0）。
  static Future<void> _scanUpdateDir({
    required Directory updateDir,
    required String currentVersion,
    required Map<CacheCategory, int> bytes,
    required Map<CacheCategory, int> count,
  }) async {
    try {
      for (final e in updateDir.listSync(followLinks: false)) {
        if (e is! File || !_isUpdateResidue(e, currentVersion)) continue;
        count[CacheCategory.updateApks] = count[CacheCategory.updateApks]! + 1;
        try {
          bytes[CacheCategory.updateApks] =
              bytes[CacheCategory.updateApks]! + await e.length();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 删除 update/ 下非当前版本的 APK + 断点侧车（逐项 try/catch）。
  static Future<void> _sweepUpdateDir({
    required Directory updateDir,
    required String currentVersion,
    required Map<CacheCategory, int> removed,
    required Map<CacheCategory, int> freedByCat,
    required void Function(String) progress,
  }) async {
    final targets = <File>[];
    try {
      for (final e in updateDir.listSync(followLinks: false)) {
        if (e is! File || !_isUpdateResidue(e, currentVersion)) continue;
        targets.add(e);
      }
    } catch (_) {} // 目录不存在 / 无权限 → 无目标
    for (final t in targets) {
      await _deleteEntity(
        t,
        category: CacheCategory.updateApks,
        removed: removed,
        freedByCat: freedByCat,
        progress: progress,
      );
    }
  }

  /// update/ 内单条目是否属清理目标（防误删守卫，三类命中其一）：
  ///   1) .apk 文件且文件名不含当前版本号（旧版本安装包）；
  ///   2) .part / .part.json 断点续传侧车（任何版本——下载中断残留，
  ///      重进更新页会自动重新下载或续传，删除不破坏功能）；
  ///   3) .apk.crdownload 等其它非 APK 文件一律不动（保稳定，不认识就不删）。
  /// 当前版本 APK 保留：升级失败/安装器中断后可零流量重装。
  static bool _isUpdateResidue(File e, String currentVersion) {
    final name = _basename(e).toLowerCase();
    if (name.endsWith('.part') || name.endsWith('.part.json')) return true;
    if (name.endsWith('.apk')) return !_versionInName(name, currentVersion);
    return false;
  }

  /// 扫描 parent 直接子项中 basename 以 [prefix] 开头且类型匹配的条目，
  /// 累计字节（目录递归求和）与条数。目录不存在 / 无权限 → 整类跳过（0）。
  static Future<void> _scanPrefixed({
    required Directory parent,
    required String prefix,
    required bool dirsOnly,
    required CacheCategory category,
    required Map<CacheCategory, int> bytes,
    required Map<CacheCategory, int> count,
  }) async {
    try {
      for (final e in parent.listSync(followLinks: false)) {
        final ok = dirsOnly ? e is Directory : e is File;
        if (!ok || !_basename(e).startsWith(prefix)) continue;
        count[category] = count[category]! + 1;
        var size = 0;
        try {
          size = e is Directory
              ? await _dirBytes(e)
              : await (e as File).length();
        } catch (_) {}
        bytes[category] = bytes[category]! + size;
      }
    } catch (_) {}
  }

  /// 扫描 cache 根直接子项的 .zip 文件（zipCopies；后缀大小写不敏感）。
  static Future<void> _scanZipCopies(
    Directory cache, {
    required Map<CacheCategory, int> bytes,
    required Map<CacheCategory, int> count,
  }) async {
    try {
      for (final e in cache.listSync(followLinks: false)) {
        if (e is! File || !_basename(e).toLowerCase().endsWith('.zip')) {
          continue;
        }
        count[CacheCategory.zipCopies] = count[CacheCategory.zipCopies]! + 1;
        try {
          bytes[CacheCategory.zipCopies] =
              bytes[CacheCategory.zipCopies]! + await e.length();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 删除 parent 直接子项中匹配 [prefix] 的条目（逐项 try/catch）。
  /// 返回命中的条目数（无论删除成败）——供调用方决定是否写 AppLog。
  static Future<int> _sweepPrefixed({
    required Directory parent,
    required String prefix,
    required bool dirsOnly,
    required CacheCategory category,
    required Map<CacheCategory, int> removed,
    required Map<CacheCategory, int> freedByCat,
    required void Function(String) progress,
  }) async {
    final targets = <FileSystemEntity>[];
    try {
      for (final e in parent.listSync(followLinks: false)) {
        final ok = dirsOnly ? e is Directory : e is File;
        if (!ok || !_basename(e).startsWith(prefix)) continue;
        targets.add(e);
      }
    } catch (_) {} // 目录不存在 / 无权限 → 无目标
    for (final t in targets) {
      await _deleteEntity(
        t,
        category: category,
        removed: removed,
        freedByCat: freedByCat,
        progress: progress,
      );
    }
    return targets.length;
  }

  /// 删除 cache 根直接子项的 .zip 文件（仅统计删除成功的项）。
  static Future<void> _sweepZipCopies(
    Directory cache, {
    required Map<CacheCategory, int> removed,
    required Map<CacheCategory, int> freedByCat,
    required void Function(String) progress,
  }) async {
    final targets = <File>[];
    try {
      for (final e in cache.listSync(followLinks: false)) {
        if (e is! File || !_basename(e).toLowerCase().endsWith('.zip')) {
          continue;
        }
        targets.add(e);
      }
    } catch (_) {}
    for (final f in targets) {
      await _deleteEntity(
        f,
        category: CacheCategory.zipCopies,
        removed: removed,
        freedByCat: freedByCat,
        progress: progress,
      );
    }
  }

  /// 删除单个条目（文件或目录）：不存在 → 跳过；失败 → 进度提示并跳过，
  /// 不计 removed/freedBytes。成功 → 先把字节计入 freedBytes 再删。
  static Future<void> _deleteEntity(
    FileSystemEntity e, {
    required CacheCategory category,
    required Map<CacheCategory, int> removed,
    required Map<CacheCategory, int> freedByCat,
    required void Function(String) progress,
  }) async {
    if (!e.existsSync()) return;
    var bytes = 0;
    try {
      bytes = e is Directory ? await _dirBytes(e) : await (e as File).length();
    } catch (_) {}
    try {
      if (e is Directory) {
        e.deleteSync(recursive: true);
      } else {
        (e as File).deleteSync();
      }
    } catch (err) {
      progress('删除失败（已跳过）：${e.path}（$err）');
      return;
    }
    removed[category] = removed[category]! + 1;
    freedByCat[category] = freedByCat[category]! + bytes;
    progress('已删除：${e.path}');
  }

  /// 递归统计目录字节（逐文件 length；权限/占用异常跳过该项，不抛）。
  static Future<int> _dirBytes(Directory d) async {
    var total = 0;
    try {
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is File) {
          try {
            total += await e.length();
          } catch (_) {}
        }
      }
    } catch (_) {}
    return total;
  }

static String _basename(FileSystemEntity e) {
    // 目录的 uri 以 '/' 结尾，pathSegments 末位是空串 → 过滤空段。
    final segs = e.uri.pathSegments.where((s) => s.isNotEmpty);
    return segs.isEmpty ? e.path : segs.last;
  }

  static String _label(CacheCategory c) => switch (c) {
    CacheCategory.importTmp => '导入残留',
    CacheCategory.pkgValidate => '校验残留',
    CacheCategory.zipCopies => 'zip 拷贝',
    CacheCategory.backups => '旧库备份',
    CacheCategory.updateApks => '旧版安装包',
  };

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);
}
