// 恒牙（hengya）·「恒牙」聚合页（AboutPage）与设置页共用的 AI 服务/降级卡片部件
// ============================================================================
// 2026-09-11 UI 迁移：AI 服务配置区（含生卡 LLM / 备用生卡 LLM / 向量模型 /
// 重排序模型 + 编辑层）自 settings_page.dart 迁入 AboutPage。为控制单文件体积
// 并避免复制粘贴两份降级卡（知识库区仍在设置页用），现将以下公共部件与常量
// 集中于此：
//   · kEmbeddingDefaultUrl / kEmbeddingDefaultModel —— embedding 编辑层默认预填
//   · NeedUpgradeCard  —— 旧服务器 404 / 加载失败降级卡（含重试入口）
//   · AiServiceCard    —— 单套 AI 服务展示卡（掩码态）
//   · AiServiceEditSheet —— 三字段（baseUrl/model/apiKey）+ 测试连接 + 保存
// settings_page.dart 仍引用 NeedUpgradeCard（知识库区）；AboutPage 引用全部。
import 'package:flutter/material.dart';

import '../services/api/api_client.dart';
import '../services/local/corpus/run_llm.dart' show llmListModels;
import '../services/local/local_backend.dart';
import '../widgets/top_toast.dart';

/// embedding 卡默认预填（#1/#6②，2026-09-07）：对齐 reranker 卡做法——
/// 未配置时编辑层预填 SiliconFlow 完整 embeddings 端点 + 默认嵌入模型
/// （用户可改任意）。与 corpus/search_api.dart 的 kEmbedApiUrl / kEmbedModel
/// 同值——本页自持常量，不与检索引擎文件耦合。两形态兼容：settings 存
/// 基址（…/v1）或完整端点（…/v1/embeddings）均可，运行时（建库选路 /
/// 检索查询 / 测试连接）见 /embeddings 后缀不再追加。
const String kEmbeddingDefaultUrl = 'https://api.siliconflow.cn/v1/embeddings';
const String kEmbeddingDefaultModel = 'Qwen/Qwen3-VL-Embedding-8B';

/// ---------------- M5：需升级 / 加载失败降级卡 ----------------
/// 旧服务器（0.2.0）对新增端点 404 → 显示「需服务器 0.3.0+，暂未部署」，不崩溃；
/// 拉取失败（非 404）→ 显示重试入口。
class NeedUpgradeCard extends StatelessWidget {
  const NeedUpgradeCard({super.key, required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.cloud_off_outlined, size: 20, color: scheme.outline),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '$message，点右侧刷新',
                style: TextStyle(fontSize: 13, color: scheme.outline),
              ),
            ),
            IconButton(
              tooltip: '重试',
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: onRetry,
            ),
          ],
        ),
      ),
    );
  }
}

/// ---------------- M5：单套 AI 服务卡 ----------------
class AiServiceCard extends StatelessWidget {
  const AiServiceCard({
    super.key,
    required this.scheme,
    required this.title,
    required this.desc,
    required this.config,
    required this.onEdit,
  });

  final ColorScheme scheme;
  final String title;
  final String desc;
  final AiServiceConfig config;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final keyInfo = config.encryptedDisplay.isEmpty
        ? config.keyDisplay
        : '${config.keyDisplay} · ${config.encryptedDisplay}';
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(desc, style: TextStyle(fontSize: 11, color: scheme.outline)),
            const SizedBox(height: 4),
            Text(
              '地址：${config.baseUrl.isEmpty ? '—' : config.baseUrl}',
              style: const TextStyle(fontSize: 12),
            ),
            Text(
              '模型：${config.model.isEmpty ? '—' : config.model}',
              style: const TextStyle(fontSize: 12),
            ),
            Text('Key：$keyInfo', style: const TextStyle(fontSize: 12)),
          ],
        ),
        isThreeLine: true,
        trailing: Icon(Icons.edit_outlined, size: 20, color: scheme.primary),
        onTap: onEdit,
      ),
    );
  }
}

/// ---------------- M5：AI 服务编辑层 ----------------
/// 三字段（baseUrl/model/apiKey）+「测试连接」（ok/延迟/失败原因）+「保存」。
/// reranker（重排序）/ embedding（向量）：URL = 完整端点，未配置时预填
/// SiliconFlow 默认端点 + 默认模型（可改任意）；reranker 测试结果额外经
/// TopToast 反馈（失败透传上游裸 message）。
/// llm（生卡）：URL 为 OpenAI 兼容基址（到 /v1），未配置留空（输入框带
/// 示例与常驻说明，#1）；测试连接成功后核对所配 model 是否在服务方
/// /models 列表（#2）——不在列表时橙色警示行提示，不阻断保存。
/// 安全：apiKey 只进请求体；保存成功立即清空 apiKey 控制器，界面只显示服务端掩码。
class AiServiceEditSheet extends StatefulWidget {
  const AiServiceEditSheet({
    super.key,
    required this.service,
    required this.config,
    required this.onSaved,
  });

