import 'package:share_plus/share_plus.dart';

class ContactInviteService {
  static const String inviteUrl = String.fromEnvironment(
    'MATZAV_INVITE_URL',
    defaultValue: 'https://example.com/matzav',
  );

  ContactInviteService._();
  static final instance = ContactInviteService._();

  static const String inviteText =
      'היי! הוספתי אותך ל-Matzav כדי שנוכל לראות מתי נוח לדבר. '
      'הורד/י את האפליקציה והתחבר/י עם הטלפון או המייל שלך. '
      'קישור התקנה: $inviteUrl';

  Future<void> shareInvite({String? contactName}) async {
    final prefix = (contactName == null || contactName.trim().isEmpty)
        ? ''
        : '${contactName.trim()}, ';
    await SharePlus.instance.share(
      ShareParams(
        text: '$prefix$inviteText',
        subject: 'הזמנה ל-Matzav',
      ),
    );
  }
}
