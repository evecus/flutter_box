package com.github.catvod

import android.util.Base64
import java.io.ByteArrayInputStream

/**
 * go=SuperParse 的落点 (对照原版 com.mobile.novabox.util.parser.SuperParse.loadHtml).
 * 返回一个内嵌各解析接口 iframe 的 HTML 页, 由播放器 WebView 加载后嗅探视频地址.
 *
 * 原版的 flagWebJx 由 parseMix 流程 (type 3/4 聚合解析) 填充;
 * flutter_box 暂无聚合解析 UI, 此处保留注册表结构, 未注册时返回 null (代理返回 500).
 */
object SuperParse {

    private val flagWebJx = HashMap<String, List<String>>()

    fun registerWebJx(flag: String, urls: List<String>) {
        if (urls.isNotEmpty()) flagWebJx[flag] = urls
    }

    fun loadHtml(flag: String?, url: String?): Array<Any?>? {
        return try {
            if (url.isNullOrEmpty()) return null
            val jxUrls = flagWebJx[flag]
            if (jxUrls.isNullOrEmpty()) return null
            val decoded = String(Base64.decode(url, Base64.DEFAULT or Base64.URL_SAFE or Base64.NO_WRAP), Charsets.UTF_8)
            val html = "\n" +
                "<!doctype html>\n" +
                "<html>\n" +
                "<head>\n" +
                "<title>解析</title>\n" +
                "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />\n" +
                "<meta http-equiv=\"X-UA-Compatible\" content=\"IE=EmulateIE10\" />\n" +
                "<meta name=\"renderer\" content=\"webkit|ie-comp|ie-stand\">\n" +
                "<meta name=\"viewport\" content=\"width=device-width\">\n" +
                "</head>\n" +
                "<body>\n" +
                "<script>\n" +
                "var apiArray=[#jxs#];\n" +
                "var urlPs=\"#url#\";\n" +
                "var iframeHtml=\"\";\n" +
                "for(var i=0;i<apiArray.length;i++){\n" +
                "var URL=apiArray[i]+urlPs;\n" +
                "iframeHtml=iframeHtml+\"<iframe sandbox='allow-scripts allow-same-origin allow-forms' frameborder='0' allowfullscreen='true' webkitallowfullscreen='true' mozallowfullscreen='true' src=\"+URL+\"></iframe>\";\n" +
                "}\n" +
                "document.write(iframeHtml);\n" +
                "</script>\n" +
                "</body>\n" +
                "</html>"

            val jxs = StringBuilder()
            for (i in jxUrls.indices) {
                jxs.append("\"")
                jxs.append(jxUrls[i])
                jxs.append("\"")
                if (i < jxUrls.size - 1) {
                    jxs.append(",")
                }
            }
            val page = html.replace("#url#", decoded).replace("#jxs#", jxs.toString())
            val result = arrayOfNulls<Any>(3)
            result[0] = 200
            result[1] = "text/html; charset=\"UTF-8\""
            result[2] = ByteArrayInputStream(page.toByteArray(Charsets.UTF_8))
            result
        } catch (th: Throwable) {
            th.printStackTrace()
            null
        }
    }
}
