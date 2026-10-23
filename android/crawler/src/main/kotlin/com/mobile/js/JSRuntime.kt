package com.mobile.js

import android.util.Base64
import com.github.catvod.net.Net
import com.github.catvod.server.LocalServer
import com.google.gson.Gson
import com.google.gson.JsonObject
import okhttp3.Request
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.io.InputStreamReader
import java.util.HashMap
import java.util.HashSet
import java.util.regex.Matcher
import java.util.regex.Pattern

object JSRuntime {

    private val URL_JOIN: Pattern =
        Pattern.compile("^http.*\\.(js|txt|json)", Pattern.MULTILINE or Pattern.CASE_INSENSITIVE)

    const val CACHE_TTL: Int = 604800

    private val cachedDirFiles = HashMap<String, Set<String>>()

    fun loadModule(name: String?): String? {
        var rel: String? = null
        var target = name ?: return null
        try {
            if (target.contains("gbk.js")) {
                target = "gbk.js"
            } else if (target.contains("模板.js")) {
                target = "模板.js"
            } else if (target.contains("cat.js")) {
                target = "cat.js"
            }
            Loge.i("echo-loadModule $target")
            val m: Matcher = URL_JOIN.matcher(target)
            if (m.find()) {
                val cache = getCache(Md5.encode(target))
                rel = cache
                if (cache.isEmpty()) {
                    val netStr = fetch(target, null)
                    if (netStr.isNotEmpty()) {
                        setCache(CACHE_TTL, Md5.encode(target), netStr)
                    }
                    rel = netStr
                }
            } else if (target.startsWith("assets://")) {
                rel = getAsOpen(target.substring(9))
            } else if (isAsFile(target, "js/lib")) {
                rel = getAsOpen("js/lib/$target")
            } else if (target.startsWith("file://")) {
                // 对齐原版 FileUtils.loadModule：本地文件走 LocalServer /file/ 路由
                rel = fetch(
                    LocalServer.getAddress(true) + "file/" +
                        target.replace("file:///", "").replace("file://", ""),
                    null
                )
            } else if (target.startsWith("clan://localhost/")) {
                rel = fetch(
                    LocalServer.getAddress(true) + "file/" + target.replace("clan://localhost/", ""),
                    null
                )
            } else if (target.startsWith("clan://")) {
                val substring = target.substring(7)
                val indexOf = substring.indexOf('/')
                if (indexOf > 0) {
                    rel = fetch(
                        "http://" + substring.substring(0, indexOf) + "/file/" + substring.substring(indexOf + 1),
                        null
                    )
                }
            }
        } catch (e: Exception) {
            Loge.e("echo-loadModule-error " + e.message)
        }
        return rel
    }

    fun isAsFile(name: String, dir: String): Boolean {
        val files: Set<String>
        val cached = synchronized(cachedDirFiles) { cachedDirFiles[dir] }
        if (cached == null) {
            Loge.i("echo-readAssetsList")
            files = try {
                val list = App.get().assets.list(dir)
                HashSet<String>(list!!.toList())
            } catch (e: Exception) {
                HashSet()
            }
            synchronized(cachedDirFiles) {
                cachedDirFiles[dir] = files
            }
        } else {
            files = cached
        }
        return files.contains(name.trim())
    }

    fun getAsOpen(name: String): String {
        try {
            val inputStream: InputStream = App.get().assets.open(name)
            val data = ByteArray(inputStream.available())
            inputStream.read(data)
            inputStream.close()
            return String(data, Charsets.UTF_8)
        } catch (e: Exception) {
        }
        return ""
    }

    fun fetch(url: String?, headers: Map<String, String>?): String {
        if (url == null || !url.startsWith("http")) return ""
        return try {
            val builder = Request.Builder().url(url)
            if (headers != null) for ((k, v) in headers) builder.header(k, v)
            Net.defaultClient().newCall(builder.build()).execute().use { it.body?.string() ?: "" }
        } catch (e: Exception) {
            ""
        }
    }

    fun getCache(name: String): String {
        try {
            var code = ""
            val file = open(name)
            if (file.exists()) {
                val data = readSimple(file)
                if (data != null) code = String(data, Charsets.UTF_8)
            }
            if (code.isEmpty()) {
                return ""
            }
            val obj = Gson().fromJson(code, JsonObject::class.java).asJsonObject
            if (obj.get("expires").asInt.toLong() <= System.currentTimeMillis() / 1000) {
                recursiveDelete(open(name))
            }
            return obj.get("data").asString
        } catch (e: Exception) {
            return ""
        }
    }

