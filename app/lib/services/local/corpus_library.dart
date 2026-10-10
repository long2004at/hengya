// 完整语料目录与内容读取。数据库/登记/manifest/原件/大纲取并集，不依赖检索 top-k。
// 删除为显式的跨 SQLite/文件事务：先准备缓存与日志，再提交数据库，最后幂等清理。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';
import 'corpus/extract_all.dart' show ensureCorpusSchema;
import 'corpus/outline_docx.dart' show outlineLevelOfFilename;

const corpusLibraryJobId = 'corpus-library';
const corpusDeleteJournalName = '.library-delete.json';
String corpusTypeLabel(String type) => switch (type) {
  'ppt' => '课件',
  'textbook' => '教材',
  'exam' => '真题',
  'outline' => '考试大纲',
  _ => type.isEmpty || type == 'other' ? '其他 / 未分类' : '其他（$type）',
};
String _str(Object? x) => x?.toString() ?? '';
int _int(Object? x) => x is num ? x.toInt() : 0;
String _id(List<String> parts) =>
    base64Url.encode(utf8.encode(jsonEncode(parts)));
List<String> _parts(String id) =>
    (jsonDecode(utf8.decode(base64Url.decode(id))) as List).cast<String>();

class CorpusSourceFile {
  const CorpusSourceFile({
    required this.relativePath,
    required this.exists,
    this.bytes = 0,
    this.modifiedMs = 0,
    this.isLink = false,
    this.supported = true,
  });
  final String relativePath;
  final bool exists, isLink, supported;
  final int bytes, modifiedMs;
  Map<String, Object?> toMap() => {
    'path': relativePath,
    'exists': exists,
    'bytes': bytes,
    'modifiedMs': modifiedMs,
    'isLink': isLink,
    'supported': supported,
  };
  factory CorpusSourceFile.fromMap(Map m) => CorpusSourceFile(
    relativePath: _str(m['path']),
    exists: m['exists'] == true,
    bytes: _int(m['bytes']),
    modifiedMs: _int(m['modifiedMs']),
    isLink: m['isLink'] == true,
    supported: m['supported'] != false,
  );
}

class CorpusDocument {
  const CorpusDocument({
    required this.id,
    required this.kind,
    required this.subjectId,
    required this.title,
    required this.types,
    required this.chunks,
    required this.outlineEntries,
    required this.origin,
    required this.files,
    required this.revision,
    this.relatedSubjects = const [],
    this.notes = const [],
    this.needsBuild = false,
    this.sourceHint = '',
  });
  final String id, kind, subjectId, title, origin, revision, sourceHint;
  final List<String> types, relatedSubjects, notes;
  final List<CorpusSourceFile> files;
  final int chunks, outlineEntries;
  final bool needsBuild;
  int get entries => chunks + outlineEntries;
  bool get hasOriginal => files.any((f) => f.exists && !f.isLink);
  String get status => files.any((f) => f.isLink || !f.supported)
      ? '需检查原件'
      : needsBuild
      ? '待建库 / 待更新'
      : entries > 0
      ? (hasOriginal
            ? '已建库'
            : origin == 'package'
            ? '语料包内容'
            : '已建库 · 无本机原件')
      : '未生成内容';
  Map<String, Object?> toMap() => {
    'id': id,
    'kind': kind,
    'subjectId': subjectId,
    'title': title,
    'types': types,
    'chunks': chunks,
    'outlineEntries': outlineEntries,
    'origin': origin,
    'files': [for (final f in files) f.toMap()],
    'revision': revision,
    'relatedSubjects': relatedSubjects,
    'notes': notes,
    'needsBuild': needsBuild,
    'sourceHint': sourceHint,
  };
  factory CorpusDocument.fromMap(Map m) => CorpusDocument(
    id: _str(m['id']),
    kind: _str(m['kind']),
    subjectId: _str(m['subjectId']),
    title: _str(m['title']),
    origin: _str(m['origin']),
    chunks: _int(m['chunks']),
    outlineEntries: _int(m['outlineEntries']),
    revision: _str(m['revision']),
    types: (m['types'] as List).cast<String>(),
    relatedSubjects: (m['relatedSubjects'] as List? ?? []).cast<String>(),
    notes: (m['notes'] as List? ?? []).cast<String>(),
    needsBuild: m['needsBuild'] == true,
    sourceHint: _str(m['sourceHint']),
    files: [
      for (final f in m['files'] as List) CorpusSourceFile.fromMap(f as Map),
    ],
  );
}

