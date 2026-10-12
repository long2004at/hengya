// 恒牙（hengya）· DeepSeek 双通道聊天 · 传输层（chat_transport.dart）
// ============================================================================
//
// 聊天会话专用的 OpenAI 兼容流式客户端（P2.1）：POST {baseUrl}/chat/completions
// + SSE 增量回调。语义与拆卡传输层 run_llm.dart 的 _llmPost/_readSse 一致，
// 但独立实现且不复用 LlmException——拆卡的失败语义（token 熔断/failover/
// HTTP 400 降级梯）只属于生卡流水线，聊天不复用以免混淆（红线：不动 run_llm）。
//
// 证书 pinning：服务器反代为自签证书（10 年，CN=47.100.82.115.nip.io），
// Dart 的 HttpClient 走 badCertificateCallback 校验服务器证书 SHA256 指纹
// （cert.der 再 sha256，package:crypto；pubspec 既有依赖）。指纹不符即拒绝，
// 杜绝中间人；HTTPS 之外（http:// 本地测试宿主）不会触发该回调。
//
// 纪律：日志/错误消息绝不携带 apiKey；User-Agent 浏览器风格（WAF 拦默认 UA）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// 聊天代理服务器证书 SHA256 指纹（冒号分隔大写十六进制）。
/// 证书为自签 10 年（CN=47.100.82.115.nip.io）；换证书必须同步改这里。
const String kChatProxyCertSha256 =
    '3E:5E:57:76:9A:DA:9D:19:6A:5D:EC:37:E0:2F:E6:6B:F0:6C:17:B1:'
    '09:60:F6:39:A1:D4:AA:8F:6F:DB:39:E7';

/// 浏览器风格 UA（与 run_llm.kBrowserUa 逐字一致；复制常量而非 import，
/// 避免聊天层与拆卡层产生编译期耦合）。
const String kChatUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

/// 聊天服务默认预填（P2.4 设置页「聊天服务」卡未配置时回填；用户可改任意）：
/// baseUrl = 反代 OpenAI 兼容基址（到 /v1），model = 反代默认模型。
const String kChatDefaultBaseUrl = 'https://47.100.82.115.nip.io:8443/v1';
const String kChatDefaultModel = 'v4.1flash';

/// 聊天传输配置（baseUrl 形如 https://host/v1；apiKey 为反代 Bearer key）。
class ChatTransportConfig {
  const ChatTransportConfig({
    required this.baseUrl,
    required this.apiKey,
    this.model = 'v4.1flash',
    this.timeoutSec = 120,
    this.temperature,
  });

  final String baseUrl;
  final String apiKey;
  final String model;

  /// 单次请求总超时（连接 + 全流读完）。聊天回答可长，默认 120s。
  final int timeoutSec;

  /// 温度可选：null = 不带 temperature 字段（服务端用默认值）。
  final double? temperature;

  bool get configured =>
      baseUrl.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;
}

