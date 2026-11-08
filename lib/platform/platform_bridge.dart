/// The Dart side of the platform bridge.
///
/// Everything here is a thin adapter over a [MethodChannel]. The *decisions*
/// live in `lib/core`; this file only moves data across the boundary and
/// converts the platform's vocabulary into the domain's.
library;

import 'package:flutter/services.dart';

import '../core/models.dart';
import '../core/platform_stores.dart';
import '../core/session.dart';

/// The platform channel.
class PlatformBridge {
  PlatformBridge({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'ir.ac.uk.bahonar_nut/platform';

  final MethodChannel _channel;

  /// A [SecureCredentialStore] backed by the Android Keystore.
  SecureCredentialStore get credentialStore => _KeystoreCredentialStore(this);

  /// A [PlainStore] backed by SharedPreferences.
  PlainStore get plainStore => _PreferencesStore(this);

  /// Whether the user has granted the notification permission.
  Future<bool> hasNotificationPermission() async =>
      await _call<bool>('notificationPermission') ?? false;

  /// Asks for the notification permission.
  Future<bool> requestNotificationPermission() async =>
      await _call<bool>('requestNotificationPermission') ?? false;

  /// Posts a notification.
  Future<void> postNotification({
    required int id,
    required String title,
    required String body,
    String? deepLink,
  }) async {
    await _call<void>('postNotification', {
      'id': id,
      'title': title,
      'body': body,
      'deepLink': deepLink,
    });
  }

  /// Cancels a notification.
  Future<void> cancelNotification(int id) async {
    await _call<void>('cancelNotification', {'id': id});
  }

  /// Returns the deep link that launched the app from a notification on cold start, if any.
  Future<String?> getInitialDeepLink() async =>
      await _call<String>('getInitialDeepLink');

  /// Whether exact alarms are permitted.
  Future<bool> canScheduleExactAlarms() async =>
      await _call<bool>('canScheduleExactAlarms') ?? false;

  /// Asks for the exact-alarm permission, which opens the system setting.
  Future<bool> requestExactAlarmPermission() async =>
      await _call<bool>('requestExactAlarmPermission') ?? false;

  /// Schedules an exact alarm.
  Future<void> scheduleAlarm({
    required int requestCode,
    required DateTime triggerAt,
    String? payload,
  }) async {
    await _call<void>('scheduleAlarm', {
      'requestCode': requestCode,
      'triggerAtMillis': triggerAt.millisecondsSinceEpoch,
      'payload': payload,
    });
  }

  /// Cancels an alarm.
  Future<void> cancelAlarm(int requestCode) async {
    await _call<void>('cancelAlarm', {'requestCode': requestCode});
  }

  /// Arms the hunt's wake-up for [accountId].
  ///
  /// The hunt's alarm is separate from the reminder alarms, and the account
  /// is part of its identity — so arming one account's hunt does not replace
  /// another's, and cancelling one does not cancel the other.
  Future<void> scheduleHuntAlarm({
    required AccountId accountId,
    required DateTime triggerAt,
  }) async {
    await _call<void>('scheduleHuntAlarm', {
      'accountId': accountId,
      'triggerAtMillis': triggerAt.millisecondsSinceEpoch,
    });
  }

  /// Cancels the hunt's wake-up for [accountId].
  Future<void> cancelHuntAlarm(AccountId accountId) async {
    await _call<void>('cancelHuntAlarm', {'accountId': accountId});
  }

  /// The reminder deliveries the app owes.
  ///
  /// A reminder alarm fires when the app may not be running, and the digest
  /// is composed in Dart — so when the process was dead the alarm fired into
  /// nothing and the reminder was lost without a sound. The native side
  /// records the delivery instead, and the Dart side picks it up when it
  /// next runs.
  ///
  /// This is the **visible catch-up** the risk register asks for: a delivery
  /// that was owed is not forgotten, and the student learns about it.
  Future<List<String>> pendingDeliveries() async {
    final result = await _call<List<Object?>>('pendingDeliveries');
    if (result == null) return const [];
    return result.whereType<String>().toList();
  }

  /// Clears the owed deliveries, after they have been delivered.
  ///
  /// Cleared by the side that knows the outcome — the Dart side, once the
  /// digest has actually been posted. Clearing it in the receiver would
  /// forget a delivery that was handed over and then lost.
  ///
  /// Only the named payloads are cleared, and only their first occurrence: a
  /// live fire records the payload and hands it to the Dart side in the same
  /// breath, so the Dart side delivers it and clears that copy — leaving any
  /// other owed delivery alone.
  Future<void> clearPendingDeliveries(List<String> payloads) async {
    await _call<void>('clearPendingDeliveries', {'payloads': payloads});
  }

  /// The requests the platform made that the Dart side has not answered.
  ///
  /// A hunt wake-up fired with the app killed, and the re-arm after a
  /// reboot. Both were delivered through a channel that only exists while the
  /// app is open, so both were lost — and the reboot one could never arrive
  /// even in principle, because a boot happens with the process dead.
  ///
  /// The native side records them instead, and the Dart side picks them up
  /// when it next runs.
  ///
  /// Each entry is `kind` or `kind:payload`, where the kind is `hunt` or
  /// `rearm`.
  Future<List<String>> pendingRequests() async {
    final result = await _call<List<Object?>>('pendingRequests');
    if (result == null) return const [];
    return result.whereType<String>().toList();
  }

  /// Clears the answered requests, after they have been acted on.
  ///
  /// Only the named entries are cleared, so a request that was recorded and
  /// then failed to act on stays owed.
  Future<void> clearPendingRequests(List<String> entries) async {
    await _call<void>('clearPendingRequests', {'entries': entries});
  }

  /// Whether the app is exempt from battery optimisation.
  ///
  /// Without the exemption, a network read in Doze is **blocked** and does
  /// not fail — it hangs, waiting for the system to open a maintenance
  /// window. Measured on the emulator: a read that should have taken a
  /// second took ten.
  Future<bool> isIgnoringBatteryOptimizations() async =>
      await _call<bool>('isIgnoringBatteryOptimizations') ?? false;

  /// Asks for the battery-optimisation exemption.
  ///
  /// Opens the system setting. The request is never silent: the screen that
  /// asks for it states the reason first.
  Future<bool> requestIgnoreBatteryOptimizations() async =>
      await _call<bool>('requestIgnoreBatteryOptimizations') ?? false;

  /// Starts the hunt's foreground service.
  ///
  /// The service keeps the process alive for the length of the hunt, which a
  /// background job cannot be relied on to do: the system may defer it past
  /// the very cutoff it is trying to hit.
  ///
  /// [payload] identifies the account whose hunt it is, so the Dart side knows
  /// whose configuration to read.
  Future<void> startHuntService({String? payload}) async {
    await _call<void>('startHuntService', {'payload': payload});
  }

  /// Stops the hunt's foreground service.
  ///
  /// Called on every exit path, including a successful purchase: the service
  /// is released the moment there is nothing left to hunt for.
  Future<void> stopHuntService() async {
    await _call<void>('stopHuntService');
  }

  /// Shares text through the platform's native share sheet (SMS, messengers, etc.).
  Future<void> shareText({required String text, String? title}) async {
    await _call<void>('shareText', {
      'text': text,
      'title': title,
    });
  }

  /// Opens the default SMS application with [text] ready to send.
  Future<void> sendSms({required String text}) async {
    await _call<void>('sendSms', {
      'text': text,
    });
  }

  /// Opens a URL in the platform's default web browser.
  Future<void> openUrl(String url) async {
    await _call<void>('openUrl', {
      'url': url,
    });
  }

  /// Reads an encrypted string from the hardware Keystore.
  Future<String?> secureReadString(String key) async =>
      await _call<String>('secureReadString', {'key': key});

  /// Writes an encrypted string to the hardware Keystore.
  Future<void> secureWriteString(String key, String value) async {
    await _call<void>('secureWriteString', {
      'key': key,
      'value': value,
    });
  }

  /// Deletes an encrypted string from the hardware Keystore.
  Future<void> secureDeleteString(String key) async {
    await _call<void>('secureDeleteString', {'key': key});
  }

  /// Authenticates using biometrics (fingerprint/face) or device credentials (PIN/pattern).
  Future<bool> authenticateBiometric({
    String reason = 'تأیید هویت برای استفاده از اطلاعات کارت بانکی',
  }) async {
    try {
      final result = await _call<bool>('authenticateBiometric', {'reason': reason});
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Starts listening for incoming OTP SMS via Android SMS User Consent API.
  Future<bool> startSmsUserConsent() async {
    try {
      final result = await _call<bool>('startSmsUserConsent');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Stops listening for incoming SMS.
  Future<void> stopSmsUserConsent() async {
    try {
      await _call<void>('stopSmsUserConsent');
    } catch (_) {}
  }

  /// Registers a handler for when an OTP SMS is received.
  void onOtpSmsReceived(void Function(String message) handler) {
    _installHandler();
    _otpSmsHandler = handler;
  }

  /// Invokes a platform method, surfacing any failure.
  ///
  /// A silent failure here is the worst kind: the app would appear to have
  /// saved an account or a password when it had not, and the user would only
  /// find out when the app failed to log in later. So the error is re-thrown
  /// with the platform's message attached.
  Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw StateError('platform call "$method" failed: ${e.message}');
    } on MissingPluginException catch (e) {
      throw StateError(
        'platform call "$method" failed: the platform is not available. '
        'This happens in a test, or before the activity is ready. ($e)',
      );
    }
  }

  /// Registers a handler for the platform asking for a hunt.
  ///
  /// The handler is called for the platform's own requests: a hunt, a
  /// reminder alarm that fired, a reboot, and a notification tap.
  ///
  /// The payload distinguishes them. A reminder's payload names a slot
  /// (`lunch`, `evening`); anything else is the platform asking the app to
  /// act on its own state.
  void onHuntRequested(void Function(String? payload) handler) {
    _installHandler();
    _huntHandler = handler;
  }

  /// Registers a handler for the platform saying a permission was answered.
  ///
  /// The permission request returns **before** the system dialog is
  /// answered, so a read straight after the ask reads the old answer. The
  /// platform announces the answer when it is known, and the app re-reads
  /// then — otherwise the app keeps warning about a grant the student has
  /// already given.
  void onPermissionChanged(void Function() handler) {
    _installHandler();
    _permissionHandler = handler;
  }

  void Function(String? payload)? _huntHandler;
  void Function()? _permissionHandler;
  void Function(String message)? _otpSmsHandler;
  bool _handlerInstalled = false;

  /// Installs the channel's method handler, once.
  ///
  /// A method channel has **one** handler: setting a second replaces the
  /// first. So the bridge owns the dispatch and routes each method to the
  /// subscriber that wants it, rather than letting each subscriber claim
  /// the whole channel — which is how one registration used to silence the
  /// other.
  void _installHandler() {
    if (_handlerInstalled) return;
    _handlerInstalled = true;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'huntRequested':
        case 'reminderFired':
        case 'deepLink':
          _huntHandler?.call(call.arguments as String?);
        case 'rebootCompleted':
          _huntHandler?.call(null);
        case 'permissionChanged':
          _permissionHandler?.call();
        case 'onOtpSmsReceived':
        case 'otpSmsReceived':
          final msg = call.arguments as String?;
          if (msg != null) _otpSmsHandler?.call(msg);
      }
      return null;
    });
  }
}

/// A [SecureCredentialStore] on the Android Keystore.
class _KeystoreCredentialStore implements SecureCredentialStore {
  _KeystoreCredentialStore(this._bridge);

