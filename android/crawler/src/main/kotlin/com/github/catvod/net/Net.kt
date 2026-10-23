package com.github.catvod.net

import java.util.concurrent.TimeUnit
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.OkHttpClient
import okhttp3.dnsoverhttps.DnsOverHttps
import okhttp3.HttpUrl.Companion.toHttpUrl

object Net {

    const val DEFAULT_MILLISECONDS: Long = 10000

    @Volatile
    private var defaultClient: OkHttpClient? = null

    @Volatile
    private var noRedirectClient: OkHttpClient? = null

    @Volatile
    var dnsOverHttps: DnsOverHttps? = null
        private set

    @Volatile
    private var dohUrl: String = ""

    fun setDoh(url: String) {
        synchronized(this) {
            if (url == dohUrl) return
            dohUrl = url
            dnsOverHttps = null
            defaultClient = null
            noRedirectClient = null
        }
        if (url.isNotEmpty()) {
            try {
                dnsOverHttps = buildDoh(url)
            } catch (ignored: Throwable) {
                dnsOverHttps = null
            }
        }
    }

    private fun buildDoh(url: String): DnsOverHttps? {
        if (url.isEmpty()) return null
        val httpUrl = url.toHttpUrl()
        val bootstrapClient = OkHttpClient.Builder()
            .connectTimeout(DEFAULT_MILLISECONDS, TimeUnit.MILLISECONDS)
            .build()
        val builder = DnsOverHttps.Builder().client(bootstrapClient).url(httpUrl)
        try {
            val host = java.net.InetAddress.getByName(httpUrl.host)
            builder.bootstrapDnsHosts(host)
        } catch (ignored: Throwable) {
        }
        return builder.build()
    }

    fun defaultClient(): OkHttpClient {
        defaultClient?.let { return it }
        synchronized(this) {
            defaultClient?.let { return it }
            val c = OkHttpClient.Builder()
                .connectTimeout(DEFAULT_MILLISECONDS, TimeUnit.MILLISECONDS)
                .readTimeout(DEFAULT_MILLISECONDS, TimeUnit.MILLISECONDS)
                .writeTimeout(DEFAULT_MILLISECONDS, TimeUnit.MILLISECONDS)
                .retryOnConnectionFailure(true)
                .followRedirects(true)
                .followSslRedirects(true)
                .sslSocketFactory(TrustAll.ssl(), TrustAll.trustManager)
                .hostnameVerifier(TrustAll.hostnameVerifier)
                .build()
            defaultClient = c
            return c
        }
    }

    fun getNoRedirectClient(): OkHttpClient {
        noRedirectClient?.let { return it }
        synchronized(this) {
            noRedirectClient?.let { return it }
            val c = defaultClient().newBuilder()
                .followRedirects(false)
                .followSslRedirects(false)
                .build()
            noRedirectClient = c
            return c
        }
    }

    fun reset() {
        synchronized(this) {
            defaultClient = null
            noRedirectClient = null
        }
    }
}
