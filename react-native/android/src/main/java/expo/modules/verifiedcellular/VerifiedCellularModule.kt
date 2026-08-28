package expo.modules.verifiedcellular

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import expo.modules.kotlin.exception.Exceptions
import expo.modules.kotlin.functions.Coroutine
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.kotlin.records.Field
import expo.modules.kotlin.records.Record
import kotlin.time.Duration.Companion.milliseconds

// The Expo bridge, and nothing else. The forcing, the HTTP and the decoding are
// all in VerifiedCellular.kt, which is the Android app's file copied over with
// only its package line changed — this file is the only part of the module that
// knows JavaScript exists.
//
// What it does own is the wire shape, because a thrown Kotlin exception crosses
// the bridge as a code and a sentence and nothing else: a `CellularError`
// carrying a status code or a URL would arrive stripped. So no call here throws
// for a failure it expects. Each one answers with a record naming which of the
// three things happened — the verification, the API's refusal, or no answer at
// all — and the TypeScript wrapper turns that back into a returned value or a
// thrown typed error.
//
// The wording of those errors is deliberately not here. It belongs to the
// TypeScript layer, which is the one copy iOS and Android share; the native apps
// each carry their own.

class VerifiedCellularModule : Module() {
    // Advisory watchers only. The real enforcement is in VerifiedCellular, which
    // pins every hop to cellular no matter what these report.
    private var cellularCallback: ConnectivityManager.NetworkCallback? = null
    private var routeCallback: ConnectivityManager.NetworkCallback? = null

    override fun definition() = ModuleDefinition {
        Name("VerifiedCellular")

        Events("onCellularAvailabilityChange", "onDefaultRouteChange")

        // Scoped to cellular: does a usable cellular network exist at all,
        // whatever the default route happens to be. This is what gates the
        // button on the JavaScript side.
        //
        // registerNetworkCallback, not requestNetwork: this only reports a
        // cellular network that already exists, and never asks the OS to bring
        // one up. Bringing one up is VerifiedCellular's job, at the moment a
        // request is made.
        //
        // NET_CAPABILITY_INTERNET is the load-bearing line. Without it the
        // request also matches the special purpose networks Android keeps up
        // for MMS and SUPL when mobile data is off, and the button would enable
        // when nothing can work.
        OnStartObserving("onCellularAvailabilityChange") {
            val request = NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    sendEvent("onCellularAvailabilityChange", mapOf("available" to true))
                }

                override fun onLost(network: Network) {
                    sendEvent("onCellularAvailabilityChange", mapOf("available" to false))
                }
            }
            connectivityManager().registerNetworkCallback(request, callback)
            cellularCallback = callback
        }

        OnStopObserving("onCellularAvailabilityChange") {
            cellularCallback?.let { runCatching { connectivityManager().unregisterNetworkCallback(it) } }
            cellularCallback = null
        }

        // Unscoped: does WiFi win the default route right now. Display copy
        // only, it gates nothing. The request is deliberately unfiltered, and
        // the answer is re-derived from the OS's own activeNetwork rather than
        // from whichever network happened to fire.
        OnStartObserving("onDefaultRouteChange") {
            val manager = connectivityManager()

            fun refreshRoute() {
                val capabilities = manager.activeNetwork
                    ?.let { manager.getNetworkCapabilities(it) }
                val wifiIsDefault =
                    capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                sendEvent("onDefaultRouteChange", mapOf("wifiIsDefaultRoute" to wifiIsDefault))
            }

            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = refreshRoute()
                override fun onLost(network: Network) = refreshRoute()
                override fun onCapabilitiesChanged(
                    network: Network,
                    capabilities: NetworkCapabilities,
                ) = refreshRoute()
            }
            manager.registerNetworkCallback(NetworkRequest.Builder().build(), callback)
            refreshRoute() // report where things stand now, don't wait for a change
            routeCallback = callback
        }

        OnStopObserving("onDefaultRouteChange") {
            routeCallback?.let { runCatching { connectivityManager().unregisterNetworkCallback(it) } }
            routeCallback = null
        }

        AsyncFunction("getDeviceIpAsync") Coroutine { timeoutMs: Double ->
            try {
                DeviceIpAnswer(deviceIp = VerifiedCellular.getDeviceIp(context(), timeoutMs.milliseconds))
            } catch (error: CellularError) {
                DeviceIpAnswer(cellularError = error.toRecord())
            }
        }

        AsyncFunction("followRedirectsAsync") Coroutine { url: String, timeoutMs: Double ->
            try {
                VerifiedCellular.followRedirects(context(), url, timeoutMs.milliseconds).fold(
                    onSuccess = { ChainAnswer(verification = VerificationRecord.from(it)) },
                    onFailure = { failure ->
                        // followRedirects only ever *returns* an ApiError; a
                        // CellularError is thrown, and caught below.
                        val apiError = failure as? VerifiedCellular.ApiError ?: throw failure
                        ChainAnswer(apiError = ApiErrorRecord.from(apiError))
                    },
                )
            } catch (error: CellularError) {
                ChainAnswer(cellularError = error.toRecord())
            }
        }
    }

    private fun context(): Context = appContext.reactContext ?: throw Exceptions.ReactContextLost()

    private fun connectivityManager(): ConnectivityManager =
        context().getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
}

