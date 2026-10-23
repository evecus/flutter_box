import 'dart:convert';

import 'package:flutter/services.dart';

/// Kotlin <-> Dart bridge. All spider work happens on the Android side
/// through `com.novabox.engine.SpiderEngine`.
class EngineChannel {
  static const MethodChannel _channel = MethodChannel('novabox/engine');

  static Future<bool> loadSites(List<Map<String, String>> sites) async {
    try {
      final json = jsonEncode(sites);
      return await _channel.invokeMethod<bool>('loadSites', {'sites': json}) ?? false;
    } catch (e) {
      return false;
    }
  }

  /// 加载主 spider jar. 返回空串表示成功, 非空为失败原因 (Kotlin 侧透传).
  static Future<String> loadMainJar(String jarPath) async {
    try {
      return await _channel.invokeMethod<String>('loadMainJar', {'jar': jarPath}) ?? '';
    } catch (e) {
      return 'loadMainJar 通道异常: $e';
    }
  }

  static Future<String> invoke(String siteKey, String method, String arg) async {
    try {
      return await _channel
              .invokeMethod<String>('invoke', {'siteKey': siteKey, 'method': method, 'arg': arg}) ??
          '';
    } catch (e) {
      return '';
    }
  }

  /// 进入/退出播放页时声明当前播放源 (对照原版 ApiConfig.setCurrentPlaySourceKey:
  /// jar 源的 do=ck 代理探测请求不带 siteKey, 原版靠"当前播放源"回退定位).
  /// 传空串 = 退出播放页 (原版 setCurrentPlaySourceKey("")).
  static Future<bool> setPlaySource(String siteKey) async {
    try {
      return await _channel.invokeMethod<bool>('setPlaySource', {'siteKey': siteKey}) ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<String> proxyUrl([bool local = true]) async {
    try {
      return await _channel.invokeMethod<String>('proxyUrl', {'local': local}) ?? '';
    } catch (e) {
      return '';
    }
  }

  static Future<String> getIp() async {
    try {
      return await _channel.invokeMethod<String>('getIp') ?? '';
    } catch (e) {
      return '';
    }
  }

  /// 引擎侧 OkHttp 拉取文本 (标准 UA + content-type charset 解码), 用于 Dart http 被反爬/编码不对时的兜底.
  static Future<String> getText(String url) async {
    try {
      return await _channel.invokeMethod<String>('getText', {'url': url}) ?? '';
    } catch (e) {
      return '';
    }
  }

  /// 原版 ApiConfig.FindResult 的加密配置解密 (8位**+base64 / 2423 AES-CBC / ;pk; AES-ECB).
  /// [key] 为 ;pk; 携带的密钥, 可空. 解密失败时原样返回.
  static Future<String> decrypt(String text, String key) async {
    try {
      return await _channel.invokeMethod<String>('decrypt', {'text': text, 'key': key}) ?? '';
    } catch (e) {
      return '';
    }
  }

  /// 引擎侧 OkHttp 下载二进制 (jar), 支持 IDN 中文域名. Dart http 失败时的兜底.
  static Future<bool> download(String url, String path) async {
    try {
      return await _channel.invokeMethod<bool>('download', {'url': url, 'path': path}) ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> stopAll() async {
    try {
      return await _channel.invokeMethod<bool>('stopAll') ?? false;
    } catch (e) {
      return false;
    }
  }

  static Future<bool> unload() async {
    try {
      return await _channel.invokeMethod<bool>('unload') ?? false;
    } catch (e) {
      return false;
    }
  }
}
