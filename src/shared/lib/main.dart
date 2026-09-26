import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'data/backend_defaults.dart';

import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:timezone/data/latest.dart' as tzdata;

import 'data/store.dart';
import 'ui/app_theme.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  tzdata.initializeTimeZones();
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
    final appearance = Appearance(root);
    await appearance.load();
    runApp(ReceiptApp(store: store, zone: zone, appearance: appearance));
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(child: Text('无法启动应用，请重试。\n${e.runtimeType}')),
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
    animation: appearance,
    builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Receipt Master',
      theme: receiptTheme(Brightness.light),
      darkTheme: receiptTheme(Brightness.dark),
      themeMode: appearance.mode,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemBars(Theme.of(context).brightness),
        child: child ?? const SizedBox.shrink(),
      ),
      home: HomePage(store: store, zone: zone, appearance: appearance),
    ),
  );
}
