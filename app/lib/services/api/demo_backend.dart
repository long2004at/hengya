// 演示模式数据源（M3 前端验收专用）：
// 零服务器依赖，本地内存模拟全部 API 语义——流转是真的（批准→入队列、
// 评分→FSRS 调度、回炉→重造→回待审池），数据是内置示例。
//
// 编译期注入：main.dart 用 --dart-define=DEMO=1 时启用。
// 一套代码两种构建：DEMO=1 演示包（无网可玩）/ 默认 真实服务器包。
import 'package:shared/hengya_shared.dart';

import 'api_client.dart';

class DemoBackend {
  DemoBackend._();

  static final DemoBackend instance = DemoBackend._();

  static const bool enabled = bool.fromEnvironment('DEMO');

  // ---------------- 内存态 ----------------

  final List<Subject> _subjects = [
    Subject(id: 'hist', name: '世界历史', isExamSubject: true),
    Subject(id: 'chem', name: '基础化学', isExamSubject: true),
    Subject(id: 'geo', name: '自然地理', isExamSubject: false),
    Subject(id: 'music', name: '音乐理论', isExamSubject: false),
  ];

  /// M5 AI 服务配置内存态（svc → 掩码态配置；明文 key 不落地，只存掩码）
  final Map<String, Map<String, dynamic>> _aiCfg = {};

  /// M5 知识库：待处理课件文件名（演示 pendingFiles 递增）
  final List<String> _pendingCorpus = [];

  /// ⑨ 章节管理演示态：科目 → {learned: 原始指针, skipped: 不学章集}。
  /// **PUT 后才建态**——GET 章节管理/主 /progress 在未动过时用底表初值
  /// 计算（与 §7.5 硬编码演示块逐字段一致），零行为漂移。
  final Map<String, Map<String, Object>> _chapterState = {};

  /// ⑨ 章节管理演示底表：科目 → (no, title, page) 全章列表（与 /progress
  /// 演示块的 learned/total/next 逐字段一致——next 章名/页码均取自本表）。
  static const Map<String, List<(int, String, int)>> _demoChapters = {
    'hist': [
      (1, '目录', 7), (2, '前言', 9),
      (3, '第一章 人类文明的曙光', 14), (4, '第二章 古代文明的交融', 32),
      (5, '第三章 资本主义的兴起', 51), (6, '第四章 工业革命', 78),
      (7, '第五章 殖民体系', 102), (8, '第六章 两次世界大战', 130),
      (9, '第七章 冷战', 158), (10, '第八章 全球化', 186),
      (11, '第九章 信息革命', 205), (12, '第十章 当代世界', 228),
      (13, '第十一章 文明的比较', 246), (14, '第十二章 环境与发展', 261),
      (15, '第十三章 人口与社会', 278), (16, '第十四章 科技革命', 293),
      (17, '第十五章 文化交流', 310), (18, '第十六章 区域史', 326),
      (19, '第十七章 史学史', 341), (20, '第十八章 史料学', 356),
      (21, '第十九章 研究方法', 372), (22, '中英文名词对照索引', 388),
      (23, '后记', 401),
    ],
    'chem': [
      (1, '目录', 5), (2, '前言', 7),
      (3, '第一篇 物质结构', 12), (4, '化学反应原理', 34),
      (5, '第二篇 溶液与胶体', 58), (6, '第三篇 电化学基础', 89),
      (7, '第四篇 化学分析与实验', 118), (8, '中英文名词对照索引', 156),
    ],
    'geo': [
      (1, '目录', 5), (2, '前言', 9),
      (3, '第一章 绪论', 13), (4, '第二章 地球的结构', 28),
      (5, '第三章 地壳与岩石', 46), (6, '第四章 大气圈', 67),
      (7, '第五章 水圈', 88), (8, '第六章 生物圈', 109),
      (9, '第七章 地貌', 128), (10, '第八章 土壤', 147),
      (11, '第九章 自然区划', 166), (12, '第十章 人类与自然', 182),
      (13, '中英文名词对照索引', 198),
    ],
    'music': [
      (1, '目录', 3), (2, '前言', 5),
      (3, '第一章 音的基础知识', 9), (4, '第二章 记谱法', 22),
      (5, '第三章 节奏与节拍', 35), (6, '第四章 音程', 48),
      (7, '第五章 和弦', 61), (8, '第六章 调式', 74),
      (9, '第七章 调性', 87), (10, '第八章 曲式', 100),
      (11, '第九章 旋律', 113), (12, '第十章 和声进行', 126),
      (13, '第十一章 复调', 139), (14, '第十二章 配器', 152),
      (15, '第十三章 音乐分析', 165), (16, '第十四章 视唱练耳', 178),
      (17, '第十五章 音乐史', 191), (18, '第十六章 音乐美学', 204),
      (19, '后记', 217),
    ],
  };

  /// 底表初始指针（与 /progress 硬编码块 learned_through 一致）
  static const Map<String, int> _demoInitialLearned = {
    'hist': 4,
    'chem': 4,
    'geo': 0,
    'music': 19,
  };

  /// 辅文章过滤（§7.5 契约：9 项精确集合，去空白归一比对）
  static const _nonContentExact = {
    '目录', '目录尾', '前言', '序', '序言', '附录', '附录一', '附录二', '附录三',
  };

  static String _norm(String s) => s.replaceAll(RegExp(r'\s+'), '');

  static final _nonContentNorm = {for (final t in _nonContentExact) _norm(t)};

