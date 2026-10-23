package com.github.catvod.crawler

import android.util.Log
import com.github.catvod.server.LocalServer
import com.github.catvod.Proxy
import com.mobile.js.App
import com.mobile.js.JSRuntime
import com.mobile.js.Loge
import com.mobile.js.Md5
import com.github.catvod.net.OkHttp
import dalvik.system.DexClassLoader
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.lang.reflect.Field
import java.lang.reflect.Method
import java.lang.reflect.Modifier
import java.util.concurrent.ConcurrentHashMap
import java.util.zip.ZipFile

class JarLoader {

    private val classLoaders = ConcurrentHashMap<String, DexClassLoader>()
    private val proxyMethods = ConcurrentHashMap<String, Method>()
    private val spiders = ConcurrentHashMap<String, Spider>()
    private val siteJarKeys = ConcurrentHashMap<String, String>()
    private val protectedInitJars = ConcurrentHashMap<String, Boolean>()

    @Volatile
    private var recentJarKey = ""

    @Volatile
    private var lastError = ""

    /// 最近一次加载失败的原因 (供 Dart 侧透传给用户), 成功加载后清空.
    fun lastError(): String = lastError

    /// Android 14+ (targetSdk 34+) 的 ENFORCE_READ_ONLY_JAVA_DCL 强制要求
    /// DexClassLoader 加载的文件必须只读, 否则构造时直接抛异常.
    /// 原版 NovaBox targetSdk 33 不受影响; 本应用 targetSdk 35 必须显式置只读.
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

    private val DEFAULT_CONFIG_JSON =
        "{\"version\":\"25.0\",\"update\":\"关闭\",\"danmuColor\":\"默认\",\"aliHD\":\"阿里原画\",\"quarkHD\":\"夸克原画\",\"ucHD\":\"UC原画\",\"panBlock\":\"\",\"proxyMode\":\"Go多线程\",\"pansouUrl\":\"https://so.252035.xyz\",\"panOrder\":\"百度,夸克,UC,天翼,123,阿里,移动\",\"homePage\":\"热门电影,热播剧集,热门动漫,热播综艺\",\"aliThread\":\"64\",\"quarkThread\":\"16\",\"ucThread\":\"自动\"}"

    fun load(cache: String): Boolean {
        recentJarKey = "main"
        return loadClassLoader(cache, recentJarKey)
    }

    fun setRecentJarKey(key: String?) {
        if (!key.isNullOrEmpty()) {
            recentJarKey = key
            injectProxyPort(classLoaders[key])
        }
    }

    fun clear() {
        spiders.clear()
        proxyMethods.clear()
        classLoaders.clear()
        siteJarKeys.clear()
    }

    /**
     * 切换配置时只清蜘蛛缓存, 保留已加载的 classLoader (主 jar / 站点自带 jar).
     * 对照原版: ApiConfig 加载配置时并不 clearLoader (只在构造和显式清理缓存时清),
     * 若在 setConfig 里清掉 classLoaders, 刚 loadMainJar 的主 jar 会被抹掉, 所有 csp 源变死源.
     */
    fun clearSpiders() {
        spiders.clear()
        proxyMethods.clear()
        siteJarKeys.clear()
    }

