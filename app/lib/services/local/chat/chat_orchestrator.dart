// 恒牙（hengya）· DeepSeek 双通道聊天 · 编排层（chat_orchestrator.dart）
// ============================================================================
//
// P3.1 双通道自动退回：反代通道（chat.* + AiKeyVault 'chat'）优先发起流式
// 请求；反代未配置或请求失败（连不上/超时/HTTP>=400/空流）且**一个 delta 都
// 没收到**时，自动退回官方 LLM 通道（svc='llm' 的 baseUrl/model + key，
// OpenAI 兼容，走同一个 chatStream——官方是正规 CA 证书，绝不套用反代自签
// pinning）。反代已吐出部分增量后才失败 → 不退回重发（用户已看到半截答案），
// 错误直接抛出（气泡显示错误文案）。
//
// P3.2 预设档案消费：若 chat.presetId 非空且对应档案存在，反代通道改用档案
// 的 baseUrl/model/温度 + vault svc `preset.<id>` 的 key 组配置；否则回落
// chat.* 直读（P2 行为零变化）。官方退回通道不受 preset 影响（永远 svc='llm'）。
//
// 纪律：本层只做编排（选通道/退回判定/日志），不持有传输状态；日志/错误
// 消息绝不携带 apiKey。
import 'dart:async';

import '../app_log.dart';
import '../local_backend.dart';
import 'chat_transport.dart';

/// 通道标识（chat_messages.channel 列口径）：反代通道成功。
const String kChatChannelProxy = 'proxy';

/// 通道标识：退回官方 LLM 通道成功。
const String kChatChannelOfficial = 'official';

/// 编排结果：本次回答实际走了哪条通道 + 额外语义标记。
class ChatOrchestration {
  const ChatOrchestration({
    required this.channel,
    this.fallbackUsed = false,
  });

  /// 实际通道：'proxy' | 'official'（与 chat_messages.channel 同口径）。
  final String channel;

  /// 本次发送是否发生了退回（聊天页据此弹 TopToast 提示）。
  final bool fallbackUsed;
}

/// 双通道流式聊天编排。
///
/// [proxyCfg] 反代通道配置（聊天页组好：preset 或 chat.* 直读，见
/// [loadChatProxyConfig]）；null 或未配置（缺 baseUrl/key/model 任一）=
/// 反代不可用，直接走官方。两者都失败 → 抛 [ChatTransportException]，
/// 消息说明两通道都试过（不含 key）。
///
/// 退回语义（delta 计数器实现）：反代 [onDelta] 已回调过 ≥1 次后再失败，
/// 不退回、原错误上抛；零 delta 的失败才切官方重发。
Future<ChatOrchestration> chatOrchestrate(
  ChatTransportConfig? proxyCfg,
  List<({String role, String content})> messages, {
  required void Function(String piece) onDelta,
  void Function(int promptTokens, int completionTokens)? onDone,
  ChatTransportConfig? officialCfg,
}) async {
  final proxyReady = proxyCfg != null && proxyCfg.configured;
  final officialReady = officialCfg != null && officialCfg.configured;

  // 反代可用先走反代（含 pinning 指纹；自签证书反代专用）。
  if (proxyReady) {
    var deltas = 0;
    try {
      await chatStream(
        proxyCfg,
        messages,
        onDelta: (piece) {
          deltas++;
          onDelta(piece);
        },
        onDone: onDone,
        // 预设可能指向其他 HTTPS 服务，仅自签网关使用其证书指纹。
        pinnedFingerprint: proxyCfg.baseUrl.startsWith('$kChatDefaultBaseUrl/') ||
                proxyCfg.baseUrl.replaceAll(RegExp(r'/+$'), '') ==
                    kChatDefaultBaseUrl
            ? kChatProxyCertSha256
            : null,
      );
      return const ChatOrchestration(channel: kChatChannelProxy);
    } on ChatTransportException catch (e) {
      if (deltas > 0) {
        // 部分流式失败：不退回重发（用户已看到半截答案），原错误上抛。
        rethrow;
      }
      _logFallback(e.message);
      if (!officialReady) {
        throw ChatTransportException('反代不可用（${e.message}）且官方通道未配置');
      }
    }
  }

  // 官方通道（退回或反代未配置时的唯一通道；正规 CA，无 pinning）。
  if (!officialReady) {
    throw const ChatTransportException(
      '聊天服务未配置（需服务地址 / 密钥 / 模型）',
    );
  }
  try {
    await chatStream(officialCfg, messages, onDelta: onDelta, onDone: onDone);
  } on ChatTransportException catch (e) {
    throw ChatTransportException(
      proxyReady
          ? '反代与官方通道均失败：反代（未收到内容）、官方（${e.message}）'
          : '官方通道请求失败：${e.message}',
    );
  }
  return ChatOrchestration(
    channel: kChatChannelOfficial,
    fallbackUsed: proxyReady,
  );
}