  /// 章节管理视图（⑨ `GET /progress/<subject>/chapters` 演示实现）：
  /// 底表 + 演示态（无态 = 底表初值），口径与 local 实装一致。
  Map<String, dynamic> _chapterView(String id) {
    final spec = _demoChapters[id];
    if (spec == null) {
      throw ApiException(404, '科目 $id 不在进度库——章节管理仅面向已有科目');
    }
    final st = _chapterState[id];
    final learned = st == null ? _demoInitialLearned[id]! : st['learned'] as int;
    final skipped = st == null
        ? const <int>{}
        : (st['skipped'] as Set<int>);
    // #1 口径对齐（2026-09-13）：有效已学/有效总量 = 真实正文章口径
    // （剔辅文与跳过），与 local 实装 _effectiveLearned/_effectiveTotal 一致
    bool isContent(int no, String title) =>
        !skipped.contains(no) && !_nonContentNorm.contains(_norm(title));
    final effLearned = [
      for (final (no, title, _) in spec)
        if (no > 0 && no <= learned && isContent(no, title)) no,
    ].length;
    // 下一章（9 项辅文章过滤 + 跳过感知）
    Map<String, dynamic>? next;
    for (final (no, title, page) in spec) {
      if (no <= learned || skipped.contains(no)) continue;
      if (_nonContentNorm.contains(_norm(title))) continue;
      next = {'no': no, 'title': title, 'page': page};
      break;
    }
    return {
      'id': id,
      'textbook': _textbookOf(id),
      'learned_through': learned,
      'skipped': skipped.toList()..sort(),
      'total': spec.length,
      'effective_total': spec.length - skipped.length,
      'effective_learned': effLearned,
      'next_chapter': next,
      'chapters': [
        for (final (no, title, page) in spec)
          {
            'no': no,
            'title': title,
            'page_start': page,
            'learned': no > 0 && no <= learned,
            'skipped': skipped.contains(no),
          },
      ],
    };
  }

  /// 演示教材名（与 /progress 硬编码块一致）
  static String _textbookOf(String id) => switch (id) {
        'hist' => '世界通史-第2版',
        'chem' => '基础化学-第2版',
        'geo' => '自然地理-第1版',
        _ => '音乐理论基础-第1版',
      };

  var _autoSubjectSeq = 0;

  final Map<String, List<FlashCard>> _cardsBySubject = {};
  final Map<String, CardMemoryState> _memory = {};
  final List<Map<String, dynamic>> _reworkQueue = [];
  final List<Map<String, dynamic>> _inbox = [];
  final List<Map<String, dynamic>> _reviewLogs = [];
  // M4 题库：卡片备注/留言（cardId → {userNote, aiNote}）
  final Map<String, Map<String, String>> _notes = {};
  int _dataVersion = 1;

  void _bump() => _dataVersion++;

  final _scheduler = const FsrsScheduler();

  bool _seeded = false;

  void _seedIfNeeded() {
    if (_seeded) return;
    _seeded = true;
    final now = DateTime.now();
    // 科目 1（世界历史）：两张到期卡 + 一张未来到期（演示"今日 2 张"角标）
    _importDemo(
      'hist',
      'demo-hist-001',
      '文艺复兴运动最早兴起于哪个国家？',
      '意大利（14 世纪，从佛罗伦萨等城市兴起）',
      '近代史·文艺复兴｜兴起地',
      '世界历史 近代史 PPT',
    );
    _importDemo(
      'hist',
      'demo-hist-002',
      '文艺复兴的定义是什么？',
      '14-16 世纪发源于意大利、以人文主义为核心的思想文化运动。',
      '近代史·文艺复兴｜定义',
      '世界历史 近代史 PPT',
    );
    _importDemo(
      'hist',
      'demo-hist-003',
      '工业革命最早开始于哪个国家？',
      '英国（18 世纪 60 年代，从棉纺织业开始）。',
      '近代史·工业革命｜起点',
      '世界历史 近代史 PPT',
    );
    _activateDemo('demo-hist-001');
    _activateDemo('demo-hist-002');
    _activateDemo('demo-hist-003');
    // 给 003 安排到 3 天后（演示"未来到期"）
    _memory['demo-hist-003'] = CardMemoryState(
      state: SchedulingState.review,
      dueAt: now.add(const Duration(days: 3)),
      stability: 5.0,
      difficulty: 5.0,
      reps: 2,
      lapses: 0,
      lastReviewedAt: now.subtract(const Duration(days: 1)),
    );

    // 科目 2（基础化学）：一张到期卡 + 病例卡（演示 caseChain 卡型）
    _importDemo(
      'chem',
      'demo-chem-001',
      '什么是化学元素？',
      '具有相同质子数（核电荷数）的一类原子的总称。',
      '基本概念·元素｜同质子数',
      '基础化学 1.1 PPT',
    );
    _importDemo(
      'chem',
      'demo-chem-002',
      '实验中铜片加热变黑，通入氢气后又恢复红色。如何解释这一现象？',
      '铜被氧化生成黑色的氧化铜；氢气具有还原性，夺取氧化铜中的氧，使铜重新析出（氧化还原反应）。',
      '实验现象·氧化还原｜案例链',
      '基础化学 实验 PPT',
      type: CardType.caseChain,
    );
    _activateDemo('demo-chem-001');
    _activateDemo('demo-chem-002');

    // 科目 3/4：空科目（演示零角标 + 空队列态）
    _cardsBySubject['geo'] = [];
    _cardsBySubject['music'] = [];

    // 待审核池 3 张（其中 1 张标"待确认"——演示审核三键）
    _importDemo(
      'chem',
      'demo-new-001',
      '稀有气体的定义是什么？为什么化学性质极不活泼？',
      '元素周期表 0 族气体（He/Ne/Ar 等）；最外层电子已达稳定结构，极难得失电子。',
      '元素周期律·0 族｜待核对',
      '基础化学 教材（PPT 未覆盖，标【待确认】）',
      status: CardStatus.pending,
    );
    _importDemo(
      'hist',
      'demo-new-002',
      '新航路开辟的两大主要动机是什么？',
      '追寻黄金香料等财富、传播宗教；深层动力是商品经济发展与资本主义萌芽。',
      '近代史·新航路｜两大动机',
      '世界历史 近代史 PPT',
      status: CardStatus.pending,
    );
    _importDemo(
      'geo',
      'demo-new-003',
      '季风气候的主要成因是什么？',
      '海陆热力性质差异（冬季风从陆地吹向海洋、夏季风从海洋吹向陆地）。',
      '气候类型·季风｜待核对',
      '自然地理 PPT',
      status: CardStatus.pending,
    );

    // 模拟历史复习日志（演示热力图 + streak + 统计页）
    _fakeHistory(now);
  }