/**
 * A [CellularError] flattened into fields a record can carry. [code] is the wire
 * name of the case — the Swift bridge and the TypeScript wrapper spell the same
 * six, and that agreement is the whole contract.
 */
class CellularErrorRecord(
    @Field val code: String = "",
    @Field val statusCode: Int? = null,
    @Field val url: String? = null,
    @Field val body: String? = null,
) : Record

/** Either this device's cellular address, or why there isn't one. */
class DeviceIpAnswer(
    @Field val deviceIp: String? = null,
    @Field val cellularError: CellularErrorRecord? = null,
) : Record

/** The three ways a chain ends. Exactly one field is ever set. */
class ChainAnswer(
    @Field val verification: VerificationRecord? = null,
    @Field val apiError: ApiErrorRecord? = null,
    @Field val cellularError: CellularErrorRecord? = null,
) : Record

/**
 * [VerifiedCellular.OneClickVerificationEntity] as a record. `isVerified` is
 * left off on purpose: it is derived, and the TypeScript side derives it the
 * same way rather than trusting a second copy of the rule to have travelled.
 */
class VerificationRecord(
    @Field val uuid: String = "",
    @Field val channel: String? = null,
    @Field val status: String? = null,
    @Field val phone: String? = null,
    @Field val verified: Boolean? = null,
    @Field val createdAt: Long? = null,
    @Field val expiresAt: Long? = null,
    @Field val verifiedAt: Long? = null,
    @Field val deliveredAt: Long? = null,
    @Field val attemptsRemaining: Int? = null,
) : Record {
    companion object {
        fun from(entity: VerifiedCellular.OneClickVerificationEntity) = VerificationRecord(
            uuid = entity.uuid,
            channel = entity.channel,
            status = entity.status,
            phone = entity.phone,
            verified = entity.verified,
            createdAt = entity.createdAt,
            expiresAt = entity.expiresAt,
            verifiedAt = entity.verifiedAt,
            deliveredAt = entity.deliveredAt,
            attemptsRemaining = entity.attemptsRemaining,
        )
    }
}

/**
 * The API's error body. `describedMessage` is left off for the same reason
 * `isVerified` is: TypeScript composes it from these fields.
 */
class ApiErrorRecord(
    @Field val message: String = "",
    @Field val name: String? = null,
    @Field val code: Int? = null,
    @Field val className: String? = null,
    @Field val errorCode: String? = null,
) : Record {
    companion object {
        fun from(apiError: VerifiedCellular.ApiError) = ApiErrorRecord(
            message = apiError.message,
            name = apiError.name,
            code = apiError.code,
            className = apiError.className,
            errorCode = apiError.errorCode,
        )
    }
}

private fun CellularError.toRecord(): CellularErrorRecord = when (this) {
    is CellularError.NoCellularAvailable -> CellularErrorRecord(code = "NO_CELLULAR_AVAILABLE")
    is CellularError.Timeout -> CellularErrorRecord(code = "TIMEOUT")
    is CellularError.TooManyRedirects -> CellularErrorRecord(code = "TOO_MANY_REDIRECTS")
    is CellularError.CleartextRedirectBlocked ->
        CellularErrorRecord(code = "CLEARTEXT_REDIRECT_BLOCKED")

    is CellularError.UnusableURL -> CellularErrorRecord(code = "UNUSABLE_URL", url = url)

    // The body travels because it is the only thing that explains a carrier
    // gateway answering 200 with a login page.
    is CellularError.UnreadableBody -> CellularErrorRecord(
        code = "UNREADABLE_BODY",
        statusCode = statusCode,
        url = url,
        body = body,
    )
}
