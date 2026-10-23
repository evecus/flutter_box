package com.mobile.js

import org.jsoup.Jsoup
import org.jsoup.nodes.Document
import org.jsoup.select.Elements
import java.net.URL
import java.util.ArrayList
import java.util.Arrays
import java.util.regex.Matcher
import java.util.regex.Pattern

object HtmlParser {

    private const val EMPTY = ""

    private var pdfh_html: String = EMPTY
    private var pdfa_html: String = EMPTY
    private var pdfh_doc: Document? = null
    private var pdfa_doc: Document? = null

    private val p: Pattern = Pattern.compile("url\\((.*?)\\)", Pattern.MULTILINE or Pattern.DOTALL)
    private val NOADD_INDEX: Pattern = Pattern.compile(":eq|:lt|:gt|:first|:last|^body$|^#")
    private val URLJOIN_ATTR: Pattern =
        Pattern.compile("(url|src|href|-original|-src|-play|-url|style)$", Pattern.MULTILINE or Pattern.CASE_INSENSITIVE)
    private val SPECIAL_URL: Pattern =
        Pattern.compile("^(ftp|magnet|thunder|ws):", Pattern.MULTILINE or Pattern.CASE_INSENSITIVE)

    fun isEmpty(str: String?): Boolean {
        return str == null || str.isEmpty()
    }

    fun isNotEmpty(str: String?): Boolean {
        return !isEmpty(str)
    }

    fun joinUrl(parent: String?, child: String?): String? {
        if (isEmpty(parent)) {
            return child
        }
        val q: String
        try {
            val url = URL(URL(parent), child)
            q = url.toExternalForm()
        } catch (e: Exception) {
            return child
        }
        return q
    }

    class Painfo {
        var nparse_rule: String = EMPTY
        var nparse_index: Int = 0
        var excludes: List<String>? = null
    }

    @Throws(java.lang.Exception::class)
    private fun parseInt(nparsePos: String?): Int {
        if (nparsePos == null) throw java.lang.Exception("null")
        return nparsePos.replace("eq(", "").replace(")", "").toInt()
    }

    private fun getParseInfo(nparse: String): Painfo {
        val painfo = Painfo()
        painfo.nparse_rule = nparse
        if (nparse.contains(":eq")) {
            // 对齐原版 Java: split(":") 后首段为规则, 第二段为位置
            val parts = nparse.split(":")
            painfo.nparse_rule = parts[0]
            var nparse_pos = if (parts.size > 1) parts[1] else ""
            if (painfo.nparse_rule.contains("--")) {
                val rules = painfo.nparse_rule.split("--")
                painfo.excludes = rules.drop(1)
                painfo.nparse_rule = rules[0]
            } else if (nparse_pos.contains("--")) {
                val rules = nparse_pos.split("--")
                painfo.excludes = rules.drop(1)
                nparse_pos = rules[0]
            }
            try {
                painfo.nparse_index = parseInt(nparse_pos.replace("eq(", "").replace(")", ""))
            } catch (e1: Exception) {
                painfo.nparse_index = 0
            }
        } else {
            if (nparse.contains("--")) {
                val rules = painfo.nparse_rule.split("--")
                painfo.excludes = rules.drop(1)
                painfo.nparse_rule = rules[0]
            }
        }
        return painfo
    }

    private fun parseHikerToJq(parse: String, first: Boolean): String {
        var parse = parse
        if (parse.contains("&&")) {
            val parses = parse.split("&&".toRegex())
            val new_parses = ArrayList<String>()
            for (i in parses.indices) {
                val pss = parses[i].split(" ".toRegex())
                val ps = pss[pss.size - 1]
                val m = NOADD_INDEX.matcher(ps)
                if (!m.find()) {
                    if (!first && i >= parses.size - 1) {
                        new_parses.add(parses[i])
                    } else {
                        new_parses.add(parses[i] + ":eq(0)")
                    }
                } else {
                    new_parses.add(parses[i])
                }
            }
            parse = java.lang.String.join(" ", new_parses)
        } else {
            val pss = parse.split(" ".toRegex())
            val ps = pss[pss.size - 1]
            val m = NOADD_INDEX.matcher(ps)
            if (!m.find() && first) {
                parse = parse + ":eq(0)"
            }
        }
        return parse
    }

