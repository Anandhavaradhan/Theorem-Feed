/// Keeps the app working while it is in the background or the screen is off.
///
/// The work itself (finding videos, reading a PDF) stays in the app; an Android
/// foreground service just keeps the process alive, with a wake lock and a
/// Wi-Fi lock, and shows a notification with the progress and a Stop button.
/// Swiping the app away from recent apps stops it (the next start continues).
library;

import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';

abstract class BackgroundKeeper {
  /// Called when the work starts; [onStop] is called if Stop is pressed in the notification.
  Future<void> start({required String title, required String text, required void Function() onStop});
  Future<void> update(String text);
  Future<void> stop();
}

/// For tests and platforms without a foreground service.
class NoBackgroundKeeper implements BackgroundKeeper {
  @override
  Future<void> start({required String title, required String text, required void Function() onStop}) async {}
  @override
  Future<void> update(String text) async {}
  @override
  Future<void> stop() async {}
}

const _stopButtonId = 'stop';

@pragma('vm:entry-point')
void _keepAliveCallback() => FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());

/// Runs beside the app while the service is on; only relays the Stop button
/// and opens the app when the notification is tapped.
class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
  @override
  void onNotificationButtonPressed(String id) {
    if (id == _stopButtonId) FlutterForegroundTask.sendDataToMain(_stopButtonId);
  }

  @override
  void onNotificationPressed() => FlutterForegroundTask.launchApp();
}

class ForegroundServiceKeeper implements BackgroundKeeper {
  ForegroundServiceKeeper() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'finding_videos',
        channelName: 'Finding videos',
        channelDescription: 'Shown while TheoremFeed finds videos or reads a PDF in the background.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        allowWakeLock: true, // keep working with the screen off
        allowWifiLock: true,
        stopWithTask: true,
      ),
    );
    FlutterForegroundTask.addTaskDataCallback(_onData);
  }

  void Function()? _onStop;
  var _asked = false;

  void _onData(Object data) {
    if (data == _stopButtonId) _onStop?.call();
  }

  @override
  Future<void> start({required String title, required String text, required void Function() onStop}) async {
    _onStop = onStop;
    try {
      if (!_asked) {
        _asked = true;
        // Android 13+: the notification needs permission; and to keep working with
        // the screen off, Android asks once to let the app run in the background.
        if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
          await FlutterForegroundTask.requestNotificationPermission();
        }
        if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
        }
      }
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
        return;
      }
      await FlutterForegroundTask.startService(
        serviceId: 7,
        notificationTitle: title,
        notificationText: text,
        notificationButtons: const [NotificationButton(id: _stopButtonId, text: 'Stop')],
        callback: _keepAliveCallback,
      );
    } catch (_) {
      // No background service (e.g. permission refused): the work still runs while the app is open.
    }
  }

  @override
  Future<void> update(String text) async {
    try {
      await FlutterForegroundTask.updateService(notificationText: text);
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    _onStop = null;
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}
  }
}
