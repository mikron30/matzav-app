import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'automation_preferences.dart';
import 'debug_log_service.dart';
import 'user_repository.dart';

class DiagnosticExportService {
  DiagnosticExportService._();
  static final instance = DiagnosticExportService._();

  static const _nativeSnapshotKey = 'matzav_native_debug_snapshot_v47';
  static const _nativeLogKey = 'matzav_native_debug_log_v47';
  static const MethodChannel _automaticStatusChannel = MethodChannel(
    'com.mikron30.matzav/automatic_status',
  );

  Future<String> buildReport(String uid) async {
    final createdAt = DateTime.now();
    final package = await PackageInfo.fromPlatform();
    final automation = await AutomationPreferences.instance.load();
    final prefs = await SharedPreferences.getInstance();
    final profileSnapshot = await FirebaseFirestore.instance
        .collection('profiles')
        .doc(uid)
        .get();
    final profile = profileSnapshot.data() ?? const <String, dynamic>{};
    final zones = await UserRepository.instance.getZones(uid);
    final dartLog = await DebugLogService.instance.read();
    final liveCallState = await _readLiveCallState();

    final locationServiceEnabled = await Geolocator.isLocationServiceEnabled();
    final locationPermission = await Geolocator.checkPermission();
    Position? position;
    try {
      position = await Geolocator.getLastKnownPosition();
    } catch (_) {
      position = null;
    }

    final buffer = StringBuffer()
      ..writeln('MATZAV DIAGNOSTIC REPORT')
      ..writeln('createdAt=${createdAt.toIso8601String()}')
      ..writeln('app=${package.version}+${package.buildNumber}')
      ..writeln('uidSuffix=${_uidSuffix(uid)}')
      ..writeln('privacy=Generated locally; shared only by explicit user action.')
      ..writeln()
      ..writeln('[AUTOMATION SETTINGS]')
      ..writeln('driving=${automation.driving}')
      ..writeln('zones=${automation.zones}')
      ..writeln('away=${automation.away}')
      ..writeln('calls=${automation.calls}')
      ..writeln('sleep=${automation.sleep}')
      ..writeln('legacyMaster=${prefs.getBool(AutomationPreferences.legacyMasterKey)}')
      ..writeln(
        'flutterLastOverride='
        '${prefs.getString('automatic_status_last_override_v1') ?? 'none'}',
      )
      ..writeln(
        'flutterPreviousActivity='
        '${prefs.getString('automatic_status_previous_activity_v1') ?? 'none'}',
      )
      ..writeln()
      ..writeln('[CURRENT PROFILE]');

    const profileKeys = <String>[
      'activity',
      'availability',
      'updatedAt',
      'activityTimerEndsAt',
      'activityTimerPrevious',
      'availabilityTimerEndsAt',
      'availabilityTimerPrevious',
      'abroadStartsAt',
      'abroadEndsAt',
      'automaticNativeOverride',
      'automaticPreviousActivity',
      'nativeDrivingDetected',
      'nativeDrivingPreviousActivity',
      'busyAvailabilityPrevious',
    ];
    for (final key in profileKeys) {
      if (profile.containsKey(key)) {
        buffer.writeln('$key=${_formatValue(profile[key])}');
      }
    }

    buffer
      ..writeln()
      ..writeln('[LOCATION NOW / LAST KNOWN]')
      ..writeln('serviceEnabled=$locationServiceEnabled')
      ..writeln('permission=${locationPermission.name}');

    if (position == null) {
      buffer.writeln('position=unavailable');
    } else {
      buffer
        ..writeln('lat=${position.latitude.toStringAsFixed(6)}')
        ..writeln('lng=${position.longitude.toStringAsFixed(6)}')
        ..writeln('accuracyM=${position.accuracy.toStringAsFixed(1)}')
        ..writeln('speedKmh=${(position.speed * 3.6).toStringAsFixed(1)}')
        ..writeln('positionTime=${position.timestamp.toIso8601String()}');
    }

    buffer
      ..writeln()
      ..writeln('[SAVED ZONES]');
    if (zones.isEmpty) {
      buffer.writeln('none');
    } else {
      for (final entry in zones.entries) {
        final raw = entry.value;
        if (raw is! Map) continue;
        final zone = Map<String, dynamic>.from(raw);
        final lat = (zone['lat'] as num?)?.toDouble();
        final lng = (zone['lng'] as num?)?.toDouble();
        final radius = (zone['radius'] as num?)?.toDouble() ?? 150;
        if (lat == null || lng == null) continue;
        final distance = position == null
            ? null
            : Geolocator.distanceBetween(
                position.latitude,
                position.longitude,
                lat,
                lng,
              );
        buffer.writeln(
          '${entry.key}: lat=${lat.toStringAsFixed(6)}, '
          'lng=${lng.toStringAsFixed(6)}, radiusM=${radius.toStringAsFixed(0)}, '
          'distanceNowM=${distance?.toStringAsFixed(0) ?? 'unknown'}',
        );
      }
    }

    buffer
      ..writeln()
      ..writeln('[NATIVE ANDROID LIVE CALL STATE]')
      ..writeln(
        liveCallState == null
            ? 'unavailable'
            : const JsonEncoder.withIndent('  ').convert(liveCallState),
      )
      ..writeln()
      ..writeln('[NATIVE ANDROID SNAPSHOT]')
      ..writeln(_prettyJsonOrText(prefs.getString(_nativeSnapshotKey)))
      ..writeln()
      ..writeln('[NATIVE ANDROID RECENT EVENTS]')
      ..writeln(prefs.getString(_nativeLogKey) ?? 'none')
      ..writeln()
      ..writeln('[FLUTTER RECENT EVENTS]');

    if (dartLog.isEmpty) {
      buffer.writeln('none');
    } else {
      for (final line in dartLog) {
        buffer.writeln(line);
      }
    }

    return buffer.toString();
  }

  Future<void> shareReport(String uid) async {
    final report = await buildReport(uid);
    await SharePlus.instance.share(
      ShareParams(
        text: report,
        subject: 'Matzav diagnostic report',
      ),
    );
  }

  Future<void> copyReport(String uid) async {
    final report = await buildReport(uid);
    await Clipboard.setData(ClipboardData(text: report));
  }

  Future<void> clearLogs() async {
    await DebugLogService.instance.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_nativeLogKey);
  }

  Future<Map<String, dynamic>?> _readLiveCallState() async {
    try {
      final raw = await _automaticStatusChannel
          .invokeMapMethod<String, dynamic>('getCallDiagnostics');
      return raw == null ? null : Map<String, dynamic>.from(raw);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (error) {
      return <String, dynamic>{
        'error': error.code,
        if (error.message != null) 'message': error.message,
      };
    }
  }

  String _uidSuffix(String uid) {
    if (uid.length <= 6) return uid;
    return '...${uid.substring(uid.length - 6)}';
  }

  String _formatValue(Object? value) {
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is DateTime) return value.toIso8601String();
    return value?.toString() ?? 'null';
  }

  String _prettyJsonOrText(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 'none';
    try {
      final decoded = jsonDecode(raw);
      return const JsonEncoder.withIndent('  ').convert(decoded);
    } catch (_) {
      return raw;
    }
  }
}