class CorpusInventory {
  const CorpusInventory({
    required this.documents,
    required this.totalChunks,
    required this.totalOutlineEntries,
    required this.warnings,
    required this.complete,
    required this.pendingDeletion,
  });
  final List<CorpusDocument> documents;
  final int totalChunks, totalOutlineEntries;
  final List<String> warnings;
  final bool complete, pendingDeletion;
  Map<String, Object?> toMap() => {
    'documents': [for (final d in documents) d.toMap()],
    'totalChunks': totalChunks,
    'totalOutlineEntries': totalOutlineEntries,
    'warnings': warnings,
    'complete': complete,
    'pendingDeletion': pendingDeletion,
  };
  factory CorpusInventory.fromMap(Map m) => CorpusInventory(
    documents: [
      for (final d in m['documents'] as List) CorpusDocument.fromMap(d as Map),
    ],
    totalChunks: _int(m['totalChunks']),
    totalOutlineEntries: _int(m['totalOutlineEntries']),
    warnings: (m['warnings'] as List).cast<String>(),
    complete: m['complete'] == true,
    pendingDeletion: m['pendingDeletion'] == true,
  );
}

class _Draft {
  _Draft(this.parts, this.subject, this.title);
  final List<String> parts;
  final String subject;
  String title, origin = 'unregistered', sourceHint = '';
  final types = <String>{},
      related = <String>{},
      notes = <String>[],
      paths = <String>{};
  final registered = <String, Object?>{};
  int chunks = 0, outline = 0;
  bool needsBuild = false;
  String get id => _id(parts);
}

class CorpusLibrary {
  CorpusLibrary(
    this.directory, {
    this.afterDeleteCommit,
    this.afterDeletePrepared,
  });
  final String directory;

  /// 仅测试崩溃恢复用；生产 worker 不传回调。
  final void Function()? afterDeleteCommit;
  final void Function()? afterDeletePrepared;
  File get _dbFile => File('$directory/corpus.db');
  File get _journal => File('$directory/$corpusDeleteJournalName');
  bool get hasPendingDelete => _journal.existsSync();
  bool _table(Database db, String table) => db.select(
    'SELECT 1 FROM sqlite_master WHERE type IN (\'table\',\'view\') AND name=?',
    [table],
  ).isNotEmpty;
  String _stamp() =>
      '${_fileStamp(_dbFile)}|${_fileStamp(File('${_dbFile.path}-wal'))}';
  String _fileStamp(File file) {
    if (!file.existsSync()) return 'absent';
    final s = file.statSync();
    return '${s.size}:${s.modified.microsecondsSinceEpoch}';
  }

