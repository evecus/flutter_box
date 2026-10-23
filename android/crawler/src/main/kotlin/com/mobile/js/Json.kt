package com.mobile.js

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser
import org.json.JSONObject
import java.util.ArrayList
import java.util.HashMap

object Json {

    fun valid(text: String?): Boolean {
        return try {
            JSONObject(text)
            true
        } catch (e: Exception) {
            false
        }
    }

    fun invalid(text: String?): Boolean {
        return !valid(text)
    }

    fun safeString(obj: JsonObject, key: String): String {
        return try {
            obj.getAsJsonPrimitive(key).asString.trim()
        } catch (e: Exception) {
            ""
        }
    }

    fun safeListString(obj: JsonObject, key: String): List<String> {
        val result = ArrayList<String>()
        if (!obj.has(key)) return result
        if (obj.get(key).isJsonObject) result.add(safeString(obj, key))
        else for (opt in obj.getAsJsonArray(key)) result.add(opt.asString)
        return result
    }

    fun safeListElement(obj: JsonObject, key: String): List<JsonElement> {
        val result = ArrayList<JsonElement>()
        if (!obj.has(key)) return result
        if (obj.get(key).isJsonObject) result.add(obj.get(key).asJsonObject)
        else for (opt in obj.getAsJsonArray(key)) result.add(opt.asJsonObject)
        return result
    }

    fun safeObject(element: JsonElement): JsonObject {
        try {
            var el = element
            if (el.isJsonPrimitive) el = JsonParser.parseString(el.asJsonPrimitive.asString)
            return el.asJsonObject
        } catch (e: Exception) {
            return JsonObject()
        }
    }

    fun toMap(element: JsonElement?): Map<String, String> {
        val map = HashMap<String, String>()
        try {
            if (element == null || element.isJsonNull) return map
            val object1 = safeObject(element)
            for (key in object1.keySet()) map[key] = safeString(object1, key)
        } catch (ignored: Exception) {
        }
        return map
    }
}
