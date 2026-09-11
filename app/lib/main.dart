// 恒牙 App 入口
// M2（审计 P0 整改）：启动即注入离线队列持久层，App 被杀不丢评分
// M3：启动按用户设置注册每日本地提醒（13.2 防断签兜底）
// M3-5：生产包编译期注入 API_BASE/API_TOKEN + CA 证书 pinning
// 问1+5：启动即注入离线缓存持久层（断网/服务器故障时只读数据回退）
// Phase 1（local-first）：BACKEND=local 启动即注入数据目录
//（getApplicationSupportDirectory()/{hengya.db, corpus/}，一人一机一库）
// Phase 4：端上拆卡流水线接线——/pipeline/trigger 落 .force_run 后经
// pipelineKick 后台消费（六步总编排 pipeline_runner.runCatchup）；启动即
// 消费上次遗留标志（上次失败重试/跨会话排队语义，≈force-check.sh cron）。
import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'services/api/api_client.dart';
import 'services/api/local_cache.dart';
import 'services/local/app_log.dart';
import 'services/local/data_manager.dart';
import 'services/local/full_backup.dart';
import 'services/local/local_backend.dart';
import 'services/local/pipeline_runner.dart';
import 'services/notification/daily_reminder.dart';

/// v0.1.9 日志基建：全局兜底三件套注入（先于 runApp）——① [FlutterError.onError]
/// 框架异常 ② [PlatformDispatcher.onError] 平台通道异常 ③ runZonedGuarded
/// zone 内其余未捕获异步异常。全部经 [AppLog] 落盘（真机崩溃/未捕获自查）。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // ①框架异常（build/layout/paint…）：落盘 + 保留框架既有呈现
  //（FlutterError.presentError：debug 红屏 / release 默认上报路径）。
  FlutterError.onError = (details) {
    AppLog.instance.log(
      AppLogLevel.error,
      'flutter',
      '${details.exceptionAsString()}'
          '${details.stack == null ? '' : '\n${details.stack}'}',
    );
    FlutterError.presentError(details);
  };
  // ②平台通道 / 异步平台错误（root zone）：落盘即视为已处理（return true
  // 不再上抛重复告警）。
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    AppLog.instance.log(AppLogLevel.error, 'platform', '$error\n$stack');
    return true;
  };
  // ③zone 内未捕获异常：原入口主体移入 _mainImpl（保留既有同步初始化结构，
  // 改动最小化），任何未捕获异步异常回落到 zone 处理器落盘。
  runZonedGuarded(() => _mainImpl(), (error, stack) {
    AppLog.instance.log(AppLogLevel.error, 'zone', '$error\n$stack');
  });
}

/// 原 main 主体（兜底注入后原样保留：ensureInitialized 幂等可重复调用）。
Future<void> _mainImpl() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  ApiClient.instance.offlineStore = SharedPrefsAnswerStore(prefs);
  // 离线缓存（只读端点最近一次成功响应；token 等敏感信息绝不入缓存）
  LocalCache.instance.attach(SharedPrefsCacheStore(prefs));
  // Phase 1：本地模式注入数据目录（hengya.db + corpus/ 挂其下；
  // 未初始化就调用会显式 StateError，而非静默写错位置）
  if (kBackendMode == BackendMode.local) {
    final support = await getApplicationSupportDirectory();
    // 上次恢复若被系统中断，必须在任何数据库连接打开前先恢复一致状态。
    FullBackupManager.instance.recoverInterruptedRestore(support.path);
    LocalBackend.instance.init(support.path);
    // 安全修复 C：AI 服务 key 从 settings 表明文迁入系统安全存储
    //（AiKeyVault，Android Keystore 加密）。启动即执行一次性迁移（幂等，
    // 防旧库升级后 key 丢失）并预热内存缓存——vault 读写是异步平台通道，
    // 路由/流水线运行期经 LocalBackend.aiKeyOf 同步取用；先于流水线接线
    //（worker 依赖缓存预热后随请求下发 key）。
    await LocalBackend.instance.initAiKeys();
    // Phase 2：48h 冷启动自动备份（滚动 7 份；同步毫秒级，不阻塞启动）
    DataManager.instance.autoBackupIfNeeded(support.path);
    // Phase 4：流水线后台执行接线（路由 kick + 启动消费遗留 .force_run）
    LocalBackend.pipelineKick = PipelineRunner.instance.consumeForceRun;
    unawaited(
      PipelineRunner.instance.consumeForceRun(
        trigger: kPipelineTriggerStartup, // #13：启动消费遗留标志（非用户手动）
      ),
    );
  }
  // 每日提醒：按已存设置幂等重注册（开机自启后通知权限就绪场景）
  final s = await DailyReminder.instance.loadSettings();
  await DailyReminder.instance.apply(
    enabled: s.enabled,
    hour: s.hour,
    minute: s.minute,
  );
  // M3-5 证书 pinning：仅远程模式且走 https 时，只信内置自签 CA（防中间人）
  //（demo/local 无网络请求，不需要）。开源版不随库分发 CA 证书（私有资产，
  // *.pem 已 gitignore）：证书资产缺失时安全降级——跳过 pinning 走系统
  // 信任链，仅提示不崩。自备 CA 的开发者：把 ca.pem 放到 app/assets/certs/
  // 并在 pubspec 的 flutter.assets 加回 - assets/certs/ca.pem 即恢复 pinning。
  if (kBackendMode == BackendMode.remote &&
      ApiClient.instance.baseUrl.startsWith('https')) {
    try {
      final ca = await rootBundle.load('assets/certs/ca.pem');
      ApiClient.instance.pinCaCertificate(ca.buffer.asUint8List());
    } catch (_) {
      debugPrint(
        '[恒牙] assets/certs/ca.pem 未打包（开源版默认不内置 CA），'
        '本次启动跳过证书固定，远程 HTTPS 将走系统信任链。',
      );
    }
  }
  runApp(const HengyaApp());
  // 启动日志（异步补足，不阻塞首帧）：版本 + 剩余存储。
  unawaited(_logStartupAsync());
}

