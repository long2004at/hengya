// 双通道编排层测试（chat_orchestrator.dart 对拍硬门）。
//
// 【宿主纪律】plain test：真 HttpClient + 本机回环 HttpServer（与
// chat_transport_test 同款），不调 TestWidgetsFlutterBinding。
// AppLog 无 dataDir 不落盘（只 debugPrint），编排层日志路径零环境依赖。
//
// 覆盖面（规格逐条）：
//   1. 反代成功 → 不走官方（官方端口零请求），channel='proxy'、fallback=false
//   2. 反代零 delta 失败（HTTP 500）→ 官方成功，channel='official'、
//      fallback=true、delta 顺序正确（官方内容不与反代残留混淆）
//   3. 反代已吐 delta 后失败（先吐一段再断流/发坏帧）→ 不退回，原错误上抛，
//      官方端口零请求
//   4. 反代未配置（null cfg）→ 直接官方，channel='official'、fallback=false
//   5. 反代失败 + 官方也失败 → 抛错，消息说明两通道都试过
//   6. 反代未配置且官方也未配置 → 抛「未配置」
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/services/local/chat/chat_orchestrator.dart';
import 'package:hengya/services/local/chat/chat_transport.dart';

void main() {
  late HttpServer proxy;
  late HttpServer official;
  late ChatTransportConfig proxyCfg;
  late ChatTransportConfig officialCfg;

  setUp(() async {
    proxy = await HttpServer.bind('127.0.0.1', 0);
    official = await HttpServer.bind('127.0.0.1', 0);
    proxyCfg = ChatTransportConfig(
      baseUrl: 'http://127.0.0.1:${proxy.port}/v1',
      apiKey: 'proxy-key',
      model: 'v4.1flash',
    );
    officialCfg = ChatTransportConfig(
      baseUrl: 'http://127.0.0.1:${official.port}/v1',
      apiKey: 'official-key',
      model: 'official-model',
    );
  });

  tearDown(() async {
    await proxy.close(force: true);
    await official.close(force: true);
  });

  /// SSE 响应帧组（与 chat_transport_test 同款写法）。
  void serveSse(HttpServer server, List<String> lines) {
    server.listen((req) async {
      req.response.headers
        ..contentType = ContentType('text', 'event-stream')
        ..add('Cache-Control', 'no-cache');
      req.response.add(utf8.encode(lines.join('\r\n\r\n')));
      await req.response.close();
    });
  }

  String deltaLine(String piece) => jsonEncode({
        'choices': [
          {'delta': {'content': piece}}
        ],
      });

  test('反代成功 → 不走官方；channel=proxy、fallbackUsed=false', () async {
    serveSse(proxy, [
      'data: ${deltaLine('代')}',
      'data: [DONE]',
    ]);
    var officialHits = 0;
    official.listen((req) async {
      officialHits++;
      await req.response.close();
    });
    final pieces = <String>[];
    final r = await chatOrchestrate(
      proxyCfg,
      [const (role: 'user', content: 'q')],
      onDelta: pieces.add,
      officialCfg: officialCfg,
    );
    expect(r.channel, 'proxy');
    expect(r.fallbackUsed, false);
    expect(pieces.join(), '代');
    expect(officialHits, 0, reason: '反代成功绝不触碰官方通道');
  });

  test('反代零 delta 失败 → 退回官方成功；channel=official、fallbackUsed=true',
      () async {
    proxy.listen((req) async {
      req.response.statusCode = 500;
      req.response.write('proxy down');
      await req.response.close();
    });
    serveSse(official, [
      'data: ${deltaLine('官')}',
      'data: ${deltaLine('方')}',
      'data: [DONE]',
    ]);
    final pieces = <String>[];
    final r = await chatOrchestrate(
      proxyCfg,
      [const (role: 'user', content: 'q')],
      onDelta: pieces.add,
      officialCfg: officialCfg,
    );
    expect(r.channel, 'official');
    expect(r.fallbackUsed, true);
    expect(pieces.join(), '官方');
  });

  test('反代已吐 delta 后失败 → 不退回、原错误上抛（官方零请求）', () async {
    proxy.listen((req) async {
      req.response.headers.contentType = ContentType('text', 'event-stream');
      // 先吐一段真 delta（正常 flush，客户端读到并计数），随后追加非法
      // UTF-8 字节 → 客户端 utf8.decoder 抛 FormatException → 传输层转
      // ChatTransportException 上抛。确定性时序，无断连竞态。
      req.response.add(utf8.encode('data: ${deltaLine('半截')}\r\n\r\n'));
      await req.response.flush();
      req.response.add(const [0xFF, 0xFE, 0x00]);
      await req.response.close();
    });
    var officialHits = 0;
    official.listen((req) async {
      officialHits++;
      await req.response.close();
    });
    final pieces = <String>[];
    await expectLater(
      chatOrchestrate(
        proxyCfg,
        [const (role: 'user', content: 'q')],
        onDelta: pieces.add,
        officialCfg: officialCfg,
      ),
      throwsA(isA<ChatTransportException>()),
    );
    expect(pieces.join(), '半截', reason: '已上屏的增量原样保留');
    expect(officialHits, 0, reason: '部分流式失败绝不退回重发');
  });

  test('反代未配置（null）→ 直接官方；channel=official、fallbackUsed=false',
      () async {
    serveSse(official, [
      'data: ${deltaLine('直')}',
      'data: [DONE]',
    ]);
    var proxyHits = 0;
    proxy.listen((req) async {
      proxyHits++;
      await req.response.close();
    });
    final pieces = <String>[];
    final r = await chatOrchestrate(
      null,
      [const (role: 'user', content: 'q')],
      onDelta: pieces.add,
      officialCfg: officialCfg,
    );
    expect(r.channel, 'official');
    expect(r.fallbackUsed, false);
    expect(pieces.join(), '直');
    expect(proxyHits, 0);
  });

  test('反代失败 + 官方也失败 → 抛错且消息说明两通道都试过', () async {
    proxy.listen((req) async {
      req.response.statusCode = 502;
      await req.response.close();
    });
    official.listen((req) async {
      req.response.statusCode = 503;
      await req.response.close();
    });
    await expectLater(
      chatOrchestrate(
        proxyCfg,
        [const (role: 'user', content: 'q')],
        onDelta: (_) {},
        officialCfg: officialCfg,
      ),
      throwsA(
        isA<ChatTransportException>().having(
          (e) => e.message,
          'message',
          allOf(contains('反代'), contains('官方')),
        ),
      ),
    );
  });

  test('反代未配置且官方未配置 → 抛「未配置」', () async {
    await expectLater(
      chatOrchestrate(
        null,
        [const (role: 'user', content: 'q')],
        onDelta: (_) {},
        officialCfg: null,
      ),
      throwsA(
        isA<ChatTransportException>().having(
          (e) => e.message,
          'message',
          contains('未配置'),
        ),
      ),
    );
  });
}
