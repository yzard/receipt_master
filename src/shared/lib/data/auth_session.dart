import 'network_error.dart';

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
  String? _savedHttpEndpoint;
  int expiresAt = 0;
  Future<void>? _refreshing;
  int _epoch = 0;
  Future<void> restore({required bool refreshOnline}) async {
    final defaults = await loadDefaults();
    final savedEndpoint = await credentialStore.read(key: 'endpoint');
    endpoint = savedEndpoint ?? defaults.endpoint;
    _savedHttpEndpoint = Uri.tryParse(savedEndpoint ?? '')?.scheme == 'http'
        ? savedEndpoint
        : null;
    refreshToken = await credentialStore.read(key: 'refresh_token') ?? '';
    if (refreshToken.isNotEmpty) {
      try {
        final saved = await credentialStore.read(key: 'account');
        if (saved != null) {
          final value = jsonDecode(saved);
          if (value is Map &&
              value['user_id'] is String &&
              value['username'] is String &&
              value['must_change_password'] is bool) {
            user = Map<String, dynamic>.from(value);
          } else {
            await credentialStore.delete(key: 'account');
          }
        }
      } on FormatException {
        await credentialStore.delete(key: 'account');
      }
    }
    await credentialStore.delete(key: 'api_key');
    if (refreshOnline && refreshToken.isNotEmpty) {
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
      allowedHttpEndpoint: _savedHttpEndpoint ?? defaults.endpoint,
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
    Future<http.Response> send(String access) => client
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'X-Receipt-Client': 'mobile',
            if (authenticated) 'Authorization': 'Bearer $access',
          },
          body: jsonEncode(
            path == 'logout' ? {'refresh_token': refreshToken} : data,
          ),
        )
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () => throw RequestTimeout(),
        );
    final response = authenticated
        ? await authorizedResponse(send)
        : await send(token);
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw AuthenticationError(
        response.statusCode,
        body['error']?['message'] ?? '认证请求失败',
      );
    }
    return body;
  }

  Future<http.Response> authorizedResponse(
    Future<http.Response> Function(String) send,
  ) async {
    final epoch = _epoch;
    final rejectedToken = token;
    final response = await send(rejectedToken);
    if (response.statusCode != 401 || epoch != _epoch) return response;
    final fresh = await recoverAuthentication(rejectedToken);
    if (epoch != _epoch) throw const InputError('账户已变更');
    return send(fresh.key);
  }

  Future<void> accept(dynamic body) async {
    token = body['access_token'];
    refreshToken = body['refresh_token'];
    expiresAt =
        DateTime.now().millisecondsSinceEpoch +
        (body['expires_in'] as int) * 1000;
    user = Map<String, dynamic>.from(body['user']);
    await credentialStore.write(key: 'endpoint', value: endpoint);
    _savedHttpEndpoint = Uri.tryParse(endpoint)?.scheme == 'http'
        ? endpoint
        : null;
    await credentialStore.write(key: 'refresh_token', value: refreshToken);
    await credentialStore.write(key: 'account', value: jsonEncode(user));
    await credentialStore.delete(key: 'refresh_request_key');
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
      final key =
          await credentialStore.read(key: 'refresh_request_key') ?? newId();
      if (epoch != _epoch) throw const InputError('账户已变更');
      await credentialStore.write(key: 'refresh_request_key', value: key);
      if (epoch != _epoch) throw const InputError('账户已变更');
      final body = await call('refresh', {
        'refresh_token': refreshToken,
        'request_key': key,
      });
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
      allowedHttpEndpoint: _savedHttpEndpoint ?? defaults.endpoint,
    );
  }

  Future<BackendConnection> recoverAuthentication(String rejectedToken) async {
    if (token == rejectedToken) await refresh();
    return connection();
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
    await credentialStore.delete(key: 'account');
    await credentialStore.delete(key: 'refresh_request_key');
    notifyListeners();
  }

  Future<List<Map<String, dynamic>>> users() async {
    final c = await connection();
    final response = await authorizedResponse(
      (access) => client
          .get(
            c.uri.resolve('/api/auth/users'),
            headers: {'Authorization': 'Bearer $access'},
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw RequestTimeout(),
          ),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
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
    final response = await authorizedResponse(
      (access) => client
          .delete(
            c.uri.resolve('/api/auth/users/$id'),
            headers: {'Authorization': 'Bearer $access'},
          )
          .timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw RequestTimeout(),
          ),
    );
    if (response.statusCode != 200) {
      throw InputError(
        jsonDecode(response.body)['error']?['message'] ?? '无法删除用户',
      );
    }
  }
}
