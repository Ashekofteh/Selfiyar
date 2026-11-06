/// The app's platform services, wired together.
///
/// This is the composition root: it builds the portal client, the session
/// manager, the stores and the snipe engine, and hands the UI a single
/// [AppServices] to work with.
///
/// The separation matters for testability. The UI depends on the *interfaces*
/// in `lib/core`, so a test can supply in-memory stores and a fake portal,
/// while the real app supplies the Keystore-backed ones.
library;

import 'dart:async';

import 'dart:io';
import 'package:flutter/foundation.dart';

import 'desktop_bridge.dart';
import '../adapter/captcha_solver.dart';
import '../adapter/cullinan_client.dart';
import '../core/account_store.dart';
import '../core/bank_card_store.dart';
import '../core/hunt_store.dart';
import '../core/local_meal_store.dart';
import '../core/platform_stores.dart';
import '../core/portal.dart';
import '../core/request_ledger.dart';
import '../core/session.dart';
import '../core/session_manager.dart';
import '../core/serialised_portal_client.dart';
import '../core/snipe_engine.dart';
import '../core/time.dart';
import '../transport/http_transport.dart';
import 'hunt_service.dart';
import 'hunt_schedule_service.dart';
import 'platform_bridge.dart';
import 'reminder_service.dart';
import 'reservation_service.dart';
import 'top_up_service.dart';
import 'app_update_service.dart';

/// The portal's base address.
const String portalBaseUrl = 'https://nut.uk.ac.ir/';

/// Everything the app needs, assembled.
class AppServices {
  AppServices({
    required this.bridge,
    required this.client,
    required this.sessions,
    required this.credentialStore,
    required this.plainStore,
    required this.clock,
    this.requests,
    this.transport,
  });

  /// Builds the real services, backed by the Android platform.
  factory AppServices.forAndroid({
    PlatformBridge? bridge,
    DateTime Function()? now,
  }) {
    final theBridge = bridge ?? PlatformBridge();
    final clock = SyncedServerClock();
    // The ledger is the record of what the app asked the portal for. It is
    // created here and given to the transport, so it counts every request —
    // and the engine reads the same one, so the hunt's budget is measured in
    // the requests the portal actually saw rather than in the polls the app
    // believes it made.
    final requests = RequestLedger();
    // The transport carries the clock so every response can sync it: the
    // portal's `Date` header rides along on the reads the app was making
    // anyway, and a hunt cannot start without a trustworthy server time.
    final transport = PortalTransport(
      baseUri: Uri.parse(portalBaseUrl),
      clock: clock,
      ledger: requests,
    );
    final client = CullinanPortalClient(transport: transport);
    // The serialising wrapper is what every consumer sees, so a read and a
    // write for one account can never interleave. The portal's weekly page
    // chains its weeks through the viewstate, so an operation is several
    // requests, and two overlapping ones would work against a chain the other
    // has already moved along.
    final portal = SerialisedPortalClient(client);
    final credentialStore = theBridge.credentialStore;
    final plainStore = theBridge.plainStore;

    return AppServices(
      bridge: theBridge,
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: PlatformSessionStore(
          secureStore: credentialStore,
          plainStore: plainStore,
        ),
        solver: _SolverAdapter(CaptchaSolver()),
        clock: clock,
      ),
      credentialStore: credentialStore,
      plainStore: plainStore,
      clock: clock,
      requests: requests,
      transport: transport,
    );
  }

  /// Builds the real services for Desktop platforms (Windows, macOS, Linux).
  factory AppServices.forDesktop({
    DesktopPlatformBridge? bridge,
    Directory? storageDirectory,
    DateTime Function()? now,
  }) {
    final theBridge = bridge ?? DesktopPlatformBridge(storageDirectory: storageDirectory);
    final clock = SyncedServerClock();
    final requests = RequestLedger();
    final transport = PortalTransport(
      baseUri: Uri.parse(portalBaseUrl),
      clock: clock,
      ledger: requests,
    );
    final client = CullinanPortalClient(transport: transport);
    final portal = SerialisedPortalClient(client);
    final credentialStore = theBridge.credentialStore;
    final plainStore = theBridge.plainStore;

    return AppServices(
      bridge: theBridge,
      client: portal,
      sessions: SessionManager(
        client: portal,
        store: PlatformSessionStore(
          secureStore: credentialStore,
          plainStore: plainStore,
        ),
        solver: _SolverAdapter(CaptchaSolver()),
        clock: clock,
      ),
      credentialStore: credentialStore,
      plainStore: plainStore,
      clock: clock,
      requests: requests,
      transport: transport,
    );
  }

  /// Automatically selects the correct service implementation based on the host platform.
  factory AppServices.forCurrentPlatform({
    DateTime Function()? now,
  }) {
    if (!kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux || Platform.isIOS)) {
      return AppServices.forDesktop(now: now);
    }
    return AppServices.forAndroid(now: now);
  }

  final PlatformBridge bridge;
  final PortalClient client;
  final SessionManager sessions;
  final SecureCredentialStore credentialStore;
  final PlainStore plainStore;
  final ServerClock clock;

  /// The record of the requests the app has made.
  ///
  /// Exposed so the traffic can be **read back** — the number the portal
  /// sees, per account, per hour. A budget nobody can read is a budget
  /// nobody can check, and this project treats the account as the thing at
  /// risk. Null only in a test that has no transport.
  final RequestLedger? requests;
  final PortalTransport? transport;

  /// Closes network transport sockets and releases resources.
  void dispose() {
    transport?.close();
    if (bridge is DesktopPlatformBridge) {
      (bridge as DesktopPlatformBridge).dispose();
    }
  }

  /// The app update coordinator.
  AppUpdateService get updates => AppUpdateService(plainStore: plainStore);

  /// The account list, persisted in the plain store.
  AccountStore get accountStore => PreferencesAccountStore(plainStore);

  /// The reminder configuration, persisted in the plain store.
  ReminderConfigStore get reminderConfigStore =>
      PreferencesReminderConfigStore(plainStore);

  /// The saved bank cards store, backed by hardware Keystore.
  BankCardStore get bankCardStore => PlatformBankCardStore(
        plainStore: plainStore,
        secureRead: bridge.secureReadString,
        secureWrite: bridge.secureWriteString,
        secureDelete: bridge.secureDeleteString,
      );

  /// The local mirror of held meals.
  ///
  /// A cache of portal state rather than a secret, so it does not need the
  /// Keystore, but it does need to survive a restart for the offline reminders
  /// to work.
  ///
  /// **One instance, owned here.** The store is shared by the sync that writes
  /// it, the UI that reads it, and the reminder service that digests it — so
  /// they must be the *same* object. It was a getter that built a fresh
  /// holder (and a fresh store inside it) on every call, which left the
  /// reservations screen and the reminders permanently empty: the sync filled
  /// one store and the readers looked at another.
  late final LocalMealStoreHolder mealStore = LocalMealStoreHolder(plainStore);

  /// The hunt configuration, persisted in the plain store.
  HuntConfigStore get huntConfigStore => PreferencesHuntConfigStore(plainStore);

  /// The engine that runs the hunt.
  ///
  /// Built here rather than in the UI, so the engine outlives the screen: a
  /// hunt must keep running while the student uses the rest of the app, and
  /// the foreground service is what keeps the process alive for that.
  late final SnipeEngine engine = DefaultSnipeEngine(
    client: client,
    sessions: sessions,
    clock: clock,
    // The same ledger the transport writes to, so the hunt's budget is
    // measured in the requests the portal actually saw.
    requests: requests,
  );

  /// The hunt's platform service: runs the hunt and reports its outcome.
  late final HuntService hunts = HuntService(bridge: bridge, engine: engine);

  /// The hunt's schedule: arms the wake-up that starts the hunt by itself.
  late final HuntScheduleService huntSchedule =
      HuntScheduleService(bridge: bridge);

  /// Books and cancels weekly meals.
  late final ReservationService reservations = ReservationService(
    client: client,
    sessions: sessions,
    mealStore: mealStore.store,
    persist: mealStore.persist,
  );

  /// Starts and settles top-ups.
  late final TopUpService topUp = TopUpService(
    client: client,
    sessions: sessions,
  );

  /// The reminder service: builds digests, posts notifications, arms alarms.
  ///
  /// It reads the **same** store the sync writes. A separate instance here
  /// would make every digest empty, because the digest is built from the
  /// store and the store is what the sync fills.
  late final ReminderService reminders = ReminderService(
    bridge: bridge,
    mealStore: mealStore.store,
  );
}

