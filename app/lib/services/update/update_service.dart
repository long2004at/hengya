// 应用内更新服务（batch3 node1，2026-09-07）——**云直链单通道**（已拍板）：
// 用户个人阿里云 ECS 上 nginx 静态分发 latest.json + APK，无任何其它更新通道。
//
// 职责（设置页只渲染状态，全部逻辑/文案在此）：
//   · 更新源 URL 持久化：db settings key=update.source（settingGet/settingSet）
//   · checkUpdate：GET 源 latest.json（8s 超时）→ 防御式解析 → versionCode 比较
//   · downloadAndVerify：直链下载（apk 为相对源目录文件名）→ 进度回调 →
//     SHA-256 校验（crypto 已有依赖，不新增）→ 不符 → 删文件 + 报错
//   · installApk：MethodChannel 唤起系统安装器（Android 不允许静默安装）；
//     未授「安装未知应用」→ 结构化错误码 not_authorized → 页面引导跳授权页
//
// 测试 seam（对齐 LocalBackend.corpusBuildJobOverride 风格）：
//   · debugFetchOverride   —— 替代 HTTP 取 latest.json 原文（testWidgets 宿主
//     HttpClient 是恒 400 假实现，UI 测试必须注入）
//   · debugChannelOverride —— 替代原生 MethodChannel（宿主非 Android 时也能
//     提供 getPackageInfo / installApk 假响应）
//
// 契约见 docs/ECS更新服务部署指南.md；latest.json 由 tools/release_build.ps1 生成：
//   {"versionName":"1.7.0+15","versionCode":15,"apk":"heng-1.7.0+15-local-release.apk",
//    "sha256":"<64hex>","sizeBytes":80530636,"date":"ISO8601","notes":"更新说明"}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart' show MethodChannel, MissingPluginException;

import '../local/local_backend.dart';

/// latest.json 数据模型（防御式解析：任何字段缺失/类型不符 → null，页面报「源数据不完整」）
class UpdateManifest {
  const UpdateManifest({
    required this.versionName,
    required this.versionCode,
    required this.apk,
    required this.sha256,
    required this.sizeBytes,
    this.date,
    this.notes = '',
  });

  /// 形如 "1.7.0+15"（展示用；比较只认 versionCode）
  final String versionName;

  /// 递增的整数版本号（App 只认这个判断谁新）
  final int versionCode;

  /// 相对更新源所在目录的 APK 文件名（纯 ASCII，禁止路径分隔符——防穿越）
  final String apk;

  /// 64 位十六进制 SHA-256（统一小写比较）
  final String sha256;

  /// 字节数（可缺省 0 → 展示「大小未知」、进度条转不确定态）
  final int sizeBytes;

  final String? date;

  /// 更新说明（可多行；仅展示，不参与任何判断）
  final String notes;

  /// 解析 latest.json 原文；非法/缺字段 → null。
  static UpdateManifest? tryParse(String body) {
    Object decoded;
    try {
      decoded = jsonDecode(body);
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final versionName = decoded['versionName'];
    final versionCode = decoded['versionCode'];
    final apk = decoded['apk'];
    final sha256 = decoded['sha256'];
    if (versionName is! String || versionName.isEmpty) return null;
    if (versionCode is! int || versionCode <= 0) return null;
    if (apk is! String || apk.isEmpty) return null;
    if (apk.contains('/') || apk.contains('\\')) return null;
    if (sha256 is! String || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(sha256)) {
      return null;
    }
    final sizeBytes = decoded['sizeBytes'];
    final date = decoded['date'];
    final notes = decoded['notes'];
    return UpdateManifest(
      versionName: versionName,
      versionCode: versionCode,
      apk: apk,
      sha256: sha256.toLowerCase(),
      sizeBytes: sizeBytes is int ? sizeBytes : 0,
      date: date is String ? date : null,
      notes: notes is String ? notes : '',
    );
  }

  /// 大小展示：「76.8 MB」；sizeBytes 缺省 0 → 「大小未知」
  String get sizeDisplay =>
      sizeBytes > 0 ? '${(sizeBytes / 1048576).toStringAsFixed(1)} MB' : '大小未知';
}

/// 检查结果。available=false 即「已是最新」（相等/更旧均不提示——降级拒绝）。
class UpdateCheckResult {
  const UpdateCheckResult({
    required this.available,
    required this.manifest,
    required this.currentVersionName,
    required this.currentVersionCode,
  });

  final bool available;
  final UpdateManifest? manifest;
  final String currentVersionName;
  final int currentVersionCode;
}

/// 更新流程唯一异常类型（message 已是可直接展示的中文文案）
class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 设置页更新区块的状态机（渲染所需的全部相位；文案见 [UpdateMessages]）
enum UpdateUiPhase {
  /// 初始（未检查/刚进入）——不渲染状态区
  idle,

  /// 检查中
  checking,

  /// 已是最新
  upToDate,

  /// 发现新版本（notes + 大小 + 「下载并安装」）
  available,

  /// 下载中（百分比 + 进度条）
  downloading,

