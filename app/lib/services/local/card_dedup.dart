// 恒牙（hengya）· 卡片查重（#11，2026-09-13 拍板）
// ============================================================================
//
// 背景（issue #11）：一个关键词被解读成多张小幅改动的相似卡；全链路原本
// 无任何内容级查重（唯一防重是卡 id 精确相等，跨关键词/措辞漂移即失效）。
//
// 方案（用户拍板）：入库后由流水线对「缺向量的卡」做**嵌入相似度查重**——
//   · 向量相似（非文本规则），比对域 = card_vectors 全表（模型一致者）；
//   · 每批嵌入 ≤[kDupEmbedBatch]（用户拍板：一批不得超过二十，仿建库节流）；
//   · 阈值 cosine ≥[kDupThresholdDefault]（设置页 dup.threshold 可调，宁漏勿误杀）；
//   · 命中 → dup_check='dup' + dup_of=已有卡 id（照常进审核区，带「疑似重复」
//     徽标与并排对比，审核时人工裁决）；
//   · 嵌入 API 不可用 → 优雅降级（用户拍板 3a）：卡照常入库（已入库），
//     dup_check='skipped'（审核区带「未查重」徽标）+ 日志 warning；
//   · **自动补查**（用户拍板）：skipped 卡缺向量，下一轮流水线趟次自然
//     重嵌重比并更新徽标——无需人工触发。
//
// 单趟流水（[runCardDupPass]）统一承载：新卡入库、历史回填、降级补查三种
// 场景都是「缺向量 → 嵌 → 存向量 → 比对 → 写结果」，无独立分支。
//
// 纪律：本文件纯 Dart + package:sqlite3（Db 由调用方传入），不 import
// Flutter；嵌入经由注入 seam（不直接依赖 extract_all/_apiPostJson——
// 测试注入假实现）。日志经注入回调（worker 内 = ctx.log 回流主 isolate）。
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'db.dart';

/// 默认相似度阈值（cosine 下界）：宁漏勿误杀起步，设置页可调【可调】。
const double kDupThresholdDefault = 0.92;

/// settings 键（设置页「疑似重复相似度阈值」）。
const String kDupThresholdSettingKey = 'dup.threshold';

/// 读生效阈值（settings 缺失/坏值回退默认——worker 与路由层同源）。
double dupThresholdOf(Db db) =>
    double.tryParse(db.settingGet(kDupThresholdSettingKey) ?? '') ??
    kDupThresholdDefault;

/// 每批嵌入上限（用户拍板：一批不得超过二十——仿建库嵌入节流）。
const int kDupEmbedBatch = 20;

/// 连续批失败上限：超过即把剩余卡全部标 skipped 收口（API 挂了不空转）。
const int kDupMaxBatchFailures = 3;

/// 批间退避基数（429/5xx 后等待；指数递增，上限 60s——与建库嵌入同风格）。
const int kDupBackoffBaseSec = 4;
const int kDupBackoffMaxSec = 60;

/// float32 向量余弦（两向量字节数不符 → 0——维度不一致不可比，防御性）。
double dupCosine(Uint8List a, Uint8List b) {
  if (a.length != b.length || a.length < 4) return 0;
  final fa = Float32List.view(a.buffer, a.offsetInBytes, a.length ~/ 4);
  final fb = Float32List.view(b.buffer, b.offsetInBytes, b.length ~/ 4);
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < fa.length; i++) {
    dot += fa[i] * fb[i];
    na += fa[i] * fa[i];
    nb += fb[i] * fb[i];
  }
  if (na == 0 || nb == 0) return 0;
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// 嵌入批量注入 seam：texts → 等长向量列表。失败抛异常（调用方降级）。
/// 生产装配 = apiEmbedBatch 截断重整后的闭包；测试注入假实现。
typedef DupEmbedBatchFn = Future<List<List<double>>> Function(
  List<String> texts,
);

/// float32 → 原始字节（card_vectors.vec 存储形态；同端读写同形态，无跨端
/// 字节序问题——比对两端都出自本表）。
Uint8List dupVecToBytes(List<double> v) {
  final f = Float32List.fromList(v);
  return f.buffer.asUint8List();
}

/// 单趟查重结果（设置页/日志消费）。
class CardDupPassResult {
  CardDupPassResult({
    required this.embedded,
    required this.dupMarked,
    required this.skipped,
  });

  /// 本趟补嵌向量张数（含历史回填与降级补查）。
  int embedded;

