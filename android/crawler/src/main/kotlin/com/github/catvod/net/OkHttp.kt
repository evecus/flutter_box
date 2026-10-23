package com.github.catvod.net

import androidx.collection.ArrayMap
import java.util.concurrent.TimeUnit
import okhttp3.Call
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.HttpUrl
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okhttp3.Headers.Companion.toHeaders
import okhttp3.HttpUrl.Companion.toHttpUrl

object OkHttp {

    const val TIMEOUT: Long = 30000
    private const val USER_AGENT =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"
    private const val ACCEPT =
        "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/json;q=0.9"

    @Volatile
    private var dns: OkDns? = null

    @Volatile
    private var client: OkHttpClient? = null

    @JvmStatic
    fun dns(): OkDns {
        if (dns == null) dns = OkDns()
        return dns!!
    }

    @JvmStatic
    fun client(): OkHttpClient {
        client?.let { return it }
        synchronized(this) {
            client?.let { return it }
            val c = OkHttpClient.Builder()
                .dns(dns())
                .addInterceptor(defaultHeaders())
                .connectTimeout(TIMEOUT, TimeUnit.MILLISECONDS)
                .readTimeout(TIMEOUT, TimeUnit.MILLISECONDS)
                .writeTimeout(TIMEOUT, TimeUnit.MILLISECONDS)
                .retryOnConnectionFailure(true)
                .followRedirects(true)
                .followSslRedirects(true)
                .sslSocketFactory(TrustAll.ssl(), TrustAll.trustManager)
                .hostnameVerifier(TrustAll.hostnameVerifier)
                .build()
            client = c
            return c
        }
    }

    @JvmStatic
    fun player(): OkHttpClient = client()

    @JvmStatic
    fun client(timeout: Long): OkHttpClient {
        return client().newBuilder()
            .connectTimeout(timeout, TimeUnit.MILLISECONDS)
            .readTimeout(timeout, TimeUnit.MILLISECONDS)
            .writeTimeout(timeout, TimeUnit.MILLISECONDS)
            .build()
    }

    @JvmStatic
    fun noRedirect(): OkHttpClient = noRedirect(TIMEOUT)

    @JvmStatic
    fun noRedirect(timeout: Long): OkHttpClient {
        return client().newBuilder()
            .addInterceptor(defaultHeaders())
            .connectTimeout(timeout, TimeUnit.MILLISECONDS)
            .readTimeout(timeout, TimeUnit.MILLISECONDS)
            .writeTimeout(timeout, TimeUnit.MILLISECONDS)
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
    }

    @JvmStatic
    fun reset() {
        synchronized(this) {
            client = null
            dns = null
        }
        Net.reset()
    }

    @JvmStatic
    fun resetClient() {
        synchronized(this) {
            client = null
        }
    }

    @JvmStatic
    fun client(redirect: Boolean, timeout: Long): OkHttpClient {
        return if (redirect) client(timeout) else noRedirect(timeout)
    }

    @JvmStatic
    fun string(url: String?): String {
        if (url == null || !url.startsWith("http")) return ""
        try {
            newCall(url).execute().use { res -> return res.body?.string() ?: "" }
        } catch (e: Exception) {
            return ""
        }
    }

    @JvmStatic
    fun string(url: String?, timeout: Long): String {
        if (url == null || !url.startsWith("http")) return ""
        try {
            newCall(client(timeout), url).execute().use { res -> return res.body?.string() ?: "" }
        } catch (e: Exception) {
            return ""
        }
    }

    @JvmStatic
    fun string(url: String?, headers: Map<String, String>?): String {
        if (url == null || !url.startsWith("http")) return ""
        try {
            newCall(url, headers).execute().use { res -> return res.body?.string() ?: "" }
        } catch (e: Exception) {
            return ""
        }
    }

