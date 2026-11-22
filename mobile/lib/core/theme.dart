import 'package:material_ui/material_ui.dart';

/// A familiar video-app look: flat white / near-black surfaces, grey metadata,
/// pill chips, edge-to-edge thumbnails, red accent. TheoremFeed keeps its own
/// name and mark (no third-party logo or wordmark).
class AppColors {
  static const accent = Color(0xFFFF0000); // red accent
  static const lightBg = Color(0xFFFFFFFF);
  static const lightText = Color(0xFF0F0F0F);
  static const lightMeta = Color(0xFF606060);
  static const lightChip = Color(0xFFF2F2F2);
  static const lightDivider = Color(0xFFE5E5E5);
  static const darkBg = Color(0xFF0F0F0F);
  static const darkText = Color(0xFFF1F1F1);
  static const darkMeta = Color(0xFFAAAAAA);
  static const darkChip = Color(0xFF272727);
  static const darkDivider = Color(0xFF3F3F3F);
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final bg = dark ? AppColors.darkBg : AppColors.lightBg;
  final text = dark ? AppColors.darkText : AppColors.lightText;
  final meta = dark ? AppColors.darkMeta : AppColors.lightMeta;
  final chip = dark ? AppColors.darkChip : AppColors.lightChip;
  final scheme = ColorScheme.fromSeed(seedColor: AppColors.accent, brightness: brightness).copyWith(
    primary: AppColors.accent,
    surface: bg,
    onSurface: text,
    onSurfaceVariant: meta,
    surfaceContainerHighest: chip,
    surfaceContainerHigh: chip,
    surfaceContainer: chip,
    outlineVariant: dark ? AppColors.darkDivider : AppColors.lightDivider,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: bg,
    canvasColor: bg,
    dividerColor: scheme.outlineVariant,
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      foregroundColor: text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(color: text, fontSize: 20, fontWeight: FontWeight.w600),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: bg,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      height: 56,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 10, color: text)),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: text, size: 24)),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: chip,
      selectedColor: text,
      side: BorderSide.none,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      labelStyle: TextStyle(color: text, fontSize: 14, fontWeight: FontWeight.w500),
      secondaryLabelStyle: TextStyle(color: bg, fontSize: 14, fontWeight: FontWeight.w500),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    cardTheme: CardThemeData(color: bg, elevation: 0, margin: EdgeInsets.zero),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: text,
        foregroundColor: bg,
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: text,
        backgroundColor: chip,
        side: BorderSide.none,
        shape: const StadiumBorder(),
      ),
    ),
    textTheme: const TextTheme().apply(bodyColor: text, displayColor: text),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
  );
}

/// "17:02", "1:02:05" — the badge format on thumbnails.
String formatDuration(int seconds) {
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  String two(int n) => n.toString().padLeft(2, '0');
  return h > 0 ? '$h:${two(m)}:${two(s)}' : '$m:${two(s)}';
}

/// TheoremFeed's mark: a white integral sign in a red rounded box.
class AppMark extends StatelessWidget {
  const AppMark({super.key, this.size = 28});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size * 1.4,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: AppColors.accent, borderRadius: BorderRadius.circular(size * 0.3)),
      child: Text('∫', style: TextStyle(color: Colors.white, fontSize: size * 0.72, fontWeight: FontWeight.w800, height: 1)),
    );
  }
}

/// Round "channel" avatar for a concept: initials on a colour derived from the name.
class ConceptAvatar extends StatelessWidget {
  const ConceptAvatar(this.name, {super.key, this.radius = 18});
  final String name;
  final double radius;

  static const _palette = [
    Color(0xFF3D5AFE), Color(0xFF00897B), Color(0xFF8E24AA), Color(0xFFEF6C00),
    Color(0xFF6D4C41), Color(0xFF1E88E5), Color(0xFF43A047), Color(0xFFD81B60),
  ];

  @override
  Widget build(BuildContext context) {
    final words = name.split(RegExp(r"[\s'-]+")).where((w) => w.isNotEmpty).toList();
    final initials = words.take(2).map((w) => w[0].toUpperCase()).join();
    final color = _palette[name.codeUnits.fold(0, (a, b) => a + b) % _palette.length];
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      child: Text(initials, style: TextStyle(color: Colors.white, fontSize: radius * 0.75, fontWeight: FontWeight.w600)),
    );
  }
}