  final PlatformBridge _bridge;

  @override
  Future<Credentials?> read(AccountId accountId) async {
    final result = await _bridge._call<Map<Object?, Object?>>(
      'secureRead',
      {'accountId': accountId},
    );
    if (result == null) return null;
    final studentId = result['studentId'];
    final password = result['password'];
    if (studentId is! String || password is! String) return null;
    return Credentials(studentId: studentId, password: password);
  }

  @override
  Future<void> write(AccountId accountId, Credentials credentials) async {
    await _bridge._call<void>('secureWrite', {
      'accountId': accountId,
      'studentId': credentials.studentId,
      'password': credentials.password,
    });
  }

  @override
  Future<void> delete(AccountId accountId) async {
    await _bridge._call<void>('secureDelete', {
      'accountId': accountId,
    });
  }

  @override
  Future<List<AccountId>> listAccountIds() async {
    final result = await _bridge._call<List<Object?>>('secureList');
    if (result == null) return const [];
    return result.whereType<String>().toList();
  }
}

/// A [PlainStore] on SharedPreferences.
class _PreferencesStore implements PlainStore {
  _PreferencesStore(this._bridge);

  final PlatformBridge _bridge;

  @override
  Future<String?> readString(String key) async =>
      await _bridge._call<String>('plainReadString', {'key': key});

  @override
  Future<void> writeString(String key, String? value) async {
    await _bridge._call('plainWriteString', {
      'key': key,
      'value': value,
    });
  }

  @override
  Future<int?> readInt(String key) async =>
      await _bridge._call<int>('plainReadInt', {'key': key});

  @override
  Future<void> writeInt(String key, int value) async {
    await _bridge._call<void>('plainWriteInt', {
      'key': key,
      'value': value,
    });
  }

  @override
  Future<bool?> readBool(String key) async =>
      await _bridge._call<bool>('plainReadBool', {'key': key});

  @override
  Future<void> writeBool(String key, bool value) async {
    await _bridge._call<void>('plainWriteBool', {
      'key': key,
      'value': value,
    });
  }

  @override
  Future<void> remove(String key) async {
    await _bridge._call<void>('plainRemove', {'key': key});
  }

  @override
  Future<Set<String>> keys() async {
    final result = await _bridge._call<List<Object?>>('plainKeys');
    if (result == null) return <String>{};
    return result.whereType<String>().toSet();
  }
}
