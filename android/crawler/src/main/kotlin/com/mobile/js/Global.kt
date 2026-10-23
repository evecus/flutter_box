package com.mobile.js

import android.net.Uri
import com.whl.quickjs.wrapper.ContextSetter
import com.whl.quickjs.wrapper.Function
import com.whl.quickjs.wrapper.JSArray
import com.whl.quickjs.wrapper.JSFunction
import com.whl.quickjs.wrapper.JSObject
import com.whl.quickjs.wrapper.JSUtils
import com.whl.quickjs.wrapper.QuickJSContext
import com.github.catvod.server.LocalServer
import java.util.Timer
import java.util.TimerTask
import java.util.concurrent.ExecutorService
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Response

class Global(private val executor: ExecutorService) {

    private var runtime: QuickJSContext? = null
    private val timer: Timer = Timer()

    @Function
    fun getProxy(local: Any?): String {
        val l = local is Boolean && local
        return LocalServer.getAddress(l) + "proxy?do=js"
    }

    @Function
    fun js2Proxy(vararg args: Any?): String {
        val dynamic = if (args.isNotEmpty()) args[0] as? Boolean else false
        val siteType = if (args.size > 1) args[1] as? Int else 0
        val siteKey = if (args.size > 2) args[2] as? String else ""
        val url = if (args.size > 3) args[3] as? String else ""
        val headers = if (args.size > 4) args[4] as? JSObject else null
        val local = dynamic == null || !dynamic
        val headerJson = try {
            headers?.toJsonString() ?: ""
        } catch (e: Exception) {
            ""
        }
        return getProxy(local) + "&from=catvod" + "&siteType=" + (siteType ?: 0) + "&siteKey=" + (siteKey ?: "") +
                "&header=" + Uri.encode(headerJson) + "&url=" + Uri.encode(url ?: "")
    }

    @Function
    fun joinUrl(parent: String?, child: String?): String? {
        return HtmlParser.joinUrl(parent, child)
    }

    @Function
    fun pd(html: String?, rule: String?, add_url: String?): String {
        return HtmlParser.parseDomForUrl(html, rule, add_url ?: "")
    }

    @Function
    fun pdfh(html: String?, rule: String?): String {
        return HtmlParser.parseDomForUrl(html, rule, "")
    }

    @Function
    fun pdfa(html: String?, rule: String?): JSArray? {
        val rt = runtime ?: return null
        return JSUtils<String>().toArray(rt, HtmlParser.parseDomForArray(html, rule))
    }

    @Function
    fun pdfla(html: String?, p1: String?, list_text: String?, list_url: String?, add_url: String?): JSArray? {
        val rt = runtime ?: return null
        return JSUtils<String>().toArray(rt, HtmlParser.parseDomForList(html, p1, list_text, list_url, add_url ?: ""))
    }

    @Function
    fun s2t(text: String?): String {
        return try {
            Trans.s2t(false, text)
        } catch (e: Exception) {
            ""
        }
    }

    @Function
    fun t2s(text: String?): String {
        return try {
            Trans.t2s(false, text)
        } catch (e: Exception) {
            ""
        }
    }

    @Function
    fun aesX(mode: String?, encrypt: Boolean?, input: String?, inBase64: Boolean?, key: String?, iv: String?, outBase64: Boolean?): String {
        return Crypto.aes(mode ?: "AES/CBC", encrypt ?: true, input ?: "", inBase64 ?: false, key ?: "0123456789abcdef", iv, outBase64 ?: true)
    }

    @Function
    fun rsaX(mode: String?, pub: Boolean?, encrypt: Boolean?, input: String?, inBase64: Boolean?, key: String?, outBase64: Boolean?): String {
        return Crypto.rsa(pub ?: false, encrypt ?: false, input ?: "", inBase64 ?: false, key ?: "", outBase64 ?: true)
    }

