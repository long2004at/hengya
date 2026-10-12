// 聊天页（P2.3，P3.1 扩展）：DeepSeek 双通道聊天的端上会话 UI。
// ============================================================================
// 布局：AppBar（AI 问答 + 历史会话入口）+ 消息气泡列表 + 底部输入框。
// 数据：会话/消息经 LocalBackend.sharedDb 的 Db 聊天方法（P2.2 已测）持久化；
// 流式回答经 chatOrchestrate（P3.1 编排层：反代优先、失败自动退回官方，配置
// 组装见 loadChatProxyConfig/loadChatOfficialConfig）。
//
// 状态机（发送流程）：用户消息立刻上屏并 chatMessageAppend(user) → 助手占位
// 气泡 + onDelta 增量追加（打字机）→ 结束 chatMessageAppend(assistant, tokens,
// channel: 编排层返回的真实通道 'proxy'|'official')。退回发生时 TopToast 提示。
// 失败（ChatTransportException）：占位气泡显示错误文案 + TopToast，不入库
// （错误消息不持久）。
//
// 纪律：StatefulWidget + setState（不引入状态管理库）；长会话 ListView.builder；
// 滚动跟随最新消息，但用户上翻查看历史时不强制拉底（简单位移判断）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/local/chat/chat_orchestrator.dart';
import '../services/local/chat/chat_transport.dart';
import '../services/local/local_backend.dart';
import '../widgets/top_toast.dart';
import 'about_page.dart';

/// 单条聊天消息的页面态（含未入库的占位/流式中间态）。
class _ChatItem {
  _ChatItem({
    required this.role,
    required this.content,
    this.tokens = 0,
    this.channel = '',
    this.sending = false,
  });

  final String role; // 'user' | 'assistant'
  String content;
  int tokens;
  String channel; // 通道标识（'' 不显示；'proxy'=反代 / 'official'=官方退回）
  bool sending; // true = 流式接收中（占位气泡）
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _inputCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_ChatItem> _items = [];
  String _sessionId = '';
  bool _busy = false; // 助手回答流式接收中（发送禁用）
  bool _configured = false; // 聊天服务配置就绪（baseUrl/key/model 三项齐）

  /// 用户是否仍在列表底部附近（滚动跟随开关：上翻看历史时不强制拉底）。
  bool _pinned = true;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(() {
      final nearBottom = _scrollCtrl.position.maxScrollExtent -
              _scrollCtrl.offset <
          80;
      if (_pinned != nearBottom) setState(() => _pinned = nearBottom);
    });
    _startNewSession();
    _checkConfigured();
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkConfigured() async {
    final cfg = await loadChatProxyConfig();
    if (!mounted) return;
    setState(() => _configured = cfg?.configured ?? false);
  }

  // P3.1：配置组装移入编排层（loadChatProxyConfig——P3.2 起含 preset 选择）。

  void _startNewSession() {
    setState(() {
      _sessionId = '';
      _items.clear();
    });
  }

