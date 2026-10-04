import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class InterfaceLanguage {
  const InterfaceLanguage(this.code, this.name);
  final String code, name;
  Locale get locale {
    final parts = code.split('-');
    return Locale.fromSubtags(
      languageCode: parts.first,
      scriptCode: parts.skip(1).where((part) => part.length == 4).firstOrNull,
      countryCode: parts
          .skip(1)
          .where((part) => part.length == 2 || part.length == 3)
          .firstOrNull,
    );
  }
}

/// The backend owns all translation tables and the available-language list.
class TranslationCatalog extends ChangeNotifier {
  static final instance = TranslationCatalog();
  List<InterfaceLanguage> languages = [];
  Map<String, Map<String, String>> translations = {};
  String defaultLanguage = 'zh';
  Object? error;
  final _loaded = <String, dynamic>{};
  String? _activeOrigin;
  final _pending = <String, Future<void>>{};
  Future<void> Function()? _retry;

  Locale get defaultLocale =>
      languages
          .where((entry) => entry.code == defaultLanguage)
          .firstOrNull
          ?.locale ??
      const Locale('zh');
  List<Locale> get locales => languages.isEmpty
      ? [const Locale('zh')]
      : languages.map((entry) => entry.locale).toList();
  Locale resolveLocale(Locale selected) =>
      languages.isEmpty || locales.contains(selected)
      ? selected
      : defaultLocale;

  void install(dynamic data) {
    if (data is! Map ||
        data['schema_version'] != 1 ||
        data['available_languages'] is! List ||
        data['translations'] is! Map) {
      throw const FormatException('翻译资源无效');
    }
    final nextLanguages = <InterfaceLanguage>[];
    final nextTranslations = <String, Map<String, String>>{};
    final pattern = RegExp(r'^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$');
    for (final entry in data['available_languages']) {
      if (entry is! Map ||
          entry['code'] is! String ||
          !pattern.hasMatch(entry['code']) ||
          entry['name'] is! String ||
          (entry['name'] as String).isEmpty ||
          entry['locale'] is! String ||
          !pattern.hasMatch(entry['locale']) ||
          nextTranslations.containsKey(entry['code'])) {
        throw const FormatException('翻译资源无效');
      }
      final table = data['translations'][entry['code']];
      if (table is! Map ||
          table.isEmpty ||
          table.entries.any(
            (entry) =>
                entry.key is! String ||
                (entry.key as String).isEmpty ||
                entry.value is! String,
          )) {
        throw const FormatException('翻译资源无效');
      }
      nextLanguages.add(InterfaceLanguage(entry['code'], entry['name']));
      nextTranslations[entry['code']] = Map<String, String>.from(table);
    }
    if (nextLanguages.isEmpty ||
        !nextTranslations.containsKey(data['default_language']))
      throw const FormatException('翻译资源无效');
    languages = List.unmodifiable(nextLanguages);
    translations = nextTranslations;
    defaultLanguage = data['default_language'];
    error = null;
    notifyListeners();
  }

  Map<String, String> table(Locale locale) =>
      translations[locale.toLanguageTag()] ??
      translations[defaultLanguage] ??
      {};

  Future<void> retry() async => await _retry?.call();

  /// Coalesce calls and fetch once per server per app launch. Cache is server-scoped.
  Future<void> load({
    required Uri origin,
    required http.Client client,
    required String cacheRoot,
  }) {
    final base = origin.replace(path: '/', query: '', fragment: '');
    final key = base.toString();
    _retry = () => load(origin: origin, client: client, cacheRoot: cacheRoot);
    if (_activeOrigin != key) {
      _activeOrigin = key;
      if (_loaded.containsKey(key)) install(_loaded[key]);
    }
    if (_loaded.containsKey(key)) return Future.value();
    return _pending[key] ??= _load(
      base,
      client,
      cacheRoot,
    ).whenComplete(() => _pending.remove(key));
  }

  Future<void> _load(Uri origin, http.Client client, String cacheRoot) async {
    final id = sha256.convert(utf8.encode(origin.toString()));
    final cache = File('$cacheRoot/localizations-$id.json');
    try {
      if (await cache.exists() && _activeOrigin == origin.toString()) {
        install(jsonDecode(await cache.readAsString()));
      }
    } on FileSystemException {
      /* Offline without a readable cache uses source text. */
    } on FormatException {
      /* Invalid cache is replaced only by validated server data. */
    }
    try {
      final response = await client
          .post(
            origin.resolve('/api/v1/localizations/get'),
            headers: {'Content-Type': 'application/json'},
            body: '{}',
          )
          .timeout(const Duration(seconds: 10));
      if (response.statusCode != 200)
        throw const HttpException('无法加载界面语言，请重试。');
      final data = jsonDecode(utf8.decode(response.bodyBytes))['data'];
      // Validate without letting a late response replace another server's resources.
      final validated = TranslationCatalog();
      try {
        validated.install(data);
      } finally {
        validated.dispose();
      }
      _loaded[origin.toString()] = data;
      if (_activeOrigin == origin.toString()) install(data);
      try {
        await cache.parent.create(recursive: true);
        final temporary = File('${cache.path}.tmp');
        await temporary.writeAsString(jsonEncode(data), flush: true);
        await temporary.rename(cache.path);
      } on FileSystemException {
        /* Valid resources remain available in memory. */
      }
    } catch (failure) {
      if (_activeOrigin == origin.toString()) {
        error = failure;
        notifyListeners();
      }
      rethrow;
    }
  }
}
