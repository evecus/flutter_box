package com.github.catvod.server

import com.github.catvod.crawler.SpiderLoader
import com.mobile.js.App
import fi.iki.elonen.NanoHTTPD
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.util.HashMap

object LocalServer {

    const val port: Int = 9978

    private var server: ControlServer? = null

    @Volatile
    private var started = false

    fun start() {
        if (started) return
        try {
            server = ControlServer(port)
            server!!.start(5000, false)
            started = true
            loge("echo-server-started port=$port")
        } catch (th: Throwable) {
            started = false
            // 绑定失败必须留痕: 播放链路全靠 9978, 静默吞掉会让播放一直转圈无迹可循
            loge("echo-server-start-failed port=$port msg=" + th.message)
        }
    }

    /// 对齐原版语义: 播放/代理请求到达时确保服务在位.
    /// 进程被杀重启或首次绑定偶发失败时, 这里是自愈点.
    fun ensureStarted() {
        if (!started) start()
    }

    fun stop() {
        try {
            server?.stop()
        } catch (ignored: Exception) {
        }
        started = false
    }

    private fun loge(msg: String) {
        try {
            android.util.Log.d("LocalServer", msg)
        } catch (ignored: Throwable) {
        }
    }

    fun isStarted(): Boolean {
        return started
    }

    fun getAddress(local: Boolean): String {
        val ip = if (local) "127.0.0.1" else App.getIp()
        return "http://" + ip + ":" + port + "/"
    }
}

class ControlServer : NanoHTTPD {

    constructor(port: Int) : super(port)

    constructor(hostname: String?, port: Int) : super(hostname, port)

    override fun serve(session: IHTTPSession): Response {
        val uri = session.uri
        return try {
            when {
                uri == "/proxy" -> serveProxy(session)
                uri.startsWith("/file/") -> serveFile(uri.substring(6))
                else -> newFixedLengthResponse(Response.Status.NOT_FOUND, "text/plain", "Not Found")
            }
        } catch (th: Throwable) {
            newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", th.message ?: "error")
        }
    }

    private fun serveProxy(session: IHTTPSession): Response {
        LocalServer.ensureStarted()
        // 对照原版 RemoteServer: params = parms + headers.
        // jar 代理从 params 读 range/ua/referer/host, 播放器发给本机的这些头必须透传下去.
        val params: MutableMap<String, String> = HashMap<String, String>()
        params.putAll(session.parms)
        params.putAll(session.headers)
        loge("echo-proxy uri=" + session.uri + " do=" + params["do"] + " go=" + params["go"] + " siteKey=" + params["siteKey"])
        var rs: Array<Any?>? = null
        try {
            rs = if (params.containsKey("do")) {
                SpiderLoader.proxyInvoke(params)
            } else if (params.containsKey("go")) {
                GoProxy.proxy(params)
            } else {
                null
            }
        } catch (th: Throwable) {
            loge("echo-proxy-dispatch " + th.message)
        }
        return buildProxyResponse(rs)
    }

    private fun buildProxyResponse(rs: Array<Any?>?): Response {
        try {
            if (rs == null || rs.size < 3) {
                return newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "500")
            }
            val mime = rs[1] as? String ?: "application/octet-stream"
            val code = (rs[0] as? Number)?.toInt() ?: 200
            val status = Response.Status.lookup(code) ?: Response.Status.OK
            val stream: InputStream? = when (val data = rs[2]) {
                is InputStream -> data
                is ByteArray -> ByteArrayInputStream(data)
                is String -> ByteArrayInputStream(data.toByteArray(Charsets.UTF_8))
                else -> ByteArrayInputStream(data.toString().toByteArray(Charsets.UTF_8))
            }
            val response = newChunkedResponse(status, mime, stream)
            if (rs.size >= 4 && rs[3] is Map<*, *>) {
                val headers = rs[3] as Map<*, *>
                for (key in headers.keys) {
                    if (key == null) continue
                    val value = headers[key] ?: continue
                    response.addHeader(key.toString(), value.toString())
                }
            }
            return response
        } catch (th: Throwable) {
            loge("echo-proxy " + th.message)
            return newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "500")
        }
    }

    private fun serveFile(path: String): Response {
        try {
            val root = android.os.Environment.getExternalStorageDirectory().absolutePath
            val file = File(root, path)
            if (file.exists()) {
                if (file.isFile) {
                    return newChunkedResponse(Response.Status.OK, "application/octet-stream", FileInputStream(file))
                } else {
                    return newFixedLengthResponse(Response.Status.OK, "text/plain", fileList(root, path))
                }
            }
            return newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", "File $file not found!")
        } catch (th: Throwable) {
            return newFixedLengthResponse(Response.Status.INTERNAL_ERROR, "text/plain", th.message ?: "error")
        }
    }

    private fun fileList(root: String, path: String): String {
        val dir = File(File(root, path).absolutePath)
        val sb = StringBuilder()
        val files = dir.listFiles()
        if (files != null) {
            for (file in files) {
                if (file.isFile) {
                    sb.append("file://").append(file.absolutePath.replace(root, "")).append("\n")
                }
            }
        }
        return sb.toString()
    }

    companion object {
        private fun loge(msg: String?) {
            try {
                android.util.Log.d("LocalServer", msg ?: "")
            } catch (ignored: Throwable) {
            }
        }
    }
}
