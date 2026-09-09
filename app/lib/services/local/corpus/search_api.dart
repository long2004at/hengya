// 恒牙（hengya）· 端上检索引擎网络层（Phase 4 · 第 1 刀）
// ============================================================================
//
// Python 参考实现：automation/server-pipeline/search_corpus.py
//   - api_embed        L541-578（SiliconFlow /v1/embeddings，OpenAI 兼容；
//                       400+dimension 自动去掉 dimensions 参数重试；
//                       重试 2 次，间隔 1.5×(attempt+1)s）
//   - api_rerank       L620-649（SiliconFlow /v1/rerank，Jina/Cohere 兼容；
//                       无内部重试——模型降级链兜底，429 由上层退避）
//   - rerank_documents L652-696（模型链 8B→4B→0.6B；每模型一次首调烟测
//                       （>2s 降级，结果弃用）；429 退避 2 次；链尽跳过重排）
//
// 网络实现：dart:io HttpClient。Dart HttpClient 默认 findProxy=DIRECT——
// 与 Python 侧「显式禁用系统代理（防代理 MITM 污染证书链）」语义一致，
// 无需额外处理。Bearer 认证；非 2xx 抛 [HttpApiException]（含状态码与
// 截断响应体，供 400/429 分支判定）。
//
// 本文件不含 API key 的读取/存储——配置由调用方组装（App 运行时从
// hengya.db settings 表 reranker.* / embedding.* 读，见 api_client.dart
// L765-793 消费契约；CLI 探针从参数/环境注入）。
import 'dart:async';
import 'dart:convert' as convert;
import 'dart:io';

import 'package:hengya/services/local/corpus/search_engine.dart';

/// SiliconFlow /v1/embeddings 默认端点（Python EMBED_API_URL L138）。
const String kEmbedApiUrl = 'https://api.siliconflow.cn/v1/embeddings';

/// 查询侧嵌入默认模型（Python EMBED_MODEL L139；与库内 meta.embedding_model
/// 一致——不一致时引擎按空间不兼容自动互斥）。
const String kEmbedModel = 'Qwen/Qwen3-VL-Embedding-8B';

/// MRL 截断维度（Python EMBED_DIM L140；= meta.embedding_dim / vec0_dim）。
const int kEmbedDim = 1024;

/// SiliconFlow /v1/rerank 默认端点（Python RERANK_API_URL L171；
/// 与 App 侧 ApiClient.kRerankerDefaultUrl 同款）。
const String kRerankApiUrl = 'https://api.siliconflow.cn/v1/rerank';

/// 重排默认模型（Python RERANK_MODEL_DEFAULT L172；App 侧预填同款）。
const String kRerankModelDefault = 'Qwen/Qwen3-Reranker-8B';

/// 重排降级链兜底模型（Python RERANK_FALLBACK_MODELS L173-174）。
const List<String> kRerankFallbackModels = [
  'Qwen/Qwen3-Reranker-4B',
  'Qwen/Qwen3-Reranker-0.6B',
];

/// 嵌入请求超时秒（Python API_TIMEOUT L155）。
const int kApiTimeoutS = 20;

/// 嵌入重试次数（Python API_RETRIES L156）。
const int kApiRetries = 2;

/// 重排请求超时秒（Python RERANK_TIMEOUT L177）。
const int kRerankTimeoutS = 15;

/// 烟测延迟线：每模型首调成功但超此秒数即降级（RERANK_SMOKE_MAX_S L176）。
const double kRerankSmokeMaxS = 2.0;

// ------------------------------------------------------------- 配置 ----

class SiliconFlowConfig {
  const SiliconFlowConfig({
    required this.apiKey,
    this.embedBaseUrl = kEmbedApiUrl,
    this.embedModel = kEmbedModel,
    this.embedDim = kEmbedDim,
    this.queryInstruct,
    this.rerankUrl = kRerankApiUrl,
    this.rerankModel = kRerankModelDefault,
  });

  /// API key（空 = 不可用——调用方跳过对应路）。
  final String apiKey;

  /// /v1/embeddings 完整端点。
  final String embedBaseUrl;

  /// 查询侧嵌入模型标识（须与库内 embedding_model 一致）。
  final String embedModel;

  /// MRL 截断维度（个别模型拒绝 dimensions 参数时自动去掉重试）。
  final int embedDim;

  /// 查询侧 instruct 前缀：null = 内置默认 kQueryInstruct（2026-09-06
  /// 真库 A/B 定论：保留——禁用则生造词越过低分线）；'' = 禁用前缀。
  final String? queryInstruct;

  /// /v1/rerank 完整端点（App 侧 = settings reranker.baseUrl，即完整端点）。
  final String rerankUrl;

  /// 重排主模型（不可用/烟测超时自动降级 4B → 0.6B）。
  final String rerankModel;
}

