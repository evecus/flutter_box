package com.mobile.js

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import java.net.Inet4Address
import java.net.NetworkInterface

object App {

    lateinit var shared: Application

    fun get(): Application = shared

    fun prefs(name: String): SharedPreferences = shared.getSharedPreferences(name, Context.MODE_PRIVATE)

    fun getIp(): String {
        try {
            val en = NetworkInterface.getNetworkInterfaces()
            while (en.hasMoreElements()) {
                val net = en.nextElement()
                val addresses = net.inetAddresses
                while (addresses.hasMoreElements()) {
                    val addr = addresses.nextElement()
                    if (addr is Inet4Address && !addr.isLoopbackAddress && addr.isSiteLocalAddress) {
                        return addr.hostAddress ?: ""
                    }
                }
            }
        } catch (ignored: Throwable) {
        }
        return "127.0.0.1"
    }
}