  void _importDemo(
    String subjectId,
    String id,
    String front,
    String back,
    String anchor,
    String source, {
    CardType type = CardType.basic,
    CardStatus status = CardStatus.active,
    List<String> tags = const [],
  }) {
    final card = FlashCard(
      id: id,
      subjectId: subjectId,
      type: type,
      front: front,
      back: back,
      anchor: anchor,
      source: source,
      status: status,
      tags: tags,
    );
    (_cardsBySubject[subjectId] ??= []).add(card);
  }

  void _activateDemo(String id) {
    for (final list in _cardsBySubject.values) {
      final idx = list.indexWhere((c) => c.id == id);
      if (idx >= 0) {
        final c = list[idx];
        list[idx] = FlashCard(
          id: c.id,
          subjectId: c.subjectId,
          type: c.type,
          front: c.front,
          back: c.back,
          anchor: c.anchor,
          source: c.source,
          status: CardStatus.active,
          tags: c.tags,
        );
        // FSRS newCard 状态，due=now（立即可复习）
        _memory[id] = CardMemoryState(
          state: SchedulingState.newCard,
          dueAt: DateTime.now(),
          stability: 0,
          difficulty: 0,
          reps: 0,
          lapses: 0,
          lastReviewedAt: null,
        );
        return;
      }
    }
  }

  void _fakeHistory(DateTime now) {
    // 近 3 周：大部分天有 2-6 次复习（演示热力图梯度 + streak=5）
    final pattern = [
      2,
      4,
      6,
      3,
      0,
      5,
      2,
      4,
      3,
      6,
      2,
      0,
      4,
      5,
      3,
      2,
      6,
      4,
      0,
      5,
      3,
    ];
    for (var back = pattern.length - 1; back >= 0; back--) {
      final day = now.subtract(Duration(days: back));
      final n = pattern[pattern.length - 1 - back];
      for (var i = 0; i < n; i++) {
        _reviewLogs.add({
          'cardId': 'demo-hist-00$i',
          'subjectId': i % 2 == 0 ? 'hist' : 'chem',
          'rating': i % 5 == 0 ? 'again' : 'good',
          'reviewedAt':
              '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}'
              'T${(9 + i % 8).toString().padLeft(2, '0')}:${(i * 7 % 60).toString().padLeft(2, '0')}:00',
        });
      }
    }
    // leech 弱卡：给一张卡累计 4 次 lapse（演示弱卡榜非空）
    _memory['demo-chem-002'] = CardMemoryState(
      state: SchedulingState.review,
      dueAt: now,
      stability: 1.2,
      difficulty: 9.2,
      reps: 6,
      lapses: 4,
      lastReviewedAt: now.subtract(const Duration(hours: 6)),
    );
    // 收件箱 2 条未消费（演示统计页 pendingInbox + 也可直接入箱）
    _inbox.addAll([
      {
        'id': 1,
        'subjectId': 'chem',
        'keyword': '元素周期表速记',
        'source': 'chat',
        'note': '',
        'createdAt': now.toIso8601String(),
      },
      {
        'id': 2,
        'subjectId': 'hist',
        'keyword': '工业革命的影响',
        'source': 'app',
        'note': '',
        'createdAt': now.toIso8601String(),
      },
    ]);
  }

  // ---------------- API 语义模拟 ----------------

  /// 路由归一化：ApiClient 全链路带 `/api/v1` 前缀，本后端按挂载路径匹配；
  /// 两种调用形态统一剥前缀（裸路径原样通过）。
  /// 修正：此前演示包全页面 404 → 显示「连不上服务器」。
  String _normalize(String path) {
    const prefix = '/api/v1';
    if (path == prefix) return '/';
    return path.startsWith('$prefix/') ? path.substring(prefix.length) : path;
  }

  /// query 解析：兼容「已编码」与「未编码」两种形态。
  /// ApiClient 正常链路走 Uri.encodeQueryComponent（已编码）；
  /// 直接调用 DemoBackend（测试/调试）可能传裸中文——
  /// Uri.splitQueryString / decodeComponent 对未编码非 ASCII 会抛
  /// Illegal percent encoding，而 Uri.parse 对两种形态都正确解码。
  Map<String, String> _parseQuery(String path) {
    return Uri.parse(path).queryParameters;
  }

