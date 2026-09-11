// 生卡 LLM 主备 failover 单测：
//   - 主连续 3 次 LlmException → switchedToBackup 事件 + 后续走备用
//   - 备用成功 → 计数清零；备用连续 3 次失败 → tripped 熔断
//   - 熔断后剩余请求立即抛（不真打 chat）
//   - 未配备用 → 与单通道等价（不切换不熔断）
//   - 成功一次即清零连续失败计数
// 纯 Dart：chat 注入 fake（chat seam），零网络。
import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/services/local/corpus/run_llm.dart';

void main() {
  const primary = LlmConfig(
    baseUrl: 'https://primary.example.com/v1',
    apiKey: 'pk',
    model: 'primary-model',
  );
  const backup = LlmConfig(
    baseUrl: 'https://backup.example.com/v1',
    apiKey: 'bk',
    model: 'backup-model',
  );

  /// 构造 failover seam + 脚本化 chat（'fail' 抛 / 其余返回 'ok'）。
  /// usedModels 记录每次实际使用的配置 model 名（断言通道归属）。
  (LlmChatFn, List<String> usedModels) makeLlm(
    List<String> script,
    List<LlmFailoverEvent> events,
  ) {
    final usedModels = <String>[];
    var i = 0;
    final llm = failoverLlmChatFn(
      primary: primary,
      backup: backup,
      account: LlmAccount(),
      onEvent: (e, _) => events.add(e),
      chat: (cfg, account, system, user, {tag = ''}) async {
        usedModels.add(cfg.model);
        final act = i < script.length ? script[i] : 'ok';
        i++;
        if (act == 'fail') throw LlmException('[$tag] fake fail #$i');
        return 'ok:${cfg.model}';
      },
    );
    return (llm, usedModels);
  }

  test('主连续 3 次失败 → 切备用；后续请求走备用', () async {
    final events = <LlmFailoverEvent>[];
    final (llm, usedModels) =
        makeLlm(['fail', 'fail', 'fail', 'ok'], events);
    // 第 1-3 次：主失败（第 3 次触发切换并抛切换说明）
    await expectLater(llm('', ''), throwsA(isA<LlmException>()));
    await expectLater(llm('', ''), throwsA(isA<LlmException>()));
    await expectLater(llm('', ''), throwsA(isA<LlmException>()));
    expect(events, [LlmFailoverEvent.switchedToBackup]);
    // 第 4 次：走备用成功
    final r = await llm('', '');
    expect(r, 'ok:backup-model');
    expect(usedModels, [
      'primary-model',
      'primary-model',
      'primary-model',
      'backup-model',
    ]);
  });

  test('备用也连续 3 次失败 → 熔断；后续立即抛不真打', () async {
    final events = <LlmFailoverEvent>[];
    final (llm, usedModels) = makeLlm(List.filled(6, 'fail'), events);
    for (var k = 0; k < 6; k++) {
      await expectLater(llm('', ''), throwsA(isA<LlmException>()));
    }
    expect(events, [
      LlmFailoverEvent.switchedToBackup,
      LlmFailoverEvent.tripped,
    ]);
    // 熔断后：不再真打 chat（usedModels 停在 6）
    expect(usedModels.length, 6);
    await expectLater(llm('', ''), throwsA(isA<LlmException>()));
    expect(usedModels.length, 6, reason: '熔断后不真打');
  });

  test('成功一次清零计数：2 失败 + 1 成功 + 2 失败 ≠ 切换', () async {
    final events = <LlmFailoverEvent>[];
    final script = ['fail', 'fail', 'ok', 'fail', 'fail', 'fail'];
    final (llm, usedModels) = makeLlm(script, events);
    await expectLater(llm('', ''), throwsA(isA<LlmException>()));
    await expectLater(llm('', ''), throwsA(isA<LlmException>()));
    expect(await llm('', ''), 'ok:primary-model'); // 清零
    await expectLater(llm('', ''), throwsA(isA<LlmException>()));
    await expectLater(llm('', ''), throwsA(isA<LlmException>()));
    // 第 5 次失败才凑满 3 连败 → 切换
    await expectLater(llm('', ''), throwsA(isA<LlmException>()));
expect(events, [LlmFailoverEvent.switchedToBackup]);
    // 6 次全走主通道（第 6 次失败凑满 3 连败才切换）
    expect(usedModels.where((m) => m == 'primary-model').length, 6);
  });

  test('未配备用 → 纯主通道（失败不切换不熔断）', () async {
    final events = <LlmFailoverEvent>[];
    var calls = 0;
    final llm = failoverLlmChatFn(
      primary: primary,
      backup: null,
      account: LlmAccount(),
      onEvent: (e, _) => events.add(e),
      chat: (cfg, account, system, user, {tag = ''}) async {
        calls++;
        throw LlmException('f');
      },
    );
    for (var k = 0; k < 10; k++) {
      await expectLater(llm('', ''), throwsA(isA<LlmException>()));
    }
    expect(events, isEmpty);
    expect(calls, 10, reason: '无备用时每次都真打主通道');
  });
}