  final String service; // llm | embedding | reranker
  final AiServiceConfig config;
  final VoidCallback onSaved; // 保存成功后父级刷新掩码

  @override
  State<AiServiceEditSheet> createState() => _AiServiceEditSheetState();
}

class _AiServiceEditSheetState extends State<AiServiceEditSheet> {
  bool get _isReranker => widget.service == 'reranker';

  /// 字段预填：已配置回显原值；reranker / embedding 未配置预填 SiliconFlow
  /// 默认值（#6②：对齐 reranker 卡现有做法——完整端点 + 默认模型，可改
  /// 任意），llm 未配置留空（示例引导见输入框 hint/helper，#1）
  late final _baseUrlCtrl = TextEditingController(
    text: widget.config.baseUrl.isNotEmpty
        ? widget.config.baseUrl
        : switch (widget.service) {
            'reranker' => ApiClient.kRerankerDefaultUrl,
            'embedding' => kEmbeddingDefaultUrl,
            _ => '',
          },
  );
  late final _modelCtrl = TextEditingController(
    text: widget.config.model.isNotEmpty
        ? widget.config.model
        : switch (widget.service) {
            'reranker' => ApiClient.kRerankerDefaultModel,
            'embedding' => kEmbeddingDefaultModel,
            _ => '',
          },
  );
  final _keyCtrl = TextEditingController();

  bool _testing = false;
  bool _saving = false;
  AiServiceTestResult? _testResult;
  String? _error;

