// 题库页 —— 自由查看全部科目卡片（M4，对齐设计稿 02/02b 屏）
// 列表：搜索框 + 科目筛选胶囊 + 卡片列表（题干 + 科目胶囊 + 标签 + 状态）
// 详情：题卡（标签/题干/答案/锚点）+ 三操作（编辑/备注/回炉）+ 我的备注区
//       （AI 留言入口已移除：对卡的改进意见统一走回炉原因闭环，次日拆卡 AI 读）
// 离线韧性（问1+5）：搜索/科目列表带缓存回退——断网时显示最近一次搜索结果
// + 「离线数据 · 更新于 HH:mm」提示条。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared/hengya_shared.dart';

import '../services/api/api_client.dart';
import '../services/api/local_cache.dart';
import '../theme.dart';
import '../widgets/offline_data_bar.dart';
import '../widgets/reason_action_dialog.dart';
import '../widgets/top_toast.dart';

class BankPage extends StatefulWidget {
  const BankPage({super.key});

  @override
  State<BankPage> createState() => _BankPageState();
}

class _BankPageState extends State<BankPage> {
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce; // 搜索防抖（真机问题 2：每击键一次请求）
  String? _subject; // null = 全部
  List<SubjectWithDue> _subjects = [];
  List<BankCard> _cards = [];
  int _total = 0;
  bool _loading = true;
  bool _bootstrapped = false; // 首次加载是否完成（未完成才全屏转圈）
  String? _error;
  int _seq = 0; // 乱序守卫：并发请求返回时序号不匹配 → 丢弃旧响应
  DateTime? _cacheAt; // 非 null = 列表/科目来自离线缓存回退

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// 搜索防抖：击键停 300ms 才发请求（省 120 req/min 限速额度 + 不闪整页转圈）
  void _onSearchChanged(String _) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), _load);
  }

  Future<void> _load() async {
    final seq = ++_seq; // 乱序守卫：本次请求的序号
    if (!_bootstrapped) {
      // 只有首次进入显示全屏 loading；增量刷新（搜索/筛选/回列）保留旧列表不转圈
      setState(() {
        _loading = true;
        _error = null;
      });
    } else if (_error != null) {
      setState(() => _error = null); // 增量重试：先恢复旧列表再刷新
    }
    try {
      // 科目列表只拉一次（首次），后续搜索/筛选不再重复 fetchSubjects（限速额度）
      final subjectsFuture = _subjects.isEmpty
          ? ApiClient.instance.fetchSubjects()
          : null;
      final searchFuture = ApiClient.instance.searchBankCards(
        subject: _subject,
        q: _searchCtrl.text.trim(),
      );
      final subjectList = await subjectsFuture;
      final r = await searchFuture;
      if (seq != _seq || !mounted) return; // 乱序守卫：旧响应直接丢弃
      setState(() {
        if (subjectList != null) _subjects = subjectList;
        _cards = r.cards;
        _total = r.total;
        _bootstrapped = true;
        _loading = false;
        _error = null;
        _cacheAt = ApiClient.instance.latestCacheHitAmong([
          CacheKeys.bankSearch,
          CacheKeys.subjects,
        ]);
      });
    } on ApiException catch (e) {
      if (seq != _seq || !mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题行（对齐设计稿：恒牙 · 题库）
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  const Text(
                    '题库',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: HengyaColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '共 $_total 张',
                    style: const TextStyle(
                      fontSize: 12,
                      color: HengyaColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            // 搜索框
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: _SearchBar(
                controller: _searchCtrl,
                onChanged: _onSearchChanged, // 防抖 300ms（真机问题 2）
              ),
            ),
            // 科目筛选胶囊行
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: SizedBox(
                height: 32,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _SubjectChip(
                      label: '全部 ${_total.toString()}',
                      selected: _subject == null,
                      onTap: () {
                        if (_subject != null) {
                          _subject = null;
                          _load();
                        }
                      },
                    ),
                    // 胶囊展示名：全部走全局科目名缓存（库名 → 原样 id）；
                    // 旧计数只统计当前页 ≤50 条，误导 → 去掉，只保留「全部」的总数
                    ..._subjects.map(
                      (s) => _SubjectChip(
                        label: ApiClient.instance.subjectNameOf(s.subject.id),
                        selected: _subject == s.subject.id,
                        onTap: () {
                          if (_subject != s.subject.id) {
                            _subject = s.subject.id;
                            _load();
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            // 离线缓存回退提示条（断网时显示最近一次搜索结果的时间戳）
            if (_cacheAt != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                child: OfflineDataBar(savedAt: _cacheAt),
              ),
            // 卡片列表
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? _ErrorState(message: _error!, onRetry: _load)
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: _cards.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: const [
                                SizedBox(height: 120),
                                Icon(
                                  Icons.search_off,
                                  size: 48,
                                  color: HengyaColors.divider,
                                ),
                                SizedBox(height: 12),
                                Center(
                                  child: Text(
                                    '没有匹配的卡片',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: HengyaColors.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : ListView.separated(
                              physics: const AlwaysScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                              itemCount: _cards.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 10),
                              itemBuilder: (context, i) => _BankCardTile(
                                item: _cards[i],
                                subjectName: _nameOf(_cards[i].card.subjectId),
                                onTap: () => _openDetail(_cards[i].card.id),
                              ),
                            ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 进详情（dataVersion 守卫，2026-09-06 真机问题整改：返回偶发卡顿延迟——
  /// 旧版 push 返回后无条件 `_load()` 全量重查重建列表）。
  /// push 前记录 data_version，返回后未变则跳过重查：详情页全部写路径
  /// （编辑 `/cards/<id>/edit`、备注 `/cards/<id>/notes`、回炉 `/cards/rework`）
  /// 在 local（local_backend）与 remote（server cards.dart）两侧都会 bump
  /// data_version，未变即证明详情无写操作，列表无刷新必要。
  /// 守卫只省查询、不承担正确性风险：版本取不到（断网等）一律降级为全量
  /// 刷新，与旧行为一致；对 demo / local / remote 三模式同语义
  /// （fetchDataVersion 三后端均应答 meta/version）。
  Future<void> _openDetail(String cardId) async {
    String? before;
    try {
      before = await ApiClient.instance.fetchDataVersion();
    } catch (_) {} // 取不到版本 → 返回后走 before == null 分支（全量刷新）
    if (!mounted) return;
    await context.push('/bank/$cardId');
    if (!mounted) return;
    if (before == null) {
      _load(); // 进详情前就拿不到版本：保守全量刷新
      return;
    }
    try {
      final after = await ApiClient.instance.fetchDataVersion();
      if (!mounted) return;
      if (after != before) _load(); // 版本递增（详情有写操作）→ 刷新
    } catch (_) {
      _load(); // 返回后版本查询失败 → 保守全量刷新
    }
  }

  String _nameOf(String subjectId) {
    for (final s in _subjects) {
      if (s.subject.id == subjectId) return s.subject.name;
    }
    // M5 动态科目：页面列表没有（新科目/离线）→ 走全局缓存（库名 → 原样 id）
    return ApiClient.instance.subjectNameOf(subjectId);
  }
}

/// 搜索框（设计稿 02：圆角 12、白底、放大镜）
///
/// 整改③（搜索框显示问题）修正四处显示缺陷：
/// ① 显隐滞后（实证）：旧版是 StatelessWidget，在 build 里读
///    controller.text 判断清除钮，而击键只走防抖 Timer、不触发 setState，
///    页面唯一重建时机是搜索请求返回后 → 打字中 × 完全不出现，要等
///    300ms 防抖 + 一轮网络往返才弹出来（被 120 req/min 限速拖住时全程
///    不可见）；点 × 清空后 × 又滞留到请求结束才消失。现改为 StatefulWidget
///    监听 controller，空 ↔ 非空翻转时立刻刷新。
/// ② 聚焦无反馈（实证）：旧版自绘 Container + InputBorder.none 绕开了
///    全局 inputDecorationTheme（theme.dart：divider 描边 + 聚焦品牌蓝
///    1.6px），全 App 唯独这里点击后边框纹丝不动。改用原生 InputDecoration
///    自动继承主题：12 圆角 + divider 描边，聚焦切品牌蓝。
/// ③ 大字号裁剪（实证边界）：旧版固定 height:40 是紧约束，系统
///    textScaleFactor 调大后 TextField 首选高度超过 40，内容被垂直裁剪。
///    现无固定高度：默认 ≈40（图标约束盒兜底），大字号随内容长高。
/// ④ 热区过小（实证）：旧版清除钮 GestureDetector 默认 deferToChild，
///    Padding 空白不参与命中，可点区域仅图标本体 16×16 像素。
///    现改为 opaque + padding 撑满 38×40 热区。
class _SearchBar extends StatefulWidget {
  const _SearchBar({required this.controller, required this.onChanged});

  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = widget.controller.text.isNotEmpty;
    widget.controller.addListener(_syncHasText);
  }

  @override
  void didUpdateWidget(_SearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncHasText);
      widget.controller.addListener(_syncHasText);
      _syncHasText();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncHasText);
    super.dispose();
  }

  /// 仅在「空 ↔ 非空」翻转时 setState，逐字符输入不整框重建。
  void _syncHasText() {
    final hasText = widget.controller.text.isNotEmpty;
    if (hasText != _hasText) setState(() => _hasText = hasText);
  }

  void _clear() {
    widget.controller.clear(); // 触发 _syncHasText → × 立刻消失
    widget.onChanged(''); // 通知父级：走防抖刷新列表
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      onChanged: widget.onChanged,
      textInputAction: TextInputAction.search,
      style: const TextStyle(fontSize: 13, color: HengyaColors.textPrimary),
      decoration: InputDecoration(
        hintText: '搜题干、答案、标签',
        hintStyle: const TextStyle(
          fontSize: 13,
          color: HengyaColors.textSecondary,
        ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 10),
        prefixIcon: const Icon(
          Icons.search,
          size: 18,
          color: HengyaColors.textSecondary,
        ),
        // 38 = 旧版「12 空隙 + 18 图标 + 8 空隙」→ 文字起点与旧版完全一致
        prefixIconConstraints: const BoxConstraints(
          minWidth: 38,
          minHeight: 40,
        ),
        suffixIcon: _hasText
            ? GestureDetector(
                onTap: _clear,
                behavior: HitTestBehavior.opaque, // 整块 38×40 都可点
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(10, 12, 12, 12),
                  child: Icon(
                    Icons.close,
                    size: 16,
                    color: HengyaColors.textSecondary,
                  ),
                ),
              )
            : null,
        suffixIconConstraints: const BoxConstraints(
          minWidth: 38,
          minHeight: 40,
        ),
      ),
    );
  }
}

/// 科目筛选胶囊
class _SubjectChip extends StatelessWidget {
  const _SubjectChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? HengyaColors.brand : Colors.white,
          borderRadius: BorderRadius.circular(999),
          border: selected ? null : Border.all(color: HengyaColors.divider),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : HengyaColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// 题库卡（设计稿 02：白卡 16 圆角，题干 + 科目胶囊 + 标签 + 状态徽标）
class _BankCardTile extends StatelessWidget {
  const _BankCardTile({
    required this.item,
    required this.subjectName,
    required this.onTap,
  });

  final BankCard item;
  final String subjectName;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = item.card;
    final status = _statusBadge(item);
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  // 修正（真机问题 3）：长题干未约束 → RenderFlex 溢出、徽标被挤出屏
                  Flexible(
                    child: Text(
                      c.front,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: HengyaColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: status.$2.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      status.$1,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: status.$2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDF2FF),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      subjectName.characters.take(2).toString(),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: HengyaColors.brand,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  if (c.tags.isNotEmpty)
                    Expanded(
                      child: Text(
                        c.tags.take(3).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: HengyaColors.textSecondary,
                        ),
                      ),
                    ),
                  if (item.userNote.isNotEmpty) ...[
                    const Spacer(),
                    const Icon(
                      Icons.sticky_note_2_outlined,
                      size: 13,
                      color: Color(0xFFE37318),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 状态徽标：重造中（琥珀，#10①）/ 今天到期（蓝）/ 弱卡（红）/
  /// 已掌握（绿）/ X天后到期（灰）
  (String, Color) _statusBadge(BankCard item) {
    // #10①：回炉入队后卡片必须有可见的「重造中」状态（旧版与普通卡
    // 一样落到调度徽标「未开始」，用户无从知道已在重造）
    if (item.card.status == CardStatus.rework) {
      return ('重造中', const Color(0xFFE37318));
    }
    final due = item.dueAt;
    if (item.lapses >= 4) return ('弱卡', const Color(0xFFD54941));
    if (due == null) return ('未开始', HengyaColors.textSecondary);
    final days = due.difference(DateTime.now()).inDays;
    if (days <= 0) return ('今天到期', HengyaColors.brand);
    if (item.reps >= 8) return ('已掌握', const Color(0xFF2BA471));
    return ('$days 天后到期', HengyaColors.textSecondary);
  }
}

/// 错误态：直接显示真实 message（网络错误原文 / 404 文案），
/// 不再硬编码「连不上服务器」掩盖真实错误（真机问题 1）
class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.wifi_off_outlined,
              size: 48,
              color: HengyaColors.divider,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                color: HengyaColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

// ---------------- 02b 详情页（编辑/备注/AI留言/回炉） ----------------

class BankDetailPage extends StatefulWidget {
  const BankDetailPage({super.key, required this.cardId});

  final String cardId;

  @override
  State<BankDetailPage> createState() => _BankDetailPageState();
}

class _BankDetailPageState extends State<BankDetailPage> {
  BankCard? _item;
  CardNotes? _notes;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // M4.1：单卡直取 GET /api/v1/cards/<id>（与 search 条目同构），
      // 替代旧方案「searchBankCards(q: 卡id)」——卡 id 从不出现在正文里，
      // LIKE %id% 必然 0 命中 → 详情页必显错误（真机问题 1 的根因）
      final results = await Future.wait([
        ApiClient.instance.fetchCardById(widget.cardId),
        ApiClient.instance.fetchCardNotes(widget.cardId),
      ]);
      if (!mounted) return;
      setState(() {
        _item = results[0] as BankCard;
        _notes = results[1] as CardNotes;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        // 404 → 真实文案（旧方案 0 命中时的文案是误导性的「不在题库中」）
        _error = e.statusCode == 404 ? '卡片不存在或已下架' : e.message;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        backgroundColor: const Color(0xFFF6F7F9),
        title: const Text(
          '卡片详情',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(
              child: Text(
                widget.cardId,
                style: const TextStyle(
                  fontSize: 11,
                  color: HengyaColors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? _ErrorState(message: _error!, onRetry: _load)
          : _buildBody(),
    );
  }

  Widget _buildBody() {
    final item = _item!;
    final notes = _notes!;
    final c = item.card;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
      children: [
        // 题卡（设计稿 02b：白卡 + 标签行 + 题干 + 答案 + 锚点）
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: kCardSoftShadow,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _typeChip(c.type.name),
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFEDF2FF),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _subjectName(c.subjectId),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: HengyaColors.brand,
                      ),
                    ),
                  ),
                  // #10①「重造中」状态徽标：回炉入队后可见（否则与普通卡无异，
                  // 用户无从知道已在重造、还会再点回炉）
                  if (c.status == CardStatus.rework) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE37318).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '重造中',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFFE37318),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 8),
                  // 修正（真机问题 3）：长标签未约束 → 头部 Row 溢出
                  //（Expanded 占满剩余宽 + 右对齐 + 省略号，短标签视觉与原版一致）
                  if (c.tags.isNotEmpty)
                    Expanded(
                      child: Text(
                        c.tags.take(2).join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.right,
                        style: const TextStyle(
                          fontSize: 10,
                          color: HengyaColors.textSecondary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                c.front,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF0F7FF),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  c.back,
                  style: const TextStyle(
                    fontSize: 14,
                    height: 1.6,
                    color: Color(0xFF1A2B4A),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  const Icon(
                    Icons.anchor,
                    size: 13,
                    color: HengyaColors.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      c.anchor.isEmpty ? '无锚点' : '锚点 ${c.anchor}',
                      style: const TextStyle(
                        fontSize: 11,
                        color: HengyaColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        // 操作排（设计稿 02b：编辑 / 备注 / 回炉——AI 留言入口已移除）
        // M4.1：服务端契约放宽为 pending/active 均可编辑；
        // rework/rejected/archived 隐藏编辑入口（点了服务端也 400）
        Row(
          children: [
            if (c.status == CardStatus.pending ||
                c.status == CardStatus.active) ...[
              _ActionButton(
                icon: Icons.edit_outlined,
                label: '编辑',
                onTap: _openEditor,
              ),
              const SizedBox(width: 8),
            ],
            _ActionButton(
              icon: Icons.sticky_note_2_outlined,
              label: '备注',
              onTap: _openUserNote,
            ),
            const SizedBox(width: 8),
            // #10①：重造中的卡禁再次回炉——按钮换「重造中」态（点击只提示，
            // 不再弹回炉面板，从入口杜绝重复提交）
            // #15：rejected 废卡换「移除」入口（物理删除 + 二次确认）；
            // archived 无操作（旧版误显示「回炉」→ 点了必 400，防呆一并隐藏）。
            if (c.status == CardStatus.rework)
              _ActionButton(
                icon: Icons.autorenew_rounded,
                label: '重造中',
                color: const Color(0xFFE37318),
                onTap: () => _toast('已在回炉队列，无需重复提交'),
              )
            else if (c.status == CardStatus.rejected)
              _ActionButton(
                icon: Icons.delete_outline_outlined,
                label: '移除',
                color: const Color(0xFFD54941),
                onTap: _confirmRemove,
              )
            else if (c.status == CardStatus.active)
              _ActionButton(
                icon: Icons.restart_alt_outlined,
                label: '回炉',
                color: const Color(0xFFD54941),
                onTap: _openRework,
              ),
          ],
        ),
        const SizedBox(height: 12),
        // 我的备注区（琥珀底）
        _NoteSection(
          title: '我的备注',
          emptyHint: '点上方「备注」写下你自己的记忆口诀',
          content: notes.userNote,
          accent: const Color(0xFFB35B00),
          bg: const Color(0xFFFFF7E8),
        ),
      ],
    );
  }

  // 科目名（M5 动态科目：服务端/本地库名缓存 → 原样 id）
  String _subjectName(String id) => ApiClient.instance.subjectNameOf(id);

  Widget _typeChip(String type) {
    final label = switch (type) {
      'basic' => '问答',
      'cloze' => '填空',
      'caseChain' => '病例',
      'image' => '图像',
      _ => type,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFE8F5E9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: Color(0xFF2BA471),
        ),
      ),
    );
  }

  // ---- 编辑（题干/答案/锚点，复用保存按钮交互：loading + 错误提示）----
  void _openEditor() {
    final c = _item!.card;
    final frontCtrl = TextEditingController(text: c.front);
    final backCtrl = TextEditingController(text: c.back);
    final anchorCtrl = TextEditingController(text: c.anchor);
    showDialog<void>(
      context: context,
      builder: (dlgCtx) => _CenterDialog(
        title: '编辑卡片',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: frontCtrl,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '题干',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: backCtrl,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: '答案',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: anchorCtrl,
              decoration: const InputDecoration(
                labelText: '锚点（PPT 页码/章节）',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            _DialogSaveButton(
              savingText: '保存中…',
              onSave: () async {
                final front = frontCtrl.text.trim();
                final back = backCtrl.text.trim();
                if (front.isEmpty || back.isEmpty) {
                  throw ApiException(400, '题干和答案不能为空');
                }
                await ApiClient.instance.editPendingCard(
                  widget.cardId,
                  front: front,
                  back: back,
                  anchor: anchorCtrl.text.trim(),
                );
              },
              onSaved: () async {
                if (dlgCtx.mounted) Navigator.pop(dlgCtx);
                await _load();
                _toast('已保存修改');
              },
              onError: (msg) => _toast('保存失败：$msg'),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 我的备注 ----
  void _openUserNote() {
    final ctrl = TextEditingController(text: _notes?.userNote ?? '');
    showDialog<void>(
      context: context,
      builder: (dlgCtx) => _CenterDialog(
        title: '我的备注',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              maxLines: 5,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '写给自己看：口诀、联想、易错点…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 14),
            _DialogSaveButton(
              savingText: '保存中…',
              onSave: () => ApiClient.instance.updateCardNotes(
                widget.cardId,
                userNote: ctrl.text.trim(),
              ),
              onSaved: () async {
                if (dlgCtx.mounted) Navigator.pop(dlgCtx);
                await _load();
                _toast('备注已保存');
              },
              onError: (msg) => _toast('保存失败：$msg'),
            ),
          ],
        ),
      ),
    );
  }

  // ---- 回炉（与待审核池拒绝弹窗共用 ReasonActionDialog：六原因 + 自由输入 + 确认）----
  // #9：底部面板承载（isScrollControlled + viewInsets 键盘安全，见组件头注释）
  void _openRework() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      builder: (dlgCtx) => ReasonActionDialog(
        title: '回炉重造',
        subtitle: '「${_item!.card.front}」将退出复习队列，重造后回待审核池',
        reasons: kReworkReasons,
        noteHint: '补充说明（可选）：想怎么改这张卡？',
        buttonLabel: '送进回炉队列',
        buttonIcon: Icons.restart_alt_outlined,
        emptyReasonToast: '先选至少一个回炉原因',
        onConfirm: (reason, note) async {
          try {
            final res = await ApiClient.instance.reworkCard(
              widget.cardId,
              reason: reason,
              note: note,
            );
            await _load();
            if (mounted) {
              // #10②：duplicate=true 幂等重复（该卡已在回炉队列）——提示明确
              // 文案，不再抛「提交失败：卡 <内部id> 状态为 rework…」
              if (res['duplicate'] == true) {
                TopToast.show(
                  context,
                  '已在回炉队列，无需重复提交',
                  type: TopToastType.info,
                );
              } else {
                TopToast.show(
                  context,
                  '已送进回炉队列，重造后回待审核池',
                  type: TopToastType.success,
                );
              }
            }
          } on ApiException catch (e) {
            if (mounted) {
              TopToast.show(
                context,
                '提交失败：${e.message}',
                type: TopToastType.error,
                stayDuration: const Duration(milliseconds: 1800),
              );
            }
          }
        },
      ),
    );
  }

  // ---- 移除废卡（#15：物理删除 + 二次确认；仅 rejected 卡入口可见）----
  // 复用 _CenterDialog 版式（与编辑/备注弹窗统一）；确认后 removeCard →
  // toast「已移除」→ pop 回题库列表。列表刷新走既有 dataVersion 守卫链
  // （_openDetail push 前记录版本，delete 已 bump → 返回后自动重查），
  // 无需在详情页 _load（卡已物理删除，重拉必 404）。
  void _confirmRemove() {
    showDialog<void>(
      context: context,
      builder: (dlgCtx) => _CenterDialog(
        title: '移除废卡',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '确定从题库移除这张废卡吗？移除后不可恢复。',
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: HengyaColors.textSecondary,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(dlgCtx),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFD54941),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () async {
                      Navigator.pop(dlgCtx); // 先关弹窗（防双击重复提交）
                      try {
                        await ApiClient.instance.removeCard(widget.cardId);
                        if (!mounted) return;
                        // 先 toast 后 pop：TopToast 挂 rootOverlay，
                        // 详情页出栈后气泡仍完整展示
                        TopToast.show(context, '已移除',
                            type: TopToastType.success);
                        Navigator.pop(context); // 回列表（版本已变 → 自动重查）
                      } on ApiException catch (e) {
                        if (mounted) {
                          TopToast.show(context, '移除失败：${e.message}',
                              type: TopToastType.error);
                        }
                      }
                    },
                    child: const Text('确认移除'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _toast(String msg) {
    // 2026-09-06：轻提示统一顶部气泡（快速淡化 + 底色随机氛围），替换灰色 SnackBar
    if (mounted) {
      TopToast.show(context, msg);
    }
  }
}

/// 备注展示区（设计稿 02b：我的备注 琥珀底；AI 留言蓝底区已随留言入口移除）
class _NoteSection extends StatelessWidget {
  const _NoteSection({
    required this.title,
    required this.emptyHint,
    required this.content,
    required this.accent,
    required this.bg,
  });

  final String title;
  final String emptyHint;
  final String content;
  final Color accent;
  final Color bg;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
          const SizedBox(height: 6),
          if (content.isEmpty)
            Text(
              emptyHint,
              style: const TextStyle(
                fontSize: 12,
                color: HengyaColors.textSecondary,
              ),
            )
          else
            Text(
              content,
              style: const TextStyle(
                fontSize: 13,
                height: 1.5,
                color: Color(0xFF333333),
              ),
            ),
        ],
      ),
    );
  }
}

/// 操作按钮（设计稿 02b：白底圆角小按钮排）
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final fg = color ?? HengyaColors.brand;
    return Expanded(
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              children: [
                Icon(icon, size: 18, color: fg),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 居中弹窗容器（设计稿 06/07/03b 统一版式：342 宽 + 圆角 16 + 投影）
class _CenterDialog extends StatelessWidget {
  const _CenterDialog({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 32,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

/// 弹窗保存按钮（loading / 错误双状态，对齐设计稿 07）
class _DialogSaveButton extends StatefulWidget {
  const _DialogSaveButton({
    required this.onSave,
    required this.onSaved,
    required this.onError,
    required this.savingText,
  });

  final Future<void> Function() onSave;
  final Future<void> Function() onSaved;
  final void Function(String) onError;
  final String savingText;

  @override
  State<_DialogSaveButton> createState() => _DialogSaveButtonState();
}

class _DialogSaveButtonState extends State<_DialogSaveButton> {
  bool _saving = false;

  Future<void> _go() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave();
      await widget.onSaved();
    } on ApiException catch (e) {
      if (mounted) setState(() => _saving = false);
      widget.onError(e.message);
    } catch (e) {
      if (mounted) setState(() => _saving = false);
      widget.onError('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: HengyaColors.brand,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        onPressed: _saving ? null : _go,
        child: _saving
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(widget.savingText),
                ],
              )
            : const Text('确认保存'),
      ),
    );
  }
}
