import '../l10n/strings.dart';
import '../l10n/catalog.dart';

import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Appearance and interface language are device preferences.
/// Receipt and recognition data stay on the server.
class Appearance extends ChangeNotifier {
  Appearance(this.root);

  final String root;
  ThemeMode mode = ThemeMode.system;
  Locale locale = const Locale('zh');

  File get _languageFile => File(p.join(root, 'language.txt'));

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
    try {
      if (await _languageFile.exists()) {
        final code = (await _languageFile.readAsString()).trim();
        locale = RegExp(r'^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$').hasMatch(code)
            ? InterfaceLanguage(code, code).locale
            : TranslationCatalog.instance.defaultLocale;
      }
    } on FileSystemException {
      locale = const Locale('zh');
    }
    notifyListeners();
  }

  Future<void> setLocale(Locale value) async {
    if (!ReceiptLocalizations.supportedLocales.contains(value)) {
      throw ArgumentError.value(value, 'locale', 'Unsupported language');
    }
    if (locale == value) return;
    final previous = locale;
    locale = value;
    notifyListeners();
    try {
      await _languageFile.writeAsString(value.toLanguageTag(), flush: true);
    } catch (_) {
      locale = previous;
      notifyListeners();
      rethrow;
    }
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

abstract final class Space {
  static const xs = 4.0,
      sm = 8.0,
      md = 12.0,
      lg = 16.0,
      xl = 20.0,
      x2l = 24.0,
      x3l = 32.0,
      x4l = 40.0;
}

abstract final class Motion {
  static const fast = Duration(milliseconds: 120);
  static const base = Duration(milliseconds: 180);
  static const slow = Duration(milliseconds: 260);
  static const standard = Cubic(.2, 0, 0, 1);
}

@immutable
class ReceiptTokens extends ThemeExtension<ReceiptTokens> {
  const ReceiptTokens({
    required this.text3,
    required this.success,
    required this.successSoft,
    required this.warning,
    required this.warningSoft,
    required this.warningTint,
    required this.warningBorder,
    required this.dangerTint,
    required this.dangerBorder,
    required this.info,
    required this.infoSoft,
    required this.photoBg,
    required this.chart,
  });

  final Color text3,
      success,
      successSoft,
      warning,
      warningSoft,
      warningTint,
      warningBorder,
      dangerTint,
      dangerBorder,
      info,
      infoSoft,
      photoBg;
  final List<Color> chart;

  static const _chart = [
    Color(0xFF14937F),
    Color(0xFFE0682F),
    Color(0xFF5B6FE8),
    Color(0xFFD04E79),
    Color(0xFFB3841A),
    Color(0xFF8E5BD6),
    Color(0xFF3E8ED0),
  ];

  static const light = ReceiptTokens(
    text3: Color(0xFF6A6E75),
    success: Color(0xFF136C34),
    successSoft: Color(0xFFE7F6EC),
    warning: Color(0xFF9A5B00),
    warningSoft: Color(0xFFFDF1DC),
    warningTint: Color(0xFFFEF8EC),
    warningBorder: Color(0xFFF2C97D),
    dangerTint: Color(0xFFFEF4F3),
    dangerBorder: Color(0xFFF4B4AE),
    info: Color(0xFF1D5BD6),
    infoSoft: Color(0xFFE8EFFD),
    photoBg: Color(0xFF2A2D31),
    chart: _chart,
  );

  static const dark = ReceiptTokens(
    text3: Color(0xFF8A9098),
    success: Color(0xFF4ADE80),
    successSoft: Color(0xFF12291B),
    warning: Color(0xFFF5B544),
    warningSoft: Color(0xFF2E2410),
    warningTint: Color(0xFF221C10),
    warningBorder: Color(0xFF5C4718),
    dangerTint: Color(0xFF261515),
    dangerBorder: Color(0xFF6B2B2B),
    info: Color(0xFF7AA7FF),
    infoSoft: Color(0xFF172540),
    photoBg: Color(0xFF0A0B0C),
    chart: _chart,
  );

  @override
  ReceiptTokens copyWith({
    Color? text3,
    Color? success,
    Color? successSoft,
    Color? warning,
    Color? warningSoft,
    Color? warningTint,
    Color? warningBorder,
    Color? dangerTint,
    Color? dangerBorder,
    Color? info,
    Color? infoSoft,
    Color? photoBg,
    List<Color>? chart,
  }) => ReceiptTokens(
    text3: text3 ?? this.text3,
    success: success ?? this.success,
    successSoft: successSoft ?? this.successSoft,
    warning: warning ?? this.warning,
    warningSoft: warningSoft ?? this.warningSoft,
    warningTint: warningTint ?? this.warningTint,
    warningBorder: warningBorder ?? this.warningBorder,
    dangerTint: dangerTint ?? this.dangerTint,
    dangerBorder: dangerBorder ?? this.dangerBorder,
    info: info ?? this.info,
    infoSoft: infoSoft ?? this.infoSoft,
    photoBg: photoBg ?? this.photoBg,
    chart: chart ?? this.chart,
  );

  @override
  ReceiptTokens lerp(ReceiptTokens? other, double t) {
    if (other == null) return this;
    return ReceiptTokens(
      text3: Color.lerp(text3, other.text3, t)!,
      success: Color.lerp(success, other.success, t)!,
      successSoft: Color.lerp(successSoft, other.successSoft, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningSoft: Color.lerp(warningSoft, other.warningSoft, t)!,
      warningTint: Color.lerp(warningTint, other.warningTint, t)!,
      warningBorder: Color.lerp(warningBorder, other.warningBorder, t)!,
      dangerTint: Color.lerp(dangerTint, other.dangerTint, t)!,
      dangerBorder: Color.lerp(dangerBorder, other.dangerBorder, t)!,
      info: Color.lerp(info, other.info, t)!,
      infoSoft: Color.lerp(infoSoft, other.infoSoft, t)!,
      photoBg: Color.lerp(photoBg, other.photoBg, t)!,
      chart: t < .5 ? chart : other.chart,
    );
  }
}

extension ReceiptTokensX on BuildContext {
  ReceiptTokens get tokens {
    final theme = Theme.of(this);
    return theme.extension<ReceiptTokens>() ??
        (theme.brightness == Brightness.dark
            ? ReceiptTokens.dark
            : ReceiptTokens.light);
  }
}

abstract final class AppPalette {
  static const accent = Color(0xFF0F766E);
  static const accentDark = Color(0xFF3FC6B4);
  static const lightCanvas = Color(0xFFF6F6F3);
  static const darkCanvas = Color(0xFF0E1012);
  static const cameraAccent = accentDark;

  static Color muted(BuildContext context) =>
      Theme.of(context).colorScheme.onSurfaceVariant;

  static Color warningSurface(BuildContext context) =>
      context.tokens.warningSoft;

  static Color errorSurface(BuildContext context) =>
      Theme.of(context).colorScheme.errorContainer;
}

const _lightScheme = ColorScheme(
  brightness: Brightness.light,
  primary: AppPalette.accent,
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFFE6F4F1),
  onPrimaryContainer: Color(0xFF0B5550),
  secondary: Color(0xFF4A5D5A),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFFE3ECEA),
  onSecondaryContainer: Color(0xFF1F3532),
  tertiary: Color(0xFF1D5BD6),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFE8EFFD),
  onTertiaryContainer: Color(0xFF16357A),
  error: Color(0xFFB42318),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0xFFFDECEA),
  onErrorContainer: Color(0xFF7A1A12),
  surface: AppPalette.lightCanvas,
  onSurface: Color(0xFF1A1C1E),
  onSurfaceVariant: Color(0xFF55595F),
  surfaceContainerLowest: Color(0xFFFFFFFF),
  surfaceContainerLow: Color(0xFFFFFFFF),
  surfaceContainer: Color(0xFFF0F0EC),
  surfaceContainerHigh: Color(0xFFE7E7E2),
  surfaceContainerHighest: Color(0xFFDEDED8),
  outline: Color(0xFFCACAC2),
  outlineVariant: Color(0xFFE2E2DC),
  inverseSurface: Color(0xFF1A1C1E),
  onInverseSurface: Color(0xFFECEEF0),
  inversePrimary: AppPalette.accentDark,
  scrim: Color(0xFF101214),
  surfaceTint: Colors.transparent,
);

