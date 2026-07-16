import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

@immutable
final class BackgroundTaskNotificationData {
  const BackgroundTaskNotificationData({
    required this.taskKey,
    required this.operation,
    required this.title,
    required this.message,
    required this.progress,
    required this.speed,
    required this.isPaused,
    required this.isError,
    this.estimatedRemaining,
    this.hasDeterminateProgress = true,
  });

  final String taskKey;
  final String operation;
  final String title;
  final String message;
  final double progress;
  final int speed;
  final bool isPaused;
  final bool isError;
  final Duration? estimatedRemaining;
  final bool hasDeterminateProgress;
}

@visibleForTesting
String buildBackgroundTaskNotificationTitle(
  BackgroundTaskNotificationData data,
) {
  final title = data.title.trim();
  final operation = translateBackgroundTaskProgressText(data.operation);
  return title.isEmpty ? operation : '$operation: $title';
}

@visibleForTesting
String buildBackgroundTaskNotificationBody(
  BackgroundTaskNotificationData data,
) {
  final parts = <String>[];
  if (data.hasDeterminateProgress && data.progress.isFinite) {
    final percent = (data.progress.clamp(0.0, 1.0) * 100).floor();
    parts.add('$percent%');
  }
  final message = translateBackgroundTaskProgressText(data.message.trim());
  if (message.isNotEmpty) parts.add(message);
  if (data.speed > 0) parts.add('${bytesToReadableString(data.speed)}/s');
  final remaining = data.estimatedRemaining;
  if (remaining != null && remaining > Duration.zero) {
    parts.add(
      '${_translateBackgroundTaskKey('Remaining')} ${_formatRemaining(remaining)}',
    );
  }
  return parts.isEmpty
      ? translateBackgroundTaskProgressText(data.operation)
      : parts.join(' - ');
}

const _backgroundTaskProgressKeys = <String>[
  'Preparing compression...',
  'Compression complete',
  'Waiting to compress',
  'Writing compressed file',
  'Verifying compressed file',
  'Opening compressed comic',
  'Cleaning source files',
  'Checking source files',
  'Scanning files',
  'Preparing comic',
  'Fetching comic info...',
  'Downloading cover...',
  'Fetching image list',
  'Downloading...',
  'Resuming...',
  'Compressing',
  'Downloading',
  'Paused',
  'Skipped',
  'Error',
];

String translateBackgroundTaskProgressText(
  String value, {
  String Function(String key)? translate,
}) {
  if (value.isEmpty) return value;
  final translateKey = translate ?? _translateBackgroundTaskKey;
  return value
      .split('\n')
      .map((line) {
        for (final key in _backgroundTaskProgressKeys) {
          if (line == key) return translateKey(key);
          if (line.startsWith('$key ')) {
            return '${translateKey(key)}${line.substring(key.length)}';
          }
          if (line.startsWith('$key:')) {
            return '${translateKey(key)}${line.substring(key.length)}';
          }
        }
        return line;
      })
      .join('\n');
}

String _translateBackgroundTaskKey(String key) {
  try {
    return key.tl;
  } catch (_) {
    // Translation assets are not initialized in headless isolates and unit tests.
    return key;
  }
}

String _formatRemaining(Duration value) {
  final seconds = value.inSeconds.clamp(0, const Duration(days: 7).inSeconds);
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final remainder = seconds % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${remainder.toString().padLeft(2, '0')}';
  }
  return '$minutes:${remainder.toString().padLeft(2, '0')}';
}

/// Keeps Android download and compression work in a data-sync foreground
/// service. Other platforms retain the same task queue without notifications.
final class BackgroundTaskNotificationService {
  BackgroundTaskNotificationService._();

  static final instance = BackgroundTaskNotificationService._();

