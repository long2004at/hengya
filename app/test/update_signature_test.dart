// 更新清单 Ed25519 验签单测（安全修复 B）。
//
// 【宿主纪律】plain test：不经 TestWidgetsFlutterBinding——清单原文经
// UpdateService.debugFetchOverride 注入，当前版本经 debugChannelOverride
// 注入，验签公钥经 debugPublicKeyOverride 注入固定测试密钥对公钥
// （update_sign_fixture.dart），全程无真 HTTP / db / 原生通道。
//
// 覆盖：canonical payload 规范 / 好签名通过 / 坏签名拒绝 / 缺 signature
// 拒绝 / 篡改任一 payload 字段拒绝 / 公钥不可加载拒绝。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/services/update/update_service.dart';

import 'update_sign_fixture.dart';

void main() {
  late UpdateSignFixture fx;

  setUpAll(() async {
    fx = await UpdateSignFixture.load();
  });

  setUp(() {
    // 公钥 = 固定测试密钥对公钥（生产 asset 路径另有专测）
    UpdateService.debugPublicKeyOverride = fx.publicKeyBytes;
    // 假「当前应用版本」14 < 清单 15 → 通过验签后 available=true
    UpdateService.debugChannelOverride = (method, [args]) async {
      assert(method == 'getPackageInfo');
      return {'versionName': '1.6.2+14', 'versionCode': 14};
    };
  });

  tearDown(() {
    UpdateService.debugFetchOverride = null;
    UpdateService.debugChannelOverride = null;
    UpdateService.debugPublicKeyOverride = null;
  });

  // 不会被真正请求（fetch 全被 override）
  const src = 'http://127.0.0.1:9/latest.json';

  Future<void> expectRejected(String body) async {
    UpdateService.debugFetchOverride = (url) async => body;
    await expectLater(
      UpdateService.instance.checkUpdate(sourceUrl: src),
      throwsA(isA<UpdateException>().having(
          (e) => e.message, 'message', UpdateMessages.signVerifyFailed)),
    );
  }

  test('canonical payload 规范：五字段竖线连接 + sha256 归一小写 + 十进制整数', () {
    final m = UpdateManifest.tryParse(jsonEncode({
      'versionName': '1.7.0+15',
      'versionCode': 15,
      'apk': 'heng-1.7.0+15-local-release.apk',
      'sha256': 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789',
      'sizeBytes': 80530636,
    }));
    expect(m, isNotNull);
    expect(
      m!.canonicalPayload,
      '1.7.0+15|15|heng-1.7.0+15-local-release.apk'
      '|abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
      '|80530636',
    );
  });

  test('tryParse：signature 可缺省（缺省 ≠ 解析失败）；坏类型按缺省处理', () {
    const goodSha =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    final base = {
      'versionName': '1.7.0+15',
      'versionCode': 15,
      'apk': 'a.apk',
      'sha256': goodSha,
    };
    // 缺省 → 解析成功、signature 为 null（由 checkUpdate 验签环节拒绝）
    final noSig = UpdateManifest.tryParse(jsonEncode(base));
    expect(noSig, isNotNull);
    expect(noSig!.signature, isNull);
    // 合法字符串 → 透传
    final withSig = UpdateManifest.tryParse(
        jsonEncode({...base, 'signature': 'QUJDRA=='}));
    expect(withSig!.signature, 'QUJDRA==');
    // 非字符串（数字）→ 按缺省（null），不判解析失败
    final badType = UpdateManifest.tryParse(
        jsonEncode({...base, 'signature': 12345}));
    expect(badType, isNotNull);
    expect(badType!.signature, isNull);
  });

  test('好签名 → checkUpdate 通过（available=true）', () async {
    final body = await fx.manifestJson();
    UpdateService.debugFetchOverride = (url) async => body;
    final r = await UpdateService.instance.checkUpdate(sourceUrl: src);
    expect(r.available, isTrue);
    expect(r.manifest!.versionName, '1.7.0+15');
    expect(r.manifest!.signature, isNotNull);
  });

  test('坏签名（翻转签名字节）→ signVerifyFailed', () async {
    final body = await fx.manifestJson();
    final map = jsonDecode(body) as Map<String, Object?>;
    final sigBytes = base64Decode(map['signature']! as String);
    sigBytes[0] ^= 0xFF;
    map['signature'] = base64Encode(sigBytes);
    await expectRejected(jsonEncode(map));
  });

  test('缺 signature 字段 → signVerifyFailed', () async {
    final body = await fx.manifestJson();
    final map = jsonDecode(body) as Map<String, Object?>..remove('signature');
    await expectRejected(jsonEncode(map));
  });

  test('signature 为空串 → signVerifyFailed', () async {
    final body = await fx.manifestJson();
    final map = jsonDecode(body) as Map<String, Object?>
      ..['signature'] = '';
    await expectRejected(jsonEncode(map));
  });

  test('signature 非字符串（数字）→ signVerifyFailed', () async {
    final body = await fx.manifestJson();
    final map = jsonDecode(body) as Map<String, Object?>
      ..['signature'] = 12345;
    await expectRejected(jsonEncode(map));
  });

  group('篡改任一 payload 字段（签名仍为原字段）→ signVerifyFailed', () {
    // 每个用例：签好合法清单 → 单独改一个字段 → 验签必拒
    // （篡改 versionCode 用更大值：证明验签先于 versionCode 比较，
    //   若先比较再验签则此用例会漏过）
    final tamperCases = <String, Object?>{
      'versionName': '9.9.9+99',
      'versionCode': 16,
      'apk': 'evil.apk',
      'sha256': List.filled(64, 'f').join(),
      'sizeBytes': 999999999,
    };
    for (final entry in tamperCases.entries) {
      test('篡改 ${entry.key}', () async {
        final body = await fx.manifestJson();
        final map = jsonDecode(body) as Map<String, Object?>
          ..[entry.key] = entry.value;
        await expectRejected(jsonEncode(map));
      });
    }
  });

  test('公钥不可加载（无 override、plain test 宿主无 asset）→ signVerifyFailed',
      () async {
    UpdateService.debugPublicKeyOverride = null;
    final body = await fx.manifestJson();
    await expectRejected(body);
  });
}
