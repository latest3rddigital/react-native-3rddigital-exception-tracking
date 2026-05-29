package com.thirddigitalexceptiontracking

import android.app.ActivityManager
import android.content.Intent
import android.content.IntentFilter
import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.StatFs
import android.provider.Settings
import android.util.Log
import com.facebook.react.bridge.Callback
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import com.facebook.react.turbomodule.core.interfaces.TurboModule
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess
import org.json.JSONObject

class ThirdDigitalExceptionTrackingModule(
    reactContext: ReactApplicationContext
) : ReactContextBaseJavaModule(reactContext), TurboModule {

    init {
        NativeExceptionReporter.restoreConfiguration(reactContext.applicationContext)
        NativeExceptionReporter.uploadPendingException(reactContext.applicationContext)
    }

    override fun getName(): String = NAME

    @ReactMethod
    fun configureNativeExceptionHandler(options: ReadableMap) {
        NativeExceptionReporter.configureNativeFallback(
            reactApplicationContext.applicationContext,
            options
        )
    }

    @ReactMethod
    fun installNativeExceptionHandler(
        executeOriginalUncaughtExceptionHandler: Boolean,
        forceToQuit: Boolean
    ) {
        val originalHandler = Thread.getDefaultUncaughtExceptionHandler()
        NativeExceptionReporter.configure(
            null,
            originalHandler,
            executeOriginalUncaughtExceptionHandler,
            forceToQuit
        )

        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            NativeExceptionReporter.reportException(throwable)
            NativeExceptionReporter.continueCrash(thread, throwable)
        }
    }

    @ReactMethod
    fun setNativeExceptionCallback(customHandler: Callback) {
        NativeExceptionReporter.setCallback(customHandler)
    }

    @ReactMethod
    fun setHandlerforNativeException(
        executeOriginalUncaughtExceptionHandler: Boolean,
        forceToQuit: Boolean,
        customHandler: Callback
    ) {
        val originalHandler = Thread.getDefaultUncaughtExceptionHandler()
        NativeExceptionReporter.configure(
            customHandler,
            originalHandler,
            executeOriginalUncaughtExceptionHandler,
            forceToQuit
        )

        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            NativeExceptionReporter.reportException(throwable)
            NativeExceptionReporter.continueCrash(thread, throwable)
        }
    }

    @ReactMethod
    fun releaseExceptionHold(handled: Boolean) {
        NativeExceptionReporter.releaseExceptionHold(handled)
    }

    companion object {
        const val NAME = "ThirdDigitalExceptionTracking"
    }
}

object NativeExceptionReporter {
    private const val NAME = "ThirdDigitalExceptionTracking"
    private const val PREFS_NAME = "react_native_exception_handler"
    private const val PENDING_PAYLOAD_JSON_KEY = "pendingPayloadJson"
    private const val CRASH_HOLD_TIMEOUT_MS = 5000L

    private var callback: Callback? = null
    private var originalHandler: Thread.UncaughtExceptionHandler? = null
    private var executeOriginalHandler = true
    private var forceToQuit = false
    private var nativeFallbackEnabled = true
    private var ingestUrl: String? = null
    private var apiKey: String? = null
    private var projectKey: String? = null
    private var headersJson = "{}"
    private var basePayloadJson = "{}"
    private var appContext: Context? = null
    @Volatile private var currentCrashLatch: CountDownLatch? = null
    @Volatile private var lastReportedThrowableId: Int? = null
    private val privatePayloadKeys = arrayOf(
        "apiKey",
        "url",
        "headers",
        "ingestUrl",
        "project",
        "projectKey"
    )

