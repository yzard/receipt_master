import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../domain/models.dart';
import 'backend_defaults.dart';

const androidUpdateChannel = MethodChannel('receipt_master/android_update');

class AndroidRelease {
  final int versionCode, bytes;
  final String versionName, hash, path, packageName;
  AndroidRelease.fromJson(Map<String, dynamic> json)
    : versionCode = json['version_code'] as int,
      bytes = json['bytes'] as int,
      versionName = json['version_name'] as String,
      hash = json['sha256'] as String,
      path = json['path'] as String,
      packageName = json['package_name'] as String {
    if (versionCode <= 0 ||
        bytes <= 0 ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(hash) ||
        path != '/updates/$hash.apk' ||
        packageName != 'com.receiptmaster.receipt_master') {
      throw const InputError('更新信息无效');
    }
  }
  bool isNewerThan(int installedVersion, String installedHash) =>
      versionCode >= installedVersion && hash != installedHash;
}

AndroidRelease selectAndroidRelease(
  Map<String, dynamic> manifest,
  List<String> abis,
) {
  if (manifest['schema_version'] != 1 || manifest['variants'] is! Map) {
    throw const InputError('更新服务返回了不支持的格式');
  }
  final variants = manifest['variants'] as Map;
  for (final abi in abis) {
    if (variants[abi] is Map<String, dynamic>) {
      return AndroidRelease.fromJson(variants[abi] as Map<String, dynamic>);
    }
  }
  throw const InputError('暂时没有适合此设备的更新包');
}

class AndroidUpdate {
  final Uri origin;
  final AndroidRelease release;
  AndroidUpdate(this.origin, this.release);

  static Future<AndroidUpdate?> check() async {
    final defaults = await loadBackendDefaults();
    if (defaults.key.isEmpty) throw const InputError('此安装包未配置本地更新服务');
    final endpoint = Uri.parse(defaults.endpoint);
    final origin = endpoint.replace(path: '/', query: null, fragment: null);
    final installed = Map<String, dynamic>.from(
      (await androidUpdateChannel.invokeMethod<Map>('installedApp'))!,
    );
    final client = http.Client();
    try {
      final request = http.Request(
        'GET',
        origin.resolve('/android-update.json'),
      )..followRedirects = false;
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw const InputError('无法检查更新，请确认后端已启动');
      final manifest = jsonDecode(
        await response.stream.bytesToString().timeout(
          const Duration(seconds: 20),
        ),
      ) as Map<String, dynamic>;
      final release = selectAndroidRelease(
        manifest,
        List<String>.from(installed['abis'] as List),
      );
      if (!release.isNewerThan(
        installed['version_code'] as int,
        installed['sha256'] as String,
      )) {
        return null;
      }
      return AndroidUpdate(origin, release);
    } finally {
      client.close();
    }
  }

  Future<String> downloadAndInstall(void Function(double) progress) async {
    final directory = Directory(
      '${(await getTemporaryDirectory()).path}/updates',
    );
    await directory.create(recursive: true);
    final file = File('${directory.path}/client.apk');
    final partial = File('${file.path}.part');
    final client = http.Client();
    try {
      final response = await client
          .send(
            http.Request('GET', origin.resolve(release.path))
              ..followRedirects = false,
          )
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) throw const InputError('更新包下载失败，请稍后重试');
      final sink = partial.openWrite();
      var received = 0;
      try {
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (received > release.bytes) throw const InputError('更新包大小不匹配');
          sink.add(chunk);
          progress(received / release.bytes);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (received != release.bytes ||
          (await sha256.bind(partial.openRead()).first).toString() !=
              release.hash) {
        throw const InputError('更新包校验失败，请重新检查更新');
      }
      await partial.rename(file.path);
      return (await androidUpdateChannel.invokeMethod<String>('installUpdate', {
        'path': file.path,
        'sha256': release.hash,
        'version_code': release.versionCode,
      }))!;
    } finally {
      client.close();
      if (await partial.exists()) await partial.delete();
    }
  }
}
