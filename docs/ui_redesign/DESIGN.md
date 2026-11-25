# Receipt Master UI redesign: "Ledger"

Status: design spec, ready for implementation. Audience: the engineer implementing it (Codex).
Companion mockups: [`web_mockup.html`](web_mockup.html) and [`android_mockup.html`](android_mockup.html). Open them directly in a browser; both use a toggle to show light and dark.

This is a visual and layout refresh only. Every API call, flow, element behavior, accessible name and localization key stays the same. Where this spec asks for a JSX or widget change, the change is limited to wrappers, class names, ordering or style. It never touches data flow. §9 lists what the existing tests pin; read it before you touch a screen.

---

## 0. What is wrong today, and the direction

The problems, as observed in the current code:

1. **Glass everywhere.** Translucent panels and `backdrop-filter` / `BackdropFilter` blur on toolbars, drawers, the save bar and dialogs. The result is low contrast, muddy dark mode and visual noise.
2. **No structure.** Content floats on the canvas with no containers. Tables, forms and lists are hairlines on a tinted background, so the eye cannot find groups.
3. **Shouting headings.** Every web page carries a fixed "RECEIPT MASTER" eyebrow and a 44 px title. Android uses 34 px w800 titles and a 38 px gradient hero.
4. **Status is shown by flooding rows** with yellow or pink (`.receipt-table tr.draft td`, `.line.warning`, Flutter `warningSurface` cards). Status reads as an error state, and the text sits on low-contrast fills.
5. **Desktop web hides navigation** behind a hamburger, even at 1440 px.
6. **The two clients are inconsistent.** The web uses accent `#3159D9` and radii of 10–22 px. Flutter uses a `fromSeed` palette, radii of 17/18/22/28 and a separate iOS-blue palette. Flutter has one `Notice` color for errors, info and warnings, and mixed section-title sizes (titleLarge, headlineSmall, and hard-coded 20/22).

**Direction: "Ledger".** The app should feel like a calm, precise bookkeeping tool: paper and ink.

- Warm-neutral paper surfaces, near-black ink, and one confident **teal** accent for primary actions and selection.
- Flat, bordered **cards** group content. Shadows appear only on things that float: menus, the dock, dialogs and the save bar.
- **Numbers are the hero.** Amounts use tabular figures, right alignment and a heavier weight.
- Status uses **small semantic badges plus a 3 px leading stripe**, not full-row floods.
- One token set, used with the same hex values on web (CSS custom properties) and on Flutter (`ColorScheme` plus a `ThemeExtension`).

---

## 1. Design principles

1. **Content first, chrome quiet.** Bars are solid and neutral. The accent color is reserved for the one primary action per view, the selection state and the "total" chart line.
2. **Group by card.** Anything that belongs together sits in a bordered card with a 12 px radius. A page is a column of cards.
3. **Status is small and honest.** A badge and a stripe show it, never a full-row fill. Errors are red, needs-review is amber, processing is blue, and done is quiet (no badge on web; a neutral icon on mobile).
4. **Money is legible.** Use `font-variant-numeric: tabular-nums` / `FontFeature.tabularFigures()` everywhere an amount or date appears. Amounts align right in tables and get weight 600–700.
5. **Same system, native feel.** The tokens are identical on both clients. Web uses 40 px pointer controls and a persistent sidebar. Mobile uses 48 px or larger touch controls, the existing floating dock and the drawer.
6. **No new runtime dependencies.** Fonts are system stacks only. Icons are the existing inline SVG paths on web and the Material `Icons` / `CupertinoIcons` already in Flutter. No CDNs. The web CSP (`default-src 'self'; style-src 'self' 'unsafe-inline'`, set in `src/backend_api/src/lib.rs`) needs no change.
7. **Accessible by default.** WCAG 2.2 AA contrast, visible focus rings, 44×44 minimum targets on touch, `prefers-reduced-motion` / `disableAnimations` honoured.

---

## 2. Design tokens (shared by web and Flutter)

The **token name** is the source of truth. On web it is a CSS custom property; on Flutter it maps to a `ColorScheme` role or a `ReceiptTokens` ThemeExtension field (§2.8).

### 2.1 Color: light

| Token | Hex | Use | Flutter |
|---|---|---|---|
| `--bg` | `#F6F6F3` | Page/canvas background | `scheme.surface` and `scaffoldBackgroundColor` |
| `--surface` | `#FFFFFF` | Cards, inputs, bars, dialogs | `surfaceContainerLowest` **and** `surfaceContainerLow` |
| `--surface-2` | `#F0F0EC` | Hover, table header, segmented track, subtle fill | `surfaceContainer` |
| `--surface-3` | `#E7E7E2` | Pressed, avatar, neutral selected | `surfaceContainerHigh` |
| — | `#DEDED8` | (Flutter only) | `surfaceContainerHighest` |
| `--border` | `#E2E2DC` | Card borders, dividers | `outlineVariant` |
| `--border-strong` | `#CACAC2` | Input and secondary-button borders | `outline` |
| `--text` | `#1A1C1E` | Primary text | `onSurface` |
| `--text-2` | `#55595F` | Secondary text, labels (7.0:1 on white) | `onSurfaceVariant` |
| `--text-3` | `#6A6E75` | Meta, captions, placeholders (≥4.5:1 on `--bg` and white) | `ReceiptTokens.text3` |
| `--primary` | `#0F766E` | Primary buttons, selection, focus, links | `primary` |
| `--primary-hover` | `#115E59` | Primary hover/pressed | (state layer) |
| `--on-primary` | `#FFFFFF` | Text on primary (5.47:1) | `onPrimary` |
| `--primary-soft` | `#E6F4F1` | Selected nav item, tonal button, chips | `primaryContainer` |
| `--on-primary-soft` | `#0B5550` | Text on primary-soft (7.65:1) | `onPrimaryContainer` |
| `--success` | `#136C34` | Confirmed, positive | `ReceiptTokens.success` |
| `--success-soft` | `#E7F6EC` | Success badge background | `ReceiptTokens.successSoft` |
| `--warning` | `#9A5B00` | Draft / needs review text, icon, stripe | `ReceiptTokens.warning` |
| `--warning-soft` | `#FDF1DC` | Warning badge and notice background, draft row fill on mobile | `ReceiptTokens.warningSoft` (= `AppPalette.warningSurface`) |
| `--warning-tint` | `#FEF8EC` | Very light row tint (web line items) | `ReceiptTokens.warningTint` |
| `--warning-border` | `#F2C97D` | Notice and warning-card border | `ReceiptTokens.warningBorder` |
| `--danger` | `#B42318` | Errors, destructive | `error` |
| `--on-danger` | `#FFFFFF` | | `onError` |
| `--danger-soft` | `#FDECEA` | Error badge and notice background, failed row | `errorContainer` (= `AppPalette.errorSurface`) |
| — | `#7A1A12` | | `onErrorContainer` |
| `--danger-tint` | `#FEF4F3` | Very light row tint (web line items) | `ReceiptTokens.dangerTint` |
| `--danger-border` | `#F4B4AE` | Error notice and missing-name card border | `ReceiptTokens.dangerBorder` |
| `--info` | `#1D5BD6` | Processing / recognizing, info notices | `tertiary` and `ReceiptTokens.info` |
| `--info-soft` | `#E8EFFD` | Info badge, upload banner | `tertiaryContainer` and `ReceiptTokens.infoSoft` |
| — | `#16357A` | | `onTertiaryContainer` |
| `--scrim` | `rgb(16 18 20 / 45%)` | Modal/drawer backdrop | `scrim` = `#101214`, alpha .45 |
| `--photo-bg` | `#2A2D31` | Behind receipt photos | `ReceiptTokens.photoBg` |
| `--inverse` | `#1A1C1E` / text `#ECEEF0` | Toast/snackbar | `inverseSurface` / `onInverseSurface`; `inversePrimary` = `#3FC6B4` |

Flutter `secondary` = `#4A5D5A`, `onSecondary` = `#FFFFFF`, `secondaryContainer` = `#E3ECEA`, `onSecondaryContainer` = `#1F3532`. Secondary is rarely used; it is defined so that M3 widgets do not fall back to seed colors.

### 2.2 Color: dark

| Token | Hex | Flutter |
|---|---|---|
| `--bg` | `#0E1012` | `surface` |
| `--surface` | `#16191C` | `surfaceContainerLowest`, `surfaceContainerLow` |
| `--surface-2` | `#1D2125` | `surfaceContainer` |
| `--surface-3` | `#252A2F` | `surfaceContainerHigh` |
| — | `#2E3439` | `surfaceContainerHighest` |
| `--border` | `#2A2F35` | `outlineVariant` |
| `--border-strong` | `#3B4148` | `outline` |
| `--text` | `#ECEEF0` | `onSurface` |
| `--text-2` | `#A7ADB4` (7.8:1 on surface) | `onSurfaceVariant` |
| `--text-3` | `#8A9098` (5.5:1) | `text3` |
| `--primary` | `#3FC6B4` | `primary` |
| `--primary-hover` | `#5ED6C6` | |
| `--on-primary` | `#04201D` (8.1:1) | `onPrimary` |
| `--primary-soft` | `#12302C` | `primaryContainer` |
| `--on-primary-soft` | `#8FE5D9` | `onPrimaryContainer` |
| `--success` / `--success-soft` | `#4ADE80` / `#12291B` | |
| `--warning` / `--warning-soft` / `--warning-tint` / `--warning-border` | `#F5B544` / `#2E2410` / `#221C10` / `#5C4718` | |
| `--danger` / `--on-danger` / `--danger-soft` / `--danger-tint` / `--danger-border` | `#F87171` / `#2D0A0A` / `#331A1A` / `#261515` / `#6B2B2B` | `error`, `onError`, `errorContainer`; `onErrorContainer` = `#FECACA` |
| `--info` / `--info-soft` | `#7AA7FF` / `#172540` | `tertiary` / `tertiaryContainer`; `onTertiary` = `#0A1A3A`, `onTertiaryContainer` = `#C9DAFF` |
| `--scrim` | `rgb(0 0 0 / 60%)` | |
| `--photo-bg` | `#0A0B0C` | |
| `--inverse` | `#ECEEF0` / text `#1A1C1E` | `inverseSurface` / `onInverseSurface`; `inversePrimary` = `#0F766E` |

Flutter dark `secondary` = `#9FC2BC`, `onSecondary` = `#0F2421`, `secondaryContainer` = `#1F3532`, `onSecondaryContainer` = `#CFE3DF`.

Every text/background pair above was checked to be ≥4.5:1, and every non-text UI pair (stripe, focus ring, chart line) to be ≥3:1.

### 2.3 Chart palette (same in both modes)

These are mid-luminance colors chosen so that each is ≥3:1 against both `#FFFFFF` and `#16191C`. The web needs one palette because `stroke` must stay a literal color (§9).

| Slot | Hex | Use |
|---|---|---|
| chart-0 | `#14937F` | **Total** line (web). Flutter's total line uses `scheme.primary`. |
| chart-1 | `#E0682F` | series |
| chart-2 | `#5B6FE8` | series |
| chart-3 | `#D04E79` | series |
| chart-4 | `#B3841A` | series |
| chart-5 | `#8E5BD6` | series |
| chart-6 | `#3E8ED0` | series |

The hashing of series keys to slots is unchanged: web `trendColor()`, Flutter `_TrendPainter`.

### 2.4 Typography

Font stacks. Do **not** load Inter or any web font; delete `Inter` from the stack.

- Web: `system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans CJK SC", "Noto Sans SC", sans-serif`
- Mono (IDs only): `ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace`
- Flutter: do not set `fontFamily`. The platform default (Roboto / SF + CJK fallback) is correct.

