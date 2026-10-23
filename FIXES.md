# flutter_box 爬虫引擎修复说明（对照原版 NovaBox）

## 问题现象

设置页可成功导入源，但**首页 / 分类 / 搜索**对绝大多数站点返回空；
仅少数「直播站源」（js 源）能出结果。

## 根因（两个叠加，都必须修）

### 根因 A：Dart 侧 `_abs` 误拼 csp_ api（直接原因，日志实锤）

线上配置导入后，`csp_AppgzGuard` 被 `Site.fromMap` 的 `_abs()` 当成相对路径，
拼成 `http://www.饭太硬.net/csp_AppgzGuard`；Kotlin 侧 `removePrefix("csp_")`
后得到 `http://www.饭太硬.net/AppgzGuard`，`loadClass("com.github.catvod.spider.http://…")`
必然 `ClassNotFound`。logcat 实锤（每条源都命中）：

```
echo-getSpider error key=瓜子 clsKey=http://www.饭太硬.net/AppgzGuard
  msg=Didn't find class "com.github.catvod.spider.http://www.饭太硬.net/AppgzGuard"
```

js 源 api 是完整 https URL，`_abs` 原样返回，所以只有 js 直播源能用——
与现象完全吻合。原版 `ApiConfig` 对 api 是**原样透传**：
`sb.setApi(obj.get("api").getAsString().trim())`。

**修复**：`lib/config/config.dart` 新增 `_absApi()`，`csp_` 前缀直接透传，
其余（相对 js 路径等）维持 base 补全；`Site.fromMap` 改调 `_absApi`。
另补两个回归测试（csp 透传 + 相对路径仍补全）。

### 根因 B：Kotlin `object` 缺 `@JvmStatic`/`@JvmField`（jar 链路易被掩盖的第二因）

TVBox 配置里站点分两类入口：

| api 形式 | 走哪条路 | 典型源 |
|---|---|---|
| `xxx.js` | QuickJS（JsSpider） | 虎牙/斗鱼直播、兔小贝 |
| `csp_XXX`（或任意非 .js） | 主 jar 内预编译 dex 爬虫类 `com.github.catvod.spider.XXX` | 饭太硬 46/49 个源、绝大多数影视站 |

主 jar（常伪装成 `.jpg` 的 APK/dex）里的爬虫类以**静态方式**链接宿主的门面类：

```java
INVOKESTATIC com.github.catvod.net.OkHttp.string (Ljava/lang/String;)Ljava/lang/String;
INVOKESTATIC com.github.catvod.crawler.Spider.client ()Lokhttp3/OkHttpClient;
INVOKESTATIC com.github.catvod.crawler.SpiderDebug.log (Ljava/lang/String;)V
GETFIELD     com.github.catvod.crawler.Spider.siteKey
```

而 flutter_box 把这些类写成了 Kotlin `object`，未加 `@JvmStatic`/`@JvmField`
时方法编译为**实例方法**（`INVOKEVIRTUAL OkHttp.INSTANCE.string(...)`）。
dex 按静态签名链接不到 → `NoSuchMethodError` → 异常被 invoke 的 try/catch
吞掉 → 所有 csp_ 源静默返回空字符串。

**注意**：根因 A 会先于 B 暴露（loadClass 就挂了，根本走不到调用门面那一步），
所以只修 A 不修 B，csp 源照样全空；两个修复缺一不可。

## 修改清单（12 个文件）

### 1. `android/crawler/src/main/kotlin/com/github/catvod/net/OkHttp.kt`（重写）
- 所有 public 函数加 `@JvmStatic`（`string`/`newCall`/`client`/`toBody`/`cancel`/`cancelAll`/`reset`/`resetClient`/`dns`/`player`/`download`/`noRedirect` 等）
- `client()` 构建器补 trust-all SSL（见 TrustAll.kt）
- 新增 `resetClient()`（原版有，OkGoHelper.reloadDns 会调）
- `toBody(params: ArrayMap)`、`newCall(url, headers, ArrayMap)` —— **对齐原版擦除签名**
  （原版 Java 参数是 `androidx.collection.ArrayMap`，jar 按该签名调用）