  Future<Map<String, dynamic>> get(String path) async {
    await Future.delayed(const Duration(milliseconds: 120)); // 拟真延迟
    _seedIfNeeded();
    path = _normalize(path);

    // /health
    if (path == '/health') {
      return {'status': 'ok', 'data_version': '$_dataVersion'};
    }

    // /meta/version
    if (path.startsWith('/meta/version')) {
      return {'data_version': '$_dataVersion'};
    }

    // /subjects（含各科 dueCount；server 0.3.0 同构；0.3.1 起不再含内置标记字段）
    if (path.startsWith('/subjects')) {
      return {
        'subjects': [
          for (final s in _subjects)
            {..._subjectJson(s), 'dueCount': _dueCount(s.id)},
        ],
      };
    }

    // /settings/ai（M5：三套 AI 服务配置掩码态——llm / embedding / reranker）
    if (path == '/settings/ai') {
      return {
        'llm': _aiCfgOf('llm'),
        'embedding': _aiCfgOf('embedding'),
        'reranker': _aiCfgOf('reranker'),
      };
    }

    // /corpus/status（M5 知识库状态）
    if (path == '/corpus/status') {
      return _corpusStatus();
    }

    // /cards/pending
    if (path == '/cards/pending') {
      return {
        'list': [
          for (final c in _allCards())
            if (c.status == CardStatus.pending) c.toJson(),
        ],
      };
    }

    // /cards/queue?subject=xx
    if (path.startsWith('/cards/queue')) {
      final subject = _parseQuery(path)['subject']!;
      return {
        'cards': [
          for (final c in _cardsBySubject[subject] ?? const <FlashCard>[])
            if (c.status == CardStatus.active &&
                (_memory[c.id]?.dueAt.isBefore(DateTime.now()) ?? false))
              c.toJson(),
        ],
      };
    }

    // /cards/leech
    if (path.startsWith('/cards/leech')) {
      return {
        'cards': [
          for (final c in _allCards())
            if (c.status == CardStatus.active &&
                (_memory[c.id]?.lapses ?? 0) >= 4)
              c.toJson(),
        ],
      };
    }

    // /cards/search（M4 题库：科目过滤 + 全文匹配 + 分页）
    if (path.startsWith('/cards/search')) {
      final query = _parseQuery(path);
      final subject = query['subject'];
      final q = query['q'] ?? '';
      var cards = [
        for (final c in _allCards())
          if (c.status != CardStatus.pending) c,
      ];
      if (subject != null && subject.isNotEmpty) {
        cards = cards.where((c) => c.subjectId == subject).toList();
      }
      if (q.isNotEmpty) {
        cards = cards
            .where(
              (c) =>
                  c.front.contains(q) ||
                  c.back.contains(q) ||
                  c.tags.any((t) => t.contains(q)),
            )
            .toList();
      }
      final offset = int.tryParse(query['offset'] ?? '') ?? 0;
      final limit = int.tryParse(query['limit'] ?? '') ?? 50;
      return {
        'cards': [
          for (final c in cards.skip(offset).take(limit))
            {
              ...c.toJson(),
              'dueAt': _memory[c.id]?.dueAt.toIso8601String() ?? '',
              'reps': _memory[c.id]?.reps ?? 0,
              'lapses': _memory[c.id]?.lapses ?? 0,
              'userNote': _notes[c.id]?['userNote'] ?? '',
              'aiNote': _notes[c.id]?['aiNote'] ?? '',
            },
        ],
        'total': cards.length,
      };
    }

    // /cards/<id>/notes（M4：备注与 AI 留言）
    final notesGet = RegExp(r'^/cards/([^/]+)/notes$').firstMatch(path);
    if (notesGet != null) {
      final n = _notes[notesGet.group(1)!];
      return {'userNote': n?['userNote'] ?? '', 'aiNote': n?['aiNote'] ?? ''};
    }

    // /cards/rework/pending（M4 双通道：queue 回炉队列 + aiNotes 未读学生留言，
    // 与正式服务端 routes/cards.dart 契约一致）
    if (path == '/cards/rework/pending') {
      return {
        'queue': _reworkQueue.where((r) => r['status'] == 'pending').toList(),
        'aiNotes': <Map<String, dynamic>>[],
      };
    }

    // /cards/<id>（M4.1 单卡查询：题库详情页直取，与 /cards/search 条目完全同构）
    // 顺序敏感：必须排在 /cards/pending、/cards/queue、/cards/leech、/cards/search、
    // /cards/rework/pending 之后——search 等路径的 query 段同样不含「/」，
    // 本路由若在前会把它们当 <id> 吞掉（与真实服务端 routes/cards.dart 注册序对齐）。
    final cardGet = RegExp(r'^/cards/([^/]+)$').firstMatch(path);
    if (cardGet != null) {
      final c = _cardOf(cardGet.group(1)!);
      if (c == null) throw ApiException(404, '卡不存在');
      return {
        ...c.toJson(),
        'dueAt': _memory[c.id]?.dueAt.toIso8601String() ?? '',
        'reps': _memory[c.id]?.reps ?? 0,
        'lapses': _memory[c.id]?.lapses ?? 0,
        'userNote': _notes[c.id]?['userNote'] ?? '',
        'aiNote': _notes[c.id]?['aiNote'] ?? '',
      };
    }

    // /inbox/pending
    if (path == '/inbox/pending') {
      return {'list': _inbox};
    }

    // /stats/*
    if (path.startsWith('/stats/streak')) {
      return {'streak': _streak()};
    }
    if (path.startsWith('/stats/heatmap')) {
      return {'days': 84, 'byDay': _heatmap()};
    }
    if (path.startsWith('/stats/forecast')) {
      return {'list': _forecast()};
    }
    if (path.startsWith('/stats/summary')) {
      return _summary();
    }
    if (path.startsWith('/stats/retention')) {
      return _retention();
    }

    // /progress（§7.5 学习罗盘演示数据：与真实服务端同构——
    // hist/chem 在学、geo 未开学、music 学完 next_chapter=null；
    // ⑨ 章节管理 PUT 动过的科目改由底表+演示态计算有效口径）
    if (path == '/progress') {
      return {
        'subjects': [
          for (final id in const ['hist', 'chem', 'geo', 'music'])
            if (_chapterState.containsKey(id))
              () {
                final v = _chapterView(id);
                final lt = v['learned_through'] as int;
                final sk = (v['skipped'] as List).cast<int>();
                return {
                  'id': id,
                  'textbook': v['textbook'],
                  // 与 local 主视图同口径：指针原样（减跳过），非正文章计数
                  'learned_through': lt - sk.where((s) => s <= lt).length,
                  'total': v['effective_total'],
                  // #1：展示口径补充字段（与 local 主视图一致）
                  'effective_learned': v['effective_learned'],
                  'effective_total': v['effective_total'],
                  'next_chapter': v['next_chapter'],
                };
              }()
            else if (id == 'hist')
              {
                'id': 'hist',
                'textbook': '世界通史-第2版',
                'learned_through': 4,
                'total': 23,
                'next_chapter': {'no': 5, 'title': '第三章 资本主义的兴起', 'page': 51},
              }
            else if (id == 'chem')
              {
                'id': 'chem',
                'textbook': '基础化学-第2版',
                'learned_through': 4,
                'total': 8,
                'next_chapter': {'no': 5, 'title': '第二篇 溶液与胶体', 'page': 58},
              }
            else if (id == 'geo')
              {
                'id': 'geo',
                'textbook': '自然地理-第1版',
                'learned_through': 0,
                'total': 13,
                'next_chapter': {'no': 3, 'title': '第一章 绪论', 'page': 13},
              }
            else
              {
                'id': 'music',
                'textbook': '音乐理论基础-第1版',
                'learned_through': 19,
                'total': 19,
                'next_chapter': null,
              },
        ],
        'updated_at': DateTime.now().toIso8601String(),
      };
    }

    // /progress/<subject>/chapters（⑨ 章节管理 GET：底表 + 演示态视图）
    final chapterGet = RegExp(r'^/progress/([^/]+)/chapters$').firstMatch(path);
    if (chapterGet != null) {
      return _chapterView(chapterGet.group(1)!);
    }

    throw ApiException(404, '演示模式不支持: $path');
  }

