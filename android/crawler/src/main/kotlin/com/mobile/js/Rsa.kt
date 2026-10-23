package com.mobile.js

import android.util.Base64
import java.io.ByteArrayOutputStream
import java.security.KeyFactory
import java.security.PrivateKey
import java.security.PublicKey
import java.security.interfaces.RSAPrivateKey
import java.security.interfaces.RSAPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import javax.crypto.Cipher

object Rsa {

    const val ECB_PKCS1_PADDING = "RSA/ECB/PKCS1Padding"
    const val KEY_ALGORITHM = "RSA"
    private const val MAX_ENCRYPT_BLOCK = 117
    private const val MAX_DECRYPT_BLOCK = 128

    fun getPublicKey(pubKey: String): PublicKey? {
        return try {
            KeyFactory.getInstance(KEY_ALGORITHM).generatePublic(X509EncodedKeySpec(base64Decode(pubKey)))
        } catch (e: Exception) {
            null
        }
    }

    fun getPrivateKey(prvKey: String): PrivateKey? {
        return try {
            KeyFactory.getInstance(KEY_ALGORITHM).generatePrivate(PKCS8EncodedKeySpec(base64Decode(prvKey)))
        } catch (e: Exception) {
            null
        }
    }

    fun encryptByPublicKey(data: String, pubKey: String, mlong: Int, block: Boolean): String {
        return encryptByPublicKey(data, pubKey, ECB_PKCS1_PADDING, mlong, block)
    }

    fun encryptByPublicKey(data: String, pubKey: String, config: String, mlong: Int, block: Boolean): String {
        try {
            val bytes = data.toByteArray(Charsets.UTF_8)
            val cipher = Cipher.getInstance(config)
            val rsaPublicKey = getPublicKey(pubKey) as RSAPublicKey
            cipher.init(Cipher.ENCRYPT_MODE, rsaPublicKey)
            if (mlong == 1) return base64Encode(cipher.doFinal(bytes))
            var bitLength = MAX_ENCRYPT_BLOCK
            if (block) bitLength = rsaPublicKey.modulus.bitLength() / 8 - 11
            val inputLen = bytes.size
            val out = ByteArrayOutputStream()
            var offSet = 0
            var i = 0
            while (inputLen - offSet > 0) {
                val cache = if (inputLen - offSet > bitLength) cipher.doFinal(bytes, offSet, bitLength) else cipher.doFinal(bytes, offSet, inputLen - offSet)
                out.write(cache, 0, cache.size)
                i++
                offSet = i * bitLength
            }
            val encryptedData = out.toByteArray()
            out.close()
            return base64Encode(encryptedData)
        } catch (e: Exception) {
            return ""
        }
    }

    fun decryptByPrivateKey(encryptBase64Data: String, prvKey: String, mlong: Int, block: Boolean): String {
        return decryptByPrivateKey(encryptBase64Data, prvKey, ECB_PKCS1_PADDING, mlong, block)
    }

    fun decryptByPrivateKey(encryptBase64Data: String, prvKey: String, config: String, mlong: Int, block: Boolean): String {
        try {
            val encryptedData = base64Decode(encryptBase64Data)
            val cipher = Cipher.getInstance(config)
            val rsaPrivateKey = getPrivateKey(prvKey) as RSAPrivateKey
            cipher.init(Cipher.DECRYPT_MODE, rsaPrivateKey)
            if (mlong == 1) return String(cipher.doFinal(encryptedData))
            var bitLength = MAX_DECRYPT_BLOCK
            if (block) bitLength = rsaPrivateKey.modulus.bitLength() / 8
            val inputLen = encryptedData.size
            val out = ByteArrayOutputStream()
            var offSet = 0
            var i = 0
            while (inputLen - offSet > 0) {
                val cache = if (inputLen - offSet > bitLength) cipher.doFinal(encryptedData, offSet, bitLength) else cipher.doFinal(encryptedData, offSet, inputLen - offSet)
                out.write(cache, 0, cache.size)
                i++
                offSet = i * bitLength
            }
            out.close()
            return out.toString("UTF-8")
        } catch (e: Exception) {
            return ""
        }
    }

    fun encryptByPrivateKey(data: String, prvKey: String, mlong: Int, block: Boolean): String {
        return encryptByPrivateKey(data, prvKey, ECB_PKCS1_PADDING, mlong, block)
    }

    fun encryptByPrivateKey(data: String, prvKey: String, config: String, mlong: Int, block: Boolean): String {
        try {
            val bytes = data.toByteArray(Charsets.UTF_8)
            val cipher = Cipher.getInstance(config)
            val rsaPrivateKey = getPrivateKey(prvKey) as RSAPrivateKey
            cipher.init(Cipher.ENCRYPT_MODE, rsaPrivateKey)
            if (mlong == 1) return base64Encode(cipher.doFinal(bytes))
            var bitLength = MAX_ENCRYPT_BLOCK
            if (block) bitLength = rsaPrivateKey.modulus.bitLength() / 8 - 11
            val inputLen = bytes.size
            val out = ByteArrayOutputStream()
            var offSet = 0
            var i = 0
            while (inputLen - offSet > 0) {
                val cache = if (inputLen - offSet > bitLength) cipher.doFinal(bytes, offSet, bitLength) else cipher.doFinal(bytes, offSet, inputLen - offSet)
                out.write(cache, 0, cache.size)
                i++
                offSet = i * bitLength
            }
            val encryptedData = out.toByteArray()
            out.close()
            return base64Encode(encryptedData)
        } catch (e: Exception) {
            return ""
        }
    }

    fun decryptByPublicKey(encryptBase64Data: String, pubKey: String, mlong: Int, block: Boolean): String {
        return decryptByPublicKey(encryptBase64Data, pubKey, ECB_PKCS1_PADDING, mlong, block)
    }

    fun decryptByPublicKey(encryptBase64Data: String, pubKey: String, config: String, mlong: Int, block: Boolean): String {
        try {
            val encryptedData = base64Decode(encryptBase64Data)
            val cipher = Cipher.getInstance(config)
            val rsaPublicKey = getPublicKey(pubKey) as RSAPublicKey
            cipher.init(Cipher.DECRYPT_MODE, rsaPublicKey)
            if (mlong == 1) return String(cipher.doFinal(encryptedData))
            var bitLength = MAX_DECRYPT_BLOCK
            if (block) bitLength = rsaPublicKey.modulus.bitLength() / 8
            val inputLen = encryptedData.size
            val out = ByteArrayOutputStream()
            var offSet = 0
            var i = 0
            while (inputLen - offSet > 0) {
                val cache = if (inputLen - offSet > bitLength) cipher.doFinal(encryptedData, offSet, bitLength) else cipher.doFinal(encryptedData, offSet, inputLen - offSet)
                out.write(cache, 0, cache.size)
                i++
                offSet = i * bitLength
            }
            out.close()
            return out.toString("UTF-8")
        } catch (e: Exception) {
            return ""
        }
    }

    fun base64Encode(bytes: ByteArray): String {
        return android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
    }

    fun base64Decode(text: String): ByteArray {
        return android.util.Base64.decode(text, android.util.Base64.DEFAULT)
    }
}