const _darkScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: AppPalette.accentDark,
  onPrimary: Color(0xFF04201D),
  primaryContainer: Color(0xFF12302C),
  onPrimaryContainer: Color(0xFF8FE5D9),
  secondary: Color(0xFF9FC2BC),
  onSecondary: Color(0xFF0F2421),
  secondaryContainer: Color(0xFF1F3532),
  onSecondaryContainer: Color(0xFFCFE3DF),
  tertiary: Color(0xFF7AA7FF),
  onTertiary: Color(0xFF0A1A3A),
  tertiaryContainer: Color(0xFF172540),
  onTertiaryContainer: Color(0xFFC9DAFF),
  error: Color(0xFFF87171),
  onError: Color(0xFF2D0A0A),
  errorContainer: Color(0xFF331A1A),
  onErrorContainer: Color(0xFFFECACA),
  surface: AppPalette.darkCanvas,
  onSurface: Color(0xFFECEEF0),
  onSurfaceVariant: Color(0xFFA7ADB4),
  surfaceContainerLowest: Color(0xFF16191C),
  surfaceContainerLow: Color(0xFF16191C),
  surfaceContainer: Color(0xFF1D2125),
  surfaceContainerHigh: Color(0xFF252A2F),
  surfaceContainerHighest: Color(0xFF2E3439),
  outline: Color(0xFF3B4148),
  outlineVariant: Color(0xFF2A2F35),
  inverseSurface: Color(0xFFECEEF0),
  onInverseSurface: Color(0xFF1A1C1E),
  inversePrimary: AppPalette.accent,
  scrim: Color(0xFF000000),
  surfaceTint: Colors.transparent,
);