/// 聊天传输失败（与拆卡 LlmException 刻意不同型：语义与处理方都不同）。
class ChatTransportException implements Exception {
  const ChatTransportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 逐字段比对 [cfg] 发起流式聊天请求：每收到一段 delta.content 即回调
/// [onDelta]（打字机增量）；流末 usage 块回调 [onDone]（网关不回则计 0）。
/// 思考链增量（delta.reasoning_content）静默忽略。
///
/// 错误一律抛 [ChatTransportException]，消息中文简洁（'连接超时' /
/// '服务返回 HTTP 502: …'）。未配置直接抛（调用方负责先引导设置）。
///
/// [pinnedFingerprint]（P3.1）：服务器证书 SHA256 指纹（冒号分隔十六进制，
/// 大小写不敏感）。null = 默认系统信任（不设 badCertificateCallback）——
/// 官方 LLM 通道是正规 CA 证书，绝不能套用反代的自签 pinning；非空 =
/// 自签证书验证失败时按指纹比对放行（反代通道）。
Future<void> chatStream(
  ChatTransportConfig cfg,
  List<({String role, String content})> messages, {
  required void Function(String piece) onDelta,
  void Function(int promptTokens, int completionTokens)? onDone,
  String? pinnedFingerprint,
}) async {
  if (!cfg.configured) {
    throw const ChatTransportException('聊天服务未配置（需服务地址 / 密钥 / 模型）');
  }
  final url = '${cfg.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
  final body = <String, Object?>{
    'model': cfg.model,
    'messages': [
      for (final m in messages) {'role': m.role, 'content': m.content},
    ],
    'stream': true,
    if (cfg.temperature != null) 'temperature': cfg.temperature,
  };

  // 指纹模式不能保留系统 CA 信任根，否则受信任但证书指纹不匹配时
  // badCertificateCallback 不会被调用，pinning 会被悄悄绕过。
  final client = HttpClient(
    context: pinnedFingerprint == null
        ? null
        : SecurityContext(withTrustedRoots: false),
  );
  try {
    // 自签证书 pinning（P3.1 可选）：只有指纹相符才放行；
    // null = 默认系统信任（官方通道或其他 HTTPS 预设）。
    if (pinnedFingerprint != null) {
      final expected = hexFingerprint(pinnedFingerprint);
      client.badCertificateCallback =
          (cert, host, port) => _certFingerprint(cert) == expected;
    }
    final req = await client.postUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.apiKey}');
    req.headers.contentType = ContentType.json;
    req.headers.set('User-Agent', kChatUa);
    // HttpClientRequest.write 可能按 latin1 编码；中文对话必须显式 UTF-8。
    req.add(utf8.encode(jsonEncode(body)));
    final resp = await req.close().timeout(
      Duration(seconds: cfg.timeoutSec),
      onTimeout: () {
        req.abort();
        throw const ChatTransportException('连接超时');
      },
    );
    if (resp.statusCode >= 400) {
      final raw = await resp.transform(utf8.decoder).join();
      final head = raw.length > 200 ? raw.substring(0, 200) : raw;
      throw ChatTransportException('服务返回 HTTP ${resp.statusCode}: $head');
    }
    var prompt = 0, completion = 0;
    await _readSse(
      resp,
      onDelta,
      usage: (p, c) {
        prompt = p;
        completion = c;
      },
    ).timeout(Duration(seconds: cfg.timeoutSec), onTimeout: () {
      req.abort();
      throw const ChatTransportException('连接超时');
    });
    onDone?.call(prompt, completion);
  } on ChatTransportException {
    rethrow;
  } on TimeoutException {
    throw const ChatTransportException('连接超时');
  } on SocketException catch (e) {
    throw ChatTransportException('网络连接失败：${e.message}');
  } catch (e) {
    throw ChatTransportException('聊天请求失败：${e.runtimeType}');
  } finally {
    client.close(force: true);
  }
}

/// SSE 流式读取（语义对齐 run_llm._readSse，带增量回调）：逐行取 data: 载荷，
/// [DONE] 终止，JSON 解析失败静默跳过，reasoning delta 忽略，usage 取流末块。
/// 读完全流 content 为空 → 视为失败（网关静默空流是故障不是空回答）。
Future<void> _readSse(
  HttpClientResponse resp,
  void Function(String piece) onDelta, {
  required void Function(int prompt, int completion) usage,
}) async {
  var hasContent = false;
  await for (final line
      in resp.transform(utf8.decoder).transform(const LineSplitter())) {
    final l = line.trim();
    if (!l.startsWith('data:')) {
      continue; // 跳过 event:/注释/空行
    }
    final data = l.substring(5).trim();
    if (data.isEmpty) {
      continue;
    }
    if (data == '[DONE]') {
      break;
    }
    Object? obj;
    try {
      obj = jsonDecode(data);
    } catch (_) {
      continue;
    }
    if (obj is! Map) {
      continue;
    }
    final u = obj['usage'];
    if (u is Map) {
      usage(
        (u['prompt_tokens'] as num?)?.toInt() ?? 0,
        (u['completion_tokens'] as num?)?.toInt() ?? 0,
      );
    }
    final choices = obj['choices'];
    if (choices is List) {
      for (final ch0 in choices) {
        if (ch0 is! Map) {
          continue;
        }
        final delta = ch0['delta'];
        if (delta is Map) {
          // delta.reasoning_content（思考链增量）刻意不取——聊天正文只有 content
          final piece = delta['content'];
          if (piece is String && piece.isNotEmpty) {
            hasContent = true;
            onDelta(piece);
          }
        }
      }
    }
  }
  if (!hasContent) {
    throw const ChatTransportException('服务返回内容为空');
  }
}

/// 证书 DER → 冒号分隔大写十六进制 SHA256 指纹（与 kChatProxyCertSha256 同形）。
String _certFingerprint(X509Certificate cert) =>
    hexFingerprint(sha256.convert(cert.der).toString());

/// 归一化任意十六进制串（可含冒号）为冒号分隔大写形态，供两侧统一比对。
/// （公开：编排层/设置校验与测试共用同一归一口径。）
String hexFingerprint(String hex) {
  final packed = hex.replaceAll(':', '').toUpperCase();
  return [
    for (var i = 0; i + 1 < packed.length; i += 2)
      packed.substring(i, i + 2),
  ].join(':');
}
