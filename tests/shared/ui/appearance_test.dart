import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:receipt_master/ui/app_theme.dart';

class InMemoryAppearance extends Appearance {
  InMemoryAppearance() : super('/unused');

  @override
  Future<void> setMode(ThemeMode value) async {
    mode = value;
    notifyListeners();
  }
}

void main() {
  test(
    'appearance defaults to system and persists the selected mode',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'receipt-appearance-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final first = Appearance(directory.path);
      await first.load();
      expect(first.mode, ThemeMode.system);
      await first.setMode(ThemeMode.dark);
      final restored = Appearance(directory.path);
      await restored.load();
      expect(restored.mode, ThemeMode.dark);
      await restored.setMode(ThemeMode.light);
      final light = Appearance(directory.path);
      await light.load();
      expect(light.mode, ThemeMode.light);
    },
  );

  test('light and dark palettes expose matching brightness', () {
    expect(receiptTheme(Brightness.light).brightness, Brightness.light);
    expect(receiptTheme(Brightness.dark).brightness, Brightness.dark);
    expect(
      receiptTheme(Brightness.light).colorScheme.surface,
      isNot(receiptTheme(Brightness.dark).colorScheme.surface),
    );
  });

  testWidgets('narrow settings screen switches system, dark, and light', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final appearance = InMemoryAppearance();
    await tester.pumpWidget(
      AnimatedBuilder(
        animation: appearance,
        builder: (context, _) => MaterialApp(
          theme: receiptTheme(Brightness.light),
          darkTheme: receiptTheme(Brightness.dark),
          themeMode: appearance.mode,
          home: Scaffold(
            body: Center(
              child: AppearancePicker(appearance: appearance, onError: (_) {}),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('跟随系统'), findsOneWidget);
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(appearance.mode, ThemeMode.dark);
    expect(
      Theme.of(tester.element(find.text('深色'))).brightness,
      Brightness.dark,
    );
    await tester.tap(find.text('浅色'));
    await tester.pumpAndSettle();
    expect(appearance.mode, ThemeMode.light);
    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    expect(appearance.mode, ThemeMode.system);
    expect(tester.takeException(), isNull);
  });
}
