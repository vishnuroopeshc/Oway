import 'package:flutter/material.dart';

/// Shared color palette so every screen pulls from the same source
/// instead of repeating hex literals.
class AppColors {
  AppColors._();

  static const seed = Color(0xFF4A6741);

  static const primaryGreen = Color(0xFF2E7D32);
  static const dangerRed = Color(0xFFD64545);
  static const neutralDark = Color(0xFF4F4F4F);
  static const accentBlue = Color(0xFF3B7DDD);
  static const discoveryAmber = Color(0xFFFFC107);

  static const cardBorder = Color(0xFFE7E4DC);
  static const mapPlaceholder = Color(0xFFE9E4D8);

  static const savedRoute = Colors.blue;
  static const liveRoute = Colors.green;
}
