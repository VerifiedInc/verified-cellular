package network.verified.cellular

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlin.time.Duration
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.Duration.Companion.seconds

// The channel bridge, and nothing else. The forcing, the HTTP and the decoding are
// all in VerifiedCellular.kt, which is the Android app's file copied over with
// only its package line changed — this file is the only part of the module that
// knows Dart exists.
//
// A failure crosses as an error with a code and `details`, and `details` can carry
// any value the standard message codec encodes — a map included. So unlike the
// React Native port, which has to answer with a record because an Expo exception
// carries only a code and a sentence, here a throw is lossless: the code names the
// case and `details` carries the status code, URL and body that go with it.
//
// The wording of those failures is deliberately not here. It belongs to the Dart
// layer, which is the one copy iOS and Android share; the native apps each carry
// their own.

class VerifiedCellularPlugin(private val context: Context) {
    private val mainHandler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    private var methodChannel: MethodChannel? = null
    private var cellularChannel: EventChannel? = null
    private var routeChannel: EventChannel? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, "verified_cellular").also {
            it.setMethodCallHandler(::handle)
        }
        // Scoped to cellular: does a usable cellular network exist at all, whatever
        // the default route happens to be. This is what gates the button on the
        // Dart side.
        cellularChannel = EventChannel(messenger, "verified_cellular/cellular_available").also {
            it.setStreamHandler(CellularAvailableHandler(context, mainHandler))
        }
        // Unscoped: which network currently wins the default route. Display copy
        // only, it gates nothing.
        routeChannel = EventChannel(messenger, "verified_cellular/wifi_is_default_route").also {
            it.setStreamHandler(WifiIsDefaultRouteHandler(context, mainHandler))
        }
    }

    fun detach() {
        methodChannel?.setMethodCallHandler(null)
        cellularChannel?.setStreamHandler(null)
        routeChannel?.setStreamHandler(null)
        methodChannel = null
        cellularChannel = null
        routeChannel = null
        scope.cancel()
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getDeviceIp" -> getDeviceIp(call, result)
            "followRedirects" -> followRedirects(call, result)
            else -> result.notImplemented()
        }
    }

    private fun getDeviceIp(call: MethodCall, result: MethodChannel.Result) {
        val timeout = call.timeout(default = 3.seconds)
        scope.launch {
            try {
                result.success(VerifiedCellular.getDeviceIp(context, timeout))
            } catch (error: CellularError) {
                result.error(error)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (unexpected: Exception) {
                result.unexpected(unexpected)
            }
        }
    }

    private fun followRedirects(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url")
        if (url == null) {
            result.error("UNUSABLE_URL", null, null)
            return
        }
        val timeout = call.timeout(default = 10.seconds)

        scope.launch {
            try {
                VerifiedCellular.followRedirects(context, url, timeout).fold(
                    onSuccess = { result.success(it.toMap()) },
                    onFailure = { failure ->
                        // followRedirects only ever *returns* an ApiError; a
                        // CellularError is thrown, and caught below.
                        val apiError = failure as? VerifiedCellular.ApiError ?: throw failure
                        result.error("API_ERROR", null, apiError.toMap())
                    },
                )
            } catch (error: CellularError) {
                result.error(error)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (unexpected: Exception) {
                result.unexpected(unexpected)
            }
        }
    }

    private fun MethodCall.timeout(default: Duration): Duration =
        argument<Number>("timeoutMs")?.toLong()?.milliseconds ?: default

    /**
     * `code` is the wire name of the case — the Swift bridge and the Dart wrapper
     * spell the same six, and that agreement is the whole contract. No message:
     * the sentence a person reads is Dart's to write.
     */
    private fun MethodChannel.Result.error(error: CellularError) = when (error) {
        is CellularError.NoCellularAvailable -> error("NO_CELLULAR_AVAILABLE", null, null)
        is CellularError.Timeout -> error("TIMEOUT", null, null)
        is CellularError.TooManyRedirects -> error("TOO_MANY_REDIRECTS", null, null)
        is CellularError.CleartextRedirectBlocked -> error("CLEARTEXT_REDIRECT_BLOCKED", null, null)

        is CellularError.UnusableURL ->
            error("UNUSABLE_URL", null, mapOf("url" to error.url))

        // The body travels because it is the only thing that explains a carrier
        // gateway answering 200 with a login page.
        is CellularError.UnreadableBody -> error(
            "UNREADABLE_BODY",
            null,
            mapOf(
                "statusCode" to error.statusCode,
                "url" to error.url,
                "body" to error.body,
            ),
        )
    }

    /**
     * Anything the snippet did not classify — an IOException the connection
     * surfaced, say. Reported under its own code so Dart's message ladder falls
     * through to it rather than calling it something it isn't.
     */
    private fun MethodChannel.Result.unexpected(cause: Exception) =
        error("UNEXPECTED", cause.message ?: cause.javaClass.simpleName, null)
}

/**
 * `isVerified` is left off on purpose: it is derived, and Dart derives it the same
 * way rather than trusting a second copy of the rule to have travelled. A key left
 * out reads as null in Dart, which is what these fields mean when the record
 * hasn't reached that point in its life.
 */
private fun VerifiedCellular.OneClickVerificationEntity.toMap(): Map<String, Any> =
    buildMap {
        put("uuid", uuid)
        channel?.let { put("channel", it) }
        status?.let { put("status", it) }
        phone?.let { put("phone", it) }
        verified?.let { put("verified", it) }
        createdAt?.let { put("createdAt", it) }
        expiresAt?.let { put("expiresAt", it) }
        verifiedAt?.let { put("verifiedAt", it) }
        deliveredAt?.let { put("deliveredAt", it) }
        attemptsRemaining?.let { put("attemptsRemaining", it) }
    }

/** Same reasoning for `describedMessage`: Dart composes it from these fields. */
private fun VerifiedCellular.ApiError.toMap(): Map<String, Any> =
    buildMap {
        put("message", message)
        name?.let { put("name", it) }
        code?.let { put("code", it) }
        className?.let { put("className", it) }
        errorCode?.let { put("errorCode", it) }
    }

/**
 * `registerNetworkCallback`, not `requestNetwork`: this only reports a cellular
 * network that already exists, and never asks the OS to bring one up. Bringing one
 * up is VerifiedCellular's job, at the moment a request is made.
 *
 * NET_CAPABILITY_INTERNET is the load-bearing line, and `NetworkRequest.Builder`
 * does not add it for you. A transport-only cellular request also matches the
 * special purpose networks Android keeps up for MMS and SUPL when mobile data is
 * switched off, so without it the button stays enabled when nothing can work.
 *
 * ConnectivityManager fires on a binder thread and event sinks must be called on
 * the main thread, hence the Handler.
 */
private class CellularAvailableHandler(
    private val context: Context,
    private val mainHandler: Handler,
) : EventChannel.StreamHandler {
    private var connectivityManager: ConnectivityManager? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                mainHandler.post { events.success(true) }
            }

            override fun onLost(network: Network) {
                mainHandler.post { events.success(false) }
            }
        }
        manager.registerNetworkCallback(request, networkCallback)
        connectivityManager = manager
        callback = networkCallback
    }

    override fun onCancel(arguments: Any?) {
        callback?.let { registered ->
            runCatching { connectivityManager?.unregisterNetworkCallback(registered) }
        }
        callback = null
        connectivityManager = null
    }
}

