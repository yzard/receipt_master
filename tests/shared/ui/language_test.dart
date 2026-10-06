import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart' hide testWidgets;

import '../platform_test.dart';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/data/auth_session.dart';
import 'package:receipt_master/ui/account.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/l10n/strings.dart';
import 'package:receipt_master/l10n/catalog.dart';
import 'package:receipt_master/main.dart';
import 'package:receipt_master/ui/app_theme.dart';
import 'package:receipt_master/ui/common.dart';
import 'package:timezone/data/latest.dart' as tzdata;

void main() {
  testWidgets(
    'Settings uses backend language choices including a newly added language',
    (tester) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = const Size(430, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final file = File('../../src/backend_api/resources/localizations.json');
      final original = jsonDecode(file.readAsStringSync());
      final data = jsonDecode(file.readAsStringSync());
      data['available_languages'].add({
        'code': 'fr',
        'name': 'Français',
        'locale': 'fr-FR',
      });
      data['translations']['fr'] = {
        ...data['translations']['en'] as Map,
        '设置': 'Paramètres',
      };
      TranslationCatalog.instance.install(data);
      addTearDown(() => TranslationCatalog.instance.install(original));
      final root = Directory.systemTemp.createTempSync(
        'receipt-server-language-ui-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        return http.Response(
          jsonEncode({
            'data': request.url.path.endsWith('/receipts/list')
                ? {'items': [], 'next_cursor': null}
                : {'weight_unit': 'kg', 'report_currency': 'USD'},
          }),
          200,
        );
      });
      addTearDown(client.close);
      final store = AppStore(
        root.path,
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: client,
      );
      final appearance = Appearance(root.path);
      await tester.pumpWidget(
        ReceiptApp(
          store: store,
          zone: 'America/New_York',
          appearance: appearance,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('打开导航菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      final before = requests;
      await tester.ensureVisible(find.byType(DropdownButtonFormField<Locale>));
      await tester.tap(find.byType(DropdownButtonFormField<Locale>));
      await tester.pumpAndSettle();
      expect(find.text('Français'), findsOneWidget);
      await tester.tap(find.text('Français'));
      await tester.runAsync(() async {
        for (var i = 0; i < 100; i++) {
          if (await File('${root.path}/language.txt').exists()) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, 800));
      await tester.pumpAndSettle();
      expect(find.text('Paramètres'), findsOneWidget);
      expect(appearance.locale, const Locale('fr'));
      expect(requests, before);
      expect(
        MaterialLocalizations.of(tester.element(find.text('Paramètres')))
            .cancelButtonLabel,
        'Annuler',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  test(
    'device language persists, invalid settings fall back, writes roll back',
    () async {
      final root = await Directory.systemTemp.createTemp('receipt-language-');
      addTearDown(() => root.deleteSync(recursive: true));
      final appearance = Appearance(root.path);
      await appearance.load();
      expect(appearance.locale, const Locale('zh'));
      await appearance.setLocale(const Locale('en'));
      final restored = Appearance(root.path);
      await restored.load();
      expect(restored.locale, const Locale('en'));
      expect(restored.mode, ThemeMode.system);
      await expectLater(
        restored.setLocale(const Locale('fr')),
        throwsArgumentError,
      );
      await File('${root.path}/language.txt').writeAsString('invalid');
      await restored.load();
      expect(restored.locale, const Locale('zh'));
      await File('${root.path}/language.txt').delete();
      await Directory('${root.path}/language.txt').create();
      await expectLater(
        restored.setLocale(const Locale('en')),
        throwsA(isA<FileSystemException>()),
      );
      expect(restored.locale, const Locale('zh'));
    },
  );

  test(
    'localized messages preserve amounts, placeholders and unknown OCR notes',
    () {
      const english = ReceiptLocalizations(Locale('en'));
      expect(english.text('第 {0} 张', [3]), 'Photo 3');
      expect(
        english.text('录入 {0}\n收据 {1}', ['2026-10-02', '2025-12-01']),
        'Entered 2026-10-02\nReceipt 2025-12-01',
      );
      expect(english.message('正在下载更新 37%'), 'Downloading update 37%');
      expect(
        english.message('缺少金额\n用户名或密码不正确'),
        'Missing amount\nIncorrect username or password',
      );
      expect(
        english.message('称重金额不符：计算 USD 8.40，票面 USD 9.40，差额 USD +1.00（票面−计算）'),
        'Weight amount mismatch: calculated USD 8.40, printed USD 9.40, difference USD +1.00 (printed − calculated)',
      );
      expect(english.message('OCR 原始备注 abc 123'), 'OCR 原始备注 abc 123');
      expect(english.text('追溯编号：{0}', ['{1}']), 'Tracking ID: {1}');
    },
  );

  testWidgets(
    'Settings switches the whole app and Material controls without server writes',
    (tester) async {
      tzdata.initializeTimeZones();
      tester.view.physicalSize = const Size(430, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final root = Directory.systemTemp.createTempSync('receipt-language-ui-');
      addTearDown(() => root.deleteSync(recursive: true));
      final requests = <String>[];
      final store = AppStore(
        root.path,
        configuration: () async =>
            const BackendConnection('https://example.test', 'key'),
        client: MockClient((request) async {
          requests.add(request.url.path);
          final dynamic data = switch (request.url.path) {
            '/api/v1/receipts/list' => {
              'items': [
                {
                  'receipt_id': 'receipt-1',
                  'version': 1,
                  'raw_store': '原始店铺名',
                  'status': 'posted',
                  'recognition_status': 'applied',
                  'created_at_utc_ms': 1780000000000,
                  'occurred_at_utc_ms': 1780000000000,
                  'total_minor': 450,
                  'currency_code': 'USD',
                },
              ],
              'next_cursor': null,
            },
            '/api/v1/config/get' => {
              'weight_unit': 'kg',
              'report_currency': 'USD',
            },
            _ => throw StateError('Unexpected request ${request.url.path}'),
          };
          return http.Response(
            jsonEncode({'data': data}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      final appearance = Appearance(root.path);
      await tester.pumpWidget(
        ReceiptApp(
          store: store,
          zone: 'America/New_York',
          appearance: appearance,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('打开导航菜单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置'));
      await tester.pumpAndSettle();
      final before = requests.length;
      await tester.tap(find.byType(DropdownButtonFormField<Locale>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.runAsync(() async {
        // Await real device preference I/O before advancing the test clock.
        for (var i = 0; i < 100; i++) {
          if (await File('${root.path}/language.txt').exists()) break;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Preferences'), findsOneWidget);
      expect(find.text('设置'), findsNothing);
      expect(requests.length, before);
      final settingsContext = tester.element(find.text('Settings'));
      expect(Localizations.localeOf(settingsContext), const Locale('en'));
      expect(
        MaterialLocalizations.of(settingsContext).cancelButtonLabel,
        'Cancel',
      );
      await tester.tap(find.byTooltip('Open navigation menu'));
      await tester.pumpAndSettle();
      expect(find.text('Reports'), findsOneWidget);
      expect(find.text('Stores'), findsOneWidget);
      await tester.tap(find.text('Receipts'));
      await tester.pumpAndSettle();
      expect(find.text('Entry time'), findsOneWidget);
      expect(find.text('原始店铺名'), findsOneWidget);
      final restored = Appearance(root.path);
      await tester.runAsync(restored.load);
      expect(restored.locale, const Locale('en'));
      await tester.runAsync(() => appearance.setLocale(const Locale('zh')));
      await tester.pumpAndSettle();
      expect(find.text('收据'), findsOneWidget);
      expect(find.text('录入时间'), findsOneWidget);
      expect(
        MaterialLocalizations.of(tester.element(find.text('收据')))
            .cancelButtonLabel,
        '取消',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'language switches labels without changing editable or receipt names',
    (tester) async {
      final locale = ValueNotifier(const Locale('zh'));
      addTearDown(locale.dispose);
      final controller = TextEditingController(text: '瓶装水');
      addTearDown(controller.dispose);
      Widget app() => ListenableBuilder(
        listenable: locale,
        builder: (context, _) => MaterialApp(
          locale: locale.value,
          supportedLocales: ReceiptLocalizations.supportedLocales,
          localizationsDelegates: ReceiptLocalizations.delegates,
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  TextField(
                    controller: controller,
                    decoration: InputDecoration(labelText: context.tr('商品名称')),
                  ),
                  const ReceiptItemName(
                    productName: '瓶装水',
                    printedName: '**KWSWTR40PK',
                    kind: 'product',
                  ),
                  const ReceiptItemName(
                    productName: null,
                    printedName: '',
                    kind: 'tax',
                  ),
                  const Notice('用户名或密码不正确'),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '新输入的商品');
      locale.value = const Locale('en');
      await tester.pumpAndSettle();
      expect(find.text('Product name'), findsOneWidget);
      expect(controller.text, '新输入的商品');
      expect(find.text('瓶装水'), findsOneWidget);
      expect(find.text('**KWSWTR40PK'), findsOneWidget);
      expect(find.text('Tax'), findsOneWidget);
      expect(find.text('Incorrect username or password'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('English sign-in and password forms retain autofill hints', (
    tester,
  ) async {
    final session = AuthSession(
      MockClient((_) async => throw StateError('No request expected')),
    );
    addTearDown(session.dispose);
    Widget app(Widget home) => MaterialApp(
      locale: const Locale('en'),
      supportedLocales: ReceiptLocalizations.supportedLocales,
      localizationsDelegates: ReceiptLocalizations.delegates,
      home: home,
    );
    await tester.pumpWidget(app(LoginPage(session: session)));
    await tester.pumpAndSettle();
    expect(find.text('Username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    // iOS announces form errors after a one-second accessibility delay.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Enter your username'), findsOneWidget);
    expect(find.text('Enter your password'), findsOneWidget);
    expect(
      tester
          .widgetList<TextField>(find.byType(TextField))
          .where(
            (f) => f.autofillHints?.contains(AutofillHints.password) == true,
          ),
      hasLength(1),
    );
    await tester.pumpWidget(
      app(PasswordPage(session: session, requiredChange: false)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Current password'), findsOneWidget);
    expect(find.text('New password (at least 12 characters)'), findsOneWidget);
    expect(find.text('Confirm new password'), findsOneWidget);
    final fields = tester.widgetList<TextField>(find.byType(TextField));
    expect(
      fields.where(
        (f) => f.autofillHints?.contains(AutofillHints.newPassword) == true,
      ),
      hasLength(2),
    );
    await tester.pumpWidget(const SizedBox());
  });
}