  Future<Map<String, dynamic>> post(String path, Object? body) async {
    await Future.delayed(const Duration(milliseconds: 120));
    _seedIfNeeded();
    path = _normalize(path);
    final m = body is Map<String, dynamic>
        ? body
        : body is Map
        ? Map<String, dynamic>.from(body)
        : const <String, dynamic>{};

    // /cards/<id>/approve
    final approve = RegExp(r'^/cards/([^/]+)/approve$').firstMatch(path);
    if (approve != null) {
      return _setStatus(approve.group(1)!, CardStatus.active);
    }

    // /cards/<id>/reject（M4：带理由 → 登记回炉队列，AI 可见）
    final reject = RegExp(r'^/cards/([^/]+)/reject$').firstMatch(path);
    if (reject != null) {
      final cardId = reject.group(1)!;
      final reason = (m['reason'] as String? ?? '').trim();
      final note = (m['note'] as String? ?? '').trim();
      final res = _setStatus(cardId, CardStatus.rejected);
      if (reason.isNotEmpty) {
        _reworkQueue.add({
          'id': _reworkQueue.length + 1,
          'cardId': cardId,
          'reason': '审核拒绝：$reason',
          'note': note,
          'status': 'pending',
          'createdAt': DateTime.now().toIso8601String(),
        });
        _bump();
      }
      return res;
    }

    // /cards/<id>/notes（M4：更新备注/留言）
    final notesPost = RegExp(r'^/cards/([^/]+)/notes$').firstMatch(path);
    if (notesPost != null) {
      final cardId = notesPost.group(1)!;
      if (_findIdx(cardId) == null) throw ApiException(404, '卡不存在');
      final n = _notes.putIfAbsent(cardId, () => <String, String>{});
      final userNote = m['userNote'] as String?;
      final aiNote = m['aiNote'] as String?;
      if (userNote == null && aiNote == null) {
        throw ApiException(400, '至少传 userNote 或 aiNote 之一');
      }
      if (userNote != null) n['userNote'] = userNote;
      if (aiNote != null) n['aiNote'] = aiNote;
      _bump();
      return {
        'ok': true,
        'id': cardId,
        'userNote': n['userNote'] ?? '',
        'aiNote': n['aiNote'] ?? '',
      };
    }

    // /cards/<id>/edit
    final edit = RegExp(r'^/cards/([^/]+)/edit$').firstMatch(path);
    if (edit != null) return _editCard(edit.group(1)!, m);

    // /cards/rework
    if (path == '/cards/rework') {
      final cardId = m['cardId'] as String;
      final idx = _findIdx(cardId);
      // #15：404 文案对齐 local 路由（去内部 id 化）
      if (idx == null) throw ApiException(404, '卡片不存在或已被移除');
      // #10② 幂等（对齐 local 路由）：重造中的重复提交 → duplicate:true
      // 幂等成功（不重复入队、不抛错）
      if (_cardOf(cardId)!.status == CardStatus.rework) {
        return {'ok': true, 'cardId': cardId, 'duplicate': true};
      }
      _setCardStatus(cardId, CardStatus.rework);
      _reworkQueue.add({
        'id': _reworkQueue.length + 1,
        'cardId': cardId,
        'reason': m['reason'] ?? '',
        'note': m['note'] ?? '',
        'status': 'pending',
        'createdAt': DateTime.now().toIso8601String(),
      });
      _dataVersion++;
      return {'ok': true, 'cardId': cardId};
    }

    // /cards/delete（#15 对齐 local 路由：移除废卡——物理删除，仅 rejected；
    // 再删同 id → 404 幂等；文案不带内部 id）
    if (path == '/cards/delete') {
      final cardId = m['cardId'] as String?;
      if (cardId == null || cardId.isEmpty) throw ApiException(400, '缺少 cardId');
      final c = _cardOf(cardId);
      if (c == null) throw ApiException(404, '卡片不存在或已被移除');
      if (c.status != CardStatus.rejected) {
        throw ApiException(400, '仅已拒绝的废卡可移除');
      }
      _cardsBySubject[c.subjectId]?.removeWhere((x) => x.id == cardId);
      _memory.remove(cardId);
      _notes.remove(cardId);
      _reworkQueue.removeWhere((r) => r['cardId'] == cardId);
      _reviewLogs.removeWhere((r) => r['cardId'] == cardId); // 防御性对齐 local
      _bump();
      return {'ok': true, 'cardId': cardId};
    }

    // /cards/rework/<queueId>/done（重造完成 → 回待审池）
    final done = RegExp(r'^/cards/rework/(\d+)/done$').firstMatch(path);
    if (done != null) {
      final qid = int.parse(done.group(1)!);
      final item = _reworkQueue.firstWhere(
        (r) => r['id'] == qid && r['status'] == 'pending',
        orElse: () => throw ApiException(400, '队列项已处理或不存在'),
      );
      final cardId = item['cardId'] as String;
      _updateCardFields(
        cardId,
        front: m['front'] as String?,
        back: m['back'] as String?,
        anchor: m['anchor'] as String?,
      );
      _setCardStatus(cardId, CardStatus.pending);
      item['status'] = 'done';
      _dataVersion++;
      return {'ok': true, 'queueId': qid};
    }

    // /review/answer（单条/批量；FSRS 真调度）
    if (path == '/review/answer') {
      final items = body is List ? body : [m];
      var applied = 0;
      final results = <Map<String, dynamic>>[];
      for (final raw in items) {
        final item = Map<String, dynamic>.from(raw as Map);
        final cardId = item['cardId'] as String;
        final rating = ReviewRating.values.byName(item['rating'] as String);
        final reviewedAt =
            DateTime.tryParse(item['reviewedAt'] as String? ?? '') ??
            DateTime.now();
        var mem = _memory[cardId];
        if (mem == null || _cardOf(cardId)?.status != CardStatus.active) {
          results.add({
            'cardId': cardId,
            'ok': false,
            'error': '非 active 或不存在',
          });
          continue;
        }
        final result = _scheduler.schedule(mem, rating, now: reviewedAt);
        _memory[cardId] = CardMemoryState(
          state: result.state,
          dueAt: result.dueAt,
          stability: result.stability,
          difficulty: result.difficulty,
          reps: result.reps,
          lapses: result.lapses,
          lastReviewedAt: reviewedAt,
        );
        _reviewLogs.add({
          'cardId': cardId,
          'subjectId': _cardOf(cardId)!.subjectId,
          'rating': rating.name,
          'reviewedAt': reviewedAt.toIso8601String(),
        });
        applied++;
        results.add({
          'cardId': cardId,
          'ok': true,
          'state': result.state.name,
          'dueAt': result.dueAt.toIso8601String(),
          'intervalDays': result.intervalDays,
        });
      }
      _dataVersion++;
      return {
        'ok': true,
        'applied': applied,
        'skipped': items.length - applied,
        'results': results,
      };
    }

    // /inbox/keywords
    if (path == '/inbox/keywords') {
      final items = body is List ? body : [m];
      var inserted = 0;
      for (final raw in items) {
        final item = Map<String, dynamic>.from(raw as Map);
        _inbox.add({
          'id': _inbox.length + 1,
          'subjectId': item['subjectId'],
          'keyword': item['keyword'],
          'source': item['source'] ?? 'app',
          'note': item['note'] ?? '',
          'createdAt': DateTime.now().toIso8601String(),
        });
        inserted++;
      }
      _dataVersion++;
      return {'ok': true, 'inserted': inserted};
    }

    // /settings/ai/<svc>/test（M5：演示模式恒连通；svc ∈ llm|embedding|reranker）
    final aiTest = RegExp(
      r'^/settings/ai/(llm|embedding|reranker)/test$',
    ).firstMatch(path);
    if (aiTest != null) {
      return {
        'ok': true,
        'status': 200,
        'latencyMs': 42,
        'message': '演示模式：模拟连接成功',
      };
    }

    // /subjects（M5 动态科目：新建；id 留空自动生成，重复短码 409）
    if (path == '/subjects') {
      final name = (m['name'] as String? ?? '').trim();
      if (name.isEmpty) throw ApiException(400, '名称必填');
      var id = ((m['id'] as String?) ?? '').trim();
      if (id.isEmpty) id = 'sub${++_autoSubjectSeq}'; // 自动短码
      if (_subjects.any((s) => s.id == id)) {
        throw ApiException(409, '短码已存在：$id');
      }
      _subjects.add(Subject(id: id, name: name, isExamSubject: false));
      _bump();
      return {'ok': true, 'id': id, 'name': name};
    }

    // /pipeline/trigger（server 0.4.1 契约 stub：演示模式无真实流水线，
    // 恒返回首次排队成功，供设置页「强制开始拆卡 / 改卡」入口联调）
    if (path == '/pipeline/trigger') {
      return {'ok': true, 'triggered': true, 'note': '演示模式：已模拟触发（无真实流水线）'};
    }

    throw ApiException(404, '演示模式不支持: $path');
  }

