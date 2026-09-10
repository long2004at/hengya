// 固定测试密钥对 fixture（安全修复 B：更新清单 Ed25519 验签）。
//
// seed 固定 → 每次运行派生出同一密钥对（等价硬编码 fixture，不随机）。
// 供 update_signature_test / update_service_test / update_settings_ui_test
// 复用：正例签出合法清单；负例篡改字段/签名后断言拒绝。
//
// 【纪律】仅测试用，与生产公钥（assets/certs/update_pub.b64）无关。
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// 固定 Ed25519 seed（32 字节）
final List<int> kUpdateTestSeed =
    List<int>.generate(32, (i) => (i * 7 + 11) & 0xFF);

class UpdateSignFixture {
  UpdateSignFixture._(this._keyPair, this.publicKeyBytes);

  final SimpleKeyPair _keyPair;

  /// 原始 32 字节公钥（注入 UpdateService.debugPublicKeyOverride）
  final List<int> publicKeyBytes;

  /// 由固定 seed 派生密钥对（同 seed 恒同 key）
  static Future<UpdateSignFixture> load() async {
    final keyPair = await Ed25519().newKeyPairFromSeed(kUpdateTestSeed);
    final pub = await keyPair.extractPublicKey();
    return UpdateSignFixture._(keyPair, pub.bytes);
  }

  /// canonical payload——与 update_service.dart 逐字段一致：
  /// `$versionName|$versionCode|$apk|$sha256|$sizeBytes`
  /// （sha256 归一小写——对齐 App 端 tryParse 的归一化语义）
  String canonicalPayload({
    required String versionName,
    required int versionCode,
    required String apk,
    required String sha256,
    required int sizeBytes,
  }) =>
      '$versionName|$versionCode|$apk|${sha256.toLowerCase()}|$sizeBytes';

  /// Ed25519 签名 → base64 无换行
  Future<String> sign(String payload) async {
    final sig = await Ed25519().sign(utf8.encode(payload), keyPair: _keyPair);
    return base64Encode(sig.bytes);
  }

  /// 构造带合法签名的 latest.json 原文（字段与生产契约一致）
  Future<String> manifestJson({
    String versionName = '1.7.0+15',
    int versionCode = 15,
    String apk = 'fake.apk',
    String sha256 =
        '0000000000000000000000000000000000000000000000000000000000000000',
    int sizeBytes = 1234567,
    String date = '2026-09-07T12:00:00Z',
    String notes = '修复若干问题',
  }) async {
    final payload = canonicalPayload(
      versionName: versionName,
      versionCode: versionCode,
      apk: apk,
      sha256: sha256,
      sizeBytes: sizeBytes,
    );
    return jsonEncode({
      'versionName': versionName,
      'versionCode': versionCode,
      'apk': apk,
      'sha256': sha256,
      'sizeBytes': sizeBytes,
      'date': date,
      'notes': notes,
      'signature': await sign(payload),
    });
  }
}
