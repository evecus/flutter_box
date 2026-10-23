package com.github.catvod

import com.github.catvod.crawler.SpiderDebug
import com.github.catvod.net.OkHttp
import com.github.catvod.server.LocalServer
import com.mobile.js.App
import java.io.ByteArrayInputStream
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

/**
 * 应用侧本地代理 (对照原版 com.mobile.novabox.util.Proxy).
 *
 * LocalServer /proxy?go=... 的落点:
 *  - go=live: 拉取 m3u8 并把分片/密钥 URL 全部改写成本地代理地址 (播放器
 *    后续每个 ts/key 请求都会带回 /proxy?go=live&type=media&ua=...&url=...),
 *    这是"播放地址都是本机 9978"的机制; ts/media/key 走流式转发.
 *  - go=bom: 去掉 m3u8 的 UTF-8 BOM.
 *  - go=SuperParse: 返回 iframe 解析页 (给 WebView 嗅探用).
 */
object Proxy {

    private val URI_ATTR = Regex("URI=\"([^\"]+)\"")

    private var port: Int = LocalServer.port

    @JvmStatic
    fun set(port: Int) {
        this.port = port
    }

    @JvmStatic
    fun getPort(): Int {
        return if (port > 0) port else LocalServer.port
    }

    @JvmStatic
    fun getUrl(local: Boolean): String {
        val ip = if (local) "127.0.0.1" else getIp()
        return "http://" + ip + ":" + getPort() + "/proxy"
    }

    private fun getIp(): String {
        return try {
            App.getIp()
        } catch (th: Throwable) {
            "127.0.0.1"
        }
    }

    fun proxy(params: Map<String, String>): Array<Any?>? {
        return try {
            when (params["go"]) {
                "live" -> itv(params)
                "bom" -> removeBOMFromM3U8(params)
                "SuperParse" -> SuperParse.loadHtml(params["flag"], params["url"])
                else -> null
            }
        } catch (ignored: Throwable) {
            null
        }
    }

    fun itv(params: Map<String, String>): Array<Any?>? {
        return try {
            val result = arrayOfNulls<Any>(4)
            var url = params["url"] ?: return null
            val type = params["type"] ?: return null
            url = URLDecoder.decode(url, "UTF-8")
            val client: OkHttpClient = OkHttp.client()
            if (type == "m3u8") {
                val request = buildRequest(url, params)
                client.newCall(request).execute().use { response ->
                    if (response.isSuccessful) {
                        val respContent = response.body?.string() ?: ""
                        val finalUrl = response.request.url.toString()
                        val m3u8Content = processM3u8Content(respContent, finalUrl, params)
                        result[0] = 200
                        result[1] = "application/vnd.apple.mpegurl"
                        result[2] = ByteArrayInputStream(m3u8Content.toByteArray(Charsets.UTF_8))
                    } else {
                        throw IOException("M3U8 Request failed with code: " + response.code)
                    }
                }
            } else if (type == "ts" || type == "media" || type == "key") {
                val request = buildRequest(url, params)
                val response = client.newCall(request).execute()
                if (response.isSuccessful) {
                    result[0] = response.code
                    result[1] = getMime(type, url, response)
                    result[2] = ResponseInputStream(response)
                    result[3] = responseHeaders(response)
                } else {
                    val code = response.code
                    response.close()
                    throw IOException("Media Request failed with code: $code")
                }
            } else {
                throw IllegalArgumentException("Invalid type: $type")
            }
            result
        } catch (e: Exception) {
            SpiderDebug.log(e)
            null
        }
    }

    fun removeBOMFromM3U8(params: Map<String, String>): Array<Any?>? {
        return try {
            val result = arrayOfNulls<Any>(3)
            var url = params["url"] ?: return null
            url = URLDecoder.decode(url, "UTF-8")
            val client: OkHttpClient = OkHttp.client()
            val redirectUrl = getRedirectedUrl(url)
            val request = Request.Builder().url(redirectUrl).build()
            client.newCall(request).execute().use { response ->
                if (response.isSuccessful) {
                    var m3u8Content = response.body?.string() ?: ""
                    if (m3u8Content.startsWith("\ufeff")) {
                        m3u8Content = m3u8Content.substring(1)
                    }
                    result[0] = 200
                    result[1] = "application/vnd.apple.mpegurl"
                    result[2] = ByteArrayInputStream(m3u8Content.toByteArray())
                } else {
                    throw IOException("Request failed with code: " + response.code)
                }
            }
            result
        } catch (e: Exception) {
            SpiderDebug.log(e)
            null
        }
    }

