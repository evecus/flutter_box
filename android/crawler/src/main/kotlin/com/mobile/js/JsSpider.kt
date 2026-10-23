package com.mobile.js

import android.content.Context
import android.util.Base64
import com.github.catvod.crawler.Spider
import com.whl.quickjs.wrapper.Function
import com.whl.quickjs.wrapper.JSArray
import com.whl.quickjs.wrapper.JSCallFunction
import com.whl.quickjs.wrapper.JSObject
import com.whl.quickjs.wrapper.JSUtils
import com.whl.quickjs.wrapper.QuickJSContext
import com.whl.quickjs.wrapper.UriUtil
import com.whl.quickjs.wrapper.ModuleLoader
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.InputStream
import java.lang.reflect.Method
import java.util.concurrent.Callable
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

class JsSpider(rawKey: String, val api: String, val dex: Class<*>?) : Spider() {

    private val key: String = "J" + Md5.encode(rawKey)
    private val executor: ExecutorService = Executors.newSingleThreadExecutor()
    private var ctx: QuickJSContext? = null
    private var jsObject: JSObject? = null
    private var cat = false
    private var emptyModuleBytecode: ByteArray? = null
    private val destroyed = AtomicBoolean(false)

    init {
        try {
            initializeJS()
        } catch (e: Throwable) {
            Loge.e("echo-JsSpider-init " + e.message)
        }
    }

    override fun cancelByTag() {
        Connect.cancelByTag("js_okhttp_tag")
    }

    private fun <T> submit(callable: Callable<T>): java.util.concurrent.Future<T> {
        return executor.submit(callable)
    }

    private fun call(func: String, vararg args: Any?): Any? {
        if (destroyed.get() || jsObject == null) return null
        val obj = jsObject ?: return null
        return try {
            submit(Callable { Async.run(obj, func, args).get() }).get()
        } catch (e: Throwable) {
            Loge.i("echo-call-error " + e.message)
            null
        }
    }

    private fun cfg(ext: String?): JSObject {
        val context = ctx!!
        val cfgObj = context.createJSObject()
        cfgObj.set("stype", 3)
        cfgObj.set("skey", key)
        if (Json.invalid(ext)) cfgObj.set("ext", ext)
        else cfgObj.set("ext", context.parse(ext) as JSObject)
        return cfgObj
    }

    override fun init(context: Context?, extend: String?) {
        mContext = context
        try {
            if (cat) call("init", submit(Callable { cfg(extend) }).get())
            else call("init", if (Json.valid(extend)) ctx?.parse(extend) else extend)
        } catch (ignored: Exception) {
        }
    }

