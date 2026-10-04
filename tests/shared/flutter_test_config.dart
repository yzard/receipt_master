import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:receipt_master/l10n/catalog.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Read the same backend-owned resource used by all production clients.
  TranslationCatalog.instance.install(
    jsonDecode(
      File('../../src/backend_api/resources/localizations.json')
          .readAsStringSync(),
    ),
  );
  await testMain();
}
