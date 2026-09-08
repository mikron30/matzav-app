package com.mikron30.matzav;

import java.util.HashMap;
import java.util.Map;
import java.util.Objects;

/** Runs without Android/Firebase. Exercises the actual worker decision code. */
public final class DrivingStatusPolicyTest {
    private static int passed;
    private static final long NOW = 10_000L;

    public static void main(String[] args) {
        check("driving-only requests Physical Activity",
                DrivingStatusPolicy.requiresPhysicalActivityPermission(true, false));
        check("sleep-only still requests Physical Activity",
                DrivingStatusPolicy.requiresPhysicalActivityPermission(false, true));
        check("neither detector requests Physical Activity",
                !DrivingStatusPolicy.requiresPhysicalActivityPermission(false, false));

        Map<String, Object> home = map("activity", "home", "availability", "canTalk");
        Map<String, Object> entered = apply(home, change(home, true));
        equal("enter publishes driving", "driving", entered.get("activity"));
        equal("enter remembers home", "home", entered.get("nativeDrivingPreviousActivity"));
        check("repeat enter is idempotent", change(entered, true).isEmpty());
        Map<String, Object> exited = apply(entered, change(entered, false));
        equal("exit restores home", "home", exited.get("activity"));
        check("exit clears ownership", !exited.containsKey("nativeDrivingDetected"));
        check("exit clears saved activity", !exited.containsKey("nativeDrivingPreviousActivity"));

        Map<String, Object> manual = new HashMap<>(entered);
        manual.put("activity", "work");
        equal("exit preserves a later manual status", "work",
                apply(manual, change(manual, false)).get("activity"));
        check("manual driving without native ownership is left alone",
                change(map("activity", "driving"), false).isEmpty());

        check("call priority while entering", DrivingStatusPolicy.updates(home, true, true, "home", NOW).isEmpty());
        check("sleep priority while exiting", DrivingStatusPolicy.updates(entered, false, true, "home", NOW).isEmpty());
        Map<String, Object> duringCall = new HashMap<>(entered);
        duringCall.put("activity", "onCall");
        duringCall.put("automaticNativeOverride", "onCall");
        check("wait for the call restoration write", change(duringCall, true).isEmpty());
        duringCall.remove("automaticNativeOverride");
        duringCall.put("activity", "driving");
        equal("trip that ended during a call restores afterward", "home",
                apply(duringCall, change(duringCall, false)).get("activity"));

        Map<String, Object> expiredMeeting = map("activity", "driving",
                "nativeDrivingDetected", true, "nativeDrivingPreviousActivity", "meeting",
                "activityTimerEndsAt", NOW - 1, "activityTimerPrevious", "work");
        Map<String, Object> afterMeeting = apply(expiredMeeting, change(expiredMeeting, false));
        equal("expired meeting is not resurrected", "work", afterMeeting.get("activity"));
        check("expired meeting timer is cleared", !afterMeeting.containsKey("activityTimerEndsAt"));

        Map<String, Object> meeting = map("activity", "meeting", "availability", "doNotDisturb",
                "busyAvailabilityPrevious", "freeToTalk", "activityTimerEndsAt", NOW + 1);
        Map<String, Object> fromMeeting = apply(meeting, change(meeting, true));
        equal("driving releases meeting DND", "freeToTalk", fromMeeting.get("availability"));
        Map<String, Object> returnMeeting = apply(fromMeeting, change(fromMeeting, false));
        equal("unexpired meeting returns", "meeting", returnMeeting.get("activity"));
        equal("meeting DND is restored", "doNotDisturb", returnMeeting.get("availability"));

        Map<String, Object> timedDnd = map("activity", "meeting", "availability", "doNotDisturb",
                "busyAvailabilityPrevious", "doNotDisturb", "availabilityTimerEndsAt", NOW - 1,
                "availabilityTimerPrevious", "freeToTalk");
        equal("expired DND does not leak into driving", "freeToTalk",
                apply(timedDnd, change(timedDnd, true)).get("availability"));

        // Network recovery processes the final persisted EXIT, not stale queued ENTER jobs.
        check("offline enter plus exit never publishes a completed trip", change(home, false).isEmpty());
        check("late callback from old revision is rejected",
                !DrivingStatusPolicy.isCurrentSnapshot("A", "A", "A", 1, 2));
        check("latest revision is accepted", DrivingStatusPolicy.isCurrentSnapshot("A", "A", "A", 2, 2));
        check("signed-out user cannot publish", !DrivingStatusPolicy.isCurrentSnapshot("A", null, "A", 2, 2));
        check("account switch cannot publish to old account",
                !DrivingStatusPolicy.isCurrentSnapshot("A", "B", "B", 2, 2));
        check("old local account state is rejected",
                !DrivingStatusPolicy.isCurrentSnapshot("A", "A", "B", 2, 2));

        Map<String, Object> legacy = map("activity", "driving", "nativeDrivingDetected", true);
        equal("v43 migration can restore its fallback", "work",
                DrivingStatusPolicy.updates(legacy, false, false, "work", NOW).get("activity"));
        equal("temporary fallback is sanitized", "home",
                DrivingStatusPolicy.updates(legacy, false, false, "onCall", NOW).get("activity"));
        System.out.println("PASS: " + passed + " driving policy checks");
    }

    private static Map<String, Object> change(Map<String, Object> data, boolean driving) {
        return DrivingStatusPolicy.updates(data, driving, false, "home", NOW);
    }

    private static Map<String, Object> apply(Map<String, Object> data, Map<String, Object> updates) {
        Map<String, Object> result = new HashMap<>(data);
        updates.forEach((key, value) -> { if (value == null) result.remove(key); else result.put(key, value); });
        return result;
    }

    private static Map<String, Object> map(Object... values) {
        Map<String, Object> result = new HashMap<>();
        for (int i = 0; i < values.length; i += 2) result.put((String) values[i], values[i + 1]);
        return result;
    }

    private static void equal(String name, Object expected, Object actual) {
        check(name + " (expected " + expected + ", got " + actual + ")", Objects.equals(expected, actual));
    }

    private static void check(String name, boolean condition) {
        if (!condition) throw new AssertionError(name);
        passed++;
    }
}