    private fun loadClassLoader(jar: String, key: String): Boolean {
        if (classLoaders.containsKey(key)) {
            injectProxyPort(classLoaders[key])
            Loge.i("echo-loadClassLoader jar缓存$key")
            ensureDefaultConfig()
            return true
        }
        var success = false
        lastError = ""
        try {
            val cacheDir = File(App.get().cacheDir.absolutePath + "/catvod_csp")
            if (!cacheDir.exists()) cacheDir.mkdirs()
            // Android 14+ DCL 只读强制: 先置只读再构造 loader.
            ensureReadOnly(jar)
            val classLoader = DexClassLoader(jar, cacheDir.absolutePath, null, App.get().classLoader)
            injectProxyPort(classLoader)
            injectProtectedClassLoader(classLoader)
            var count = 0
            do {
                try {
                    val classInit = classLoader.loadClass("com.github.catvod.spider.Init")
                    if (classInit != null) {
                        val initMethod = classInit.getMethod("init", android.content.Context::class.java)
                        val initThread = Thread {
                            try {
                                if (isProtectedInitJar(jar)) {
                                    initProtectedJar(classInit)
                                } else {
                                    initMethod.invoke(null, App.get())
                                    invokeSaveConfig(classInit)
                                }
                            } catch (e: Exception) {
                                Loge.e("echo-initJar " + e.message)
                            } finally {
                                ensureDefaultConfig()
                            }
                        }
                        initThread.start()
                        initThread.join()
                        Loge.i("echo-jar-code-loaded")
                        success = true
                        try {
                            val proxy = classLoader.loadClass("com.github.catvod.spider.Proxy")
                            val proxyMethod = proxy.getMethod("proxy", Map::class.java)
                            proxyMethods[key] = proxyMethod
                        } catch (th: Throwable) {
                            Loge.e("echo-loadProxyMethod " + th.message)
                        }
                        break
                    }
                    Thread.sleep(200)
                } catch (th: Throwable) {
                    Loge.e("echo-loadClassLoader-loop " + th.message)
                    lastError = "loadClass 失败: ${th.javaClass.simpleName}: ${th.message}"
                }
                count++
            } while (count < 2)
            if (success) {
                classLoaders[key] = classLoader
            } else if (lastError.isEmpty()) {
                lastError = "com.github.catvod.spider.Init 加载失败 (重试 2 次)"
            }
        } catch (th: Throwable) {
            Loge.e("echo-loadClassLoader-error key=$key msg=" + th.message)
            lastError = "DexClassLoader 构造失败: ${th.javaClass.simpleName}: ${th.message}"
        }
        return success
    }

    private fun isProtectedInitJar(jar: String): Boolean {
        protectedInitJars[jar]?.let { return it }
        var result = false
        try {
            val file = File(jar)
            if (file.exists()) {
                val data = JSRuntime.readSimple(file)
                if (data != null && data.size > 4 && data[0] == 'd'.code.toByte() && data[1] == 'e'.code.toByte() && data[2] == 'x'.code.toByte()) {
                    result = isProtectedInitDex(data)
                } else if (data != null) {
                    ZipFile(file).use { zip ->
                        val entries = zip.entries()
                        while (entries.hasMoreElements()) {
                            val entry = entries.nextElement()
                            if (!entry.getName().endsWith(".dex")) continue
                            zip.getInputStream(entry).use { iss: InputStream ->
                                if (isProtectedInitDex(JSRuntime.readBytes(iss))) {
                                    result = true
                                }
                            }
                            if (result) break
                        }
                    }
                }
            }
        } catch (ignored: Throwable) {
        }
        protectedInitJars[jar] = result
        return result
    }

    private fun isProtectedInitDex(data: ByteArray): Boolean {
        if (data.isEmpty()) return false
        return try {
            val text = String(data, Charsets.UTF_8)
            text.contains("包名不匹配") && text.contains("killProcess") && !text.contains("com.novabox.flutter.jun")
        } catch (th: Throwable) {
            false
        }
    }

    private fun initProtectedJar(classInit: Class<*>) {
        try {
            val get = classInit.getMethod("get")
            val init = get.invoke(null)
            val context = classInit.getDeclaredField("c")
            context.isAccessible = true
            context.set(init, App.get())
        } catch (ignored: Throwable) {
        }
        invokeSaveConfig(classInit)
    }

    private fun injectProtectedClassLoader(classLoader: DexClassLoader) {
        injectClassLoaderFields(classLoader, "com.github.catvod.spider.Init")
        injectClassLoaderFields(classLoader, "com.github.catvod.spider.DexNative")
        injectClassLoaderFields(classLoader, "com.github.catvod.spider.BaseSpiderGuard")
    }

    private fun injectClassLoaderFields(classLoader: DexClassLoader, className: String) {
        try {
            val cls = classLoader.loadClass(className)
            setClassLoaderFields(cls, null, classLoader)
            val singleton = getSingleton(cls)
            if (singleton != null) {
                setClassLoaderFields(cls, singleton, classLoader)
            }
        } catch (ignored: Throwable) {
        }
    }