    @Function
    fun rsaEncrypt(vararg args: Any?): String {
        if (args.isEmpty()) return ""
        val data = args[0] as? String ?: return ""
        if (args.size < 2) return ""
        val key = args[1] as? String ?: return ""
        var mLong = 1
        var mType = 1
        var mBlock = true
        var mConfig: String? = null
        if (args.size > 2 && args[2] is JSObject) {
            try {
                val op = (args[2] as JSObject).toJsonObject()
                if (op.has("config")) mConfig = op.getString("config")
                if (op.has("type")) mType = (op.getDouble("type") ?: 1.0).toInt()
                if (op.has("long")) mLong = (op.getDouble("long") ?: 1.0).toInt()
                if (op.has("block")) mBlock = op.getBoolean("block") ?: true
            } catch (ignored: Exception) {
            }
        }
        return try {
            when (mType) {
                1 -> {
                    if (mConfig != null) Rsa.encryptByPublicKey(data, key, mConfig, mLong, mBlock)
                    else Rsa.encryptByPublicKey(data, key, mLong, mBlock)
                }
                2 -> {
                    if (mConfig != null) Rsa.encryptByPrivateKey(data, key, mConfig, mLong, mBlock)
                    else Rsa.encryptByPrivateKey(data, key, mLong, mBlock)
                }
                else -> ""
            }
        } catch (e: Exception) {
            ""
        }
    }

    @Function
    fun rsaDecrypt(vararg args: Any?): String {
        if (args.isEmpty()) return ""
        val data = args[0] as? String ?: return ""
        if (args.size < 2) return ""
        val key = args[1] as? String ?: return ""
        var mLong = 1
        var mType = 1
        var mBlock = true
        var mConfig: String? = null
        if (args.size > 2 && args[2] is JSObject) {
            try {
                val op = (args[2] as JSObject).toJsonObject()
                if (op.has("config")) mConfig = op.getString("config")
                if (op.has("type")) mType = (op.getDouble("type") ?: 1.0).toInt()
                if (op.has("long")) mLong = (op.getDouble("long") ?: 1.0).toInt()
                if (op.has("block")) mBlock = op.getBoolean("block") ?: true
            } catch (ignored: Exception) {
            }
        }
        return try {
            when (mType) {
                1 -> {
                    if (mConfig != null) Rsa.decryptByPrivateKey(data, key, mConfig, mLong, mBlock)
                    else Rsa.decryptByPrivateKey(data, key, mLong, mBlock)
                }
                2 -> {
                    if (mConfig != null) Rsa.decryptByPublicKey(data, key, mConfig, mLong, mBlock)
                    else Rsa.decryptByPublicKey(data, key, mLong, mBlock)
                }
                else -> ""
            }
        } catch (e: Exception) {
            ""
        }
    }

    private fun req(url: String, options: JSObject): JSObject? {
        val rt = runtime ?: return null
        try {
            val request = Req.objectFrom(options.toJsonObject().toString())
            val res = Connect.to(url, request).execute()
            try {
                return Connect.success(rt, request, res)
            } finally {
                res.close()
            }
        } catch (e: Exception) {
            return Connect.error(rt)
        }
    }

    @Function
    fun _http(url: String?, options: JSObject): JSObject? {
        if (url.isNullOrEmpty()) return null
        val complete = options.getJSFunction("complete")
        if (complete == null) return req(url, options)
        val request = Req.objectFrom(options.toJsonObject().toString())
        Connect.to(url, request).enqueue(getCallback(complete, request))
        return null
    }

    @Function
    fun setTimeout(func: JSFunction?, delay: Int?) {
        if (func == null) return
        try {
            func.hold()
            timer.schedule(object : TimerTask() {
                override fun run() {
                    try {
                        if (!executor.isShutdown) executor.submit(Runnable { func.call() })
                    } catch (ignored: Throwable) {
                    }
                }
            }, (delay ?: 0).toLong())
        } catch (ignored: Throwable) {
        }
    }

    private fun getCallback(complete: JSFunction, req: Req): Callback {
        return object : Callback {
            override fun onResponse(call: Call, res: Response) {
                var rt = runtime
                try {
                    if (rt != null) {
                        val context = rt
                        executor.submit(Runnable { complete.call(Connect.success(context, req, res)) })
                    }
                } catch (ignored: Throwable) {
                } finally {
                    res.close()
                }
            }

            override fun onFailure(call: Call, e: java.io.IOException) {
                try {
                    val rt = runtime
                    if (rt != null) executor.submit(Runnable { complete.call(Connect.error(rt)) })
                } catch (ignored: Throwable) {
                }
            }
        }
    }

    @ContextSetter
    fun setJSContext(runtime: QuickJSContext) {
        this.runtime = runtime
    }
}
