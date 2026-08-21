package com.revenuehog.android

import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** A response with its body — only the paywall path reads one. */
internal data class TransportResponse(val status: Int, val body: String)

/** Minimal HTTP seam so tests run without a network. */
internal interface Transport {
    /**
     * POSTs [body] and returns the HTTP status code. Throws [IOException]
     * on transport (network) failure only — HTTP error statuses are
     * returned, not thrown.
     */
    @Throws(IOException::class)
    fun post(url: String, body: String, headers: Map<String, String>): Int

    /**
     * POSTs [body] and returns status plus response body, within
     * [timeoutMs] (the paywall is the money path and resolves fast). The
     * default keeps old transports compiling; it discards the body.
     */
    @Throws(IOException::class)
    fun postForBody(
        url: String,
        body: String,
        headers: Map<String, String>,
        timeoutMs: Int,
    ): TransportResponse = TransportResponse(post(url, body, headers), "")
}

/** Plain HttpURLConnection — ships with the platform, zero dependencies. */
internal class HttpUrlConnectionTransport : Transport {
    override fun post(url: String, body: String, headers: Map<String, String>): Int =
        request(url, body, headers, 15_000, readBody = false).status

    override fun postForBody(
        url: String,
        body: String,
        headers: Map<String, String>,
        timeoutMs: Int,
    ): TransportResponse = request(url, body, headers, timeoutMs, readBody = true)

    private fun request(
        url: String,
        body: String,
        headers: Map<String, String>,
        timeoutMs: Int,
        readBody: Boolean,
    ): TransportResponse {
        val connection = URL(url).openConnection() as HttpURLConnection
        return try {
            connection.requestMethod = "POST"
            connection.connectTimeout = timeoutMs
            connection.readTimeout = timeoutMs
            connection.doOutput = true
            for ((field, value) in headers) connection.setRequestProperty(field, value)
            connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val responseBody = if (readBody) {
                val stream = if (status in 200..299) connection.inputStream else connection.errorStream
                stream?.use { it.readBytes().toString(Charsets.UTF_8) } ?: ""
            } else {
                ""
            }
            TransportResponse(status, responseBody)
        } finally {
            connection.disconnect()
        }
    }
}