  /// PUT（M5：AI 服务配置更新，契约 `PUT /api/v1/settings/ai/<svc>`）。
  /// apiKey 空串 = 保持已存 key 不变；非空 = 更新（只存掩码，明文不落地）。
  Future<Map<String, dynamic>> put(String path, Object? body) async {
    await Future.delayed(const Duration(milliseconds: 120));
    _seedIfNeeded();
    path = _normalize(path);
    final m = body is Map<String, dynamic>
        ? body
        : body is Map
        ? Map<String, dynamic>.from(body)
        : const <String, dynamic>{};

    final aiPut =
        RegExp(r'^/settings/ai/(llm|embedding|reranker)$').firstMatch(path);
    if (aiPut != null) {
      final cfg = _aiCfg.putIfAbsent(aiPut.group(1)!, _emptyAiCfg);
      final baseUrl = m['baseUrl'] as String?;
      final model = m['model'] as String?;
      if (baseUrl != null && baseUrl.isNotEmpty) cfg['baseUrl'] = baseUrl;
      if (model != null && model.isNotEmpty) cfg['model'] = model;
      final key = (m['apiKey'] as String?) ?? '';
      if (key.isNotEmpty) {
        cfg['keySet'] = true;
        cfg['keyMasked'] = _maskKey(key);
      }
      _bump();
      return {
        'ok': true,
        'keySet': cfg['keySet'],
        'keyMasked': cfg['keyMasked'],
      };
    }

    // /progress/<subject>/chapters（⑨ 章节管理写：演示态读-改-写——
    // body {learned_through?, skipped?}，缺省字段不动；超范围 400）
    final chapterPut = RegExp(r'^/progress/([^/]+)/chapters$').firstMatch(path);
    if (chapterPut != null) {
      final id = chapterPut.group(1)!;
      final spec = _demoChapters[id];
      if (spec == null) {
        throw ApiException(404, '科目 $id 不在进度库——章节管理仅面向已有科目');
      }
      final lt = m['learned_through'];
      final sk = m['skipped'];
      if (lt != null && lt is! int) {
        throw ApiException(400, 'learned_through 须为整数章序');
      }
      if (lt != null && (lt < 0 || lt > spec.length)) {
        throw ApiException(400, '超出罗盘：第 $lt 章 > 共 ${spec.length} 章');
      }
      if (sk != null && sk is! List) {
        throw ApiException(400, 'skipped 须为章序（int）列表');
      }
      final st = _chapterState.putIfAbsent(id, () {
        return {
          'learned': _demoInitialLearned[id]!,
          'skipped': <int>{},
        };
      });
      if (lt != null) {
        st['learned'] = lt;
      }
      if (sk != null) {
        st['skipped'] = {
          for (final v in sk)
            if (v is int && v >= 1 && v <= spec.length) v,
        };
      }
      _bump();
      return {..._chapterView(id), 'ok': true, 'note': '演示模式已更新'};
    }

    throw ApiException(404, '演示模式不支持: $path');
  }