    override fun homeContent(filter: Boolean): String {
        return try {
            (call("home", filter) as? String) ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    override fun homeVideoContent(): String {
        return try {
            (call("homeVod") as? String) ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    @Suppress("UNCHECKED_CAST")
    override fun categoryContent(tid: String?, pg: String?, filter: Boolean, extend: HashMap<String, String>?): String {
        return try {
            val obj = submit(Callable { JSUtils<String>().toObj(ctx, extend as Map<String, String>?) }).get()
            (call("category", tid, pg, filter, obj) as? String) ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    override fun detailContent(ids: List<String>?): String {
        return try {
            (call("detail", if (ids.isNullOrEmpty()) "" else ids[0]) as? String) ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    override fun searchContent(key: String?, quick: Boolean): String {
        return try {
            (call("search", key, quick) as? String) ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    override fun playerContent(flag: String?, id: String?, vipFlags: List<String>?): String {
        return try {
            val array = submit(Callable { JSUtils<String>().toArray(ctx, vipFlags) }).get()
            (call("play", flag, id, array) as? String) ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    override fun liveContent(url: String?): String {
        return try {
            (call("live", url) as? String) ?: ""
        } catch (e: Exception) {
            ""
        }
    }

    override fun manualVideoCheck(): Boolean {
        return try {
            (call("sniffer") as? Boolean) ?: false
        } catch (e: Exception) {
            false
        }
    }

    override fun isVideoFormat(url: String?): Boolean {
        return try {
            (call("isVideo", url) as? Boolean) ?: false
        } catch (e: Exception) {
            false
        }
    }

    override fun proxyLocal(params: Map<String, String>): Array<Any?>? {
        return try {
            if ("catvod" == params["from"]) proxy2(params)
            else submit(Callable { proxy1(params) }).get()
        } catch (e: Throwable) {
            emptyProxy()
        }
    }

    override fun action(action: String?): String? {
        return try {
            call("action", action) as? String
        } catch (e: Exception) {
            null
        }
    }

    override fun destroy() {
        if (!destroyed.compareAndSet(false, true)) return
        try {
            executor.submit {
                try {
                    jsObject = null
                    ctx?.destroy()
                    ctx = null
                } catch (th: Throwable) {
                    Loge.i("echo-js-destroy-error " + th.message)
                } finally {
                    executor.shutdown()
                }
            }
        } catch (th: Throwable) {
            executor.shutdownNow()
        }
    }

    private fun initializeJS() {
        try {
            submit(Callable {
                try {
                    if (ctx == null) createCtx()
                    if (dex != null) createDex()
                    var content: String? = JSRuntime.loadModule(api)
                    if (isInvalidModuleContent(content)) return@Callable null
                    val context = ctx!!
                    if (content!!.startsWith("//bb")) {
                        cat = true
                        val b = Base64.decode(content.replace("//bb", ""), Base64.DEFAULT)
                        context.execute(byteFF(b), key + ".js")
                        context.evaluateModule(String.format(SPIDER_STRING_CODE, key + ".js") + "globalThis." + key + " = globalThis.__JS_SPIDER__;", "tv_box_root.js")
                    } else {
                        if (content.contains("__JS_SPIDER__")) {
                            content = content.replace("__JS_SPIDER__\\s*=".toRegex(), "export default ")
                        }
                        if (content.contains("__jsEvalReturn") && !content.contains("export default")) {
                            cat = true
                        }
                        context.evaluateModule(content, api)
                        context.evaluateModule(String.format(SPIDER_STRING_CODE, api) + "globalThis." + key + " = globalThis.__JS_SPIDER__;", "tv_box_root.js")
                    }
                    jsObject = context.get(context.getGlobalObject(), key) as? JSObject
                    jsObject?.hold()
                    null
                } catch (th: Throwable) {
                    Loge.e("echo-initializeJS-error " + th.message)
                    null
                }
            }).get()
        } catch (th: Throwable) {
            Loge.e("echo-initializeJS-wait " + th.message)
        }
    }

    fun byteFF(bytes: ByteArray): ByteArray {
        val newBt = ByteArray(bytes.size - 4)
        newBt[0] = 1
        System.arraycopy(bytes, 5, newBt, 1, bytes.size - 5)
        return newBt
    }

    private fun createCtx() {
        val context = QuickJSContext.create()
        ctx = context
        try {
            emptyModuleBytecode = context.compileModule(EMPTY_MODULE_CODE, "empty.js")
        } catch (th: Throwable) {
            emptyModuleBytecode = ByteArray(0)
        }
        try {
            context.setModuleLoader(object : ModuleLoader() {
                override fun isBytecodeMode(): Boolean {
                    return true
                }

                override fun getModuleBytecode(moduleName: String): ByteArray {
                    val cacheName = if (moduleName.contains("cheerio.min.js")) "cheerio.min"
                        else if (moduleName.contains("crypto-js.js")) "crypto-js" else null
                    if (cacheName != null && cacheName.isNotEmpty()) {
                        try {
                            val cached = JSRuntime.getCacheByte(cacheName)
                            if (cached.isNotEmpty()) return cached
                        } catch (ignored: Throwable) {
                        }
                    }
                    val ss = JSRuntime.loadModule(moduleName)
                    if (isInvalidModuleContent(ss)) {
                        return compileEmptyModule(moduleName)
                    }
                    return if (ss!!.startsWith("//DRPY")) {
                        Base64.decode(ss.replace("//DRPY", ""), Base64.URL_SAFE)
                    } else if (ss.startsWith("//bb")) {
                        val b = Base64.decode(ss.replace("//bb", ""), Base64.DEFAULT)
                        byteFF(b)
                    } else {
                        compileModule(moduleName, ss)
                    }
                }

                override fun getModuleStringCode(moduleName: String): String {
                    return JSRuntime.loadModule(moduleName) ?: ""
                }

                override fun moduleNormalizeName(moduleBaseName: String, moduleName: String): String {
                    return UriUtil.resolve(moduleBaseName, moduleName)
                }
            })
        } catch (th: Throwable) {
            Loge.e("echo-setModuleLoader-error " + th.message)
        }
        try {
            context.setConsole(object : QuickJSContext.Console {
                override fun log(info: String) {
                    Loge.i("QuJs$info")
                }
            })
        } catch (th: Throwable) {
            Loge.e("echo-setConsole-error " + th.message)
        }
        val globalObject = context.getGlobalObject()
        globalObject.bind(Global(executor))
        val localObj = context.createJSObject()
        globalObject.set("local", localObj)
        localObj.bind(local())
        val net = JSRuntime.getAsOpen("js/lib/net.js")
        if (net.isNotEmpty()) globalObject.getContext().evaluate(net)
        preloadTemplate()
    }

    private fun compileEmptyModule(moduleName: String?): ByteArray {
        Loge.i("echo-getModuleBytecode empty: $moduleName")
        return emptyModuleBytecode ?: ByteArray(0)
    }

    private fun compileModule(moduleName: String, content: String): ByteArray {
        try {
            val context = ctx!!
            if (moduleName.contains("cheerio.min.js")) {
                val bytecode = context.compileModule(content, "cheerio.min.js")
                JSRuntime.setCacheByte("cheerio.min", bytecode)
                return bytecode
            } else if (moduleName.contains("crypto-js.js")) {
                val bytecode = context.compileModule(content, "crypto-js.js")
                JSRuntime.setCacheByte("crypto-js", bytecode)
                return bytecode
            }
            return context.compileModule(content, moduleName)
        } catch (th: Throwable) {
            Loge.i("echo-compileModule-error " + moduleName + ", msg=" + th.message)
            return compileEmptyModule(moduleName)
        }
    }

    private fun isInvalidModuleContent(content: String?): Boolean {
        if (content == null || content.isEmpty()) return true
        var trim = content.trim()
        if (trim.startsWith("\uFEFF")) trim = trim.substring(1).trim()
        val lower = trim.lowercase()
        return lower.startsWith("<") ||
                lower.startsWith("{\"code\":404") ||
                lower.startsWith("404") ||
                lower.startsWith("not found")
    }

    private fun preloadTemplate() {
        try {
            val context = ctx!!
            val template = "import tpl from '模板.js';\n" +
                    "globalThis.muban = tpl.muban;\n" +
                    "globalThis.getMubans = tpl.getMubans;"
            context.evaluateModule(template, "tv_box_template.js")
        } catch (th: Throwable) {
            Loge.i("echo-preloadTemplate-error " + th.message)
        }
    }

    private fun createDex() {
        try {
            val context = ctx!!
            val obj = context.createJSObject()
            context.getGlobalObject().set("jsapi", obj)
            val dexClass = dex ?: return
            val classes = dexClass.declaredClasses
            if (classes.isEmpty()) invokeSingle(dexClass, obj)
            if (classes.isNotEmpty()) invokeMultiple(dexClass, obj)
        } catch (e: Throwable) {
            Loge.e("echo-createDex-error " + e.message)
        }
    }

    private fun invokeSingle(clz: Class<*>, jsObj: JSObject) {
        invoke(clz, jsObj, clz.getDeclaredConstructor(QuickJSContext::class.java).newInstance(ctx))
    }

    private fun invokeMultiple(clz: Class<*>, jsObj: JSObject) {
        for (subClz in clz.declaredClasses) {
            val outer = clz.getDeclaredConstructor(QuickJSContext::class.java).newInstance(ctx)
            val javaObj = subClz.getDeclaredConstructor(clz).newInstance(outer)
            val subObj = ctx!!.createJSObject()
            invoke(subClz, subObj, javaObj)
            jsObj.set(subClz.getSimpleName(), subObj)
        }
    }

    private fun invoke(clz: Class<*>, jsObj: JSObject, javaObj: Any) {
        for (method in clz.getMethods()) {
            if (!method.isAnnotationPresent(Function::class.java)) continue
            invoke(jsObj, method, javaObj)
        }
    }

    private fun invoke(jsObj: JSObject, method: Method, javaObj: Any) {
        jsObj.set(method.name, object : JSCallFunction {
            override fun call(vararg args: Any?): Any? {
                return try {
                    method.invoke(javaObj, args)
                } catch (e: Throwable) {
                    null
                }
            }
        })
    }

    private fun proxy1(params: Map<String, String>): Array<Any?>? {
        val context = ctx ?: return null
        val spider = jsObject ?: return null
        val object1 = JSUtils<String>().toObj(context, params)
        val function = spider.getJSFunction("proxy") ?: return null
        val array = (function.call(object1) as? JSArray)?.toJsonArray() ?: return null
        val headerAvailable = array.length() > 3 && array.opt(3) != null
        val result = arrayOfNulls<Any>(4)
        result[0] = array.opt(0)
        result[1] = array.opt(1)
        result[2] = getStream(array.opt(2))
        if (headerAvailable) result[3] = getHeader(array.opt(3))
        if (array.length() > 4) {
            try {
                if (array.optInt(4) == 1) {
                    var content = array.optString(2)
                    if (content.contains("base64,")) content = content.substring(content.indexOf("base64,") + 7)
                    result[2] = ByteArrayInputStream(Base64.decode(content, Base64.DEFAULT))
                }
            } catch (ignored: Exception) {
            }
        }
        return result
    }

    private fun getStream(source: Any?): Any? {
        if (source is InputStream) return source
        if (source is ByteArray) return ByteArrayInputStream(source)
        if (source is String) return ByteArrayInputStream(source.toByteArray(Charsets.UTF_8))
        return source
    }

    private fun getHeader(headerRaw: Any?): Map<String, String>? {
        val headers = HashMap<String, String>()
        if (headerRaw is JSONObject) {
            val json = headerRaw
            val keys = json.keys()
            while (keys.hasNext()) {
                val k = keys.next()
                headers[k] = json.optString(k)
            }
        } else if (headerRaw is String) {
            try {
                val json = JSONObject(headerRaw)
                val keys = json.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    headers[k] = json.optString(k)
                }
            } catch (ignored: JSONException) {
            }
        } else if (headerRaw is Map<*, *>) {
            for ((k, v) in headerRaw) {
                headers[k.toString()] = v.toString()
            }
        }
        return headers
    }

    private fun proxy2(params: Map<String, String>): Array<Any?>? {
        val context = ctx ?: return null
        val url = params["url"] ?: return null
        val header = params["header"] ?: ""
        val array = submit(Callable { JSUtils<String>().toArray(context, url.split("/".toRegex())) }).get()
        val object1 = submit(Callable { context.parse(header) }).get()
        val json = (call("proxy", array, object1) as? String) ?: return null
        val res = Res.objectFrom(json)
        var contentType = res.getContentType()
        if (contentType.isEmpty()) contentType = "application/octet-stream"
        val result = arrayOfNulls<Any>(3)
        result[0] = 200
        result[1] = contentType
        if (res.getBuffer() == 2) {
            result[2] = ByteArrayInputStream(Base64.decode(res.getContent(), Base64.DEFAULT))
        } else {
            result[2] = ByteArrayInputStream(res.getContent().toByteArray())
        }
        return result
    }

    private fun emptyProxy(): Array<Any?> {
        return arrayOfNulls(0)
    }

    companion object {
        private const val EMPTY_MODULE_CODE =
            "const empty = null;\n" +
            "export default empty;\n" +
            "export const JSEncrypt = empty;\n" +
            "export const NodeRSA = empty;\n" +
            "export const pako = empty;\n" +
            "export const JSON5 = empty;\n" +
            "export const mb = empty;\n" +
            "export const parse = empty;\n" +
            "export const stringify = empty;\n" +
            "export const inflate = empty;\n" +
            "export const deflate = empty;\n" +
            "export const gzip = empty;\n" +
            "export const ungzip = empty;\n" +
            "export const encrypt = empty;\n" +
            "export const decrypt = empty;"

        private const val SPIDER_STRING_CODE =
            "import * as spider from '%s'\n\n" +
            "if (!globalThis.__JS_SPIDER__) {\n" +
            "    if (spider.__jsEvalReturn) {\n" +
            "        globalThis.req = http\n" +
            "        globalThis.__JS_SPIDER__ = spider.__jsEvalReturn()\n" +
            "        globalThis.__JS_SPIDER__.is_cat = true\n" +
            "    } else if (spider.default) {\n" +
            "        globalThis.__JS_SPIDER__ = typeof spider.default === 'function' ? spider.default() : spider.default\n" +
            "    }\n" +
            "}\n"
    }
}
