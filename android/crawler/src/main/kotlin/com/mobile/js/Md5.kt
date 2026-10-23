package com.mobile.js

import java.security.MessageDigest

object Md5 {

    private var md5: MessageDigest? = null

    init {
        try {
            md5 = MessageDigest.getInstance("MD5")
        } catch (ignored: Exception) {
        }
    }

    fun encode(res: String): String = encode(res.toByteArray())

    fun encode(bytes: ByteArray): String {
        try {
            val d = md5?.digest(bytes) ?: return ""
            val j = d.size
            val str = CharArray(j * 2)
            var k = 0
            for (byte0 in d) {
                str[k++] = hexDigits[byte0.toInt().ushr(4) and 0xf]
                str[k++] = hexDigits[byte0.toInt() and 0xf]
            }
            return String(str)
        } catch (e: Exception) {
            return ""
        }
    }

    fun string2MD5(inStr: String?): String? {
        if (md5 == null) return null
        if (inStr.isNullOrEmpty()) return null
        return try {
            toHex(md5!!.digest(inStr.toByteArray(Charsets.UTF_8)))
        } catch (e: Exception) {
            toHex(md5!!.digest(inStr.toByteArray()))
        }
    }

    fun getFileMd5(f: java.io.File): String {
        try {
            val md = MessageDigest.getInstance("MD5")
            val buffer = ByteArray(4096)
            java.io.FileInputStream(f).use { fis ->
                while (true) {
                    val len = fis.read(buffer)
                    if (len <= 0) break
                    md.update(buffer, 0, len)
                }
            }
            return toHex(md.digest())
        } catch (e: Exception) {
            return ""
        }
    }

    private fun toHex(bytes: ByteArray): String {
        val sb = StringBuilder()
        for (b in bytes) {
            val v = b.toInt() and 0xff
            if (v < 16) sb.append('0')
            sb.append(Integer.toHexString(v))
        }
        return sb.toString()
    }

    private val hexDigits = charArrayOf('0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f')
}
