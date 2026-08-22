import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../models/friend_access_policy.dart';
import '../services/contact_invite_service.dart';
import '../services/premium_service.dart';
import '../services/user_repository.dart';
import 'premium_screen.dart';

class AddFriendsScreen extends StatefulWidget {
  const AddFriendsScreen({super.key});

  @override
  State<AddFriendsScreen> createState() => _AddFriendsScreenState();
}

class _AddFriendsScreenState extends State<AddFriendsScreen> {
  List<Contact> _contacts = [];
  final Set<String> _selected = {};
  bool _loading = true;
  bool _saving = false;
  bool _contactsPermissionDenied = false;
  int _friendCount = 0;
  String _query = '';
  String? _loadError;

  bool get _isPremium => PremiumService.instance.isPremium;

  @override
  void initState() {
    super.initState();
    PremiumService.instance.addListener(_premiumChanged);
    _load();
  }

  @override
  void dispose() {
    PremiumService.instance.removeListener(_premiumChanged);
    super.dispose();
  }

  void _premiumChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final countFuture = UserRepository.instance.getFriendCount(uid);
      final permission = await FlutterContacts.permissions.request(
        PermissionType.read,
      );
      final count = await countFuture;

      if (permission != PermissionStatus.granted) {
        if (mounted) {
          setState(() {
            _friendCount = count;
            _contactsPermissionDenied = true;
            _loading = false;
          });
        }
        return;
      }

