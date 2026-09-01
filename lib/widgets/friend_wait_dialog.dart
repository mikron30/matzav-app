import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../models/status_models.dart';
import '../services/call_wait_service.dart';
import '../services/status_timer_service.dart';

enum FriendWaitKind { callEnd, drivingStart }

Future<void> showFriendWaitDialog({
  required BuildContext context,
  required String requesterUid,
  required List<QueryDocumentSnapshot<Map<String, dynamic>>> friendDocs,
  required FriendWaitKind kind,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _FriendWaitDialog(
      requesterUid: requesterUid,
      friendDocs: friendDocs,
      kind: kind,
    ),
  );
}

class _FriendWaitDialog extends StatefulWidget {
  const _FriendWaitDialog({
    required this.requesterUid,
    required this.friendDocs,
    required this.kind,
  });

  final String requesterUid;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> friendDocs;
  final FriendWaitKind kind;

  @override
  State<_FriendWaitDialog> createState() => _FriendWaitDialogState();
}

class _FriendWaitDialogState extends State<_FriendWaitDialog> {
  bool _loading = true;
  String? _loadError;
  final List<_WaitCandidate> _candidates = [];

  bool get _isCallEnd => widget.kind == FriendWaitKind.callEnd;

  @override
  void initState() {
    super.initState();
    _loadCandidates();
  }

  Future<void> _loadCandidates() async {
    final candidates = <_WaitCandidate>[];

    try {
      for (final friendDoc in widget.friendDocs) {
        final friend = friendDoc.data();
        final friendUid = friend['friendUid'] as String?;
        if (friendUid == null || friendUid.isEmpty) continue;

        try {
          final profileSnapshot = await FirebaseFirestore.instance
              .collection('profiles')
              .doc(friendUid)
              .get();
          final profile = profileSnapshot.data();
          if (profile == null) continue;

          final activity = StatusTimerService.effectiveActivity(profile);
          final eligible = _isCallEnd
              ? activity == ActivityStatus.onCall
              : activity != ActivityStatus.driving;
          if (!eligible) continue;

          final contactName = friend['contactName'] as String? ?? 'חבר';
          final displayName =
              profile['displayName'] as String? ?? contactName;
          final waiting = _isCallEnd
              ? await CallWaitService.instance
                    .waitingStream(
                      requesterUid: widget.requesterUid,
                      targetUid: friendUid,
                    )
                    .first
              : await CallWaitService.instance
                    .drivingWaitingStream(
                      requesterUid: widget.requesterUid,
                      targetUid: friendUid,
                    )
                    .first;

          candidates.add(
            _WaitCandidate(
              uid: friendUid,
              name: displayName,
              activity: activity,
              waiting: waiting,
            ),
          );
        } catch (_) {
          // One unavailable friend should not prevent managing the others.
        }
      }

      candidates.sort((a, b) => a.name.compareTo(b.name));
      if (!mounted) return;
      setState(() {
        _candidates
          ..clear()
          ..addAll(candidates);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadError = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _toggleCandidate(_WaitCandidate candidate, bool selected) async {
    if (candidate.busy) return;
    setState(() => candidate.busy = true);

    try {
      if (_isCallEnd) {
        if (selected) {
          final ok = await CallWaitService.instance.waitForCallEnd(
            requesterUid: widget.requesterUid,
            targetUid: candidate.uid,
            targetName: candidate.name,
          );
          if (!ok) {
            if (!mounted) return;
            setState(() => _candidates.remove(candidate));
            _showMessage('השיחה של ${candidate.name} כבר הסתיימה.');
            return;
          }
        } else {
          await CallWaitService.instance.cancelWait(
            requesterUid: widget.requesterUid,
            targetUid: candidate.uid,
          );
        }
      } else {
        if (selected) {
          final ok = await CallWaitService.instance.waitForDrivingStart(
            requesterUid: widget.requesterUid,
            targetUid: candidate.uid,
            targetName: candidate.name,
          );
          if (!ok) {
            if (!mounted) return;
            setState(() => _candidates.remove(candidate));
            _showMessage('${candidate.name} כבר התחיל/ה לנסוע.');
            return;
          }
        } else {
          await CallWaitService.instance.cancelDrivingWait(
            requesterUid: widget.requesterUid,
            targetUid: candidate.uid,
          );
        }
      }

      if (!mounted) return;
      setState(() => candidate.waiting = selected);
    } catch (e) {
      if (!mounted) return;
      _showMessage(
        selected
            ? 'לא ניתן להפעיל את ההמתנה עבור ${candidate.name}: $e'
            : 'לא ניתן לבטל את ההמתנה עבור ${candidate.name}: $e',
      );
    } finally {
      if (mounted && _candidates.contains(candidate)) {
        setState(() => candidate.busy = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final title = _isCallEnd ? 'המתן לסיום שיחה' : 'המתן לתחילת נסיעה';
    final emptyText = _isCallEnd
        ? 'אין כרגע חברים שנמצאים בשיחה.'
        : 'אין כרגע חברים שאפשר להמתין לתחילת הנסיעה שלהם.';
    final helpText = _isCallEnd
        ? 'סמן את החברים שבשיחה. ביטול הסימון מבטל מיד את ההמתנה.'
        : 'סמן את החברים שאינם בנסיעה. ביטול הסימון מבטל מיד את ההמתנה.';

    return AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 420,
        child: _loading
            ? const Padding(
                padding: EdgeInsets.all(28),
                child: Center(child: CircularProgressIndicator()),
              )
            : _loadError != null
            ? Text('לא ניתן לטעון את רשימת החברים: $_loadError')
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(helpText),
                  const SizedBox(height: 10),
                  if (_candidates.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Text(emptyText, textAlign: TextAlign.center),
                    )
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 420),
                      child: ListView.builder(
                        shrinkWrap: true,
                        itemCount: _candidates.length,
                        itemBuilder: (context, index) {
                          final candidate = _candidates[index];
                          return CheckboxListTile(
                            value: candidate.waiting,
                            onChanged: candidate.busy
                                ? null
                                : (value) {
                                    if (value == null) return;
                                    _toggleCandidate(candidate, value);
                                  },
                            controlAffinity: ListTileControlAffinity.leading,
                            secondary: candidate.busy
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Text(
                                    candidate.activity.emoji,
                                    style: const TextStyle(fontSize: 22),
                                  ),
                            title: Text(candidate.name),
                            subtitle: Text(candidate.activity.label),
                          );
                        },
                      ),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('סגור'),
        ),
      ],
    );
  }
}

class _WaitCandidate {
  _WaitCandidate({
    required this.uid,
    required this.name,
    required this.activity,
    required this.waiting,
  });

  final String uid;
  final String name;
  final ActivityStatus activity;
  bool waiting;
  bool busy = false;
}
