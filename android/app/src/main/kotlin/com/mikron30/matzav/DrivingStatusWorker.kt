package com.mikron30.matzav

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.os.SystemClock
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.google.android.gms.location.LocationServices
import com.google.android.gms.tasks.Tasks
import com.google.firebase.Timestamp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.firestore.FieldValue
import com.google.firebase.firestore.FirebaseFirestore
import com.google.firebase.firestore.SetOptions
import java.util.concurrent.TimeUnit

/** Publishes a durable native transition without needing a Flutter engine. */
class DrivingStatusWorker(context: Context, parameters: WorkerParameters) : Worker(context, parameters) {
    private data class SyncOutcome(
        val kind: String,
        val returnActivity: String? = null,
        val locationResolvedActivity: String? = null,
    )

    private data class GpsEvidence(
        val available: Boolean,
        val ageMs: Long = Long.MAX_VALUE,
        val accuracyM: Float = Float.MAX_VALUE,
        val hasSpeed: Boolean = false,
        val speedMps: Float = Float.MAX_VALUE,
        val latitude: Double = Double.NaN,
        val longitude: Double = Double.NaN,
    )

    private data class SavedZone(
        val latitude: Double,
        val longitude: Double,
        val radiusM: Double,
    )

    companion object {
        private const val GPS_GUARD_MAX_AGE_MS = 10L * 60L * 1000L
        private const val GPS_GUARD_MAX_ACCURACY_M = 100f
        private const val GPS_GUARD_STATIONARY_SPEED_MPS = 2.0f
        private const val ZONE_RESOLUTION_MAX_AGE_MS = 10L * 60L * 1000L
        private const val ZONE_RESOLUTION_MAX_ACCURACY_M = 75f
        private const val DEFAULT_ZONE_RADIUS_M = 150.0
        private const val FLUTTER_ZONES_ENABLED_KEY = "flutter.matzav_auto_zones_v31"
        private const val FLUTTER_AWAY_ENABLED_KEY = "flutter.matzav_auto_away_v34"
    }