/// 启动日志：版本（PackageInfo）+ 剩余存储（所在盘估算；取不到写 unknown）。
/// 只读公开数据，不含任何敏感值；任何失败降级为 unknown。
Future<void> _logStartupAsync() async {
  var version = 'unknown';
  try {
    final info = await PackageInfo.fromPlatform();
    version = info.version;
  } catch (_) {}
  var storage = 'unknown';
  try {
    final docs = await getApplicationDocumentsDirectory();
    final freeMb = _freeDiskSpaceMb(docs.path);
    if (freeMb != null) storage = '$freeMb MB';
  } catch (_) {}
  AppLog.instance.log(
    AppLogLevel.info,
    'startup',
    '启动：版本 $version，剩余存储 $storage',
  );
}

/// 剩余存储估算（MB，best-effort）：取不到 → null（调用方写 unknown）。
/// Android/Linux 走 libc statvfs（<路径> 所在文件系统，即 getApplication
/// DocumentsDirectory 所在盘）；Windows 走 kernel32 GetDiskFreeSpaceExW；
/// 其余平台 → null。全程异常吞掉返回 null。
int? _freeDiskSpaceMb(String path) {
  try {
    if (Platform.isAndroid || Platform.isLinux) return _statvfsFreeMb(path);
    if (Platform.isWindows) return _windowsFreeMb(path);
  } catch (_) {}
  return null;
}

/// statvfs：struct 布局按指针位宽分支（LP64 / ILP32），以原始缓冲按偏移
/// 读取，避免 Struct ABI 绑定。自由字节 = f_bavail × f_frsize
/// （f_frsize 为 0 时退 f_bsize）。
///
/// bionic/glibc struct statvfs（字段即 unsigned long / fsblkcnt_t；8/4 字节）：
///   64 位：f_bsize@0(8) f_frsize@8(8) f_bavail@32(8)
///   32 位：f_bsize@0(4) f_frsize@4(4) f_bavail@24(8)
int? _statvfsFreeMb(String path) {
  final statvfs = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Pointer<Uint8>),
        int Function(Pointer<Utf8>, Pointer<Uint8>)
      >('statvfs');
  final cPath = path.toNativeUtf8();
  final buf = calloc<Uint8>(128); // 覆盖 64/32 位 struct 全字段
  try {
    if (statvfs(cPath, buf) != 0) return null;
    final is64 = sizeOf<IntPtr>() == 8;
    final bsize = is64 ? buf.cast<Uint64>().value : buf.cast<Uint32>().value;
    final frsize = is64
        ? (buf.cast<Uint64>() + 1).value
        : (buf.cast<Uint32>() + 1).value;
    final bavail = is64
        ? (buf.cast<Uint64>() + 4).value
        : (buf.cast<Uint64>() + 3).value;
    final block = frsize != 0 ? frsize : bsize;
    if (block == 0) return null;
    return (bavail * block) ~/ (1024 * 1024);
  } finally {
    calloc.free(cPath);
    calloc.free(buf);
  }
}

/// GetDiskFreeSpaceExW（kernel32）：取 lpFreeBytesAvailableToCaller——
/// 配额感知的「应用实际可用量」，比 totalFree 更贴近真实可写空间。
int? _windowsFreeMb(String path) {
  final getFree = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<
        Int32 Function(
          Pointer<Utf16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        ),
        int Function(
          Pointer<Utf16>,
          Pointer<Uint64>,
          Pointer<Uint64>,
          Pointer<Uint64>,
        )
      >('GetDiskFreeSpaceExW');
  final cPath = path.toNativeUtf16();
  final avail = calloc<Uint64>();
  final total = calloc<Uint64>();
  final free = calloc<Uint64>();
  try {
    if (getFree(cPath, avail, total, free) == 0) return null;
    return avail.value ~/ (1024 * 1024);
  } finally {
    calloc.free(cPath);
    calloc.free(avail);
    calloc.free(total);
    calloc.free(free);
  }
}
