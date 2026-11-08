import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

// The headless hunt's entrypoint, imported for its existence and nothing else.
//
// The native side starts a second engine and names this file as a **string**;
// no Dart code is supposed to call it. That is exactly the problem: a name
// that exists only in Kotlin is invisible to the Dart compiler, and a library
// that nothing imports is never compiled into the app. The native call then
// asks the VM to run a library that is not there — at 16:30, in the
// background, with no screen to say so.
//
// This import is the only edge that puts the file in the program. The
// function's own `@pragma('vm:entry-point')` is what keeps it, and everything
// it reaches, from being shaken out of a release build.
//
// ignore: unused_import
import 'background/hunt_entrypoint.dart';

import 'platform/platform_services.dart';
import 'ui/app_state.dart';
import 'ui/home_shell.dart';
import 'ui/theme.dart';

void main() {
  runApp(const BahonarNutApp());
}

/// The application root.
class BahonarNutApp extends StatefulWidget {
  const BahonarNutApp({super.key, this.services});

  /// Injected in tests; built for Android in the app.
  final AppServices? services;

  @override
  State<BahonarNutApp> createState() => _BahonarNutAppState();
}

class _BahonarNutAppState extends State<BahonarNutApp> {
  late final AppServices _services;
  late final AppState _state;

  @override
  void initState() {
    super.initState();

    // On a device this is the Keystore-backed, preference-backed set. On desktop
    // this is backed by persistent file storage. In a test the services can be
    // supplied, so the UI can be driven without a platform.
    _services = widget.services ?? AppServices.forCurrentPlatform();

    _state = AppState(
      accountStore: _services.accountStore,
      reminderConfigStore: _services.reminderConfigStore,
      huntConfigStore: _services.huntConfigStore,
      credentialStore: _services.credentialStore,
      bankCardStore: _services.bankCardStore,
      plainStore: _services.plainStore,
      // The **shared** mirror: the same store the portal sync writes, the
      // reservations screen reads, and the reminder service digests. A second
      // instance here would leave every one of them looking at an empty store.
      mealStore: _services.mealStore.store,
      menuStore: _services.menuStore.store,
    );

    // The load is started here and **not awaited**, so the first frame is not
    // held up by the disk. The shell arms the reminder alarms when the load
    // finishes, because the configuration only exists then.
    _state.load();

    // The mirror is restored before anything reads it, so the app can answer
    // "what am I collecting" with no network — which is the whole point of
    // the offline-first design.
    _services.mealStore.restore().then((_) => _state.mealsChanged());
    _services.menuStore.restore();
  }

  @override
  void dispose() {
    _state.dispose();
    _services.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _state,
      builder: (context, _) => MaterialApp(
        title: 'سِلفیار',
        debugShowCheckedModeBanner: false,
        theme: buildLightTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: _state.themeMode,
        // Persian is right-to-left, and the layout must follow: an RTL app with an
        // LTR layout mirrors the navigation bar, the back gesture and the text
        // alignment, which is not a detail.
        locale: const Locale('fa', 'IR'),
        supportedLocales: const [Locale('fa', 'IR')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: HomeShell(state: _state, services: _services),
      ),
    );
  }
}
