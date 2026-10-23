package com.github.catvod.crawler

import com.github.catvod.net.OkHttp
import com.mobile.js.App
import com.mobile.js.JsSpider
import com.mobile.js.JSRuntime
import com.mobile.js.Loge
import com.mobile.js.Md5
import dalvik.system.DexClassLoader
import java.io.File
import java.util.concurrent.ConcurrentHashMap

class JsLoader {

    private val spiders = ConcurrentHashMap<String, Spider>()
    private val classes = ConcurrentHashMap<String, Class<*>>()

    /// 对照原版 JsLoader: js 源自己产的 proxy://do=js 地址不带 siteKey,
    /// 代理回调按"最近访问的 js 源"路由 (原版 spiders.get(recentKey)).
    @Volatile
    private var recentKey = ""

    fun destroy() {
        for (spider in spiders.values) {
            try {
                spider.cancelByTag()
                spider.destroy()
            } catch (ignored: Throwable) {
            }
        }
        spiders.clear()
        classes.clear()
    }

    fun clear() {
        spiders.clear()
        classes.clear()
    }

    /// 切换配置时只清蜘蛛缓存, 保留 js api 的 classLoader (站点自带 jar), 避免重复下载.
    fun clearSpiders() {
        spiders.clear()
    }

    fun stopAll() {
        for (spider in spiders.values) {
            try {
                spider.cancelByTag()
            } catch (ignored: Throwable) {
            }
        }
    }

    @Volatile
    private var lastError = ""

    /// 最近一次 js api jar 加载失败的原因, 成功加载后清空.
    fun lastError(): String = lastError

    /// Android 14+ (targetSdk 34+) 的 ENFORCE_READ_ONLY_JAVA_DCL 强制要求
    /// DexClassLoader 加载的文件必须只读, 否则构造时直接抛异常.
    private fun ensureReadOnly(path: String) {
        try {
            val f = File(path)
            if (f.exists() && f.canWrite() && !f.setReadOnly()) {
                Loge.e("echo-ensureReadOnly-failed $path")
            }
        } catch (th: Throwable) {
            Loge.e("echo-ensureReadOnly-error " + th.message)
        }
    }

    private fun loadClassLoader(jar: String, key: String): Boolean {
        var success = false
        lastError = ""
        try {
            val cacheDir = File(App.get().cacheDir.absolutePath + "/catvod_jsapi")
            if (!cacheDir.exists()) cacheDir.mkdirs()
            // Android 14+ DCL 只读强制: 先置只读再构造 loader.
            ensureReadOnly(jar)
            val classLoader = DexClassLoader(jar, cacheDir.absolutePath, null, App.get().classLoader)
            var count = 0
            var classInit: Class<*>? = null
            do {
                try {
                    classInit = classLoader.loadClass("com.github.catvod.js.Method")
                    if (classInit != null) {
                        Loge.i("echo-jsapi-loaded")
                        success = true
                        break
                    }
                    Thread.sleep(200)
                } catch (th: Throwable) {
                    Loge.e("echo-loadClassLoader " + th.message)
                    lastError = "loadClass 失败: ${th.javaClass.simpleName}: ${th.message}"
                }
                count++
            } while (count < 5)
            if (success && classInit != null) {
                classes[key] = classInit
            } else if (lastError.isEmpty()) {
                lastError = "com.github.catvod.js.Method 加载失败 (重试 5 次)"
            }
        } catch (th: Throwable) {
            Loge.e("echo-loadClassLoader " + th.message)
            lastError = "DexClassLoader 构造失败: ${th.javaClass.simpleName}: ${th.message}"
        }
        return success
    }

    private fun loadJarInternal(jar: String, md5: String, key: String): Class<*>? {
        if (classes.containsKey(key)) {
            Loge.i("echo-loadJarInternal cached")
            return classes[key]
        }
        val cache = File(App.get().filesDir.absolutePath + "/csp/" + key + ".jar")
        if (md5.isNotEmpty()) {
            if (cache.exists() && Md5.getFileMd5(cache).equals(md5, ignoreCase = true)) {
                loadClassLoader(cache.absolutePath, key)
                return classes[key]
            }
        } else {
            if (cache.exists() && !JSRuntime.isWeekAgo(cache)) {
                if (loadClassLoader(cache.absolutePath, key)) {
                    return classes[key]
                }
            }
        }
        if (OkHttp.download(jar, cache)) {
            loadClassLoader(cache.absolutePath, key)
            return classes[key]
        }
        return null
    }

    fun getSpider(key: String, api: String, ext: String?, jar: String): Spider {
        recentKey = key
        if (spiders.containsKey(key)) {
            Loge.i("echo-getSpider cached")
            return spiders[key]!!
        }
        var cls: Class<*>? = null
        if (jar.isNotEmpty()) {
            val urls = jar.split(";md5;".toRegex()).toTypedArray()
            val jarUrl = urls[0]
            val jarKey = Md5.string2MD5(jarUrl) ?: jarUrl
            val jarMd5 = if (urls.size > 1) urls[1].trim() else ""
            cls = loadJarInternal(jarUrl, jarMd5, jarKey)
        }
        try {
            Loge.i("echo-getSpider load $key")
            val spider = JsSpider(key, api, cls)
            spider.siteKey = key
            spider.init(App.get(), ext)
            spiders[key] = spider
            return spider
        } catch (th: Throwable) {
            Loge.e("echo-getSpider-error " + th.message)
        }
        return SpiderNull()
    }

    fun spiderFor(siteKey: String?): Spider? {
        if (siteKey == null) return null
        return spiders[siteKey]
    }

    fun proxyInvoke(params: Map<String, String>): Array<Any?>? {
        return try {
            // siteKey 优先 (Dart 侧 PlayResolver 拼的 do=js 地址带 siteKey),
            // 缺省回退最近访问的 js 源 (对齐原版 recentKey)
            val spider = spiderFor(params["siteKey"]) ?: spiders[recentKey] ?: return null
            spider.proxyLocal(params)
        } catch (th: Throwable) {
            null
        }
    }
}