/// #6①（2026-09-07）：embedding baseUrl 规范化 → /v1/embeddings 完整端点。
///
/// settings `embedding.baseUrl` 两种存储形态并存（真机用户可能已手动补过
/// 后缀，不可逼用户删）：
/// - 基址形态：`https://api.siliconflow.cn/v1`
/// - 完整端点形态：`https://api.siliconflow.cn/v1/embeddings`
///
/// 规则：trim + 去全部尾部斜杠 → 已以 /embeddings 结尾（大小写不敏感）则
/// 原样返回，否则自动补 `/embeddings`；全空回退 [fallback]（默认
/// [kEmbedApiUrl]）。修复前 [SiliconFlowConfig.embedBaseUrl] 直接透传基址
/// 形态 → 查询嵌入 POST …/v1 恒 404 → 三级检索全灭 → 全占位卡；建库侧
/// （local_backend._selectBuildMode）一直有同款补尾拼法——本 helper 供
/// 检索装配（assembleEmbedder）与建库共用语义。
String normalizeEmbedEndpoint(
  String baseUrl, {
  String fallback = kEmbedApiUrl,
}) {
  var u = baseUrl.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  if (u.isEmpty) {
    return fallback;
  }
  if (u.toLowerCase().endsWith('/embeddings')) {
    return u;
  }
  return '$u/embeddings';
}

// --------------------------------------------------------- HTTP 异常 ----

/// 非 2xx 响应（对齐 Python urllib.error.HTTPError 的 code/body 消费面）。
class HttpApiException implements Exception {
  HttpApiException(this.statusCode, this.body);

  final int statusCode;
  final String body;

  @override
  String toString() => 'HTTP $statusCode: $body';
}

Future<Map<String, Object?>> _postJson(
  String url,
  String apiKey,
  Map<String, Object?> payload,
  int timeoutS,
) async {
  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    req.headers.contentType = ContentType.json;
    final bytes = convert.utf8.encode(convert.jsonEncode(payload));
    req.add(bytes);
    final resp = await req.close().timeout(Duration(seconds: timeoutS));
    final bodyBytes = await resp
        .fold<List<int>>([], (acc, d) => acc..addAll(d))
        .timeout(Duration(seconds: timeoutS));
    final body = convert.utf8.decode(bodyBytes, allowMalformed: true);
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw HttpApiException(
        resp.statusCode,
        body.length > 300 ? '${body.substring(0, 300)}…' : body,
      );
    }
    return convert.jsonDecode(body) as Map<String, Object?>;
  } finally {
    client.close(force: true);
  }
}

// ------------------------------------------------------------- 嵌入 ----

/// SiliconFlow /v1/embeddings（Python api_embed L541-578 逐段对齐）。
Future<List<double>> apiEmbed(
  String text,
  String apiKey, {
  required String url,
  required String model,
  required int dim,
  int timeout = kApiTimeoutS,
  int retries = kApiRetries,
  List<String>? notes,
}) async {
  final payload = <String, Object?>{
    'model': model,
    'input': text,
    'encoding_format': 'float',
    'dimensions': dim,
  };
  Object? lastErr;
  for (var attempt = 0; attempt <= retries; attempt++) {
    try {
      final data = await _postJson(url, apiKey, payload, timeout);
      final arr = data['data'];
      final emb =
          arr is List &&
              arr.isNotEmpty &&
              (arr[0] as Map<String, Object?>)['embedding'] is List
          ? (arr[0] as Map<String, Object?>)['embedding'] as List
          : null;
      if (emb == null) {
        throw StateError('embeddings 响应缺 data[0].embedding');
      }
      return [for (final x in emb) (x as num).toDouble()];
    } on HttpApiException catch (e) {
      lastErr = e;
      if (e.statusCode == 400 &&
          e.body.toLowerCase().contains('dimension') &&
          payload.containsKey('dimensions')) {
        payload.remove('dimensions');
        notes?.add(
          'API 拒绝 dimensions 参数，已去掉重试'
          '（返回维度由检索侧 MRL 截断到库内维度）',
        );
        continue; // 与 Python 同：continue 跳过退避 sleep
      }
    } catch (e) {
      lastErr = e;
    }
    await Future<void>.delayed(Duration(milliseconds: 1500 * (attempt + 1)));
  }
  throw StateError('embeddings API 调用失败（重试 $retries 次）：$lastErr');
}

/// 查询嵌入注入函数（SearchEngine.embed 用）：
/// 拼 instruct 前缀 → apiEmbed；失败向上抛（调用方决定向量路禁用）。
EmbedQueryFn siliconFlowEmbedder(SiliconFlowConfig cfg) {
  return (String query) async {
    final instruct = cfg.queryInstruct == null
        ? kQueryInstruct
        : cfg.queryInstruct!;
    return await apiEmbed(
      '$instruct$query',
      cfg.apiKey,
      url: cfg.embedBaseUrl,
      model: cfg.embedModel,
      dim: cfg.embedDim,
    );
  };
}