/// 退回事件日志（AppLog info；消息不含 key）。
void _logFallback(String proxyError) {
  try {
    AppLog.instance.log(
      AppLogLevel.info,
      'chat',
      '聊天通道退回：反代失败($proxyError)，已用官方通道',
    );
  } catch (_) {
    // 日志为兜底录，自身失败绝不影响编排。
  }
}

/// 组反代通道配置（聊天页发送前调用）：`chat.presetId` 指向存在的档案 →
/// 档案 baseUrl/model/温度 + vault svc `preset.<id>`；否则 chat.* 直读 +
/// aiKeyOf('chat')（P2 行为）。数据层异常/未初始化 → null（编排层会走官方
/// 退回或抛「未配置」）。
Future<ChatTransportConfig?> loadChatProxyConfig() async {
  try {
    await LocalBackend.instance.initAiKeys();
    final db = await LocalBackend.instance.sharedDb;
    final presetId = db.settingGet('chat.presetId') ?? '';
    if (presetId.isNotEmpty) {
      final baseUrl = db.settingGet('preset.$presetId.baseUrl') ?? '';
      final model = db.settingGet('preset.$presetId.model') ?? '';
      final apiKey = LocalBackend.instance.aiKeyOf('preset.$presetId');
      final tempRaw = db.settingGet('preset.$presetId.temperature') ?? '';
      final temperature = double.tryParse(tempRaw);
      if (baseUrl.isNotEmpty && model.isNotEmpty && apiKey.isNotEmpty) {
        return ChatTransportConfig(
          baseUrl: baseUrl,
          apiKey: apiKey,
          model: model,
          temperature: temperature,
        );
      }
      // 档案存在但配置不齐（如 key 未设）→ 回落 chat.* 直读。
    }
    final baseUrl = db.settingGet('chat.baseUrl') ?? '';
    final model = db.settingGet('chat.model') ?? '';
    final apiKey = LocalBackend.instance.aiKeyOf('chat');
    if (baseUrl.isEmpty || apiKey.isEmpty || model.isEmpty) return null;
    return ChatTransportConfig(baseUrl: baseUrl, apiKey: apiKey, model: model);
  } catch (_) {
    return null;
  }
}

/// 组官方退回通道配置（svc='llm' 直读；vault key 经内存缓存同步取）。
/// 未配置 → null（编排层据此跳过官方通道）。
Future<ChatTransportConfig?> loadChatOfficialConfig() async {
  try {
    await LocalBackend.instance.initAiKeys();
    final db = await LocalBackend.instance.sharedDb;
    final baseUrl = db.settingGet('llm.baseUrl') ?? '';
    final model = db.settingGet('llm.model') ?? '';
    final apiKey = LocalBackend.instance.aiKeyOf('llm');
    if (baseUrl.isEmpty || apiKey.isEmpty || model.isEmpty) return null;
    return ChatTransportConfig(baseUrl: baseUrl, apiKey: apiKey, model: model);
  } catch (_) {
    return null;
  }
}