BoxShadow receiptShadow(Brightness brightness, {bool strong = false}) {
  final dark = brightness == Brightness.dark;
  return BoxShadow(
    color: (dark ? Colors.black : const Color(0xFF101828)).withValues(
      alpha: strong ? (dark ? .70 : .28) : (dark ? .55 : .12),
    ),
    blurRadius: strong ? 48 : 16,
    offset: Offset(0, strong ? 24 : 8),
    spreadRadius: strong ? -12 : -4,
  );
}

ThemeData receiptTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final scheme = dark ? _darkScheme : _lightScheme;
  final tokens = dark ? ReceiptTokens.dark : ReceiptTokens.light;
  final surface = scheme.surfaceContainerLowest;
  const radius = BorderRadius.all(Radius.circular(12));
  const dialogShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(16)),
  );
  const buttonShape = RoundedRectangleBorder(borderRadius: radius);
  final outline = BorderSide(color: scheme.outline);
  final divider = BorderSide(color: scheme.outlineVariant);
  final scrim = scheme.scrim.withValues(alpha: dark ? .60 : .45);
  final shadow = receiptShadow(brightness, strong: true).color;

  TextStyle type(
    double size,
    double line,
    FontWeight weight, [
    double tracking = 0,
  ]) => TextStyle(
    fontSize: size,
    height: line / size,
    fontWeight: weight,
    letterSpacing: tracking,
    color: scheme.onSurface,
    fontFeatures: const [FontFeature.tabularFigures()],
  );

  const regular = FontWeight.w400;
  const medium = FontWeight.w500;
  const semibold = FontWeight.w600;
  const bold = FontWeight.w700;
  final material = Typography.material2021(colorScheme: scheme);
  final text = (dark ? material.white : material.black).merge(
    TextTheme(
      displaySmall: type(36, 44, bold, -.5),
      headlineLarge: type(28, 34, bold, -.4),
      headlineSmall: type(22, 28, bold, -.2),
      titleLarge: type(20, 28, semibold, -.2),
      titleMedium: type(16, 24, semibold),
      titleSmall: type(14, 20, semibold),
      bodyLarge: type(16, 24, regular),
      bodyMedium: type(14, 20, regular),
      bodySmall: type(12, 16, regular),
      labelLarge: type(14, 20, semibold),
      labelMedium: type(12, 16, medium),
      labelSmall: type(11, 16, semibold),
    ),
  );

  final supporting = text.bodySmall!.copyWith(color: tokens.text3);
  final menu = MenuStyle(
    backgroundColor: WidgetStatePropertyAll(surface),
    surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
    shape: const WidgetStatePropertyAll(buttonShape),
    elevation: const WidgetStatePropertyAll(2),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    extensions: [tokens],
    textTheme: text,
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    focusColor: scheme.primary.withValues(alpha: .12),
    appBarTheme: AppBarTheme(
      backgroundColor: surface,
      foregroundColor: scheme.onSurface,
      surfaceTintColor: Colors.transparent,
      systemOverlayStyle: systemBars(brightness),
      elevation: 0,
      scrolledUnderElevation: 0,
      shape: Border(bottom: divider),
      centerTitle: false,
      toolbarHeight: 64,
      titleTextStyle: text.titleLarge,
    ),
    cardTheme: CardThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: radius, side: divider),
      clipBehavior: Clip.antiAlias,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surface,
      border: OutlineInputBorder(borderRadius: radius, borderSide: outline),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: outline,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.error),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: scheme.error, width: 2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: divider,
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.lg,
      ),
      labelStyle: text.bodyLarge!.copyWith(color: scheme.onSurfaceVariant),
      floatingLabelStyle: text.bodyLarge!.copyWith(color: scheme.primary),
      hintStyle: supporting,
      helperStyle: supporting,
      errorStyle: supporting.copyWith(color: scheme.error),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(menuStyle: menu),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: Space.xl),
        textStyle: text.labelLarge,
        shape: buttonShape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        foregroundColor: scheme.onSurface,
        textStyle: text.labelLarge,
        side: outline,
        shape: buttonShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 40),
        textStyle: text.labelLarge,
        shape: buttonShape,
      ),
    ),
    iconButtonTheme: const IconButtonThemeData(
      style: ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(48, 48))),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surface,
      selectedColor: scheme.primaryContainer,
      secondarySelectedColor: scheme.primaryContainer,
      labelStyle: text.labelMedium!.copyWith(
        fontSize: 13,
        color: scheme.onSurfaceVariant,
      ),
      secondaryLabelStyle: text.labelMedium!.copyWith(
        fontSize: 13,
        color: scheme.onPrimaryContainer,
        fontWeight: semibold,
      ),
      padding: const EdgeInsets.symmetric(horizontal: Space.md),
      labelPadding: EdgeInsets.zero,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      side: outline,
      showCheckmark: false,
      iconTheme: IconThemeData(size: 16, color: scheme.onSurfaceVariant),
      surfaceTintColor: Colors.transparent,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: const WidgetStatePropertyAll(StadiumBorder()),
        side: WidgetStatePropertyAll(outline),
        minimumSize: const WidgetStatePropertyAll(Size(0, 40)),
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.primaryContainer
              : surface,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(4)),
      ),
      side: BorderSide(color: scheme.onSurfaceVariant, width: 2),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      barrierColor: scrim,
      shadowColor: shadow,
      shape: dialogShape,
      elevation: 6,
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium!.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      modalBarrierColor: scrim,
      showDragHandle: true,
      dragHandleColor: scheme.outline,
      dragHandleSize: const Size(32, 4),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      contentTextStyle: text.bodyMedium!.copyWith(
        color: scheme.onInverseSurface,
      ),
      actionTextColor: scheme.inversePrimary,
      closeIconColor: scheme.onInverseSurface,
      shape: buttonShape,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      elevation: 3,
    ),
    navigationDrawerTheme: NavigationDrawerThemeData(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 1,
      shadowColor: shadow,
      tileHeight: 52,
      indicatorColor: scheme.primaryContainer,
      indicatorShape: const StadiumBorder(),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        return text.labelLarge!.copyWith(
          color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
          fontWeight: selected ? semibold : medium,
        );
      }),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? scheme.onPrimaryContainer
              : scheme.onSurfaceVariant,
        ),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg),
      iconColor: scheme.onSurfaceVariant,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall!.copyWith(
        color: scheme.onSurfaceVariant,
      ),
      minVerticalPadding: Space.sm,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: scheme.primary,
      linearTrackColor: scheme.primaryContainer,
      circularTrackColor: Colors.transparent,
      linearMinHeight: 3,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: surface,
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shape: buttonShape,
    ),
    menuTheme: MenuThemeData(style: menu),
    expansionTileTheme: ExpansionTileThemeData(
      shape: const Border(),
      collapsedShape: const Border(),
      tilePadding: const EdgeInsets.symmetric(horizontal: Space.lg),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      iconColor: scheme.onSurfaceVariant,
      collapsedIconColor: scheme.onSurfaceVariant,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: text.bodySmall!.copyWith(color: scheme.onInverseSurface),
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final contrast = MediaQuery.highContrastOf(context);
    final fill = theme.brightness == Brightness.dark
        ? scheme.surfaceContainer
        : scheme.surfaceContainerLowest;
    final edge = BorderSide(color: scheme.outlineVariant);
    final body = DecoratedBox(
      decoration: BoxDecoration(
        color: fill.withValues(alpha: contrast ? 1 : .92),
        borderRadius: radius,
        border: radius == null
            ? Border(bottom: edge)
            : Border.fromBorderSide(edge),
      ),
      child: Material(type: MaterialType.transparency, child: child),
    );
    final surface = contrast
        ? body
        : BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: body,
          );
    if (radius == null) return ClipRect(child: surface);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [receiptShadow(theme.brightness)],
      ),
      child: ClipRRect(borderRadius: radius!, child: surface),
    );
  }
}

