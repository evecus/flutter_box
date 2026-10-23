package com.mobile.js

import com.google.gson.Gson
import com.google.gson.JsonElement
import com.google.gson.annotations.SerializedName
import java.util.Arrays
import java.util.Objects

class Req private constructor() {

    @SerializedName("buffer")
    private val buffer: Int? = null

    @SerializedName("redirect")
    private val redirect: Int? = null

    @SerializedName("timeout")
    private val timeout: Int? = null

    @SerializedName("postType")
    private val postType: String? = null

    @SerializedName("method")
    private val method: String? = null

    @SerializedName("body")
    private val body: String? = null

    @SerializedName("data")
    private val data: JsonElement? = null

    @SerializedName("headers")
    private val headers: JsonElement? = null

    fun getBuffer(): Int = buffer ?: 0

    fun getRedirect(): Int = redirect ?: 1

    fun getTimeoutMs(): Int = timeout ?: 10000

    fun getPostType(): String = if (postType.isNullOrEmpty()) "json" else postType

    fun getMethod(): String = if (method.isNullOrEmpty()) "get" else method

    fun getBody(): String? = body

    fun getData(): JsonElement? = data

    private fun getHeaders(): JsonElement? = headers

    fun isRedirect(): Boolean = getRedirect() == 1

    fun getHeader(): Map<String, String> = Json.toMap(getHeaders())

    fun getCharset(): String {
        val header = getHeader()
        val keys = Arrays.asList("Content-Type", "content-type")
        for (key in keys) if (header.containsKey(key)) return getCharset(header[key] ?: "")
        return "UTF-8"
    }

    private fun getCharset(value: String): String {
        for (text in value.split(";".toRegex())) if (text.contains("charset=")) return text.split("=".toRegex())[1]
        return "UTF-8"
    }

    companion object {
        fun objectFrom(json: String?): Req {
            return try {
                Gson().fromJson(json, Req::class.java)
            } catch (e: Exception) {
                Req()
            }
        }
    }
}