      final contacts = await FlutterContacts.getAll(
        properties: {
          ContactProperty.phone,
          ContactProperty.email,
          ContactProperty.photoThumbnail,
        },
      );
      contacts.sort(
        (a, b) => (a.displayName ?? '').compareTo(b.displayName ?? ''),
      );
      if (mounted) {
        setState(() {
          _contacts = contacts;
          _friendCount = count;
          _loading = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadError = error.toString();
          _loading = false;
        });
      }
    }
  }

  bool _hasIdentity(Contact contact) {
    return contact.phones.any((item) => item.number.trim().isNotEmpty) ||
        contact.emails.any((item) => item.address.trim().isNotEmpty);
  }

  Future<void> _openPremium() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            PremiumScreen(uid: FirebaseAuth.instance.currentUser!.uid),
      ),
    );
    if (mounted) setState(() {});
  }

  void _showFreeLimit() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text(
          'הגרסה החינמית מוגבלת ל־7 חברים. Premium מאפשר חברים ללא הגבלה.',
        ),
        action: SnackBarAction(label: 'Premium', onPressed: _openPremium),
      ),
    );
  }

  void _setContactSelected(String id, bool selected) {
    if (selected &&
        !FriendAccessPolicy.canAdd(
          currentFriendCount: _friendCount,
          selectedFriendCount: _selected.length,
          isPremium: _isPremium,
        )) {
      _showFreeLimit();
      return;
    }

    setState(() {
      if (selected) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
    });
  }

  Future<void> _addSelected() async {
    if (_saving || _selected.isEmpty) return;
    setState(() => _saving = true);

    var addedCount = 0;
    try {
      final uid = FirebaseAuth.instance.currentUser!.uid;
      final selectedContacts = _contacts
          .where(
            (contact) => contact.id != null && _selected.contains(contact.id),
          )
          .toList();

      for (final contact in selectedContacts) {
        final phones = contact.phones
            .map((item) => item.number.trim())
            .where((value) => value.isNotEmpty)
            .toList();
        final emails = contact.emails
            .map((item) => item.address.trim())
            .where((value) => value.isNotEmpty)
            .toList();
        final created = await UserRepository.instance.addFriendContact(
          ownerUid: uid,
          contactName: contact.displayName?.trim().isNotEmpty == true
              ? contact.displayName!.trim()
              : 'ללא שם',
          phones: phones,
          emails: emails,
          contactPhoto: contact.photo?.thumbnail,
          maxFriends: _isPremium ? null : FriendAccessPolicy.freeFriendLimit,
        );
        if (created) addedCount++;
        _selected.remove(contact.id);
      }

      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            addedCount == 0
                ? 'אנשי הקשר שבחרת כבר נמצאים ברשימת החברים.'
                : 'נוספו $addedCount חברים. אפשר לשלוח להם הזמנה מהרשימה.',
          ),
        ),
      );
    } on FriendLimitReachedException {
      if (!mounted) return;
      setState(() => _friendCount += addedCount);
      _showFreeLimit();
    } catch (error) {
      if (!mounted) return;
      setState(() => _friendCount += addedCount);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('לא ניתן להוסיף את החברים: $error')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _contacts.where((contact) {
      if (_query.trim().isEmpty) return true;
      return (contact.displayName ?? '').toLowerCase().contains(
        _query.trim().toLowerCase(),
      );
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('הוספת חברים'),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty || _saving ? null : _addSelected,
            child: _saving
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text('הוסף (${_selected.length})'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _loadError != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'לא ניתן לטעון את אנשי הקשר:\n$_loadError',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : _contactsPermissionDenied
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'כדי לבחור חברים יש לאפשר ל־Matzav גישה לאנשי הקשר בהגדרות המכשיר.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                _FriendAllowanceCard(
                  friendCount: _friendCount,
                  isPremium: _isPremium,
                  onUpgrade: _openPremium,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: TextField(
                    onChanged: (value) => setState(() => _query = value),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'חיפוש באנשי קשר',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      final contact = filtered[index];
                      final id = contact.id;
                      final selected = id != null && _selected.contains(id);
                      final hasIdentity = _hasIdentity(contact);
                      final details = [
                        ...contact.phones.map((item) => item.number),
                        ...contact.emails.map((item) => item.address),
                      ].where((value) => value.trim().isNotEmpty).join(' • ');
                      final displayName =
                          contact.displayName?.trim().isNotEmpty == true
                          ? contact.displayName!.trim()
                          : 'ללא שם';
                      return CheckboxListTile(
                        value: selected,
                        onChanged: id == null || !hasIdentity || _saving
                            ? null
                            : (value) => _setContactSelected(id, value == true),
                        title: Text(displayName),
                        subtitle: !hasIdentity
                            ? const Text('אין מספר טלפון או אימייל')
                            : details.isEmpty
                            ? null
                            : Text(details),
                        secondary: _ContactAvatar(
                          displayName: displayName,
                          thumbnail: contact.photo?.thumbnail,
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving
            ? null
            : () => ContactInviteService.instance.shareInvite(),
        icon: const Icon(Icons.ios_share),
        label: const Text('שתף הזמנה'),
      ),
    );
  }
}

class _FriendAllowanceCard extends StatelessWidget {
  const _FriendAllowanceCard({
    required this.friendCount,
    required this.isPremium,
    required this.onUpgrade,
  });

  final int friendCount;
  final bool isPremium;
  final VoidCallback onUpgrade;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: ListTile(
        leading: Icon(
          isPremium ? Icons.workspace_premium : Icons.people_outline,
        ),
        title: Text(
          isPremium
              ? '$friendCount חברים • Premium'
              : '$friendCount מתוך ${FriendAccessPolicy.freeFriendLimit} חברים בחינם',
        ),
        subtitle: Text(
          isPremium
              ? 'אפשר להוסיף חברים ללא הגבלה וללא פרסומות.'
              : 'Premium מאפשר חברים ללא הגבלה ומסיר פרסומות.',
        ),
        trailing: isPremium
            ? null
            : TextButton(onPressed: onUpgrade, child: const Text('שדרג')),
      ),
    );
  }
}

class _ContactAvatar extends StatelessWidget {
  const _ContactAvatar({required this.displayName, required this.thumbnail});

  final String displayName;
  final Uint8List? thumbnail;

  @override
  Widget build(BuildContext context) {
    final photo = thumbnail;
    return CircleAvatar(
      backgroundImage: photo == null ? null : MemoryImage(photo),
      child: photo == null
          ? Text(displayName == 'ללא שם' ? '?' : displayName.characters.first)
          : null,
    );
  }
}
