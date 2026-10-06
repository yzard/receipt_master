// Run from build/flutter with flutter run -d <simulator-id>
// --target=../../tests/ios/smoke.dart --no-resident.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receipt_master/data/backend_defaults.dart';
import 'package:receipt_master/main.dart' as app;
import 'package:receipt_master/platform/credentials.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final checks = <String>[];
  final key = 'ios-smoke-${DateTime.now().microsecondsSinceEpoch}';
  try {
    await credentialStore.write(key: key, value: 'smoke-value');
    if (await credentialStore.read(key: key) != 'smoke-value') {
      throw StateError('Keychain read/write mismatch');
    }
    await credentialStore.delete(key: key);
    if (await credentialStore.read(key: key) != null) {
      throw StateError('Keychain delete failed');
    }
    checks.add('keychain-write-read-delete');
    final support = await getApplicationSupportDirectory();
    final file = File('${support.path}/$key');
    try {
      await file.writeAsString('persisted', flush: true);
      if (await file.readAsString() != 'persisted') {
        throw StateError('Application storage mismatch');
      }
    } finally {
      if (await file.exists()) await file.delete();
    }
    checks.add('application-storage');
    await getTemporaryDirectory();
    checks.add('temporary-storage');
    if ((await FlutterTimezone.getLocalTimezone()).identifier.isEmpty) {
      throw StateError('Missing device timezone');
    }
    checks.add('device-timezone');
    await loadBackendDefaults();
    checks.add('bundled-defaults');
    // Structured output intentionally excludes connection details and keys.
    debugPrint('IOS_SMOKE_PASS ${jsonEncode(checks)}');
  } catch (error, stack) {
    debugPrint('IOS_SMOKE_FAIL ${error.runtimeType}\n$stack');
    rethrow;
  } finally {
    await credentialStore.delete(key: key);
  }
  await app.main();
}