/// Adapts the CAPTCHA solver to the [ChallengeSolver] interface.
///
/// The solver works on raw bytes and returns a richer result (including a
/// confidence); the interface takes a [LoginChallenge] and returns the answer
/// or null. The adapter keeps the solver's own API untouched, so its tests
/// stay honest, and translates at the boundary.
class _SolverAdapter implements ChallengeSolver {
  _SolverAdapter(this._solver);

  final CaptchaSolver _solver;

  @override
  Future<String?> solve(LoginChallenge challenge) async {
    final solution = _solver.solve(challenge.imageBytes);
    if (!solution.isConfident) return null;
    return solution.text;
  }
}

/// The local meal store, backed by the plain store.
///
/// Holds the **one** [LocalMealStore] the app shares, and keeps it and the
/// disk copy in step.
///
/// ## Why the holder exists rather than the store itself
///
/// The store is a synchronous, in-memory value type — pure Dart, testable on
/// the VM. Reading and writing it is asynchronous, and belongs to the platform
/// layer. The holder is the seam: one object owning both halves, so a caller
/// cannot accidentally hold a store that is not the persisted one.
class LocalMealStoreHolder {
  LocalMealStoreHolder(this._store);

  final PlainStore _store;

  /// The in-memory store the app uses.
  ///
  /// The persisted copy is the same data; this is the live view the reminders
  /// read and the sync updates.
  late final LocalMealStore store = LocalMealStore();

  static const String _key = 'meals.held';

  /// Reads the persisted meals into the live store.
  ///
  /// Called once at startup, before anything reads the store. Without it the
  /// app would start with an empty mirror and report "no reservations" for a
  /// student who has them — the offline-first promise broken at exactly the
  /// moment it matters, which is when the phone has no network.
  Future<void> restore() async {
    final raw = await _store.readString(_key);
    if (raw == null) return;
    try {
      store.replaceAll(decodeMealList(raw));
      store.prune(DateTime.now().toUtc());
    } catch (_) {
      // A corrupt cache is not worth surfacing: the next sync fills it again.
    }
  }

  /// Writes the live store to disk.
  ///
  /// Called after every change, so a restart finds what the app knew. A meal
  /// that passed is still written — the retention policy prunes at read time,
  /// which is a decision made with the whole picture, not a reason to risk
  /// losing the write.
  Future<void> persist() async {
    await _store.writeString(_key, encodeMealList(store.all));
  }
}
