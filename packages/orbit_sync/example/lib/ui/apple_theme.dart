import 'package:flutter/material.dart';

/// Apple Human Interface Guidelines design tokens and system colors.
class AppleTheme {
  // Apple System Palette
  static const Color systemBlue = Color(0xFF007AFF);
  static const Color systemBlueDark = Color(0xFF0A84FF);

  static const Color systemGreen = Color(0xFF34C759);
  static const Color systemGreenDark = Color(0xFF30D158);

  static const Color systemIndigo = Color(0xFF5856D6);
  static const Color systemIndigoDark = Color(0xFF5E5CE6);

  static const Color systemOrange = Color(0xFFFF9500);
  static const Color systemOrangeDark = Color(0xFFFF9F0A);

  static const Color systemRed = Color(0xFFFF3B30);
  static const Color systemRedDark = Color(0xFFFF453A);

  static const Color systemPurple = Color(0xFFAF52DE);
  static const Color systemPurpleDark = Color(0xFFBF5AF2);

  // Background surfaces
  static Color bg(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF000000)
          : const Color(0xFFF2F2F7);

  static Color secondaryBg(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF1C1C1E)
          : const Color(0xFFFFFFFF);

  static Color tertiaryBg(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF2C2C2E)
          : const Color(0xFFE5E5EA);

  static Color quaternaryBg(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF3A3A3C)
          : const Color(0xFFEBEBF0);

  // Labels
  static Color label(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF000000);

  static Color secondaryLabel(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF8E8E93)
          : const Color(0xFF8E8E93);

  static Color tertiaryLabel(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0xFF636366)
          : const Color(0xFFAEAEB2);

  // Dividers & Specular Highlights
  static Color divider(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0x28FFFFFF)
          : const Color(0x1F000000);

  static Color specularBorder(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark
          ? const Color(0x22FFFFFF)
          : const Color(0x33000000);

  // Dynamic Semantics
  static Color accent(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? systemBlueDark : systemBlue;

  static Color success(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? systemGreenDark : systemGreen;

  static Color warning(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? systemOrangeDark : systemOrange;

  static Color destructive(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? systemRedDark : systemRed;

  // Frosted Glass Material
  static Color glass(BuildContext context, {double opacity = 0.82}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark
        ? Color.fromRGBO(28, 28, 30, opacity)
        : Color.fromRGBO(255, 255, 255, opacity);
  }

  // Corner Radii
  static const double radiusSmall = 8.0;
  static const double radiusMedium = 12.0;
  static const double radiusLarge = 16.0;
  static const double radiusSheet = 24.0;
  static const double radiusPill = 999.0;

  // Spring animations: critically damped default (damping 1.0, response 0.3-0.4)
  static const Duration springDuration = Duration(milliseconds: 320);
  static const Duration quickDuration = Duration(milliseconds: 180);
  static const Curve springCurve = Curves.easeOutCubic;
  static const Curve bouncyCurve = Curves.easeOutBack;
}