    private fun getSingleton(cls: Class<*>): Any? {
        return try {
            val get = cls.getMethod("get")
            get.invoke(null)
        } catch (ignored: Throwable) {
            null
        }
    }

    private fun setClassLoaderFields(cls: Class<*>, instance: Any?, classLoader: DexClassLoader) {
        try {
            for (field in cls.getDeclaredFields()) {
                if (!ClassLoader::class.java.isAssignableFrom(field.type) && field.type != Any::class.java) continue
                val isStatic = Modifier.isStatic(field.modifiers)
                if (instance == null && !isStatic) continue
                if (instance != null && isStatic) continue
                field.isAccessible = true
                val current = field.get(instance)
                if (current == null) {
                    field.set(instance, classLoader)
                }
            }
        } catch (ignored: Throwable) {
        }
    }

    private fun invokeSaveConfig(classInit: Class<*>) {
        try {
            val saveConfig = classInit.getMethod("saveConfig")
            saveConfig.invoke(null)
        } catch (ignored: Throwable) {
        }
    }

    private fun injectProxyPort(classLoader: DexClassLoader?) {
        Proxy.set(getServerPort())
        if (classLoader == null) return
        try {
            val proxy = classLoader.loadClass("com.github.catvod.Proxy")
            val set = proxy.getMethod("set", Int::class.javaPrimitiveType)
            set.invoke(null, getServerPort())
        } catch (ignored: Throwable) {
        }
    }

    private fun getServerPort(): Int {
        return try {
            val address = LocalServer.getAddress(true)
            if (address.startsWith("http://127.0.0.1:")) {
                val baseUrl = if (address.endsWith("/")) address.substring(0, address.length - 1) else address
                Integer.parseInt(baseUrl.substring(baseUrl.lastIndexOf(":") + 1))
            } else {
                LocalServer.port
            }
        } catch (ignored: Throwable) {
            LocalServer.port
        }
    }

    private fun ensureDefaultConfig() {
        try {
            val config = File(App.get().filesDir, "config.json")
            var rewrite = !config.exists() || config.length() == 0L
            if (!rewrite) {
                try {
                    val obj = JSONObject(JSRuntime.readFileToString(config.absolutePath, "UTF-8"))
                    rewrite = !obj.has("homePage")
                } catch (th: Throwable) {
                    rewrite = true
                }
            }
            if (rewrite) {
                JSRuntime.saveCache(config, DEFAULT_CONFIG_JSON)
            }
        } catch (ignored: Throwable) {
        }
    }

    private fun loadJarInternal(jar: String, md5: String, key: String): DexClassLoader? {
        if (classLoaders.containsKey(key)) {
            Loge.i("echo-loadJarInternal jar缓存$key")
            ensureDefaultConfig()
            return classLoaders[key]
        }
        val cache = File(App.get().filesDir.absolutePath + "/csp/" + key + ".jar")
        if (md5.isNotEmpty()) {
            if (cache.exists() && Md5.getFileMd5(cache).equals(md5, ignoreCase = true)) {
                if (loadClassLoader(cache.absolutePath, key)) {
                    return classLoaders[key]
                } else {
                    return null
                }
            }
        } else {
            if (cache.exists() && !JSRuntime.isWeekAgo(cache)) {
                if (loadClassLoader(cache.absolutePath, key)) {
                    return classLoaders[key]
                }
            }
        }
        if (OkHttp.download(jar, cache)) {
            loadClassLoader(cache.absolutePath, key)
            return classLoaders[key]
        }
        return null
    }

