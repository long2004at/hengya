// 恒牙根组件：底部导航四页（科目 / 题库 / 待审核 / 统计）
// M1：go_router 路由（复习会话子页）+ SessionStore 注入（离线补传角标）
// M4：第二 Tab 由「复习」改为「题库」（自由查看全部卡片；复习会话保留在科目页入口）
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'pages/bank_page.dart';
import 'pages/home_page.dart';
import 'pages/pending_page.dart';
import 'pages/progress_page.dart';
import 'pages/review_page.dart';
import 'pages/stats_page.dart';
import 'services/api/api_client.dart';
import 'services/review/session_store.dart';
import 'theme.dart';

final _rootKey = GlobalKey<NavigatorState>();

GoRouter _router(SessionStore store) => GoRouter(
  navigatorKey: _rootKey,
  initialLocation: '/',
  routes: [
    ShellRoute(
      builder: (context, state, child) {
        return _RootShell(child: child);
      },
      routes: [
        GoRoute(path: '/', builder: (context, state) => const HomePage()),
        GoRoute(
          path: '/review-home',
          builder: (context, state) => const ReviewPage(),
          routes: [
            GoRoute(
              path: ':subjectId',
              parentNavigatorKey: _rootKey,
              builder: (context, state) => ReviewSessionPage(
                subjectId: state.pathParameters['subjectId']!,
              ),
            ),
          ],
        ),
        GoRoute(
          path: '/bank',
          builder: (context, state) => const BankPage(),
          routes: [
            GoRoute(
              path: ':cardId',
              parentNavigatorKey: _rootKey,
              builder: (context, state) =>
                  BankDetailPage(cardId: state.pathParameters['cardId']!),
            ),
          ],
        ),
        GoRoute(
          path: '/pending',
          builder: (context, state) => const PendingPage(),
        ),
        GoRoute(path: '/stats', builder: (context, state) => const StatsPage()),
      ],
    ),
    // 学习进度页（§7.5）：顶层路由（根导航器渲染 → 全屏带返回键，
    // 无底部导航壳）——go_router 不允许 ShellRoute 直接子路由指向根键
    GoRoute(
      path: '/progress',
      parentNavigatorKey: _rootKey,
      builder: (context, state) => const ProgressPage(),
    ),
  ],
);

class _RootShell extends StatefulWidget {
  const _RootShell({required this.child});

  final Widget child;

  @override
  State<_RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<_RootShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.toString();
    // 根据路径回算 tab 索引（go_router ShellRoute 无状态恢复）
    final idx = switch (location) {
      String l when l.startsWith('/bank') => 1,
      String l when l.startsWith('/review-home') => 1,
      '/pending' => 2,
      '/stats' => 3,
      _ => 0,
    };
    if (idx != _index) _index = idx;

    return Scaffold(
      body: widget.child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) {
          setState(() => _index = i);
          switch (i) {
            case 0:
              context.go('/');
            case 1:
              context.go('/bank');
            case 2:
              context.go('/pending');
            case 3:
              context.go('/stats');
          }
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: '科目',
          ),
          NavigationDestination(
            icon: Icon(Icons.style_outlined),
            selectedIcon: Icon(Icons.style),
            label: '题库',
          ),
          NavigationDestination(
            icon: Icon(Icons.rate_review_outlined),
            selectedIcon: Icon(Icons.rate_review),
            label: '待审核',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights),
            label: '统计',
          ),
        ],
      ),
    );
  }
}

class HengyaApp extends StatefulWidget {
  const HengyaApp({super.key});

  @override
  State<HengyaApp> createState() => _HengyaAppState();
}

class _HengyaAppState extends State<HengyaApp> {
  late final SessionStore _store;

  @override
  void initState() {
    super.initState();
    _store = SessionStore();
    ApiClient.instance.onQueueChanged = (count) {
      _store.updatePending(count);
    };
    // 打开即拉取（13.6）：先恢复磁盘上的离线评分 → 再尝试批量补传
    ApiClient.instance.restorePendingAnswers().then((_) {
      ApiClient.instance.flushPendingAnswers();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _store,
      child: MaterialApp.router(
        title: '恒牙',
        debugShowCheckedModeBanner: false,
        theme: buildHengyaTheme(),
        routerConfig: _router(_store),
      ),
    );
  }
}
