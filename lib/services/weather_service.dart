import 'dart:convert';

import 'package:http/http.dart' as http;

class CurrentWeather {
  final double temperatureC;
  final double feelsLikeC;
  final int weatherCode;

  const CurrentWeather({
    required this.temperatureC,
    required this.feelsLikeC,
    required this.weatherCode,
  });
}

class HourlyForecast {
  final DateTime time;
  final double temperatureC;
  final int weatherCode;

  const HourlyForecast({
    required this.time,
    required this.temperatureC,
    required this.weatherCode,
  });
}

class WeatherDetails {
  final CurrentWeather current;

  /// Upcoming hours only (already filtered to now-or-later), soonest first.
  final List<HourlyForecast> hourly;

  const WeatherDetails({required this.current, required this.hourly});
}

/// Open-Meteo is a free weather API with no API key required — same
/// no-key-needed spirit as the map tile providers this app already uses.
class WeatherService {
  WeatherService._();

  static Future<WeatherDetails?> fetchDetails(double lat, double lon) async {
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=$lat&longitude=$lon'
      '&current=temperature_2m,apparent_temperature,weather_code'
      '&hourly=temperature_2m,weather_code'
      '&forecast_days=2&timezone=auto',
    );
    try {
      final response = await http.get(uri).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final body = jsonDecode(response.body) as Map<String, dynamic>;

      final current = body['current'] as Map<String, dynamic>?;
      if (current == null) return null;
      final temp = current['temperature_2m'];
      final feelsLike = current['apparent_temperature'];
      final code = current['weather_code'];
      if (temp is! num || code is! num) return null;

      final currentWeather = CurrentWeather(
        temperatureC: temp.toDouble(),
        feelsLikeC: (feelsLike is num ? feelsLike : temp).toDouble(),
        weatherCode: code.toInt(),
      );

      final hourlyBody = body['hourly'] as Map<String, dynamic>?;
      final hourly = <HourlyForecast>[];
      if (hourlyBody != null) {
        final times = hourlyBody['time'] as List<dynamic>? ?? [];
        final temps = hourlyBody['temperature_2m'] as List<dynamic>? ?? [];
        final codes = hourlyBody['weather_code'] as List<dynamic>? ?? [];
        final now = DateTime.now();
        for (
          var i = 0;
          i < times.length && i < temps.length && i < codes.length;
          i++
        ) {
          final t = DateTime.tryParse(times[i] as String);
          if (t == null ||
              t.isBefore(now.subtract(const Duration(minutes: 30)))) {
            continue;
          }
          final hTemp = temps[i];
          final hCode = codes[i];
          if (hTemp is! num || hCode is! num) continue;
          hourly.add(
            HourlyForecast(
              time: t,
              temperatureC: hTemp.toDouble(),
              weatherCode: hCode.toInt(),
            ),
          );
        }
      }

      return WeatherDetails(
        current: currentWeather,
        hourly: hourly.take(24).toList(),
      );
    } catch (_) {
      return null;
    }
  }

  static String labelFor(int code) {
    if (code == 0) return 'Clear';
    if (code <= 2) return 'Partly cloudy';
    if (code == 3) return 'Cloudy';
    if (code == 45 || code == 48) return 'Foggy';
    if (code >= 51 && code <= 57) return 'Drizzle';
    if (code >= 61 && code <= 67) return 'Rain';
    if (code >= 71 && code <= 77) return 'Snow';
    if (code >= 80 && code <= 82) return 'Showers';
    if (code >= 85 && code <= 86) return 'Snow showers';
    if (code >= 95) return 'Thunderstorm';
    return 'Weather';
  }
}
