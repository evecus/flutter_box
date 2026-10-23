package com.novabox.engine

import android.os.Handler
import android.os.Looper
import com.github.catvod.crawler.SpiderLoader
import com.github.catvod.server.LocalServer
import com.github.catvod.net.OkHttp
import com.mobile.js.App
import com.mobile.js.Loge
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

object SpiderEngine {

    private const val CHANNEL_ID = "novabox/engine"

    private var channel: MethodChannel? = null
    private val runner: ExecutorService = Executors.newFixedThreadPool(4)
    private val mainHandler = Handler(Looper.getMainLooper())

    fun bind(messenger: BinaryMessenger) {
        channel = MethodChannel(messenger, CHANNEL_ID)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "loadSites" -> {
                    try {
                        val sites = ArrayList<JSONObject>()
                        val array = JSONArray(call.argument<String>("sites") ?: "[]")
                        for (i in 0 until array.length()) {
                            val obj = array.optJSONObject(i) ?: continue
                            if (obj.optString("key").isEmpty()) continue
                            val type = obj.optInt("type", 0)
                            sites.add(obj)
                            Loge.i("echo-site type=" + type + " key=" + obj.optString("key"))
                        }
                        runner.submit(Callable {
                            SpiderLoader.setConfig(sites)
                            null
                        })
                        result.success(true)
                    } catch (th: Throwable) {
                        result.success(false)
                    }
                }
                "loadMainJar" -> {
                    try {
                        val jar = call.argument<String>("jar") ?: ""
                        // 同步加载: Dart 侧 apply() 会先 await 本调用再 loadSites,
                        // 异步提交会让 setConfig 抢在主 jar 加载前跑, csp 源拿不到 classloader.
                        val ok = SpiderLoader.loadJar(jar)
                        // 返回空串表示成功, 非空为失败原因 (透传给用户,
                        // 避免只显示一句没有信息量的 "DexClassLoader 失败").
                        result.success(if (ok) "" else SpiderLoader.jarError())
                    } catch (th: Throwable) {
                        result.success("loadMainJar 异常: ${th.javaClass.simpleName}: ${th.message}")
                    }
                }
                "invoke" -> {
                    val siteKey = call.argument<String>("siteKey") ?: ""
                    val method = call.argument<String>("method") ?: ""
                    val arg = call.argument<String>("arg") ?: ""
                    runner.execute {
                        val data = try {
                            SpiderLoader.invoke(siteKey, method, arg)
                        } catch (th: Throwable) {
                            Loge.e("echo-invoke " + th.message)
                            ""
                        }
                        mainHandler.post {
                            result.success(data)
                        }
                    }
                }
                "proxyUrl" -> {
                    val local = call.argument<Boolean>("local") ?: true
                    result.success(LocalServer.getAddress(local) + "proxy?do=js")
                }
                "getIp" -> {
                    result.success(App.getIp())
                }
                "getText" -> {
                    val url = call.argument<String>("url") ?: ""
                    runner.execute {
                    val text = try {
                        OkHttp.newCall(url, null).execute().use { it.body?.string() ?: "" }
                    } catch (th: Throwable) {
                            Loge.e("echo-getText " + th.message)
                            ""
                        }
                        mainHandler.post {
                            result.success(text)
                        }
                    }
                }
                "decrypt" -> {
                    val text = call.argument<String>("text") ?: ""
                    val key = call.argument<String>("key") ?: ""
                    runner.execute {
                        val decrypted = try {
                            ConfigCrypto.findResult(text, key.ifEmpty { null })
                        } catch (th: Throwable) {
                            Loge.e("echo-decrypt " + th.message)
                            text
                        }
                        mainHandler.post {
                            result.success(decrypted)
                        }
                    }
                }
                "download" -> {
                    val url = call.argument<String>("url") ?: ""
                    val path = call.argument<String>("path") ?: ""
                    runner.execute {
                        val ok = try {
                            OkHttp.download(url, java.io.File(path))
                        } catch (th: Throwable) {
                            Loge.e("echo-download " + th.message)
                            false
                        }
                        mainHandler.post {
                            result.success(ok)
                        }
                    }
                }
                "stopAll" -> {
                    runner.submit(Callable {
                        SpiderLoader.cancelAll()
                        null
                    })
                    result.success(true)
                }
                "unload" -> {
                    runner.submit(Callable {
                        SpiderLoader.unloadAll()
                        null
                    })
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    fun unbind() {
        channel?.setMethodCallHandler(null)
        runner.shutdownNow()
        channel = null
    }
}
