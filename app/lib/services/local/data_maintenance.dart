/// 数据维护的主 isolate 单飞锁。worker isolate 的 static 状态不共享，
/// 所以调用方必须在第一次 await 前 acquire，并在全部收尾后 release。
/// 身份 token 防止失败的调用或过期任务误释放其他任务持有的锁。
abstract final class DataMaintenance {
  static Object? _token;
  static String? _operation;

  static bool get busy => _token != null;
  static String? get operation => _operation;

  static Object acquire(String operation) {
    if (_token != null) {
      throw StateError('正在${_operation ?? '维护学习数据'}，请稍后再试');
    }
    final token = Object();
    _token = token;
    _operation = operation;
    return token;
  }

  static void release(Object token) {
    if (!identical(_token, token)) return;
    _token = null;
    _operation = null;
  }
}
