import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide dark mode toggle. A single global instance so both the
/// MaterialApp (to apply the theme) and Settings (to flip it) can share it
/// without threading state through every screen.
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController() : super(ThemeMode.light) {
    _load();
  }

  static const _prefKey = 'dark_mode_enabled';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      value = (prefs.getBool(_prefKey) ?? false)
          ? ThemeMode.dark
          : ThemeMode.light;
    } catch (_) {
      // Keep the light-mode default if prefs aren't available.
    }
  }

  Future<void> setDark(bool isDark) async {
    value = isDark ? ThemeMode.dark : ThemeMode.light;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, isDark);
    } catch (_) {
      // Non-fatal; the toggle still works for the rest of this session.
    }
  }
}

final themeController = ThemeController();
