package com.github.catvod.crawler

import android.content.Context
import com.github.catvod.net.OkHttp
import okhttp3.OkHttpClient
import org.json.JSONObject

open class Spider {

    @JvmField
    var siteKey: String? = null

    open fun init(context: Context?) {
        mContext = context
    }

    open fun init(context: Context?, extend: String?) {
        init(context)
    }

    open fun initApi(api: SpiderApi) {
    }

    open fun homeContent(filter: Boolean): String = ""

    open fun homeVideoContent(): String = ""

    open fun categoryContent(tid: String?, pg: String?, filter: Boolean, extend: HashMap<String, String>?): String = ""

    open fun detailContent(ids: List<String>?): String = ""

    open fun searchContent(key: String?, quick: Boolean): String = ""

    open fun searchContent(key: String?, quick: Boolean, pg: String?): String = searchContent(key, quick)

    open fun playerContent(flag: String?, id: String?, vipFlags: List<String>?): String = ""

    open fun isVideoFormat(url: String?): Boolean {
        return false
    }

    open fun manualVideoCheck(): Boolean {
        return false
    }

    open fun liveContent(url: String?): String {
        return ""
    }

    open fun cancelByTag() {
    }

    open fun destroy() {
    }

    open fun proxyLocal(params: Map<String, String>): Array<Any?>? {
        return null
    }

    open fun proxy(params: Map<String, String>): Array<Any?>? {
        return proxyLocal(params)
    }

    open fun action(action: String?): String? {
        return null
    }

    companion object {
        @JvmField
        val empty: JSONObject = JSONObject()

        @JvmField
        var mContext: Context? = null

        // jar 子类以静态方式调用 Spider.safeDns()/Spider.client()，必须是静态方法
        @JvmStatic
        fun safeDns(): okhttp3.Dns = OkHttp.dns()

        @JvmStatic
        fun client(): OkHttpClient = OkHttp.client()
    }
}