    fun configureNativeFallback(context: Context, options: ReadableMap) {
        appContext = context.applicationContext
        ingestUrl = getString(options, "url", ingestUrl)
        apiKey = getString(options, "apiKey", apiKey)
        projectKey = getString(options, "projectKey", projectKey)
        nativeFallbackEnabled = getBoolean(options, "nativeFallbackEnabled", true)
        executeOriginalHandler = getBoolean(options, "executeOriginalHandler", executeOriginalHandler)
        forceToQuit = getBoolean(options, "forceToQuit", forceToQuit)

        if (options.hasKey("headers") && !options.isNull("headers")) {
            options.getMap("headers")?.let { headersJson = readableMapToJson(it).toString() }
        }
        if (options.hasKey("basePayload") && !options.isNull("basePayload")) {
            options.getMap("basePayload")?.let { basePayloadJson = readableMapToJson(it).toString() }
        }

        persistConfiguration(appContext)
        uploadPendingException(appContext)
    }

    fun configure(
        customHandler: Callback?,
        originalUncaughtExceptionHandler: Thread.UncaughtExceptionHandler?,
        executeOriginalUncaughtExceptionHandler: Boolean,
        shouldForceToQuit: Boolean
    ) {
        callback = customHandler
        originalHandler = originalUncaughtExceptionHandler
        executeOriginalHandler = executeOriginalUncaughtExceptionHandler
        forceToQuit = shouldForceToQuit
    }

    fun setCallback(customHandler: Callback?) {
        callback = customHandler
    }

    fun reportException(throwable: Throwable) {
        val throwableId = System.identityHashCode(throwable)
        if (lastReportedThrowableId == throwableId) {
            return
        }

        lastReportedThrowableId = throwableId
        val payload = buildPayload(throwable)
        persistPendingException(appContext, payload)

        var uploadedByNative = false
        if (nativeFallbackEnabled) {
            uploadedByNative = postException(payload)
            if (uploadedByNative) {
                clearPendingException(appContext)
            }
        }

        val crashLatch = CountDownLatch(1)
        currentCrashLatch = crashLatch

        try {
            val stackTrace = Log.getStackTraceString(throwable)
            val exceptionCallback = callback
            if (exceptionCallback == null) {
                crashLatch.countDown()
            } else {
                exceptionCallback.invoke(stackTrace, payload.toString(), uploadedByNative)
            }
        } catch (callbackError: RuntimeException) {
            Log.e(NAME, "Failed to invoke JS native exception callback", callbackError)
            crashLatch.countDown()
        }

        try {
            crashLatch.await(CRASH_HOLD_TIMEOUT_MS, TimeUnit.MILLISECONDS)
        } catch (interruptedException: InterruptedException) {
            Thread.currentThread().interrupt()
        } finally {
            currentCrashLatch = null
        }
    }

    fun releaseExceptionHold(handled: Boolean) {
        if (handled) {
            clearPendingException(appContext)
        }
        currentCrashLatch?.countDown()
    }

    fun continueCrash(thread: Thread, throwable: Throwable) {
        if (executeOriginalHandler) {
            originalHandler?.uncaughtException(thread, throwable)
            return
        }

        if (forceToQuit) {
            android.os.Process.killProcess(android.os.Process.myPid())
            exitProcess(10)
        }

        android.os.Process.killProcess(android.os.Process.myPid())
        exitProcess(10)
    }

    fun restoreConfiguration(context: Context?) {
        if (context == null) {
            return
        }

        appContext = context.applicationContext
        val prefs = appContext!!.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        ingestUrl = prefs.getString("ingestUrl", ingestUrl)
        apiKey = prefs.getString("apiKey", apiKey)
        projectKey = prefs.getString("projectKey", projectKey)
        headersJson = prefs.getString("headersJson", headersJson) ?: "{}"
        basePayloadJson = prefs.getString("basePayloadJson", basePayloadJson) ?: "{}"
        nativeFallbackEnabled = prefs.getBoolean("nativeFallbackEnabled", nativeFallbackEnabled)
        executeOriginalHandler = prefs.getBoolean("executeOriginalHandler", executeOriginalHandler)
        forceToQuit = prefs.getBoolean("forceToQuit", forceToQuit)
    }

    fun uploadPendingException(context: Context?) {
        if (context == null || !nativeFallbackEnabled) {
            return
        }

        val pendingPayloadJson = context
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(PENDING_PAYLOAD_JSON_KEY, null)
        if (pendingPayloadJson.isNullOrBlank()) {
            return
        }

        Thread({
            try {
                if (postExceptionSync(JSONObject(pendingPayloadJson))) {
                    clearPendingException(context)
                }
            } catch (exception: Exception) {
                clearPendingException(context)
            }
        }, "PendingRNExceptionUploader").start()
    }

