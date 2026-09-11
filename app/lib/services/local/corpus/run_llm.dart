// 恒牙（hengya）· Phase 4 run_engine · LLM 传输层（run_llm.dart）
// ============================================================================
//
// Python 参考基线：automation/server-pipeline/run.py L444-603（llm_chat /
// _llm_post / _read_sse / extract_json_obj），语义 1:1 移植：
//   - 流式优先（stream=true + stream_options.include_usage）：Cloudflare 类
//     网关 ~100s 空闲超时下唯一稳定形态（非流式大体量拆卡实测 504）；
//     纯标准库 SSE 解析，reasoning delta 自动忽略，usage 取流末块（无则计 0）。
//   - HTTP 400 参数降级梯：stream_options → response_format → stream 逐项撤
//     （最多 3 级，不耗重试次数），兼容不支持双保险参数的端点。
//   - 5xx/超时重试 2 次（5xx 间隔 30s 给中转喘息；其余 5s）。
//   - 当日 token 熔断：超 cap 抛错（当次关键词按失败处理、不 consume）。
//   - User-Agent 统一浏览器风格（python-urllib 默认 UA 会被 WAF 拦，§3.2）。
//
// 本文件纯 Dart（dart:io HttpClient），不依赖 Flutter——app 内嵌流水线、
// CLI 探针（tool/run_probe.dart）与测试三态共用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 浏览器风格 UA（WAF 拦默认 UA；与 run.py BROWSER_UA 逐字一致）。
const String kBrowserUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

const double kLlmTemperature = 0.3; // 与 run.py LLM_TEMPERATURE 一致
const int kLlmTimeoutSec = 300; // 单次请求超时（实测单题 20-42s，多卡批次放宽）
const int kLlmRetryTimes = 2; // 失败重试次数
const int kLlmRetryIntervalSec = 5; // 非 5xx 重试间隔
const int kLlmDailyTokenCapDefault = 500000; // 当日 token 熔断【可调】
const int kLlmModelsTimeoutSec = 15; // /models 列表拉取超时（设置页测试连接后的核对，非流水线路径）

/// LLM 调用失败（契约 9/10：不 consume，留给次日补跑）。
class LlmException implements Exception {
  const LlmException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// OpenAI 兼容拆卡 LLM 配置（App 内嵌流水线从 settings llm.* 读取；
/// 探针从 .env 读取——LLM_BASE_URL / LLM_API_KEY / LLM_MODEL）。
class LlmConfig {
  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature = kLlmTemperature,
    this.dailyTokenCap = kLlmDailyTokenCapDefault,
    this.timeoutSec = kLlmTimeoutSec,
  });

  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;
  final int dailyTokenCap;
  final int timeoutSec;

  bool get configured =>
      baseUrl.isNotEmpty && apiKey.isNotEmpty && model.isNotEmpty;
}

/// 当日 LLM 用量账本（跨调用累计；日报如实展示）。
class LlmAccount {
  int calls = 0;
  int promptTokens = 0;
  int completionTokens = 0;
  final List<String> notes = <String>[];

  Map<String, Object?> toJson() => {
        'calls': calls,
        'promptTokens': promptTokens,
        'completionTokens': completionTokens,
        'notes': List<String>.of(notes),
      };
}

/// 引擎侧注入 seam（run_engine 的 LlmChatFn 由本层闭包装配）。
typedef LlmChatFn = Future<String> Function(String system, String user,
    {String tag});

/// 装配 [llmChat] 为引擎注入 seam（绑定配置与账本）。
LlmChatFn llmChatFn(LlmConfig cfg, LlmAccount account) =>
    (system, user, {tag = ''}) => llmChat(cfg, account, system, user, tag: tag);

