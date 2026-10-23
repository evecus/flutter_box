# NovaBox (Flutter + Kotlin)

TVBox-flavored movie app, rebuilt as a Flutter/Kotlin hybrid. Android only, touch only.

## Architecture

- **Flutter (Dart)** - all UI, players (media_kit/mpv), config, storage (shared_preferences).
- **Kotlin (native)** - crawler ecosystem only:
  - `android/quickjs` - QuickJS JNI wrapper (verbatim from the original NovaBox project, must not be modified).
  - `android/crawler` - spider engine: `com.mobile.js.*` (JS bridge, QuickJS runtime, okhttp, crypto, trans),
    `com.github.catvod.*` (Spider, JsLoader, JarLoader, LocalServer on port 9978, proxy routing).
  - `android/app` - `NovaboxApplication` (QuickJSLoader + LocalServer bootstrap), `MainActivity`,
    `com.novabox.engine.SpiderEngine` - the `novabox/engine` MethodChannel.

## Engine channel contract (`novabox/engine`)

- `loadSites { sites: json } -> bool` - accepts TVBox sites entries (`key,type,api,ext,jar`).
  Spider 路由对照原版 `ApiConfig.getCSP`: api 以 `.js` 结尾走 jsLoader, 其余 (含 `csp_XXX`) 走 jarLoader.
- `loadMainJar { jar: localPath } -> bool` - initializes a previously downloaded main jar (同步加载).
- `invoke { siteKey, method, arg } -> json string` - spider calls:
  `home` (arg "true"/"false" = filter) / `homeVod` / `category` / `detail` / `search` / `player` / `live` / `action`.
- `proxyUrl { local } -> string` - local proxy base, always `.../proxy?do=js`.
- `getText { url } -> string` - OkHttp 拉取文本, 支持 IDN 中文域名 (Dart http 失败时的兜底).
- `decrypt { text, key } -> string` - 原版 `FindResult` 的配置解密 (8位**+base64 / 2423 AES-CBC / `;pk;` AES-ECB).
- `download { url, path } -> bool` - OkHttp 下载二进制 (jar), 支持 IDN 中文域名.
- `getIp`, `stopAll`, `unload`.

## Config format

Standard TVBox config: `{"spider": "url;md5;...", "sites": [{"key": ..., "type": 0|3|4, "api": ..., "ext": ..., "jar": ...}, ...]}`.
The app downloads the main jar internally and hands the local path to the engine.
Note: the spider URL is fetched as-is — modern configs deliberately disguise the jar as
`.jpg`/other extensions (the bytes are a real APK with `classes.dex`, md5 matches), so
extension-based filtering would kill every source.

导入 (设置页) 支持的形式, 均对照原版 NovaBox `ApiConfig`:

- 远程 URL (缺省自动补 `http://`), 或直接粘贴配置 JSON 文本 (`{`/`[` 开头或整体 Base64 长串时不走网络, 其余按原版规则补 `http://` 拉取);
- `{"urls": [{"name": ..., "url": ...}, ...]}` 多线路集合: 自动切到第一条, 设置页"线路"列表可切换;
- `{"url": "..."}` 单线包装跳转 (最多 6 层);
- 加密配置: `[A-Za-z0-9]{8}**` + Base64 / `2423` 开头 AES-CBC / `;pk;` 密钥 AES-ECB (引擎侧解密);
- 整体 Base64 / `@` 拼接的多段 Base64 / 带 `//` 注释的轻量 JSON.

主 jar 加载失败不会静默: 具体原因 (下载失败/DexClassLoader 失败/存储目录不可用) 会显示在
设置页状态栏; jar 失败但存在 js/自带 jar 的源时配置仍可导入.

## Milestones

- **M1** - engine wiring: config apply, js/jar source listing, browse/detail/search pages, direct playback.
- **M2** - full play chain: `PlayResolver` handles `proxy://` (js own proxy), parse+jx, spider headers;
  watch progress (resume, per site+vod), history recording, next-episode.
- **M2.5** - 首页链路: source picker + 首页推荐 grid + 分类入口 → 详情 → 播放;
  全站搜索 (并行搜索所有源, 精确命中置顶, 源标签).
- **M3** - library features: favorites, watch history UI, source switching, settings page
  (config change / TVBox 配置导入 (URL / 剪贴板) / engine cache clear / data wipe), bottom navigation shell.

## Page chain

首页 (源选择 + 推荐 + 分类入口) → 全站搜索 / 分类浏览 → 详情页 (选集 / 收藏 / 换源) → 播放页
(续播 / 下集 / headers proxy:// 与 jx 化解析). 直播暂未实现.

## Run

Open `novabox_flutter/` with `flutter pub get` then `flutter run` on Android
(minSdk 24, compileSdk 35, Gradle 8.13 wrapper included).

## CI

`.github/workflows/build_arm64.yml` builds the release APK **arm64 only**
(`NOVA_ABI_FILTERS=arm64-v8a` overrides the default armeabi-v7a fallback locally).
Put this directory at the repo root when pushing (workflow path assumption).

## TV 模式 (手机 / TV 同一 APK 共存)

TV 界面与遥控操作逻辑对照原版 NovaTV (`com.github.tvbox.osc`) 移植:

- **检测**: Kotlin `MainActivity` 的 `novabox/platform` 通道返回 `isTV`
  (`leanback` feature 或 `UI_MODE_TYPE_TELEVISION`); Dart 侧 `lib/tv/tv_mode.dart`
  另有手动覆盖 (SharedPreferences `tv_mode`: `auto`/`on`/`off`, 设置页 "界面 → TV 模式").
  TV 模式启动时强制横屏 (对照原版各 Activity `sensorLandscape`).
- **Manifest**: `leanback`/`touchscreen` 均 `required="false"`, MainActivity 增加
  `LEANBACK_LAUNCHER` category, 电视桌面可直接启动.
- **布局切换** (`TvMode.isTV` 驱动, 整树重建):
  - 根页面: 底部导航 → 左侧 `NavigationRail` (初始焦点在导航栏, 右键进内容);
  - 首页: 大海报网格 (200px / 0.66) + 大字号, 顶栏 chip / 搜索入口 / 收藏历史全部可聚焦;
    选择器 (线路/站源) 由底部弹层改为可聚焦对话框; MENU 键短按换源, 长按 2s 进设置
    (对照 `HomeActivity.dispatchKeyEvent`);
  - 搜索页 (对照 `SearchActivity` + `SearchKeyboard`): TV 三栏 ——
    左栏 = 指定搜索源按钮 + 输入框 + 搜索/清空按钮 + 屏显键盘 (远程搜索/删除 + A-Z + 0-9,
    每行 6 键, 遥控器移动焦点输入); 中栏 = 热词 (豆瓣热播片名, 聚焦即搜);
    右栏 = 源筛选 + 结果, 搜索完成后焦点自动落到首条结果;
  - 详情页: 选集按钮放大可聚焦, 首集自动获焦 (进页按 OK 即播);
  - 播放页: 无 AppBar, 视频占满 + 顶部悬浮 (返回/标题/下一集) + 底部自制控制条
    (播放暂停 / 快退快进 10s / 进度滑条, 全部可聚焦) + 横排选集;
  - 收藏/历史/设置: 列表项焦点白描边, 按钮放大, 设置页动作按钮可聚焦.
- **焦点样式**: `lib/tv/tv_focus.dart` `TvFocusable` —— 焦点态白色 2px 描边 + 4% 放大
  (对照原版 `res/drawable/shape_user_focus`), OK/确定键 (enter/select/space/gameButtonA)
  与触摸点击等价; 手机模式自动退化为普通 `InkWell`.
