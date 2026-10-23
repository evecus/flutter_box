package com.novabox.engine

import android.util.Base64
import org.json.JSONObject
import java.security.spec.AlgorithmParameterSpec
import javax.crypto.Cipher
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * 配置解密, 移植自原版 NovaBox ApiConfig.FindResult + util.AES.
 * 支持:
 *  1. 明文 JSON 直接返回
 *  2. "[A-Za-z0-9]{8}**" 标记 + Base64
 *  3. "2423" 开头的 AES-CBC (PKCS7, key/iv 从 hex 解码后的内容中提取)
 *  4. ;pk; 密钥的 AES-ECB
 */
object ConfigCrypto {

    fun findResult(json: String, configKey: String?): String {
        var content = json
        try {
            if (isJson(content)) return content
            val pattern = Regex("[A-Za-z0-9]{8}\\*\\*")
            val matcher = pattern.find(content)
            if (matcher != null) {
                content = content.substring(content.indexOf(matcher.value) + 10)
                content = String(Base64.decode(content.replace(Regex("\\s+"), ""), Base64.DEFAULT))
            }
            content = content.trim()
            if (content.startsWith("2423")) {
                content = content.replace(Regex("\\s+"), "")
                val data = content.substring(content.indexOf("2324") + 4, content.length - 26)
                val lower = String(toBytes(content)).lowercase()
                val key = rightPadding(lower.substring(lower.indexOf("$#") + 2, lower.indexOf("#$")), "0", 16)
                val iv = rightPadding(lower.substring(lower.length - 13), "0", 16)
                return cbc(data, key, iv) ?: content
            } else if (configKey != null && !isJson(content)) {
                return ecb(content, configKey) ?: content
            }
            return content
        } catch (e: Exception) {
            e.printStackTrace()
        }
        return json
    }

    private fun isJson(content: String): Boolean {
        return try {
            JSONObject(content)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun rightPadding(key: String, replace: String, length: Int): String {
        val trimmed = key.trim()
        return when {
            trimmed.length > length -> trimmed.substring(0, length)
            trimmed.length == length -> trimmed
            else -> trimmed + replace.repeat(length - trimmed.length)
        }
    }

    private fun toBytes(src: String): ByteArray {
        val result = ByteArray(src.length / 2)
        for (i in result.indices) {
            val index = i * 2
            result[i] = ((Character.digit(src[index], 16) shl 4) + Character.digit(src[index + 1], 16)).toByte()
        }
        return result
    }

    private fun ecb(data: String, key: String): String? {
        return try {
            val keySpec = SecretKeySpec(rightPadding(key, "0", 16).toByteArray(), "AES")
            val cipher = Cipher.getInstance("AES/ECB/PKCS5Padding")
            cipher.init(Cipher.DECRYPT_MODE, keySpec)
            String(cipher.doFinal(toBytes(data)))
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun cbc(data: String, key: String, iv: String): String? {
        return try {
            val keySpec = SecretKeySpec(key.toByteArray(), "AES")
            val paramSpec: AlgorithmParameterSpec = IvParameterSpec(iv.toByteArray())
            val cipher = Cipher.getInstance("AES/CBC/PKCS5Padding")
            cipher.init(Cipher.DECRYPT_MODE, keySpec, paramSpec)
            String(cipher.doFinal(toBytes(data)))
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }
}