// ---------------- 主备 failover（生卡 LLM 保底） ----------------
//
// 语义（用户拍板，2026-09-11）：
//   主 LLM 连续 3 次 LlmException → 切备用（onEvent 上报「主异常已用备用」）；
//   备用连续 3 次失败 → 熔断闸：本轮剩余请求立即抛 LlmException（调用方按
//   关键词 failed 处理、收件箱保留，次日自动再试）；
//   备用成功 → 冷却 30 分钟后自动切回主（下轮调度天然机会，Q2-B）。
// 设计约束：引擎零改动（仍是 LlmChatFn seam）；熔断抛 LlmException 与现有
// 单点降级链（splitKeyword/synonym/studylog 的 on LlmException catch）完全
// 兼容——熔断 = 快速失败，不空转烧超时。

/// failover 状态快照（onEvent 上报/设置页展示用）。
class LlmFailoverState {
  const LlmFailoverState({
    required this.onBackup,
    required this.tripped,
    required this.failStreak,
    this.lastError,
    this.switchedAt,
  });

  /// 当前是否走备用配置。
  final bool onBackup;

  /// 备用也已熔断（本轮剩余请求不再真打）。
  final bool tripped;

  /// 当前通道连续失败次数（主或备用各自累计）。
  final int failStreak;

  final String? lastError;

  /// 最近一次切换时间（null = 从未切过）。
  final DateTime? switchedAt;

  Map<String, Object?> toJson() => {
        'onBackup': onBackup,
        'tripped': tripped,
        'failStreak': failStreak,
        'lastError': lastError,
        'switchedAt': switchedAt?.toIso8601String(),
      };
}

/// 主备切换事件类型（onEvent 回调标签）。
enum LlmFailoverEvent {
  switchedToBackup, // 主连续失败 → 切备用
  switchedBackToPrimary, // 备用成功 + 冷却到期 → 切回主
  tripped, // 备用也连续失败 → 熔断
}

/// 主备 failover LLM seam：无备用配置时与 [llmChatFn] 等价。
/// [chat] 仅测试注入（默认真 [llmChat]；生产勿碰）。
LlmChatFn failoverLlmChatFn({
  required LlmConfig primary,
  LlmConfig? backup,
  required LlmAccount account,
  void Function(LlmFailoverEvent, LlmFailoverState)? onEvent,
  Future<String> Function(LlmConfig, LlmAccount, String, String,
      {String tag})? chat,
}) {
final chatFn = chat ?? llmChat;
  if (backup == null || !backup.configured) {
    // 未配备用 → 纯主通道（透传 chat seam，测试注入仍生效）
    return (system, user, {tag = ''}) =>
        chatFn(primary, account, system, user, tag: tag);
  }
  var onBackup = false;
  var tripped = false;
  var failStreak = 0; // 当前通道连续失败
  var switchedAt = DateTime.now();
  DateTime? lastSuccessAt;

  // 冷却 30 分钟：备用成功后到期自动切回主
  const coolDownSec = 30 * 60;

  LlmFailoverState state() => LlmFailoverState(
        onBackup: onBackup,
        tripped: tripped,
        failStreak: failStreak,
        lastError: null,
        switchedAt: switchedAt,
      );

  void emit(LlmFailoverEvent e) => onEvent?.call(e, state());

  return (system, user, {tag = ''}) async {
    // 熔断闸：备用也挂了 → 快速失败，不空转
    if (tripped) {
      throw LlmException(
          '[$tag] 生卡 LLM 主备均已熔断，本轮跳过（收件箱保留，次日自动重试）');
    }
    // 冷却到期自动切回主（下轮首请求生效）
    if (onBackup &&
        lastSuccessAt != null &&
        DateTime.now().difference(lastSuccessAt!).inSeconds >= coolDownSec) {
      onBackup = false;
      failStreak = 0;
      switchedAt = DateTime.now();
      emit(LlmFailoverEvent.switchedBackToPrimary);
    }
    final cfg = onBackup ? backup : primary;
    try {
final content = await chatFn(cfg, account, system, user, tag: tag);
      failStreak = 0;
      lastSuccessAt = DateTime.now();
      return content;
    } on LlmException catch (e) {
      failStreak++;
      // 主通道连续 3 次失败 → 切备用
      if (!onBackup && failStreak >= 3 && backup.configured) {
        onBackup = true;
        failStreak = 0;
        switchedAt = DateTime.now();
        emit(LlmFailoverEvent.switchedToBackup);
        throw LlmException(
            '[$tag] 主 LLM 连续失败已切备用（${e.message}）；本轮继续用备用');
      }
      // 备用也连续 3 次失败 → 熔断
      if (onBackup && failStreak >= 3) {
        tripped = true;
        emit(LlmFailoverEvent.tripped);
        throw LlmException(
            '[$tag] 备用 LLM 也已连续失败，主备熔断（收件箱保留，次日自动重试）：${e.message}');
      }
      rethrow;
    }
  };
}

