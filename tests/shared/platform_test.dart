import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart' as testing;

/// Exercise the same business flows with native iOS or Android widget behavior.
void testWidgets(String description, testing.WidgetTesterCallback callback) {
  testing.testWidgets(
    description,
    callback,
    variant: testing.TargetPlatformVariant({
      const String.fromEnvironment('TEST_PLATFORM') == 'ios'
          ? TargetPlatform.iOS
          : TargetPlatform.android,
    }),
  );
}
