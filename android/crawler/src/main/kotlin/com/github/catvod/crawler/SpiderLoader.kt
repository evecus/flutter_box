package com.github.catvod.crawler

import com.github.catvod.Proxy
import com.mobile.js.Loge
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

object SpiderLoader {

    const val TYPE_JAR = 0
    const val TYPE_JS = 3
    const val TYPE_XPATH = 4

    /// 当前播放的源 key (对照原版 ApiConfig.currentPlaySourceKey).
    /// 播放前由 SpiderEngine.invoke("player") 设置; 爬虫生成的 proxy:// URL
    /// 不一定带 siteKey, 代理分发时用它回填.
    @Volatile
    var currentPlaySourceKey: String = ""

    private val siteTypes = ConcurrentHashMap<String, Int>()
    private val siteInfos = ConcurrentHashMap<String, JSONObject>()
    private val jsLoader = JsLoader()
    private val jarLoader = JarLoader()

    private val lock = Any()

    fun types(): Map<String, Int> {
        return siteTypes
    }

    fun siteInfo(siteKey: String?): JSONObject? {
        if (siteKey == null) return null
        return siteInfos[siteKey]
    }

    fun setConfig(sites: List<JSONObject>) {
        synchronized(lock) {
            siteTypes.clear()
            siteInfos.clear()
            // 只清蜘蛛缓存; classLoader (主 jar / 站点 jar) 必须保留,
            // 否则刚加载的主 jar 被清掉, csp 源全部不可用 (对照原版 ApiConfig 加载配置时不清 loader).
            jsLoader.clearSpiders()
            jarLoader.clearSpiders()
        }
        for (site in sites) {
            val key = site.optString("key")
            if (key.isEmpty()) continue
            val type = site.optInt("type", 0)
            siteInfos[key] = site
            siteTypes[key] = type
            try {
                getSpider(key)
            } catch (th: Throwable) {
                Loge.e("echo-setConfig-load-error key=" + key + " msg=" + th.message)
            }
        }
    }

    fun getSpider(siteKey: String): Spider {
        val info = siteInfos[siteKey] ?: return SpiderNull()
        val api = info.optString("api")
        val ext = info.optString("ext")
        val jar = info.optString("jar")
        // 路由规则对照原版 ApiConfig.getCSP: 只看 api 后缀, 不按 type 卡死.
        // type 3 的站点 api 既可能是 .js (js 爬虫) 也可能是 csp_XXX (主 jar 内的类),
        // 以前把所有 type 3 都丢给 jsLoader 会导致 csp_ 站点全部变成死源.
        return if (isJsApi(api)) {
            jsLoader.getSpider(siteKey, api, ext, jar)
        } else {
            jarLoader.getSpider(siteKey, api.removePrefix("csp_"), ext, jar)
        }
    }

    private fun isJsApi(api: String): Boolean {
        return api.endsWith(".js") || api.contains(".js?")
    }

    fun loadJar(path: String): Boolean {
        return jarLoader.load(path)
    }

    /// 最近一次 jar 加载失败的原因 (成功时为空串), 供 Dart 侧透传给用户.
    fun jarError(): String = jarLoader.lastError()

    fun invoke(siteKey: String, method: String, arg: String?): String {
        return try {
            val spider = getSpider(siteKey)
            when (method) {
                "home" -> spider.homeContent("true" == arg)
                "homeVod" -> spider.homeVideoContent()
                "category" -> {
                    val json = JSONObject(arg ?: "{}")
                    spider.categoryContent(json.optString("tid"), json.optString("pg", "1"), json.optBoolean("filter", false), parseExtend(json.optJSONObject("ext")))
                }
                "detail" -> {
                    val json = JSONObject(arg ?: "{}")
                    val id = json.optString("id")
                    val ids = ArrayList<String>()
                    if (id.isNotEmpty()) ids.add(id)
                    spider.detailContent(ids)
                }
                "search" -> {
                    val json = JSONObject(arg ?: "{}")
                    spider.searchContent(json.optString("wd"), json.optBoolean("quick", false), json.optString("pg", "1"))
                }
                "player", "play" -> {
                    val json = JSONObject(arg ?: "{}")
                    spider.playerContent(json.optString("flag"), json.optString("id"), ArrayList())
                }
                "live" -> spider.liveContent(JSONObject(arg ?: "{}").optString("url"))
                "action" -> spider.action(JSONObject(arg ?: "{}").optString("action")) ?: ""
                else -> ""
            }
        } catch (th: Throwable) {
            Loge.e("echo-SpiderLoader-invoke " + siteKey + " " + method + " msg=" + th.message)
            ""
        }
    }