  /// 校验失败（sha256 不符；文件已删）
  verifyFailed,

  /// 未授「安装未知应用」权限 → 引导跳设置
  needPermission,

  /// 已唤起系统安装器（等用户点系统确认）
  installHandoff,

  /// 网络失败/解析失败等（_updateError 承载消息）
  failed,
}

/// 更新区块文案（逐字；测试断言以此为准）
class UpdateMessages {
  const UpdateMessages._();

  static const sourceLabel = '更新源（latest.json 直链）';
  static const sourceHint = 'http://<ECS-IP>:8443/heng-<token>/latest.json';
  static const checkButton = '检查更新';
  static const downloadButton = '下载并安装';

  static const checking = '正在检查更新…';
  static String upToDate(String versionName) => '已是最新版本（v$versionName）';
  static String foundNew(String versionName) => '发现新版本 v$versionName';
  static String sizeOf(UpdateManifest m) => '大小 ${m.sizeDisplay}';
  static const downloadingKnown = '正在下载… {pct}%（{got} MB / {total} MB）';
  static String downloadingUnknown(int got) => '正在下载… 已下载 ${_mb(got)} MB';
  static const verifyFailed = '安装包校验失败（SHA-256 不符），已删除下载文件；请重试或检查更新源';
  static const needPermission = '未授予「安装未知应用」权限，无法完成安装';
  static const goGrantPermission = '去授权';
  static const installHandoff = '已唤起系统安装器，请在系统弹窗中确认安装';
  static String installFailed(String code) => '安装失败（$code）';

  static const emptySource = '请先填写更新源';
  static const badSourceUrl = '更新源地址无效（需 http/https 直链）';
  static const manifestBad = '更新源数据无法解析或缺少必要字段';
  static const unreachable = '无法连接更新源，请检查网络或稍后重试';
  static String httpStatus(int status) => '更新源返回 HTTP $status';
  static String downloadHttpStatus(int status) => '下载失败：HTTP $status';
  static const downloadIncomplete = '下载中断，文件不完整';
  static const noCurrentVersion = '无法读取当前应用版本';
  static const noDataDir = '本地数据目录未初始化';

  static String _mb(int bytes) => (bytes / 1048576).toStringAsFixed(1);
}

class UpdateService {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  // ---------------- 常量与通道 ----------------

  /// db settings 键（settingGet/settingSet 持久化）
  static const String sourceKey = 'update.source';

  /// 唯一原生通道（协议见 MainActivity.kt 头注释）
  static const MethodChannel _channel = MethodChannel('dev.hengya.hengya/update');

  // ---------------- 测试 seam（对齐项目 Override 静态注入风格） ----------------

  /// 非 null 时 [checkUpdate] 经此取 latest.json 原文（不再走真 HttpClient）。
  /// widget 测试必须注入（testWidgets 宿主 HttpClient 为恒 400 假实现）。
  static Future<String> Function(String sourceUrl)? debugFetchOverride;

  /// 非 null 时全部原生调用经此（假 getPackageInfo/installApk 响应）。
  static Future<Object?> Function(String method, [Map<String, dynamic>? args])?
      debugChannelOverride;

  static Future<Object?> _invoke(String method, [Map<String, dynamic>? args]) async {
    final override = debugChannelOverride;
    if (override != null) return override(method, args);
    try {
      return await _channel.invokeMethod(method, args);
    } on MissingPluginException {
      return null; // 宿主非 Android / 无 handler：上层按错误展示，不炸页面
    }
  }

  // ---------------- 源 URL 持久化（db settings） ----------------

  Future<String?> getSourceUrl() async {
    final db = await LocalBackend.instance.sharedDb;
    return db.settingGet(sourceKey);
  }

  Future<void> setSourceUrl(String url) async {
    final db = await LocalBackend.instance.sharedDb;
    db.settingSet(sourceKey, url);
  }

  // ---------------- 当前版本 ----------------

  /// 当前包信息（Kotlin PackageManager；longVersionCode 兜 API<28）。
  Future<({String versionName, int versionCode})> currentPackageInfo() async {
    final res = await _invoke('getPackageInfo');
    if (res is Map &&
        res['versionName'] is String &&
        res['versionCode'] is num) {
      return (
        versionName: res['versionName'] as String,
        versionCode: (res['versionCode'] as num).toInt(),
      );
    }
    throw UpdateException(UpdateMessages.noCurrentVersion);
  }

  // ---------------- 检查更新 ----------------

  /// [sourceUrl] 显式传入（页面用输入框值；测试直填），否则读 db 持久值。
  Future<UpdateCheckResult> checkUpdate({String? sourceUrl}) async {
    final src = (sourceUrl ?? (await getSourceUrl()) ?? '').trim();
    if (src.isEmpty) throw UpdateException(UpdateMessages.emptySource);
    final uri = Uri.tryParse(src);
    if (uri == null || !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw UpdateException(UpdateMessages.badSourceUrl);
    }
    final body = await _fetchLatest(uri);
    final manifest = UpdateManifest.tryParse(body);
    if (manifest == null) throw UpdateException(UpdateMessages.manifestBad);
    final info = await currentPackageInfo();
    return UpdateCheckResult(
      available: manifest.versionCode > info.versionCode,
      manifest: manifest,
      currentVersionName: info.versionName,
      currentVersionCode: info.versionCode,
    );
  }