    @JvmStatic
    fun download(url: String?, file: java.io.File?): Boolean {
        if (url == null || file == null || !url.startsWith("http")) return false
        try {
            newCall(url).execute().use { res ->
                if (!res.isSuccessful || res.body == null) return false
                res.body!!.byteStream().use { iss ->
                    file.parentFile?.mkdirs()
                    // 上次加载后文件可能被置为只读 (Android 14+ DCL 要求),
                    // 直接开会写失败, 先删掉再写.
                    if (file.exists()) file.delete()
                    file.outputStream().use { fos -> iss.copyTo(fos) }
                }
                return file.exists() && file.length() > 0
            }
        } catch (e: Exception) {
            return false
        }
    }

    @JvmStatic
    fun newCall(url: String): Call {
        return client().newCall(Request.Builder().url(url).build())
    }

    @JvmStatic
    fun newCall(url: String, tag: String): Call {
        return client().newCall(Request.Builder().url(url).tag(tag).build())
    }

    @JvmStatic
    fun newCall(client: OkHttpClient, url: String): Call {
        return client.newCall(Request.Builder().url(url).build())
    }

    @JvmStatic
    fun newCall(client: OkHttpClient, url: String, tag: String): Call {
        return client.newCall(Request.Builder().url(url).tag(tag).build())
    }

    @JvmStatic
    fun newCall(url: String, headers: Map<String, String>?): Call {
        return client().newCall(Request.Builder().url(url).headers(headers(headers)).build())
    }

    @JvmStatic
    fun newCall(url: String, headers: Map<String, String>?, params: Map<String, String>?): Call {
        return client().newCall(Request.Builder().url(buildUrl(url, params)).headers(headers(headers)).build())
    }

    // 原版签名为 newCall(String, Map, ArrayMap)，jar 按该擦除签名调用，必须保留 ArrayMap 重载
    @JvmStatic
    fun newCall(url: String, headers: Map<String, String>?, params: ArrayMap<String, String>?): Call {
        return client().newCall(Request.Builder().url(buildUrl(url, params)).headers(headers(headers)).build())
    }

    @JvmStatic
    fun newCall(url: String, headers: Map<String, String>?, body: RequestBody): Call {
        return client().newCall(Request.Builder().url(url).headers(headers(headers)).post(body).build())
    }

    @JvmStatic
    fun newCall(url: String, body: RequestBody, tag: String): Call {
        return client().newCall(Request.Builder().url(url).post(body).tag(tag).build())
    }

    @JvmStatic
    fun newCall(client: OkHttpClient, url: String, body: RequestBody): Call {
        return client.newCall(Request.Builder().url(url).post(body).build())
    }

    @JvmStatic
    fun cancel(client: OkHttpClient, tag: String?) {
        if (tag == null) return
        for (call in client.dispatcher.queuedCalls()) if (tag == call.request().tag()) call.cancel()
        for (call in client.dispatcher.runningCalls()) if (tag == call.request().tag()) call.cancel()
    }

    @JvmStatic
    fun cancel(tag: String?) {
        cancel(client(), tag)
    }

    @JvmStatic
    fun cancelAll() {
        cancelAll(client())
    }

    @JvmStatic
    fun cancelAll(client: OkHttpClient) {
        client.dispatcher.cancelAll()
    }

    // 原版签名为 toBody(ArrayMap)，jar 按该擦除签名调用
    @JvmStatic
    fun toBody(params: ArrayMap<String, String>?): FormBody {
        val body = FormBody.Builder()
        if (params != null) for ((key, value) in params) body.add(key, value)
        return body.build()
    }

    private fun headers(headers: Map<String, String>?): Headers {
        return if (headers == null) Headers.headersOf() else headers.toHeaders()
    }

    private fun defaultHeaders(): Interceptor {
        return Interceptor { chain ->
            val request = chain.request()
            val builder = request.newBuilder()
            if (request.header("User-Agent") == null) builder.header("User-Agent", USER_AGENT)
            if (request.header("Accept") == null) builder.header("Accept", ACCEPT)
            chain.proceed(builder.build())
        }
    }

    private fun buildUrl(url: String, params: Map<String, String>?): HttpUrl {
        val builder = url.toHttpUrl().newBuilder()
        if (params != null) for ((key, value) in params) builder.addQueryParameter(key, value)
        return builder.build()
    }
}