/// OpenAI 兼容 chat/completions：流式优先 + 参数降级梯 + 重试 + 当日 token 熔断。
///
/// 对拍基线 run.py llm_chat L517-582：HTTP 400 降级梯不耗重试次数；重试环
/// 同形态再试（5xx 间隔 30s / 其余 5s）；仍败抛 [LlmException]（消息带 tag）。
Future<String> llmChat(LlmConfig cfg, LlmAccount account, String system,
    String user,
    {String tag = ''}) async {
  if (!cfg.configured) {
    throw const LlmException('LLM 未配置（需 baseUrl / apiKey / model）');
  }
  final used = account.promptTokens + account.completionTokens;
  if (used >= cfg.dailyTokenCap) {
    throw LlmException('当日 token 熔断（cap=${cfg.dailyTokenCap} 已耗 $used）');
  }
  final url = '${cfg.baseUrl.replaceAll(RegExp(r'/+$'), '')}/chat/completions';
  final messages = [
    {'role': 'system', 'content': system},
    {'role': 'user', 'content': user},
  ];
  final baseBody = <String, Object?>{
    'model': cfg.model,
    'messages': messages,
    'temperature': cfg.temperature,
    'stream': true,
    'stream_options': {'include_usage': true},
    'response_format': {'type': 'json_object'},
  };
  const droppable = ['stream_options', 'response_format', 'stream'];
  final dropped = <String>[];

  Map<String, Object?> payload() {
    final p = Map<String, Object?>.of(baseBody);
    for (final k in dropped) {
      p.remove(k);
    }
    return p;
  }

  String account_(String content, ({int prompt, int completion}) u) {
    account.calls += 1;
    account.promptTokens += u.prompt;
    account.completionTokens += u.completion;
    return content;
  }

  var lastErr = '';
  // 参数兼容梯（HTTP 400 → 逐项降级，不耗重试次数）
  for (var dropI = 0; dropI <= droppable.length; dropI++) {
    try {
      final (content, u) = await _llmPost(cfg, url, payload());
      return account_(content, u);
    } on LlmException catch (e) {
      lastErr = e.message;
      if (lastErr.contains('HTTP 400') && dropI < droppable.length) {
        dropped.add(droppable[dropI]);
        continue;
      }
      break;
    }
  }
  // 重试环（同形态；5xx 给中转更长喘息）
  for (var attempt = 0; attempt < kLlmRetryTimes; attempt++) {
    await Future<void>.delayed(Duration(
        seconds: lastErr.contains('HTTP 5') ? 30 : kLlmRetryIntervalSec));
    try {
      final (content, u) = await _llmPost(cfg, url, payload());
      return account_(content, u);
    } on LlmException catch (e) {
      lastErr = e.message;
      if (lastErr.contains('HTTP 400')) {
        final nxt = droppable.where((k) => !dropped.contains(k)).toList();
        if (nxt.isNotEmpty) {
          dropped.add(nxt.first);
        }
      }
    }
  }
  throw LlmException('[$tag] ${lastErr.isEmpty ? 'LLM 失败' : lastErr}');
}

