package com.mobile.js

import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object Loge {

    private const val TAG = "SpiderLog"
    private const val MAX_LOG_BYTES = 512L * 1024L // 512KB 滚动

    private val fmt = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    private val lock = Any()

    /// 同时写 logcat 与文件 (filesDir/engine.log, 超限截断保留尾部),
    /// 供设置页「查看引擎日志」导出, 用户回传诊断 jar/爬虫问题.
    fun i(msg: String?) {
        try {
            android.util.Log.i(TAG, msg ?: "")
            write("I", msg)
        } catch (ignored: Throwable) {
        }
    }

    fun e(msg: String?) {
        try {
            android.util.Log.e(TAG, msg ?: "")
            write("E", msg)
        } catch (ignored: Throwable) {
        }
    }

    private fun write(level: String, msg: String?) {
        synchronized(lock) {
            try {
                // App.get() 是 lateinit, 未初始化时抛异常, 由外层 catch 兜住.
                val dir = App.get().filesDir ?: return
                val file = File(dir, "engine.log")
                if (file.length() > MAX_LOG_BYTES) {
                    // 保留尾部 3/4, 避免无限增长.
                    val keep = file.readBytes().let { it.copyOfRange((it.size * 3 / 4).coerceAtLeast(0), it.size) }
                    file.writeBytes(keep)
                }
                val line = fmt.format(Date()) + " " + level + "/" + TAG + ": " + (msg ?: "") + "\n"
                file.appendText(line)
            } catch (ignored: Throwable) {
            }
        }
    }
}
