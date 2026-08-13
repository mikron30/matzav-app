import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import '../services/contact_invite_service.dart';
import '../services/user_repository.dart';

class AddFriendsScreen extends StatefulWidget {
  const AddFriendsScreen({super.key});

  @override
  State<AddFriendsScreen> createState() => _AddFriendsScreenState();
}

class _AddFriendsScreenState extends State<AddFriendsScreen> {
  List<Contact> _contacts = [];
  final Set<String> _selected = {};
  bool _loading = true;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await FlutterContacts.permissions.request(PermissionType.read);
    if (result != PermissionStatus.granted) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final contacts = await FlutterContacts.getAll(
      properties: {
        ContactProperty.phone,
        ContactProperty.email,
      },
    );
    contacts.sort((a, b) => (a.displayName ?? '').compareTo(b.displayName ?? ''));
    if (mounted) {
      setState(() {
        _contacts = contacts;
        _loading = false;
      });
    }
  }

  Future<void> _addSelected() async {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final selectedContacts = _contacts
        .where((c) => c.id != null && _selected.contains(c.id))
        .toList();

    for (final contact in selectedContacts) {
      final phone = contact.phones.isEmpty ? null : contact.phones.first.number;
      final email = contact.emails.isEmpty ? null : contact.emails.first.address;
      await UserRepository.instance.addFriendContact(
        ownerUid: uid,
        contactName: contact.displayName?.trim().isNotEmpty == true ? contact.displayName!.trim() : 'ללא שם',
        phone: phone,
        email: email,
      );
    }

    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('נוספו ${selectedContacts.length} חברים. אפשר לשלוח להם הזמנה מהרשימה.'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _contacts.where((c) {
      if (_query.trim().isEmpty) return true;
      return (c.displayName ?? '').toLowerCase().contains(_query.trim().toLowerCase());
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('הוספת חברים'),
        actions: [
          TextButton(
            onPressed: _selected.isEmpty ? null : _addSelected,
            child: Text('הוסף (${_selected.length})'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
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
                      final details = [
                        if (contact.phones.isNotEmpty) contact.phones.first.number,
                        if (contact.emails.isNotEmpty) contact.emails.first.address,
                      ].join(' • ');
                      final displayName = contact.displayName?.trim().isNotEmpty == true
                          ? contact.displayName!.trim()
                          : 'ללא שם';
                      return CheckboxListTile(
                        value: selected,
                        onChanged: id == null
                            ? null
                            : (value) => setState(() {
                                  if (value == true) {
                                    _selected.add(id);
                                  } else {
                                    _selected.remove(id);
                                  }
                                }),
                        title: Text(displayName),
                        subtitle: details.isEmpty ? null : Text(details),
                        secondary: CircleAvatar(
                          child: Text(
                            displayName == 'ללא שם'
                                ? '?'
                                : displayName.characters.first,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => ContactInviteService.instance.shareInvite(),
        icon: const Icon(Icons.ios_share),
        label: const Text('שתף הזמנה'),
      ),
    );
  }
}