    fun getSpider(key: String, cls: String?, ext: String?, jar: String?): Spider {
        val k = key ?: ""
        val c = cls ?: ""
        val e = ext ?: ""
        val j = jar ?: ""
        if (spiders.containsKey(k)) {
            val jarKey = getJarKey(j)
            recentJarKey = jarKey
            siteJarKeys[k] = jarKey
            injectProxyPort(classLoaders[jarKey])
            Loge.i("echo-getSpider spider缓存$k")
            ensureDefaultConfig()
            return spiders[k]!!
        }
        if (c.isEmpty()) {
            Loge.i("echo-getSpider empty class key=$k")
            return SpiderNull()
        }
        val clsKey = c.replace("csp_", "")
        var jarUrl = ""
        var jarMd5 = ""
        val jarKey: String
        if (j.isEmpty()) {
            jarKey = "main"
        } else {
            val urls = j.split(";md5;".toRegex()).toTypedArray()
            jarUrl = urls[0]
            jarKey = Md5.string2MD5(jarUrl) ?: j
            jarMd5 = if (urls.size > 1) urls[1].trim() else ""
        }
        recentJarKey = jarKey
        siteJarKeys[k] = jarKey
        val classLoader = if (jarKey == "main") classLoaders["main"] else loadJarInternal(jarUrl, jarMd5, jarKey)
        if (classLoader == null) {
            Loge.i("echo-getSpider classLoader null key=$k jarKey=$jarKey jarUrl=$jarUrl")
            return SpiderNull()
        }
        try {
            ensureDefaultConfig()
            Loge.i("echo-getSpider loading sp: $k")
            injectProtectedClassLoader(classLoader)
            val spider = classLoader.loadClass("com.github.catvod.spider.$clsKey").newInstance() as? Spider
            if (spider == null) return SpiderNull()
            spider.siteKey = k
            spider.initApi(SpiderApi())
            spider.init(App.get(), e)
            spiders[k] = spider
            return spider
        } catch (th: Throwable) {
            Loge.e("echo-getSpider error key=$k clsKey=$clsKey msg=" + th.message)
        }
        return SpiderNull()
    }

    private fun getJarKey(jar: String): String {
        if (jar.isEmpty()) return "main"
        val urls = jar.split(";md5;".toRegex()).toTypedArray()
        return Md5.string2MD5(urls[0]) ?: jar
    }

    fun jsonExt(key: String?, jxs: LinkedHashMap<String, String>?, url: String): JSONObject? {
        try {
            val classLoader = classLoaders["main"] ?: return null
            val clsKey = "Json$key"
            val hotClass = "com.github.catvod.parser.$clsKey"
            val parserCls = classLoader.loadClass(hotClass)
            val method = parserCls.getMethod("parse", LinkedHashMap::class.java, String::class.java)
            return method.invoke(null, jxs, url) as? JSONObject
        } catch (th: Throwable) {
            Log.e("JarLoader", "echo-jsonExt", th)
        }
        return null
    }

    fun jsonExtMix(flag: String?, key: String?, name: String?, jxs: LinkedHashMap<String, HashMap<String, String>>?, url: String): JSONObject? {
        try {
            val classLoader = classLoaders["main"] ?: return null
            val clsKey = "Mix$key"
            val hotClass = "com.github.catvod.parser.$clsKey"
            val parserCls = classLoader.loadClass(hotClass)
            val method = parserCls.getMethod("parse", LinkedHashMap::class.java, String::class.java, String::class.java, String::class.java)
            return method.invoke(null, jxs, name, flag, url) as? JSONObject
        } catch (th: Throwable) {
            Log.e("JarLoader", "echo-jsonExtMix", th)
        }
        return null
    }

    fun proxyInvoke(params: Map<String, String>): Array<Any?>? {
        val jarKey = getProxyJarKey(params)
        injectProxyPort(classLoaders[jarKey])
        return invokeProxy(proxyMethods[jarKey], params)
    }

    private fun getProxyJarKey(params: Map<String, String>): String {
        val siteKey = params["siteKey"]
        if (siteKey != null && siteJarKeys.containsKey(siteKey)) {
            return siteJarKeys[siteKey]!!
        }
        return recentJarKey
    }

    private fun invokeProxy(proxyFun: Method?, params: Map<String, String>): Array<Any?>? {
        if (proxyFun == null) return null
        return try {
            @Suppress("UNCHECKED_CAST")
            proxyFun.invoke(null, params) as? Array<Any?>
        } catch (th: Throwable) {
            Loge.e("echo-invokeProxy " + th.message)
            null
        }
    }
}