  /// 加载历史会话（历史会话弹层点选）：清空当前列表后按 id 回放消息行。
  Future<void> _loadSession(String id) async {
    final db = await LocalBackend.instance.sharedDb;
    final rows = db.chatMessages(id);
    if (!mounted) return;
    setState(() {
      _sessionId = id;
      _items
        ..clear()
        ..addAll([
          for (final r in rows)
            _ChatItem(
              role: r.role,
              content: r.content,
              tokens: r.tokens,
              channel: r.channel,
            ),
        ]);
    });
    _jumpBottom();
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
    });
  }

  /// 发送流程（页面状态机见文件头）：首条用户消息同时建会话（标题取前
  /// 30 字符），助手占位气泡流式打字，结束落库；失败只提示不入库。
  /// P3.1：改走 chatOrchestrate 双通道编排——反代失败且零 delta 时自动退回
  /// 官方通道（落库 channel='official'），已吐 delta 后失败不退回直接报错。
  Future<void> _send() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty || _busy) return;
    final proxyCfg = await loadChatProxyConfig();
    final officialCfg = await loadChatOfficialConfig();
    if (!mounted) return;
    if ((proxyCfg == null || !proxyCfg.configured) &&
        (officialCfg == null || !officialCfg.configured)) {
      TopToast.show(context, '未配置聊天服务，请到设置页配置', type: TopToastType.error);
      return;
    }
    setState(() {
      _configured = true;
      _busy = true;
      _items.add(_ChatItem(role: 'user', content: text));
      _items.add(_ChatItem(role: 'assistant', content: '', sending: true));
      _inputCtrl.clear();
    });
    _jumpBottom();

    final db = await LocalBackend.instance.sharedDb;
    _sessionId = _sessionId.isEmpty ? db.chatSessionCreate(title: _sessionTitle(text)) : _sessionId;
    db.chatMessageAppend(_sessionId, role: 'user', content: text);

    // 历史上下文：只送 user/assistant 两条合法角色（错误占位不入库，天然不混入）
    final history = [
      for (final it in _items)
        if (!it.sending && (it.role == 'user' || it.role == 'assistant'))
          (role: it.role, content: it.content),
    ];

    final placeholder = _items.last;
    var prompt = 0, completion = 0;
    try {
      final r = await chatOrchestrate(
        proxyCfg,
        history,
        officialCfg: officialCfg,
        onDelta: (piece) {
          setState(() => placeholder.content += piece);
          if (_pinned) _jumpBottom();
        },
        onDone: (p, c) {
          prompt = p;
          completion = c;
        },
      );
      // 流结束但内容为空（理论上传输层已拦截空流）→ 不入库占位提示
      if (placeholder.content.isEmpty) {
        if (mounted) {
          setState(() {
            placeholder.sending = false;
            placeholder.content = '（服务返回内容为空）';
          });
        }
        return;
      }
      setState(() {
        placeholder.sending = false;
        placeholder.tokens = prompt + completion;
        placeholder.channel = r.channel; // 'proxy' | 'official'
      });
      db.chatMessageAppend(
        _sessionId,
        role: 'assistant',
        content: placeholder.content,
        tokens: prompt + completion,
        channel: r.channel,
      );
      if (r.fallbackUsed && mounted) {
        TopToast.show(context, '反代不可用，本次已走官方通道', type: TopToastType.info);
      }
    } on ChatTransportException catch (e) {
      // 失败不入库：占位气泡转错误文案（灰显），TopToast 同步提示
      setState(() {
        placeholder.sending = false;
        placeholder.content = '发送失败：${e.message}';
      });
      if (mounted) {
        TopToast.show(context, e.message, type: TopToastType.error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 会话标题：首条用户消息前 30 字符。
  String _sessionTitle(String first) =>
      first.length <= 30 ? first : first.substring(0, 30);

  // ---------------- 历史会话弹层 ----------------

  Future<void> _showSessions() async {
    final db = await LocalBackend.instance.sharedDb;
    final sessions = db.chatSessions();
    if (!mounted) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: sessions.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: Text('暂无历史会话', style: TextStyle(fontSize: 13))),
              )
            : ListView.builder(
                shrinkWrap: true,
                itemCount: sessions.length,
                itemBuilder: (_, i) {
                  final s = sessions[i];
                  final active = s.id == _sessionId;
                  return ListTile(
                    leading: Icon(
                      active ? Icons.chat_bubble : Icons.chat_bubble_outline,
                      size: 20,
                      color: active ? Theme.of(sheetCtx).colorScheme.primary : null,
                    ),
                    title: Text(
                      s.title.isEmpty ? '（无标题）' : s.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 14),
                    ),
                    subtitle: Text(
                      s.updatedAt,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: IconButton(
                      tooltip: '删除会话',
                      icon: const Icon(Icons.delete_outline, size: 20),
                      onPressed: () {
                        db.chatSessionDelete(s.id);
                        if (s.id == _sessionId) _startNewSession();
                        Navigator.of(sheetCtx).pop();
                        TopToast.show(context, '已删除会话');
                      },
                    ),
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _loadSession(s.id);
                    },
                  );
                },
              ),
      ),
    );
  }

  // ---------------- UI ----------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 问答'),
        actions: [
          IconButton(
            tooltip: '历史会话',
            icon: const Icon(Icons.history_rounded),
            onPressed: _showSessions,
          ),
          IconButton(
            tooltip: '新建会话',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: _busy ? null : _startNewSession,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _items.isEmpty
                ? Center(
                    child: Text(
                      '有问题尽管问，比如「龋齿的四联因素」',
                      style: TextStyle(fontSize: 13, color: scheme.outline),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    itemCount: _items.length,
                    itemBuilder: (_, i) => _bubble(_items[i], scheme),
                  ),
          ),
          if (!_configured) _configBanner(scheme),
          _inputBar(scheme),
        ],
      ),
    );
  }

  /// 配置未就绪提示条（点击跳设置页「AI 服务配置」区）。
  Widget _configBanner(ColorScheme scheme) {
    return Material(
      color: scheme.tertiaryContainer,
      child: InkWell(
        onTap: () => Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(builder: (_) => const AboutPage()),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.info_outline, size: 16, color: scheme.onTertiaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '未配置聊天服务，请到设置页配置',
                  style: TextStyle(fontSize: 12, color: scheme.onTertiaryContainer),
                ),
              ),
              Icon(Icons.chevron_right, size: 16, color: scheme.onTertiaryContainer),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inputBar(ColorScheme scheme) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _inputCtrl,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.newline,
                enabled: !_busy,
                style: const TextStyle(fontSize: 14),
                decoration: InputDecoration(
                  hintText: _busy ? '回答中…' : '输入问题',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(22),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor: scheme.surfaceContainerHigh,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: '发送',
              onPressed: _busy ? null : _send,
              icon: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_rounded, size: 20),
            ),
          ],
        ),
      ),
    );
  }

  /// 消息气泡：用户右/助手左；助手气泡可长按复制；底部小字标注通道。
  Widget _bubble(_ChatItem item, ColorScheme scheme) {
    final isUser = item.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: isUser ? scheme.primaryContainer : scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isUser ? 14 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 14),
          ),
        ),
        child: GestureDetector(
          onLongPress: isUser
              ? null
              : () => Clipboard.setData(
                  ClipboardData(text: item.content),
                ).then((_) {
                  if (!mounted) return;
                  TopToast.show(
                    context,
                    '已复制',
                    type: TopToastType.success,
                  );
                }),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                item.content.isEmpty && item.sending ? '…' : item.content,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: isUser ? scheme.onPrimaryContainer : scheme.onSurface,
                ),
              ),
              if (item.channel.isNotEmpty && !item.sending)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 通道小圆点：反代=品牌蓝 / 官方=青绿，视觉一眼区分
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: item.channel == 'proxy'
                              ? scheme.primary
                              : scheme.tertiary,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '通道：${item.channel == 'proxy' ? '反代' : '官方'}',
                        style: TextStyle(fontSize: 10, color: scheme.outline),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