  Future<String> _fetchLatest(Uri uri) async {
    final override = debugFetchOverride;
    if (override != null) {
      try {
        return await override(uri.toString());
      } on UpdateException {
        rethrow;
      } catch (_) {
        throw UpdateException(UpdateMessages.unreachable);
      }
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final rq = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 8));
      final rs = await rq.close().timeout(const Duration(seconds: 8));
      if (rs.statusCode != 200) {
        await rs.drain<void>();
        throw UpdateException(UpdateMessages.httpStatus(rs.statusCode));
      }
      return await rs
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 8));
    } on UpdateException {
      rethrow;
    } on TimeoutException {
      throw UpdateException(UpdateMessages.unreachable);
    } on IOException {
      throw UpdateException(UpdateMessages.unreachable);
    } catch (_) {
      throw UpdateException(UpdateMessages.unreachable);
    } finally {
      client.close();
    }
  }

  // ---------------- 下载 + 校验 ----------------

  /// 下载目录：dataDir/update/（不引新插件；与语料库同数据根）
  Future<String> _downloadDir() async {
    final dataDir = LocalBackend.instance.dataDir;
    if (dataDir == null) throw UpdateException(UpdateMessages.noDataDir);
    final dir = Directory('$dataDir/update');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  /// APK 直链：apk 为相对源目录的文件名 → Uri.resolve 同目录拼接
  /// （源 .../latest.json + heng-x.apk → .../heng-x.apk）。
  Uri apkUrlOf(UpdateManifest manifest, String sourceUrl) {
    final base = Uri.tryParse(sourceUrl.trim());
    if (base == null || !base.hasScheme) {
      throw UpdateException(UpdateMessages.badSourceUrl);
    }
    return base.resolve(manifest.apk);
  }

  /// 收尾辅助（全程吞错：失败路径上的清理失败不掩盖原始错误）
  static Future<void> _closeQuietly(IOSink? sink) async {
    try {
      await sink?.close();
    } catch (_) {}
  }

  static void _deleteQuietly(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 下载到 dataDir/update/ 下（文件名取 manifest.apk）并做 SHA-256 校验。
  /// [onProgress](received, total)；total 为 null = 大小未知（页面转不确定进度）。
  /// 校验失败 → 删文件 + [UpdateMessages.verifyFailed]。
  Future<File> downloadAndVerify(
    UpdateManifest manifest, {
    required String sourceUrl,
    void Function(int received, int? total)? onProgress,
  }) async {
    final dir = await _downloadDir();
    final dest = File('$dir/${manifest.apk}');
    final url = apkUrlOf(manifest, sourceUrl);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    IOSink? sink;
    var received = 0;
    try {
      final rq = await client.getUrl(url).timeout(const Duration(seconds: 8));
      final rs = await rq.close();
      if (rs.statusCode != 200) {
        await rs.drain<void>();
        throw UpdateException(UpdateMessages.downloadHttpStatus(rs.statusCode));
      }
      final contentLength = rs.contentLength >= 0 ? rs.contentLength : null;
      final total = contentLength ??
          (manifest.sizeBytes > 0 ? manifest.sizeBytes : null);
      sink = dest.openWrite();
      await for (final chunk in rs) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
      await sink.flush();
      await sink.close();
      sink = null;
      if (contentLength != null && received != contentLength) {
        throw UpdateException(UpdateMessages.downloadIncomplete);
      }
    } on UpdateException {
      await _closeQuietly(sink);
      _deleteQuietly(dest); // 下载中断不留半截文件
      rethrow;
    } catch (_) {
      await _closeQuietly(sink);
      _deleteQuietly(dest);
      throw UpdateException(UpdateMessages.unreachable);
    } finally {
      await _closeQuietly(sink);
      client.close();
    }

    // SHA-256 校验（流式；80MB 级 APK 不整读入内存）
    final digest = await crypto.sha256.bind(dest.openRead()).first;
    if (digest.toString() != manifest.sha256) {
      try {
        dest.deleteSync();
      } catch (_) {}
      throw UpdateException(UpdateMessages.verifyFailed);
    }
    return dest;
  }

  // ---------------- 安装 ----------------

  /// 唤起系统安装器。null = 已唤起；否则返回结构化错误码
  /// （'not_authorized' → 页面转授权引导相位；其余 → 失败文案）。
  Future<String?> installApk(String path) async {
    final res = await _invoke('installApk', {'path': path});
    if (res is Map && res['ok'] != true) {
      return (res['code'] is String) ? res['code'] as String : 'error';
    }
    if (res == null) return 'error'; // 通道缺失（非 Android 宿主）
    return null;
  }

  /// 跳系统「安装未知应用」授权页（Kotlin 端兜底跳应用详情设置）
  Future<void> openInstallPermissionSettings() async {
    await _invoke('openInstallPermissionSettings');
  }
}
