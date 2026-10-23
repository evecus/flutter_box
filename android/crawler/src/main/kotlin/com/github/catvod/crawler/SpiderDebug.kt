package com.github.catvod.crawler

object SpiderDebug {

    @JvmStatic
    fun log(th: Throwable?) {
        try {
            android.util.Log.d("SpiderLog", th?.message ?: "", th)
        } catch (ignored: Throwable) {
        }
    }

    @JvmStatic
    fun log(msg: String?) {
        try {
            android.util.Log.d("SpiderLog", msg ?: "")
        } catch (ignored: Throwable) {
        }
    }

    @JvmStatic
    fun ec(i: Int): String {
        return ""
    }
}