  static const _notificationId = 4101;
  static const _channelId = 'venera_background_tasks';
  static const _updateInterval = Duration(milliseconds: 350);
  static const _methodChannel = MethodChannel('venera/method_channel');

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  Future<void> _operations = Future<void>.value();
  Timer? _updateTimer;
  BackgroundTaskNotificationData? _pendingData;
  String? _currentTaskKey;
  bool _initialized = false;
  bool _permissionRequested = false;
  bool _serviceRunning = false;
  BackgroundTaskNotificationPermission _permission =
      BackgroundTaskNotificationPermission.unknown;
  Future<bool>? _permissionCheck;

  BackgroundTaskNotificationPermission get permission => _permission;

  bool get notificationNeedsAttention =>
      backgroundTaskNotificationNeedsAttention(App.isAndroid, _permission);

  Future<void> initialize() async {
    if (!App.isAndroid || _initialized) return;
    try {
      const settings = InitializationSettings(
        android: AndroidInitializationSettings('ic_stat_venera'),
      );
      await _notifications.initialize(settings: settings);
      _initialized = true;
    } catch (error, stackTrace) {
      Log.error(
        'BackgroundTask',
        'Notification initialization failed: $error',
        stackTrace,
      );
    }
  }

  Future<bool> refreshPermissionStatus() {
    return ensurePermission(requestIfNeeded: false);
  }

  Future<bool> ensurePermission({bool requestIfNeeded = true}) {
    if (!App.isAndroid) return Future<bool>.value(true);
    final pending = _permissionCheck;
    if (pending != null) return pending;
    final check = _ensurePermission(requestIfNeeded: requestIfNeeded);
    _permissionCheck = check;
    return check.whenComplete(() {
      if (identical(_permissionCheck, check)) _permissionCheck = null;
    });
  }

  Future<bool> _ensurePermission({required bool requestIfNeeded}) async {
    try {
      final plugin = await _androidPlugin();
      if (plugin == null) {
        _setPermission(BackgroundTaskNotificationPermission.error);
        return false;
      }
      var enabled = await plugin.areNotificationsEnabled() == true;
      if (!enabled && requestIfNeeded && !_permissionRequested) {
        _permissionRequested = true;
        enabled = await plugin.requestNotificationsPermission() == true;
        if (!enabled) {
          enabled = await plugin.areNotificationsEnabled() == true;
        }
      }
      if (enabled && await _isChannelDisabled(plugin)) {
        _setPermission(BackgroundTaskNotificationPermission.channelDisabled);
        return false;
      }
      _setPermission(
        enabled
            ? BackgroundTaskNotificationPermission.enabled
            : BackgroundTaskNotificationPermission.disabled,
      );
      return enabled;
    } catch (error, stackTrace) {
      _setPermission(BackgroundTaskNotificationPermission.error);
      Log.error(
        'BackgroundTask',
        'Notification permission check failed: $error',
        stackTrace,
      );
      return false;
    }
  }

  Future<void> openNotificationSettings() async {
    if (!App.isAndroid) return;
    try {
      await _methodChannel.invokeMethod<void>('openNotificationSettings', {
        'channelId': _channelId,
      });
    } catch (error, stackTrace) {
      Log.error(
        'BackgroundTask',
        'Opening notification settings failed: $error',
        stackTrace,
      );
    } finally {
      await refreshPermissionStatus();
    }
  }

  Future<bool> _isChannelDisabled(
    AndroidFlutterLocalNotificationsPlugin plugin,
  ) async {
    final channels = await plugin.getNotificationChannels();
    final channel = channels
        ?.where((item) => item.id == _channelId)
        .firstOrNull;
    return channel?.importance == Importance.none;
  }

  void _setPermission(BackgroundTaskNotificationPermission value) {
    if (_permission == value) return;
    _permission = value;
    permissionChanges.value = value;
  }

  final ValueNotifier<BackgroundTaskNotificationPermission> permissionChanges =
      ValueNotifier(BackgroundTaskNotificationPermission.unknown);

  void setCurrentTaskKey(String? value) {
    if (_currentTaskKey == value) return;
    _currentTaskKey = value;
    _pendingData = null;
    _updateTimer?.cancel();
    _updateTimer = null;
    if (value == null) {
      _enqueue(_stopService);
    }
  }

