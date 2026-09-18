import '../domain/models.dart';

/// Clients know only the backend origin and its authentication credential.
class BackendConnection {
  final String endpoint, key;
  final String? allowedHttpEndpoint;
  const BackendConnection(this.endpoint, this.key, {this.allowedHttpEndpoint});
  Uri get endpointUri {
    final value = Uri.tryParse(endpoint);
    final allowed = Uri.tryParse(allowedHttpEndpoint ?? '');
    if (value == null ||
        value.host.isEmpty ||
        value.userInfo.isNotEmpty ||
        (value.scheme != 'https' &&
            !(value.scheme == 'http' &&
                allowed?.scheme == 'http' &&
                value.host == allowed?.host &&
                value.port == allowed?.port))) {
      throw const InputError('请输入有效 HTTPS 后端地址，或使用此安装包预置的本地地址');
    }
    return Uri(
      scheme: value.scheme,
      host: value.host,
      port: value.hasPort ? value.port : null,
      path: '/',
    );
  }

  Uri get uri {
    final origin = endpointUri;
    if (key.trim().isEmpty) throw const InputError('请填写后端访问密钥');
    return origin;
  }
}
