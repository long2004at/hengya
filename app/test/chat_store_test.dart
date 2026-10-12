// 聊天会话持久化测试（Db chat_sessions/chat_messages 读写硬门）。
//
// 【宿主纪律】Windows 宿主显式加载 test/sqlite3.dll（勿动）；临时目录建库，
// Db.openSync 覆盖建会话 → 插消息 → 查询 → 删除级联全链路。
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:hengya/services/local/db.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart' as sqlite_open;

void main() {
  // Windows 测试宿主：显式加载 test/sqlite3.dll（CWD = 包根 app/）
  if (Platform.isWindows) {
    final dll = File('test/sqlite3.dll').absolute.path;
    sqlite_open.open.overrideForAll(() => ffi.DynamicLibrary.open(dll));
  }

  late Directory tmp;
  late Db db;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hengya_chat_store_test_');
    db = Db.openSync('${tmp.path}${Platform.pathSeparator}hengya.db');
  });

  tearDown(() {
    db.close();
    tmp.deleteSync(recursive: true);
  });

  test('chatSessionCreate：返回 32 位随机 id，标题可空默认', () {
    final id1 = db.chatSessionCreate(title: '龋病学提问');
    final id2 = db.chatSessionCreate();
    expect(id1, isNot(id2));
    expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(id1), true, reason: 'uuid 形态');
    final sessions = db.chatSessions();
    expect(sessions.length, 2);
  });

  test('建会话 → 插 3 条消息 → 查询顺序与字段正确', () {
    final sid = db.chatSessionCreate(title: '会话 A');
    db.chatMessageAppend(sid,
        role: 'user', content: '什么是龋病？');
    db.chatMessageAppend(sid,
        role: 'assistant',
        content: '龋病是……',
        refs: '[{"chunkId":"c1"}]',
        tokens: 123,
        channel: 'proxy');

    final msgs = db.chatMessages(sid);
    expect(msgs.length, 2);
    // 顺序：按 id ASC（写入序）
    expect(msgs[0].role, 'user');
    expect(msgs[0].content, '什么是龋病？');
    expect(msgs[0].refs, '[]', reason: '用户消息 refs 默认空数组');
    expect(msgs[0].tokens, 0);
    expect(msgs[0].channel, '', reason: '用户消息 channel 恒空');
    expect(msgs[1].role, 'assistant');
    expect(msgs[1].content, '龋病是……');
    expect(msgs[1].refs, '[{"chunkId":"c1"}]', reason: 'refs 保持原始 JSON 串');
    expect(msgs[1].tokens, 123);
    expect(msgs[1].channel, 'proxy');
    expect(msgs[1].createdAt, isNotEmpty);

    // refs 原始串可被上层 jsonDecode（解析留给上层）
    final refs = msgs[1].refs;
    expect(refs.startsWith('['), true);
  });

  test('chatMessageAppend touch 会话 updated_at；chatSessions 按 updated_at DESC',
      () async {
    final old = db.chatSessionCreate(title: '旧会话');
    db.chatMessageAppend(old, role: 'user', content: 'm1');
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final neu = db.chatSessionCreate(title: '新会话');
    expect(db.chatSessions().map((s) => s.id).toList(), [neu, old],
        reason: '刚活跃的会话排最前');
    final before = db.chatSessions().firstWhere((s) => s.id == old).updatedAt;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    db.chatMessageAppend(old, role: 'user', content: 'm2');
    final after = db.chatSessions().firstWhere((s) => s.id == old).updatedAt;
    expect(after == before, false, reason: '追加消息必须 touch updated_at');
  });

  test('chatSessionRename / chatSessionDelete：改名生效、删除级联清消息', () {
    final sid = db.chatSessionCreate(title: '原名');
    db.chatMessageAppend(sid, role: 'user', content: 'm1');
    db.chatMessageAppend(sid, role: 'assistant', content: 'm2');

    db.chatSessionRename(sid, '新名');
    expect(db.chatSessions().single.title, '新名');

    db.chatSessionDelete(sid);
    expect(db.chatSessions(), isEmpty);
    expect(db.chatMessages(sid), isEmpty,
        reason: 'ON DELETE CASCADE 连带清空消息');
  });

  test('隔离性：删除会话 A 不影响会话 B 的消息', () {
    final a = db.chatSessionCreate(title: 'A');
    final b = db.chatSessionCreate(title: 'B');
    db.chatMessageAppend(a, role: 'user', content: 'a1');
    db.chatMessageAppend(b, role: 'user', content: 'b1');
    db.chatSessionDelete(a);
    expect(db.chatMessages(b).single.content, 'b1');
  });
}
