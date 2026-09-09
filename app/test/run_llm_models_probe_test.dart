// #2（2026-09-07）：run_llm.llmListModels 真实外呼探针（plain test）
// ============================================================================
// 纪律（历史实锤教训）：
//  · 绝不调 TestWidgetsFlutterBinding.ensureInitialized()——它会把 dart:io
//    HttpClient 全局替换为恒 400 假实现，真网络必死；本文件纯 plain test。
//  · 真实 key 只经环境变量 HENGYA_TEST_LLM_KEY 注入，绝不写入仓库任何文件。
// 探针端点（公开仓库占位值；本地实跑可自行改成你的 OpenAI 兼容端点）：
// baseUrl https://example.com/v1、model zai-org/GLM-5.3-Flash——
// 验收口径：所配 model 应在服务方 /models 列表。
// 离线两分支断言见 m5_widget_test.dart（llmListModelsOverride 注入）。
import 'dart:io';

import 'package:hengya/services/local/corpus/run_llm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('#2 真连：拉取服务方 /models 列表，用户所配 model 在列', () async {
    final envKey = Platform.environment['HENGYA_TEST_LLM_KEY'] ?? '';
    if (envKey.isEmpty) {
      // 无 key 环境（CI / 他人机器）跳过，不算失败
      return;
    }
    const kLlmBase = 'https://example.com/v1';
    const kLlmModel = 'zai-org/GLM-5.3-Flash';

    expect(llmListModelsOverride, isNull,
        reason: '生产路径必须走真外呼（注入 seam 仅测试内使用后置 null）');

    final ids = await llmListModels(kLlmBase, envKey);
    expect(ids, isNotEmpty, reason: '真网关 /models 必须返回非空模型 id 列表');
    expect(ids, contains(kLlmModel),
        reason: '用户所配 model $kLlmModel 应在服务方模型列表（验收口径）');

    // 打样几条（key/敏感信息不打；model id 非机密）
    stdout.writeln('== /models 共 ${ids.length} 个；样例: '
        '${ids.take(5).join(' | ')}');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
