package com.github.catvod.server

import com.github.catvod.crawler.SpiderDebug
import com.github.catvod.net.OkHttp
import java.io.ByteArrayInputStream
import java.io.FilterInputStream
import java.io.IOException
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import okhttp3.Request
import okhttp3.Response

/**
 * /proxy?go=... 分支, 对照原版 com.mobile.novabox.util.Proxy:
 *  - go=live: m3u8 重写代理 (playlist 内所有分片/key/子列表改写回本机 9978,
 *    ts/media/key 透传, ua/referer/origin/cookie/range 透传)
 *  - go=bom: 去掉 m3u8 的 UTF-8 BOM 后原样返回
 *  - direct(): do=py 直链兜底 (原版 ApiConfig.proxyDirect), jar 静态 Proxy
 *    不可用时对 m3u8 直链走 go=live 重写
 */
object GoProxy {

    private val URI_ATTR = Regex("URI=\"([^\"]+)\"")

    fun proxy(params: Map<String, String>): Array<Any?>? {
        return try {
            when (params["go"]) {
                "live" -> itv(params)
                "bom" -> removeBOMFromM3U8(params)
                else -> null
            }
        } catch (th: Throwable) {
            SpiderDebug.log(th)
            null
        }
    }

    /// 原版 ApiConfig.proxyDirect: do=py 失败时对 m3u8 直链兜底
    fun direct(params: Map<String, String>): Array<Any?>? {
        return try {
            var url = params["url"] ?: return null
            url = URLDecoder.decode(url, "UTF-8")
            if (!url.startsWith("http://") && !url.startsWith("https://")) return null
            if (!url.contains(".m3u8")) return null
            val p = HashMap<String, String>(params)
            p["url"] = url
            p["go"] = "live"
            p["type"] = "m3u8"
            itv(p)
        } catch (th: Throwable) {
            SpiderDebug.log(th)
            null
        }
    }

    fun itv(params: Map<String, String>): Array<Any?>? {
        return try {
            var url = params["url"] ?: return null
            url = URLDecoder.decode(url, "UTF-8")
            val type = params["type"] ?: return null
            if (type == "m3u8") {
                val request = buildRequest(url, params)
                OkHttp.client().newCall(request).execute().use { response ->
                    if (!response.isSuccessful) throw IOException("M3U8 Request failed with code: " + response.code)
                    val finalUrl = response.request.url.toString()
                    val content = processM3u8(response.body?.string() ?: "", finalUrl, params)
                    arrayOf<Any?>(
                        200,
                        "application/vnd.apple.mpegurl",
                        ByteArrayInputStream(content.toByteArray(Charsets.UTF_8))
                    )
                }
            } else if (type == "ts" || type == "media" || type == "key") {
                val request = buildRequest(url, params)
                val response = OkHttp.client().newCall(request).execute()
                if (response.isSuccessful) {
                    arrayOf<Any?>(
                        response.code,
                        getMime(type, url, response),
                        ResponseStream(response),
                        responseHeaders(response)
                    )
                } else {
                    val code = response.code
                    response.close()
                    throw IOException("Media Request failed with code: $code")
                }
            } else {
                throw IllegalArgumentException("Invalid type: $type")
            }
        } catch (e: Exception) {
            SpiderDebug.log(e)
            null
        }
    }

    fun removeBOMFromM3U8(params: Map<String, String>): Array<Any?>? {
        return try {
            var url = params["url"] ?: return null
            url = URLDecoder.decode(url, "UTF-8")
            val request = Request.Builder().url(url).build()
            OkHttp.client().newCall(request).execute().use { response ->
                if (!response.isSuccessful) throw IOException("M3U8 Request failed with code: " + response.code)
                var m3u8Content = response.body?.string() ?: ""
                if (m3u8Content.startsWith("\ufeff")) {
                    m3u8Content = m3u8Content.substring(1)
                }
                arrayOf<Any?>(
                    200,
                    "application/vnd.apple.mpegurl",
                    ByteArrayInputStream(m3u8Content.toByteArray(Charsets.UTF_8))
                )
            }
        } catch (e: Exception) {
            SpiderDebug.log(e)
            null
        }
    }

