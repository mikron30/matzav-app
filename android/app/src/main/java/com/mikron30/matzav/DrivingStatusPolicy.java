package com.mikron30.matzav;

import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Objects;

/** Pure status decisions shared by the Android worker and executable JVM tests. */
public final class DrivingStatusPolicy {
    private DrivingStatusPolicy() {}

    public static boolean requiresPhysicalActivityPermission(boolean driving, boolean sleep) {
        return driving || sleep;
    }

    public static boolean isCurrentSnapshot(String owner, String signedInUser,
            String stateOwner, long revision, long currentRevision) {
        return owner != null && !owner.isEmpty() && owner.equals(signedInUser)
                && owner.equals(stateOwner) && revision == currentRevision;
    }

    public static boolean isDeferred(Map<String, Object> profile, boolean overrideActive) {
        String override = string(profile.get("automaticNativeOverride"), "none");
        return overrideActive || "onCall".equals(override) || "sleeping".equals(override);
    }

    /** Null values mean delete a field. Timer values are epoch milliseconds. */
    public static Map<String, Object> updates(Map<String, Object> profile,
            boolean driving, boolean overrideActive, String fallback, long now) {
        Map<String, Object> changes = new LinkedHashMap<>();
        if (isDeferred(profile, overrideActive)) return changes;

        String current = string(profile.get("activity"), "home");
        boolean owned = Boolean.TRUE.equals(profile.get("nativeDrivingDetected"));
        String saved = string(profile.get("nativeDrivingPreviousActivity"), null);
        if (driving) {
            if (!owned || saved == null) {
                String previous = stable(current) ? current : safe(fallback);
                changes.put("nativeDrivingPreviousActivity", previous);
            }
            if (!owned) changes.put("nativeDrivingDetected", true);
            if (!"driving".equals(current)) changes.put("activity", "driving");
            adjustAvailability(profile, changes, "driving", now);
        } else {
            // Do not undo a manual change made after the detected trip.
            if (owned && "driving".equals(current)) {
                String restore = safe(saved != null ? saved : fallback);
                if ("meeting".equals(restore) && expired(profile.get("activityTimerEndsAt"), now)) {
                    restore = safe(string(profile.get("activityTimerPrevious"), "home"));
                    changes.put("activityTimerEndsAt", null);
                    changes.put("activityTimerPrevious", null);
                }
                changes.put("activity", restore);
                adjustAvailability(profile, changes, restore, now);
            }
            if (profile.containsKey("nativeDrivingDetected")) changes.put("nativeDrivingDetected", null);
            if (profile.containsKey("nativeDrivingPreviousActivity")) changes.put("nativeDrivingPreviousActivity", null);
        }
        return changes;
    }

    public static boolean stable(String activity) {
        return activity != null && !activity.isEmpty() && !"driving".equals(activity)
                && !"onCall".equals(activity) && !"sleeping".equals(activity);
    }

    private static String safe(String activity) {
        return stable(activity) ? activity : "home";
    }

    private static String string(Object value, String fallback) {
        return value instanceof String && !((String) value).isEmpty() ? (String) value : fallback;
    }

    private static boolean expired(Object value, long now) {
        return value instanceof Number && ((Number) value).longValue() <= now;
    }

    private static void adjustAvailability(Map<String, Object> profile,
            Map<String, Object> changes, String activity, long now) {
        String current = string(profile.get("availability"), "canTalk");
        String previous = string(profile.get("busyAvailabilityPrevious"), null);
        if ("meeting".equals(activity)) {
            if (previous == null) {
                String restore = "doNotDisturb".equals(current)
                        && profile.get("availabilityTimerEndsAt") == null ? "canTalk" : current;
                changes.put("busyAvailabilityPrevious", restore);
            }
            if (!"doNotDisturb".equals(current)) changes.put("availability", "doNotDisturb");
        } else if (previous != null) {
            if ("doNotDisturb".equals(previous) && expired(profile.get("availabilityTimerEndsAt"), now)) {
                previous = string(profile.get("availabilityTimerPrevious"), "canTalk");
                changes.put("availabilityTimerEndsAt", null);
                changes.put("availabilityTimerPrevious", null);
            }
            if (!Objects.equals(current, previous)) changes.put("availability", previous);
            changes.put("busyAvailabilityPrevious", null);
        }
    }
}
