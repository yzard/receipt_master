import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../platform/credentials.dart';
import '../domain/models.dart';
import 'backend_connection.dart';
import 'backend_defaults.dart';

class AuthenticationError implements Exception {
  const AuthenticationError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => message;
}

class AuthSession extends ChangeNotifier {
  AuthSession(this.client, {this.loadDefaults = loadBackendDefaults});
  final Future<BackendDefaults> Function() loadDefaults;
  static final instance = AuthSession(http.Client());
  final http.Client client;
  Map<String, dynamic>? user;
  String endpoint = '', token = '', refreshToken = '';
  int expiresAt = 0;
  Future<void>? _refreshing;
  int _epoch = 0;
  Future<void> restore() async {
    final defaults = await loadDefaults();
    endpoint = await credentialStore.read(key: 'endpoint') ?? defaults.endpoint;
    refreshToken = await credentialStore.read(key: 'refresh_token') ?? '';
    await credentialStore.delete(key: 'api_key');
    if (refreshToken.isNotEmpty) {
      try {
        await refresh();
      } on AuthenticationError catch (e) {
        if (e.status == 401) await clear();
      } catch (_) {
        // Keep the secure refresh credential through a network outage.
      }
    }
  }

  Future<Uri> origin() async {
    final defaults = await loadDefaults();
    return BackendConnection(
      endpoint,
      '',
      allowedHttpEndpoint: defaults.endpoint,
    ).endpointUri;
  }

  Future<dynamic> call(
    String path,
    Map<String, dynamic> data, {
    bool authenticated = false,
  }) async {
    final epoch = _epoch;
    final uri = (await origin()).resolve('/api/auth/$path');
    if (epoch != _epoch) throw const InputError('账户已变更');
    final response = await client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'X-Receipt-Client': 'mobile',
            if (authenticated) 'Authorization': 'Bearer $token',
          },
          body: jsonEncode(data),
        )
        .timeout(const Duration(seconds: 30));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401 && authenticated && epoch == _epoch) {
        await clear();
      }
      throw AuthenticationError(
        response.statusCode,
        body['error']?['message'] ?? '认证请求失败',
      );
    }
    return body;
  }

  Future<void> accept(dynamic body) async {
    token = body['access_token'];
    refreshToken = body['refresh_token'];
    expiresAt =
        DateTime.now().millisecondsSinceEpoch +
        (body['expires_in'] as int) * 1000;
    user = Map<String, dynamic>.from(body['user']);
    await credentialStore.write(key: 'endpoint', value: endpoint);
    await credentialStore.write(key: 'refresh_token', value: refreshToken);
    notifyListeners();
  }

  Future<void> login(String address, String username, String password) async {
    final epoch = ++_epoch;
    endpoint = address.trim();
    final body = await call('login', {
      'username': username.trim(),
      'password': password,
    });
    if (epoch == _epoch) await accept(body);
  }

  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);
  Future<void> _refresh() async {
    if (refreshToken.isEmpty) throw const InputError('请先登录');
    final epoch = _epoch;
    try {
      final body = await call('refresh', {'refresh_token': refreshToken});
      if (epoch != _epoch) throw const InputError('账户已变更');
      await accept(body);
    } on AuthenticationError catch (e) {
      if (epoch == _epoch && e.status == 401) await clear();
      rethrow;
    }
  }

  Future<BackendConnection> connection() async {
    if (expiresAt <= DateTime.now().millisecondsSinceEpoch + 60000) {
      await refresh();
    }
    final defaults = await loadDefaults();
    return BackendConnection(
      endpoint,
      token,
      allowedHttpEndpoint: defaults.endpoint,
    );
  }

  Future<void> changePassword(String old, String password) async {
    final epoch = _epoch;
    await connection();
    final body = await call('change-password', {
      'current_password': old,
      'new_password': password,
    }, authenticated: true);
    if (epoch == _epoch) await accept(body);
  }

  Future<void> logout() async {
    final epoch = _epoch;
    try {
      await call('logout', {
        'refresh_token': refreshToken,
      }, authenticated: true);
    } finally {
      if (epoch == _epoch) await clear();
    }
  }

  Future<void> clear() async {
    _epoch++;
    token = '';
    refreshToken = '';
    expiresAt = 0;
    user = null;
    await credentialStore.delete(key: 'refresh_token');
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> users() async {
    final c = await connection();
    final response = await client
        .get(
          c.uri.resolve('/api/auth/users'),
          headers: {'Authorization': 'Bearer ${c.key}'},
        )
        .timeout(const Duration(seconds: 30));
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      if (response.statusCode == 401 && token == c.key) {
        await clear();
      }
      throw InputError(body['error']?['message'] ?? '无法读取用户');
    }
    return (body as List).map((u) => Map<String, dynamic>.from(u)).toList();
  }

  Future<void> createUser(String name, String password) async {
    await connection();
    await call('users', {
      'username': name,
      'password': password,
    }, authenticated: true);
  }

  Future<void> deleteUser(String id) async {
    final c = await connection();
    final response = await client
        .delete(
          c.uri.resolve('/api/auth/users/$id'),
          headers: {'Authorization': 'Bearer ${c.key}'},
        )
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      if (response.statusCode == 401 && token == c.key) {
        await clear();
      }
      throw InputError(
        jsonDecode(response.body)['error']?['message'] ?? '无法删除用户',
      );
    }
  }
}
