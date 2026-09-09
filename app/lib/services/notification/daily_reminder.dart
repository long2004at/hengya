// 每日本地提醒服务（M3，计划书 13.2：防断签兜底）
//
// flutter_local_notifications zonedSchedule 每日固定时间触发；
// 不依赖 FCM/服务器——国产 ROM 无推送也能到点提醒。
// 国产 ROM 注意：需引导用户开启「自启动 + 通知权限」（首次注册时弹提示）。
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class DailyReminder {
  DailyReminder._();

  static final DailyReminder instance = DailyReminder._();

  static const _keyEnabled = 'hengya.reminder.enabled';
  static const _keyHour = 'hengya.reminder.hour';
  static const _keyMinute = 'hengya.reminder.minute';

  static const _channelId = 'hengya.daily';
  static const _channelName = '每日复习提醒';

  final _plugin = FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// 默认提醒时间：20:30（晚自习前后，留足当天复习窗口）
  static const defaultHour = 20;
  static const defaultMinute = 30;

  Future<void> ensureInit() async {
    if (_initialized) return;
    tzdata.initializeTimeZones();
    // Android 需要 permit；iOS 请求通知权限
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );
    _initialized = true;
  }

  /// 读取用户设置（开关 + 时刻）；未设置过 → 默认开 20:30
  Future<({bool enabled, int hour, int minute})> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      enabled: prefs.getBool(_keyEnabled) ?? true,
      hour: prefs.getInt(_keyHour) ?? defaultHour,
      minute: prefs.getInt(_keyMinute) ?? defaultMinute,
    );
  }

  /// 应用设置并（重）注册每日提醒
  Future<void> apply({required bool enabled, int? hour, int? minute}) async {
    await ensureInit();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyEnabled, enabled);
    final h = hour ?? (prefs.getInt(_keyHour) ?? defaultHour);
    final m = minute ?? (prefs.getInt(_keyMinute) ?? defaultMinute);
    await prefs.setInt(_keyHour, h);
    await prefs.setInt(_keyMinute, m);

    await _plugin.cancel(0); // 幂等：先取消旧计划
    if (!enabled) return;

    await _plugin.zonedSchedule(
      0,
      _channelName,
      '今天的卡片到期了，来恒牙复习吧',
      _nextInstanceOf(h, m),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time, // 每日重复
    );
  }

  /// 计算下一次触发时刻（已过今天 h:m 则排明天；返回本地时区 TZDateTime）
  tz.TZDateTime _nextInstanceOf(int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    return scheduled;
  }
}

/// 设置页入口（简版）：开关 + 时刻选择
class ReminderSettingsSheet extends StatefulWidget {
  const ReminderSettingsSheet({super.key});

  @override
  State<ReminderSettingsSheet> createState() => _ReminderSettingsSheetState();
}

class _ReminderSettingsSheetState extends State<ReminderSettingsSheet> {
  bool _enabled = true;
  TimeOfDay _time = const TimeOfDay(hour: DailyReminder.defaultHour,
      minute: DailyReminder.defaultMinute);
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = await DailyReminder.instance.loadSettings();
    setState(() {
      _enabled = s.enabled;
      _time = TimeOfDay(hour: s.hour, minute: s.minute);
      _loaded = true;
    });
  }

  Future<void> _save() async {
    await DailyReminder.instance.apply(
      enabled: _enabled,
      hour: _time.hour,
      minute: _time.minute,
    );
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('每日提醒',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  '到点本地通知，不联网也能提醒；部分手机需允许「自启动/通知」权限',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('开启提醒'),
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('提醒时间'),
                  trailing: Text(
                    _time.format(context),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  onTap: _enabled
                      ? () async {
                          final picked = await showTimePicker(
                            context: context,
                            initialTime: _time,
                          );
                          if (picked != null) setState(() => _time = picked);
                        }
                      : null,
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _save,
                    child: const Text('保存'),
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
    );
  }
}