  void report(BackgroundTaskNotificationData data) {
    if (!App.isAndroid || data.taskKey != _currentTaskKey) return;
    _pendingData = data;
    if (data.isPaused || data.isError) {
      _updateTimer?.cancel();
      _updateTimer = null;
      _enqueue(_stopService);
      return;
    }
    if (_updateTimer != null) return;
    _updateTimer = Timer(_serviceRunning ? _updateInterval : Duration.zero, () {
      _updateTimer = null;
      final latest = _pendingData;
      if (latest != null) _enqueue(() => _show(latest));
    });
  }

  void clear(String taskKey) {
    if (_currentTaskKey != taskKey) return;
    setCurrentTaskKey(null);
  }

  void _enqueue(Future<void> Function() operation) {
    _operations = _operations
        .catchError((_) {})
        .then((_) => operation())
        .catchError((Object error, StackTrace stackTrace) {
          Log.error('BackgroundTask', error, stackTrace);
        });
  }

  Future<AndroidFlutterLocalNotificationsPlugin?> _androidPlugin() async {
    await initialize();
    if (!_initialized) return null;
    return _notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
  }

  Future<void> _show(BackgroundTaskNotificationData data) async {
    if (data.taskKey != _currentTaskKey || data.isPaused || data.isError) {
      return;
    }
    final plugin = await _androidPlugin();
    if (plugin == null || data.taskKey != _currentTaskKey) return;
    await ensurePermission();
    if (data.taskKey != _currentTaskKey) return;
    final determinate = data.hasDeterminateProgress && data.progress.isFinite;
    final progress = determinate
        ? (data.progress.clamp(0.0, 1.0) * 1000).round()
        : 0;
    final details = AndroidNotificationDetails(
      _channelId,
      'Downloads and compression',
      channelDescription:
          'Shows live progress while downloading or compressing comics.',
      importance: Importance.low,
      priority: Priority.low,
      onlyAlertOnce: true,
      ongoing: true,
      autoCancel: false,
      showProgress: true,
      maxProgress: 1000,
      progress: progress,
      indeterminate: !determinate,
      showWhen: false,
    );
    try {
      await plugin.startForegroundService(
        id: _notificationId,
        title: buildBackgroundTaskNotificationTitle(data),
        body: buildBackgroundTaskNotificationBody(data),
        notificationDetails: details,
        payload: '/downloads',
        startType: AndroidServiceStartType.startSticky,
        foregroundServiceTypes: const {
          AndroidServiceForegroundType.foregroundServiceTypeDataSync,
        },
      );
      await _notifications.show(
        id: _notificationId,
        title: buildBackgroundTaskNotificationTitle(data),
        body: buildBackgroundTaskNotificationBody(data),
        notificationDetails: NotificationDetails(android: details),
        payload: '/downloads',
      );
      _serviceRunning = true;
      if (await _isChannelDisabled(plugin)) {
        _setPermission(BackgroundTaskNotificationPermission.channelDisabled);
      } else {
        _setPermission(BackgroundTaskNotificationPermission.enabled);
      }
    } catch (_) {
      _setPermission(BackgroundTaskNotificationPermission.error);
      rethrow;
    }
  }

  Future<void> _stopService() async {
    _pendingData = null;
    final plugin = await _androidPlugin();
    await plugin?.stopForegroundService();
    await _notifications.cancel(id: _notificationId);
    _serviceRunning = false;
  }
}

@visibleForTesting
bool backgroundTaskNotificationNeedsAttention(
  bool isAndroid,
  BackgroundTaskNotificationPermission permission,
) {
  return isAndroid &&
      permission != BackgroundTaskNotificationPermission.unknown &&
      permission != BackgroundTaskNotificationPermission.enabled;
}

enum BackgroundTaskNotificationPermission {
  unknown,
  enabled,
  disabled,
  channelDisabled,
  error,
}