| Role | Size / line height | Weight | Tracking | Web usage | Flutter `TextTheme` slot |
|---|---|---|---|---|---|
| display | 36/44 | 700 | −0.5 | Report hero amount (mobile) | `displaySmall` |
| page-title | 28/36 web, 28/34 Flutter | 700 | −0.4 (−0.02em) | `h1` in `.page-heading` | `headlineLarge` (PageHeading) |
| heading | 22/28 | 700 | −0.2 | Editor "核对这张收据", Settings username | `headlineSmall` |
| title-lg | 20/28 | 650 web / w600 Flutter | −0.2 | Section `h2`, app-bar title, dialog title | `titleLarge` |
| title | 16/24 | 600 | 0 | Card headers, settings section titles | `titleMedium` |
| title-sm | 14/20 | 600 | 0 | Row titles, store name | `titleSmall` |
| body-lg | 16/24 | 400 | 0 | Flutter inputs | `bodyLarge` |
| body | 14/20 | 400 | 0 | Default text | `bodyMedium` |
| body-sm | 12/16 | 400 | 0 | Meta, hints, captions (`--text-2` / `text3`) | `bodySmall` |
| label | 14/20 | 600 (web 500 for secondary buttons) | 0 | Buttons | `labelLarge` |
| label-md | 13/18 web, 12/16 Flutter | 500 | 0 | Field labels, chips | `labelMedium` |
| label-sm | 11/16 or 12/16 | 600 | 0 | Table headers, badges | `labelSmall` (11) |
| kpi | 28/36 | 650 | −0.02em | Web KPI tiles | — |

Rules:
- Amounts and dates always use tabular figures. Web: class `.numeric`. Flutter: `fontFeatures: [FontFeature.tabularFigures()]`.
- No uppercase eyebrows. Delete the `RECEIPT MASTER` eyebrow (it is not a localization key).
- The Flutter heading sizes in `app_theme.dart` change from 34/w800 → 28/w700, 25 → 22, and the AppBar title from 23 → 20.

### 2.5 Spacing (4 px grid)

`space-1` 4 · `space-2` 8 · `space-3` 12 · `space-4` 16 · `space-5` 20 · `space-6` 24 · `space-8` 32 · `space-10` 40 · `space-12` 48 · `space-16` 64

- Web page gutter: 32 px at ≥1024 px, 24 px at 640–1023 px, 16 px below that. Content max-width is 1200 px (Settings: 720 px).
- Card padding: 20 px on web (16 px below 640 px); 16 px on Flutter.
- Gaps: 16 px between form fields, 16 px between cards, 32 px before a new page section.
- Flutter: add `abstract final class Space { static const xs = 4.0, sm = 8.0, md = 12.0, lg = 16.0, xl = 20.0, x2l = 24.0, x3l = 32.0, x4l = 40.0; }` to `app_theme.dart`.

### 2.6 Radii

| Token | Value | Used by |
|---|---|---|
| `--r-xs` | 4 px | Checkbox, chart-legend swatch |
| `--r-sm` | 8 px | **Web** buttons, inputs, nav items, chips; Flutter chips; logo thumbnails |
| `--r-md` | 12 px | Cards everywhere; **Flutter** buttons and inputs (48 px controls); notices; photo tiles |
| `--r-lg` | 16 px | Dialogs, bottom sheets, report hero, page overlay (not used at full-screen) |
| `--r-xl` | 20 px | Flutter floating dock pills |
| `--r-pill` | 999 px | Badges, save-bar pill (mobile), drawer item indicator |

Pointer controls (40 px tall) use 8 px; touch controls (48 px or taller) use 12 px. This keeps both visually proportional.

### 2.7 Elevation

Cards are **flat**: a 1 px `--border` and no shadow. Shadows mark only floating layers.

| Level | Web `box-shadow` (light) | Dark | Flutter | Used by |
|---|---|---|---|---|
| e0 | none + 1 px border | same | `elevation: 0` + `side: outlineVariant` | Cards, tables, bars |
| e1 | `0 1px 2px rgb(16 24 40/6%), 0 1px 3px rgb(16 24 40/8%)` | `0 1px 2px rgb(0 0 0/40%)` | elevation 1 | Segmented "thumb" |
| e2 | `0 2px 4px rgb(16 24 40/6%), 0 8px 16px -4px rgb(16 24 40/12%)` | `0 8px 24px -4px rgb(0 0 0/55%)` | `BoxShadow(color: #101828 α.12, blur 16, offset (0,8), spread −4)` | Popovers, autocomplete, dock, toast, login card |
| e3 | `0 24px 48px -12px rgb(16 24 40/28%)` | `0 24px 48px -12px rgb(0 0 0/70%)` | `BoxShadow(α.28 / dark .7, blur 48, offset (0,24), spread −12)` | Dialogs, drawer, save-bar pill |

Glass: remove every `backdrop-filter` on web. In Flutter, `FrostedBar` keeps its name and API (tests find it by type) but becomes a near-opaque surface (§3.1).

Set `surfaceTintColor: Colors.transparent` in every Flutter component theme that has it (Card, Dialog, BottomSheet, NavigationDrawer, PopupMenu, Menu) so M3 tinting does not shift the palette.

### 2.8 Flutter ThemeExtension

Add to `app_theme.dart`:

```dart
@immutable
class ReceiptTokens extends ThemeExtension<ReceiptTokens> {
  const ReceiptTokens({required this.text3, required this.success, required this.successSoft,
    required this.warning, required this.warningSoft, required this.warningTint, required this.warningBorder,
    required this.dangerTint, required this.dangerBorder, required this.info, required this.infoSoft,
    required this.photoBg, required this.chart});
  final Color text3, success, successSoft, warning, warningSoft, warningTint, warningBorder,
      dangerTint, dangerBorder, info, infoSoft, photoBg;
  final List<Color> chart; // §2.3, index 0 = total
  static const light = ReceiptTokens(/* §2.1 values */);
  static const dark  = ReceiptTokens(/* §2.2 values */);
  // copyWith + lerp (lerp: Color.lerp per field; chart: t < .5 ? a : b)
}
extension ReceiptTokensX on BuildContext {
  ReceiptTokens get tokens => Theme.of(this).extension<ReceiptTokens>()!;
}
```

Keep `AppPalette`; tests call it. Re-implement it in terms of the tokens:
- `accent` = `#0F766E`, `accentDark` = `#3FC6B4`, `lightCanvas` = `#F6F6F3`, `darkCanvas` = `#0E1012`
- `warningSurface(ctx)` → `ReceiptTokens.warningSoft` (light `#FDF1DC` / dark `#2E2410`)
- `errorSurface(ctx)` → `scheme.errorContainer` (light `#FDECEA` / dark `#331A1A`)
- `muted(ctx)` unchanged
- Add `static const cameraAccent = Color(0xFF3FC6B4);`. The camera UI is always dark.

Build the `ColorScheme` with the explicit constructor (`ColorScheme(brightness: …, primary: …, …)`) from §2.1 and §2.2. **Do not use `fromSeed`.** Delete the iOS-blue scheme branch: iOS uses the same palette. Keep the iOS-specific *behaviors*: Cupertino icons in the home toolbar, larger radii on the iOS dock (§6.2), and platform page transitions.

### 2.9 Motion

| Token | Value | Use |
|---|---|---|
| `--dur-fast` | 120 ms | Hover, press, color changes |
| `--dur-base` | 180 ms | Tabs, chips, segmented, checkbox, toast in |
| `--dur-slow` | 260 ms | Drawer, dialog, bottom sheet enter |
| exit | 0.75 × enter | |
| `--ease-standard` | `cubic-bezier(.2, 0, 0, 1)` | Default; Flutter `Cubic(0.2, 0, 0, 1)` |
| `--ease-decel` | `cubic-bezier(0, 0, 0, 1)` | Entering elements |
| `--ease-accel` | `cubic-bezier(.3, 0, 1, 1)` | Exiting elements |

- Web: wrap every transition and animation in `@media (prefers-reduced-motion: no-preference)`. This block already exists in `style.css`; extend it.
- Animate the drawer with `translateX(-100%) → 0` (slow, decel). The toast slides up 8 px with a fade (base). The dialog scales 0.98 → 1 with a fade (slow, decel).
- Flutter: add `abstract final class Motion { static const fast = Duration(milliseconds: 120), base = …180, slow = …260; static const standard = Cubic(.2, 0, 0, 1); }`. Where widgets animate explicitly, use `MediaQuery.disableAnimationsOf(context) ? Duration.zero : Motion.base`. Do not add page-transition packages.

### 2.10 Iconography

- Web: keep the inline SVG `paths` map and the `Icon` component in `main.tsx`. Change `strokeWidth` from 1.6 to 1.75, default size 20 (16 in dense rows). Add two paths: `alert` (`M12 3 2 20h20zM12 10v4M12 17v.5`) for callouts and `chevron` (`m9 6 6 6-6 6`) for group rows.
- Flutter: use Material **outlined** icons for the unselected state and filled ones for selected, as today. Icon color is `onSurfaceVariant` by default and `primary` only when selected or for the primary action. Change `listTileTheme.iconColor` from `primary` to `onSurfaceVariant`.

### 2.11 Layering (web z-index)

Content 0 · sticky table header 1 · editor save bar 2 · top bar 20 · drawer shade 21 · drawer 22 · autocomplete 30 · toast 40 · offline notice 41. Native `<dialog>` stays in the top layer.

---

## 3. Components

Each component has a web spec (selector in `src/web/src/style.css`) and a Flutter spec (theme or widget in `src/shared/lib/ui/`).

### 3.1 Top bar / app bar

**Web `.toolbar`:**
- Height 64 px (56 px below 768 px). Background `--bg` with a 1 px `--border` bottom border. **No blur, no translucency.**
- At ≥1024 px it starts after the sidebar (`left: 248px`) and contains: spacer, page actions, account chip.
- Below 1024 px it contains: menu icon button, wordmark (16 px/700), spacer, icon-only actions.
- Receipts-page actions (`拍照` / `上传照片` / `手动录入`):
  - At ≥1024 px they show icon + label. `拍照` is the primary button; the other two are secondary buttons.
  - Below 1024 px they are icon-only 40×40 buttons, as today.
- Account chip (`.account-label`): 28 px avatar circle (`--surface-3`, first letter of the username, 12 px/600) followed by the username, with a 1 px left divider. Hidden below 768 px.

**Flutter:**
- `AppBarTheme`: `backgroundColor: scheme.surfaceContainerLowest`, `surfaceTintColor: transparent`, `elevation: 0`, `scrolledUnderElevation: 0`, `shape: Border(bottom: BorderSide(color: outlineVariant))`, `titleTextStyle: titleLarge`, `centerTitle: false`, `toolbarHeight: 64`.
- `FrostedBar` keeps its constructor and remains a `StatelessWidget`. The new rendering is the same on all platforms:
  - Fill: light `surfaceContainerLowest` α .92; dark `surfaceContainer` α .92.
  - Blur σ20 (`BackdropFilter`) so content behind stays faintly visible. With `MediaQuery.highContrastOf` → opaque fill, no blur.
  - Border: 1 px `outlineVariant`. When `radius == null`, top or bottom edge only, as today.
  - Shadow: e2 when `radius != null`.
  - Delete the gradient, the white rim and the iOS-only branch.

### 3.2 Navigation

**Web, ≥1024 px: persistent sidebar.** The existing `nav.drawer` is rendered docked.
- Width 248 px, fixed, full height. Background `--surface`, 1 px right border, padding 16 px 12 px.
- `.drawer-brand`: 32 px mark (8 px radius, `--primary` fill, `receipt` icon in `--on-primary`) plus "Receipt Master" in 16/700. 20 px below.
- Items (`.drawer button`): 40 px tall, radius 8, padding 0 12 px, 12 px gap, icon 20, label 14/500 `--text-2`.
  - Hover: `--surface-2` with `--text`.
  - `.active`: `--primary-soft` background, `--on-primary-soft` text, weight 600.
- `.android-download`: same item style, preceded by a 1 px divider with 10 px margins. Remove its special border-top and border-radius 0.
- `.drawer small` (footer): pinned bottom with a top border. 32 px avatar, then the username (14/600) with `· 私人数据空间` in body-sm `--text-3` below it.
- The shade is not rendered.

**Web, below 1024 px: drawer (current behavior).**
- The same `nav.drawer` slides in from the left, below the toolbar (top 64, or 56 below 768 px, as today). Width `min(300px, 85vw)`, `--surface` (opaque, no blur), e3 shadow.
- The shade is a `--scrim` covering the area below the toolbar. `打开导航菜单` / `关闭导航菜单` behavior is unchanged.

