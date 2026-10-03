import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:receipt_master/data/auth_session.dart';
import 'package:receipt_master/data/backend_connection.dart';
import 'package:receipt_master/data/store.dart';
import 'package:receipt_master/l10n/strings.dart';
import 'package:receipt_master/ui/account.dart';
import 'package:receipt_master/ui/app_theme.dart';
import 'package:receipt_master/ui/settings.dart';

void main() {
  for (final (size, locale, brightness, scale, admin) in [
    (const Size(390, 844), const Locale('en'), Brightness.dark, 1.0, true),
    (const Size(320, 720), const Locale('en'), Brightness.light, 1.6, false),
    (const Size(840, 700), const Locale('zh'), Brightness.dark, 1.4, true),
  ]) {
    testWidgets(
      'settings account and preferences fit $size ${locale.languageCode} scale $scale admin $admin',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final previousUser = AuthSession.instance.user;
        final previousEndpoint = AuthSession.instance.endpoint;
        AuthSession.instance.user = {
          'username': 'account-with-a-long-name',
          'is_admin': admin,
        };
        AuthSession.instance.endpoint = 'https://receipts.example.com/';
        addTearDown(() {
          AuthSession.instance.user = previousUser;
          AuthSession.instance.endpoint = previousEndpoint;
        });
        var changed = 0;
        final saves = <Map<String, dynamic>>[];
        final client = MockClient((request) async {
          final input = jsonDecode(request.body)['input'];
          if (request.url.path.endsWith('/save_weight_unit')) {
            saves.add(Map<String, dynamic>.from(input));
          } else {
            expect(request.url.path, '/api/v1/config/get');
          }
          return http.Response(
            jsonEncode({
              'data': {'weight_unit': 'kg', 'report_currency': 'USD'},
              'catalog_version': 1,
            }),
            200,
          );
        });
        addTearDown(client.close);
        final store = AppStore(
          '/unused',
          configuration: () async =>
              const BackendConnection('https://example.test', 'key'),
          client: client,
        );
        addTearDown(store.dispose);
        final appearance = Appearance('/unused');
        addTearDown(appearance.dispose);
        const username = ValueKey('settings-username');
        final tr = ReceiptLocalizations(locale).text;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            supportedLocales: ReceiptLocalizations.supportedLocales,
            localizationsDelegates: ReceiptLocalizations.delegates,
            theme: receiptTheme(brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: Scaffold(
              body: SettingsPage(
                store: store,
                zone: 'America/New_York',
                onChanged: () async => changed++,
                appearance: appearance,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final name = find.byKey(username);
        final password = find.byTooltip(tr('修改密码'));
        final logout = find.byTooltip(tr('退出登录'));
        expect(tester.getCenter(name).dy, tester.getCenter(password).dy);
        expect(tester.getCenter(name).dy, tester.getCenter(logout).dy);
        expect(
          tester.getRect(name).right,
          lessThan(tester.getRect(password).left),
        );
        expect(
          tester.widget<Text>(name).style!.fontWeight!.value,
          greaterThanOrEqualTo(FontWeight.w700.value),
        );
        final management = find.widgetWithText(ListTile, tr('用户管理'));
        expect(management, admin ? findsOneWidget : findsNothing);
        if (admin) {
          expect(
            tester.getRect(management).top,
            greaterThan(tester.getRect(name).bottom),
          );
          expect(tester.getRect(management).width, size.width - 32);
        }
        await tester.tap(password);
        await tester.pumpAndSettle();
        expect(find.byType(PasswordPage), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        final scroll = find.byType(Scrollable).first;
        final weight = find.widgetWithText(
          DropdownButtonFormField<String>,
          'kg',
        );
        final retry = find.widgetWithText(OutlinedButton, tr('重试未完成的照片上传'));
        await tester.scrollUntilVisible(retry, 180, scrollable: scroll);
        await tester.pumpAndSettle();
        expect(
          tester.getRect(find.text(tr('全局重量显示单位'))).top,
          greaterThan(
            tester
                    .getRect(
                      find.widgetWithText(OutlinedButton, tr('重试未完成的照片上传')),
                    )
                    .bottom +
                8,
          ),
        );
        for (final label in [
          '收据与商品统一显示此单位；数据库统一保存克数。',
          '所有已确认收据按交易日汇率换算后统一统计。',
        ]) {
          final helper = find.text(tr(label));
          await tester.scrollUntilVisible(helper, 100, scrollable: scroll);
          await tester.pumpAndSettle();
          expect(
            tester.renderObject<RenderParagraph>(helper).didExceedMaxLines,
            isFalse,
          );
        }
        await tester.scrollUntilVisible(weight, -100, scrollable: scroll);
        await tester.tap(weight);
        await tester.pumpAndSettle();
        await tester.tap(find.text('lb').last);
        await tester.pumpAndSettle();
        expect(saves.single['weight_unit'], 'lb');
        expect(store.weightUnit, 'lb');
        expect(changed, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