    fun setCache(time: Int, name: String, data: String) {
        try {
            val obj = JSONObject()
            obj.put("expires", time + (System.currentTimeMillis() / 1000))
            obj.put("data", data)
            writeSimple(obj.toString().toByteArray(Charsets.UTF_8), open(name))
        } catch (e: Exception) {
        }
    }

    fun setCacheByte(name: String, data: ByteArray) {
        try {
            writeSimple(byteMerger("//DRPY".toByteArray(), Base64.encode(data, Base64.URL_SAFE)), open("B_$name"))
        } catch (e: Exception) {
        }
    }

    fun getCacheByte(name: String): ByteArray {
        return try {
            val data = readSimple(open("B_$name")) ?: return ByteArray(0)
            val text = String(data, Charsets.UTF_8)
            if (text.startsWith("//DRPY")) Base64.decode(text.replace("//DRPY", ""), Base64.URL_SAFE) else ByteArray(0)
        } catch (e: Exception) {
            ByteArray(0)
        }
    }

    fun byteMerger(bt1: ByteArray, bt2: ByteArray): ByteArray {
        val bt3 = ByteArray(bt1.size + bt2.size)
        System.arraycopy(bt1, 0, bt3, 0, bt1.size)
        System.arraycopy(bt2, 0, bt3, bt1.size, bt2.size)
        return bt3
    }

    fun open(str: String): File {
        return File(getExternalCachePath() + "/qjscache_" + str + ".js")
    }

    fun getExternalCachePath(): String {
        val externalCacheDir = App.get().externalCacheDir
        if (externalCacheDir == null) {
            return App.get().cacheDir.absolutePath
        }
        return externalCacheDir.absolutePath
    }

    fun writeSimple(data: ByteArray, dst: File): Boolean {
        try {
            if (dst.exists()) dst.delete()
            BufferedOutputStream(FileOutputStream(dst)).use { bos -> bos.write(data) }
            return true
        } catch (e: Exception) {
            Loge.e("echo-writeSimple " + e.message)
        }
        return false
    }

    fun readSimple(src: File): ByteArray? {
        try {
            val bis = BufferedInputStream(FileInputStream(src))
            val len = bis.available()
            val data = ByteArray(len)
            bis.read(data)
            bis.close()
            return data
        } catch (e: Exception) {
        }
        return null
    }

    fun readBytes(inputStream: InputStream?): ByteArray {
        if (inputStream == null) return ByteArray(0)
        try {
            val baos = ByteArrayOutputStream()
            val buffer = ByteArray(8192)
            while (true) {
                val len = inputStream.read(buffer)
                if (len <= 0) break
                baos.write(buffer, 0, len)
            }
            inputStream.close()
            return baos.toByteArray()
        } catch (e: Exception) {
            return ByteArray(0)
        }
    }

    fun recursiveDelete(file: File?) {
        if (file == null || !file.exists()) return
        if (file.isDirectory) {
            val children = file.listFiles()
            if (children != null) for (f in children) recursiveDelete(f)
        }
        file.delete()
    }

    fun isWeekAgo(file: File): Boolean {
        val oneWeekMillis: Long = 3L * 24 * 60 * 60 * 1000
        return System.currentTimeMillis() - file.lastModified() > oneWeekMillis
    }

    fun readFileToString(path: String, charsetName: String): String {
        val sb = StringBuilder()
        try {
            val reader = InputStreamReader(FileInputStream(File(path)), charsetName)
            val buf = CharArray(4096)
            while (true) {
                val len = reader.read(buf)
                if (len <= 0) break
                sb.append(buf, 0, len)
            }
            reader.close()
        } catch (ignored: Exception) {
        }
        return sb.toString()
    }

    fun saveCache(cache: File, json: String) {
        try {
            val cacheDir = cache.parentFile
            if (cacheDir != null && !cacheDir.exists()) cacheDir.mkdirs()
            if (cache.exists()) cache.delete()
            java.io.FileOutputStream(cache).use { fos -> fos.write(json.toByteArray(Charsets.UTF_8)) }
        } catch (e: Exception) {
        }
    }
}