- `cancelAll()` 无参重载（原版有）

### 2. `android/crawler/src/main/kotlin/com/github/catvod/net/TrustAll.kt`（新增）
对齐原版 `OkGoHelper.setOkHttpSsl`：信任所有证书的 `X509TrustManager` +
`HostnameVerifier`。原版默认 client 即信任所有证书，否则自签名/证书链不完整的
https 源直接 `SSLHandshakeException`。提供 `ssl()` / `trustManager` / `hostnameVerifier`。

### 3. `android/crawler/src/main/kotlin/com/github/catvod/net/Net.kt`
`defaultClient()` 同样补 trust-all SSL（JS 侧 `Connect`/`JSRuntime.fetch` 走这个 client）。

### 4. `android/crawler/src/main/kotlin/com/github/catvod/crawler/Spider.kt`
- `siteKey` 加 `@JvmField`（原版是 public 字段，jar 子类直接字段访问）
- `safeDns()`/`client()` 移入 companion object 并加 `@JvmStatic`
  （jar 内 `Spider.client()` 是静态调用）

### 5. `android/crawler/src/main/kotlin/com/github/catvod/Proxy.kt`
`set`/`getPort`/`getUrl` 加 `@JvmStatic`。`JarLoader.injectProxyPort` 反射
`getMethod("set", int).invoke(null, port)` 注入 jar 内 Proxy 端口，也依赖静态方法。

### 6. `android/crawler/src/main/kotlin/com/github/catvod/crawler/SpiderDebug.kt`
`log(Throwable)`/`log(String)` 加 `@JvmStatic`；补回原版有的 `ec(i: Int): String`。

### 7. `android/crawler/src/main/kotlin/com/mobile/js/HtmlParser.kt`
`getParseInfo` 修复 `--` 排除规则的两处 bug（对照原版 `HtmlParser.java`）：
- 原版语义：`rules = rule.split("--")` → `excludes = rules 的拷贝去掉首段` →
  `nparse_rule = rules[0]`（原始数组首段）
- 旧 Kotlin 版：`excludes = rules`（别名污染）+ `removeAt(0)` 后 `rules[0]` 取到
  **第二段**，选择器变成排除文本本身 → 海阔 `pdfa/pd` 含 `--` 的规则全部选错元素
- 另将 `split(":".toRegex())` 改为字面量 `split(":")` 并对齐原版 `split(":")` 取首段语义

### 8. `android/crawler/src/main/kotlin/com/mobile/js/JSRuntime.kt`
`loadModule` 补齐原版 `FileUtils.loadModule` 支持的三类本地模块路径
（旧版只有 `assets://` 和 `js/lib`）：
- `file://` → `LocalServer.getAddress(true) + "file/" + 路径`
- `clan://localhost/` → 同上
- `clan://<host>/<path>` → `http://<host>/file/<path>`

### 9. `android/crawler/build.gradle`
新增 `implementation "androidx.collection:collection:1.2.0"`（ArrayMap 签名所需）。

### 10. `android/app/src/main/kotlin/com/novabox/engine/SpiderEngine.kt`
`getText` 的 `OkHttp.newCall(url, null, null)` 改为二参 `newCall(url, null)`，
消除新增 ArrayMap 重载后的重载歧义风险（行为不变）。

### 11. `lib/config/config.dart`（根因 A 修复）
新增 `_absApi()`：`csp_` 前缀的 api 原样透传（类引用不是相对路径），
其余仍走 `_abs()` 按配置 base 补全；`Site.fromMap` 的 api 字段改调 `_absApi`。