    override fun doWork(): Result {
        val owner = inputData.getString(NativeDrivingMonitor.KEY_OWNER) ?: return Result.success()
        val state = NativeDrivingMonitor.prefs(applicationContext)
        if (state.getString(NativeDrivingMonitor.KEY_OWNER, null) != owner) return Result.success()
        val user = FirebaseAuth.getInstance().currentUser ?: run {
            recordResult(state, "auth_missing_retry")
            return Result.retry()
        }
        if (user.uid != owner) return Result.success()
        val revision = state.getLong(NativeDrivingMonitor.KEY_REVISION, 0L)
        val fallback = state.getString("previous_activity", null)
            ?: state.getString("last_non_driving", "home") ?: "home"
        val firestore = FirebaseFirestore.getInstance()
        val ref = firestore.collection("profiles").document(owner)
        val privateRef = firestore.collection("private_users").document(owner)
        val flutterPrefs =
            applicationContext.getSharedPreferences(NativeDrivingMonitor.FLUTTER_PREFS, Context.MODE_PRIVATE)
        val legacyDefault =
            flutterPrefs.getBoolean(NativeDrivingMonitor.FLUTTER_LEGACY_MASTER_KEY, true)
        val zonesEnabled = flutterPrefs.getBoolean(FLUTTER_ZONES_ENABLED_KEY, legacyDefault)
        val awayEnabled = flutterPrefs.getBoolean(FLUTTER_AWAY_ENABLED_KEY, zonesEnabled)

        recordResult(state, "running")
        val gpsEvidence = readRecentGpsEvidence()
        recordGpsEvidence(state, gpsEvidence)

        try {
            val outcome = Tasks.await(firestore.runTransaction { transaction ->
                val active = NativeDrivingMonitor.isDrivingActive(applicationContext)
                val snapshot = transaction.get(ref)
                val shouldResolveLocation =
                    !active && canResolveActivityFromLocation(gpsEvidence) &&
                        (zonesEnabled || awayEnabled)
                val privateSnapshot =
                    if (shouldResolveLocation) transaction.get(privateRef) else null
                if (isStopped || !DrivingStatusPolicy.isCurrentSnapshot(owner,
                        FirebaseAuth.getInstance().currentUser?.uid,
                        state.getString(NativeDrivingMonitor.KEY_OWNER, null), revision,
                        state.getLong(NativeDrivingMonitor.KEY_REVISION, 0L))) {
                    return@runTransaction SyncOutcome("obsolete")
                }
                if (!snapshot.exists()) return@runTransaction SyncOutcome("missing")
                val data = HashMap<String, Any>(snapshot.data ?: emptyMap())
                for (key in listOf("activityTimerEndsAt", "availabilityTimerEndsAt")) {
                    (data[key] as? Timestamp)?.let { data[key] = it.toDate().time }
                }
                val overrideActive = NativeDrivingMonitor.callOrSleepActive(applicationContext)
                if (DrivingStatusPolicy.isDeferred(data, overrideActive)) return@runTransaction SyncOutcome("deferred")
                val alreadyDrivingOrOwned =
                    data["activity"] == "driving" ||
                    data["nativeDrivingDetected"] == true
                if (active && DrivingStatusPolicy.gpsContradictsFreshEnter(
                        alreadyDrivingOrOwned,
                        gpsEvidence.available,
                        gpsEvidence.ageMs,
                        gpsEvidence.accuracyM,
                        gpsEvidence.hasSpeed,
                        gpsEvidence.speedMps,
                        GPS_GUARD_MAX_AGE_MS,
                        GPS_GUARD_MAX_ACCURACY_M,
                        GPS_GUARD_STATIONARY_SPEED_MPS,
                    )) {
                    return@runTransaction SyncOutcome("gps_stationary")
                }
                val locationResolvedActivity =
                    if (!active && privateSnapshot != null) {
                        resolveActivityFromLocation(
                            privateSnapshot.data,
                            gpsEvidence,
                            zonesEnabled,
                            awayEnabled,
                        )
                    } else {
                        null
                    }

                // For a native-owned trip, a reliable destination fix is
                // stronger than the status that happened to be active before
                // the trip. This makes a background EXIT at work restore
                // "work" instead of "home" without needing Flutter to open.
                if (locationResolvedActivity != null &&
                    data["nativeDrivingDetected"] == true &&
                    data["activity"] == "driving") {
                    data["nativeDrivingPreviousActivity"] = locationResolvedActivity
                }

                val changes = DrivingStatusPolicy.updates(
                    data,
                    active,
                    overrideActive,
                    fallback,
                    System.currentTimeMillis(),
                )
                if (changes.isNotEmpty()) {
                    val updates = hashMapOf<String, Any>()
                    for ((key, value) in changes) updates[key] = value ?: FieldValue.delete()
                    updates["updatedAt"] = FieldValue.serverTimestamp()
                    transaction.set(ref, updates, SetOptions.merge())
                }
                val returnActivity = if (active) {
                    changes["nativeDrivingPreviousActivity"] as? String
                        ?: data["nativeDrivingPreviousActivity"] as? String
                } else {
                    changes["activity"] as? String ?: data["activity"] as? String
                }
                SyncOutcome(
                    "applied",
                    returnActivity?.takeIf { DrivingStatusPolicy.stable(it) },
                    locationResolvedActivity,
                )
            }, 20, TimeUnit.SECONDS)

            recordResult(state, outcome.kind)
            outcome.locationResolvedActivity?.let {
                recordLocationResolvedActivity(state, it, gpsEvidence)
            }

            if (outcome.kind == "missing") return Result.retry()

            if (outcome.kind == "gps_stationary") {
                // Keep the native state pending and retry. If the phone really
                // starts moving, fused GPS/Flutter will quickly provide moving
                // evidence; if this was a false IN_VEHICLE classification it
                // never reaches Firestore as driving.
                return Result.retry()
            }

            if (outcome.kind == "deferred") {
                // Call/sleep completion normally schedules an immediate fresh
                // driving sync. Keep WorkManager's own retry as a second safety
                // net so a missed/failed override restoration cannot strand an
                // EXIT indefinitely.
                return Result.retry()
            }

            if (outcome.kind == "applied") {
                NativeDrivingMonitor.completeSync(applicationContext, owner, revision, outcome.returnActivity)
            }
            return Result.success()
        } catch (error: Exception) {
            if (error is InterruptedException) Thread.currentThread().interrupt()
            recordResult(state, "error_retry", error.message ?: error.javaClass.simpleName)
            Log.w("MatzavDriving", "Vehicle status sync will retry", error)
            return Result.retry()
        }
    }

