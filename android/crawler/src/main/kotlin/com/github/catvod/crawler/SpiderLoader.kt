package com.github.catvod.crawler

import com.github.catvod.server.GoProxy
import com.mobile.js.Loge
import org.json.JSONObject
import java.util.concurrent.ConcurrentHashMap

object SpiderLoader {

    const val TYPE_JAR = 0
    const val TYPE_JS = 3
    const val TYPE_XPATH = 4

    private val siteTypes = ConcurrentHashMap<String, Int>()
    private val siteInfos = ConcurrentHashMap<String, JSONObject>()
    private val jsLoader = JsLoader()
    private val jarLoader = JarLoader()

    private val lock = Any()

    /// 当前播放页的源 key. 对照原版 ApiConfig.currentPlaySourceKey:
    /// 只在进入播放页时由 UI 显式设置 (原版 PlayFragment/PlayActivity.initData → setCurrentPlaySourceKey),
    /// 退出播放页清空; 不在 invoke 里随手更新, 避免"最近访问的源"漂移把 jar 的
    /// do=ck 探测路由到错误的源 (500 → 端口检测失败 → 播放转圈).
    @Volatile
    private var currentPlaySourceKey = ""

    /// 对照原版 ApiConfig.setCurrentPlaySourceKey
    fun setCurrentPlaySourceKey(key: String?) {
        currentPlaySourceKey = key ?: ""
    }

    /// 最近一次 invoke 的源 (对齐原版 getCurrentProxySource 的"当前源"语义:
    /// jar 源的 do=ck 等探测请求不带 siteKey, 原版回退到当前源, 探测才能命中
    /// spider 实例的 proxy 方法 → 200; 否则探测 500 → jar 端口检测失败 → 播放转圈)
    @Volatile
    private var recentSiteKey = ""

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
            for (site in sites) {
                val key = site.optString("key")
                if (key.isEmpty()) continue
                siteInfos[key] = site
                siteTypes[key] = site.optInt("type", 0)
            }
        }
        warmUp(sites.mapNotNull { it.optString("key").ifEmpty { null } })
        // 对照原版 ApiConfig.parseJson: 配置阶段只登记站点, 爬虫在首次使用时 getCSP 懒创建.
        // 以前这里会把几十个站点逐个 getSpider (联网下载 js/jar + init), 全程在后台跑且
        // loadSites 立即返回, 首页的 home 调用与它赛跑: 站点表还没填好时 home 拿到 SpiderNull
        // → 空串 → 首页空白; 预加载期间 init 失败 (空 ext) 也会白白留下错误日志.
    }

    private val keyLocks = ConcurrentHashMap<String, Any>()

    @Volatile
    private var warmGeneration = 0

    /// 后台预热: 单独一条守护线程按配置顺序逐个创建爬虫 (搜索要并发命中几十个源,
    /// 冷启动时全部现场创建会很慢). 与前台调用共用按 key 的锁, 不会重复创建;
    /// 配置切换时 generation 变化, 旧的预热线程自行退出.
    private fun warmUp(keys: List<String>) {
        val gen = ++warmGeneration
        Thread {
            for (key in keys) {
                if (gen != warmGeneration) return@Thread
                try {
                    getSpider(key)
                } catch (th: Throwable) {
                    Loge.e("echo-warmUp key=$key msg=" + th.message)
                }
            }
        }.also {
            it.isDaemon = true
            it.name = "spider-warmup"
        }.start()
    }


    fun getSpider(siteKey: String): Spider {
        // 同一站点的首次创建串行化: 首页 home / 搜索 / 播放可能并发命中同一个 key,
        // 重复创建会让 jar init 与 js 上下文互相踩.
        synchronized(keyLocks.getOrPut(siteKey) { Any() }) {
            return createSpider(siteKey)
        }
    }

    private fun createSpider(siteKey: String): Spider {
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
                "home" -> spider.homeContent("true" == arg).also {
                    if (it.isNullOrEmpty()) Loge.e("echo-home-empty key=" + siteKey + " spider=" + spider.javaClass.simpleName)
                }
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

    /// 对照原版 ApiConfig.proxyLocal (去掉 py/live 分支, flutter_box 暂无对应 loader):
    ///  1. do=js → jsLoader (js 爬虫自带代理)
    ///  2. type 3 且 api 非 .js (canUseType3): spider.proxy 实例级 → jar 静态 Proxy →
    ///     直链 m3u8 兜底 (GoProxy.direct, 原版 proxyDirect)
    ///  3. 其余 → jarLoader (静态 com.github.catvod.spider.Proxy)
    /// siteKey 缺省 (jar 源 do=ck 探测等) 回退最近 invoke 的源, 对齐原版 getCurrentProxySource
    /// 的"当前源"语义 — 不回退则探测 500 → jar 端口检测失败 → 播放转圈 (瓜子/文采实测).
    fun proxyInvoke(params: MutableMap<String, String>): Array<Any?>? {
        val siteKey = params["siteKey"] ?: ""
        val result = try {
            if (params["do"] == "js") {
                jsLoader.proxyInvoke(params)
            } else {
                val key = if (siteKey.isNotEmpty()) siteKey else currentPlaySourceKey
                // 对齐原版 getCurrentProxySource: 回退后把 siteKey 写回 params,
                // jar 的 BaseSpiderGuard.proxy 靠 params["siteKey"] 定位实例, 缺了照样 null
                if (siteKey.isEmpty() && key.isNotEmpty()) params["siteKey"] = key
                val info = siteInfos[key]
                val isApiJs = info != null && isJsApi(info.optString("api"))
                if (key.isNotEmpty() && siteTypes[key] == TYPE_JS && !isApiJs) {
                    val spider = getSpider(key)
                    val fromSpider = if (spider !is SpiderNull) spider.proxy(params) else null
                    fromSpider ?: jarLoader.proxyInvoke(params) ?: GoProxy.direct(params)
                } else if (isApiJs) {
                    jsLoader.proxyInvoke(params)
                } else {
                    jarLoader.proxyInvoke(params) ?: GoProxy.direct(params)
                }
            }
        } catch (th: Throwable) {
            Loge.e("echo-SpiderLoader-proxyInvoke msg=" + th.message)
            null
        }
        return result
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
