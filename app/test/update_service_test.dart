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
//   6. 清单签名：本文件所有 latest.json 均带合法 Ed25519 签名（安全修复 B；
//      验签正/负例专项见 update_signature_test.dart）
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:hengya/services/local/local_backend.dart';
import 'package:hengya/services/update/update_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

import 'update_sign_fixture.dart';

void main() {
  // Windows 测试宿主：显式加载 test/sqlite3.dll（CWD = 包根 app/）
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => ffi.DynamicLibrary.open(dll));
  }

  // 固定测试密钥对（checkUpdate 验签公钥经 debugPublicKeyOverride 注入）
  late UpdateSignFixture fx;

  setUpAll(() async {
    fx = await UpdateSignFixture.load();
  });

  late Directory tmp;
  late ServerSocket server;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('hengya_update_test_');
    // LocalBackend：下载目录（dataDir/update/）+ 源 URL 持久化都要它
    await LocalBackend.instance.resetForTest();
    LocalBackend.instance.init(tmp.path);
    UpdateService.debugPublicKeyOverride = fx.publicKeyBytes;
    // 裸 ServerSocket 手写迷你 HTTP 服务（不用 HttpServer：掐线场景经
    // detachSocket 的字节流会被其怪癖污染，见 truncate 模式注释）
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });

  tearDown(() async {
    UpdateService.debugFetchOverride = null;
    UpdateService.debugChannelOverride = null;
    UpdateService.debugPublicKeyOverride = null;
    await server.close();
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

  /// 迷你服务响应端：void async（listen 回调里 fire-and-forget）。
  void miniRespond(
    Socket socket,
    String path,
    String? range,
    Future<String> manifestBody,
    List<int> apkBytes,
    Map<String, Object?> state,
    void Function(String? rangeHeader)? onApkRequest,
  ) async {
    Future<void> reply(String status, String extraHeaders, List<int> body) async {
      socket.add(utf8.encode('HTTP/1.1 $status\r\n'
          'content-length: ${body.length}\r\n'
          '$extraHeaders'
          'connection: close\r\n\r\n'));
      if (body.isNotEmpty) socket.add(body);
      await socket.flush();
      await socket.close();
    }

    if (path == '/latest.json') {
      final body = utf8.encode(await manifestBody);
      await reply('200 OK', 'content-type: application/json\r\n', body);
    } else if (path == '/fake.apk') {
      final mode = state['mode'] as String? ?? 'full';
      onApkRequest?.call(range);
      if (mode == 'truncate') {
        final n = ((state['truncateBytes'] as int?) ?? 0)
            .clamp(0, apkBytes.length);
        socket.add(utf8.encode('HTTP/1.1 200 OK\r\n'
            'content-length: ${apkBytes.length}\r\n'
            'connection: close\r\n\r\n'));
        if (n > 0) socket.add(apkBytes.sublist(0, n));
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await socket.close(); // FIN：收不满声明长度 → 客户端失败 + part 留存
        return;
      }
      final rm =
          range == null ? null : RegExp(r'bytes=(\d+)-').firstMatch(range);
      if (mode == 'full' && rm != null) {
        final start = int.parse(rm.group(1)!);
        if (start >= apkBytes.length) {
          await reply('416 Range Not Satisfiable', '', const []);
        } else {
          await reply(
            '206 Partial Content',
            'content-range: '
                'bytes $start-${apkBytes.length - 1}/${apkBytes.length}\r\n',
            apkBytes.sublist(start),
          );
        }
      } else {
        await reply('200 OK', '', apkBytes);
      }
    } else {
      await reply('404 Not Found', '', const []);
    }
  }

  /// 回环迷你 HTTP 服务（裸 ServerSocket 手写）：/latest.json 吐
  /// manifestBody；/fake.apk 吐 apkBytes。每响应 connection: close。
  ///
  /// [state] 可在用例中途变更：
  /// · mode = 'full'（缺省）：支持 Range → 带 Range 请求回 206 + Content-Range
  ///   + 剩余字节；无 Range 回 200 全量（断点续传正路）
  /// · mode = 'ignore'：无视 Range 恒回 200 全量（服务端不支持续传的回退路）
  /// · mode = 'truncate'：声明全量 content-length 但发 [truncateBytes] 字节后
  ///   先等 500ms（让客户端把已达数据落盘）再 FIN 掐线——客户端收不满声明
  ///   长度即失败，part 留存待续传（模拟弱网中断/退 App）
  /// [onApkRequest] 记录 /fake.apk 请求头（断言 Range 确实发出）。
  void serveRoutes(
      {required Future<String> manifestBody,
      required List<int> apkBytes,
      Map<String, Object?> state = const {},
      void Function(String? rangeHeader)? onApkRequest}) {
    server.listen((socket) {
      final buf = BytesBuilder();
      StreamSubscription? sub;
      sub = socket.listen((data) {
        buf.add(data);
        final head = utf8.decode(buf.toBytes(), allowMalformed: true);
        if (!head.contains('\r\n\r\n')) return; // 请求头未收全（GET 无 body）
        sub?.cancel();
        final lines =
            head.substring(0, head.indexOf('\r\n\r\n')).split('\r\n');
        final reqParts = lines.first.split(' ');
        final path = reqParts.length > 1 ? reqParts[1] : '';
        String? range;
        for (final l in lines.skip(1)) {
          if (l.toLowerCase().startsWith('range:')) {
            range = l.substring('range:'.length).trim();
          }
        }
        miniRespond(
            socket, path, range, manifestBody, apkBytes, state, onApkRequest);
      });
    });
  }

  /// latest.json 原文（带合法 Ed25519 签名——安全修复 B 后 checkUpdate 必验）
  Future<String> latestJson({
    String versionName = '1.7.0+15',
    int versionCode = 15,
    String apk = 'fake.apk',
    String sha256 = '',
    int sizeBytes = 1234567,
  }) async {
    final payload = fx.canonicalPayload(
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
      'date': '2026-09-07T12:00:00Z',
      'notes': '修复若干问题',
      'signature': await fx.sign(payload),
    });
  }

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
      serveRoutes(manifestBody: Future.value('{}'), apkBytes: []);
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
      await server.close();
      await expectLater(
        UpdateService.instance
            .checkUpdate(sourceUrl: 'http://127.0.0.1:$deadPort/latest.json'),
        throwsA(isA<UpdateException>().having(
            (e) => e.message, 'message', UpdateMessages.unreachable)),
      );
    });

    test('坏 JSON → 「更新源数据无法解析或缺少必要字段」', () async {
      fakePackage();
      serveRoutes(manifestBody: Future.value('garbage!!!'), apkBytes: []);
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
      final m = UpdateManifest.tryParse(await latestJson(
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
      final m = UpdateManifest.tryParse(await latestJson(sha256: wrongSha))!;
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
      final m = UpdateManifest.tryParse(await latestJson(
          sha256: digest.toString(), sizeBytes: apkBytes.length))!;
      final src = 'http://127.0.0.1:${server.port}/latest.json';
      final f1 =
          await UpdateService.instance.downloadAndVerify(m, sourceUrl: src);
      expect(f1.existsSync(), isTrue);

      // 断网（关掉回环服务器）：复用路径若触网必抛 unreachable
      await server.close();
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
      final m = UpdateManifest.tryParse(await latestJson(sha256: digest.toString()))!;
      final src = 'http://127.0.0.1:${server.port}/latest.json';
      // 造一个内容不符的残留（大小也不同）
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/fake.apk').writeAsBytesSync(List.filled(64, 9));
      final f =
          await UpdateService.instance.downloadAndVerify(m, sourceUrl: src);
      expect(f.lengthSync(), apkBytes.length); // 被正确内容覆盖
    });

    test('断点续传：中断保留 part → 二次调用 Range 续传完成（206）', () async {
      fakePackage();
      final apkBytes = List<int>.generate(300000, (i) => i % 251);
      final digest = crypto.sha256.convert(apkBytes);
      final m = UpdateManifest.tryParse(await latestJson(
          sha256: digest.toString(), sizeBytes: apkBytes.length))!;
      final src = 'http://127.0.0.1:${server.port}/latest.json';
      // 第一轮：发 100000 字节后掐线 → 下载失败但 part 留存
      final state = <String, Object?>{'mode': 'truncate', 'truncateBytes': 100000};
      serveRoutes(
        manifestBody:
            latestJson(sha256: digest.toString(), sizeBytes: apkBytes.length),
        apkBytes: apkBytes,
        state: state,
      );
      await expectLater(
        UpdateService.instance.downloadAndVerify(m, sourceUrl: src),
        throwsA(isA<UpdateException>()),
      );
      final partFile = File('${tmp.path}/update/fake.apk.part');
      expect(partFile.existsSync(), isTrue); // 半截留存（不再像旧版删掉）
      final partLen = partFile.lengthSync();
      expect(partLen, allOf(greaterThan(0), lessThanOrEqualTo(100000)));
      expect(File('${tmp.path}/update/fake.apk.part.json').existsSync(), isTrue);
      expect(File('${tmp.path}/update/fake.apk').existsSync(), isFalse);

      // 第二轮：网络恢复（full 模式）→ 从断点续传完成
      state['mode'] = 'full';
      var firstProgress = -1;
      final file = await UpdateService.instance.downloadAndVerify(
        m,
        sourceUrl: src,
        onProgress: (received, total) {
          if (firstProgress < 0) firstProgress = received;
        },
      );
      expect(file.lengthSync(), apkBytes.length);
      expect(firstProgress, partLen); // 进度从断点基数起跳
      expect(File('${tmp.path}/update/fake.apk.part').existsSync(), isFalse);
      expect(File('${tmp.path}/update/fake.apk.part.json').existsSync(), isFalse);
    });

    test('断点续传：服务器侧确实收到 Range 头 + 回 206（掐线→恢复全程）', () async {
      fakePackage();
      final apkBytes = List<int>.generate(50000, (i) => (i * 7) % 256);
      final digest = crypto.sha256.convert(apkBytes);
      final m = UpdateManifest.tryParse(await latestJson(
          sha256: digest.toString(), sizeBytes: apkBytes.length))!;
      final src = 'http://127.0.0.1:${server.port}/latest.json';
      final state = <String, Object?>{'mode': 'truncate', 'truncateBytes': 20000};
      final sawRange = <String?>[];
      serveRoutes(
        manifestBody:
            latestJson(sha256: digest.toString(), sizeBytes: apkBytes.length),
        apkBytes: apkBytes,
        state: state,
        onApkRequest: sawRange.add,
      );
      await expectLater(
        UpdateService.instance.downloadAndVerify(m, sourceUrl: src),
        throwsA(isA<UpdateException>()),
      );
      final partLen = File('${tmp.path}/update/fake.apk.part').lengthSync();
      state['mode'] = 'full';
      final file = await UpdateService.instance.downloadAndVerify(
          m, sourceUrl: src);
      expect(file.lengthSync(), apkBytes.length);
      // 第 1 次无 Range（全新下载），第 2 次带断点 Range——续传实锤
      expect(sawRange.length, 2);
      expect(sawRange[0], isNull);
      expect(sawRange[1], 'bytes=$partLen-');
    });

    test('服务端忽略 Range（回 200）→ 弃 part 整包重下，内容仍正确', () async {
      fakePackage();
      final apkBytes = List<int>.generate(5000, (i) => i % 97);
      final digest = crypto.sha256.convert(apkBytes);
      serveRoutes(
        manifestBody:
            latestJson(sha256: digest.toString(), sizeBytes: apkBytes.length),
        apkBytes: apkBytes,
        state: const {'mode': 'ignore'},
      );
      // 手造「中断残留」：part + 指纹一致的侧车
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/fake.apk.part')
          .writeAsBytesSync(apkBytes.sublist(0, 2000));
      File('${tmp.path}/update/fake.apk.part.json').writeAsStringSync(jsonEncode({
        'v': 1,
        'sha256': digest.toString(),
        'sizeBytes': apkBytes.length,
      }));
      final m = UpdateManifest.tryParse(await latestJson(
          sha256: digest.toString(), sizeBytes: apkBytes.length))!;
      final f = await UpdateService.instance.downloadAndVerify(
          m, sourceUrl: 'http://127.0.0.1:${server.port}/latest.json');
      expect(f.lengthSync(), apkBytes.length); // 全量正确（200 整包覆盖）
      expect(File('${tmp.path}/update/fake.apk.part').existsSync(), isFalse);
    });

    test('part 指纹与 manifest 不符（换源/重发布）→ 弃 part 全新下载', () async {
      fakePackage();
      final apkBytes = List<int>.generate(5000, (i) => i % 97);
      final digest = crypto.sha256.convert(apkBytes);
      final sawRange = <String?>[];
      serveRoutes(
        manifestBody:
            latestJson(sha256: digest.toString(), sizeBytes: apkBytes.length),
        apkBytes: apkBytes,
        onApkRequest: sawRange.add,
      );
      // 手造「别份 manifest」的 part（指纹侧车 sha 不符）+ 陈旧其他版本 part
      Directory('${tmp.path}/update').createSync(recursive: true);
      File('${tmp.path}/update/fake.apk.part')
          .writeAsBytesSync(apkBytes.sublist(0, 2000));
      File('${tmp.path}/update/fake.apk.part.json').writeAsStringSync(jsonEncode({
        'v': 1,
        'sha256': List.filled(64, '0').join(), // 另一份的指纹
        'sizeBytes': apkBytes.length,
      }));
      File('${tmp.path}/update/heng-0.0.1.apk.part')
          .writeAsBytesSync(List.filled(999, 1)); // 其他版本孤儿 → 应被清扫
      final m = UpdateManifest.tryParse(await latestJson(
          sha256: digest.toString(), sizeBytes: apkBytes.length))!;
      final f = await UpdateService.instance.downloadAndVerify(
          m, sourceUrl: 'http://127.0.0.1:${server.port}/latest.json');
      expect(f.lengthSync(), apkBytes.length);
      expect(sawRange.single, isNull); // 指纹不符 → 不带 Range（全新下载）
      expect(File('${tmp.path}/update/fake.apk.part').existsSync(), isFalse);
      expect(File('${tmp.path}/update/heng-0.0.1.apk.part').existsSync(), isFalse);
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
        return await latestJson(
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