    private fun readRecentGpsEvidence(): GpsEvidence {
        val fine = applicationContext.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        val coarse = applicationContext.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED
        if (!fine && !coarse) return GpsEvidence(false)

        return try {
            val location = Tasks.await(
                LocationServices.getFusedLocationProviderClient(applicationContext).lastLocation,
                3,
                TimeUnit.SECONDS,
            ) ?: return GpsEvidence(false)
            val ageMs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.JELLY_BEAN_MR1) {
                ((SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos)
                    .coerceAtLeast(0L) / 1_000_000L)
            } else {
                (System.currentTimeMillis() - location.time).coerceAtLeast(0L)
            }
            GpsEvidence(
                available = true,
                ageMs = ageMs,
                accuracyM = location.accuracy,
                hasSpeed = location.hasSpeed(),
                speedMps = location.speed,
                latitude = location.latitude,
                longitude = location.longitude,
            )
        } catch (_: Exception) {
            GpsEvidence(false)
        }
    }

    private fun canResolveActivityFromLocation(gps: GpsEvidence): Boolean {
        return gps.available &&
            gps.ageMs in 0..ZONE_RESOLUTION_MAX_AGE_MS &&
            gps.accuracyM in 0f..ZONE_RESOLUTION_MAX_ACCURACY_M &&
            !gps.latitude.isNaN() &&
            !gps.longitude.isNaN()
    }

    private fun resolveActivityFromLocation(
        privateData: Map<String, Any>?,
        gps: GpsEvidence,
        zonesEnabled: Boolean,
        awayEnabled: Boolean,
    ): String? {
        if (!canResolveActivityFromLocation(gps)) return null

        val zones = privateData?.get("zones") as? Map<*, *> ?: return null
        val home = readZone(zones["home"])
        val work = readZone(zones["work"])
        val hobby = readZone(zones["hobby"])
        val dogWalk = readZone(zones["dogWalk"])

        if ((zonesEnabled || awayEnabled) && home != null && inside(gps, home)) {
            return "home"
        }

        if (zonesEnabled) {
            if (work != null && inside(gps, work)) return "work"
            if (hobby != null && inside(gps, hobby)) return "hobby"
            if (dogWalk != null && inside(gps, dogWalk)) return "dogWalk"
        }

        if (awayEnabled && home != null) {
            val homeDistance = distanceMeters(gps, home)
            // Near a zone boundary, GPS uncertainty should not manufacture an
            // "away" status. Fall back to the pre-trip activity instead.
            if (homeDistance > home.radiusM + gps.accuracyM) return "away"
        }

        return null
    }

    private fun readZone(raw: Any?): SavedZone? {
        val map = raw as? Map<*, *> ?: return null
        val latitude = (map["lat"] as? Number)?.toDouble() ?: return null
        val longitude = (map["lng"] as? Number)?.toDouble() ?: return null
        val radius = (map["radius"] as? Number)?.toDouble() ?: DEFAULT_ZONE_RADIUS_M
        return SavedZone(latitude, longitude, radius)
    }

    private fun inside(gps: GpsEvidence, zone: SavedZone): Boolean =
        distanceMeters(gps, zone) <= zone.radiusM

    private fun distanceMeters(gps: GpsEvidence, zone: SavedZone): Double {
        val result = FloatArray(1)
        Location.distanceBetween(
            gps.latitude,
            gps.longitude,
            zone.latitude,
            zone.longitude,
            result,
        )
        return result[0].toDouble()
    }

    private fun recordLocationResolvedActivity(
        state: android.content.SharedPreferences,
        activity: String,
        gps: GpsEvidence,
    ) {
        state.edit()
            .putString("last_location_return_activity", activity)
            .putLong("last_location_return_at", System.currentTimeMillis())
            .putLong("last_location_return_gps_age_ms", gps.ageMs)
            .putFloat("last_location_return_accuracy_m", gps.accuracyM)
            .apply()
    }

    private fun recordGpsEvidence(
        state: android.content.SharedPreferences,
        gps: GpsEvidence,
    ) {
        val editor = state.edit()
            .putLong("last_gps_guard_at", System.currentTimeMillis())
            .putBoolean("last_gps_guard_available", gps.available)
        if (gps.available) {
            editor
                .putLong("last_gps_guard_age_ms", gps.ageMs)
                .putFloat("last_gps_guard_accuracy_m", gps.accuracyM)
                .putBoolean("last_gps_guard_has_speed", gps.hasSpeed)
                .putFloat("last_gps_guard_speed_mps", gps.speedMps)
        } else {
            editor
                .remove("last_gps_guard_age_ms")
                .remove("last_gps_guard_accuracy_m")
                .remove("last_gps_guard_has_speed")
                .remove("last_gps_guard_speed_mps")
        }
        editor.apply()
    }

    private fun recordResult(
        state: android.content.SharedPreferences,
        result: String,
        error: String? = null,
    ) {
        val editor = state.edit()
            .putString("last_sync_result", result)
            .putLong("last_sync_at", System.currentTimeMillis())
        if (error == null) {
            editor.remove("last_sync_error")
        } else {
            editor.putString("last_sync_error", error.take(400))
        }
        editor.apply()
    }
}
