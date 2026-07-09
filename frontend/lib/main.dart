import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'pages/home_page.dart';

void main() {
  runApp(const DeepDiveTrackerApp());
}

/// Shared corner radius for cards, inputs, and buttons so the question box
/// and the answer field match exactly.
const double kCornerRadius = 14;

ThemeData _buildTheme(Brightness brightness) {
  final isDark = brightness == Brightness.dark;

  // Claude-inspired scientific palette: warm cream paper, ink text,
  // terracotta accent.
  const terracotta = Color(0xFFB4552D);
  const terracottaDark = Color(0xFFD97757);
  final scheme = ColorScheme.fromSeed(
    seedColor: terracotta,
    brightness: brightness,
  ).copyWith(
    primary: isDark ? terracottaDark : terracotta,
    // Dark mode follows the Gemini dark theme neutrals (#131314 canvas,
    // #1E1F20 surfaces); light mode keeps the warm paper palette.
    surface: isDark ? const Color(0xFF1E1F20) : const Color(0xFFFBF9F3),
    surfaceContainerHighest:
        isDark ? const Color(0xFF282A2C) : const Color(0xFFEFE9DC),
    outlineVariant: isDark ? const Color(0xFF3C4043) : const Color(0xFFDDD5C4),
    onSurface: isDark ? const Color(0xFFE3E3E3) : const Color(0xFF35311F),
    // Labels on the orange (primary) buttons use the app background color so
    // they stand out against the terracotta fill.
    onPrimary: isDark ? const Color(0xFF131314) : const Color(0xFFF4F0E5),
  );

  final baseText = isDark ? ThemeData.dark().textTheme : ThemeData.light().textTheme;
  final textTheme = GoogleFonts.libreBaskervilleTextTheme(baseText).apply(
    bodyColor: scheme.onSurface,
    displayColor: scheme.onSurface,
  );

  final shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(kCornerRadius),
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    textTheme: textTheme,
    scaffoldBackgroundColor:
        isDark ? const Color(0xFF131314) : const Color(0xFFF4F0E5),
    appBarTheme: AppBarTheme(
      backgroundColor: isDark ? const Color(0xFF131314) : const Color(0xFFF4F0E5),
      foregroundColor: scheme.onSurface,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: textTheme.titleLarge,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surface,
      shape: shape.copyWith(side: BorderSide(color: scheme.outlineVariant)),
      margin: EdgeInsets.zero,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kCornerRadius),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kCornerRadius),
        borderSide: BorderSide(color: scheme.outlineVariant),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(kCornerRadius),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kCornerRadius - 4),
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(kCornerRadius - 4),
        ),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: scheme.surfaceContainerHighest,
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
    ),
    dialogTheme: DialogThemeData(shape: shape, backgroundColor: scheme.surface),
  );
}

class DeepDiveTrackerApp extends StatelessWidget {
  const DeepDiveTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Deep Dive Tracker',
      debugShowCheckedModeBanner: false,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      home: const HomePage(),
    );
  }
}