  /// 原始字节流上传（M5：课件上传，契约 `POST /api/v1/corpus/upload`）
  Future<Map<String, dynamic>> upload(String path, List<int> bytes) async {
    await Future.delayed(const Duration(milliseconds: 120));
    _seedIfNeeded();
    path = _normalize(path);

    if (path.startsWith('/corpus/upload')) {
      final q = _parseQuery(path);
      _pendingCorpus.add('${q['subject']}/${q['filename']}');
      _bump();
      return {
        'ok': true,
        'received': bytes.length,
        'pending': _pendingCorpus.length,
      };
    }

    throw ApiException(404, '演示模式不支持: $path');
  }

  // ---------------- 内部辅助 ----------------

  Map<String, dynamic> _subjectJson(Subject s) => {
    'id': s.id,
    'name': s.name,
    'isExamSubject': s.isExamSubject,
  };

  /// M5：单套 AI 服务配置（未配置态 + 已配置掩码态）
  Map<String, dynamic> _aiCfgOf(String svc) =>
      Map<String, dynamic>.from(_aiCfg[svc] ?? _emptyAiCfg());

  Map<String, dynamic> _emptyAiCfg() => {
    'baseUrl': '',
    'model': '',
    'keySet': false,
    'keyMasked': '',
    'encrypted': true, // 服务端真实现 AES-GCM 加密存储；演示态同义
  };

  /// 掩码：保留首 3 位 + 尾 2 位，中间 ****（与服务端掩码语义一致：可识别不可还原）
  String _maskKey(String key) => key.length <= 5
      ? '****'
      : '${key.substring(0, 3)}****${key.substring(key.length - 2)}';

  /// M5：语料库状态（演示为固定语料 + 递增的待处理文件）
  Map<String, dynamic> _corpusStatus() {
    return {
      'totalChunks': 42,
      'subjects': {'oms': 18, 'endo': 24},
      'lastBuild': null,
      'pendingFiles': _pendingCorpus.length,
      // ⑦ 回炉待重造：与 local 同语义（rework_queue pending 行数，含拒绝
      // 带理由登记）——对齐本端 /cards/rework/pending 的 queue 口径
      'reworkPending': _reworkQueue
          .where((r) => r['status'] == 'pending')
          .length,
      'storageMB': 3.2,
    };
  }

  List<FlashCard> _allCards() => [
    for (final list in _cardsBySubject.values) ...list,
  ];

  int _dueCount(String subjectId) {
    final now = DateTime.now();
    return (_cardsBySubject[subjectId] ?? const []).where((c) {
      if (c.status != CardStatus.active) return false;
      final mem = _memory[c.id];
      return mem != null && mem.dueAt.isBefore(now);
    }).length;
  }