/**
 * Does WiFi win the default route right now. The request here is deliberately
 * unfiltered: it exists only to get a callback whenever any network changes, and
 * the answer is re-derived from the OS's own `activeNetwork` rather than from
 * whichever network happened to fire.
 */
private class WifiIsDefaultRouteHandler(
    private val context: Context,
    private val mainHandler: Handler,
) : EventChannel.StreamHandler {
    private var connectivityManager: ConnectivityManager? = null
    private var callback: ConnectivityManager.NetworkCallback? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        fun refresh() {
            val capabilities = manager.activeNetwork?.let { manager.getNetworkCapabilities(it) }
            val wifiIsDefault = capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
            mainHandler.post { events.success(wifiIsDefault) }
        }

        val networkCallback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = refresh()
            override fun onLost(network: Network) = refresh()
            override fun onCapabilitiesChanged(
                network: Network,
                capabilities: NetworkCapabilities,
            ) = refresh()
        }
        manager.registerNetworkCallback(NetworkRequest.Builder().build(), networkCallback)
        refresh() // report where things stand now, don't wait for the first change
        connectivityManager = manager
        callback = networkCallback
    }

    override fun onCancel(arguments: Any?) {
        callback?.let { registered ->
            runCatching { connectivityManager?.unregisterNetworkCallback(registered) }
        }
        callback = null
        connectivityManager = null
    }
}
