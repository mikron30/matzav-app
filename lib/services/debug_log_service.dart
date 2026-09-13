import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Small, local-only rolling event log used to diagnose automatic-status bugs.
/// Nothing is uploaded automatically. The user explicitly exports it from
/// Settings when they want to share a diagnostic report.
class DebugLogService {
  DebugLogService._();
  static final instance = DebugLogService._();

  static const _key = 'matzav_debug_events_v47';
  static const _maxEntries = 320;

  Future<void> _queue = Future<void>.value();

  Future<void> log(
    String source,
    String event, {
    Map<String, Object?> data = const {},
  }) {
    final entry = jsonEncode({
      'time': DateTime.now().toIso8601String(),
      'source': source,
      'event': event,
      if (data.isNotEmpty) 'data': data,
    });

    _queue = _queue.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final entries = prefs.getStringList(_key)?.toList() ?? <String>[];
      entries.add(entry);
      if (entries.length > _maxEntries) {
        entries.removeRange(0, entries.length - _maxEntries);
      }
      await prefs.setStringList(_key, entries);
    }).catchError((_) {
      // Diagnostics must never break the actual status feature.
    });

    return _queue;
  }

  Future<List<String>> read() async {
    await _queue;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_key)?.toList() ?? const <String>[];
  }

  Future<void> clear() async {
    await _queue;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
