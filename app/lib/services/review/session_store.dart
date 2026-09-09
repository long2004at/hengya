// 复习会话状态 —— 离线评分队列的 UI 观察面（13.6）
// 轻量 ChangeNotifier：ApiClient 的补传队列变化 → 各页 AppBar 角标
import 'package:flutter/foundation.dart';

class SessionStore extends ChangeNotifier {
  int _pendingCount = 0;

  /// 当前待补传评分数（AppBar 显示"待补传 N"）
  int get pendingCount => _pendingCount;

  void updatePending(int count) {
    if (_pendingCount == count) return;
    _pendingCount = count;
    notifyListeners();
  }
}
