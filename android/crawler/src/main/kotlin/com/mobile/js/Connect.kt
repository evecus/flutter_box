package com.mobile.js

import android.util.Base64
import com.github.catvod.net.Net
import com.whl.quickjs.wrapper.JSArray
import com.whl.quickjs.wrapper.JSObject
import com.whl.quickjs.wrapper.JSUtils
import com.whl.quickjs.wrapper.QuickJSContext
import okhttp3.Call
import okhttp3.FormBody
import okhttp3.Headers
import okhttp3.MediaType
import okhttp3.MultipartBody
import okhttp3.Request
import okhttp3.RequestBody
import okhttp3.Response
import okhttp3.Headers.Companion.toHeaders
import okhttp3.MediaType.Companion.toMediaType
import java.nio.charset.Charset
import java.util.Random

object Connect {

    fun to(url: String, req: Req): Call {
        val client = Net.defaultClient()
        return client.newCall(getRequest(url, req, req.getHeader().toHeaders()))
    }

    fun success(ctx: QuickJSContext, req: Req, res: Response): JSObject {
        try {
            val jsObject = ctx.createJSObject()
            val jsHeader = ctx.createJSObject()
            setHeader(ctx, res, jsHeader)
            jsObject.set("headers", jsHeader)
            val bytes = res.body?.bytes() ?: ByteArray(0)
            if (req.getBuffer() == 0) jsObject.set("content", String(bytes, charset(req.getCharset())))
            if (req.getBuffer() == 1) {
                val array = ctx.createJSArray()
                for (aByte in bytes) array.push(aByte.toInt())
                jsObject.set("content", array)
            }
            if (req.getBuffer() == 2) jsObject.set("content", Base64.encodeToString(bytes, Base64.DEFAULT or Base64.NO_WRAP))
            return jsObject
        } catch (e: Exception) {
            return error(ctx)
        }
    }

    fun error(ctx: QuickJSContext): JSObject {
        val jsObject = ctx.createJSObject()
        val jsHeader = ctx.createJSObject()
        jsObject.set("headers", jsHeader)
        jsObject.set("content", "")
        return jsObject
    }

    private fun charset(name: String): Charset {
        return try {
            Charset.forName(name)
        } catch (e: Exception) {
            Charsets.UTF_8
        }
    }

    private fun getRequest(url: String, req: Req, headers: Headers): Request {
        return if (req.getMethod().equals("post", ignoreCase = true)) {
            Request.Builder().url(url).tag("js_okhttp_tag").headers(headers).post(getPostBody(req, headers.get("Content-Type"))).build()
        } else if (req.getMethod().equals("header", ignoreCase = true)) {
            Request.Builder().url(url).tag("js_okhttp_tag").headers(headers).head().build()
        } else {
            Request.Builder().url(url).tag("js_okhttp_tag").headers(headers).get().build()
        }
    }

    private fun getPostBody(req: Req, contentType: String?): RequestBody {
        val mediaType: MediaType? = if (contentType != null) try { contentType.toMediaType() } catch (e: Exception) { null } else null
        if (req.getData() != null && req.getPostType() == "json") return getJsonBody(req)
        if (req.getData() != null && req.getPostType() == "form") return getFormBody(req)
        if (req.getData() != null && req.getPostType() == "form-data") return getFormDataBody(req)
        if (req.getBody() != null && mediaType != null) return RequestBody.create(mediaType, req.getBody() ?: "")
        return RequestBody.create(null, "")
    }

    private fun getJsonBody(req: Req): RequestBody {
        return RequestBody.create("application/json".toMediaType(), req.getData().toString())
    }

    private fun getFormBody(req: Req): RequestBody {
        val formBody = FormBody.Builder()
        val params = Json.toMap(req.getData())
        for ((key, value) in params) formBody.add(key, value)
        return formBody.build()
    }

    private fun getFormDataBody(req: Req): RequestBody {
        val boundary = "--dio-boundary-" + Random().nextInt(42949) + "" + Random().nextInt(67296)
        val builder = MultipartBody.Builder(boundary).setType(MultipartBody.FORM)
        val params = Json.toMap(req.getData())
        for ((key, value) in params) builder.addFormDataPart(key, value)
        return builder.build()
    }

    private fun setHeader(ctx: QuickJSContext, res: Response, object1: JSObject) {
        for ((key, value) in res.headers.toMultimap()) {
            if (value.size == 1) object1.set(key, value[0])
            if (value.size >= 2) object1.set(key, JSUtils<String>().toArray(ctx, value))
        }
    }

    fun cancelByTag(tag: Any?) {
        try {
            val client = Net.defaultClient()
            for (call in client.dispatcher.queuedCalls()) {
                if (tag == call.request().tag()) call.cancel()
            }
            for (call in client.dispatcher.runningCalls()) {
                if (tag == call.request().tag()) call.cancel()
            }
        } catch (ignored: Exception) {
        }
    }
}
