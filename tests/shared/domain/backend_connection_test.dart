import 'package:flutter_test/flutter_test.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/data/backend_defaults.dart';

void main() {
  const defaults = BackendDefaults('http://192.168.1.20:5000/');
  test(
    'account authentication and saved legacy path resolve to backend origin',
    () {
      expect(defaults.resolve({}).endpointUri.toString(), defaults.endpoint);
      expect(
        defaults
            .resolve({
              'endpoint': 'http://192.168.1.20:5000/v1/chat/completions',
              'access_token': 'saved',
            })
            .uri
            .toString(),
        defaults.endpoint,
      );
      expect(
        defaults.resolve({
          'endpoint': 'https://example.test/',
          'access_token': 'custom',
        }).key,
        'custom',
      );
    },
  );
  test('HTTP is limited to provisioned host and port; standalone needs authentication', () {
    for (final url in ['http://example.test/', 'http://192.168.1.20:5001/']) {
      expect(
        () => BackendConnection(
          url,
          'key',
          allowedHttpEndpoint: defaults.endpoint,
        ).uri,
        throwsException,
      );
    }
    expect(() => BackendDefaults.fromJson({}).resolve({}).uri, throwsException);
    expect(
      () => const BackendConnection('https://example.test/', '').uri,
      throwsException,
    );
  });
}