    fun parseDomForUrl(html: String?, rule: String?, add_url: String): String {
        if (html == null || rule == null) return ""
        if (!pdfh_html.contentEquals(html)) {
            pdfh_html = html
            pdfh_doc = Jsoup.parse(html)
        }
        val doc = pdfh_doc
        if (rule == "body&&Text" || rule == "Text") {
            return doc?.text() ?: ""
        } else if (rule == "body&&Html" || rule == "Html") {
            return doc?.html() ?: ""
        }
        var option = ""
        var r = rule
        if (r.contains("&&")) {
            val rs = r.split("&&".toRegex())
            option = rs[rs.size - 1]
            val excludes = rs.toMutableList()
            excludes.removeAt(rs.size - 1)
            r = java.lang.String.join("&&", excludes)
        }
        r = parseHikerToJq(r, true)
        val parses = r.split(" ".toRegex())
        if (doc == null) return ""
        var ret = Elements()
        for (nparse in parses) {
            ret = parseOneRule(doc, nparse, ret)
            if (ret.isEmpty()) {
                return ""
            }
        }
        return if (isNotEmpty(option)) {
            val result: String
            if (option == "Text") {
                result = ret.text()
            } else if (option == "Html") {
                result = ret.html()
            } else {
                var res = ret.attr(option)
                if (option.lowercase().contains("style") && res.contains("url(")) {
                    val m = p.matcher(res)
                    if (m.find()) {
                        res = m.group(1)
                    }
                    if (isNotEmpty(res)) {
                        res = res.replace("^['|\"](.*)['|\"]$".toRegex(), "$1")
                    }
                }
                if (isNotEmpty(res) && isNotEmpty(add_url)) {
                    val m = URLJOIN_ATTR.matcher(option)
                    val n = SPECIAL_URL.matcher(res)
                    if (m.find() && !n.find()) {
                        if (res.contains("http")) {
                            res = res.substring(res.indexOf("http"))
                        } else {
                            res = joinUrl(add_url, res) ?: res
                        }
                    }
                }
                result = res
            }
            result
        } else {
            ret.outerHtml()
        }
    }

    fun parseDomForArray(html: String?, rule: String?): List<String> {
        if (html == null || rule == null) return ArrayList()
        if (!pdfa_html.contentEquals(html)) {
            pdfa_html = html
            pdfa_doc = Jsoup.parse(html)
        }
        val doc = pdfa_doc
        var r = parseHikerToJq(rule, false)
        val parses = r.split(" ".toRegex())
        if (doc == null) return ArrayList()
        var ret = Elements()
        for (nparse in parses) {
            ret = parseOneRule(doc, nparse, ret)
            if (ret.isEmpty()) {
                return ArrayList()
            }
        }
        val eleHtml = ArrayList<String>()
        for (i in ret.indices) {
            eleHtml.add(ret[i].outerHtml())
        }
        return eleHtml
    }

    private fun parseOneRule(doc: Document, nparse: String, retOrig: Elements): Elements {
        var ret = retOrig
        val painfo = getParseInfo(nparse)
        if (ret.isEmpty()) {
            ret = doc.select(painfo.nparse_rule)
        } else {
            ret = ret.select(painfo.nparse_rule)
        }
        if (nparse.contains(":eq")) {
            if (painfo.nparse_index < 0) {
                ret = ret.`eq`(ret.size + painfo.nparse_index)
            } else {
                ret = ret.`eq`(painfo.nparse_index)
            }
        }
        if (painfo.excludes != null && !ret.isEmpty()) {
            ret = ret.clone()
            for (exclude in painfo.excludes!!) {
                ret.select(exclude).remove()
            }
        }
        return ret
    }

    fun parseDomForList(html: String?, p1: String?, list_text: String?, list_url: String?, add_url: String): List<String> {
        if (html == null || p1 == null || list_text == null || list_url == null) return ArrayList()
        if (!pdfa_html.contentEquals(html)) {
            pdfa_html = html
            pdfa_doc = Jsoup.parse(html)
        }
        val doc = pdfa_doc
        var pp1 = parseHikerToJq(p1, false)
        val parses = pp1.split(" ".toRegex())
        if (doc == null) return ArrayList()
        var ret = Elements()
        for (nparse in parses) {
            ret = parseOneRule(doc, nparse, ret)
            if (ret.isEmpty()) {
                return ArrayList()
            }
        }
        val new_vod_list = ArrayList<String>()
        for (i in ret.indices) {
            val it = ret[i].outerHtml()
            new_vod_list.add((parseDomForUrl(it, list_text, "").trim() + '$' + parseDomForUrl(it, list_url, add_url)))
        }
        return new_vod_list
    }
}