  String? _findIdx(String id) {
    for (final e in _cardsBySubject.entries) {
      if (e.value.any((c) => c.id == id)) return e.key;
    }
    return null;
  }

  FlashCard? _cardOf(String id) {
    for (final list in _cardsBySubject.values) {
      final i = list.indexWhere((c) => c.id == id);
      if (i >= 0) return list[i];
    }
    return null;
  }

  void _setCardStatus(String id, CardStatus status) {
    for (final list in _cardsBySubject.values) {
      final i = list.indexWhere((c) => c.id == id);
      if (i >= 0) {
        final c = list[i];
        list[i] = FlashCard(
          id: c.id,
          subjectId: c.subjectId,
          type: c.type,
          front: c.front,
          back: c.back,
          anchor: c.anchor,
          source: c.source,
          status: status,
          tags: c.tags,
        );
        return;
      }
    }
  }

  Map<String, dynamic> _setStatus(String id, CardStatus status) {
    if (_cardOf(id) == null) throw ApiException(404, '卡不存在');
    if (_cardOf(id)!.status != CardStatus.pending) {
      throw ApiException(400, '仅 pending 可操作');
    }
    _setCardStatus(id, status);
    if (status == CardStatus.active) {
      _memory[id] = CardMemoryState(
        state: SchedulingState.newCard,
        dueAt: DateTime.now(),
        stability: 0,
        difficulty: 0,
        reps: 0,
        lapses: 0,
        lastReviewedAt: null,
      );
    }
    _dataVersion++;
    return {'ok': true, 'id': id, 'status': status.name};
  }

  Map<String, dynamic> _editCard(String id, Map<String, dynamic> m) {
    _updateCardFields(
      id,
      front: m['front'] as String?,
      back: m['back'] as String?,
      anchor: m['anchor'] as String?,
    );
    _dataVersion++;
    return {'ok': true, 'id': id, 'card': _cardOf(id)!.toJson()};
  }

  void _updateCardFields(
    String id, {
    String? front,
    String? back,
    String? anchor,
  }) {
    for (final list in _cardsBySubject.values) {
      final i = list.indexWhere((c) => c.id == id);
      if (i >= 0) {
        final c = list[i];
        list[i] = FlashCard(
          id: c.id,
          subjectId: c.subjectId,
          type: c.type,
          front: front ?? c.front,
          back: back ?? c.back,
          anchor: anchor ?? c.anchor,
          source: c.source,
          status: c.status,
          tags: c.tags,
        );
        return;
      }
    }
  }

  int _streak() {
    final days = _reviewLogs
        .map((r) => (r['reviewedAt'] as String).substring(0, 10))
        .toSet();
    final today = DateTime.now();
    var streak = 0;
    for (var i = 0; i < 400; i++) {
      final d = today.subtract(Duration(days: i));
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      if (days.contains(key)) {
        streak++;
      } else if (i == 0) {
        continue;
      } else {
        break;
      }
    }
    return streak;
  }

  List<Map<String, dynamic>> _heatmap() {
    final byDay = <String, int>{};
    for (final r in _reviewLogs) {
      final day = (r['reviewedAt'] as String).substring(0, 10);
      byDay[day] = (byDay[day] ?? 0) + 1;
    }
    return [
      for (final e in byDay.entries) {'day': e.key, 'reviews': e.value},
    ];
  }

  List<Map<String, dynamic>> _forecast() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final counts = List<int>.filled(7, 0);
    for (final c in _allCards()) {
      if (c.status != CardStatus.active) continue;
      final mem = _memory[c.id];
      if (mem == null) continue;
      final diff = mem.dueAt.difference(today).inDays;
      final idx = diff <= 0 ? 0 : (diff >= 7 ? 6 : diff);
      counts[idx]++;
    }
    return [
      for (var i = 0; i < 7; i++)
        {
          'date': '${today.add(Duration(days: i))}'.substring(0, 10),
          'due': counts[i],
        },
    ];
  }

  /// 保留率演示数据：与服务端 retentionStats() 同口径
  /// （≠ again 即保留成功；近1/7/30天三档窗口）
  Map<String, dynamic> _retention() {
    final now = DateTime.now();
    return {
      'windows': [
        for (final d in const [1, 7, 30])
          () {
            final since = now.subtract(Duration(days: d));
            final recent = _reviewLogs
                .where(
                  (r) =>
                      DateTime.parse(r['reviewedAt'] as String).isAfter(since),
                )
                .toList();
            final total = recent.length;
            final again = recent.where((r) => r['rating'] == 'again').length;
            return {
              'days': d,
              'total': total,
              'retained': total - again,
              'rate': total == 0
                  ? null
                  : ((total - again) / total).toStringAsFixed(3),
            };
          }(),
      ],
    };
  }

  Map<String, dynamic> _summary() {
    final now = DateTime.now();
    final since = now.subtract(const Duration(days: 7));
    final recent = _reviewLogs
        .where((r) => DateTime.parse(r['reviewedAt'] as String).isAfter(since))
        .toList();
    final again = recent.where((r) => r['rating'] == 'again').length;
    return {
      'days': 7,
      'totalReviews': recent.length,
      'againCount': again,
      'againRate': recent.isEmpty
          ? 0.0
          : (again / recent.length).toStringAsFixed(3),
      'pendingCards': _allCards()
          .where((c) => c.status == CardStatus.pending)
          .length,
      'pendingRework': _reworkQueue
          .where((r) => r['status'] == 'pending')
          .length,
      'pendingInbox': _inbox.length,
      'byDay': <Map<String, dynamic>>[],
      'bySubject': <Map<String, dynamic>>[],
    };
  }
}
