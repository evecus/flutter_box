package com.github.catvod

import com.github.catvod.server.LocalServer
import com.mobile.js.App

object Proxy {

    private var port: Int = LocalServer.port

    @JvmStatic
    fun set(port: Int) {
        this.port = port
    }

    @JvmStatic
    fun getPort(): Int {
        return if (port > 0) port else LocalServer.port
    }

    @JvmStatic
    fun getUrl(local: Boolean): String {
        val ip = if (local) "127.0.0.1" else getIp()
        return "http://" + ip + ":" + getPort() + "/proxy"
    }

    private fun getIp(): String {
        return try {
            App.getIp()
        } catch (th: Throwable) {
            "127.0.0.1"
        }
    }
}
