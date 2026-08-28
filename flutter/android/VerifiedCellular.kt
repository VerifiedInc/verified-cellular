package network.verified.cellular

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONException
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.MalformedURLException
import java.net.SocketTimeoutException
import java.net.URL
import kotlin.time.Duration
import kotlin.time.Duration.Companion.seconds

// VerifiedCellular, v2, 2026-08. The whole thing: copy it as one block.
// It stands alone — the types it answers with are declared here too.
//
// A hop is one GET and its reply, on a connection of its own. How many a call
// takes isn't known up front — each redirect adds one — so `chain` keeps making
// hops until a reply isn't a redirect, or until the cap.
//
// Two lines do the actual forcing: `requestNetwork` with TRANSPORT_CELLULAR
// brings the cellular network up, and `network.openConnection` pins every hop to
// it. Binding a socket to a Network is all the forcing takes, so the hops stay
// ordinary HttpURLConnection calls and the platform goes on parsing the
// responses, framing and chunking included.
//
// minSdk 26: that is where `requestNetwork`'s timeout overload lands. Below it
// the timeout has to be raced by hand on a Handler, which this build has no
// reason to carry.

object VerifiedCellular {

    /**
     * The IP this device shows over cellular, not the one the default route
     * shows. Read over cellular, so it holds even while WiFi is winning.
     */
    suspend fun getDeviceIp(context: Context, timeout: Duration = 3.seconds): String {
        val deviceIpEndpoint = "https://core-api.verified.inc/v2/1-click/verifications/device-ip"
        val answer = chain(context, deviceIpEndpoint, timeout)
        if (answer.status !in 200..299) throw answer.unreadable
        return answer.decode { it.stringOrNull("deviceIp") ?: throw JSONException("no deviceIp") }
    }

    /**
     * GETs [url] over cellular and follows wherever it leads. The chain ends
     * back at core-service with the verification record, so a 2xx is the
     * entity; any other status is the API's refusal, which is an answer too —
     * its body is the reason, and it comes back as the [Result]'s failure. A
     * thrown [CellularError] means no answer at all. Every hop is a bare GET
     * carrying only cookies picked up along the way.
     */
    suspend fun followRedirects(
        context: Context,
        url: String,
        timeout: Duration = 10.seconds,
    ): Result<OneClickVerificationEntity> {
        val answer = chain(context, url, timeout)
        return if (answer.status in 200..299) {
            Result.success(answer.decode(OneClickVerificationEntity::from))
        } else {
            Result.failure(
                answer.decode { ApiError.from(it) ?: throw JSONException("not an API error") },
            )
        }
    }

    /**
     * A 1-Click verification, as core-service returns it — the API calls this
     * entity `1ClickVerificationEntity`, which no language can spell.
     * Everything past [uuid] is nullable: one shape covers create, this chain's
     * last hop, and verify — the same record at different points in its life.
     */
    data class OneClickVerificationEntity(
        val uuid: String,
        val channel: String? = null,
        val status: String? = null,
        val phone: String? = null,
        val verified: Boolean? = null,
        val createdAt: Long? = null,
        val expiresAt: Long? = null,
        val verifiedAt: Long? = null,
        val deliveredAt: Long? = null,
        val attemptsRemaining: Int? = null,
    ) {
        /**
         * `verified` is derived from `verifiedAt` server-side, so either one
         * being set is the same answer.
         */
        val isVerified: Boolean get() = verified == true || verifiedAt != null

        companion object {
            fun from(json: JSONObject) = OneClickVerificationEntity(
                uuid = json.getString("uuid"),
                channel = json.stringOrNull("channel"),
                status = json.stringOrNull("status"),
                phone = json.stringOrNull("phone"),
                verified = json.boolOrNull("verified"),
                createdAt = json.longOrNull("createdAt"),
                expiresAt = json.longOrNull("expiresAt"),
                verifiedAt = json.longOrNull("verifiedAt"),
                deliveredAt = json.longOrNull("deliveredAt"),
                attemptsRemaining = json.intOrNull("attemptsRemaining"),
            )
        }
    }

