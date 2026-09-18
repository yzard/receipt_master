import 'dart:convert';

import 'package:flutter/services.dart';

import '../platform/credentials.dart';
import 'backend_connection.dart';

class BackendDefaults {
  final String endpoint, key;
  const BackendDefaults(this.endpoint, this.key);
  factory BackendDefaults.fromJson(Map<String, dynamic> value) =>
      BackendDefaults(
        value['endpoint'] as String? ?? '',
        value['api_key'] as String? ?? '',
      );
  BackendConnection resolve(Map<String, String?> saved) {
    final savedEndpoint = saved['endpoint'];
    final configured =
        (saved['api_key'] ?? '').isNotEmpty ||
        (savedEndpoint != null &&
            savedEndpoint.isNotEmpty &&
            savedEndpoint != 'https://api.openai.com/v1/chat/completions');
    return BackendConnection(
      configured ? savedEndpoint ?? endpoint : endpoint,
      configured ? saved['api_key'] ?? '' : key,
      allowedHttpEndpoint: endpoint,
    );
  }
}

Future<BackendDefaults> loadBackendDefaults() async => BackendDefaults.fromJson(
  jsonDecode(await rootBundle.loadString('resources/backend_defaults.json'))
      as Map<String, dynamic>,
);
Future<BackendConnection> loadBackendConnection() async {
  final defaults = await loadBackendDefaults();
  return defaults.resolve({
    for (final key in ['endpoint', 'api_key'])
      key: await credentialStore.read(key: key),
  });
}
