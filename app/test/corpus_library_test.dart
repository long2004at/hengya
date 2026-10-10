import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:hengya/services/local/corpus/extract_all.dart'
    show ensureCorpusSchema;
import 'package:hengya/services/local/corpus_library.dart';

void main() {
  if (Platform.isWindows) {
    open.overrideFor(
      OperatingSystem.windows,
      () => DynamicLibrary.open(File('test/sqlite3.dll').absolute.path),
    );
  }
  late Directory temp;
  late String dir;
  late CorpusLibrary library;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('hengya-library-');
    dir = '${temp.path}/corpus';
    Directory('$dir/incoming').createSync(recursive: true);
    library = CorpusLibrary(dir);
    final db = sqlite3.open('$dir/corpus.db');
    ensureCorpusSchema(db);
    db.execute(
      'CREATE TABLE vec_chunks(chunk_id TEXT PRIMARY KEY,v BLOB NOT NULL)',
    );
    db.dispose();
    File(
      '${temp.path}/hengya.db',
    ).writeAsStringSync('cards-and-review-history-must-not-change');
  });
  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });
  void seed(
    String subject,
    String ppt, {
    String source = 'tree',
    String? relative,
    String? hint,
    int count = 1,
    String type = 'ppt',
    bool register = true,
  }) {
    File? file;
    if (relative != null) {
      file = File('$dir/incoming/$relative');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('original $subject $ppt');
    }
    final db = sqlite3.open('$dir/corpus.db');
    for (var i = 0; i < count; i++) {
      final id = '$subject-$ppt-$i';
      db.execute('INSERT INTO chunks VALUES (?,?,?,?,?,?,?,?,?,?)', [
        id,
        subject,
        ppt,
        '资料 $ppt',
        i + 1,
        i + 1,
        '标题 $i',
        '正文 $i',
        type,
        '2026-10-09',
      ]);
      db.execute('INSERT INTO vectors VALUES (?,?,?,?)', [
        id,
        1,
        Uint8List.fromList([1]),
        1.0,
      ]);
      db.execute('INSERT INTO vec_chunks VALUES (?,?)', [id, Uint8List(4)]);
      db.execute('INSERT INTO chunk_state VALUES (?,?,?,?)', [
        id,
        'md5',
        'test',
        0,
      ]);
      db.execute('INSERT INTO chunks_fts VALUES (?,?,?)', [
        id,
        '标题 $i',
        '正文 $i',
      ]);
    }
    if (register) {
      db.execute('INSERT INTO deck_state VALUES (?,?,?,?,?,?,?)', [
        subject,
        ppt,
        source,
        hint ?? file?.path,
        'md5',
        count,
        'now',
      ]);
    }
    db.dispose();
    if (relative != null) {
      final manifest = File('$dir/extract_manifest.json');
      final m = manifest.existsSync()
          ? jsonDecode(manifest.readAsStringSync()) as Map
          : <String, dynamic>{'files': <String, dynamic>{}};
      (m['files'] as Map)[relative] = {
        'subject': subject,
        'ppt_id': ppt,
        'size': file!.lengthSync(),
        'mtime': file.lastModifiedSync().millisecondsSinceEpoch ~/ 1000,
        'chunk_ids': [for (var i = 0; i < count; i++) '$subject-$ppt-$i'],
      };
      manifest.writeAsStringSync(jsonEncode(m));
      File('$dir/chunks.jsonl').writeAsStringSync(
        '${[
          for (var i = 0; i < count; i++) jsonEncode({'subject_id': subject, 'ppt_id': ppt, 'chunk_id': '$subject-$ppt-$i', 'text': '正文 $i'}),
        ].join('\n')}\n',
        mode: FileMode.append,
      );
    }
  }

  int count(String table) {
    final db = sqlite3.open('$dir/corpus.db');
    try {
      return db.select('SELECT COUNT(*) n FROM $table').first['n'] as int;
    } finally {
      db.dispose();
    }
  }

  CorpusDocument document(String title) =>
      library.inventory().documents.firstWhere((d) => d.title == title);

  test('清单覆盖已入库、无登记、语料包、待建库、空登记及公共大纲', () {
    seed('math', 'lesson', relative: 'math/lesson.pptx', count: 2);
    seed('unknown', 'old', register: false);
    seed(
      'bio',
      'book',
      source: 'package',
      type: 'textbook',
      hint: '/foreign/book.pdf',
    );
    seed('chem', 'empty', count: 0);
    File('$dir/incoming/new.pdf').writeAsStringSync('pending');
    File(
      '$dir/incoming/readme.txt',
    ).writeAsStringSync('unsupported but visible');
    final db = sqlite3.open('$dir/corpus.db');
    db.execute(
      'INSERT INTO outline_entries(level,part,subject,subject_name,unit,subtopic,point,path,seq) VALUES (?,?,?,?,?,?,?,?,?)',
      ['zhiye', '口腔', 'math', '数学', '单元', '细目', '要点', '路径', 1],
    );
    db.dispose();
    final inventory = library.inventory();
    expect(inventory.complete, true);
    expect(inventory.totalChunks, 4);
    expect(inventory.totalOutlineEntries, 1);
    expect(inventory.documents, hasLength(7));
    expect(
      inventory.documents.fold(0, (n, d) => n + d.chunks),
      inventory.totalChunks,
    );
    expect(
      inventory.documents.any((d) => d.subjectId == '' && d.needsBuild),
      true,
    );
    expect(
      inventory.documents.any((d) => d.origin == 'package' && !d.hasOriginal),
      true,
    );
    expect(
      inventory.documents.any(
        (d) => d.kind == 'outline' && d.relatedSubjects.contains('math'),
      ),
      true,
    );
  });
  test('正文完整分页，后面的内容也能搜索到，不经过检索 top-k', () {
    seed('math', 'many', count: 83);
    final d = document('资料 many');
    final first = library.content(d.id);
    final last = library.content(d.id, offset: 80);
    expect(first['total'], 83);
    expect(first['items'] as List, hasLength(40));
    expect(last['items'] as List, hasLength(3));
    final found = library.content(d.id, query: '正文 82');
    expect(found['total'], 1);
    expect((found['items'] as List).single['text'], '正文 82');
  });
  test('删除同时清理正文、两种向量、FTS、登记、缓存和原件，保留其他资料及卡片', () async {
    seed('math', 'remove', relative: 'math/same.pptx', count: 2);
    seed('bio', 'keep', relative: 'bio/same.pptx');
    final d = document('资料 remove');
    await library.deleteDocument(d.id, d.revision);
    for (final table in [
      'chunks',
      'vectors',
      'vec_chunks',
      'chunk_state',
      'chunks_fts',
      'deck_state',
    ]) {
      expect(count(table), 1, reason: table);
    }
    expect(File('$dir/incoming/math/same.pptx').existsSync(), false);
    expect(File('$dir/incoming/bio/same.pptx').existsSync(), true);
    final manifest =
        jsonDecode(File('$dir/extract_manifest.json').readAsStringSync())
            as Map;
    expect((manifest['files'] as Map).keys, ['bio/same.pptx']);
    expect(
      File('$dir/chunks.jsonl').readAsStringSync(),
      isNot(contains('remove')),
    );
    expect(
      File('${temp.path}/hengya.db').readAsStringSync(),
      'cards-and-review-history-must-not-change',
    );
    expect(library.hasPendingDelete, false);
  });
  test('提交后中断可幂等恢复，恢复前原件未删且操作可识别', () async {
    seed('math', 'remove', relative: 'math/file.pptx');
    final d = document('资料 remove');
    final crashing = CorpusLibrary(
      dir,
      afterDeleteCommit: () => throw StateError('模拟进程中断'),
    );
    await expectLater(
      crashing.deleteDocument(d.id, d.revision),
      throwsStateError,
    );
    expect(count('chunks'), 0);
    expect(library.hasPendingDelete, true);
    expect(File('$dir/incoming/math/file.pptx').existsSync(), true);
    library.recoverPendingDelete();
    library.recoverPendingDelete();
    expect(File('$dir/incoming/math/file.pptx').existsSync(), false);
    expect(library.hasPendingDelete, false);
  });
  test('语料包远端登记与本机同名新文件不关联，删包内资料不删新文件', () async {
    seed('math', 'package', source: 'package', hint: 'math/file.pptx');
    Directory('$dir/incoming/math').createSync(recursive: true);
    final fresh = File('$dir/incoming/math/file.pptx')
      ..writeAsStringSync('fresh file');
    File('$dir/extract_manifest.json').writeAsStringSync(
      jsonEncode({
        'files': {
          'math/file.pptx': {
            'subject': 'math',
            'ppt_id': 'package',
            'size': 5,
            'mtime': 0,
            'chunk_ids': ['math-package-0'],
          },
        },
      }),
    );
    final d = document('资料 package');
    expect(d.files, isEmpty);
    expect(library.inventory().documents.any((d) => d.kind == 'file'), true);
    await library.deleteDocument(d.id, d.revision);
    expect(fresh.readAsStringSync(), 'fresh file');
  });
  test('无原件语料包删除不访问外部路径', () async {
    final outside = File('${temp.path}/outside.pdf')..writeAsStringSync('keep');
    seed('math', 'package', source: 'package', hint: outside.path);
    final d = document('资料 package');
    await library.deleteDocument(d.id, d.revision);
    expect(outside.readAsStringSync(), 'keep');
    expect(count('chunks'), 0);
  });
  test('原件路径拒绝遍历、绝对路径和 Windows ADS', () {
    for (final p in [
      '../outside.pdf',
      'a/../../outside',
      '/tmp/test',
      'C:/test',
      'a/file.pdf:stream',
    ]) {
      expect(() => library.sourceFile(p), throwsFormatException, reason: p);
    }
  });
  test('过期删除确认不更改数据', () async {
    seed('math', 'keep', relative: 'math/file.pptx');
    final d = document('资料 keep');
    await expectLater(
      library.deleteDocument(d.id, 'stale-revision'),
      throwsStateError,
    );
    expect(count('chunks'), 1);
    expect(File('$dir/incoming/math/file.pptx').existsSync(), true);
  });
  test('坏登记文件明确标记清单不完整并阻止删除，但仍呈现数据库正文', () async {
    seed('math', 'keep');
    File('$dir/extract_manifest.json').writeAsStringSync('{bad');
    final inventory = library.inventory();
    expect(inventory.complete, false);
    expect(inventory.totalChunks, 1);
    final d = inventory.documents.single;
    await expectLater(
      library.deleteDocument(d.id, d.revision),
      throwsStateError,
    );
    expect(count('chunks'), 1);
  });
  test('大纲按级别删除，其他级别与正文不受影响', () async {
    seed('math', 'keep');
    Directory('$dir/incoming/dagang-outline').createSync(recursive: true);
    File('$dir/incoming/dagang-outline/执业.docx').writeAsStringSync('zhiye');
    File('$dir/incoming/dagang-outline/助理.docx').writeAsStringSync('zhuli');
    final db = sqlite3.open('$dir/corpus.db');
    for (final level in ['zhiye', 'zhuli']) {
      db.execute(
        'INSERT INTO outline_entries(level,part,subject,subject_name,unit,subtopic,point,path,seq) VALUES (?,?,?,?,?,?,?,?,?)',
        [level, '口腔', 'math', '数学', '单元', '细目', '要点', '路径', 1],
      );
      db.execute('INSERT INTO meta VALUES (?,?)', [
        'outline_md5_${level}_x.docx',
        'hash',
      ]);
    }
    db.dispose();
    final d = document('执业考试大纲');
    await library.deleteDocument(d.id, d.revision);
    expect(count('outline_entries'), 1);
    expect(count('chunks'), 1);
    expect(File('$dir/incoming/dagang-outline/执业.docx').existsSync(), false);
    expect(File('$dir/incoming/dagang-outline/助理.docx').existsSync(), true);
  });
  test('已提交删除期间原件被替换时拒绝继续删除新文件', () async {
    seed('math', 'remove', relative: 'math/file.pptx');
    final d = document('资料 remove');
    final crashing = CorpusLibrary(
      dir,
      afterDeleteCommit: () => throw StateError('中断'),
    );
    await expectLater(
      crashing.deleteDocument(d.id, d.revision),
      throwsStateError,
    );
    File('$dir/incoming/math/file.pptx').writeAsStringSync('a replacement');
    expect(() => library.recoverPendingDelete(), throwsStateError);
    expect(
      File('$dir/incoming/math/file.pptx').readAsStringSync(),
      'a replacement',
    );
  });
  test('只上传未建库的原件也能删除，不影响其他原件', () async {
    File('$dir/incoming/a.pdf').writeAsStringSync('pending a');
    File('$dir/incoming/b.pdf').writeAsStringSync('pending b');
    final d = library.inventory().documents.firstWhere(
      (d) => d.title == 'a.pdf',
    );
    await library.deleteDocument(d.id, d.revision);
    expect(File('$dir/incoming/a.pdf').existsSync(), false);
    expect(File('$dir/incoming/b.pdf').readAsStringSync(), 'pending b');
  });
  test('未提交的删除日志只清理暂存文件，不删除原件或正文', () {
    seed('math', 'keep', relative: 'math/file.pptx');
    final staged = File('$dir/.library-delete-123.manifest')
      ..writeAsStringSync('{}');
    File('$dir/$corpusDeleteJournalName').writeAsStringSync(
      jsonEncode({
        'version': 1,
        'operation': '123',
        'sources': [
          {'path': 'math/file.pptx', 'sha256': 'unused'},
        ],
        'replacements': [
          {
            'target': 'extract_manifest.json',
            'staged': '.library-delete-123.manifest',
            'before': 'unused',
            'after': 'unused',
          },
        ],
      }),
    );
    library.recoverPendingDelete();
    expect(staged.existsSync(), false);
    expect(library.hasPendingDelete, false);
    expect(count('chunks'), 1);
    expect(File('$dir/incoming/math/file.pptx').existsSync(), true);
  });
  test('全新语料目录准备删除后中断，数据库先于日志存在且可安全恢复', () async {
    File('$dir/corpus.db').deleteSync();
    File('$dir/incoming/new.pdf').writeAsStringSync('never indexed');
    final d = library.inventory().documents.single;
    final crashing = CorpusLibrary(
      dir,
      afterDeletePrepared: () => throw StateError('准备后中断'),
    );
    await expectLater(
      crashing.deleteDocument(d.id, d.revision),
      throwsStateError,
    );
    expect(File('$dir/corpus.db').existsSync(), true);
    expect(library.hasPendingDelete, true);
    library.recoverPendingDelete();
    expect(library.hasPendingDelete, false);
    expect(File('$dir/incoming/new.pdf').readAsStringSync(), 'never indexed');
  });
  test('大纲目录中的 PDF 明确标为不支持建库，而不是待建库', () {
    Directory('$dir/incoming/dagang-outline').createSync(recursive: true);
    File('$dir/incoming/dagang-outline/wrong.pdf').writeAsStringSync('pdf');
    final d = library.inventory().documents.single;
    expect(d.files.single.supported, false);
    expect(d.needsBuild, false);
    expect(d.status, '需检查原件');
  });
  test('准备阶段解析缓存失败时清理暂存文件，原件与正文不变', () async {
    seed('math', 'keep', relative: 'math/file.pptx');
    File('$dir/chunks.jsonl').writeAsStringSync('{invalid json\n');
    final d = document('资料 keep');
    await expectLater(
      library.deleteDocument(d.id, d.revision),
      throwsFormatException,
    );
    expect(count('chunks'), 1);
    expect(File('$dir/incoming/math/file.pptx').existsSync(), true);
    expect(library.hasPendingDelete, false);
    expect(
      Directory(dir).listSync().where(
        (f) => f.path
            .split(Platform.pathSeparator)
            .last
            .contains('.library-delete-'),
      ),
      isEmpty,
    );
  });
}