    /**
     * An API refusal. [errorCode] carries the product code — OCV008 is
     * "autofill failed" — and it is read out of the `data` object core-service
     * wraps every error payload in. The other fields are that envelope. Only
     * `message` is required, so [from] answers null rather than let some
     * unrelated JSON object pass for an error.
     */
    class ApiError(
        override val message: String,
        val name: String? = null,
        val code: Int? = null,
        val className: String? = null,
        val errorCode: String? = null,
    ) : Exception(message) {

        val describedMessage: String
            get() {
                val prefix = errorCode ?: name
                return if (prefix.isNullOrEmpty()) message else "$prefix: $message"
            }

        companion object {
            fun from(json: JSONObject): ApiError? {
                val message = json.stringOrNull("message") ?: return null
                return ApiError(
                    message = message,
                    name = json.stringOrNull("name"),
                    code = json.intOrNull("code"),
                    className = json.stringOrNull("className"),
                    errorCode = json.objectOrNull("data")?.stringOrNull("errorCode"),
                )
            }
        }
    }

    private class Answer(
        val status: Int,
        val body: String,
        /** The end of the chain, not what was asked for. */
        val url: String,
    ) {
        val unreadable: CellularError get() = CellularError.UnreadableBody(status, body, url)

        fun <T> decode(parse: (JSONObject) -> T): T = try {
            parse(JSONObject(body))
        } catch (e: JSONException) {
            throw unreadable
        }
    }

    private suspend fun chain(context: Context, url: String, timeout: Duration): Answer {
        val deadline = System.currentTimeMillis() + timeout.inWholeMilliseconds
        val cookies = ChainCookieJar()

        val maxRedirects = 10
        // The claim has to outlast every hop, so the loop runs inside it.
        return requireCellular(context, timeout) { network ->
            var current = url

            for (hop in 0..maxRedirects) {
                val remaining = (deadline - System.currentTimeMillis()).toInt()
                if (remaining <= 0) throw CellularError.Timeout()

                val hopUrl = usableUrl(current)
                val connection = network.openConnection(hopUrl) as HttpURLConnection
                // Auto-follow can't cross schemes and won't refuse cleartext, so
                // the loop above owns the redirects instead.
                connection.instanceFollowRedirects = false
                connection.connectTimeout = remaining
                connection.readTimeout = remaining
                // Some carrier gateways drop requests that don't identify themselves.
                connection.setRequestProperty("User-Agent", "VerifiedCellular/1")
                cookies.applyTo(connection)

                try {
                    val status = connection.responseCode
                    cookies.collectFrom(connection)

                    if (status !in 300..399) {
                        return@requireCellular Answer(status, connection.readBody(), current)
                    }

                    val location = connection.getHeaderField("Location")
                        ?: throw CellularError.UnusableURL(current)
                    // Location is often relative.
                    val next = try {
                        URL(hopUrl, location)
                    } catch (malformed: MalformedURLException) {
                        throw CellularError.UnusableURL(current)
                    }
                    if (next.protocol == "http") throw CellularError.CleartextRedirectBlocked()
                    current = next.toString()
                } catch (timedOut: SocketTimeoutException) {
                    throw CellularError.Timeout()
                } finally {
                    connection.disconnect()
                }
            }
            throw CellularError.TooManyRedirects()
        }
    }

    /** A URL with no host is one no hop can be made to, so it fails like a bad one. */
    private fun usableUrl(url: String): URL {
        val parsed = try {
            URL(url)
        } catch (malformed: MalformedURLException) {
            throw CellularError.UnusableURL(url)
        }
        if (parsed.host.isNullOrEmpty()) throw CellularError.UnusableURL(url)
        return parsed
    }

    private fun HttpURLConnection.readBody(): String {
        val stream = if (responseCode in 200..299) inputStream else errorStream
        return stream?.bufferedReader()?.use { it.readText() }.orEmpty()
    }

    /**
     * How long to wait for a cellular network to come up, whatever the call's
     * own budget is. Requiring cellular means the request waits when there is no
     * cellular rather than failing, so the wait needs its own bound — otherwise a
     * device in airplane mode burns the whole 30 seconds a carrier chain is
     * allowed before reporting the obvious.
     */
    private val connectWithin = 5.seconds

