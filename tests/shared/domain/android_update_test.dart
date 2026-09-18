import 'package:flutter_test/flutter_test.dart';
import 'package:receipt_master/data/android_update.dart';

void main() {
  final hash = 'a' * 64;
  Map<String, dynamic> artifact(int version) => {
    'version_code': version,
    'version_name': '1.0.0',
    'sha256': hash,
    'bytes': 123,
    'path': '/updates/$hash.apk',
    'package_name': 'com.receiptmaster.receipt_master',
  };
  test('version and APK hash jointly determine updates without downgrades', () {
    final release = AndroidRelease.fromJson(artifact(10001));
    expect(release.isNewerThan(10000, 'b' * 64), isTrue);
    expect(release.isNewerThan(10001, hash), isFalse);
    expect(release.isNewerThan(10001, 'b' * 64), isTrue);
    expect(release.isNewerThan(10002, 'b' * 64), isFalse);
  });
  test('selects matching device ABI and rejects external download paths', () {
    final manifest = {
      'schema_version': 1,
      'variants': {'arm64-v8a': artifact(10001), 'x86_64': artifact(10002)},
    };
    expect(
      selectAndroidRelease(manifest, ['x86_64', 'arm64-v8a']).versionCode,
      10002,
    );
    expect(
      () => selectAndroidRelease(manifest, ['armeabi-v7a']),
      throwsException,
    );
    expect(
      () => AndroidRelease.fromJson({
        ...artifact(10001),
        'path': 'https://other.example/app.apk',
      }),
      throwsException,
    );
    expect(
      () => AndroidRelease.fromJson({...artifact(10001), 'sha256': 'bad'}),
      throwsException,
    );
  });
}
