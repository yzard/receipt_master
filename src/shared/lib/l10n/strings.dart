import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'catalog.dart';

/// Only explicit interface messages are translated. Never use this on names
/// supplied by the receipt or edited by the user.
class ReceiptLocalizations {
  const ReceiptLocalizations(this.locale);

  final Locale locale;
  static List<Locale> get supportedLocales =>
      TranslationCatalog.instance.locales;
  static const delegates = <LocalizationsDelegate<dynamic>>[
    _ReceiptLocalizationsDelegate(),
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ];

  static ReceiptLocalizations of(BuildContext context) =>
      Localizations.of<ReceiptLocalizations>(context, ReceiptLocalizations) ??
      const ReceiptLocalizations(Locale('zh'));

  String text(String source, [List<Object?> arguments = const []]) {
    final template =
        TranslationCatalog.instance.table(locale)[source] ?? source;
    return template.replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
      final index = int.parse(match[1]!);
      return index < arguments.length ? '${arguments[index] ?? ''}' : match[0]!;
    });
  }

  /// Errors and recognition warnings can be received before a language change.
  /// Translate known templates at render time, preserving their embedded values.
  String message(String source) {
    if (TranslationCatalog.instance.table(locale).containsKey(source)) {
      return text(source);
    }
    for (final entry in _messagePatterns(locale)) {
      final match = entry.pattern.firstMatch(source);
      if (match != null) {
        return text(entry.source, [
          for (var i = 1; i <= match.groupCount; i++) match[i],
        ]);
      }
    }
    return source.split('\n').map(_messageLine).join('\n');
  }

  String _messageLine(String line) {
    if (TranslationCatalog.instance.table(locale).containsKey(line)) {
      return text(line);
    }
    for (final entry in _messagePatterns(locale)) {
      final match = entry.pattern.firstMatch(line);
      if (match != null) {
        return text(entry.source, [
          for (var i = 1; i <= match.groupCount; i++) match[i],
        ]);
      }
    }
    return line;
  }
}

List<({String source, RegExp pattern})> _messagePatterns(Locale locale) => [
  for (final source
      in TranslationCatalog.instance
          .table(locale)
          .keys
          .where(
            (s) =>
                s.contains('{0}') &&
                RegExp('错误|不符|差额|相差|失败|无法|缺少|缺失|重复|无效|不存在|上传|下载|后端')
                    .hasMatch(s),
          ))
    (
      source: source,
      pattern: RegExp(
        '^${source.split(RegExp(r'\{\d+\}')).map(RegExp.escape).join('(.*?)')}\$',
        dotAll: true,
      ),
    ),
];

class _ReceiptLocalizationsDelegate
    extends LocalizationsDelegate<ReceiptLocalizations> {
  const _ReceiptLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => ReceiptLocalizations.supportedLocales.any(
    (supported) => supported.languageCode == locale.languageCode,
  );

  @override
  Future<ReceiptLocalizations> load(Locale locale) =>
      SynchronousFuture(ReceiptLocalizations(locale));

  @override
  bool shouldReload(_ReceiptLocalizationsDelegate old) => false;
}

extension ReceiptTranslation on BuildContext {
  String tr(String source, [List<Object?> arguments = const []]) =>
      ReceiptLocalizations.of(this).text(source, arguments);

  String translatedMessage(String source) =>
      ReceiptLocalizations.of(this).message(source);
}
