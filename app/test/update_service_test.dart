// 应用内更新服务单元测试（batch3 node1）。
//
// 【宿主纪律】本文件是 **plain test**：刻意不调 TestWidgetsFlutterBinding
// .ensureInitialized()——那会把 dart:io HttpClient 替换为恒 400 假实现，
// 本文件的检查/下载链路全靠真 HttpClient + 本机回环 HttpServer。
// sqlite3 需真库（源 URL 持久化用例）：Windows 宿主显式加载 test/sqlite3.dll。
//
// 覆盖面：
//   1. latest.json 解析：完整契约 / 缺字段 / 坏 JSON / apk 路径穿越 / sha256 归一化
//   2. 版本比较：versionCode 更新→提示；相等/更旧→「已是最新」（降级拒绝）
//   3. 检查失败映射：HTTP 404 / 连不上（关掉的服务器端口）/ 坏 JSON / 空 URL / 非 http
//   4. 下载+校验：正常（进度回调/落盘）、sha256 不符 → 删文件 + verifyFailed
//   5. 源 URL db 持久化（settings 表 update.source 回写回读）
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  // Windows 测试宿主：显式加载 test/sqlite3.dll（CWD = 包根 app/）
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => ffi.DynamicLibrary.open(dll));
  }

  late Directory tmp;
  late HttpServer server;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hengya_update_test_');
    // LocalBackend：下载目录（dataDir/update/）+ 源 URL 持久化都要它
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    UpdateService.debugFetchOverride = null;
    UpdateService.debugChannelOverride = null;
    await server.close(force: true);
    await LocalBackend.instance.resetForTest();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  // 假「当前应用版本」：真实通道在此宿主不存在，必须注入
  void fakePackage({String versionName = '1.6.2+14', int versionCode = 14}) {
    UpdateService.debugChannelOverride = (method, [args]) async {
      assert(method == 'getPackageInfo');
      return {'versionName': versionName, 'versionCode': versionCode};
    };
  }

  /// 回环 HTTP 服务：/latest.json 吐 manifestBody；/fake.apk 吐 apkBytes
  void serveRoutes({required String manifestBody, required List<int> apkBytes}) {
    server.listen((req) async {
      if (req.uri.path == '/latest.json') {
        req.response.statusCode = 200;
        req.response.headers.contentType = ContentType.json;
        req.response.add(utf8.encode(manifestBody));
      } else if (req.uri.path == '/fake.apk') {
        req.response.statusCode = 200;
        req.response.headers.contentLength = apkBytes.length;
        req.response.add(apkBytes);
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  }

  String latestJson({
    String versionName = '1.7.0+15',
    int versionCode = 15,
    String apk = 'fake.apk',
    String sha256 = '',
    int sizeBytes = 1234567,
  }) =>
      jsonEncode({
        'versionName': versionName,
        'versionCode': versionCode,
        'apk': apk,
        'sha256': sha256,
        'sizeBytes': sizeBytes,
        'date': '2026-09-07T12:00:00Z',
        'notes': '修复若干问题',
      });

  test('UpdateManifest.tryParse：完整契约逐字段 + sha256 归一化小写 + sizeDisplay', () {
    final body = jsonEncode({
      'versionName': '1.7.0+15',
      'versionCode': 15,
      'apk': 'heng-1.7.0+15-local-release.apk',
      'sha256': 'ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789',
      'sizeBytes': 80530636,
      'date': '2026-09-07T12:00:00Z',
      'notes': '第一行\n第二行',
    });
    final m = UpdateManifest.tryParse(body);
    expect(m, isNotNull);
    expect(m!.versionName, '1.7.0+15');
    expect(m.versionCode, 15);
    expect(m.apk, 'heng-1.7.0+15-local-release.apk');
    expect(m.sha256,
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789');
    expect(m.sizeBytes, 80530636);
    expect(m.date, '2026-09-07T12:00:00Z');
    expect(m.notes, '第一行\n第二行');
    expect(m.sizeDisplay, '76.8 MB');
  });

  test('tryParse 容错：缺字段/类型错/坏 JSON/非对象 → null', () {
    final goodSha =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    // 坏 JSON
    expect(UpdateManifest.tryParse('not json {'), isNull);
    // 顶层非对象
    expect(UpdateManifest.tryParse('[1,2,3]'), isNull);
    expect(UpdateManifest.tryParse('"str"'), isNull);
    // 缺 sha256 / 缺 versionCode / 缺 apk / 缺 versionName
    expect(
      UpdateManifest.tryParse(
          '{"versionName":"1.7.0+15","versionCode":15,"apk":"a.apk"}'),
      isNull,
    );
    expect(
      UpdateManifest.tryParse(
          '{"versionName":"1.7.0+15","apk":"a.apk","sha256":"$goodSha"}'),
      isNull,
    );
    expect(
      UpdateManifest.tryParse(
          '{"versionName":"1.7.0+15","versionCode":15,"sha256":"$goodSha"}'),
      isNull,
    );
    expect(
      UpdateManifest.tryParse(
          '{"versionCode":15,"apk":"a.apk","sha256":"$goodSha"}'),
      isNull,
    );
    // 类型错：versionCode 字符串
    expect(
      UpdateManifest.tryParse(
          '{"versionName":"1.7.0+15","versionCode":"15","apk":"a.apk","sha256":"$goodSha"}'),
      isNull,
    );
    // sha256 非 64 hex
    expect(
      UpdateManifest.tryParse(
          '{"versionName":"1.7.0+15","versionCode":15,"apk":"a.apk","sha256":"short"}'),
      isNull,
    );
    // apk 带路径分隔符（防穿越）：绝对路径 / 相对路径 / 反斜杠
    // （jsonEncode 构造：保证反斜杠在 JSON 里被正确转义——裸插值会把 \ 变成 \b 等转义）
    for (final apk in const [
      '../evil.apk',
      '/etc/passwd',
      'a\\b.apk',
    ]) {
      expect(
        UpdateManifest.tryParse(jsonEncode({
          'versionName': 'v',
          'versionCode': 15,
          'apk': apk,
          'sha256': goodSha,
        })),
        isNull,
        reason: 'apk=$apk 应被拒绝',
      );
    }
    // 可选字段缺失可容忍（sizeBytes/notes 缺省回退）
    final m = UpdateManifest.tryParse(
        '{"versionName":"1.7.0+15","versionCode":15,"apk":"a.apk","sha256":"$goodSha"}');
    expect(m, isNotNull);
    expect(m!.sizeBytes, 0);
    expect(m.sizeDisplay, '大小未知');
    expect(m.notes, '');
    expect(m.date, isNull);
  });

  group('checkUpdate 版本比较（真 HTTP 回环 + 假原生版本）', () {
    test('versionCode 更大（15 > 14）→ 提示更新', () async {
      fakePackage();
      serveRoutes(
        manifestBody: latestJson(sha256: List.filled(64, '0').join()),
        apkBytes: [1, 2, 3],
      );
      final r = await UpdateService.instance
          .checkUpdate(sourceUrl: 'http://127.0.0.1:${server.port}/latest.json');
      expect(r.available, isTrue);
      expect(r.manifest!.versionName, '1.7.0+15');
      expect(r.currentVersionCode, 14);
    });

    test('versionCode 相等（14 = 14）→ 已是最新', () async {
      fakePackage();
      serveRoutes(
        manifestBody: latestJson(versionCode: 14, sha256: List.filled(64, '0').join()),
        apkBytes: [1],
      );
      final r = await UpdateService.instance
          .checkUpdate(sourceUrl: 'http://127.0.0.1:${server.port}/latest.json');
      expect(r.available, isFalse);
    });

    test('versionCode 更旧（13 < 14）→ 降级拒绝（已是最新）', () async {
      fakePackage();
      serveRoutes(
        manifestBody: latestJson(versionCode: 13, sha256: List.filled(64, '0').join()),
        apkBytes: [1],
      );
      final r = await UpdateService.instance
          .checkUpdate(sourceUrl: 'http://127.0.0.1:${server.port}/latest.json');
      expect(r.available, isFalse);
    });
  });

  group('checkUpdate 失败映射', () {
    test('空源 → 「请先填写更新源」', () async {
      fakePackage();
      await expectLater(
        UpdateService.instance.checkUpdate(sourceUrl: '  '),
        throwsA(isA<UpdateException>().having(
            (e) => e.message, 'message', UpdateMessages.emptySource)),
      );
    });

    test('非 http/https 协议 → 「更新源地址无效」', () async {
      fakePackage();
      await expectLater(
        UpdateService.instance.checkUpdate(sourceUrl: 'ftp://x/latest.json'),
        throwsA(isA<UpdateException>().having(
            (e) => e.message, 'message', UpdateMessages.badSourceUrl)),
      );
    });

    test('HTTP 404 → 「更新源返回 HTTP 404」', () async {
      fakePackage();
      serveRoutes(manifestBody: '{}', apkBytes: []);
      await expectLater(
        UpdateService.instance.checkUpdate(
            sourceUrl: 'http://127.0.0.1:${server.port}/nope.json'),
        throwsA(isA<UpdateException>().having(
            (e) => e.message, 'message', UpdateMessages.httpStatus(404))),
      );
    });

    test('连不上（已关端口）→ 「无法连接更新源…」', () async {
      fakePackage();
      final deadPort = server.port; // 下面先把真 server 关掉拿一个死端口
      await server.close(force: true);
      await expectLater(
        UpdateService.instance
            .checkUpdate(sourceUrl: 'http://127.0.0.1:$deadPort/latest.json'),
        throwsA(isA<UpdateException>().having(
            (e) => e.message, 'message', UpdateMessages.unreachable)),
      );
    });

    test('坏 JSON → 「更新源数据无法解析或缺少必要字段」', () async {
      fakePackage();
      serveRoutes(manifestBody: 'garbage!!!', apkBytes: []);
      await expectLater(
        UpdateService.instance.checkUpdate(
            sourceUrl: 'http://127.0.0.1:${server.port}/latest.json'),
        throwsA(isA<UpdateException>().having(
            (e) => e.message, 'message', UpdateMessages.manifestBad)),
      );
    });
  });

  group('downloadAndVerify（真 HTTP 回环）', () {
    test('正常下载：落盘 dataDir/update/ + 进度回调推进到全量', () async {
      fakePackage();
      final apkBytes = List<int>.generate(300000, (i) => i % 251);
      final digest = crypto.sha256.convert(apkBytes);
      serveRoutes(
        manifestBody: latestJson(sha256: digest.toString(), sizeBytes: apkBytes.length),
        apkBytes: apkBytes,
      );
      final m = UpdateManifest.tryParse(latestJson(
          sha256: digest.toString(), sizeBytes: apkBytes.length))!;
      final progresses = <int>[];
      final file = await UpdateService.instance.downloadAndVerify(
        m,
        sourceUrl: 'http://127.0.0.1:${server.port}/latest.json',
        onProgress: (received, total) {
          progresses.add(received);
          expect(total, apkBytes.length);
        },
      );
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), apkBytes.length);
      // 服务以 '/' 拼 dataDir/update（Android 生产为 POSIX 路径；Windows 亦兼容）
      expect(file.parent.path, '${tmp.path}/update');
      expect(progresses.last, apkBytes.length); // 进度最终=全量
    });

    test('sha256 不符 → 拒装 + 删文件 + verifyFailed 文案', () async {
      fakePackage();
      final apkBytes = List<int>.generate(1000, (i) => i);
      final wrongSha = List.filled(64, '9').join();
      serveRoutes(
        manifestBody: latestJson(sha256: wrongSha, sizeBytes: apkBytes.length),
        apkBytes: apkBytes,
      );
      final m = UpdateManifest.tryParse(latestJson(sha256: wrongSha))!;
      final src = 'http://127.0.0.1:${server.port}/latest.json';
      final destPath =
          '${tmp.path}${Platform.pathSeparator}update${Platform.pathSeparator}fake.apk';
      // 先造一个「上次残留」的同名文件，证明失败路径确实把它清了
      Directory('${tmp.path}/update').createSync(recursive: true);
      File(destPath).writeAsBytesSync(List.filled(8, 7));
      await expectLater(
        UpdateService.instance.downloadAndVerify(m, sourceUrl: src),
        throwsA(isA<UpdateException>().having(
            (e) => e.message, 'message', UpdateMessages.verifyFailed)),
      );
      expect(File(destPath).existsSync(), isFalse); // 下载物被删
    });

    test('复用已校验的安装包：二次调用不触网（服务器已关）+ 进度回调 100%', () async {
      fakePackage();
      final apkBytes = List<int>.generate(300000, (i) => i % 251);
      final digest = crypto.sha256.convert(apkBytes);
      serveRoutes(
        manifestBody:
            latestJson(sha256: digest.toString(), sizeBytes: apkBytes.length),
        apkBytes: apkBytes,
      );
      final m = UpdateManifest.tryParse(latestJson(
          sha256: digest.toString(), sizeBytes: apkBytes.length))!;
      final src = 'http://127.0.0.1:${server.port}/latest.json';
      final f1 =
          await UpdateService.instance.downloadAndVerify(m, sourceUrl: src);
      expect(f1.existsSync(), isTrue);

      // 断网（关掉回环服务器）：复用路径若触网必抛 unreachable
      await server.close(force: true);
      var sawProgress = false;
      var gotTotal = -1;
      final f2 = await UpdateService.instance.downloadAndVerify(
        m,
        sourceUrl: src,
        onProgress: (received, total) {
          sawProgress = true;
          gotTotal = total ?? -1;
        },
      );
      expect(f2.path, f1.path); // 同一文件
      expect(f2.lengthSync(), apkBytes.length);
      expect(sawProgress, isTrue); // 复用也回调进度（页面可显示满进度）
      expect(gotTotal, apkBytes.length);
    });

    test('残留文件与 manifest 不符（损坏/半截）→ 重新下载覆盖为正确内容', () async {
      fakePackage();
      final apkBytes = List<int>.generate(1000, (i) => i);
      final digest = crypto.sha256.convert(apkBytes);
      serveRoutes(
        manifestBody:
            latestJson(sha256: digest.toString(), sizeBytes: apkBytes.length),
        apkBytes: apkBytes,
      );
      final m = UpdateManifest.tryParse(latestJson(sha256: digest.toString()))!;
      final src = 'http://127.0.0.1:${server.port}/latest.json';
      // 造一个内容不符的残留（大小也不同）
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/fake.apk').writeAsBytesSync(List.filled(64, 9));
      final f =
          await UpdateService.instance.downloadAndVerify(m, sourceUrl: src);
      expect(f.lengthSync(), apkBytes.length); // 被正确内容覆盖
    });
  });

  test('源 URL db 持久化：setSourceUrl → getSourceUrl 回读一致（settings 表）', () async {
    const url = 'http://1.2.3.4:8080/heng-token/latest.json';
    await UpdateService.instance.setSourceUrl(url);
    expect(await UpdateService.instance.getSourceUrl(), url);

    // 直查 settings 表确认键名契约 update.source
    final db = await LocalBackend.instance.sharedDb;
    expect(db.settingGet('update.source'), url);
  });

  group('默认源（海外线路 GitHub raw）回退', () {
    test('effectiveSourceUrl：未设置 → GitHub 默认源；设置后 → 持久值', () async {
      expect(await UpdateService.instance.effectiveSourceUrl(),
          UpdateService.githubSourceUrl);
      const url = 'http://1.2.3.4:8080/heng-token/latest.json';
      await UpdateService.instance.setSourceUrl(url);
      expect(await UpdateService.instance.effectiveSourceUrl(), url);
    });

    test('checkUpdate 未传源且 db 未设置 → 用 GitHub 默认源（新装零配置）', () async {
      fakePackage();
      String? fetchedUrl;
      UpdateService.debugFetchOverride = (url) async {
        fetchedUrl = url;
        return latestJson(
            versionName: '1.6.2+14',
            versionCode: 14,
            sha256: List.filled(64, '0').join());
      };
      final r = await UpdateService.instance.checkUpdate();
      expect(fetchedUrl, UpdateService.githubSourceUrl);
      expect(r.available, isFalse);
    });
  });
}