    private class ResponseStream(private val response: Response) :
        FilterInputStream(response.body!!.byteStream()) {
        override fun close() {
            try {
                super.close()
            } finally {
                response.close()
            }
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

    private fun copyHeader(builder: Request.Builder, params: Map<String, String>?, paramKey: String, headerKey: String) {
        if (params == null) return
        val value = params[paramKey] ?: return
        if (value.isEmpty()) return
        builder.header(headerKey, value)
    }

    private fun processM3u8(m3u8Content: String, m3u8Url: String, params: Map<String, String>): String {
        if (m3u8Content.isEmpty()) return ""
        var content = m3u8Content
        if (content.startsWith("\ufeff")) content = content.substring(1)
        val lines = content.replace("\r\n", "\n").replace('\r', '\n').split("\n")
        val sb = StringBuilder()
        var nextIsVariant = false
        for (line in lines) {
            val item = line.trim()
            if (item.isEmpty()) {
                sb.append(line).append("\n")
            } else if (item.startsWith("#")) {
                sb.append(rewriteUriAttributes(m3u8Url, item, params)).append("\n")
                nextIsVariant = item.startsWith("#EXT-X-STREAM-INF")
            } else {
                val type = if (nextIsVariant || isM3u8Url(item)) "m3u8" else "media"
                sb.append(joinUrl(m3u8Url, item, type, params)).append("\n")
                nextIsVariant = false
            }
        }
        return sb.toString()
    }

    private fun rewriteUriAttributes(base: String, line: String, params: Map<String, String>): String {
        return URI_ATTR.replace(line) { matcher ->
            val uri = matcher.groupValues[1]
            val type = proxyTypeForUriAttr(line, uri)
            val replacement = "URI=\"" + joinUrl(base, uri, type, params) + "\""
            replacement
        }
    }

    private fun proxyTypeForUriAttr(line: String, uri: String): String {
        val upper = line.toUpperCase()
        if (upper.startsWith("#EXT-X-KEY") || upper.startsWith("#EXT-X-SESSION-KEY")) return "key"
        if (isM3u8Url(uri) || upper.startsWith("#EXT-X-I-FRAME-STREAM-INF")) return "m3u8"
        return "media"
    }

    private fun isM3u8Url(url: String?): Boolean {
        if (url == null) return false
        var lower = url.toLowerCase()
        val query = lower.indexOf('?')
        if (query >= 0) lower = lower.substring(0, query)
        return lower.endsWith(".m3u8") || lower.endsWith(".m3u")
    }

    private fun joinUrl(base: String?, url: String?, type: String, params: Map<String, String>): String? {
        var b = base ?: ""
        var u = url ?: ""
        return try {
            u = u.trim()
            if (u.startsWith("data:") || u.startsWith("blob:")) return u
            val baseUri = URI(b.trim())
            val urlUri = URI(u)
            val proxyUrl = LocalServer.getAddress(true) + "proxy?go=live&type=" + type + headerQuery(params) + "&url="
            if (u.startsWith("http://") || u.startsWith("https://")) {
                proxyUrl + URLEncoder.encode(urlUri.toString(), "UTF-8")
            } else if (u.startsWith("://")) {
                proxyUrl + URLEncoder.encode(URI(baseUri.scheme + u).toString(), "UTF-8")
            } else if (u.startsWith("//")) {
                proxyUrl + URLEncoder.encode(URI(baseUri.scheme + ":" + u).toString(), "UTF-8")
            } else {
                proxyUrl + URLEncoder.encode(baseUri.resolve(u).toString(), "UTF-8")
            }
        } catch (e: Exception) {
            SpiderDebug.log(e)
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

    private fun appendQueryHeader(sb: StringBuilder, params: Map<String, String>?, from: String, to: String) {
        if (params == null) return
        if (sb.indexOf("&" + to + "=") >= 0) return
        val value = params[from] ?: return
        if (value.isEmpty()) return
        sb.append("&").append(to).append("=").append(encode(value))
    }

    /// URLEncoder.encode(String, String) 只抛 UnsupportedEncodingException, 这里不可能发生
    private fun encode(value: String): String {
        return try {
            URLEncoder.encode(value, "UTF-8")
        } catch (e: Exception) {
            value
        }
    }

    private fun getMime(type: String, url: String, response: Response): String {
        val contentType = response.header("Content-Type")
        if (!contentType.isNullOrEmpty()) return contentType
        if (type == "key") return "application/octet-stream"
        var lower = url.toLowerCase()
        val query = lower.indexOf('?')
        if (query >= 0) lower = lower.substring(0, query)
        if (lower.endsWith(".m4s") || lower.endsWith(".mp4") || lower.endsWith(".m4v")) return "video/mp4"
        if (lower.endsWith(".aac")) return "audio/aac"
        if (lower.endsWith(".vtt")) return "text/vtt"
        return "video/mp2t"
    }

    private fun responseHeaders(response: Response): Map<String, String> {
        val headers = LinkedHashMap<String, String>()
        copyResponseHeader(response, headers, "Content-Range")
        copyResponseHeader(response, headers, "Accept-Ranges")
        copyResponseHeader(response, headers, "Content-Length")
        copyResponseHeader(response, headers, "Cache-Control")
        return headers
    }

    private fun copyResponseHeader(response: Response, headers: MutableMap<String, String>, key: String) {
        val value = response.header(key) ?: return
        if (value.isNotEmpty()) headers[key] = value
    }
}
