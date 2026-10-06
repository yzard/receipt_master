import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'data/backend_defaults.dart';
import 'data/auth_session.dart';
import 'ui/account.dart';

import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:timezone/data/latest.dart' as tzdata;

import 'data/store.dart';
import 'ui/app_theme.dart';
import 'ui/home.dart';
import 'l10n/strings.dart';
import 'l10n/catalog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  tzdata.initializeTimeZones();
  Appearance? appearance;
  try {
    final support = await getApplicationSupportDirectory();
    final root = p.join(support.path, 'receipt-master-cache');
    await Directory(root).create(recursive: true);
    final store = AppStore(
      root,
      client: http.Client(),
      configuration: loadBackendConnection,
    );
    final zone = (await FlutterTimezone.getLocalTimezone()).identifier;
    appearance = Appearance(root);
    await appearance.load();
    await AuthSession.instance.restore(refreshOnline: false);
    runApp(AccountApp(store: store, zone: zone, appearance: appearance));
    if (AuthSession.instance.refreshToken.isNotEmpty) {
      unawaited(AuthSession.instance.refresh().catchError((Object _) {}));
    }
  } catch (e) {
    runApp(
      MaterialApp(
        locale: appearance?.locale ?? const Locale('zh'),
        supportedLocales: ReceiptLocalizations.supportedLocales,
        localizationsDelegates: ReceiptLocalizations.delegates,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: Text(context.tr('无法启动应用，请重试。\n{0}', [e.runtimeType])),
            ),
          ),
        ),
      ),
    );
  }
}

class ReceiptApp extends StatelessWidget {
  final AppStore store;
  final String zone;
  final Appearance appearance;
  const ReceiptApp({
    super.key,
    required this.store,
    required this.zone,
    required this.appearance,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([appearance, TranslationCatalog.instance]),
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Receipt Master',
      theme: receiptTheme(Brightness.light),
      darkTheme: receiptTheme(Brightness.dark),
      themeMode: appearance.mode,
      locale: TranslationCatalog.instance.resolveLocale(appearance.locale),
      supportedLocales: ReceiptLocalizations.supportedLocales,
      localizationsDelegates: ReceiptLocalizations.delegates,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemBars(Theme.of(context).brightness),
        child: child ?? const SizedBox.shrink(),
      ),
      home: HomePage(store: store, zone: zone, appearance: appearance),
    ),
  );
}

class AccountApp extends StatelessWidget {
  final AppStore store;
  final String zone;
  final Appearance appearance;
  const AccountApp({
    super.key,
    required this.store,
    required this.zone,
    required this.appearance,
  });
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([appearance, TranslationCatalog.instance]),
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Receipt Master',
      theme: receiptTheme(Brightness.light),
      darkTheme: receiptTheme(Brightness.dark),
      themeMode: appearance.mode,
      locale: TranslationCatalog.instance.resolveLocale(appearance.locale),
      supportedLocales: ReceiptLocalizations.supportedLocales,
      localizationsDelegates: ReceiptLocalizations.delegates,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemBars(Theme.of(context).brightness),
        child: child ?? const SizedBox.shrink(),
      ),
      home: AccountGate(
        store: store,
        zone: zone,
        appearance: appearance,
        session: AuthSession.instance,
      ),
    ),
  );
}
