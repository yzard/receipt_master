import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'data/backend_defaults.dart';

import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:timezone/data/latest.dart' as tzdata;

import 'data/store.dart';
import 'ui/common.dart';
import 'ui/home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
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
    runApp(ReceiptApp(store: store, zone: zone));
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
  const ReceiptApp({super.key, required this.store, required this.zone});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Receipt Master',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: ink, surface: paper),
      scaffoldBackgroundColor: paper,
      appBarTheme: const AppBarTheme(
        backgroundColor: paper,
        foregroundColor: ink,
        centerTitle: false,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
      navigationBarTheme: const NavigationBarThemeData(
        backgroundColor: Color(0xFFEEEFE7),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
      ),
    ),
    home: HomePage(store: store, zone: zone),
  );
}