    private fun buildRequest(url: String, params: Map<String, String>): Request {
        val builder = Request.Builder().url(url)
        copyHeader(builder, params, "ua", "User-Agent")
        copyHeader(builder, params, "user-agent", "User-Agent")
        copyHeader(builder, params, "User-Agent", "User-Agent")
        copyHeader(builder, params, "referer", "Referer")
        copyHeader(builder, params, "Referer", "Referer")
        copyHeader(builder, params, "origin", "Origin")
        copyHeader(builder, params, "Origin", "Origin")
        copyHeader(builder, params, "cookie", "Cookie")
        copyHeader(builder, params, "Cookie", "Cookie")
        copyHeader(builder, params, "range", "Range")
        copyHeader(builder, params, "Range", "Range")
        copyHeader(builder, params, "accept", "Accept")
        copyHeader(builder, params, "Accept", "Accept")
        copyHeader(builder, params, "accept-language", "Accept-Language")
        copyHeader(builder, params, "Accept-Language", "Accept-Language")
        return builder.build()
    }

    private fun copyHeader(builder: Request.Builder, params: Map<String, String>, paramKey: String, headerKey: String) {
        val value = params[paramKey]
        if (value == null || value.isEmpty()) return
        builder.header(headerKey, value)
    }

    private fun processM3u8Content(m3u8Content: String?, m3u8Url: String, params: Map<String, String>): String {
        if (m3u8Content == null) return ""
        var content = m3u8Content
        if (content.startsWith("\ufeff")) content = content.substring(1)
        val lines = content.replace("\r\n", "\n").replace('\r', '\n').split("\n")
        val processed = StringBuilder()
        var nextIsVariant = false
        for (line in lines) {
            val item = line.trim()
            if (item.length == 0) {
                processed.append(line).append("\n")
            } else if (item.startsWith("#")) {
                processed.append(rewriteUriAttributes(m3u8Url, line, params)).append("\n")
                nextIsVariant = item.startsWith("#EXT-X-STREAM-INF")
            } else {
                val type = if (nextIsVariant || isM3u8Url(item)) "m3u8" else "media"
                processed.append(joinUrl(m3u8Url, line, type, params)).append("\n")
                nextIsVariant = false
            }
        }
        return processed.toString().replace("\\n\\n", "\n")
    }

    private fun rewriteUriAttributes(base: String, line: String, params: Map<String, String>): String {
        return URI_ATTR.replace(line) { match ->
            val uri = match.groupValues[1]
            val type = proxyTypeForUriAttr(line, uri)
            val replacement = "URI=\"" + joinUrl(base, uri, type, params) + "\""
            java.util.regex.Matcher.quoteReplacement(replacement)
        }
    }

    private fun proxyTypeForUriAttr(line: String?, uri: String): String {
        val upper = line?.toUpperCase() ?: ""
        if (upper.startsWith("#EXT-X-KEY") || upper.startsWith("#EXT-X-SESSION-KEY")) return "key"
        if (isM3u8Url(uri) || upper.startsWith("#EXT-X-I-FRAME-STREAM-INF")) return "m3u8"
        return "media"
    }

    private fun isM3u8Url(url: String?): Boolean {
        if (url == null) return false
        var lower = url.toLowerCase()
        val query = lower.indexOf("?")
        if (query >= 0) lower = lower.substring(0, query)
        return lower.endsWith(".m3u8") || lower.endsWith(".m3u")
    }

