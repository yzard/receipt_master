import 'network_error.dart';

import 'dart:async';
import 'dart:convert';

import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../domain/models.dart';
import 'backend_connection.dart';

/// The backend owns business records. Devices retain read caches and pending uploads.
class AppStore extends ChangeNotifier {
  final String cacheRoot;
  final http.Client client;
  final Future<BackendConnection> Function() configuration;
  Future<BackendConnection> Function(String)? recoverAuthentication;
  String? offlineMessage;
  int catalogVersion = 0;

  static bool connectionFailure(Object error) =>
      error is TimeoutException ||
      error is SocketException ||
      error is http.ClientException;

  static const cachedReads = {
    'config/get',
    'receipts/list',
    'receipts/get',
    'images/list',
    'receipt_types/list',
    'merchants/list',
    'categories/list',
    'printed_names/list',
    'product_names/list',
    'products/suggest',
    'categories/suggest',
    'product_names/suggest',
    'reports/summary',
    'reports/trend',
    'recognition/get',
  };

  File readCache(String path, Map<String, dynamic> input) => File(
    '$cacheRoot/reads/${sha256.convert(utf8.encode(jsonEncode([path, input])))}.json',
  );

  final _readResponses = <String, String>{};
  Future<void> _cacheWrites = Future.value();
  bool _cacheInvalidated = false;
  Future<void> flushCache() => _cacheWrites;