### 12. `test/config_import_test.dart`
补两个回归测试：
- `csp_ api 原样透传不拼 base; 相对 js 路径仍补全`（导入路径 + firstWhere 断言 api 值）
- `相对路径 api/jar 仍按 base 补全`（确认修复没误伤相对路径补全行为）

> 旧测试全部用空 base（`Site.fromMap(map, '')`）调 `_abs`，`_abs` 直接短路，
> 且 HTTP 导入测试只断言 `sites.length` 不断言 api 值，所以这个 bug 一直漏网。

## 已验证

- Dart 侧：独立脚本复刻 `_abs`/`_absApi` 逻辑跑 6 组用例（csp_ 透传、
  完整 URL 透传、`./lib/a.js` 补全、裸文件名补全、空串）全部通过；
  jar 字段行为不变
- Kotlin 侧：用 kotlinc 2.0.21 + 真实 okhttp 4.12.0 / okio / jsoup / gson / nanohttpd jar
  编译全部改动文件 + 相关在役文件：**通过（仅弃用警告）**
- javap 字节码核对：
  - `OkHttp.string/newCall/client/toBody` 全部为 `public static final`
    （含 `newCall(String, Map, ArrayMap)` 擦除签名）
  - `Proxy.set/getPort/getUrl`、`SpiderDebug.log/ec`、`Spider.safeDns/client` 为静态
  - `Spider.siteKey` 为真实字段；`Spider.empty` 为静态字段
  - `OkHttp.client()` 字节码含 `sslSocketFactory(TrustAll.ssl(), trustManager)` + `hostnameVerifier`
- 与用户 logcat 对照：修复后 `clsKey` 应为 `AppgzGuard`（无 `http://` 前缀），
  `loadClass("com.github.catvod.spider.AppgzGuard")` 即可命中 jar 内类
- 沙箱只有 Flutter 3.0.0（Dart 2.17），项目 `config.dart` 用了 Dart 3 records，
  `flutter test` 跑不了；新增回归测试需在 Flutter 3.27.4+ 环境执行

## 构建与验证建议

1. 需要 **Flutter 3.27.4+（Dart ≥3.4）**（项目 pubspec 要求）
2. Android 侧：`flutter build apk` 或 Android Studio 直接构建
3. 验证点：
   - 导入饭太硬（或任意含 csp_ 源的配置）→ 首页/搜索应出影视结果
   - logcat 过滤：`adb logcat -s SpiderLog:D | grep echo-`
   - 修复生效的标志：`echo-getSpider loading sp: 瓜子` 后**不再**出现
     `clsKey=http://…` 的 ClassNotFound（clsKey 应只剩 `AppgzGuard` 这类纯类名）
   - 若 jar 类能加载但源仍空，看 `SpiderLoader.invoke` 日志里的具体站点报错
4. Dart 测试：`flutter test`（含新增的两个回归测试）

## 日志里另一个值得留意的现象（非当前阻塞项）

用户 logcat 中 PID 从 9291 变为 14158（进程被杀后重启），时间点在主 jar
`Init` 初始化前后。饭太硬保护 jar 含「包名不匹配 + killProcess」逻辑，
其期望包名是 `com.novabox.flutter.jun`（见 `JarLoader.isProtectedInitDex`），
与本应用 `com.novabox.flutter` 不一致。现有 `initProtectedJar()` 反射旁路
（直接取 `get()` 单例并注入 Context 字段 `c`，不调用 jar 自己的 `init`）
可绕过大部分校验；若重启仍频繁发生，可观察是否有闪退后再自动恢复，
暂不影响数据加载链路。

## 未改动部分（与原版核对一致，无需动）

quickjs wrapper 源码与 .so（md5 与原版完全一致）、8 个 js 资源（net.js/模板.js/cat.js 等）、
JsSpider/JsLoader/JarLoader/SpiderApi/SpiderLoader/Async/Crypto/Trans/Json/Connect、
LocalServer、Dart 侧其余代码。
