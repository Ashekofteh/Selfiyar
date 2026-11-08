/// Connectivity detection and reporting service.
///
/// Combines active probing with passive feedback from the HTTP transport layer.
library;

import 'dart:async';
import 'dart:io';

/// Tracks whether the app has an active network connection to the university portal.
class ConnectivityService {
  ConnectivityService({
    this.checkHost,
    bool initialOnline = true,
    this.enablePeriodicProbe = false,
    this.probeInterval = const Duration(seconds: 15),
  }) : _isOnline = initialOnline {
    if (!_isOnline && enablePeriodicProbe) {
      _startOfflineProbe();
    }
  }

  final Future<bool> Function()? checkHost;
  final bool enablePeriodicProbe;
  final Duration probeInterval;

  bool _isOnline;
  final StreamController<bool> _controller = StreamController<bool>.broadcast();
  Future<bool>? _pendingCheck;
  Timer? _offlineProbeTimer;

  /// Whether the device is currently considered online.
  bool get isOnline => _isOnline;

  /// Whether the device is currently considered offline.
  bool get isOffline => !_isOnline;

  /// Stream emitting connectivity transitions (true = online, false = offline).
  Stream<bool> get onConnectivityChanged => _controller.stream;

  /// Passively reports a successful network response.
  void markOnline() {
    _updateState(true);
  }

  /// Passively reports a connection failure (timeout, unreachable socket, etc.).
  void markOffline() {
    _updateState(false);
  }

  /// Directly sets the connectivity state.
  void setOnline(bool online) {
    _updateState(online);
  }

  void _updateState(bool online) {
    if (_isOnline == online) return;
    _isOnline = online;
    if (_isOnline) {
      _stopOfflineProbe();
    } else if (enablePeriodicProbe) {
      _startOfflineProbe();
    }
    _controller.add(online);
  }

  void _startOfflineProbe() {
    _offlineProbeTimer?.cancel();
    _offlineProbeTimer = Timer.periodic(probeInterval, (_) async {
      if (_isOnline) {
        _stopOfflineProbe();
        return;
      }
      await checkConnection();
    });
  }

  void _stopOfflineProbe() {
    _offlineProbeTimer?.cancel();
    _offlineProbeTimer = null;
  }

  /// Actively checks connectivity against the host, deduplicating concurrent checks.
  Future<bool> checkConnection() {
    if (_pendingCheck != null) return _pendingCheck!;
    final check = _doCheckConnection();
    _pendingCheck = check;
    return check.whenComplete(() {
      _pendingCheck = null;
    });
  }

  Future<bool> _doCheckConnection() async {
    final hostChecker = checkHost;
    if (hostChecker != null) {
      final res = await hostChecker();
      _updateState(res);
      return res;
    }

    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      _updateState(_isOnline);
      return _isOnline;
    }

    try {
      final results = await InternetAddress.lookup('nut.uk.ac.ir')
          .timeout(const Duration(seconds: 3));
      final reachable =
          results.isNotEmpty && results.first.rawAddress.isNotEmpty;
      _updateState(reachable);
      return reachable;
    } catch (_) {
      try {
        final fallback = await InternetAddress.lookup('google.com')
            .timeout(const Duration(seconds: 3));
        final reachable =
            fallback.isNotEmpty && fallback.first.rawAddress.isNotEmpty;
        _updateState(reachable);
        return reachable;
      } catch (_) {
        _updateState(false);
        return false;
      }
    }
  }

  /// Closes the connectivity stream and cancels background timers.
  void dispose() {
    _stopOfflineProbe();
    _controller.close();
  }
}