**Implementation (main.tsx `Workspace`):** add a hook:

```ts
function useWide() {
  const query = "(min-width: 1024px)";
  const get = () => window.matchMedia?.(query).matches ?? false;
  const [wide, setWide] = useState(get);
  useEffect(() => { const m = window.matchMedia?.(query); if (!m) return;
    const f = () => setWide(m.matches); m.addEventListener("change", f); return () => m.removeEventListener("change", f); }, []);
  return wide;
}
```

- Render the nav when `drawer || wide`. Give it the classes `"drawer" + (wide ? " docked" : "")`.
- Render the shade only when `drawer && !wide`. Hide the menu button with CSS at ≥1024 px.
- Add the class `has-sidebar` to `.workspace` and `.toolbar` when `wide`, to apply the 248 px offset.
- jsdom has no `matchMedia`, so `wide` is false and test behavior is unchanged (§9).

**Flutter: floating dock plus `NavigationDrawer` (structure kept; restyled).**
- Dock, as today: menu pill at left 14 and action pill at right 14, both at bottom inset + 14, each a `FrostedBar(radius: 20)` (iOS: 24 for the pill and a circular menu button).
  - Menu `IconButton` 58×58, icon `menu_rounded` 26 in `onSurface`.
  - `_QuickAction` targets stay 58 tall.
    - Primary (`拍照`): an inner 48×48 (pill padding 5) `primary` fill, radius 14, icon `onPrimary` 24.
    - Others: transparent with `onSurface` icon 24. Pressed: `onSurface` state layer α .08.
  - iOS: primary fill is `primary` (not α .16); radius 18.
- `NavigationDrawerThemeData`:
  - `backgroundColor: surfaceContainerLowest`, `surfaceTintColor: transparent`, `elevation: 1`, `shadowColor` e3.
  - `indicatorColor: primaryContainer`, `indicatorShape: StadiumBorder()`, `tileHeight: 52`.
  - `labelTextStyle`: 14/500 `onSurfaceVariant`, and 14/600 `onPrimaryContainer` when selected.
  - `iconTheme`: 24, `onSurfaceVariant` / `onPrimaryContainer` when selected.
  - Drawer shape: `RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(16)))`.
- Drawer header (`home.dart`, replaces the 26 pt w800 text): a Row with padding 28/40/16/20.
  - A 40 px mark: Container radius 10, `primary` fill, `Icons.receipt_long` 22 `onPrimary`.
  - 12 px gap, then a Column with "Receipt Master" (titleLarge w700) and the username in bodySmall `text3`. Use `AuthSession.instance.user?['username']`, already available.
- iOS keeps the frosted drawer wrapper with the new `FrostedBar` look and scrim `scrim` α .45.
- Do **not** add a `NavigationBar`. Delete the unused `navigationBarTheme` from `receiptTheme`.

### 3.3 Buttons

| Variant | Web | Flutter |
|---|---|---|
| Primary | `button.primary`: `--primary` bg, `--on-primary` text, 600, no border; hover `--primary-hover` | `FilledButton`: bg `primary`, fg `onPrimary`, min 48, radius 12, padding h20, `labelLarge` |
| Secondary (default) | `button`, `a.button`: `--surface` bg, 1 px `--border-strong`, `--text`, 500; hover `--surface-2` | `OutlinedButton`: side 1 px `outline`, fg `onSurface`, radius 12, min 48 |
| Tonal | `.tonal` (new class): `--primary-soft` / `--on-primary-soft` | `FilledButton.tonal`: `primaryContainer` / `onPrimaryContainer` |
| Ghost / text | `.text-button` and new `.ghost`: transparent, `--text-2` (`.text-button` keeps `--primary`) | `TextButton`: fg `primary`, radius 12, min 40 |
| Danger ghost | `.danger` (new): transparent, `--danger`; hover `--danger-soft` | `TextButton` with fg `error` |
| Icon | `.icon-button`: 40×40, radius 8, transparent, `--text-2`; hover `--surface-2` / `--text`; destructive icons (trash) hover `--danger-soft` / `--danger` | `IconButton`: 48 min, `onSurfaceVariant`; `IconButton.filledTonal` for Settings account actions |

Shared web rules:
- Height 40 (32 for `.sm`). Radius 8, padding 0 16, gap 8, icon 20.
- Disabled: opacity .45 and `cursor: not-allowed`. Keep.
- Focus: `outline: 2px solid var(--primary); outline-offset: 2px`. Replaces the 3 px / 3 px outline.
- Change `button { min-height: 42px }` to `min-height: 40px`. Below 768 px, all controls get `min-height: 44px` for touch.

### 3.4 Inputs, selects, checkboxes

**Web:**
- `input, select`:
  - Height 40 (44 below 768 px), padding 0 12, radius 8.
  - Background `--surface`, border 1 px `--border-strong`, text `--text`, placeholder `--text-3`.
  - Hover border `--text-3`.
  - `:focus-visible`: border `--primary`, `box-shadow: 0 0 0 3px var(--primary-soft)`, no outline.
  - `select`: `appearance: none` with an inline-gradient chevron (see mockup `select.input`) and padding-right 32.
- `.field`:
  - Gap 6. Label (`.field > span`) is 13/18, weight 500, `--text-2`. Field margin `0` (spacing comes from the parent `gap`).
  - Inside `.form-grid`: gap 16 16.
  - Elsewhere: keep `margin: 14px 0` → `12px 0` for flow forms (login, modals).
- `input[type=checkbox]`: 18×18, `accent-color: var(--primary)`.
- Invalid or missing: `.missing-product-name .catalog-search input` uses border `--danger` and bg `--danger-tint`. Replace the hard-coded `#c83c58`.

**Flutter `InputDecorationTheme`:**
- `filled: true`, `fillColor: surfaceContainerLowest`.
- Borders:
  - `border` / `enabledBorder`: `OutlineInputBorder(radius 12, side 1 px outline)`
  - `focusedBorder`: 2 px `primary`
  - `errorBorder`: 1 px `error`
  - `focusedErrorBorder`: 2 px `error`
  - `disabledBorder`: 1 px `outlineVariant`
- `contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16)`.
- `labelStyle`: bodyLarge `onSurfaceVariant`. `floatingLabelStyle`: 12 `primary`. `helperStyle` / `hintStyle`: bodySmall `text3`. `errorStyle`: bodySmall `error`.
- `CheckboxThemeData`: shape radius 4, side 2 px `onSurfaceVariant`, fill `primary` when selected.
- `DropdownMenuThemeData` and `DropdownButtonFormField` inherit the input theme. Set `menuStyle` bg `surfaceContainerLowest`, radius 12, and elevation through `MenuThemeData` (e2).
- Keep the missing-product-name override: the editor's local Theme sets `fillColor: AppPalette.errorSurface` (pinned).

### 3.5 Cards

- **Web:** new class `.card` (`--surface`, 1 px `--border`, radius 12). Optional `.card-header` (flex, 16 20 padding, bottom border, title 16/24/600) and `.card-body` (20 padding). Existing containers adopt this look directly in CSS (see §4): `.store-grid article`, `.settings-section`, `.report-summary > div`, `.table-scroll`, `.mapping-list`, `.series-menu`, and the editor groups.
- **Flutter `CardThemeData`:** `color: surfaceContainerLowest`, `surfaceTintColor: transparent`, `elevation: 0`, `margin: EdgeInsets.zero` (spacing via parent gaps), `shape: RoundedRectangleBorder(radius 12, side: BorderSide(color: outlineVariant, width: 1))`, `clipBehavior: Clip.antiAlias`. Today the margin is vertical 5; callers that relied on it get `SizedBox(height: 8)` separators or `Padding(bottom: 8)`.

### 3.6 Lists and receipt rows

**Web receipt table (`.receipt-table`):**
- It lives in a card: `.table-scroll` gets the card look plus `overflow: hidden auto`.
- `th`:
  - Height 40, bg `--surface-2`, 12/600 `--text-2`, padding 0 16, bottom border.
  - The sort button inherits; the active sort column is `--text` with the existing ↑/↓ glyph.
  - Numeric header right-aligned (`th:nth-child(4)`).
- `td`: height 60, padding 0 16, bottom border (none on the last row).
- Row hover: `--surface-2`.
- First column `.row-link`: store name in 14/600 `--text`. Under it is the status line (see "Status" below).
- Date columns: `--text-2`, `.numeric`. Total: `.numeric` and right-aligned, 14/600.
- Delete: `.icon-button` with danger hover.

**Status, replacing the row floods:**
- Remove the `tr.draft td` / `tr.failed td` backgrounds.
- `tr.draft td:first-child { box-shadow: inset 3px 0 0 var(--warning) }`; `tr.failed` uses `--danger`.
- Badges (§3.7), rendered as a sibling element **after** the `.row-link` button inside the first `td`, so the button's accessible name does not change:
  - `failed` → `<span class="badge danger">{tr("识别失败")}</span>`
  - `draft` (and not running) → `<span class="badge warning">{tr("草稿待确认")}</span>`
  - Queued/running: the existing `<small>{tr("识别中…")}</small>` inside the button gets class `badge info` (restyled; text and position unchanged).
  - Posted: nothing.
- The first `td` is `display: flex; flex-direction: column; align-items: flex-start; gap: 4px; justify-content: center` (keep `width: 34%` → 38%).

**Web, below 640 px: stacked rows (CSS only).**
- `thead tr` becomes a horizontal scroll row of sort chips. `th` is `display: contents`; the `th button` gets the chip look (32 px, pill, `--border-strong`), and the active sort uses the `.chip.on` look. The `操作` header is hidden.
- `tbody tr`: `display: grid; grid-template-columns: 1fr auto auto; grid-template-areas: "store total del" "time time del"`, padding 12 16, bottom border.
- The entry-time column (`td:nth-child(2)`) is `display: none` on phones. Receipt time shows under the store in body-sm `--text-3`.

**Generic list rows** (`.group-row`, `.mapping`, `.catalog-options button`, `.line`): min height 48, padding 12 20 inside cards, 1 px bottom border except the last, hover `--surface-2`.

**Flutter `ReceiptRow`** (keep the constructor, the 56 px height, the swipe behavior and the `'Trash'` text):
- Row Material color:
  - normal: `surfaceContainerLowest`
  - draft: `AppPalette.warningSurface`, pinned (now `#FDF1DC`, much lighter than today)
  - failed: `AppPalette.errorSurface`, pinned
- A 3 px leading stripe (`warning` / `error`) for draft and failed rows: a `Container(width: 3)` at the start of the Row, inside the Material.
- Status icon 18 px:
  - draft: `edit_note` in `tokens.warning`
  - failed: `error_outline` in `scheme.error` (`receipt_outlined` stays for posted, in `text3`)
  - Semantic labels unchanged.
- Name: 12/600 `onSurface`. Dates: 11 `onSurfaceVariant`, tabular. Amount: 12/700 tabular.
- Swipe delete action: bg `scheme.error`, fg `scheme.onError`, square at the row edge. Replaces `Colors.red.shade700`.

**Flutter `ReceiptTableHeader`:** bg `surfaceContainer`, 11/600 `onSurfaceVariant`, active column `onSurface` with a 12 px arrow. Height 44 (unchanged).

