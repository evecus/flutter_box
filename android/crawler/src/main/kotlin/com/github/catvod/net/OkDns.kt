package com.github.catvod.net

import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.ConcurrentHashMap
import okhttp3.Dns

class OkDns : Dns {

    private val hosts = ConcurrentHashMap<String, String>()

    fun addAll(list: List<String>?) {
        if (list == null) return
        for (host in list) {
            val splits = host.split("=".toRegex(), limit = 2)
            if (splits.size == 2) hosts[splits[0].trim()] = splits[1].trim()
        }
    }

    fun clear() {
        hosts.clear()
    }

    private fun get(hostname: String): String {
        val target = hosts[hostname]
        if (target != null) return target
        for ((key, value) in hosts) {
            if (hostname.contains(key)) return value
        }
        return hostname
    }

    @Throws(UnknownHostException::class)
    override fun lookup(hostname: String): List<InetAddress> {
        val dns: Dns = if (Net.dnsOverHttps != null) Net.dnsOverHttps!! else Dns.SYSTEM
        return dns.lookup(get(hostname))
    }
}