    /**
     * Claims a cellular network and runs [work] on it.
     *
     * The registered callback IS the claim on the cellular network. Release it
     * any earlier and Android is free to tear the network down mid-request,
     * because with WiFi as the default route nothing else needs cellular — so it
     * stays registered until the last body has been read.
     *
     * NET_CAPABILITY_INTERNET is the load-bearing line, and NetworkRequest.Builder
     * does not add it. A transport-only cellular request also matches the special
     * purpose networks Android keeps up for MMS and SUPL when mobile data is
     * switched off; binding to one of those hands back a socket that carries no
     * general traffic, instead of failing fast.
     */
    private suspend fun <T> requireCellular(
        context: Context,
        timeout: Duration,
        work: (Network) -> T,
    ): T {
        val connectivityManager =
            context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        val request = NetworkRequest.Builder()
            .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()

        val cellularNetwork = CompletableDeferred<Network>()
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                cellularNetwork.complete(network)
            }

            // Only ever fires because the timeout below elapsed, which is the
            // one thing "no cellular" looks like from here.
            override fun onUnavailable() {
                cellularNetwork.completeExceptionally(CellularError.NoCellularAvailable())
            }
        }

        connectivityManager.requestNetwork(
            request,
            callback,
            minOf(timeout, connectWithin).inWholeMilliseconds.toInt(),
        )
        try {
            val network = cellularNetwork.await()
            return withContext(Dispatchers.IO) { work(network) }
        } finally {
            // runCatching, because after onUnavailable the system has already
            // released the request and unregistering again throws.
            runCatching { connectivityManager.unregisterNetworkCallback(callback) }
        }
    }
}

/**
 * Cases are `class`, not `object`: a JVM exception captures its stack trace at
 * construction, so a singleton would hand every caller the same stale trace no
 * matter which hop actually failed.
 */
sealed class CellularError : Exception() {
    class NoCellularAvailable : CellularError()
    class Timeout : CellularError()
    class TooManyRedirects : CellularError()
    class CleartextRedirectBlocked : CellularError()

    /** A URL with no host, or a redirect pointing somewhere unparseable. */
    class UnusableURL(val url: String) : CellularError()

    /** The chain answered, but the body was not what was asked for. */
    class UnreadableBody(val statusCode: Int, val body: String, val url: String) : CellularError()
}

/** In-memory cookie jar scoped to a single redirect chain. Dies with the chain. */
private class ChainCookieJar {
    private val cookies = mutableMapOf<String, String>()

    fun applyTo(connection: HttpURLConnection) {
        if (cookies.isEmpty()) return
        connection.setRequestProperty(
            "Cookie",
            cookies.entries.joinToString("; ") { (name, value) -> "$name=$value" },
        )
    }

    fun collectFrom(connection: HttpURLConnection) {
        // headerFields keeps the server's casing and its lookup is case
        // sensitive, so a server sending lowercase set-cookie must not be missed.
        val setCookie = connection.headerFields
            .filterKeys { it?.equals("Set-Cookie", ignoreCase = true) == true }
            .values.flatten()
        for (header in setCookie) {
            // Only the leading pair is the cookie; the rest is attributes.
            val pair = header.substringBefore(';')
            val name = pair.substringBefore('=').trim()
            if (name.isNotEmpty()) {
                cookies[name] = pair.substringAfter('=', missingDelimiterValue = "").trim()
            }
        }
    }
}

// org.json reads an absent key and a JSON null the same way through isNull, and
// its opt* accessors answer with a zero value rather than nothing — so every
// nullable field goes through one of these. Travels with the module, and the
// rest of the app reads its own responses with them too.

internal fun JSONObject.stringOrNull(name: String): String? =
    if (isNull(name)) null else optString(name)

internal fun JSONObject.boolOrNull(name: String): Boolean? =
    if (isNull(name)) null else optBoolean(name)

internal fun JSONObject.intOrNull(name: String): Int? =
    if (isNull(name)) null else optInt(name)

internal fun JSONObject.longOrNull(name: String): Long? =
    if (isNull(name)) null else optLong(name)

internal fun JSONObject.doubleOrNull(name: String): Double? =
    if (isNull(name)) null else optDouble(name)

internal fun JSONObject.objectOrNull(name: String): JSONObject? =
    if (isNull(name)) null else optJSONObject(name)