**Grouped list look (home):** wrap the header and the rows visually as one card.
- `ReceiptTableHeader` gets `BorderRadius.vertical(top: Radius.circular(12))` and a 1 px `outlineVariant` border on top, left and right.
- Each `ReceiptRow` sits in a `DecoratedBox` with left and right borders. The last row gets the bottom border and a 12 px bottom radius (apply it in `home.dart` `receiptList`'s item builder; `ReceiptRow` gets no new required parameters).
- The 1 px `Divider`s between rows stay, colored `outlineVariant`.

### 3.7 Badges and chips

**Badge (web `.badge`, Flutter: small `Container` helper `StatusBadge` in `common.dart`):**
- Height 22 (Flutter 20), padding 0 8, pill, 12/500 (Flutter 11/600).
- Leading 6 px dot in `currentColor`; the `neutral` tone has no dot.
- Tones:

| Tone | Text | Background |
|---|---|---|
| `success` | `--success` | `--success-soft` |
| `warning` | `--warning` | `--warning-soft` |
| `danger` | `--danger` | `--danger-soft` |
| `info` | `--info` | `--info-soft` |
| `neutral` | `--text-2` | `--surface-2` |

- The existing web `.badge` (Settings `元用户`) becomes `neutral`: remove its border and margin-left 8.

**Chips:**
- Web `.tag`: height 36, radius 8, bg `--surface`, 1 px `--border-strong`, label 13/500. The remove `.icon-button` is 32×32 with a 16 px icon. Hover `--surface-2`.
- Flutter `ChipThemeData`:
  - Shape radius 8, side 1 px `outline`. Background `surfaceContainerLowest`; `selectedColor: primaryContainer`.
  - `labelStyle` 13/500 `onSurfaceVariant` (selected: `onPrimaryContainer` 600). Padding h12, height 32.
  - `showCheckmark: false`. `iconTheme` size 16 `onSurfaceVariant`.
  - This covers `ChoiceChip` (catalog tabs, store tabs, report periods), `InputChip` (product names, categories, store types) and `ActionChip` (add category).

### 3.8 Tabs and segmented controls

- **Web `.tabs`:**
  - Height 44, gap 4, bottom border.
  - Buttons: padding 0 14, 14/500 `--text-2`, a transparent 2 px bottom border with `margin-bottom: -1px`.
  - `.active`: `--primary` text and border. Remove the 15 px padding.
- **Web `.segmented`:**
  - Track `--surface-2` with no border, padding 3, radius 10.
  - Buttons: 32 tall, padding 0 14, radius 7, `--text-2`, weight 500.
  - `.active`: `--surface` bg, `--text`, e1 shadow.
- **Flutter `SegmentedButtonThemeData`:** stadium shape, side 1 px `outline`, selected bg `primaryContainer` / fg `onPrimaryContainer`, min height 40, `showSelectedIcon` false (reports breakdown).

### 3.9 Dialogs, sheets and overlays

**Web `.modal`:**
- `--surface` bg, 1 px `--border`, radius 16, padding 24, e3 shadow, `width: min(560px, calc(100vw - 32px))`. `.wide` = `min(1100px, …)`.
- `::backdrop`: `--scrim`, **no blur**.
- `header`: title 20/28/650, close icon button at top-right (−8 px margin to align optically), margin-bottom 16.
- `footer`: margin-top 24, gap 8, right-aligned. Primary rightmost; cancel/secondary left of it.
- Below 640 px it becomes a **bottom sheet**: `margin: auto 0 0; width: 100%; max-width: 100%; border-radius: 16px 16px 0 0; max-height: 92dvh; padding-bottom: max(24px, env(safe-area-inset-bottom))`. Footer buttons are `flex: 1`.

**Web `.page-overlay`** (editor and product receipts):
- Full viewport at every width: `inset: 0; width: 100%; height: 100dvh; border: 0; border-radius: 0; background: var(--bg)`.
- `::backdrop` transparent. These are full tasks, not floating cards.
- The product-receipts overlay content (`.overlay-content`) gets padding 24 32 and a max-width 1200 wrapper. Its `返回` button becomes a ghost button with the `back` icon.

**Flutter `DialogThemeData`:**
- bg `surfaceContainerLowest`, `surfaceTintColor` transparent, radius 16, elevation 6 (shadow e3).
- `titleTextStyle` titleLarge, `contentTextStyle` bodyMedium `onSurfaceVariant`.
- `actionsPadding: EdgeInsets.fromLTRB(24, 0, 24, 20)`, `insetPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 24)`.
- Actions: cancel = `TextButton`, confirm = `FilledButton`. Destructive confirms (`永久删除`, `删除用户`) use `FilledButton` with `backgroundColor: scheme.error`. `CategoryEditorDialog`: change `保存` from `TextButton` to `FilledButton`, for consistency.

**Flutter `BottomSheetThemeData`:** bg `surfaceContainerLowest`, surfaceTint transparent, `showDragHandle: true`, `dragHandleColor: outline`, `dragHandleSize: Size(32, 4)`, shape top radius 16, `modalBarrierColor: scrim α .45`.

**Flutter `openPageOverlay`:** unchanged (`Dialog.fullscreen`). Its Scaffold bg is `surface`.

### 3.10 Notices, toasts and snackbars

**Web `.notice` (callout):**
- Flex, gap 12, align-start, padding 12 16, radius 8, 1 px `--warning-border`, bg `--warning-soft`, text `--text`, 14/20.
- `.notice.error`: border `--danger-border`, bg `--danger-soft`.
- New `.notice.info`: border transparent, bg `--info-soft`.
- Buttons inside: `.sm` secondary, pushed right with `margin-left: auto`.
- `p` margins 4 0.

**Web `.toast`** (the `.notice.toast` element in `Workspace`):
- `position: fixed; left: 50%; bottom: 24px; transform: translateX(-50%); max-width: min(560px, calc(100vw - 32px))`.
- Bg `--inverse` and text `--inverse-text`, no border, radius 12, padding 10 8 10 16, e2, z 40.
- The close icon is 32×32 in `currentColor`.
- Below 1024 px: `bottom: max(16px, env(safe-area-inset-bottom))`. In the editor overlay it must not cover the save bar, so add `bottom: 88px` while an overlay is open; use `:has(.page-overlay[open]) .toast`. The element stays inside `.workspace` with `role="status"`.

**Web `.offline-notice`:**
- `top: 72px` (64 + 8), horizontally centered (`left: 50%; transform: translateX(-50%)`).
- Info pill: bg `--info-soft`, `--text`, radius pill, padding 8 16, 13/500, with a leading 8 px `--info` dot (`::before`).
- With the sidebar it centers in the content area: `left: calc(50% + 124px)`.

**Flutter `Notice` (`common.dart`):**
- Add an optional `tone` parameter: `enum NoticeTone { warning, error, info, success }`, default `warning` (behavior-compatible).
- Visuals: padding 12, radius 12, 1 px border, icon 20.

| Tone | Background | Border | Icon |
|---|---|---|---|
| `warning` | `warningSoft` | `warningBorder` | `warning_amber_rounded` in `warning` |
| `error` | `errorContainer` | `dangerBorder` | `error_outline` in `error` |
| `info` | `infoSoft` | transparent | `info_outline` in `info` |
| `success` | `successSoft` | transparent | `check_circle_outline` in `success` |

- Text: bodyMedium `onSurface`.
- Callers that switch tone:
  - `error`: login/password errors, editor `草稿尚未保存：{0}`, reports `报表更新失败…`, users error, receipt-types error.
  - `info`: Settings status messages (update check, download progress, backup ready).
  - Everything else keeps `warning`.

**Flutter `SnackBarThemeData`:** `behavior: floating`, bg `inverseSurface`, `contentTextStyle` bodyMedium `onInverseSurface`, `actionTextColor: inversePrimary`, `closeIconColor: onInverseSurface`, radius 12, `insetPadding: EdgeInsets.fromLTRB(16, 0, 16, 88)` (clears the dock), elevation 3. `showError` keeps `showCloseIcon` and the 6 s duration.

### 3.11 Empty, loading and error states

**Web `StateView`** (markup unchanged apart from class names):
- Loading `.loading`: centered column, padding 64 20, a 20 px CSS spinner (`::before`: 2 px `--border` ring with a `--primary` top, `animation: spin .8s linear infinite`, reduced-motion → none) above `正在加载…` in `--text-2`.
- Error `.notice.error` (role="alert"): callout with the retry button at the right.
- Empty `.empty`: padding 64 20, centered.
  - Icon in a 56 px circle (`--surface-2` bg, icon 24 `--text-2`).
  - `h3` 16/24/600 `--text`, margin 16 0 4.
  - `p` 14/20 `--text-2`, max-width 360, centered.

**Flutter:**
- `EmptyState`: 64 px circle `surfaceContainer` with a 28 px icon `onSurfaceVariant` (not primary), titleMedium, bodyMedium `onSurfaceVariant` (height 1.5), padding 40.
- Loading: `CircularProgressIndicator(strokeWidth: 2.5)`, 28 px, centered. `ProgressIndicatorThemeData`: color `primary`, `linearTrackColor: primaryContainer`, `circularTrackColor: transparent`, `linearMinHeight: 3`.
- List-level error ("数据加载失败"): `Notice(tone: error)` plus `TextButton` `点击重试`.

### 3.12 Tables (generic)

- Web `table` inside `.table-scroll.card`: same `th` and `td` rules as the receipt table, with a 52 px row height.
- Users and report detail tables. Receipt links (`.row-link`) are 14/600 `--text` and turn `--primary` on hover.

### 3.13 Charts

**Web `TrendChart`** (SVG; geometry unchanged: viewBox 980×290, x 70…935, y 35…235):
- It sits in the filter card under the filter row: `.chart-scroll` padding 8 20 4. `min-width: 700px` stays for horizontal scroll on phones.
- Grid: the baseline (`n === min`) is solid `--border`. The 0.5 and 1 lines use `stroke-dasharray: 3 4`. Add class `grid-line` / `grid-line dashed`.
- Lines:
  - `polyline`: `stroke-linejoin="round" stroke-linecap="round"`. Width 2.5 for total, 2 otherwise.
  - The `stroke` attribute stays the literal `trendColor()` color.
  - `colors` array → §2.3 (chart-0…6). `trendColor` keeps the hash formula (`colors[0]` for total, `1 + hash % (len - 1)` otherwise).
- Points: `r` 4.5 for the selected index, 2.5 otherwise, with `stroke: var(--surface); stroke-width: 2` (a CSS rule on `.trend-chart circle`).
- Selected line: `--primary` dashed `4 5`, opacity .5. `.selected-tick`: `--primary`, 650.
- Axis text: 11 px `--text-3`.
- `.trend-legend`: 13 px `--text-2`, gap 8 20, padding 4 20 16. Swatch 16×3, radius 2.
- Hit areas (the 36 px rects) unchanged. Add a focus style: `.trend-chart [role=button]:focus-visible rect { fill: var(--primary-soft); }`.

**Flutter `ReportTrendChart`** (CustomPaint; size and insets unchanged: height 268, left inset 50, see §9):
- Wrapped in a Card with padding `fromLTRB(8, 12, 8, 8)` (the wrapper lives in `reports.dart`, outside the chart widget).
- Grid: `outlineVariant`. The baseline is solid; the others are dashed. Draw the dashes manually with short segments; no dependency. If that is too costly, use solid lines at α .6.
- Total: `scheme.primary` 3 px. Series: `tokens.chart[1 + hash % 6]` instead of the `tertiary` / `secondary` / hex mix.
- Selected dot: centre fill `surfaceContainerLowest` instead of hard-coded white. Selection line `primary` α .35 at 1.5 px.
- Axis labels: 10 pt `text3`.

### 3.14 Photo tiles

- Web `.receipt-photos figure`: radius 12, bg `#FFFFFF` (paper). Figcaption chips are `rgb(20 22 24 / 72%)` with white text, pill, height 32; icon buttons are 32×32 circles. Remove their backdrop blur.
- Flutter photo tiles: radius 12; badge/action pills black α .72, radius pill. The panel bg is `tokens.photoBg`.

---

## 4. Web: concrete CSS rewrite map (`src/web/src/style.css`)

Rewrite the file top-down in this order. **Keep every existing selector working**; tests and JSX depend on the class names. Add new classes only where listed.

1. **`:root` / `[data-theme=dark]` / `@media (prefers-color-scheme: dark)`:** replace all variables with §2.1 and §2.2. Keep the three-block structure so `data-theme="system"` still follows the OS.
   - Keep the old variable names as aliases so nothing breaks: `--canvas: var(--bg)`, `--panel: var(--surface)`, `--ink: var(--text)`, `--muted: var(--text-2)`, `--line: var(--border)`, `--accent: var(--primary)`, `--soft: var(--primary-soft)`, `--warning` (**note:** the old `--warning` was a *surface*; rename old usages to `--warning-soft`), `--error` → `--danger-soft`, `--glass: var(--bg)`.
   - Audit every `var(--warning)` and `var(--error)` usage in the file while doing this.
   - Add the radius, shadow and motion tokens. Font stack per §2.4.
2. **Base:** `body` 14/20, `button`, `input`, `select` per §3.3–3.4. Focus rule per §3.3. Typography: `h1` 28/36/700, `h2` 20/28/650 margin 0, `h3` 16/24/600, `p` line-height 1.6, `small` 12/16 `--text-3`.
3. **Delete** the `.eyebrow` styles. Remove the `<p className="eyebrow">RECEIPT MASTER</p>` elements in `Heading` and `SignIn` (`main.tsx`). Also delete the `.modal .auth-card > .eyebrow` rule.
4. **Shell:** `.toolbar`, `.workspace`, `.drawer`, `.drawer-shade`, `.drawer-brand`, `.account-label` per §3.1–3.2. `.workspace` padding `96px 32px 64px` (64 toolbar + 32), with `.has-sidebar { padding-left: calc(248px + 32px) }`. Inner max-width: `.workspace > .workspace-tab > * { max-width: 1200px; margin-inline: auto }`. Simpler: `.workspace-tab { max-width: 1200px; margin: 0 auto; }`, and `.workspace-tab[data-page=settings] { max-width: 720px }`.
5. **`.page-heading`:** `align-items: flex-end`, margin-bottom 24, h1 28/36, subtitle `.muted` 14/20 margin-top 4.
6. **Cards:** add `.card`, `.card-header`, `.card-body` (§3.5) and apply the card look to `.table-scroll`, `.store-grid article`, `.settings-section`, `.mapping-list`, `.series-menu`, and the new editor groups.
7. **Tables, status, badges:** §3.6, §3.7, §3.12.
8. **Forms:** `.field`, `.form-grid`, `.check`, `.catalog-search`, `.catalog-options` (radius 12, e2, bg `--surface`; options 40 px, padding 0 12; hover / `aria-selected` `--surface-2`).
9. **Modals and overlays:** §3.9.
10. **Notices and toast:** §3.10.
11. **Editor:** §5.3.
12. **Reports and chart:** §5.4, §3.13.
13. **Catalog, stores, settings, users, camera, auth:** §5.5–5.9 and §5.1.
14. **Media queries:** consolidate to four breakpoints, in ascending specificity: `max-width: 1023px`, `max-width: 767px`, `max-width: 639px`, plus `min-width: 1024px` for the sidebar. Merge the duplicated `max-width: 599px` blocks into the `639px` block.
15. **`src/web/index.html`:** `<meta name="theme-color" content="#F6F6F3" media="(prefers-color-scheme: light)">` and a second meta tag with `#0E1012` for dark.

---

## 5. Web: per-screen layout

Breakpoints: **desktop ≥1024** (sidebar) · **tablet 640–1023** (drawer, two-column editor) · **phone <640** (drawer, stacked editor, bottom-sheet modals).

### 5.1 Login and forced password change (`SignIn`)

- `.auth-page`: `--bg`, centered, padding 32 (16 on phone).
- `.auth-card`: becomes a card. Width `min(400px, 100%)`, padding 40 36 32 (phone: 32 20 24; no shadow on phone), e2 shadow on ≥640.
- `.brand-mark`: 48×48, radius 12, **filled** `--primary`, icon 26 `--on-primary`, no border, margin-bottom 24.
- `h1`: 26/34/700, margin 0 0 8. Subtitle `.muted` 14/20.
- Form: margin-top 28, fields stacked with 16 gap (`.auth-card form { display: flex; flex-direction: column; gap: 16px }`, `.auth-card .field { margin: 0 }`).
- Error: `.notice.error` callout with an `alert` icon. The JSX may add `<Icon name="alert"/>`; optional.
- Primary button: full width, height 44, margin-top 4.
- Change mode: same card. The username field is read-only and styled with `--surface-2` bg (`input[readonly]`). The `退出登录` `.text-button` is centered below the form, `--text-2`.
- `.auth-footer`: 12/16 `--text-3`, margin-top 24.
- Inside the change-password `Modal`, keep the existing hiding rules for brand-mark and h1, and drop the eyebrow rule.

### 5.2 Receipts (`Receipts`, Workspace receipts tab)

- Top bar actions per §3.1. Labels visible on desktop. Implementation: extend `IconButton` with optional `className?: string` and `showLabel?: boolean`. When `showLabel` is set, render `<span className="button-label">{label}</span>` after the icon. CSS: `.button-label { display: none }` below 1024 px; at ≥1024 px `.toolbar .icon-button.labeled { width: auto; padding: 0 16px; border: 1px solid var(--border-strong); background: var(--surface) }` and `.labeled.primary` uses the primary look. The `aria-label` and `title` stay, so accessible names are unchanged.
- Heading: `收据` + `共 {0} 张收据` + refresh icon button (unchanged).
- Upload notice (`.notice` with `重试上传`): callout, info tone (`className="notice info"`), with a leading `upload` icon. The button sits on the right. Error lines render as `p` in body-sm `--danger`.
- Table per §3.6. Empty state per §3.11 (`还没有收据` + existing paragraph).
- Phone (<640): stacked rows with sort chips (§3.6).

### 5.3 Receipt editor (`Editor` in `PageOverlay editing`)

The overlay is full-viewport (§3.9). Structure:

```
┌ .editor-heading (64px bar, --surface, bottom border, padding 0 20) ────────────────┐
│ [←] Store name (18/24/650)      [status badge]   ……  [重新识别 ghost] [🗑 icon]     │
│     receipt id (mono 11, --text-3)                                                  │
├ .editor-layout ─────────────────────┬─────────────────────────────────────────────┤
│ .receipt-photos (--photo-bg, p 20)  │ .receipt-fields                              │
│   figure (paper, r12) …             │  .receipt-fields-scroll (p 24, gap 20)       │
│                                     │   .editor-card  收据内容 (header fields)      │
│                                     │   .editor-card  商品明细 (lines + actions)    │
│                                     │   .reconciliation (3 stat tiles)             │
│                                     │  .save-bar (sticky bottom bar)               │
└─────────────────────────────────────┴─────────────────────────────────────────────┘
```

- `.workspace.editing`: `padding: 0; height: 100dvh; display: flex; flex-direction: column`.
- `.editor-heading`:
  - Height 64, flex-shrink 0, padding 0 20, `--surface`, bottom border, gap 12, margin 0.
  - `h1` 18/24/650, ellipsized. `small` (the id) uses the mono stack at 11/16 `--text-3`.
- Status badge after the title block. Reuse the receipts logic: `posted` → none, `draft` → `草稿待确认`.
- `重新识别`: change from an icon to a ghost button with icon + label at ≥640. Same `IconButton` + `showLabel`, same aria-label.
- `.editor-layout`:
  - `grid-template-columns: minmax(0, 5fr) minmax(0, 7fr)`, gap 0, `flex: 1; min-height: 0`.
  - Tablet 640–1023: `minmax(0, 1fr) minmax(0, 1fr)`.
- `.receipt-photos`:
  - bg `--photo-bg`, padding 20, `display: flex; flex-direction: column; gap: 16px`, `overflow-y: auto`.
  - `figure` radius 12, bg `#FFF`. Keep the full-height behavior: `height: auto; aspect-ratio` is not needed; keep the current `height: 100%` for a single photo.
  - The empty message `手动录入的收据没有照片。` is centered in `#A7ADB4`.
- Fields column: wrap the groups in JSX `div.editor-card` wrappers (markup-only change):
  1. **`收据内容` card:** a `.card-header` containing `<h2>{tr("收据内容")}</h2>` (existing key, currently used only as aria-label) and, right-aligned, the `编辑店铺 Logo 名称` button styled ghost `.sm`. Then `.card-body` holding the `店铺类别` Select and the `.form-grid` (2 columns, gap 16).
  2. **`商品明细` card:** `.section-heading` becomes the card header (margin 0, padding 16 20, bottom border). Count `<small>` becomes `badge neutral`. `添加` is a secondary `.sm` button. Then the `.line` rows, then `.inline-actions` as a card footer (padding 12 20, top border, bg `--surface-2`, bottom radius). `按明细计算总额` is pushed right as a ghost button.
  3. **`.reconciliation`:** becomes a card with 3 equal stat cells, separated by vertical borders:
     - `票面总金额`: the existing key, value from `money(r.totalMinor, r.currency)`.
     - `明细合计`
     - `差额`
     - Label 12/16 `--text-2`, value 20/28/650 tabular. The difference cell uses `--warning` when non-zero (keep the class `warning-text`, restyled).
     - Still rendered only when `r.summary && !dirty`.
- `.line` (inside the card):
  - padding 12 20, gap 12, bottom border.
  - `.line-main strong` 14/600. The raw name `small` is 12 `--text-3`, margin-left 8.
  - `.line-meta` becomes inline neutral badges. Optional: render each meta part as `<span className="badge neutral">`; otherwise style `.line-meta` 12/16 `--text-2`.
  - Amount `.numeric` 14/600.
  - Delete icon is 32 px with danger hover.
  - `.line.warning`: remove the full bg and radius; use `box-shadow: inset 3px 0 0 var(--warning); background: var(--warning-tint)`.
  - `.line.missing-product-name`: same with `--danger` / `--danger-tint`.
  - `.warning-text` inside lines: 12/16 `--warning` (on missing name, `--danger`), with a leading 14 px `alert` icon. Optional JSX; CSS-only is acceptable via `::before` with a mask-less "⚠" glyph. Prefer the JSX `<Icon name="alert"/>`.
- `.save-bar`:
  - Becomes a **bottom bar** of the fields column: `position: absolute; left: 0; right: 0; bottom: 0; border-radius: 0; border: 0; border-top: 1px solid var(--border); background: var(--surface); padding: 12px 24px; gap: 8px; box-shadow: none`.
  - `.discard` is a ghost button on the left (add `margin-right: auto`). `保存草稿` is secondary; `录入并退出` is primary. Buttons are 40 tall and radius 8.
  - `.receipt-fields-scroll` padding-bottom 88.
- **Phone (<640):**
  - The heading bar stays sticky (`position: sticky; top: 0; z-index: 3`).
  - Photos become a horizontal strip (current behavior): `--photo-bg` band, padding 12, figures 150×200.
  - Fields padding 16, cards full width, `.form-grid` 1 column.
  - `.save-bar`: `position: fixed; left: 0; right: 0; bottom: 0; padding: 10px 16px max(10px, env(safe-area-inset-bottom))`. Buttons are `flex: 1` (discard `flex: 0 0 auto`, ghost).
- **Modals launched from the editor** (`LineEditor`, leave confirmation, DST choices, full photo, store logos): standard `.modal` (§3.9).
  - `LineEditor`: `.form-grid` 2 columns (1 on phone). The warnings notice is a warning callout with the `已核对，清除提示` button. Footer: `取消` secondary, `应用修改` primary.
  - DST choices: each time is a full-width secondary button with 8 gap, in a flex column.
  - Leave dialog footer order: `继续编辑` (ghost), `放弃改动` (danger ghost), `保存草稿` (primary).

### 5.4 Reports (`Reports`, `TrendChart`, `TrendSeriesMenu`)

Layout top to bottom:

1. Heading `报表` + subtitle + refresh icon button (unchanged).
2. **Filter and chart card** (`div.card.report-card`, a new wrapper):
   - **Filter row** (`.report-controls`, moved to the top of the card, padding 12 16, bottom border, wrap, gap 12):
     - `.segmented` periods.
     - The `店铺类别统计范围` Select, rendered compact: a new modifier class `field inline`, the label visually hidden (`.field.inline > span` gets `sr-only` styles), select width 200 and height 36.
     - Spacer.
     - `← 更早` and `较近 →` as secondary `.sm` buttons.
     - `曲线选择` as a secondary `.sm` button with `aria-pressed={seriesMenu}` and an active style `.tonal` when open.
     - JSX change: move the receipt-type `Select` from above the chart into `.report-controls`, after `.segmented`. Moving the chart below the controls is a reorder only; the props and handlers are unchanged.
   - `正在重新查询曲线…` status and `TrendSeriesMenu` render directly under the filter row, inside the card. `.series-menu` padding 16 20, bottom border, bg `--surface-2`. `.series-category` cards are not needed: keep the top borders.
   - Chart (§3.13) and legend.
3. **Period section:** `.section-heading` with `h2` (selected label, 20/28/650) and `返回所有分类` (ghost `.sm` with `back` icon). Margin 32 0 12.
4. **KPIs** `.report-summary`:
   - Grid of 3, gap 16, no outer borders. Each `div` is a card with padding 16 20.
   - `span` 13/18 `--text-2`, margin-bottom 6. `strong` 28/36/650 tabular, letter-spacing −0.02em.
   - Phone: 1 column, with `strong` at 24.
5. Difference notice (`明细与票面金额差额：`): warning callout.
6. **Groups** `.report-groups`:
   - `grid-template-columns: repeat(3, minmax(0, 1fr))`, gap 16. Tablet: 2 columns. Phone: 1 column.
   - Each `section` is a card: the `h2` becomes the card header (16/24/600, padding 16 20, bottom border, margin 0).
   - `.group-row`: padding 12 20, hover `--surface-2`, radius 0. Label 14/500, `small` quantity labels 12 `--text-3`, amount 14/600 tabular.
   - **Add a share bar:** `<span className="group-bar"><i style={{ width: `${pct}%` }}/></span>`, where `pct = (g.amount / max(amounts in this group)) * 100`, clamped to [0, 100]. Use 0 when max ≤ 0. Bar: height 4, radius 2, track `--surface-2`, fill `--primary`, margin-top 8. Pure presentation from existing data.
   - The empty paragraph sits inside the card body, padding 16 20.
7. Detail modal: wide `.modal` with a table (§3.12).

### 5.5 Catalog (`Catalog`, `CategoryForm`)

- Heading unchanged.
- `.tabs` per §3.8. Margin 0 0 16.
- Search: `.search` 320 px wide, height 40. A leading search icon through a CSS background is acceptable (inline SVG data-URI; CSP `img-src data:` allows it). Margin-bottom 16.
- Mapping tabs (0, 2):
  - `.mapping-list` becomes a card. `.mapping` rows: padding 10 20, gap 24, 2 columns, label 14/500, input full width.
  - `.thin-separator` becomes a full-width 8 px band with `--surface-2` bg (`border: 0; height: 8px; margin: 0`) so the "incomplete first" grouping reads as two sections.
- Product names (tab 1) and categories (tab 3): `.tags` as chip wraps (§3.7) inside a card body (padding 16 20, gap 8). `添加商品种类` is a secondary button with `add` icon, margin-top 16.
- Empty text: `.muted` centered, padding 32.
- Phone: `.mapping` becomes 1 column (label above input, gap 6).

### 5.6 Stores (`Stores`, `ReceiptTypesManager`)

- Tabs `店铺名称` / `店铺类别` per §3.8.
- `.store-grid`: `repeat(auto-fill, minmax(240px, 1fr))`, gap 16.
  - Each `article` is a card with padding 16, flex column, gap 12.
  - `img`: height 120, `object-fit: contain`, bg `#FFFFFF` (always white, even in dark mode, for logo legibility), radius 8, 1 px `--border`.
  - The delete icon button is right-aligned under the input (`align-self: flex-end`).
- `重新提取 Logo` (from the editor modal): secondary button with `refresh` icon, margin-bottom 16.
- `ReceiptTypesManager`: the intro `.muted` paragraph, then `.tags`, then `添加店铺类别` secondary. Its edit form becomes an inline card (padding 16, gap 12, flex). `h2` `店铺类别设置` 16/24/600, margin 32 0 12. `.mapping-list` card as in §5.5.

### 5.7 Settings (`Settings`)

- Column max-width 720.
- Each `.settings-section` becomes a card: padding 0. The `h2` is the card header (16/24/600, padding 16 20, bottom border, margin 0). The content wrapper padding is 20, gap 16.
  - CSS-only: `.settings-section > h2 { … }` and `.settings-section > :not(h2) { margin-inline: 20px }`, plus `padding-bottom: 20px` on the section.
  - Sections are 16 apart: `margin-bottom: 16px`. Remove the `border-bottom` and padding.
- `外观与偏好`:
  - `Language` select first; keep the literal label `Language` (§9).
  - The theme `Select` stays a select. Optional upgrade: render it as `.segmented` with three buttons wired to the same `setTheme` with the existing labels. If you do, keep a `<select>` for tests or check `tests/web` first.
  - The weight and currency selects sit in a 2-column grid at ≥640.
  - Hints `.muted` 13/18.
- `账户`: a row with a 40 px avatar, the username 16/600 and the `元用户` neutral badge. Then `.inline-actions`: `修改密码` secondary and `退出登录` danger-ghost with `logout` icon.
- `数据`: the hint paragraph, then `.data-actions` as a 2-column grid at ≥640 (gap 8) of secondary buttons, left-aligned content (`justify-content: flex-start`). The `AndroidDownloadLink` (`a.button`) gets the same style.

### 5.8 Users (`Users`)

- Heading action `创建用户`: primary with `add` icon (unchanged).
- The table sits in a card (wrap the `<table>` in `<div className="table-scroll">`, markup-only).
  - Columns: username (14/600), role as a badge (`元用户` uses `info`, `普通用户` uses `neutral`), password status (`首次登录需改密` as a `warning` badge, `已设置` as plain `--text-2`), actions (icon button, or `不可删除` in `--text-3`).
- Create modal: fields stacked with 16 gap, hint `.muted`, footer `取消` / `创建` primary.

### 5.9 Camera (`Camera` modal) and upload

- Wide modal on desktop. On phone it becomes a bottom sheet at full height (`max-height: 100dvh`, radius 0) with a black body.
- `.viewfinder`: bg `#000`, radius 12, `max-height: 60vh`.
- `.photo-strip`:
  - Gap 8, margin-top 12. Thumbnails 72×96, radius 8, 2 px transparent border; `.selected` border `--primary`.
  - The remove button is a 24 px circle at the top-right (−6 px offset), white bg, `#111` icon 14.
- Footer:
  - `重拍` secondary.
  - `拍摄` primary at **height 48 and min-width 120** (the dominant action).
  - `完成 · {0} 张` tonal.
  - Phone: all three `flex: 1`.
- The error callout sits above the strip.
- The upload file input is unchanged (hidden).

### 5.10 Product receipts overlay

Full-page overlay (§3.9). It shows the `返回` ghost button with the back icon, then the `Receipts` component with the title `商品 · {0}`. It reuses §5.2 styling, so it needs no extra rules.

---

## 6. Android / iOS (Flutter): per-screen layout

All values come from `receiptTheme` and the tokens. Remove hard-coded colors and sizes in screens unless this section lists them.

### 6.1 Theme (`lib/ui/app_theme.dart`)

Replace `receiptTheme(Brightness)` per §2–3:
- Explicit `ColorScheme`.
- `extensions: [ReceiptTokens.light / dark]`.
- `scaffoldBackgroundColor: scheme.surface`.
- `textTheme` with all slots from §2.4, colors from the scheme. Build it with `Typography.material2021().black/white` merged with the overrides, so unset slots stay consistent.
- Component themes:
  - `appBarTheme`, `cardTheme`, `inputDecorationTheme`, `filledButtonTheme`, `outlinedButtonTheme`, `textButtonTheme`, `iconButtonTheme` (min 48)
  - `chipTheme`, `segmentedButtonTheme`, `checkboxTheme`
  - `dialogTheme`, `bottomSheetTheme`, `snackBarTheme`
  - `navigationDrawerTheme`, `listTileTheme` (`contentPadding: EdgeInsets.symmetric(horizontal: 16)`, `iconColor: onSurfaceVariant`, `titleTextStyle: bodyLarge`, `subtitleTextStyle: bodySmall onSurfaceVariant`, `minVerticalPadding: 8`)
  - `dividerTheme` (`outlineVariant`, 1, space 1), `progressIndicatorTheme`, `popupMenuTheme` / `menuTheme` (radius 12, e2, bg `surfaceContainerLowest`)
  - `expansionTileTheme` (no borders, `tilePadding` h16, `childrenPadding` 16 0 16 16, `iconColor: onSurfaceVariant`)
  - `tooltipTheme` (inverse surface, radius 8)
  - `visualDensity: VisualDensity.standard`, `materialTapTargetSize: padded`
- `systemBars()`: unchanged (transparent, edge-to-edge).
- `FrostedBar`: §3.1. `PageHeading`: padding `fromLTRB(20, 12, 12, 16)`; title `headlineLarge` (28/34 w700); subtitle `bodyMedium` `onSurfaceVariant`.
- `AppearancePicker`: tiles 72 tall, radius 12, 8 gap (padding horizontal 4).
  - Selected: `primaryContainer` bg, 2 px `primary` border, `onPrimaryContainer` icon and label.
  - Unselected: `surfaceContainerLowest`, 1 px `outlineVariant`, icon `onSurfaceVariant`, label `onSurface`.
  - Animate the border and color with `AnimatedContainer(duration: Motion.base)`.

### 6.2 Shell (`lib/ui/home.dart`)

- **Delete the full-bleed diagonal gradient** (L413–430). The background is the flat `scheme.surface`. Keep `Scaffold.backgroundColor` = `surface`.
- Upload banner (L437–457):
  - `Material(color: tokens.infoSoft, borderRadius: 12)` with margin `fromLTRB(16, 0, 16, 12)`, a `cloud_upload_outlined` leading icon in `tokens.info`, title titleSmall, subtitle bodySmall.
  - When some uploads failed, use `warningSoft` / `warning`. Tap behavior unchanged.
- Import `LinearProgressIndicator`: themed; no change.
- Dock and drawer: §3.2.
- Receipt list:
  - Padding stays `16/8/16/112`. `PageHeading` with the refresh `IconButton` (unchanged).
  - The status line under the count: bodySmall. Offline / cache messages use `tokens.info`; errors use `scheme.error`.
  - Grouped table card per §3.6.
  - Error-without-rows becomes `Notice(tone: error)` plus `点击重试`. Empty state per §3.11. The loading spinner is centered with a top padding of 48.
- Lost-picker snackbars use the themed SnackBar.

### 6.3 Login, password, users (`lib/ui/account.dart`)

- `LoginPage`: centered, maxWidth 400, padding 28 horizontally.
  - **Brand mark**: `Container(56×56, radius 14, color: primary)` with `Icons.receipt_long` 30 `onPrimary`. Replaces the bare 48 px icon.
  - 24 gap, then `Receipt Master` in headlineLarge, a 6 gap, and the tagline in bodyLarge `onSurfaceVariant`. 32 gap.
  - Error `Notice(tone: error)`. Fields with 20 gaps. The `登录` FilledButton is full width with height 52, 8 above.
  - The field order (`服务地址`, `用户名`, `密码`) and validators are unchanged.
- `PasswordPage`: AppBar per theme. Content maxWidth 440, padding 24, fields 20 gap.
  - The forced notice uses `Notice(tone: warning)`. The error uses `tone: error`.
  - The FilledButton is full width with height 52. `退出登录` is a `TextButton` in `onSurfaceVariant`, centered.
- `UsersPage`: the list sits in a `Card` (margin 16) with ListTiles separated by dividers.
  - Leading: a `CircleAvatar` (radius 18, `surfaceContainerHigh`, first letter).
  - Subtitle: for the admin, `StatusBadge(info, 元用户)` plus the text `不可删除`. For a user who must change their password, `StatusBadge(warning, 首次登录需要改密)`.
  - Trailing: `shield_outlined` in `onSurfaceVariant`, or a delete `IconButton` in `error`.
  - The create dialog per the Dialog theme, with `创建` as FilledButton.

### 6.4 Capture (`lib/ui/capture.dart`)

The camera UI is always dark; ignore the theme brightness here.
- Top bar: keep the gradient (`#B8000000` → transparent). Title 18/600 white.
- Bottom panel: gradient transparent → `#E6000000` at 30 %. Padding 16/24/16/(inset + 24). Children are separated by 12 gaps.
- Hint: 12 white α .7, centered.
- Thumbnails:
  - 66×80, radius 10.
  - The selected border is **`AppPalette.cameraAccent` (`#3FC6B4`) at 3 px**, replacing `#ADC2FF`. Others: white α .4 at 1 px.
  - The delete target stays 44×44 (an `Icons.cancel` 22 white-filled circle with a `#111` glyph). The index number is 12/700.
- `重拍将替换第 {0} 张`: 12 white α .7.
- Buttons: a Row with flex 10 / 13 / 10, gap 10.
  - `重拍`: OutlinedButton, fg white, side white α .5, height 48, radius 12.
  - `拍摄`: FilledButton, bg `cameraAccent`, fg `#04201D`, height **56**, radius 16, label 16/600.
  - `完成`: `FilledButton.tonal`, bg white α .15, fg white, height 48, radius 12.
- Error overlay: `Colors.black87` with white text. `重试相机` becomes an OutlinedButton (white).

### 6.5 Editor (`lib/ui/editor.dart`)

- AppBar: keep `extendBodyBehindAppBar` and `flexibleSpace: FrostedBar()` (the new near-opaque look). The title (`编辑收据` / `收据草稿`) uses titleLarge.
  - The actions `IconButton`s stay. The delete icon changes to `delete_outline` in `scheme.error`.
- Heading `核对这张收据` in headlineSmall (22/28 w700). Subtitle bodyMedium `onSurfaceVariant`. 16 below.
- **Photos:**
  - Narrow `photoStrip`: height 170 (unchanged). Tiles radius 12 on a `tokens.photoBg` tile background. Action icons under each tile are 40 px `IconButton`s in `onSurfaceVariant`.
  - Wide `photoPanel`: panel bg `tokens.photoBg` (was `surfaceContainerLow`), inner padding **12** (pinned: photo width = panel − 24), tile radius 12.
  - The `第 {0} 张` badge is black α .72, pill, white 12. The floating action pill is black α .72, pill, 40 px circular icon buttons, white icons.
  - `quality_warning` uses `Notice(tone: warning)`.
- **Header fields:**
  - The store-not-matched notice: `tone: info`.
  - Fields with 16 gaps.
  - `店铺名称` is a `TextButton.icon(image_search)`.
  - `ExpansionTile` `更多票据信息` inside a `Card` (theme: no borders on the tile; the Card provides the border).
- **Time card:**
  - Card `ListTile` with a leading `Icons.schedule` (`onSurfaceVariant`), title titleSmall (the date, tabular), subtitle bodySmall (zone + estimate note), trailing `edit_outlined`.
  - When estimated: `color: AppPalette.warningSurface`, `side: warningBorder`.
- **Totals:** the `收据总额` field, then the `明确使用明细合计作为总额` `TextButton`.
- **Items:**
  - Section header `商品与调整` in **titleLarge** (remove the hard-coded 20/w700). The trailing `add_circle_outline` is in `primary`.
  - The selection actions Wrap (`拆分所选行` / `合并所选行` / `取消选择`): OutlinedButtons at height 40, with `取消选择` as a TextButton.
  - Line `Card`:
    - Margin bottom 8.
    - Color is pinned: `errorSurface` (missing name), `warningSurface` (warnings), else the default.
    - Add `shape` side: `dangerBorder` / `warningBorder` / `outlineVariant`.
    - Leading Checkbox, title `ReceiptItemName` (product titleSmall + printed name **12** `text3`, pinned 12), subtitle bodySmall `onSurfaceVariant`.
    - Trailing: the amount titleSmall w700 tabular, or `缺少金额` in `error`, plus the delete `IconButton(close, 18)`.
  - Empty: bodyMedium `onSurfaceVariant`.
- **Reconciliation:** `Notice(tone: warning)` when the difference is ≠ 0, otherwise `tone: success`. Same text. `追溯编号` in bodySmall `text3`.
- **Save pill (FAB slot):**
  - `Material(color: surfaceContainerLowest, shape: StadiumBorder(side: outlineVariant), elevation: 0)` wrapped in a `DecoratedBox` with the e3 shadow. Padding 6.
  - Buttons: `放弃改动` TextButton in `error`; `保存草稿` TextButton; `录入并退出` FilledButton. All are 44 tall and stadium-shaped, with label 13/600 and horizontal padding 14.
  - Total width must stay **< 340** (pinned).
- **Dialogs:**
  - Line editor: themed `AlertDialog`, content width 440, field gaps 16.
  - `对照原图位置`: TextButton.icon.
  - Evidence painter: keep the yellow highlight (`#55FFD54F` / `#FFA000`). It is a deliberate highlighter metaphor and works on photos in both modes.
  - The time dialog, split prompt, DST SimpleDialog and duplicate/warning confirms all use the themes.

### 6.6 Reports (`lib/ui/reports.dart`, `report_trend_chart.dart`)

Order (padding 16/12/16/116; replace 20 with 16 so it matches the other pages):

1. `PageHeading(title: 报表, subtitle: 按交易日期汇总所有已确认收据)`. Replace the hand-built title.
2. `店铺类别统计范围` dropdown. **Remove the duplicate second dropdown** (L439–462); no test references a second instance. Keep the first one, above the chart.
3. Chart Card (§3.13):
   - Header padding 16/14/16/0. `消费趋势` in titleMedium; the axis caption in bodySmall `text3`.
   - Then `ReportTrendChart`, then the legend Wrap (padding 12, gap 6×14, `labelMedium` `onSurfaceVariant`, swatch 16×3 radius 2).
4. Period `ChoiceChip`s plus the `曲线{0}` chip-styled `OutlinedButton.icon(tune)` (height 32, radius 8). Wrap gap 8, margin-top 12.
5. Window nav row: `更早趋势` / `更新趋势` as TextButton.icon, and the `已选 …` label in labelLarge `primary` (keep the text format exactly, pinned) with the zone in bodySmall `text3`.
6. Currency note: bodySmall `onSurfaceVariant` with a 16 px `currency_exchange` icon.
7. `统计范围` ListTile inside a Card. Trailing `filter_list`.
8. Error: `Notice(tone: error)` plus `重试统计` TextButton.icon.
9. **Hero card:**
   - **Remove the gradient.** `Container(color: primaryContainer, radius 16, padding 20)`.
   - `本期净支出`: labelLarge `onPrimaryContainer`.
   - Amount: **displaySmall** (36/44 w700, −0.5, tabular) in `onSurface`.
   - `上期 {0}`: bodyMedium `onPrimaryContainer`.
10. Stats Wrap (`支出` / `优惠` / `商品退款`): neutral chips (`Chip` with `surfaceContainerLowest` and `outline`), labelMedium tabular, gap 8.
11. Notices: `票据待核对差额` as `tone: warning`. The rounding line in bodySmall `text3`.
12. `支出去向`: titleMedium. `SegmentedButton` (theme). Then a Card holding the `_SpendRow` list, with dividers between rows.
    - Label titleSmall (15/600), amount titleSmall w700 tabular, chevron 18 `text3`.
    - Bar: height 5, radius 3, track `surfaceContainer`, fill `primary`.
    - The footer hint is bodySmall `text3`.
13. Bottom sheets: themed. The series picker header is titleLarge with bodySmall help text; child indentation stays 20. The drill sheet title is titleLarge (replaces the hard-coded 22 bold); ListTile trailing amounts are tabular.

### 6.7 Catalog, category editor, search (`catalog.dart`, `category_editor.dart`, `catalog_search.dart`)

- `PageHeading` (theme). The trailing `店铺` stays a `TextButton.icon(storefront)`.
- Tab `ChoiceChip`s per the chip theme. Avatars are 16 px icons; keep them, colored `onSurfaceVariant` / `onPrimaryContainer`.
- Column headings (`票面名称` / `商品名称`, …): labelMedium `onSurfaceVariant`, uppercase **no**.
- `_ChoiceRow`s inside one Card per section, with 1 px dividers between rows and padding 12/16. The incomplete-first separator divider (`catalog-completion-divider`) becomes a full-width 8 px `surfaceContainer` band (keep its key).
- InputChip wraps: gap 8 (spacing / runSpacing). `添加种类` ActionChip with an `add` 16 px avatar.
- `CatalogSearchField` options popup: `Material(color: surfaceContainerLowest, elevation: 0, radius 12)` wrapped in an e2 shadow, with a 1 px `outlineVariant` border. Width = field width (use `LayoutBuilder` constraints) instead of the fixed 300, capped at 420. Rows are 48 px; the selected row is `surfaceContainer`.
- `CategoryEditorDialog`: `保存` becomes a FilledButton. The error text is bodySmall `error`.

### 6.8 Stores (`logo_aliases.dart`, `receipt_types.dart`)

- Embedded `PageHeading`. Tabs as chips. Overlay mode: themed AppBar.
- Logo Card:
  - Image area 140 tall with a **white** bg (`Colors.white`, intentional in both modes), radius 8, padding 12, `BoxFit.contain`.
  - ListTile title titleSmall (or `尚未设置店名` in `text3`), subtitle bodySmall. Trailing `edit` or delete `IconButton` (error color).
  - Cards are 12 apart.
- Edit dialog: themed; the image sits on a white rounded box 100 tall; `保存别名` FilledButton.
- `ReceiptTypesManager`:
  - The explanation in bodyMedium `onSurfaceVariant`. The InputChip wrap. `添加店铺类别` TextButton.icon.
  - `店铺类别设置` in titleMedium, 24 above.
  - Merchant rows in a Card with dividers, the name in bodyLarge and the dropdown on the right (min width 160).
- `extractLogo` FilledButton: full width.

### 6.9 Product receipts (`product_receipts.dart`)

Keep the ListTile structure (tests and behavior) but align it with the receipt rows:
- `tileColor` stays (`errorSurface` / `warningSurface`), with a leading 3 px stripe implemented as `leading: Container(width: 3, height: 40, color: …)` plus the status icon.
- Title titleSmall. Subtitle bodySmall tabular. Trailing amount titleSmall w700 tabular.
- The list sits in the padding 16 ListView, with 1 px dividers.

### 6.10 Settings (`settings.dart`)

ListView padding stays 16/20/16/116; `用户管理` width is pinned at `width − 32`.

1. `PageHeading(设置, 让记录方式适合你)`. The status `Notice` uses **`tone: info`**, or `tone: error` for `无法读取服务器偏好…`.
2. Section header style for **all** sections: titleMedium (16/24 w600), padding top 24, bottom 8, left 4. Replace the mixed titleLarge, headlineSmall and hard-coded 22 bold.
3. `账户`:
   - A `Card` holding the Row: the username in **headlineSmall w700** (pinned ≥ w700), then the `IconButton.filledTonal(password_outlined)` and `IconButton.filledTonal(logout)` (pinned same row). The endpoint below in bodySmall `text3`. Padding 16.
   - Below the card, for admins only, the `用户管理` `ListTile` in its own Card with `margin: EdgeInsets.only(top: 8)`. The Card must add **no horizontal padding or margin**, so the ListTile width stays `width − 32`. Leading `people_outline`, trailing `chevron_right`.
4. `外观`: section header, the subtitle in bodySmall, then `AppearancePicker`.
5. Language: the `DropdownButtonFormField<Locale>` with **the literal label `'Language'`** (unchanged, pinned on web; keep it on mobile for parity). Loading and error states unchanged. The hint uses `_PreferenceHint` (bodySmall `onSurfaceVariant`, padding 16/6/16/0).
6. `偏好设置`:
   - Android: `检查客户端更新` stays an **`OutlinedButton.icon`**, full width, left-aligned (`alignment: Alignment.centerLeft`, padding h16).
   - `重试未完成的照片上传` likewise (pinned: OutlinedButton, and the weight dropdown sits more than 8 below it). 8 gap between the two buttons, 16 before the dropdowns.
   - Dropdowns with hints.
7. `后端数据`: the four ListTiles inside one Card with dividers. Leading icons in `onSurfaceVariant`: `backup_outlined`, `settings_backup_restore`, `history`, `table_view_outlined`. Subtitles in bodySmall. The restore tile's leading icon and title are in `error` (destructive).

### 6.11 Common (`common.dart`)

- `Notice` with `tone` (§3.10).
- Add `StatusBadge({required String label, required NoticeTone tone})` (§3.7).
- `EmptyState` (§3.11).
- `confirm()`: add an optional named `destructive: bool = false` parameter. When true, the confirm FilledButton uses `error` / `onError`. Pass it from the receipt delete, user delete and restore confirmations.
- `chooseCategory()`: `SimpleDialog` themed; selected radio icon in `primary`.
- `showError()`: themed SnackBar.

---

## 7. Responsive behavior summary

| Width | Web | Flutter |
|---|---|---|
| ≥1024 | Persistent 248 px sidebar; labeled top-bar actions; editor 5:7 columns; reports groups 3 columns | (tablet/desktop Flutter) same layouts as ≥600 below; the drawer remains |
| 768–1023 | Drawer; icon-only top-bar actions; account chip visible; editor 1:1; groups 2 columns | — |
| 640–767 | As above, account chip hidden, 44 px controls | — |
| <640 | Drawer; receipts as stacked rows with sort chips; editor stacked with photo strip and a fixed bottom save bar; modals become bottom sheets; KPIs 1 column; form grids 1 column | — |
| Flutter ≥600 | — | Editor two-pane (photo panel 9/20 below 800, 1/2 at 800 and above; pinned) |
| Flutter <600 | — | Editor single column with photo strip; catalog `_ChoiceRow` stacks below 500 |

Text scaling: web uses rem-free px but respects browser zoom; avoid fixed heights on text containers except 40/44 px controls. Flutter supports `textScaler` up to 2.0: the dock targets keep their size, labels wrap, and no `maxLines: 1` on titles except row names (ellipsis). `settings_test` already exercises large text.

---

## 8. Accessibility

- **Contrast:** every pair in §2.1 and §2.2 meets AA (body text ≥4.5:1, large text and UI ≥3:1). Never put `--text-3` on `--surface-2` or `--surface-3` for essential text. Status is never conveyed by color alone: badges carry text, the Flutter icon has a semantic label, and the stripe is decorative.
- **Focus:** web uses `:focus-visible` with a 2 px `--primary` outline and 2 px offset on every interactive element, including `.row-link`, `.group-row`, `.tag button`, the chart `[role=button]` (rect fill), and `th button`. Inputs use the border plus a 3 px `--primary-soft` ring. Never use `outline: none` without a replacement. Flutter uses the default M3 focus highlight with `focusColor: primary α .12`.
- **Targets:** web pointer controls are ≥40×40, raised to ≥44×44 below 768 px (`@media (max-width: 767px) { button, a.button, input, select { min-height: 44px } .icon-button { width: 44px; height: 44px } }`). Exception: dense `.line` delete icons at 32 px on desktop only. Flutter targets are ≥48 (`materialTapTargetSize.padded`); the capture delete target stays 44.
- **Semantics:** keep every `aria-label`, `title`, `role`, `aria-sort`, `aria-selected`, `aria-expanded`, `role=status/alert`, the `sr-only` text, and all Flutter `Semantics` and tooltips. New badges are plain text, so screen readers read "Trader Joe's, 草稿待确认".
- **Motion:** §2.9.
- **Dark mode:** both clients honour system / light / dark. On web, `data-theme` and the media query (existing). On Flutter, `Appearance` (existing).
- **High contrast (Flutter):** `FrostedBar` becomes opaque (existing behavior, kept).
- **Language:** strings may be about 40 % longer in English. Buttons never have fixed widths; the dock is icon-only (tooltips carry the labels).

---

## 9. Constraints pinned by existing tests (do not break)

These were found by reading `tests/web/*.tsx` and `tests/shared/ui/*.dart`. The redesign above already respects them.

**Web**
- Accessible names: `打开导航菜单`, `关闭导航菜单`, nav `主导航` (it must **not** exist in the DOM after closing the drawer in jsdom; hence the `matchMedia` gating), `Language` (select label, literal English), `图例` legend list, `{0}{1}商品` expand buttons with `aria-expanded`, tab roles with `aria-selected`.
- Selectors: `[data-page="receipts"]`, `.missing-product-name`, `.line`, `tr` rows, `polyline`, and the legend `li > span` swatch, whose inline `backgroundColor` must equal the polyline's **`stroke` attribute**. Keep both as literal colors from the `colors` array; do not switch to CSS variables.
- The `AndroidDownloadLink` `href` is `/receipt_master.apk`.

**Flutter**
- Widget types found by tests: `FrostedBar` (must remain the ancestor of the menu button and of the action group), `NavigationDrawerDestination`, `ChoiceChip` (catalog, stores and report tabs), `InputChip`, `CheckboxListTile`, `AlertDialog`, `Dialog`, `Card`, `ListView`, `BackButton`, `DropdownButtonFormField<String>` / `<Locale>`, `OutlinedButton` (`重试未完成的照片上传`), `ReceiptRow`, `ReportTrendChart`, `EditorPage`, `CapturePage`, `PasswordPage`, `TextField` / `TextFormField`.
- Keys: `receipt-edit-form`, `receipt-save-actions`, `receipt-photo-panel`, `receipt-photo-image-N`, `test-photo-photo`, `capture-thumbnail-0`, `catalog-completion-divider`, `PageStorageKey('receipt-overview')`.
- Dock geometry: menu bar left = 14, action bar right = width − 14, a gap of 16 or more between them, vertically centred together; the actions `拍照` / `上传照片` / `手动` are icon-only (no visible text), each ≥48×48, inside the action bar.
- `ReceiptRow` height is exactly **56**. Its first descendant `Material`'s color is `AppPalette.warningSurface` (draft) or `AppPalette.errorSurface` (failed). Left swipe reveals the literal **`Trash`** text.
- Editor line `Card.color`: `errorSurface` (missing name), `warningSurface` (warnings), not error for tax lines. The product-name field's `inputDecorationTheme.fillColor` is `errorSurface` while empty. The raw name text fontSize is **12**.
- Editor layout: photo panel width ≈ `(width − 1) × (width < 800 ? 9/20 : 1/2)`; photo width ≈ panel − 24; image height > 0.8 × panel; `旋转 90°` inside the image within 60 px of its top; the photo panel does not scroll with the form; save actions width < 340 and on screen, to the right of the photo panel.
- Settings: username, `修改密码` and `退出登录` share a centre line, with the username to the left and weight ≥ w700. The `用户管理` ListTile is below the username with width = `screen − 32`. `全局重量显示单位` sits more than 8 px below the `重试未完成的照片上传` OutlinedButton.
- Reports: a tap at `chart.left + 52` selects index 0 (keep the plot left inset at 50). A horizontal fling changes the window. The `已选 …` text format is unchanged. The `展开饮料商品` tooltip.
- Theme: `receiptTheme(light).colorScheme.surface != receiptTheme(dark).colorScheme.surface`. `AppearancePicker` shows `跟随系统` / `浅色` / `深色` and switches the brightness.

Run `npm test` (web) and the Flutter widget tests after each step. If a test fails because of a purely visual assertion that conflicts with this spec, keep the test behavior and adapt the design locally; tests are out of scope for this redesign.

---

## 10. Localization

- **No new keys are required.** Every string in the redesign and the mockups is an existing key in `src/backend_api/resources/localizations.json`: `草稿待确认`, `识别失败`, `识别中…`, `收据内容`, `票面总金额`, `明细合计`, `差额`, `外观`, `偏好设置`, `后端数据`, and so on.
- Nothing is renamed or removed. The only literal removed is the untranslated `RECEIPT MASTER` eyebrow (not a key).
- Keep the brand `Receipt Master` and the label `Language` untranslated (as today).
- If an implementer adds any visible string anyway, add it to every language in `localizations.json` with the same placeholders; the backend tests check key parity.

---

## 11. File-by-file implementation map

Do the work in this order. Each step should leave the app working and the tests green.

### Web (`src/web`)

| Step | File | Change |
|---|---|---|
| W1 | `src/style.css` | Tokens and aliases (§4.1), base, typography, buttons, inputs, focus (§4.2), delete eyebrow styles (§4.3) |
| W2 | `src/style.css` | Cards, notices, toast, offline notice, StateView, badges, chips, tabs, segmented (§3.5–3.11) |
| W3 | `src/main.tsx` | `useWide()` and sidebar docking in `Workspace`; `has-sidebar` classes; remove the eyebrow `<p>` in `Heading` and `SignIn`; `IconButton` gets `className` / `showLabel`; toolbar actions get `showLabel` (and `拍照` gets `primary`); account chip avatar span |
| W4 | `src/style.css` | Shell: toolbar, sidebar, drawer, workspace widths, breakpoints (§3.1–3.2, §4.14) |
| W5 | `src/main.tsx` + css | Receipts table status badges (sibling spans), `notice info` on uploads; table/card CSS; stacked phone rows (§3.6, §5.2) |
| W6 | `src/main.tsx` + css | Editor: `editor-card` wrappers, card headers, reconciliation third cell, status badge, `重新识别` labeled, `.save-bar` bottom bar, line stripes, phone layout (§5.3); modal and bottom-sheet CSS (§3.9) |
| W7 | `src/main.tsx` + css | Reports: `report-card` wrapper, move the receipt-type Select into `.report-controls`, the `field inline` modifier, the `curves` button `aria-pressed`, KPI cards, group cards and `group-bar`; `colors` array → §2.3; grid-line dashes, circle stroke (§5.4, §3.13) |
| W8 | css (+ minor JSX) | Catalog, Stores, `receipt_types.tsx` (classes only), Settings cards, Users table wrapper and badges, Camera, Auth (§5.1, §5.5–5.9) |
| W9 | `index.html` | theme-color metas (§4.15) |
| W10 | — | Visual QA in Chromium and Firefox at 1440 / 1024 / 820 / 390 px in light and dark; keyboard-only pass; `prefers-reduced-motion` pass |

`src/catalog-search.tsx` needs no logic change; restyle it through `.catalog-search` / `.catalog-options` only. `api.ts`, `uploads.ts` and `i18n.ts` need no changes.

### Flutter (`src/shared/lib`)

| Step | File | Change |
|---|---|---|
| F1 | `ui/app_theme.dart` | `ReceiptTokens`, `Space`, `Motion`; explicit ColorSchemes; full `receiptTheme` component themes; remove the iOS-blue scheme and `navigationBarTheme`; `AppPalette` re-pointed; `FrostedBar` simplified; `PageHeading` and `AppearancePicker` restyled (§2, §3, §6.1) |
| F2 | `ui/common.dart` | `NoticeTone` and `Notice(tone:)`, `StatusBadge`, `EmptyState`, `confirm(destructive:)` (§6.11) |
| F3 | `ui/home.dart` | Remove the gradient; upload banner; drawer header; dock restyle (`_QuickAction`, iOS toolbar); grouped receipt table card; state widgets (§6.2) |
| F4 | `ui/receipt_row.dart` | Stripe, status icons and colors, header bg, swipe-delete colors (§3.6) |
| F5 | `ui/account.dart` | Login brand mark and layout; password page; users list card, badges (§6.3) |
| F6 | `ui/capture.dart` | Accent, thumbnails, button row (§6.4) |
| F7 | `ui/editor.dart` | Photo panel bg and radii, header card, time card, items header, line card borders, reconciliation tone, save pill, AppBar actions (§6.5) |
| F8 | `ui/reports.dart`, `ui/report_trend_chart.dart` | PageHeading, remove the duplicate dropdown, chart card, hero, stats, spend rows; painter colors and dot fill (§6.6, §3.13) |
| F9 | `ui/catalog.dart`, `ui/catalog_search.dart`, `ui/category_editor.dart` | §6.7 |
| F10 | `ui/logo_aliases.dart`, `ui/receipt_types.dart`, `ui/product_receipts.dart` | §6.8, §6.9 |
| F11 | `ui/settings.dart` | Section headers, account card, `info` notices, button layout, data card (§6.10) |
| F12 | — | Run the shared widget tests; check manually on an Android device or emulator at 360×780 and 412×915 in light and dark, at text scales 1.0 and 1.6; one iOS simulator pass |

`main.dart`: no changes. Optional: theme the startup-failure `MaterialApp` with `receiptTheme(platformBrightness)`, which is a one-line improvement. `ReceiptApp` is unused; leave it.

---

## 12. Non-goals

- No new features, screens, API calls, routes or state management.
- No changes to sorting, polling, upload, offline, recognition or save logic.
- No web fonts, icon fonts, CSS frameworks or chart libraries.
- No change to the Android dock/drawer navigation model; tests pin it, and it works one-handed.
- No translation changes.