// ---------------- /models 模型列表（#2：测试连接后的 model 在列核对） ----------------

/// /models 列表拉取注入 seam（测试专用；生产勿碰）：入参 =（baseUrl /
/// Bearer key），出参 = 模型 id 列表。null = 真外呼。
/// 与 local_backend.rerankProbeOverride 同款纪律：测试注入假实现离线断言
/// UI 两分支（testWidgets 假异步真网络必死锁），用完置 null 恢复。
Future<List<String>> Function(String baseUrl, String apiKey)?
    llmListModelsOverride;

/// 拉取服务方模型 id 列表（GET {baseUrl}/models，OpenAI 兼容 data[].id）。
/// 设置页「测试连接」成功后核对所配 model 是否在列（#2）。失败抛
/// [LlmException]——调用方（settings_page）按「核对通道失败不降级连通性
/// 结论」静默跳过（详见 _AiServiceEditSheetState._checkModelInList）。
Future<List<String>> llmListModels(String baseUrl, String apiKey) {
  final injected = llmListModelsOverride;
  if (injected != null) {
    return injected(baseUrl, apiKey);
  }
  return _llmListModelsReal(baseUrl, apiKey);
}

/// 真外呼实现（纯 dart:io HttpClient，沿用本层 _llmPost 风格：浏览器 UA、
/// 尾斜杠归一、超时 abort、统一 LlmException）。
Future<List<String>> _llmListModelsReal(String baseUrl, String apiKey) async {
  final client = HttpClient();
  try {
    final url = '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models';
    final req = await client.getUrl(Uri.parse(url));
    if (apiKey.isNotEmpty) {
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
    req.headers.set('User-Agent', kBrowserUa);
    final resp = await req.close().timeout(
      const Duration(seconds: kLlmModelsTimeoutSec),
      onTimeout: () {
        req.abort();
        throw const LlmException('models 拉取超时');
      },
    );
    final raw = await resp.transform(utf8.decoder).join().timeout(
        const Duration(seconds: kLlmModelsTimeoutSec));
    if (resp.statusCode >= 400) {
      final head = raw.length > 200 ? raw.substring(0, 200) : raw;
      throw LlmException('HTTP ${resp.statusCode}: $head');
    }
    Object? obj;
    try {
      obj = jsonDecode(raw);
    } catch (_) {
      throw const LlmException('models 响应非 JSON');
    }
    final data = obj is Map ? obj['data'] : null;
    if (data is! List) {
      throw const LlmException('models 响应无 data 列表');
    }
    return data
        .map((e) => e is Map ? e['id'] : null)
        .whereType<String>()
        .toList();
  } on TimeoutException {
    throw LlmException('models 拉取超时(>${kLlmModelsTimeoutSec}s)');
  } on LlmException {
    rethrow;
  } on SocketException catch (e) {
    throw LlmException('SocketException: ${e.message}');
  } catch (e) {
    throw LlmException('${e.runtimeType}: $e');
  } finally {
    client.close(force: true);
  }
}

/// 单次 POST：流式走 SSE 解析；非流式解析 JSON。错误消息与 run.py 逐字对齐。
Future<(String, ({int prompt, int completion}))> _llmPost(
    LlmConfig cfg, String url, Map<String, Object?> payload) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${cfg.apiKey}');
    req.headers.contentType = ContentType.json;
    req.headers.set('User-Agent', kBrowserUa);
    req.write(jsonEncode(payload));
    final resp = await req
        .close()
        .timeout(Duration(seconds: cfg.timeoutSec), onTimeout: () {
      req.abort();
      throw const LlmException('超时');
    });
    if (resp.statusCode >= 400) {
      final body = await resp.transform(utf8.decoder).join();
      final head = body.length > 200 ? body.substring(0, 200) : body;
      throw LlmException('HTTP ${resp.statusCode}: $head');
    }
    if (payload['stream'] == true) {
      return await _readSse(resp);
    }
    final raw = await resp
        .transform(utf8.decoder)
        .join()
        .timeout(Duration(seconds: cfg.timeoutSec));
    Object? obj;
    try {
      obj = jsonDecode(raw);
    } catch (_) {
      final head = raw.length > 200 ? raw.substring(0, 200) : raw;
      throw LlmException('LLM 响应非 JSON：$head');
    }
    final choices = obj is Map ? obj['choices'] : null;
    if (choices is! List || choices.isEmpty) {
      final head = raw.length > 200 ? raw.substring(0, 200) : raw;
      throw LlmException('LLM 响应无 choices：$head');
    }
    final first = choices.first;
    final msg = first is Map ? first : null;
    final content = msg?['content'];
    if (content is! String || content.trim().isEmpty) {
      final head = raw.length > 200 ? raw.substring(0, 200) : raw;
      throw LlmException('LLM content 为空：$head');
    }
    var prompt = 0, completion = 0;
    final usage = obj is Map ? obj['usage'] : null;
    if (usage is Map) {
      prompt = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
      completion = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
    }
    return (content, (prompt: prompt, completion: completion));
  } on TimeoutException {
    throw LlmException('超时(>${cfg.timeoutSec}s)');
  } on LlmException {
    rethrow;
  } on SocketException catch (e) {
    throw LlmException('SocketException: ${e.message}');
  } catch (e) {
    throw LlmException('${e.runtimeType}: $e');
  } finally {
    client.close(force: true);
  }
}

