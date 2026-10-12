// 聊天传输层单元测试（chat_transport.dart 对拍硬门）。
//
// 【宿主纪律】plain test：不调 TestWidgetsFlutterBinding.ensureInitialized()
// ——真 HttpClient + 本机回环 HttpServer（与 update_service_test 同款纪律）。
//
// 覆盖面：
//   1. 正常 SSE 流：onDelta 逐段回调拼接 == 完整 content、onDone usage 正确、
//      [DONE] 后正常结束、请求体形态（model/messages/stream/temperature）
//   2. reasoning_content delta → 不进 content
//   3. 流中坏 JSON 行静默跳过；无 usage 块 → onDone 计 0
//   4. HTTP 非 200 → ChatTransportException 带 HTTP 码
//   5. content 全空流 → ChatTransportException（网关静默空流是故障）
//   6. 未配置（缺 apiKey）→ ChatTransportException
import 'dart:convert';
import 'dart:io';

import 'package:hengya/services/local/chat/chat_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late ChatTransportConfig cfg;

  setUp(() async {
    server = await HttpServer.bind('127.0.0.1', 0);
    cfg = ChatTransportConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'test-key',
      model: 'v4.1flash',
    );
  });

  tearDown(() async {
    await server.close(force: true);
  });

  /// 假 SSE 服务：收到请求后按 [lines] 逐段写响应（UTF-8 字节——HttpServer
  /// 默认 latin1 字符串写会拒中文；每段一帧，验证 LineSplitter 跨 chunk 拼行）。
  void serveSse(List<String> lines) {
    server.listen((req) async {
      req.response.headers
        ..contentType = ContentType('text', 'event-stream')
        ..add('Cache-Control', 'no-cache');
      req.response.add(utf8.encode(lines.join('\r\n\r\n')));
      await req.response.close();
    });
  }

  String deltaLine(String piece, {String? reasoning}) {
    final delta = <String, Object?>{'content': piece};
    if (reasoning != null) delta['reasoning_content'] = reasoning;
    return jsonEncode({
      'choices': [
        {'delta': delta}
      ],
    });
  }

  test('onDelta 逐段拼接 == 完整 content；onDone usage 正确；[DONE] 后正常结束',
      () async {
    serveSse([
      'data: ${deltaLine('你')}',
      'data: ${deltaLine('好，')}',
      'data: ${deltaLine('恒牙。')}',
      "data: ${jsonEncode({'usage': {'prompt_tokens': 11, 'completion_tokens': 22}})}",
      'data: [DONE]',
    ]);
    final pieces = <String>[];
    var prompt = -1, completion = -1;
    await chatStream(
      cfg,
      [const (role: 'user', content: '你好')],
      onDelta: pieces.add,
      onDone: (p, c) {
        prompt = p;
        completion = c;
      },
    );
    expect(pieces, ['你', '好，', '恒牙。'], reason: '打字机逐段回调');
    expect(pieces.join(), '你好，恒牙。');
    expect(prompt, 11);
    expect(completion, 22);
  });

  test('请求体形态：model/messages/stream/temperature 字段与 Authorization 头',
      () async {
    Map<String, Object?>? body;
    String? auth;
    server.listen((req) async {
      auth = req.headers.value('authorization');
      body = jsonDecode(await utf8.decodeStream(req)) as Map<String, Object?>;
      req.response.headers.contentType =
          ContentType('text', 'event-stream');
      req.response.add(utf8.encode(
          'data: ${deltaLine('ok')}\r\n\r\ndata: [DONE]\r\n\r\n'));
      await req.response.close();
    });
    await chatStream(
      ChatTransportConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        apiKey: 'test-key',
        temperature: 0.4,
      ),
      [
        const (role: 'system', content: '请用中文回答'),
        const (role: 'user', content: '你好，恒牙'),
      ],
      onDelta: (_) {},
    );
    expect(auth, 'Bearer test-key');
    expect(body!['model'], 'v4.1flash');
    expect(body!['stream'], true);
    expect(body!['temperature'], 0.4);
    expect(body!['messages'], [
      {'role': 'system', 'content': '请用中文回答'},
      {'role': 'user', 'content': '你好，恒牙'},
    ]);
  });

  test('temperature 未传 → 请求体不带该字段（服务端默认值）', () async {
    Map<String, Object?>? body;
    server.listen((req) async {
      body = jsonDecode(await utf8.decodeStream(req)) as Map<String, Object?>;
      req.response.headers.contentType =
          ContentType('text', 'event-stream');
      req.response.add(utf8.encode(
          'data: ${deltaLine('ok')}\r\n\r\ndata: [DONE]\r\n\r\n'));
      await req.response.close();
    });
    await chatStream(cfg, [const (role: 'user', content: 'hi')],
        onDelta: (_) {});
    expect(body!.containsKey('temperature'), false);
  });

  test('reasoning_content delta 不进 content；usage 缺失 → onDone 计 0', () async {
    serveSse([
      "data: ${jsonEncode({'choices': [{'delta': {'reasoning_content': '思考中'}}]})}",
      'data: ${deltaLine('答')}',
      'data: not-a-json-line',
      'data: [DONE]',
    ]);
    final pieces = <String>[];
    var prompt = -1, completion = -1;
    await chatStream(
      cfg,
      [const (role: 'user', content: 'q')],
      onDelta: pieces.add,
      onDone: (p, c) {
        prompt = p;
        completion = c;
      },
    );
    expect(pieces, ['答'], reason: '思考链增量与坏 JSON 行均不入正文');
    expect(prompt, 0);
    expect(completion, 0);
  });

  test('HTTP 非 200 → ChatTransportException 带 HTTP 码与 body 片段', () async {
    server.listen((req) async {
      req.response.statusCode = 502;
      req.response.write('bad gateway detail');
      await req.response.close();
    });
    await expectLater(
      chatStream(cfg, [const (role: 'user', content: 'q')],
          onDelta: (_) {}),
      throwsA(
        isA<ChatTransportException>().having(
          (e) => e.message,
          'message',
          contains('HTTP 502'),
        ),
      ),
    );
  });

  test('content 全空流 → ChatTransportException（网关静默空流是故障）', () async {
    serveSse(['data: [DONE]']);
    await expectLater(
      chatStream(cfg, [const (role: 'user', content: 'q')],
          onDelta: (_) {}),
      throwsA(isA<ChatTransportException>()),
    );
  });

  test('未配置（apiKey 空）→ ChatTransportException 且不外呼', () async {
    const bad = ChatTransportConfig(baseUrl: 'http://127.0.0.1:1', apiKey: '');
    await expectLater(
      chatStream(bad, [const (role: 'user', content: 'q')], onDelta: (_) {}),
      throwsA(isA<ChatTransportException>()),
    );
  });

  // ---------------- P3.1：pinnedFingerprint 参数 ----------------
  //
  // 本地假服务是 http（不走 TLS，badCertificateCallback 不会触发），https
  // + 自签证书场景太重不在此构造——这里只锁两点：null（官方通道形态）行为
  // 与扩展前逐字节一致；指纹归一化函数口径稳定。

  test('pinnedFingerprint: null → 默认系统信任，行为与扩展前一致', () async {
    serveSse([
      'data: ${deltaLine('正')}',
      'data: [DONE]',
    ]);
    final pieces = <String>[];
    await chatStream(
      cfg,
      [const (role: 'user', content: 'q')],
      onDelta: pieces.add,
      pinnedFingerprint: null, // 显式 null = 不挂 pinning 回调
    );
    expect(pieces, ['正']);
  });

  test('pinnedFingerprint 非空 → http 宿主不受影响（回调仅在证书验证失败时触发）',
      () async {
    serveSse([
      'data: ${deltaLine('常')}',
      'data: [DONE]',
    ]);
    final pieces = <String>[];
    await chatStream(
      cfg,
      [const (role: 'user', content: 'q')],
      onDelta: pieces.add,
      pinnedFingerprint: kChatProxyCertSha256, // 真实反代指纹；http 下不触发
    );
    expect(pieces, ['常']);
  });

  test('hexFingerprint 归一化：去冒号 + 大写 + 逐字节分组', () {
    const withColon =
        '3e:5e:57:76:9a:da:9d:19:6a:5d:ec:37:e0:2f:e6:6b:f0:6c:17:b1:'
        '09:60:f6:39:a1:d4:aa:8f:6f:db:39:e7';
    expect(hexFingerprint(withColon), kChatProxyCertSha256);
    expect(hexFingerprint('aabbcc'), 'AA:BB:CC');
    expect(hexFingerprint(''), '');
  });
}
