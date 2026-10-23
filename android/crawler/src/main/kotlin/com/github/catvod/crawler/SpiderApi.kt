package com.github.catvod.crawler

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.res.Configuration
import android.util.Base64
import android.view.Surface
import android.view.WindowManager
import com.google.gson.JsonArray
import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import com.google.gson.JsonPrimitive
import com.mobile.js.App
import com.github.catvod.net.OkHttp
import com.github.catvod.server.LocalServer
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.Headers.Companion.toHeaders
import okhttp3.RequestBody

class SpiderApi {

    fun getAddress(local: Boolean): String {
        return try {
            LocalServer.getAddress(local)
        } catch (th: Throwable) {
            ""
        }
    }

    fun getPort(): String {
        return try {
            val address = LocalServer.getAddress(true)
            val idx = address.lastIndexOf(":")
            if (idx >= 0) address.substring(idx + 1).replace("/", "") else ""
        } catch (th: Throwable) {
            ""
        }
    }

    fun log(msg: String) {
        try {
            SpiderDebug.log(msg)
        } catch (ignored: Throwable) {
        }
    }

    fun getScreenOrientation(): Int {
        try {
            val context = App.get()
            val orientation = context.resources.configuration.orientation
            val wm = context.getSystemService(android.content.Context.WINDOW_SERVICE) as WindowManager
            val rotation = wm.defaultDisplay?.rotation ?: Surface.ROTATION_0
            if (orientation == Configuration.ORIENTATION_PORTRAIT) {
                return ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            }
            if (orientation == Configuration.ORIENTATION_LANDSCAPE) {
                return if (rotation == Surface.ROTATION_90) ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE else ActivityInfo.SCREEN_ORIENTATION_REVERSE_LANDSCAPE
            }
            return ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED
        } catch (th: Throwable) {
            return ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        }
    }

    fun multiReq(array: JsonArray?): String {
        try {
            if (array == null || array.size() == 0) return ""
            val executor = java.util.concurrent.Executors.newFixedThreadPool(minOf(array.size(), 6))
            val futures = java.util.ArrayList<java.util.concurrent.Future<String>>()
            for (element in array) {
                if (!element.isJsonObject) continue
                val obj = element.asJsonObject
                futures.add(executor.submit<String> { request(obj) })
            }
            val result = JsonArray()
            for (future in futures) result.add(toResult(future.get()))
            executor.shutdown()
            return result.toString()
        } catch (th: Throwable) {
            return ""
        }
    }

    fun webParse(url: String?, flag: String?): String {
        try {
            if (url.isNullOrEmpty()) return ""
            val encoded = Base64.encodeToString(url.toByteArray(Charsets.UTF_8), Base64.DEFAULT or Base64.URL_SAFE or Base64.NO_WRAP)
            return "proxy://go=SuperParse&flag=" + (flag ?: "") + "&url=" + encoded
        } catch (th: Throwable) {
            return ""
        }
    }

    private fun request(obj: JsonObject): String {
        try {
            val url = string(obj, "url")
            if (url.isEmpty()) return ""
            val method = string(obj, "method")
            val headers = headers(obj.get("headers"))
            val builder = okhttp3.Request.Builder().url(url).headers(headers)
            if ("POST".equals(method, ignoreCase = true)) builder.post(body(obj))
            val client = OkHttp.client()
            try {
                client.newCall(builder.build()).execute().use { response ->
                    return response.body?.string() ?: ""
                }
            } catch (th: Throwable) {
                return ""
            }
        } catch (th: Throwable) {
            return ""
        }
    }

    private fun toResult(text: String?): JsonElement {
        if (text == null) return JsonPrimitive("")
        try {
            val trim = text.trim()
            if (trim.startsWith("{") || trim.startsWith("[")) {
                return JsonParser.parseString(trim)
            }
        } catch (ignored: Throwable) {
        }
        return JsonPrimitive(text)
    }

    private fun body(obj: JsonObject): RequestBody {
        val data = obj.get("data")
        if (data == null || data.isJsonNull) return RequestBody.create(null, "")
        val postType = string(obj, "postType")
        if ("form".equals(postType, ignoreCase = true) && data.isJsonObject) {
            val builder = FormBody.Builder()
            for ((key, value) in data.asJsonObject.entrySet()) {
                builder.add(key, value.asString)
            }
            return builder.build()
        }
        return RequestBody.create(null, if (data.isJsonPrimitive) data.asString else data.toString())
    }

    private fun headers(element: JsonElement?): Headers {
        try {
            if (element == null || element.isJsonNull || !element.isJsonObject) return Headers.headersOf()
            val map = HashMap<String, String>()
            for ((key, value) in element.asJsonObject.entrySet()) {
                map[key] = value.asString
            }
            return map.toHeaders()
        } catch (th: Throwable) {
            return Headers.headersOf()
        }
    }

    private fun string(obj: JsonObject, key: String): String {
        val element = obj.get(key)
        return if (element == null || element.isJsonNull) "" else element.asString
    }
}