    private fun joinUrl(base: String?, url: String?, type: String, params: Map<String, String>): String? {
        val baseStr = base ?: ""
        val urlStr = url ?: ""
        return try {
            val trimmed = urlStr.trim()
            if (trimmed.startsWith("data:") || trimmed.startsWith("blob:")) return trimmed
            val baseUri = URI(baseStr.trim())
            val urlUri = URI(trimmed)
            val proxyUrl = LocalServer.getAddress(true) + "proxy?go=live&type=" + type + headerQuery(params) + "&url="
            when {
                trimmed.startsWith("http://") || trimmed.startsWith("https://") ->
                    proxyUrl + URLEncoder.encode(urlUri.toString(), "UTF-8")
                trimmed.startsWith("://") ->
                    proxyUrl + URLEncoder.encode(URI(baseUri.scheme + trimmed).toString(), "UTF-8")
                trimmed.startsWith("//") ->
                    proxyUrl + URLEncoder.encode(URI(baseUri.scheme + ":" + trimmed).toString(), "UTF-8")
                else ->
                    proxyUrl + URLEncoder.encode(baseUri.resolve(trimmed).toString(), "UTF-8")
            }
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun headerQuery(params: Map<String, String>): String {
        val sb = StringBuilder()
        appendQueryHeader(sb, params, "User-Agent", "ua")
        appendQueryHeader(sb, params, "user-agent", "ua")
        appendQueryHeader(sb, params, "Referer", "referer")
        appendQueryHeader(sb, params, "referer", "referer")
        appendQueryHeader(sb, params, "Origin", "origin")
        appendQueryHeader(sb, params, "origin", "origin")
        appendQueryHeader(sb, params, "Cookie", "cookie")
        appendQueryHeader(sb, params, "cookie", "cookie")
        return sb.toString()
    }

    private fun appendQueryHeader(sb: StringBuilder, params: Map<String, String>, from: String, to: String) {
        if (sb.indexOf("&" + to + "=") >= 0) return
        val value = params[from]
        if (value == null || value.isEmpty()) return
        sb.append("&").append(to).append("=").append(URLEncoder.encode(value, "UTF-8"))
    }

    private fun getMime(type: String, url: String?, response: Response): String {
        val contentType = response.header("Content-Type")
        if (!contentType.isNullOrEmpty()) return contentType
        if ("key" == type) return "application/octet-stream"
        var lower = url?.toLowerCase() ?: ""
        val query = lower.indexOf("?")
        if (query >= 0) lower = lower.substring(0, query)
        if (lower.endsWith(".m4s") || lower.endsWith(".mp4") || lower.endsWith(".m4v")) return "video/mp4"
        if (lower.endsWith(".aac")) return "audio/aac"
        if (lower.endsWith(".vtt")) return "text/vtt"
        return "video/mp2t"
    }

    private fun responseHeaders(response: Response): LinkedHashMap<String, String> {
        val headers = LinkedHashMap<String, String>()
        copyResponseHeader(response, headers, "Content-Range")
        copyResponseHeader(response, headers, "Accept-Ranges")
        copyResponseHeader(response, headers, "Content-Length")
        copyResponseHeader(response, headers, "Cache-Control")
        return headers
    }

    private fun copyResponseHeader(response: Response, headers: MutableMap<String, String>, key: String) {
        val value = response.header(key) ?: return
        headers[key] = value
    }

    fun getRedirectedUrl(url: String): String {
        val client = OkHttp.noRedirect()
        val request = Request.Builder().url(url).build()
        client.newCall(request).execute().use { response ->
            if (response.isRedirect) {
                return response.header("Location") ?: url
            }
            return url
        }
    }

    fun getM3U8Content(url: String): String {
        val client = OkHttp.client()
        val request = Request.Builder().url(url).build()
        client.newCall(request).execute().use { response ->
            if (response.isSuccessful) {
                return response.body?.string() ?: ""
            }
            throw IOException("Request failed with code: " + response.code)
        }
    }

    private class ResponseInputStream(response: Response) : FilterInputStream(response.body!!.byteStream()) {
        private val response: Response = response

        override fun close() {
            try {
                super.close()
            } finally {
                response.close()
            }
        }
    }
}
