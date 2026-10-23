package com.mobile.js

import android.util.Base64
import com.google.gson.Gson
import com.google.gson.JsonElement
import com.google.gson.annotations.SerializedName
import java.io.ByteArrayInputStream
import java.util.Arrays
import java.util.Objects

class Res {

    @SerializedName("code")
    private val code: Int? = null

    @SerializedName("buffer")
    private val buffer: Int? = null

    @SerializedName("content")
    private val content: String? = null

    @SerializedName("headers")
    private val headers: JsonElement? = null

    fun getCode(): Int = code ?: 200

    fun getBuffer(): Int = buffer ?: 0

    fun getContent(): String = if (content.isNullOrEmpty()) "" else content

    private fun getHeaders(): JsonElement? = headers

    fun getHeader(): Map<String, String> = Json.toMap(getHeaders())

    fun getContentType(): String {
        val header = getHeader()
        val keys = Arrays.asList("Content-Type", "content-type")
        for (key in keys) if (header.containsKey(key)) return header[key] ?: ""
        return "application/octet-stream"
    }

    fun getStream(): ByteArrayInputStream {
        if (getBuffer() == 2) return ByteArrayInputStream(Base64.decode(getContent(), Base64.DEFAULT))
        return ByteArrayInputStream(getContent().toByteArray())
    }

    companion object {
        fun objectFrom(json: String?): Res {
            return try {
                Gson().fromJson(json, Res::class.java)
            } catch (e: Exception) {
                Res()
            }
        }
    }
}
