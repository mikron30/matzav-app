class FriendAccessPolicy {
  const FriendAccessPolicy._();

  static const int freeFriendLimit = 7;

  static int remainingFreeSlots({
    required int currentFriendCount,
    required int selectedFriendCount,
  }) {
    final remaining =
        freeFriendLimit - currentFriendCount - selectedFriendCount;
    return remaining < 0 ? 0 : remaining;
  }

  static bool canAdd({
    required int currentFriendCount,
    required int selectedFriendCount,
    required bool isPremium,
  }) {
    if (isPremium) return true;
    return currentFriendCount + selectedFriendCount < freeFriendLimit;
  }
}

class FriendLimitReachedException implements Exception {
  const FriendLimitReachedException();

  @override
  String toString() =>
      'The free version supports up to ${FriendAccessPolicy.freeFriendLimit} friends.';
}

class InvalidFriendContactException implements Exception {
  const InvalidFriendContactException(this.message);

  final String message;

  @override
  String toString() => message;
}
