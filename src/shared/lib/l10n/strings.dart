import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'english.dart';

/// Only explicit interface messages are translated. Never use this on names
/// supplied by the receipt or edited by the user.
class ReceiptLocalizations {
  const ReceiptLocalizations(this.locale);

  final Locale locale;
  static const supportedLocales = [Locale('zh'), Locale('en')];
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
    final template = locale.languageCode == 'en'
        ? englishMessages[source] ?? source
        : source;
    return template.replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
      final index = int.parse(match[1]!);
      return index < arguments.length ? '${arguments[index] ?? ''}' : match[0]!;
    });
  }

  /// Errors and recognition warnings can be received before a language change.
  /// Translate known templates at render time, preserving their embedded values.
  String message(String source) {
    if (locale.languageCode != 'en') return source;
    if (englishMessages.containsKey(source)) return text(source);
    for (final entry in _messagePatterns) {
      final match = entry.pattern.firstMatch(source);
      if (match != null) {
        return text(entry.source, [
          for (var i = 1; i <= match.groupCount; i++) message(match[i]!),
        ]);
      }
    }
    return source.split('\n').map(_messageLine).join('\n');
  }

  String _messageLine(String line) {
    if (englishMessages.containsKey(line)) return text(line);
    for (final entry in _messagePatterns) {
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

final _messagePatterns = [
  for (final source in englishMessages.keys.where((s) => s.contains('{0}')))
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