/// SSE 流式读取：累积 delta.content（reasoning delta 自动忽略）；
/// usage 取流末 include_usage 块；网关不回则计 0（日报如实展示）。
Future<(String, ({int prompt, int completion}))> _readSse(
    HttpClientResponse resp) async {
  final parts = <String>[];
  var prompt = 0, completion = 0;
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
    final usage = obj['usage'];
    if (usage is Map) {
      prompt = (usage['prompt_tokens'] as num?)?.toInt() ?? 0;
      completion = (usage['completion_tokens'] as num?)?.toInt() ?? 0;
    }
    final choices = obj['choices'];
    if (choices is List) {
      for (final ch0 in choices) {
        if (ch0 is! Map) {
          continue;
        }
        final delta = ch0['delta'];
        if (delta is Map) {
          final piece = delta['content'];
          if (piece is String && piece.isNotEmpty) {
            parts.add(piece);
          }
        }
      }
    }
  }
  final content = parts.join();
  if (content.trim().isEmpty) {
    throw const LlmException('LLM 流式输出 content 为空');
  }
  return (content, (prompt: prompt, completion: completion));
}

/// 容错提取 LLM 输出中的 JSON（剥代码围栏；对象/数组包裹均可；
/// {"cards":[…]} 或裸数组）。对拍基线 run.py extract_json_obj L585-603。
Object? extractJsonObj(String? text) {
  if (text == null) {
    throw const LlmException('LLM 空输出');
  }
  var t = text.trim();
  t = t
      .replaceFirst(RegExp(r'^```[a-zA-Z]*\s*'), '')
      .replaceFirst(RegExp(r'\s*```\s*$'), '')
      .trim();
  try {
    return jsonDecode(t);
  } catch (_) {
    // 落入下方包裹扫描
  }
  for (final pair in const [('{', '}'), ('[', ']')]) {
    final i = t.indexOf(pair.$1);
    final j = t.lastIndexOf(pair.$2);
    if (i >= 0 && j > i) {
      try {
        return jsonDecode(t.substring(i, j + 1));
      } catch (_) {
        continue;
      }
    }
  }
  final head = t.length > 200 ? t.substring(0, 200) : t;
  throw LlmException('无法从 LLM 输出解析 JSON：$head');
}