class PageHeading extends StatelessWidget {
  const PageHeading({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.status,
    this.statusColor,
  });

  final String title, subtitle;
  final String? status;
  final Color? statusColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 12, 12, 16),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.headlineLarge),
              const SizedBox(height: 2),
              Text.rich(
                TextSpan(
                  text: subtitle,
                  children: [
                    if (status != null)
                      TextSpan(
                        text: '\n$status',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: statusColor),
                      ),
                  ],
                ),
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: AppPalette.muted(context)),
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
          (
            ThemeMode.system,
            Icons.brightness_auto_outlined,
            context.tr("跟随系统"),
          ),
          (ThemeMode.light, Icons.light_mode_outlined, context.tr("浅色")),
          (ThemeMode.dark, Icons.dark_mode_outlined, context.tr("深色")),
        ])
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Space.xs),
              child: Semantics(
                selected: appearance.mode == mode,
                child: AnimatedContainer(
                  duration: MediaQuery.disableAnimationsOf(context)
                      ? Duration.zero
                      : Motion.base,
                  curve: Motion.standard,
                  decoration: BoxDecoration(
                    color: appearance.mode == mode
                        ? scheme.primaryContainer
                        : scheme.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: appearance.mode == mode
                          ? scheme.primary
                          : scheme.outlineVariant,
                      width: appearance.mode == mode ? 2 : 1,
                    ),
                  ),
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () async {
                        try {
                          await appearance.setMode(mode);
                        } catch (e) {
                          onError(e);
                        }
                      },
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: 72),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.xs,
                            vertical: Space.sm,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                icon,
                                size: 24,
                                color: appearance.mode == mode
                                    ? scheme.onPrimaryContainer
                                    : scheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: Space.xs),
                              Text(
                                label,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.labelMedium
                                    ?.copyWith(
                                      color: appearance.mode == mode
                                          ? scheme.onPrimaryContainer
                                          : scheme.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
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
