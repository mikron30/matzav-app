class CommunityModerationService {
  CommunityModerationService._();

  static const _blockedTerms = <String>[
    'fuck',
    'fucking',
    'shit',
    'bitch',
    'cunt',
    'whore',
    'נאצי',
    'זונה',
    'שרמוטה',
  ];

  /// Matzav has no free-form public posts. The only remotely visible
  /// user-supplied text is the profile display name, so sanitize that value
  /// before it is stored in the public profile.
  static String safeDisplayName(String value) {
    var cleaned = value
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (cleaned.isEmpty) return 'משתמש Matzav';
    if (cleaned.length > 50) cleaned = cleaned.substring(0, 50).trim();

    final normalized = cleaned.toLowerCase();
    if (_blockedTerms.any(normalized.contains)) {
      return 'משתמש Matzav';
    }
    return cleaned;
  }
}
