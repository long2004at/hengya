// 缓存分类治理（cache_cleaner）验证：五类残留识别与字节统计 / clean 两态
// （includeBackups: false 保备份、true 连备份删）/ updateApks 版本守卫
// （当前版本 APK 保留、旧版 APK 与断点侧车清理）/ 不存在与占用异常路径不抛 /
// 注入假 dataDir/cacheDir/currentVersion（宿主不做真实 App 目录操作，也不触发
// path_provider / package_info）。
//
// 纯 Dart 测试纪律：不 TestWidgetsFlutterBinding；Windows 宿主临时目录构造
// 假残留（Directory.systemTemp 建根 + tearDown 递归清理）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hengya/services/local/cache_cleaner.dart';

void main() {
  late Directory root;
  late String dataDir;
  late String cacheDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cache_cleaner_test_');
    dataDir = '${root.path}/data';
    cacheDir = '${root.path}/cache';
    Directory('$dataDir/corpus').createSync(recursive: true);
    Directory('$dataDir/update').createSync(recursive: true);
    Directory(cacheDir).createSync(recursive: true);
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 构造一整套假残留（验收场景铺底）：
  ///  importTmp 2 项（100B + 嵌套子目录 200B = 300B）
  ///  pkgValidate 2 项（300B + 400B = 700B）
  ///  zipCopies 2 项（500B + 700B = 1200B）
  ///  backups 1 项（1000B）
  ///  updateApks 2 项（旧版 APK 2000B + 断点侧车 30B；当前版本 APK 2100B 保留）
  ///  另埋非匹配干扰项（.txt / 无后缀前缀目录 / 别处的 .import-tmp）应被忽略。
  void seedFakeResidue() {
    // a) 导入残留（dataDir/corpus/.import-tmp-*）
    Directory('$dataDir/corpus/.import-tmp-a').createSync(recursive: true);
    File(
      '$dataDir/corpus/.import-tmp-a/f1.bin',
    ).writeAsBytesSync(List.filled(100, 1));
    Directory('$dataDir/corpus/.import-tmp-b/sub').createSync(recursive: true);
    File(
      '$dataDir/corpus/.import-tmp-b/sub/f2.bin',
    ).writeAsBytesSync(List.filled(200, 2));

    // b) 校验残留（cacheDir/hengya-pkg-validate_*）
    Directory('$cacheDir/hengya-pkg-validate_x').createSync(recursive: true);
    File(
      '$cacheDir/hengya-pkg-validate_x/corpus.db',
    ).writeAsBytesSync(List.filled(300, 3));
    Directory('$cacheDir/hengya-pkg-validate_y').createSync(recursive: true);
    File(
      '$cacheDir/hengya-pkg-validate_y/corpus.db',
    ).writeAsBytesSync(List.filled(400, 4));

    // c) zip 拷贝（cacheDir/*.zip）
    File('$cacheDir/fake.zip').writeAsBytesSync(List.filled(500, 5));
    File('$cacheDir/other.ZIP').writeAsBytesSync(List.filled(700, 6));

    // d) 旧库备份（dataDir/corpus/bak-*）
    Directory('$dataDir/corpus/bak-1').createSync(recursive: true);
    File(
      '$dataDir/corpus/bak-1/corpus.db',
    ).writeAsBytesSync(List.filled(1000, 7));

    // e) 更新下载残留（dataDir/update/；当前版本 = 0.1.22）
    File(
      '$dataDir/update/hengya-v0.1.21-release.apk',
    ).writeAsBytesSync(List.filled(2000, 8));
    File(
      '$dataDir/update/hengya-v0.1.23-release.apk.part',
    ).writeAsBytesSync(List.filled(10, 8));
    File(
      '$dataDir/update/hengya-v0.1.23-release.apk.part.json',
    ).writeAsBytesSync(List.filled(20, 8));
    // 当前版本 APK：保留（升级失败可零流量重装）
    File(
      '$dataDir/update/hengya-v0.1.22-release.apk',
    ).writeAsBytesSync(List.filled(2100, 8));

    // 干扰项（都不该被识别为任何一类）
    File('$cacheDir/note.txt').writeAsBytesSync(List.filled(10, 8));
    File(
      '$dataDir/corpus/.import-tmp-notes.md',
    ).writeAsBytesSync(List.filled(10, 9)); // 文件（非目录）不算 importTmp
    Directory('$cacheDir/hengya-pkg-validate').createSync(recursive: true);
    // 无 '_' 后缀（createTempSync 前缀必带 '_'），不应匹配 b 类
    Directory('$cacheDir/.import-tmp-z').createSync(recursive: true);
    // cache 根下的 .import-tmp 不是 a 类（a 类只认 dataDir/corpus 下）
    File(
      '$dataDir/update/hengya-v0.1.21-release.apk.crdownload',
    ).writeAsBytesSync(List.filled(10, 8)); // 不认识的扩展名不动（保稳定）
  }

  group('scan', () {
    test('识别五类残留并统计字节与条目数（含 totalBytes）', () async {
      seedFakeResidue();
      final r = await CacheCleaner.scan(
        dataDir: dataDir,
        cacheDir: cacheDir,
        currentVersion: '0.1.22',
      );

      expect(r.count[CacheCategory.importTmp], 2);
      expect(r.bytes[CacheCategory.importTmp], 300);
      expect(r.count[CacheCategory.pkgValidate], 2);
      expect(r.bytes[CacheCategory.pkgValidate], 700);
      expect(r.count[CacheCategory.zipCopies], 2);
      expect(r.bytes[CacheCategory.zipCopies], 1200);
      expect(r.count[CacheCategory.backups], 1);
      expect(r.bytes[CacheCategory.backups], 1000);
      expect(r.count[CacheCategory.updateApks], 3); // 旧版 APK + 2 侧车
      expect(r.bytes[CacheCategory.updateApks], 2000 + 10 + 20);
      expect(r.totalBytes, 300 + 700 + 1200 + 1000 + 2000 + 10 + 20);
      // 干扰项零计入
      expect(r.count[CacheCategory.zipCopies], 2); // note.txt 不算
    });

    test('五类键恒存在，空目录全为 0', () async {
      final r = await CacheCleaner.scan(
        dataDir: dataDir,
        cacheDir: cacheDir,
        currentVersion: '0.1.22',
      );
      expect(r.bytes.keys.toSet(), CacheCategory.values.toSet());
      expect(r.count.keys.toSet(), CacheCategory.values.toSet());
      expect(r.bytes.values.every((v) => v == 0), isTrue);
      expect(r.count.values.every((v) => v == 0), isTrue);
      expect(r.totalBytes, 0);
    });

    test('当前版本 APK 保留，版本号识别兼容 v 前缀缺失与点分段变体', () async {
      seedFakeResidue();
      // 无 v 前缀的发布名同样识别
      File(
        '$dataDir/update/hengya-0.1.22-release.apk',
      ).writeAsBytesSync(List.filled(50, 8));
      final r = await CacheCleaner.scan(
        dataDir: dataDir,
        cacheDir: cacheDir,
        currentVersion: '0.1.22',
      );
      expect(r.count[CacheCategory.updateApks], 3); // 0.1.22 两个都不算
      expect(
        File('$dataDir/update/hengya-v0.1.22-release.apk').existsSync(),
        isTrue,
      );
      expect(
        File('$dataDir/update/hengya-0.1.22-release.apk').existsSync(),
        isTrue,
      );
    });

    test('currentVersion 缺省（版本未知）→ update/ 下 APK 全按残留计', () async {
      seedFakeResidue();
      final r = await CacheCleaner.scan(dataDir: dataDir, cacheDir: cacheDir);
      expect(r.count[CacheCategory.updateApks], 4); // 含 0.1.22 APK
    });

    test('dataDir/corpus 不存在（local 无残留）→ 不抛且 count 正确', () async {
      File('$cacheDir/fake.zip').writeAsBytesSync(List.filled(50, 1));
      // dataDir 指向不存在的路径
      final r = await CacheCleaner.scan(
        dataDir: '${root.path}/does-not-exist',
        cacheDir: cacheDir,
      );
      expect(r.count[CacheCategory.importTmp], 0);
      expect(r.count[CacheCategory.backups], 0);
      expect(r.count[CacheCategory.zipCopies], 1);
      expect(r.bytes[CacheCategory.zipCopies], 50);
    });

    test('scan 不删除任何东西（只读）', () async {
      seedFakeResidue();
      await CacheCleaner.scan(
        dataDir: dataDir,
        cacheDir: cacheDir,
        currentVersion: '0.1.22',
      );
      expect(Directory('$dataDir/corpus/.import-tmp-a').existsSync(), isTrue);
      expect(File('$cacheDir/fake.zip').existsSync(), isTrue);
      expect(Directory('$dataDir/corpus/bak-1').existsSync(), isTrue);
      expect(
        File('$dataDir/update/hengya-v0.1.21-release.apk').existsSync(),
        isTrue,
      );
    });
  });

  group('clean', () {
    test('includeBackups: false → 删 a/b/c/e，backups 与当前版本 APK 保留', () async {
      seedFakeResidue();
      final progress = <String>[];
      final r = await CacheCleaner.clean(
        includeBackups: false,
        onProgress: progress.add,
        dataDir: dataDir,
        cacheDir: cacheDir,
        currentVersion: '0.1.22',
      );

      expect(r.removedCount[CacheCategory.importTmp], 2);
      expect(r.removedCount[CacheCategory.pkgValidate], 2);
      expect(r.removedCount[CacheCategory.zipCopies], 2);
      expect(r.removedCount[CacheCategory.backups], 0);
      expect(r.removedCount[CacheCategory.updateApks], 3);
      expect(r.freedBytes, 300 + 700 + 1200 + 2000 + 10 + 20);

      expect(Directory('$dataDir/corpus/.import-tmp-a').existsSync(), isFalse);
      expect(Directory('$dataDir/corpus/.import-tmp-b').existsSync(), isFalse);
      expect(
        Directory('$cacheDir/hengya-pkg-validate_x').existsSync(),
        isFalse,
      );
      expect(
        Directory('$cacheDir/hengya-pkg-validate_y').existsSync(),
        isFalse,
      );
      expect(File('$cacheDir/fake.zip').existsSync(), isFalse);
      expect(File('$cacheDir/other.ZIP').existsSync(), isFalse);
      // 备份保留
      expect(Directory('$dataDir/corpus/bak-1').existsSync(), isTrue);
      expect(File('$dataDir/corpus/bak-1/corpus.db').existsSync(), isTrue);
      // 旧版 APK + 断点侧车已清，当前版本 APK 保留
      expect(
        File('$dataDir/update/hengya-v0.1.21-release.apk').existsSync(),
        isFalse,
      );
      expect(
        File('$dataDir/update/hengya-v0.1.23-release.apk.part').existsSync(),
        isFalse,
      );
      expect(
        File('$dataDir/update/hengya-v0.1.23-release.apk.part.json')
            .existsSync(),
        isFalse,
      );
      expect(
        File('$dataDir/update/hengya-v0.1.22-release.apk').existsSync(),
        isTrue,
      );
      // 不认识的扩展名不动（保稳定）
      expect(
        File('$dataDir/update/hengya-v0.1.21-release.apk.crdownload')
            .existsSync(),
        isTrue,
      );

      // onProgress 有进度文案（开始 / 逐项 / 跳过备份 / 完成）
      expect(progress.isEmpty, isFalse);
      expect(progress.first, contains('开始清理'));
      expect(progress.last, contains('清理完成'));
      expect(progress.any((m) => m.contains('跳过旧库备份')), isTrue);
      expect(progress.any((m) => m.contains('已删除')), isTrue);
    });

    test('includeBackups: true → backups 也删，freedBytes 含备份', () async {
      seedFakeResidue();
      final r = await CacheCleaner.clean(
        includeBackups: true,
        dataDir: dataDir,
        cacheDir: cacheDir,
        currentVersion: '0.1.22',
      );
      expect(r.removedCount[CacheCategory.backups], 1);
      expect(r.freedBytes, 300 + 700 + 1200 + 1000 + 2000 + 10 + 20);
      expect(Directory('$dataDir/corpus/bak-1').existsSync(), isFalse);
    });

    test('clean 不存在路径/重复清理不抛（幂等，第二次全 0）', () async {
      seedFakeResidue();
      final r1 = await CacheCleaner.clean(
        includeBackups: true,
        dataDir: dataDir,
        cacheDir: cacheDir,
        currentVersion: '0.1.22',
      );
      expect(r1.freedBytes, greaterThan(0));
      // 第二次：目标已消失 → 不抛、全 0
      final r2 = await CacheCleaner.clean(
        includeBackups: true,
        dataDir: dataDir,
        cacheDir: cacheDir,
        currentVersion: '0.1.22',
      );
      expect(r2.freedBytes, 0);
      expect(r2.removedCount.values.every((v) => v == 0), isTrue);
      // dataDir 不存在也不抛
      await CacheCleaner.clean(
        includeBackups: true,
        dataDir: '${root.path}/does-not-exist',
        cacheDir: cacheDir,
        currentVersion: '0.1.22',
      );
    });

    test('单项删除失败（文件占用）不阻断整体，freedBytes 不含失败项', () async {
      seedFakeResidue();
      // Windows 上打开句柄会阻止删除（FILE_SHARE_DELETE 未开）→ 该 zip 删不掉
      final locked = File('$cacheDir/fake.zip');
      final raf = locked.openSync();
      addTearDown(() {
        try {
          raf.closeSync();
        } catch (_) {}
      });
      try {
        final r = await CacheCleaner.clean(
          includeBackups: false,
          dataDir: dataDir,
          cacheDir: cacheDir,
          currentVersion: '0.1.22',
        );
        // zipCopies 失败 1 项 → 只成功 1 项（other.ZIP 的 700B）
        expect(r.removedCount[CacheCategory.zipCopies], 1);
        expect(r.freedBytes, 300 + 700 + 700 + 2000 + 10 + 20);
        expect(locked.existsSync(), isTrue); // 占用中未被删
        expect(File('$cacheDir/other.ZIP').existsSync(), isFalse);
        expect(
          Directory('$dataDir/corpus/.import-tmp-a').existsSync(),
          isFalse,
        );
        expect(Directory('$dataDir/corpus/bak-1').existsSync(), isTrue);
      } finally {
        try {
          raf.closeSync();
        } catch (_) {}
      }
    });

    test('cache 目录不存在 → 不抛且无操作', () async {
      final r = await CacheCleaner.clean(
        includeBackups: true,
        dataDir: dataDir,
        cacheDir: '${root.path}/no-cache-dir',
      );
      expect(r.freedBytes, 0);
      expect(r.removedCount.values.every((v) => v == 0), isTrue);
    });
  });
}