  /// #2：llm 测试连接成功但所配 model 不在服务方 /models 列表时记下该
  /// model 名（null = 在列表 / 未核对 / 核对通道失败——均按正常成功展示）
  String? _modelMissing;

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    _keyCtrl.dispose(); // 含明文 key 的控制器随弹层销毁
    super.dispose();
  }

  Future<void> _test() async {
    if (!_validate()) return;
    setState(() {
      _testing = true;
      _testResult = null;
      _modelMissing = null;
    });
    try {
      final r = await ApiClient.instance.testAiService(
        widget.service,
        baseUrl: _baseUrlCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(), // 空则服务端用已存 key
      );
      // #2：llm 连接成功 → 再核对所配 model 是否在服务方 /models 列表
      //（在滚动条期间完成，一次 setState 落结果；核对失败不降级连通性结论）
      final missing =
          ((widget.service == 'llm' || widget.service == 'llm_backup') && r.ok)
          ? await _checkModelInList()
          : null;
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testResult = r;
        _modelMissing = missing;
      });
      // reranker 专属：结果经 TopToast 反馈（失败透传上游裸 message）
      if (_isReranker) {
        TopToast.show(
          context,
          r.ok ? r.display : r.message,
          type: r.ok ? TopToastType.success : TopToastType.error,
          stayDuration: r.ok
              ? const Duration(milliseconds: 1200)
              : const Duration(milliseconds: 1800),
        );
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      final message = e.statusCode == 404 ? '需服务器 0.3.0+，暂未部署' : e.message;
      setState(() {
        _testing = false;
        _testResult = AiServiceTestResult(ok: false, message: message);
        _modelMissing = null;
      });
      // reranker 专属：网络/校验层失败同样气泡透传（裸 message）
      if (_isReranker) {
        TopToast.show(
          context,
          message,
          type: TopToastType.error,
          stayDuration: const Duration(milliseconds: 1800),
        );
      }
    }
  }

  /// #2：拉取服务方 /models 列表（run_llm.llmListModels），核对所配 model
  /// 是否在列。key 口径：表单填了用表单；留空且 local 模式读本机系统安全
  /// 存储（AiKeyVault 内存缓存，与流水线同源）；remote 模式 key 在服务端、
  /// 端上拿不到 → 无法核对，静默跳过（保守：不误导、不降级连通性结论）。
  /// 返回 null = 在列表 / 无法核对；非 null = 所配 model 名（不在列表）。
  Future<String?> _checkModelInList() async {
    final baseUrl = _baseUrlCtrl.text.trim();
    final model = _modelCtrl.text.trim();
    if (baseUrl.isEmpty || model.isEmpty) return null;
    var key = _keyCtrl.text.trim();
    if (key.isEmpty && currentBackendMode == BackendMode.local) {
      try {
        await LocalBackend.instance.initAiKeys(); // 幂等预热（main 已接线）
        key = LocalBackend.instance.aiKeyOf(
          widget.service == 'llm_backup' ? 'llm_backup' : 'llm',
        );
      } catch (_) {
        key = '';
      }
    }
    if (key.isEmpty) return null;
    try {
      final ids = await llmListModels(baseUrl, key);
      return (ids.isEmpty || ids.contains(model)) ? null : model;
    } catch (_) {
      // 核对通道失败（超时/非 JSON/网关不回列表）→ 视为无法核对
      return null;
    }
  }

  Future<void> _save() async {
    if (!_validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ApiClient.instance.updateAiService(
        widget.service,
        baseUrl: _baseUrlCtrl.text.trim(),
        model: _modelCtrl.text.trim(),
        apiKey: _keyCtrl.text.trim(), // 空串=保持已存 key 不变
      );
      // 安全要求：保存成功立即清空明文 key 控制器（不留在任何 UI 态）
      _keyCtrl.clear();
      widget.onSaved(); // 父级重拉掩码
      if (!mounted) return;
      // 2026-09-06：轻提示统一顶部气泡（快速淡化 + 底色随机氛围），替换灰色 SnackBar
      TopToast.show(context, '已保存 AI 服务配置', type: TopToastType.success);
      Navigator.of(context).pop();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.statusCode == 404
            ? '需服务器 0.3.0+，暂未部署'
            : (e.statusCode == 0 ? '连不上服务器，请检查网络' : '保存失败（${e.statusCode}）');
      });
    }
  }

  bool _validate() {
    if (_baseUrlCtrl.text.trim().isEmpty || _modelCtrl.text.trim().isEmpty) {
      setState(() => _error = 'baseUrl 与 model 不能为空');
      return false;
    }
    setState(() => _error = null);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final title = switch (widget.service) {
      'llm' => '编辑生卡 LLM',
      'llm_backup' => '编辑备用生卡 LLM',
      'embedding' => '编辑向量模型',
      _ => '编辑重排序模型',
    };
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: MediaQuery.of(context).viewInsets.bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            '当前 Key：${widget.config.keyDisplay}'
            '${widget.config.encryptedDisplay.isEmpty ? '' : ' · ${widget.config.encryptedDisplay}'}',
            style: TextStyle(fontSize: 12, color: scheme.outline),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _baseUrlCtrl,
            decoration: InputDecoration(
              // 示例引导（#1，2026-09-07）：reranker/embedding 的 URL 即完整
              // 端点（不拼后缀）；llm 为 OpenAI 兼容基址——hint 给示例 URL、
              // helper 常驻说明后缀规则（旧版仅 hint 占位，改进项 #1 依据）
              labelText: switch (widget.service) {
                'reranker' => 'rerank 端点 URL',
                'embedding' => 'embeddings 端点 URL',
                _ => 'baseUrl',
              },
              hintText: switch (widget.service) {
                'reranker' => '如 ${ApiClient.kRerankerDefaultUrl}',
                'embedding' => '如 $kEmbeddingDefaultUrl',
                _ => '如 https://api.siliconflow.cn/v1',
              },
              helperText: switch (widget.service) {
                'reranker' => '完整重排序端点，直接 POST 此地址',
                'embedding' => '完整 embeddings 端点；填 …/v1 基址也可（调用时自动补全）',
                _ => 'OpenAI 兼容基址，填到 /v1 即可，无需带 /chat/completions',
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelCtrl,
            decoration: InputDecoration(
              labelText: 'model',
              // reranker/embedding 未配置时已预填默认模型；hint 提示可改任意
              //（llm 给真实模型 ID 示例，#1）
              hintText: switch (widget.service) {
                'reranker' => '如 ${ApiClient.kRerankerDefaultModel}',
                'embedding' => '如 $kEmbeddingDefaultModel',
                _ => '服务方模型 ID，如 zai-org/GLM-5.3-Flash',
              },
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _keyCtrl,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'apiKey',
              hintText: '留空保持不变',
              // local 模式 key 存本机系统安全存储（AiKeyVault，Android
              // Keystore 加密），非服务器；remote 模式存服务端
              helperText: currentBackendMode == BackendMode.local
                  ? '加密存储在本机，界面只显示掩码'
                  : '加密存储在服务器，界面只显示掩码',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(fontSize: 12, color: scheme.error)),
          ],
          if (_testResult != null) ...[
            const SizedBox(height: 8),
            Builder(
              builder: (context) {
                // #2：llm 连接成功但 model 不在服务方 /models 列表 → 换橙色
                // 警示行（保存不受影响）；其余按原语义（成功绿 / 失败红）
                final warn = _testResult!.ok && _modelMissing != null;
                final icon = _testResult!.ok
                    ? (warn ? Icons.warning_amber_rounded : Icons.check_circle)
                    : Icons.error_outline;
                final color = _testResult!.ok
                    ? (warn ? const Color(0xFFE37318) : const Color(0xFF2BA471))
                    : const Color(0xFFD54941);
                final text = warn
                    ? '连接成功，但 model $_modelMissing 不在服务方模型列表'
                    : _testResult!.display;
                return Row(
                  children: [
                    Icon(icon, size: 14, color: color),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        text,
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ),
                  ],
                );
              },
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _testing ? null : _test,
                  child: _testing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('测试连接'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('保存'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}