  /// 所有可操作原件严格限制在 incoming 内；拒绝遍历、ADS、符号链接和目录链接。
  File sourceFile(String relative) {
    final rel = relative.replaceAll('\\', '/');
    if (rel.isEmpty ||
        rel.startsWith('/') ||
        rel
            .split('/')
            .any(
              (p) =>
                  p.isEmpty ||
                  p == '.' ||
                  p == '..' ||
                  p.contains(':') ||
                  p.contains('\u0000'),
            )) {
      throw const FormatException('非法原件路径');
    }
    final base = Directory('$directory/incoming').absolute;
    var prefix = base.path;
    if (FileSystemEntity.typeSync(prefix, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('原件目录不能是链接');
    }
    for (final segment in rel.split('/')) {
      prefix = '$prefix/$segment';
      if (FileSystemEntity.typeSync(prefix, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('不能操作链接原件');
      }
    }
    final f = File.fromUri(base.uri.resolve(Uri(path: rel).toString()));
    if (f.existsSync()) {
      final canonical = f.resolveSymbolicLinksSync().replaceAll('\\', '/');
      final root = base.resolveSymbolicLinksSync().replaceAll('\\', '/');
      final prefix = Platform.isWindows ? root.toLowerCase() : root;
      final target = Platform.isWindows ? canonical.toLowerCase() : canonical;
      if (!target.startsWith('$prefix/')) {
        throw const FormatException('原件越出语料目录');
      }
    }
    return f;
  }

  String? _relative(String raw) {
    if (raw.isEmpty) return null;
    var p = raw.replaceAll('\\', '/');
    final base = Directory(
      '$directory/incoming',
    ).absolute.path.replaceAll('\\', '/');
    final lower = Platform.isWindows ? p.toLowerCase() : p;
    final parent = Platform.isWindows ? base.toLowerCase() : base;
    if (lower.startsWith('$parent/')) {
      p = p.substring(base.length + 1);
    } else if (p.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(p)) {
      return null;
    }
    if (p.startsWith('incoming/')) p = p.substring(9);
    if (p.isEmpty ||
        p
            .split('/')
            .any(
              (s) => s.isEmpty || s == '.' || s == '..' || s.contains(':'),
            )) {
      return null;
    }
    return Platform.isWindows ? p.toLowerCase() : p;
  }

  String _pathKey(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;
  (String, String) _treeType(String relative) {
    final folder = relative.split('/').first;
    for (final type in ['textbook', 'exam', 'outline']) {
      if (folder.endsWith('-$type')) {
        return (folder.substring(0, folder.length - type.length - 1), type);
      }
    }
    return (relative.contains('/') ? folder : '', 'ppt');
  }

  Map<String, dynamic> _manifest() {
    final f = File('$directory/extract_manifest.json');
    if (!f.existsSync()) return {'files': <String, dynamic>{}};
    final m = jsonDecode(f.readAsStringSync());
    if (m is! Map<String, dynamic> || m['files'] is! Map) {
      throw const FormatException('建库登记文件格式异常');
    }
    return m;
  }

  CorpusInventory inventory() {
    final docs = <String, _Draft>{};
    final warnings = <String>[];
    final fileMap = <String, CorpusSourceFile>{};
    final manifestFiles = <String, Map>{};
    var complete = true;
    var totalChunks = 0;
    var totalOutline = 0;
    _Draft deck(String subject, String ppt, String title) {
      final parts = ['deck', subject, ppt];
      return docs.putIfAbsent(
        _id(parts),
        () => _Draft(parts, subject, title.isEmpty ? ppt : title),
      );
    }

    _Draft outline(String level) => docs.putIfAbsent(
      _id(['outline', level]),
      () => _Draft(
        ['outline', level],
        '@outline',
        level == 'zhuli'
            ? '助理考试大纲'
            : level == 'zhiye'
            ? '执业考试大纲'
            : '考试大纲（$level）',
      )..types.add('outline'),
    );
    if (_dbFile.existsSync()) {
      Database? db;
      try {
        db = sqlite3.open(_dbFile.path, mode: OpenMode.readOnly);
        db.execute('BEGIN');
        if (_table(db, 'chunks')) {
          for (final row in db.select(
            "SELECT COALESCE(subject_id,'') subject,COALESCE(ppt_id,'') ppt,source_type,MAX(deck) title,COUNT(*) n FROM chunks GROUP BY subject_id,ppt_id,source_type",
          )) {
            final d = deck(
              _str(row['subject']),
              _str(row['ppt']),
              _str(row['title']),
            );
            final n = _int(row['n']);
            d.chunks += n;
            totalChunks += n;
            d.types.add(
              _str(row['source_type']).isEmpty
                  ? 'other'
                  : _str(row['source_type']),
            );
          }
        }
        if (_table(db, 'deck_state')) {
          for (final row in db.select('SELECT * FROM deck_state')) {
            final d = deck(
              _str(row['subject_id']),
              _str(row['ppt_id']),
              _str(row['ppt_id']),
            );
            d.origin = _str(row['source']);
            d.sourceHint = _str(row['file_path']);
            d.registered.addAll({
              'md5': row['file_md5'],
              'updated': row['updated_at'],
              'declaredChunks': row['chunk_count'],
            });
            // 语料包的源路径来自另一台设备，不映射为本机待删除原件。
            final rel = d.origin == 'package' ? null : _relative(d.sourceHint);
            if (rel != null) d.paths.add(rel);
          }
        }
        if (_table(db, 'outline_entries')) {
          for (final row in db.select(
            'SELECT level,subject,COUNT(*) n FROM outline_entries GROUP BY level,subject',
          )) {
            final d = outline(_str(row['level']));
            d.outline += _int(row['n']);
            totalOutline += _int(row['n']);
            d.related.add(_str(row['subject']));
          }
        }
        if (_table(db, 'meta')) {
          for (final row in db.select(
            "SELECT key,value FROM meta WHERE key LIKE 'outline_md5_%'",
          )) {
            final key = _str(row['key']);
            for (final level in ['zhiye', 'zhuli']) {
              final prefix = 'outline_md5_${level}_';
              if (key.startsWith(prefix)) {
                outline(level).registered[key] = row['value'];
              }
            }
          }
        }
        if (_table(db, 'vectors') && _table(db, 'chunks')) {
          final n = _int(
            db
                .select(
                  'SELECT COUNT(*) n FROM vectors v WHERE NOT EXISTS (SELECT 1 FROM chunks c WHERE c.chunk_id=v.chunk_id)',
                )
                .first['n'],
          );
          if (n > 0) warnings.add('检测到 $n 条孤立向量（无对应正文），请通过建库工具重建向量');
        }
        db.execute('COMMIT');
      } catch (e) {
        complete = false;
        warnings.add('数据库清单读取不完整：$e');
      } finally {
        db?.dispose();
      }
    }
    try {
      final files = _manifest()['files'] as Map;
      for (final entry in files.entries) {
        if (entry.value is! Map) throw const FormatException('存在无法识别的建库登记项');
        final m = entry.value as Map;
        final d = deck(
          _str(m['subject']),
          _str(m['ppt_id']),
          _str(m['ppt_id']),
        );
        final rel = _relative(_str(entry.key));
        if (rel != null && d.origin != 'package') {
          d.paths.add(rel);
          manifestFiles[rel] = m;
          d.types.add(_treeType(rel).$2);
        } else if (d.origin == 'package') {
          if (d.sourceHint.isEmpty) d.sourceHint = _str(entry.key);
        } else {
          d.notes.add('登记中的原件不在本机 incoming 目录');
        }
      }
    } catch (e) {
      complete = false;
      warnings.add('登记清单读取不完整：$e');
    }
    final incoming = Directory('$directory/incoming');
    void walk(Directory dir, String prefix) {
      try {
        for (final entity in dir.listSync(followLinks: false)) {
          final name = entity.path.replaceAll('\\', '/').split('/').last;
          final rel = prefix.isEmpty ? name : '$prefix/$name';
          if (entity is Directory) {
            walk(entity, rel);
            continue;
          }
          final isLink = entity is Link;
          var bytes = 0, modified = 0;
          try {
            if (!isLink) {
              final s = entity.statSync();
              bytes = s.size;
              modified = s.modified.millisecondsSinceEpoch;
            }
          } catch (e) {
            complete = false;
            warnings.add('无法读取原件属性 $rel：$e');
          }
          final supported =
              [
                '.pptx',
                '.pdf',
                '.docx',
              ].any((ext) => rel.toLowerCase().endsWith(ext)) &&
              (_treeType(rel).$2 != 'outline' ||
                  rel.toLowerCase().endsWith('.docx'));
          fileMap[_pathKey(rel)] = CorpusSourceFile(
            relativePath: rel,
            exists: true,
            bytes: bytes,
            modifiedMs: modified,
            isLink: isLink,
            supported: supported,
          );
          if (isLink) {
            complete = false;
            warnings.add('链接原件未跟随：$rel');
          }
          final type = _treeType(rel);
          if (type.$2 == 'outline' &&
              rel.toLowerCase().endsWith('.docx') &&
              !isLink) {
            final d = outline(outlineLevelOfFilename(rel));
            d.paths.add(_pathKey(rel));
            if (d.outline == 0) d.needsBuild = true;
          }
        }
      } catch (e) {
        complete = false;
        warnings.add('原件目录读取不完整 $prefix：$e');
      }
    }

    if (FileSystemEntity.typeSync(incoming.path, followLinks: false) ==
        FileSystemEntityType.link) {
      complete = false;
      warnings.add('incoming 是链接目录，未跟随，请恢复为真实目录');
    } else if (incoming.existsSync()) {
      walk(incoming, '');
    }
    final linked = {for (final d in docs.values) ...d.paths};
    for (final f in fileMap.values) {
      if (linked.contains(_pathKey(f.relativePath))) continue;
      final type = _treeType(f.relativePath);
      final d =
          _Draft(
              ['file', f.relativePath],
              type.$1,
              f.relativePath.split('/').last,
            )
            ..types.add(f.supported ? type.$2 : 'other')
            ..paths.add(_pathKey(f.relativePath))
            ..needsBuild = f.supported;
      docs[d.id] = d;
    }
    String stamp;
    try {
      stamp = _stamp();
    } catch (e) {
      stamp = 'unavailable';
      complete = false;
      warnings.add('无法核验语料库文件状态：$e');
    }
    final result = <CorpusDocument>[];
    for (final d in docs.values) {
      if (d.types.isEmpty) d.types.add('other');
      final paths = d.paths.toList()..sort();
      final files = <CorpusSourceFile>[];
      for (final rel in paths) {
        final file =
            fileMap[rel] ?? CorpusSourceFile(relativePath: rel, exists: false);
        files.add(file);
        final m = manifestFiles[rel];
        if (file.exists &&
            file.supported &&
            !file.isLink &&
            d.parts.first != 'outline') {
          if (m == null ||
              _int(m['size']) != file.bytes ||
              _int(m['mtime']) != file.modifiedMs ~/ 1000 ||
              d.chunks == 0) {
            d.needsBuild = true;
          }
        }
      }
      if (d.registered.containsKey('declaredChunks') &&
          _int(d.registered['declaredChunks']) != d.chunks) {
        d.notes.add('来源登记与实际正文数量不一致，以当前正文清单为准');
      }
      if (d.origin == 'unregistered' && d.chunks > 0) {
        d.notes.add('旧语料缺少来源登记，正文仍完整显示');
      }
      if (d.parts.first == 'outline' && files.length > 1) {
        d.notes.add('旧大纲按考试级别整体入库，无法逐文件归属；删除将作用于整个级别集合');
      }
      final types = d.types.toList()..sort();
      final related = d.related.toList()..sort();
      final revision = sha256
          .convert(
            utf8.encode(
              jsonEncode([
                stamp,
                d.parts,
                d.title,
                d.origin,
                d.sourceHint,
                d.chunks,
                d.outline,
                d.registered,
                files.map((f) => f.toMap()).toList(),
              ]),
            ),
          )
          .toString();
      result.add(
        CorpusDocument(
          id: d.id,
          kind: d.parts.first,
          subjectId: d.subject,
          title: d.title,
          types: types,
          chunks: d.chunks,
          outlineEntries: d.outline,
          origin: d.origin,
          files: files,
          revision: revision,
          relatedSubjects: related,
          notes: d.notes,
          needsBuild: d.needsBuild,
          sourceHint: d.sourceHint,
        ),
      );
    }
    result.sort((a, b) => a.title.compareTo(b.title));
    return CorpusInventory(
      documents: result,
      totalChunks: totalChunks,
      totalOutlineEntries: totalOutline,
      warnings: warnings,
      complete: complete,
      pendingDeletion: hasPendingDelete,
    );
  }

  Map<String, Object?> content(
    String id, {
    int offset = 0,
    int limit = 40,
    String query = '',
  }) {
    if (offset < 0 || limit < 1 || limit > 500) {
      throw const FormatException('分页参数无效');
    }
    final parts = _parts(id);
    if (parts.isEmpty) throw const FormatException('无效资料编号');
    if (parts.first == 'file' || !_dbFile.existsSync()) {
      return {'total': 0, 'items': <Object>[]};
    }
    final db = sqlite3.open(_dbFile.path, mode: OpenMode.readOnly);
    try {
      db.execute('BEGIN');
      String table, where, text;
      List<Object?> args;
      if (parts.first == 'deck' && parts.length == 3) {
        table = 'chunks';
        where = "COALESCE(subject_id,'')=? AND COALESCE(ppt_id,'')=?";
        text = "COALESCE(title,'') || ' ' || text";
        args = [parts[1], parts[2]];
      } else if (parts.first == 'outline' && parts.length == 2) {
        table = 'outline_entries';
        where = "COALESCE(level,'')=?";
        text = "path || ' ' || point || ' ' || subject_name";
        args = [parts[1]];
      } else {
        throw const FormatException('无效资料编号');
      }
      if (!_table(db, table)) return {'total': 0, 'items': <Object>[]};
      if (query.trim().isNotEmpty) {
        where += ' AND instr(lower($text),lower(?))>0';
        args.add(query.trim());
      }
      final total = _int(
        db
            .select('SELECT COUNT(*) n FROM $table WHERE $where', args)
            .first['n'],
      );
      final rows = db.select(
        'SELECT * FROM $table WHERE $where ORDER BY ${table == 'chunks' ? 'page_start,page_end,chunk_id' : 'seq,id'} LIMIT ? OFFSET ?',
        [...args, limit, offset],
      );
      final items = <Map<String, Object?>>[
        for (final r in rows)
          table == 'chunks'
              ? {
                  'id': r['chunk_id'],
                  'title': r['title'],
                  'text': r['text'],
                  'pageStart': r['page_start'],
                  'pageEnd': r['page_end'],
                  'type': r['source_type'],
                }
              : {
                  'id': r['id'],
                  'title': r['path'],
                  'text': r['point'],
                  'subject': r['subject_name'],
                  'pageStart': null,
                  'pageEnd': null,
                  'type': 'outline',
                },
      ];
      db.execute('COMMIT');
      return {'total': total, 'items': items};
    } finally {
      db.dispose();
    }
  }

  // ---------------- 安全删除与中断恢复 ----------------
  String _digest(File f) {
    final result = _DigestSink();
    final hash = sha256.startChunkedConversion(result);
    final file = f.openSync();
    final buffer = Uint8List(65536);
    try {
      int n;
      while ((n = file.readIntoSync(buffer)) > 0) {
        hash.add(buffer.sublist(0, n));
      }
    } finally {
      file.closeSync();
      hash.close();
    }
    return result.value!.toString();
  }

  File _internal(String name) {
    if (!RegExp(
      r'^(extract_manifest\.json|chunks\.jsonl|\.library-delete-[0-9]+\.(manifest|chunks))$',
    ).hasMatch(name)) {
      throw const FormatException('非法清理文件名');
    }
    final file = File('$directory/$name');
    if (FileSystemEntity.typeSync(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('不能替换链接缓存');
    }
    return file;
  }

  void _writeJournal(Map<String, Object?> journal) {
    final tmp = File('$directory/.library-delete.json.tmp');
    if (FileSystemEntity.typeSync(tmp.path, followLinks: false) ==
            FileSystemEntityType.link ||
        FileSystemEntity.typeSync(_journal.path, followLinks: false) ==
            FileSystemEntityType.link) {
      throw const FormatException('清理日志不能是链接');
    }
    tmp.writeAsStringSync(jsonEncode(journal), flush: true);
    tmp.renameSync(_journal.path);
  }

  Future<Map<String, Object?>> deleteDocument(
    String id,
    String expectedRevision,
  ) async {
    if (hasPendingDelete) throw StateError('上次删除尚未清理完成，请先重试清理');
    final inventoryNow = inventory();
    if (!inventoryNow.complete) throw StateError('资料清单不完整，已停止删除，请先处理诊断提示');
    final matches = inventoryNow.documents.where((d) => d.id == id).toList();
    if (matches.isEmpty) throw StateError('资料已不存在，请刷新');
    final doc = matches.single;
    if (doc.revision != expectedRevision) throw StateError('资料已变化，请刷新并重新确认删除');
    final parts = _parts(id);
    for (final file in doc.files) {
      if (file.isLink) throw StateError('不能删除链接原件');
      if (inventoryNow.documents.any(
        (other) =>
            other.id != id &&
            other.files.any((f) => f.relativePath == file.relativePath),
      )) {
        throw StateError('原件关联多份资料，需先修复来源登记，避免误删');
      }
    }
    Directory(directory).createSync(recursive: true);
    final operation = DateTime.now().microsecondsSinceEpoch.toString();
    final prepared = <File>[];
    try {
      final sourceOps = <Map<String, Object?>>[];
      for (final source in doc.files.where((s) => s.exists)) {
        final f = sourceFile(source.relativePath);
        sourceOps.add({'path': source.relativePath, 'sha256': _digest(f)});
      }
      final paths = doc.files.map((f) => _pathKey(f.relativePath)).toSet();
      bool removeRow(Map m) =>
          parts.first == 'deck' &&
          _str(m['subject_id'] ?? m['subject']) == parts[1] &&
          _str(m['ppt_id']) == parts[2];
      final replacements = <Map<String, Object?>>[];
      void prepare(String target, String suffix, String body) {
        final original = _internal(target);
        if (!original.existsSync()) return;
        final name = '.library-delete-$operation.$suffix';
        final temp = _internal(name);
        prepared.add(temp);
        temp.writeAsStringSync(body, flush: true);
        replacements.add({
          'target': target,
          'staged': name,
          'before': _digest(original),
          'after': _digest(temp),
        });
      }

      final manifestFile = _internal('extract_manifest.json');
      if (manifestFile.existsSync()) {
        final m = _manifest();
        final entries = Map<String, dynamic>.from(m['files'] as Map);
        entries.removeWhere(
          (key, value) =>
              paths.contains(_relative(key)) ||
              (value is Map && removeRow(value)),
        );
        m['files'] = entries;
        prepare('extract_manifest.json', 'manifest', jsonEncode(m));
      }
      final cached = _internal('chunks.jsonl');
      if (cached.existsSync()) {
        final name = '.library-delete-$operation.chunks';
        final temp = _internal(name);
        prepared.add(temp);
        final out = temp.openWrite();
        try {
          await for (final line
              in cached
                  .openRead()
                  .transform(utf8.decoder)
                  .transform(const LineSplitter())) {
            if (line.trim().isEmpty) continue;
            final row = jsonDecode(line);
            if (row is! Map) throw const FormatException('分块缓存格式异常，未执行删除');
            if (!removeRow(row)) out.writeln(line);
          }
          await out.flush();
        } finally {
          await out.close();
        }
        replacements.add({
          'target': 'chunks.jsonl',
          'staged': name,
          'before': _digest(cached),
          'after': _digest(temp),
        });
      }
      final journal = <String, Object?>{
        'version': 1,
        'operation': operation,
        'sources': sourceOps,
        'replacements': replacements,
      };
      final db = sqlite3.open(_dbFile.path);
      try {
        db.execute('PRAGMA busy_timeout=3000');
        ensureCorpusSchema(db);
        db.execute(
          'CREATE TABLE IF NOT EXISTS library_delete_commits (operation TEXT PRIMARY KEY)',
        );
        // 日志出现时数据库必须已经存在；否则新库准备阶段中断会无从判定是否提交。
        _writeJournal(journal);
        afterDeletePrepared?.call();
        db.execute('BEGIN IMMEDIATE');
        try {
          if (parts.first == 'deck') {
            final ids = [
              for (final r in db.select(
                "SELECT chunk_id FROM chunks WHERE COALESCE(subject_id,'')=? AND COALESCE(ppt_id,'')=?",
                [parts[1], parts[2]],
              ))
                _str(r['chunk_id']),
            ];
            for (var i = 0; i < ids.length; i += 300) {
              final batch = ids.skip(i).take(300).toList();
              final qm = List.filled(batch.length, '?').join(',');
              // 子表先删，兼容启用外键的库；float32 镜像与词面索引也必须清理。
              for (final table in [
                'vectors',
                'vec_chunks',
                'chunk_state',
                'chunks_fts',
                'chunks',
              ]) {
                if (_table(db, table)) {
                  db.execute(
                    'DELETE FROM $table WHERE chunk_id IN ($qm)',
                    batch,
                  );
                }
              }
            }
            db.execute(
              "DELETE FROM deck_state WHERE COALESCE(subject_id,'')=? AND COALESCE(ppt_id,'')=?",
              [parts[1], parts[2]],
            );
          } else if (parts.first == 'outline') {
            db.execute(
              "DELETE FROM outline_entries WHERE COALESCE(level,'')=?",
              [parts[1]],
            );
            final prefix = 'outline_md5_${parts[1]}_';
            db.execute('DELETE FROM meta WHERE substr(key,1,?)=?', [
              prefix.length,
              prefix,
            ]);
          }
          db.execute('INSERT INTO library_delete_commits VALUES (?)', [
            operation,
          ]);
          db.execute('COMMIT');
        } catch (_) {
          db.execute('ROLLBACK');
          rethrow;
        }
      } finally {
        db.dispose();
      }
      afterDeleteCommit?.call();
      recoverPendingDelete();
      return {
        'ok': true,
        'removedChunks': doc.chunks,
        'removedOutlineEntries': doc.outlineEntries,
      };
    } finally {
      // 日志尚未建立或操作已完成时，准备文件不应永久占用手机存储。
      if (!hasPendingDelete) {
        for (final file in prepared) {
          try {
            final name = file.path.replaceAll('\\', '/').split('/').last;
            final safe = _internal(name);
            if (safe.existsSync()) safe.deleteSync();
          } catch (_) {} // 清理失败不覆盖原始业务错误；不触碰原件和正文。
        }
      }
    }
  }

  void recoverPendingDelete() {
    if (!hasPendingDelete) return;
    if (FileSystemEntity.typeSync(_journal.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('删除日志不能是链接');
    }
    final raw = jsonDecode(_journal.readAsStringSync());
    if (raw is! Map ||
        raw['version'] != 1 ||
        !RegExp(r'^[0-9]+$').hasMatch(_str(raw['operation']))) {
      throw const FormatException('删除日志格式无效，已停止清理');
    }
    final operation = _str(raw['operation']);
    final replacements = (raw['replacements'] as List).cast<Map>();
    final sources = (raw['sources'] as List).cast<Map>();
    if (!_dbFile.existsSync()) throw StateError('删除日志存在但语料库缺失，已停止清理');
    final db = sqlite3.open(_dbFile.path);
    try {
      final committed =
          _table(db, 'library_delete_commits') &&
          db.select('SELECT 1 FROM library_delete_commits WHERE operation=?', [
            operation,
          ]).isNotEmpty;
      if (committed) {
        for (final op in sources) {
          final file = sourceFile(_str(op['path']));
          if (!file.existsSync()) continue;
          if (_digest(file) != op['sha256']) {
            throw StateError('待清理原件已被替换，已保留新文件：${op['path']}');
          }
          file.deleteSync();
        }
        for (final op in replacements) {
          final dest = _internal(_str(op['target']));
          final temp = _internal(_str(op['staged']));
          if (!temp.path.endsWith('.library-delete-$operation.manifest') &&
              !temp.path.endsWith('.library-delete-$operation.chunks')) {
            throw const FormatException('删除缓存与操作编号不一致');
          }
          if (dest.existsSync() && _digest(dest) == op['after']) {
            if (temp.existsSync()) temp.deleteSync();
            continue;
          }
          if (!temp.existsSync() || _digest(temp) != op['after']) {
            throw StateError('清理暂存文件缺失或损坏');
          }
          if (dest.existsSync() && _digest(dest) != op['before']) {
            throw StateError('清理期间缓存发生变化，已停止覆盖');
          }
          temp.renameSync(dest.path);
        }
        db.execute('DELETE FROM library_delete_commits WHERE operation=?', [
          operation,
        ]);
      } else {
        // 未提交：正文和原件均尚未变更，仅丢弃准备文件。
        for (final op in replacements) {
          final temp = _internal(_str(op['staged']));
          if (!temp.path.endsWith('.library-delete-$operation.manifest') &&
              !temp.path.endsWith('.library-delete-$operation.chunks')) {
            throw const FormatException('非法暂存文件');
          }
          if (temp.existsSync()) temp.deleteSync();
        }
      }
      _journal.deleteSync();
    } finally {
      db.dispose();
    }
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