// ------------------------------------------------------------- 重排 ----

/// SiliconFlow /v1/rerank（Python api_rerank L620-649）：
/// 返回 [(index, relevanceScore)] 按分数降序（index = documents 下标）。
Future<List<(int, double)>> apiRerank(
  String query,
  List<String> documents,
  String apiKey, {
  required String model,
  required String url,
  int? topN,
  int timeout = kRerankTimeoutS,
}) async {
  final payload = <String, Object?>{
    'model': model,
    'query': query,
    'documents': documents,
    'return_documents': false,
  };
  if (topN != null) payload['top_n'] = topN;
  final data = await _postJson(url, apiKey, payload, timeout);
  final results = data['results'];
  if (results is! List) {
    throw StateError(
      'rerank 响应无有效 results'
      '（keys=${data.keys.join(',')}）',
    );
  }
  final out = <(int, double)>[];
  for (final r0 in results) {
    final r = r0 as Map<String, Object?>;
    final i = r['index'];
    final s = r['relevance_score'];
    if (i is int && s is num && i >= 0 && i < documents.length) {
      out.add((i, s.toDouble()));
    }
  }
  if (out.isEmpty) {
    throw StateError(
      'rerank 响应无有效 results'
      '（keys=${data.keys.join(',')}）',
    );
  }
  out.sort((a, b) => b.$2.compareTo(a.$2));
  return out;
}

// 降级链进程内状态（Python _RERANK_STATE L606-608：idx 只前进；
// smoked 每模型只做一次首调延迟判定，成功且 ≤2s 才定档）
int _rerankChainIdx = 0;
final Set<String> _rerankSmoked = {};

/// 模型降级链（Python rerank_model_chain L611-617）：
/// 显式/默认模型在前 + 4B → 0.6B 兜底（去重防显式模型即兜底款）。
List<String> rerankModelChain(String primary) {
  final chain = [primary.trim().isEmpty ? kRerankModelDefault : primary.trim()];
  for (final m in kRerankFallbackModels) {
    if (!chain.contains(m)) chain.add(m);
  }
  return chain;
}

/// 重排入口（Python rerank_documents L652-696 逐段对齐）：
/// 返回 (ranked|null, model|null, reason|null)——ranked=null 表示本次跳过
/// 重排（调用方沿用融合序，行为与 rerank=off 一致）。
Future<RerankResult> siliconFlowReranker(
  String query,
  List<String> documents,
  SiliconFlowConfig cfg, {
  List<String>? notes,
}) async {
  if (cfg.apiKey.isEmpty) {
    return (null, null, '无 API key');
  }
  final chain = rerankModelChain(cfg.rerankModel);
  while (_rerankChainIdx < chain.length) {
    final m = chain[_rerankChainIdx];
    String? reason;
    for (var attempt = 0; attempt < 3; attempt++) {
      // 429 退避 ≤2 次重试（限流与模型无关，不降级）
      final t0 = Stopwatch()..start();
      try {
        final ranked = await apiRerank(
          query,
          documents,
          cfg.apiKey,
          model: m,
          url: cfg.rerankUrl,
          topN: documents.length,
        );
        final elapsedMs = t0.elapsedMilliseconds;
        if (!_rerankSmoked.contains(m)) {
          _rerankSmoked.add(m);
          if (elapsedMs > kRerankSmokeMaxS * 1000) {
            reason =
                '烟测延迟 ${(elapsedMs / 1000.0).toStringAsFixed(2)}s > '
                '${kRerankSmokeMaxS.toStringAsFixed(1)}s 线（结果弃用）';
            break;
          }
        }
        return (ranked, m, null);
      } on HttpApiException catch (e) {
        if (e.statusCode == 429 && attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 2000 * (attempt + 1)),
          );
          continue;
        }
        reason = 'HTTP ${e.statusCode}';
        break;
      } catch (e) {
        reason = '${e.runtimeType}: $e';
        if (reason.length > 60) {
          reason = '${reason.substring(0, 59)}…';
        }
        break;
      }
    }
    _rerankChainIdx++;
    final nxt = _rerankChainIdx < chain.length
        ? chain[_rerankChainIdx]
        : '链尽（跳过重排）';
    notes?.add('Reranker 降级：$m 不可用（$reason）→ $nxt');
  }
  return (null, null, '降级链全部不可用（原因见 notes）');
}

/// 组装 [RerankFn]（corpusSearch 的 rerankFn 注入）。
RerankFn asRerankFn(SiliconFlowConfig cfg, {List<String>? notes}) {
  return (String query, List<String> documents) =>
      siliconFlowReranker(query, documents, cfg, notes: notes);
}
