import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Appearance is a device preference; receipt and recognition data stay on the server.
class Appearance extends ChangeNotifier {
  Appearance(this.root);

  final String root;
  ThemeMode mode = ThemeMode.system;

  File get _file => File(p.join(root, 'appearance.txt'));

  Future<void> load() async {
    try {
      if (await _file.exists()) {
        mode = switch ((await _file.readAsString()).trim()) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
      }
    } on FileSystemException {
      mode = ThemeMode.system;
    }
    notifyListeners();
  }

  Future<void> setMode(ThemeMode value) async {
    if (mode == value) return;
    final previous = mode;
    mode = value;
    notifyListeners();
    try {
      await _file.writeAsString(value.name, flush: true);
    } catch (_) {
      mode = previous;
      notifyListeners();
      rethrow;
    }
  }
}

class AppPalette {
  static const accent = Color(0xFF3159D9);
  static const accentDark = Color(0xFFADC2FF);
  static const lightCanvas = Color(0xFFF6F7FB);
  static const darkCanvas = Color(0xFF0C1424);

  static Color muted(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;

  static Color warningSurface(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF51401D)
      : const Color(0xFFFFEAB4);

  static Color errorSurface(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
      ? const Color(0xFF512A35)
      : const Color(0xFFFFDFE4);
}

ThemeData receiptTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: dark ? AppPalette.accentDark : AppPalette.accent,
    brightness: brightness,
    surface: dark ? AppPalette.darkCanvas : AppPalette.lightCanvas,
  );
  final panel = dark ? const Color(0xFF17243A) : Colors.white;
  final border = scheme.outlineVariant.withValues(alpha: dark ? .25 : .32);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: TextTheme(
      headlineLarge: TextStyle(
        fontSize: 34,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
        color: scheme.onSurface,
      ),
      headlineSmall: TextStyle(
        fontSize: 25,
        fontWeight: FontWeight.w700,
        letterSpacing: -.7,
        color: scheme.onSurface,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        letterSpacing: -.4,
        color: scheme.onSurface,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 1.42,
        color: scheme.onSurface,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      foregroundColor: scheme.onSurface,
      systemOverlayStyle: systemBars(brightness),
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        color: scheme.onSurface,
        fontSize: 23,
        fontWeight: FontWeight.w700,
        letterSpacing: -.5,
      ),
    ),
    cardTheme: CardThemeData(
      color: panel,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 5),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: border, width: .7),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: panel,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: border),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 17),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(17)),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      elevation: 0,
      indicatorColor: scheme.primary.withValues(alpha: dark ? .3 : .14),
      height: 76,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 11, color: scheme.onSurface),
      ),
    ),
    dividerTheme: DividerThemeData(color: border, thickness: 1),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      iconColor: scheme.primary,
    ),
  );
}

SystemUiOverlayStyle systemBars(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarContrastEnforced: false,
    statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
    statusBarBrightness: dark ? Brightness.dark : Brightness.light,
    systemNavigationBarIconBrightness: dark
        ? Brightness.light
        : Brightness.dark,
  );
}

/// Blurred chrome is reserved for bars that float above scrolling content.
class FrostedBar extends StatelessWidget {
  const FrostedBar({super.key, required this.child, this.radius});
  final Widget child;
  final BorderRadius? radius;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final scheme = Theme.of(context).colorScheme;
    final surface = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: dark ? .78 : .72),
          borderRadius: radius,
          border: radius == null
              ? Border(
                  top: BorderSide(
                    color: scheme.outlineVariant.withValues(alpha: .45),
                  ),
                )
              : Border.all(color: scheme.outlineVariant.withValues(alpha: .55)),
        ),
        child: child,
      ),
    );
    return radius == null
        ? ClipRect(child: surface)
        : ClipRRect(borderRadius: radius!, child: surface);
  }
}

class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title, subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 16, 18),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class AppearancePicker extends StatelessWidget {
  const AppearancePicker({
    super.key,
    required this.appearance,
    required this.onError,
  });

  final Appearance appearance;
  final void Function(Object) onError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        for (final (mode, icon, label) in [
          (ThemeMode.system, Icons.brightness_auto_outlined, '跟随系统'),
          (ThemeMode.light, Icons.light_mode_outlined, '浅色'),
          (ThemeMode.dark, Icons.dark_mode_outlined, '深色'),
        ])
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: Material(
                color: appearance.mode == mode
                    ? scheme.primaryContainer
                    : scheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(18),
                child: InkWell(
                  borderRadius: BorderRadius.circular(18),
                  onTap: () async {
                    try {
                      await appearance.setMode(mode);
                    } catch (e) {
                      onError(e);
                    }
                  },
                  child: SizedBox(
                    height: 78,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          icon,
                          size: 23,
                          color: appearance.mode == mode
                              ? scheme.onPrimaryContainer
                              : scheme.onSurfaceVariant,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: appearance.mode == mode
                                ? scheme.onPrimaryContainer
                                : scheme.onSurface,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
