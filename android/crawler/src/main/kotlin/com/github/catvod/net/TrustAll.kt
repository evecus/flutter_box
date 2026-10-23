package com.github.catvod.net

import java.security.cert.CertificateException
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager
import okhttp3.OkHttpClient

/**
 * 对齐原版 OkGoHelper.setOkHttpSsl：信任所有证书 + UnsafeHostnameVerifier。
 * 主 jar 内爬虫大量访问自签名/证书链不完整的 https 站点，默认校验会 SSLHandshakeException。
 */
object TrustAll {

    val trustManager: X509TrustManager = object : X509TrustManager {
        override fun checkClientTrusted(chain: Array<java.security.cert.X509Certificate>?, authType: String?) {}
        override fun checkServerTrusted(chain: Array<java.security.cert.X509Certificate>?, authType: String?) {}
        override fun getAcceptedIssuers(): Array<java.security.cert.X509Certificate> = emptyArray()
    }

    val hostnameVerifier: HostnameVerifier = HostnameVerifier { _, _ -> true }

    fun ssl(): SSLSocketFactory {
        val context = SSLContext.getInstance("TLS")
        context.init(null, arrayOf<TrustManager>(trustManager), null)
        return context.socketFactory
    }

    /** 便捷方法：把 trust-all 配置应用到 Builder */
    fun apply(builder: OkHttpClient.Builder): OkHttpClient.Builder {
        return builder.sslSocketFactory(ssl(), trustManager).hostnameVerifier(hostnameVerifier)
    }
}