  void cacheResponse(File file, dynamic data) {
    final encoded = jsonEncode(data);
    _readResponses[file.path] = encoded;
    _cacheWrites = _cacheWrites.then((_) async {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString(encoded, flush: true);
      } on FileSystemException {
        // A cache write must not turn a completed server operation into a failure.
      }
    });
  }

  void invalidateReadCache() {
    _readResponses.clear();
    _cacheInvalidated = true;
    _cacheWrites = _cacheWrites.then((_) async {
      final directory = Directory('$cacheRoot/reads');
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
      } on FileSystemException {
        // Server writes do not depend on cache cleanup.
      }
    });
  }

  Future<String> cachedResponse(File file) async {
    final memory = _readResponses[file.path];
    if (memory != null) return memory;
    if (_cacheInvalidated) {
      throw FileSystemException('Cache invalidated', file.path);
    }
    return file.readAsString();
  }

  String weightUnit = 'kg';
  String reportCurrency = 'USD';
  Future<void> loadPreferences() async {
    final config = await request('config', 'get', {});
    weightUnit = config['weight_unit'];
    reportCurrency = config['report_currency'] ?? 'USD';
  }

  Future<void> saveWeightUnit(String unit) async {
    await request('config', 'save_weight_unit', {
      'weight_unit': unit,
      'expected_version': catalogVersion,
    });
    weightUnit = unit;
  }

  Future<void> saveReportCurrency(String currency) async {
    await request('config', 'save_report_currency', {
      'report_currency': currency,
      'expected_version': catalogVersion,
    });
    reportCurrency = currency;
  }

  final Map<String, int> versions = {};
  final Map<String, Future<Map<String, dynamic>>> uploads = {};
  AppStore(this.cacheRoot, {required this.client, required this.configuration});
  Future<dynamic> request(
    String component,
    String operation,
    Map<String, dynamic> input, {
    String? key,
  }) async {
    final path = '$component/$operation';
    final cache = readCache(path, input);
    try {
      final data = await requestOnline(path, input, key ?? newId());
      offlineMessage = null;
      if (cachedReads.contains(path)) {
        cacheResponse(cache, data);
      } else {
        invalidateReadCache();
      }
      if (data['catalog_version'] is int) {
        catalogVersion = data['catalog_version'];
      }
      return data['data'];
    } catch (error) {
      if (!connectionFailure(error)) rethrow;
      offlineMessage = error is TimeoutException ? 'Timeout' : '网络不可用，显示缓存';
      if (cachedReads.contains(path)) {
        try {
          final data = jsonDecode(await cachedResponse(cache));
          if (data['catalog_version'] is int) {
            catalogVersion = data['catalog_version'];
          }
          return data['data'];
        } on FileSystemException {
          // No cached response is available for this query.
        } on FormatException {
          // Ignore an interrupted cache write.
        }
      }
      throw InputError(offlineMessage!);
    }
  }

  Future<Map<String, dynamic>> requestOnline(
    String path,
    Map<String, dynamic> input,
    String key,
  ) async {
    var config = await configuration();
    for (var attempt = 0; attempt < 2; attempt++) {
      final origin = config.endpointUri.replace(
        path: '/',
        query: '',
        fragment: '',
      );
      if (config.key.isEmpty) throw const InputError('请先登录');
      final req = http.Request('POST', origin.resolve('/api/v1/$path'))
        ..followRedirects = false;
      req.headers.addAll({
        'Authorization': 'Bearer ${config.key}',
        'Content-Type': 'application/json',
      });
      req.body = jsonEncode({'request_key': key, 'input': input});
      final response =
          await http.Response.fromStream(
            await client
                .send(req)
                .timeout(
                  const Duration(seconds: 30),
                  onTimeout: () => throw RequestTimeout(),
                ),
          ).timeout(
            const Duration(minutes: 3),
            onTimeout: () => throw RequestTimeout(),
          );
      if (response.statusCode == 401 &&
          attempt == 0 &&
          recoverAuthentication != null) {
        config = await recoverAuthentication!(config.key);
        continue;
      }
      final data =
          jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw InputError(
          data['error']?['message'] ?? '后端请求失败 ${response.statusCode}',
        );
      }
      return data;
    }
    throw const InputError('请先登录');
  }

  List<Map<String, dynamic>> rows(dynamic value) =>
      (value as List).map((v) => Map<String, dynamic>.from(v)).toList();
  Map<String, dynamic> receipt(dynamic value) {
    final r = Map<String, dynamic>.from(value);
    versions[r['id']] = r['revision'];
    return r;
  }

  Future<List<Map<String, dynamic>>> receiptTypes() async =>
      rows(await request('receipt_types', 'list', {}));
  Future<void> saveReceiptType(String? id, String name) async {
    await request('receipt_types', 'save', {
      'id': id,
      'name': name,
      'expected_version': catalogVersion,
    });
  }

  Future<void> deleteReceiptType(String id) async {
    await request('receipt_types', 'delete', {
      'id': id,
      'expected_version': catalogVersion,
    });
  }

  Future<List<Map<String, dynamic>>> merchants() async =>
      rows(await request('merchants', 'list', {}));
  Future<void> classifyMerchant(String id, String receiptTypeId) async {
    await request('merchants', 'classify', {
      'id': id,
      'receipt_type_id': receiptTypeId,
      'expected_version': catalogVersion,
    });
  }

  Future<List<Map<String, dynamic>>> categories() async =>
      rows(await request('categories', 'list', {}));
  Future<List<Map<String, dynamic>>> searchCatalog(
    String component,
    String query,
  ) async => rows(await request(component, 'suggest', {'query': query}));
  Future<void> saveCategory(String? id, String name, String? parent) async {
    await request('categories', 'save', {
      'id': id,
      'name': name,
      'parent': parent,
      'expected_version': catalogVersion,
    });
  }

  Future<void> deleteCategory(String id) async {
    await request('categories', 'delete', {
      'id': id,
      'expected_version': catalogVersion,
    });
  }

  Future<List<Map<String, dynamic>>> printedNames() async =>
      rows(await request('printed_names', 'list', {}));
  Future<List<Map<String, dynamic>>> productNames() async =>
      rows(await request('product_names', 'list', {}));
  Future<void> classifyProductName(
    String id,
    String value, {
    required bool existing,
  }) async {
    await request('product_names', 'classify', {
      'id': id,
      existing ? 'category_id' : 'category_name': value,
      'expected_version': catalogVersion,
    });
  }

  Future<void> deleteProductName(String id) async {
    await request('product_names', 'delete', {
      'id': id,
      'expected_version': catalogVersion,
    });
  }

  Future<void> saveProductName(String id, String name) async {
    await request('printed_names', 'set_product_name', {
      'id': id,
      'name': name,
      'expected_version': catalogVersion,
    });
  }

  Future<List<Map<String, dynamic>>> suggest(String name) async =>
      rows(await request('products', 'suggest', {'name': name}));
  Future<Map<String, dynamic>> save(
    Map<String, dynamic> input,
    bool publish,
    int now,
  ) async => receipt(
    await request('receipts', publish ? 'confirm' : 'save', {'receipt': input}),
  );
  Future<Map<String, dynamic>> load(String id) async =>
      receipt(await request('receipts', 'get', {'id': id}));
  Future<List<Map<String, dynamic>>?> cachedReceipts({
    required String sortBy,
    required String direction,
  }) async {
    try {
      final data = jsonDecode(
        await cachedResponse(
          readCache('receipts/overview', {
            'sort_by': sortBy,
            'direction': direction,
          }),
        ),
      );
      return data is Map && data['data'] is List ? rows(data['data']) : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> receipts(
    bool trash, {
    required String sortBy,
    required String direction,
    required String? productNameId,
  }) async {
    final result = <Map<String, dynamic>>[];
    String? cursor;
    do {
      final page = await request('receipts', 'list', {
        'trash': trash,
        'sort_by': sortBy,
        'product_name_id': productNameId,
        'direction': direction,
        'cursor': cursor,
      });
      final entries = rows(page['items']);
      for (final r in entries) {
        versions[r['receipt_id']] = r['version'];
      }
      result.addAll(entries);
      cursor = page['next_cursor'];
    } while (cursor != null);
    if (!trash && productNameId == null) {
      cacheResponse(
        readCache('receipts/overview', {
          'sort_by': sortBy,
          'direction': direction,
        }),
        {'data': result},
      );
    }
    return result;
  }

  Future<List<Map<String, dynamic>>> duplicates(
    Map<String, dynamic> input,
  ) async =>
      rows(await request('receipts', 'check_duplicates', {'receipt': input}));
  Future<void> purge(String id) async {
    await request('receipts', 'purge', {
      'id': id,
      'expected_version': versions[id],
    });
  }

  Future<List<Map<String, dynamic>>> images(String receipt) async =>
      rows(await request('images', 'list', {'receipt_id': receipt}));
  Future<void> reorderImages(String receiptId, List<String> ids) async {
    receipt(
      await request('images', 'reorder', {
        'receipt_id': receiptId,
        'ids': ids,
        'expected_version': versions[receiptId],
      }),
    );
  }

  Future<void> removeImage(String receiptId, String id) async {
    receipt(
      await request('images', 'remove', {
        'receipt_id': receiptId,
        'id': id,
        'expected_version': versions[receiptId],
      }),
    );
  }

  Future<void> rotateImage(String receiptId, String id) async {
    receipt(
      await request('images', 'rotate', {
        'receipt_id': receiptId,
        'id': id,
        'expected_version': versions[receiptId],
      }),
    );
  }

  Future<Map<String, dynamic>> importImage(
    String receiptId,
    Uint8List bytes,
    bool camera,
    int now,
  ) async {
    return sendUpload(await queueImage(receiptId, bytes, camera, now));
  }

  Future<String> queueImage(
    String receiptId,
    Uint8List bytes,
    bool camera,
    int now,
  ) async {
    final uploadId = newId();
    final folder = Directory('$cacheRoot/pending');
    await folder.create(recursive: true);
    await File('${folder.path}/$uploadId.photo')
        .writeAsBytes(bytes, flush: true);
    final metadata = File('${folder.path}/$uploadId.json.tmp');
    await metadata.writeAsString(
      jsonEncode({
        'receipt_id': receiptId,
        'expected_version': versions[receiptId] ?? 0,
        'captured_at_utc_ms': camera ? now : null,
      }),
      flush: true,
    );
    await metadata.rename('${folder.path}/$uploadId.json');
    return uploadId;
  }

  Future<Map<String, dynamic>> sendUpload(String id, {bool rebase = false}) {
    return uploads.putIfAbsent(
      id,
      () => _sendUpload(id, rebase: rebase, retryAuthentication: true)
          .whenComplete(() {
            uploads.remove(id);
          }),
    );
  }

  Future<Map<String, dynamic>> _sendUpload(
    String id, {
    bool rebase = false,
    required bool retryAuthentication,
  }) async {
    final metadata = File('$cacheRoot/pending/$id.json');
    final file = File('$cacheRoot/pending/$id.photo');
    final input = jsonDecode(await metadata.readAsString());
    final config = await configuration();
    final origin = config.endpointUri.replace(
      path: '/',
      query: '',
      fragment: '',
    );
    final req = http.MultipartRequest(
      'POST',
      origin.resolve('/api/v1/images/upload'),
    )..followRedirects = false;
    req.headers['Authorization'] = 'Bearer ${config.key}';
    req.fields['metadata'] = jsonEncode({'request_key': id, 'input': input});
    req.files.add(await http.MultipartFile.fromPath('photo', file.path));
    final response =
        await http.Response.fromStream(
          await client
              .send(req)
              .timeout(
                const Duration(minutes: 3),
                onTimeout: () => throw RequestTimeout(),
              ),
        ).timeout(
          const Duration(minutes: 3),
          onTimeout: () => throw RequestTimeout(),
        );
    final value = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode == 409 && rebase) {
      final current = await load(input['receipt_id']);
      input['expected_version'] = current['revision'];
      await metadata.writeAsString(jsonEncode(input), flush: true);
      return _sendUpload(id, retryAuthentication: retryAuthentication);
    }
    if (response.statusCode == 401 &&
        retryAuthentication &&
        recoverAuthentication != null) {
      await recoverAuthentication!(config.key);
      return _sendUpload(id, rebase: rebase, retryAuthentication: false);
    }
    if (response.statusCode != 200) {
      throw InputError(value['error']?['message'] ?? '上传失败；照片已留存，可重试');
    }
    receipt(value['data']['receipt']);
    await metadata.delete();
    await file.delete();
    return Map<String, dynamic>.from(value['data']);
  }

  final Map<String, String> submissionStates = {};
  final Map<String, Future<void>> _submissions = {};

  Future<String> queueCapture(
    List<Uint8List> photos,
    bool camera,
    int now,
    String zone, {
    String? receiptId,
  }) async {
    if (photos.isEmpty) throw const InputError("请选择至少一张照片");
    final batch = newId();
    final draft = receiptId == null
        ? ReceiptDraft.empty(DateTime.fromMillisecondsSinceEpoch(now))
        : null;
    final target = receiptId ?? draft!.id;
    final directory = Directory('$cacheRoot/submissions');
    await directory.create(recursive: true);
    final ids = <String>[];
    for (final photo in photos) {
      ids.add(await queueImage(target, photo, camera, now));
    }
    await _writeSubmission(batch, {
      'receipt_id': target,
      'receipt': draft?.toMap(),
      'uploads': ids,
      'zone': zone,
    });
    _launchSubmission(batch);
    return target;
  }

  Future<void> _writeSubmission(String id, Map<String, dynamic> value) async {
    final temporary = File('$cacheRoot/submissions/$id.tmp');
    await temporary.writeAsString(jsonEncode(value), flush: true);
    await temporary.rename('$cacheRoot/submissions/$id.json');
  }

  void _launchSubmission(String id) {
    if (_submissions.containsKey(id)) return;
    submissionStates[id] = '上传中';
    notifyListeners();
    _submissions[id] = _submitCapture(id)
        .catchError((Object error) {
          submissionStates[id] = '上传失败，点击重试：$error';
        })
        .whenComplete(() {
          _submissions.remove(id);
          notifyListeners();
        });
  }

  Future<void> _submitCapture(String id) async {
    final file = File('$cacheRoot/submissions/$id.json');
    final input = Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()),
    );
    if (input['receipt'] != null) {
      receipt(
        await request('receipts', 'save', {
          'receipt': input['receipt'],
        }, key: 'capture-$id'),
      );
    }
    for (final upload in input['uploads']) {
      if (await File('$cacheRoot/pending/$upload.json').exists()) {
        await sendUpload(upload, rebase: true);
      }
    }
    if (input['version'] == null) {
      input['version'] = (await load(input['receipt_id']))['revision'];
      await _writeSubmission(id, input);
    }
    await startRecognition(
      input['receipt_id'],
      input['version'],
      input['zone'],
      requestKey: 'recognize-$id',
    );
    await file.delete();
    submissionStates.remove(id);
  }

  Future<void> retrySubmissions() async {
    final directory = Directory('$cacheRoot/submissions');
    if (!await directory.exists()) return;
    for (final entry in await directory.list().toList()) {
      if (entry.path.endsWith('.json')) {
        _launchSubmission(
          entry.uri.pathSegments.last.replaceFirst('.json', ''),
        );
      }
    }
  }

  Future<void> retryUploads() async {
    final managed = <String>{};
    final batches = Directory('$cacheRoot/submissions');
    if (await batches.exists()) {
      for (final entry in await batches.list().toList()) {
        if (entry.path.endsWith('.json')) {
          try {
            final value = jsonDecode(await File(entry.path).readAsString());
            managed.addAll(List<String>.from(value['uploads']));
          } on FileSystemException {
            if (await File(entry.path).exists()) rethrow;
          }
        }
      }
    }
    await retrySubmissions();
    final dir = Directory('$cacheRoot/pending');
    if (!await dir.exists()) return;
    for (final file in await dir.list().toList()) {
      if (file.path.endsWith('.json') &&
          !managed.contains(
            file.uri.pathSegments.last.replaceFirst('.json', ''),
          ) &&
          await file.exists()) {
        await sendUpload(
          file.uri.pathSegments.last.replaceFirst('.json', ''),
          rebase: true,
        );
      }
    }
  }

  Future<Uint8List> imageBytes(String id) async {
    final file = File('$cacheRoot/media/${sha256.convert(utf8.encode(id))}');
    try {
      var config = await configuration();
      for (var attempt = 0; attempt < 2; attempt++) {
        final uri = config.endpointUri.replace(
          path: '/api/v1/media/$id',
          query: '',
          fragment: '',
        );
        final req = http.Request('GET', uri)..followRedirects = false;
        req.headers['Authorization'] = 'Bearer ${config.key}';
        final response =
            await http.Response.fromStream(
              await client
                  .send(req)
                  .timeout(
                    const Duration(seconds: 30),
                    onTimeout: () => throw RequestTimeout(),
                  ),
            ).timeout(
              const Duration(minutes: 3),
              onTimeout: () => throw RequestTimeout(),
            );
        if (response.statusCode == 401 &&
            attempt == 0 &&
            recoverAuthentication != null) {
          config = await recoverAuthentication!(config.key);
          continue;
        }
        if (response.statusCode != 200) throw const InputError('无法加载照片');
        try {
          await file.parent.create(recursive: true);
          await file.writeAsBytes(response.bodyBytes, flush: true);
        } on FileSystemException {
          // Photos remain usable when the device cannot write its cache.
        }
        return response.bodyBytes;
      }
      throw const InputError('请先登录');
    } catch (error) {
      if (!connectionFailure(error)) rethrow;
      if (await file.exists()) return file.readAsBytes();
      throw InputError(error is TimeoutException ? 'Timeout' : '网络不可用，显示缓存');
    }
  }

  Widget image(Map<String, dynamic> photo, {BoxFit? fit, double? width}) =>
      FutureBuilder<Uint8List>(
        future: imageBytes(photo['media_id']),
        builder: (context, snapshot) => snapshot.hasData
            ? Image.memory(snapshot.data!, fit: fit, width: width)
            : snapshot.hasError
            ? const Icon(Icons.broken_image_outlined)
            : const Center(child: CircularProgressIndicator()),
      );
  Future<Map<String, dynamic>> report(
    int start,
    int end,
    String? category,
    String zone, {
    required String? receiptType,
  }) async {
    int? offset = 0;
    Map<String, dynamic>? result;
    final entries = <Map<String, dynamic>>[];
    do {
      final page = Map<String, dynamic>.from(
        await request('reports', 'summary', {
          'start': start,
          'end': end,
          'category': category,
          'zone': zone,
          'offset': offset,
          'receipt_type': receiptType,
        }),
      );
      result ??= page;
      entries.addAll(rows(page['entries']));
      offset = page['next_offset'];
    } while (offset != null);
    result['entries'] = entries;
    return result;
  }

  Future<String> startRecognition(
    String receiptId,
    int version,
    String zone, {
    required String? requestKey,
  }) async {
    final job = await request('recognition', 'start', {
      'receipt_id': receiptId,
      'expected_version': version,
      'zone': zone,
    }, key: requestKey);
    return job['job_id'];
  }

  Future<Uint8List> latestBackup() async {
    final value = await request('exports', 'latest_backup', {});
    return base64Decode(value['bytes_base64']);
  }

  Future<Uint8List> createBackup(int now) async {
    final value = await request('exports', 'create_backup', {});
    return base64Decode(value['bytes_base64']);
  }

  Future<String> restoreBackup(Uint8List bytes) async {
    final prepared = await request('maintenance', 'prepare_restore', {
      'bytes_base64': base64Encode(bytes),
    });
    return await request('maintenance', 'commit_restore', {
      'token': prepared['token'],
      'confirm': true,
    }) as String;
  }

  Future<String> csvExport(String zone) async =>
      await request('exports', 'csv', {'zone': zone}) as String;
}