    private fun buildPayload(throwable: Throwable): JSONObject {
        val payload = try {
            JSONObject(basePayloadJson)
        } catch (_: Exception) {
            JSONObject()
        }
        removePrivateFields(payload)

        val metadata = payload.optJSONObject("metadata") ?: JSONObject()
        metadata.put("isNativeFallbackCandidate", true)
        metadata.put("framework", "react-native")
        metadata.put("exceptionSource", "native")
        metadata.put("stackSource", "native")
        removePrivateFields(metadata)

        payload.put("source", "react-native")
        payload.put("exceptionSource", "native")
        payload.put("stackSource", "native")
        payload.put("platform", "android")
        payload.put("title", throwable.javaClass.name)
        payload.put("message", throwable.message ?: throwable.toString())
        val reportedAt = getIsoTimestamp()
        payload.put("stackTrace", Log.getStackTraceString(throwable))
        payload.put("timestamp", reportedAt)
        payload.put("reportedAt", reportedAt)
        if (!payload.has("screenName") || payload.isNull("screenName")) {
            payload.put("screenName", "")
        }
        payload.put("metadata", metadata)

        val exceptionData = payload.optJSONObject("exceptionData") ?: JSONObject()
        exceptionData.put("exceptionSource", "native")
        exceptionData.put("exceptionClass", throwable.javaClass.name)
        exceptionData.put("localizedMessage", throwable.localizedMessage)
        exceptionData.put("platform", "android")
        exceptionData.put("framework", "react-native")
        exceptionData.put("stackSource", "native")
        removePrivateFields(exceptionData)
        payload.put("exceptionData", exceptionData)

        val context = appContext
        var uniqueId: String? = payload.optString("deviceId").takeIf { it.isNotBlank() }
        if (context != null) {
            val packageInfo = try {
                context.packageManager.getPackageInfo(context.packageName, 0)
            } catch (_: Exception) {
                null
            }
            val versionName = packageInfo?.versionName
            val buildNumber = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                packageInfo?.longVersionCode?.toString()
            } else {
                @Suppress("DEPRECATION")
                packageInfo?.versionCode?.toString()
            }
            uniqueId = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ANDROID_ID
            )?.takeIf { it.isNotBlank() } ?: uniqueId
            if (!versionName.isNullOrBlank()) {
                payload.put("appVersion", versionName)
            }
            if (!buildNumber.isNullOrBlank()) {
                payload.put("buildNumber", buildNumber)
            }
            if (!versionName.isNullOrBlank() || !buildNumber.isNullOrBlank()) {
                payload.put(
                    "readableVersion",
                    listOfNotNull(versionName, buildNumber?.let { "($it)" }).joinToString(" ")
                )
            }
            payload.put("bundleId", context.packageName)
            if (!uniqueId.isNullOrBlank()) {
                payload.put("deviceId", uniqueId)
                payload.put("installationId", uniqueId)
            }
        }

        val osInfo = payload.optJSONObject("osInfo") ?: JSONObject()
        osInfo.put("osName", "android")
        osInfo.put("osVersion", Build.VERSION.RELEASE)
        osInfo.put("apiLevel", Build.VERSION.SDK_INT)
        payload.put("osInfo", osInfo)

        val deviceInfo = payload.optJSONObject("deviceInfo") ?: JSONObject()
        deviceInfo.put("brand", Build.BRAND)
        deviceInfo.put("manufacturer", Build.MANUFACTURER)
        deviceInfo.put("model", Build.MODEL)
        deviceInfo.put("modelId", Build.DEVICE)
        deviceInfo.put("deviceName", Build.MODEL)
        if (!uniqueId.isNullOrBlank()) {
            deviceInfo.put("deviceId", uniqueId)
            deviceInfo.put("uniqueId", uniqueId)
        }
        deviceInfo.put("systemName", "Android")
        deviceInfo.put("systemVersion", Build.VERSION.RELEASE)
        deviceInfo.put("isTablet", false)
        deviceInfo.put("deviceType", Build.TYPE)
        deviceInfo.put("hasNotch", false)
        payload.put("deviceInfo", deviceInfo)

        val memoryInfo = buildMemoryInfo(context)
        val storageInfo = buildStorageInfo(context)
        val batteryInfo = buildBatteryInfo(context)
        payload.put("memoryInfo", memoryInfo)
        payload.put("storageInfo", storageInfo)
        payload.put("batteryInfo", batteryInfo)
        if (!payload.has("userInfo") || payload.isNull("userInfo")) {
            payload.put("userInfo", JSONObject())
        }

        val otherDetails = payload.optJSONObject("otherDetails") ?: JSONObject()
        otherDetails.put("exceptionSource", "native")
        otherDetails.put("platform", "android")
        otherDetails.put("framework", "react-native")
        otherDetails.put("memoryInfo", memoryInfo)
        otherDetails.put("storageInfo", storageInfo)
        otherDetails.put("batteryInfo", batteryInfo)
        removePrivateFields(otherDetails)
        payload.put("otherDetails", otherDetails)
        val extraData = payload.optJSONObject("extraData") ?: JSONObject(otherDetails.toString())
        removePrivateFields(extraData)
        payload.put("extraData", extraData)

        removePrivateFields(payload)

        return payload
    }

    private fun buildMemoryInfo(context: Context?): JSONObject {
        val memoryInfo = JSONObject()
        try {
            val runtime = Runtime.getRuntime()
            memoryInfo.put("usedMemory", runtime.totalMemory() - runtime.freeMemory())
            memoryInfo.put("maxMemory", runtime.maxMemory())

            if (context != null) {
                val activityManager = context.getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
                val systemMemoryInfo = ActivityManager.MemoryInfo()
                activityManager?.getMemoryInfo(systemMemoryInfo)
                memoryInfo.put("totalMemory", systemMemoryInfo.totalMem)
                memoryInfo.put("availableMemory", systemMemoryInfo.availMem)
                memoryInfo.put("isLowMemory", systemMemoryInfo.lowMemory)
            }
        } catch (_: Exception) {
        }
        return memoryInfo
    }

    private fun buildStorageInfo(context: Context?): JSONObject {
        val storageInfo = JSONObject()
        try {
            val path = context?.filesDir?.absolutePath ?: "/"
            val statFs = StatFs(path)
            storageInfo.put("totalDiskCapacity", statFs.totalBytes)
            storageInfo.put("freeDiskStorage", statFs.availableBytes)
        } catch (_: Exception) {
        }
        return storageInfo
    }

    private fun buildBatteryInfo(context: Context?): JSONObject {
        val batteryInfo = JSONObject()
        if (context == null) {
            return batteryInfo
        }

        try {
            val batteryStatus = context.registerReceiver(
                null,
                IntentFilter(Intent.ACTION_BATTERY_CHANGED)
            )
            val level = batteryStatus?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
            val scale = batteryStatus?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
            if (level >= 0 && scale > 0) {
                batteryInfo.put("batteryLevel", level.toDouble() / scale.toDouble())
            }
            batteryInfo.put("batteryState", batteryStatus?.getIntExtra(BatteryManager.EXTRA_STATUS, -1))
            batteryInfo.put("plugged", batteryStatus?.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1))
            batteryInfo.put("health", batteryStatus?.getIntExtra(BatteryManager.EXTRA_HEALTH, -1))
            batteryInfo.put("temperature", batteryStatus?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, -1))
            batteryInfo.put("voltage", batteryStatus?.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1))
        } catch (_: Exception) {
        }

        return batteryInfo
    }

    private fun removePrivateFields(json: JSONObject) {
        privatePayloadKeys.forEach { key -> json.remove(key) }
    }

    private fun postException(payload: JSONObject): Boolean {
        val uploaded = booleanArrayOf(false)
        val uploadThread = Thread({
            uploaded[0] = postExceptionSync(payload)
        }, "RNExceptionUploader")
        uploadThread.start()
        try {
            uploadThread.join(5000)
        } catch (interruptedException: InterruptedException) {
            Thread.currentThread().interrupt()
        }
        return uploaded[0]
    }

    private fun postExceptionSync(payload: JSONObject): Boolean {
        val urlString = ingestUrl
        if (urlString.isNullOrBlank()) {
            Log.e(NAME, "Native fallback skipped because ingest URL is not configured")
            return false
        }

        var connection: HttpURLConnection? = null
        return try {
            connection = URL(urlString).openConnection() as HttpURLConnection
            connection.requestMethod = "POST"
            connection.connectTimeout = 4000
            connection.readTimeout = 4000
            connection.doOutput = true
            connection.setRequestProperty("Content-Type", "application/json")
            if (!apiKey.isNullOrBlank()) {
                connection.setRequestProperty("Api-Key", apiKey)
            }

            val headers = JSONObject(headersJson)
            headers.keys().forEach { key ->
                connection.setRequestProperty(key, headers.optString(key))
            }

            val body = payload.toString().toByteArray(Charsets.UTF_8)
            connection.outputStream.use { outputStream: OutputStream ->
                outputStream.write(body)
            }

            val responseCode = connection.responseCode
            if (responseCode < 200 || responseCode >= 300) {
                Log.e(NAME, "Native fallback failed with status $responseCode")
                false
            } else {
                true
            }
        } catch (exception: Exception) {
            Log.e(NAME, "Native fallback failed", exception)
            false
        } finally {
            connection?.disconnect()
        }
    }

    private fun persistConfiguration(context: Context?) {
        if (context == null) {
            return
        }

        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString("ingestUrl", ingestUrl)
            .putString("apiKey", apiKey)
            .putString("projectKey", projectKey)
            .putString("headersJson", headersJson)
            .putString("basePayloadJson", basePayloadJson)
            .putBoolean("nativeFallbackEnabled", nativeFallbackEnabled)
            .putBoolean("executeOriginalHandler", executeOriginalHandler)
            .putBoolean("forceToQuit", forceToQuit)
            .apply()
    }

    private fun persistPendingException(context: Context?, payload: JSONObject) {
        if (context == null) {
            return
        }

        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(PENDING_PAYLOAD_JSON_KEY, payload.toString())
            .commit()
    }

    private fun clearPendingException(context: Context?) {
        if (context == null) {
            return
        }

        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .remove(PENDING_PAYLOAD_JSON_KEY)
            .commit()
    }

    private fun getIsoTimestamp(): String {
        val dateFormat = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        dateFormat.timeZone = TimeZone.getTimeZone("UTC")
        return dateFormat.format(Date())
    }

    private fun getString(options: ReadableMap, key: String, fallback: String?): String? {
        return if (options.hasKey(key) && !options.isNull(key)) options.getString(key) else fallback
    }

    private fun getBoolean(options: ReadableMap, key: String, fallback: Boolean): Boolean {
        return if (options.hasKey(key) && !options.isNull(key)) options.getBoolean(key) else fallback
    }

    private fun readableMapToJson(map: ReadableMap): JSONObject {
        val json = JSONObject()
        val iterator = map.keySetIterator()
        while (iterator.hasNextKey()) {
            val key = iterator.nextKey()
            when (map.getType(key)) {
                com.facebook.react.bridge.ReadableType.Null -> json.put(key, JSONObject.NULL)
                com.facebook.react.bridge.ReadableType.Boolean -> json.put(key, map.getBoolean(key))
                com.facebook.react.bridge.ReadableType.Number -> json.put(key, map.getDouble(key))
                com.facebook.react.bridge.ReadableType.String -> json.put(key, map.getString(key))
                com.facebook.react.bridge.ReadableType.Map -> json.put(key, readableMapToJson(map.getMap(key)!!))
                com.facebook.react.bridge.ReadableType.Array -> json.put(key, Arguments.toList(map.getArray(key)))
            }
        }
        return json
    }
}