  /// 本趟标记疑似重复张数。
  int dupMarked;

  /// 本趟降级未查重张数（API 不可用）。
  int skipped;

  Map<String, Object?> toJson() => {
        'embedded': embedded,
        'dupMarked': dupMarked,
        'skipped': skipped,
      };
}

/// 查重趟次入口：处理「缺向量的卡」（新卡 + 历史回填 + skipped 补查统一）。
///
/// [embedBatch] 生产装配处传入（批内 ≤[kDupEmbedBatch] 由本函数切分，
/// 429/5xx 退避重试）；嵌入失败 → 本批标 skipped，连续
/// [kDupMaxBatchFailures] 批失败把剩余全部标 skipped 并收口。
/// [log] 可空（测试/CLI 不记）。
Future<CardDupPassResult> runCardDupPass({
  required Db db,
  required String model,
  required double threshold,
  required DupEmbedBatchFn embedBatch,
  void Function(String level, String tag, String message)? log,
}) async {
  final res = CardDupPassResult(embedded: 0, dupMarked: 0, skipped: 0);
  var pending = db.cardsMissingVectors();
  if (pending.isEmpty) return res;
  log?.call('info', 'dedup', '卡片查重开始：待嵌入比对 ${pending.length} 张（阈值 $threshold）');

  // 比对域：已有向量（model 一致）。本趟新嵌的向量即时入表——同批后嵌的
  // 卡也能与先嵌的同批卡互比（一关键词多子考点的近似卡互检）。
  Future<List<(String, Uint8List)>> domain() async => db.cardVectors(model);

  var failures = 0;
  while (pending.isNotEmpty) {
    final take = pending.take(kDupEmbedBatch).toList();
    pending = pending.skip(kDupEmbedBatch).toList();
    List<List<double>> vecs;
    try {
      vecs = await embedBatch([for (final (_, f) in take) f]);
      if (vecs.length != take.length) {
        throw StateError('嵌入返回条数不符（${vecs.length}/${take.length}）');
      }
      failures = 0;
    } catch (e) {
      failures++;
      // 降级（用户拍板 3a）：本批标 skipped，卡不受影响照常在审核区
      for (final (id, _) in take) {
        db.setDupResult(id, check: 'skipped');
      }
      res.skipped += take.length;
      log?.call('warn', 'dedup',
          '查重嵌入失败（连续 $failures/$kDupMaxBatchFailures）：$e——本批 ${take.length} 张标记「未查重」，下轮自动补查');
      if (failures >= kDupMaxBatchFailures) {
        for (final (id, _) in pending) {
          db.setDupResult(id, check: 'skipped');
        }
        res.skipped += pending.length;
        log?.call('warn', 'dedup',
            '查重嵌入连续失败，剩余 ${pending.length} 张全部标记「未查重」收口');
        pending = const [];
      } else {
        await Future<void>.delayed(
          Duration(
            seconds: math.min(
              kDupBackoffMaxSec,
              kDupBackoffBaseSec * (1 << (failures - 1)),
            ),
          ),
        );
      }
      continue;
    }
    // 存向量 + 比对
    for (var i = 0; i < take.length; i++) {
      final (id, front) = take[i];
      final vec = vecs[i];
      db.saveCardVector(id, model, vec.length, dupVecToBytes(vec));
      res.embedded++;
      var bestId = '';
      var bestScore = 0.0;
      for (final (oid, ovec) in await domain()) {
        if (oid == id) continue;
        final score = dupCosine(dupVecToBytes(vec), ovec);
        if (score > bestScore) {
          bestScore = score;
          bestId = oid;
        }
      }
      if (bestScore >= threshold && bestId.isNotEmpty) {
        db.setDupResult(id, check: 'dup', dupOf: bestId);
        res.dupMarked++;
        log?.call('info', 'dedup',
            '疑似重复：${_head(front, 24)} ≈ 卡 $bestId（相似度 ${bestScore.toStringAsFixed(3)}）→ 待审核区人工裁决');
      } else {
        db.setDupResult(id, check: 'ok');
      }
    }
  }
  log?.call(
      'info',
      'dedup',
      '卡片查重结束：嵌入 ${res.embedded} 张，疑似重复 ${res.dupMarked} 张'
      '${res.skipped > 0 ? '，未查重（降级）${res.skipped} 张' : ''}');
  return res;
}

String _head(String? text, int n) {
  final t = (text ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > n ? '${t.substring(0, n)}…' : t;
}
