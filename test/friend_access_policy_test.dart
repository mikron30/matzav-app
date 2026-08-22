import 'package:flutter_test/flutter_test.dart';
import 'package:matzav_app/models/friend_access_policy.dart';

void main() {
  group('FriendAccessPolicy', () {
    test('free users can add until they have seven friends', () {
      expect(
        FriendAccessPolicy.canAdd(
          currentFriendCount: 6,
          selectedFriendCount: 0,
          isPremium: false,
        ),
        isTrue,
      );
      expect(
        FriendAccessPolicy.canAdd(
          currentFriendCount: 7,
          selectedFriendCount: 0,
          isPremium: false,
        ),
        isFalse,
      );
    });

    test('selected friends consume the remaining free slots', () {
      expect(
        FriendAccessPolicy.canAdd(
          currentFriendCount: 5,
          selectedFriendCount: 1,
          isPremium: false,
        ),
        isTrue,
      );
      expect(
        FriendAccessPolicy.canAdd(
          currentFriendCount: 5,
          selectedFriendCount: 2,
          isPremium: false,
        ),
        isFalse,
      );
      expect(
        FriendAccessPolicy.remainingFreeSlots(
          currentFriendCount: 5,
          selectedFriendCount: 1,
        ),
        1,
      );
    });

    test('premium users can add above the free limit', () {
      expect(
        FriendAccessPolicy.canAdd(
          currentFriendCount: 100,
          selectedFriendCount: 20,
          isPremium: true,
        ),
        isTrue,
      );
    });

    test('existing friends above the free limit are never removed', () {
      expect(
        FriendAccessPolicy.remainingFreeSlots(
          currentFriendCount: 9,
          selectedFriendCount: 0,
        ),
        0,
      );
    });
  });
}
