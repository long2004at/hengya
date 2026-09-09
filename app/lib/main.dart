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

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'services/api/api_client.dart';
import 'services/api/local_cache.dart';
import 'services/local/data_manager.dart';
import 'services/local/local_backend.dart';
import 'services/local/pipeline_runner.dart';
import 'services/notification/daily_reminder.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  ApiClient.instance.offlineStore = SharedPrefsAnswerStore(prefs);
  // 离线缓存（只读端点最近一次成功响应；token 等敏感信息绝不入缓存）
  LocalCache.instance.attach(SharedPrefsCacheStore(prefs));
  // Phase 1：本地模式注入数据目录（hengya.db + corpus/ 挂其下；
  // 未初始化就调用会显式 StateError，而非静默写错位置）
  if (kBackendMode == BackendMode.local) {
    final support = await getApplicationSupportDirectory();
    LocalBackend.instance.init(support.path);
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
}
