import 'dart:convert';

import 'package:flutter/services.dart';

import 'auth_session.dart';
import 'backend_connection.dart';

class BackendDefaults {
  final String endpoint;
  const BackendDefaults(this.endpoint);
  factory BackendDefaults.fromJson(Map<String, dynamic> value) =>
      BackendDefaults(value['endpoint'] as String? ?? '');
  BackendConnection resolve(Map<String, String?> saved) => BackendConnection(
    saved['endpoint'] ?? endpoint,
    saved['access_token'] ?? '',
    allowedHttpEndpoint: endpoint,
  );
}

Future<BackendDefaults> loadBackendDefaults() async => BackendDefaults.fromJson(
  jsonDecode(await rootBundle.loadString('resources/backend_defaults.json'))
      as Map<String, dynamic>,
);
Future<BackendConnection> loadBackendConnection() =>
    AuthSession.instance.connection();