    private fun parseExtend(obj: JSONObject?): HashMap<String, String> {
        val result = HashMap<String, String>()
        if (obj == null) return result
        try {
            val keys = obj.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                result[key] = obj.optString(key)
            }
        } catch (ignored: Throwable) {
        }
        return result
    }

    fun proxyInvoke(params: Map<String, String>): Array<Any?>? {
        // 路由语义对照原版 ApiConfig.proxyLocal:
        // 1. siteKey 缺省时回填当前播放源 (原版 currentPlaySourceKey, 由 PlayActivity 播放前设置;
        //    爬虫生成的 proxy:// URL 不一定带 siteKey)
        var siteKey = params["siteKey"] ?: ""
        if (siteKey.isEmpty()) {
            siteKey = currentPlaySourceKey
            if (siteKey.isNotEmpty()) (params as? MutableMap<String, String>)?.put("siteKey", siteKey)
        }
        val info = if (siteKey.isNotEmpty()) siteInfos[siteKey] else null
        val action = params["do"]
        val isJs = "js" == action
        val isPy = "py" == action
        val api = info?.optString("api") ?: ""
        val isApiJs = api.contains(".js")
        val isApiPy = api.contains(".py")
        // 原版 canUseType3: type 3 的 csp 源先走爬虫实例自己的 proxy(Map) ——
        // 瓜子等源的真实拉流逻辑在实例 proxy 里 (知道用哪个头/哪个上游),
        // 直接调 jar 静态 Proxy.proxy 会因不认识 do= 动作而返回 null (代理 500, 播放必失败).
        val canUseType3 = siteKey.isNotEmpty() && info != null
            && info.optInt("type", 0) == 3 && !isJs && !isPy && !isApiJs && !isApiPy
        if (canUseType3) {
            try {
                val result = getSpider(siteKey).proxy(params)
                if (result != null) return result
            } catch (th: Throwable) {
                Loge.e("echo-proxy siteKey error key=$siteKey msg=" + th.message)
            }
            val jarResult = jarLoader.proxyInvoke(params)
            if (jarResult != null) return jarResult
            return proxyDirect(params)
        }
        // 非 type3 csp 源: js 源走 jsLoader (原版 isJsApi 分支, js 源没有 jar,
        // jarLoader.proxyInvoke 对它必然返回 null), 其余走 jar 静态 Proxy.
        if (isJs) return jsLoader.proxyInvoke(params)
        if (info != null && isJsApi(info.optString("api"))) return jsLoader.proxyInvoke(params)
        return jarLoader.proxyInvoke(params)
    }

    /// 对照原版 ApiConfig.proxyDirect: 直连 m3u8 走应用侧 itv 代理 (分片改写).
    private fun proxyDirect(params: Map<String, String>): Array<Any?>? {
        return try {
            val raw = params["url"]
            if (raw.isNullOrEmpty()) return null
            val url = java.net.URLDecoder.decode(raw, "UTF-8")
            if (!url.startsWith("http://") && !url.startsWith("https://")) return null
            if (!isVideoFormat(url)) return null
            if (url.contains(".m3u8")) {
                val p = HashMap(params)
                p["url"] = url
                p["go"] = "live"
                p["type"] = "m3u8"
                Proxy.itv(p)
            } else null
        } catch (th: Throwable) {
            Loge.e("echo-proxy direct fallback error: " + th.message)
            null
        }
    }

    /// 对照原版 DefaultConfig.isVideoFormat 的 snifferMatch.
    private val snifferMatch = Regex(
        "http((?!http).){12,}?\\.(m3u8|mp4|flv|avi|mkv|rm|wmv|mpg|m4a)\\?.*|" +
            "http((?!http).){12,}\\.(m3u8|mp4|flv|avi|mkv|rm|wmv|mpg|m4a)|" +
            "http((?!http).)*?video/tos*|" +
            "http((?!http).){20,}?/m3u8\\?pt=m3u8.*|" +
            "http((?!http).)*?default\\.ixigua\\.com/.*|" +
            "http((?!http).)*?dycdn-tos\\.pstatp[^\\?]*|" +
            "http.*?/player/m3u8play\\.php\\?url=.*|" +
            "http.*?/player/.*?[pP]lay\\.php\\?url=.*|" +
            "http.*?/playlist/m3u8/\\?vid=.*|" +
            "http.*?\\.php\\?type=m3u8&.*|" +
            "http.*?/download.aspx\\?.*|" +
            "http.*?/api/up_api.php\\?.*|" +
            "https.*?\\.66yk\\.cn.*|" +
            "http((?!http).)*?netease\\.com/file/.*"
    )

    fun isVideoFormat(url: String): Boolean {
        return try {
            snifferMatch.containsMatchIn(url)
        } catch (th: Throwable) {
            false
        }
    }

    fun cancelAll() {
        jsLoader.stopAll()
    }

    fun unloadAll() {
        synchronized(lock) {
            jsLoader.destroy()
            jarLoader.clear()
            siteTypes.clear()
            siteInfos.clear()
        }
    }
}
