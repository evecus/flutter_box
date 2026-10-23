import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../config/config.dart';
import '../data/history.dart';
import '../data/home_prefs.dart';
import '../data/watch_progress.dart';
import '../engine/engine_channel.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _urlCtrl = TextEditingController();
  String _status = '';
  bool _statusIsError = false;
  bool _busy = false;
  String _engine = '';
  List<ConfigLine> _lines = const [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final url = await Config.loadUrl();
    _lines = await Config.loadLines();
    if (!mounted) return;
    setState(() => _urlCtrl.text = url);
    await _refreshInfo();
  }

  Future<void> _refreshInfo() async {
    final ip = await EngineChannel.getIp();
    final proxy = await EngineChannel.proxyUrl(true);
    if (!mounted) return;
    setState(() {
      _engine = ip.isEmpty ? '引擎未就绪' : '$ip\n$proxy';
    });
  }

  void _say(String msg, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _status = msg;
      _statusIsError = error;
    });
  }

  void _setBusy(bool busy) {
    if (!mounted) return;
    setState(() => _busy = busy);
  }

  /// 导入并应用一个配置 (URL 或直接粘贴的 JSON 文本).
  /// 返回是否成功.
  Future<bool> _applyConfig(String input, {bool keepLines = false}) async {
    final text = input.trim();
    if (text.isEmpty) {
      await Config.saveUrl('');
      await Config.saveLines(const [], '');
      Config.markLoaded(null);
      setState(() {
        _busy = false;
        _lines = const [];
      });
      _say('配置已清除');
      return false;
    }
    setState(() {
      _busy = true;
      _statusIsError = false;
    });
    _say('应用配置中...');
    final (ok, msg) = await Config.applyInput(input, keepLines: keepLines ? _lines : const []);
    if (!mounted) return false;
    _setBusy(false);
    _lines = Config.loaded?.lines ?? const [];
    setState(() {});
    _say(msg, error: !ok);
    return ok;
  }

  Future<void> _changeConfig() => _applyConfig(_urlCtrl.text);

  /// 首页列表数据选择 (对照原版 ModelSettingFragment 的 SelectDialog).
  Future<void> _pickHomeRec() async {
    final current = HomePrefs.homeRec;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('请选择首页列表数据'),
        children: [
          for (var mode = 0; mode < 3; mode++)
            RadioListTile<int>(
              value: mode,
              groupValue: current,
              title: Text(HomePrefs.recName(mode)),
              onChanged: (v) => Navigator.of(ctx).pop(v),
            ),
        ],
      ),
    );
    if (picked == null || picked == current) return;
    await HomePrefs.setHomeRec(picked);
  }

  /// 导入对话框: 支持远程 URL / 直接粘贴 JSON 文本 / 剪贴板.
  Future<void> _showImportDialog() async {
    final ctrl = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入 TVBox 配置'),
        content: SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText: '配置地址 (https://...) 或配置 JSON 内容\n支持 {"urls":[...]} 多线路集合',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    final t = (data?.text ?? '').trim();
                    if (t.isNotEmpty) ctrl.text = t;
                  },
                  icon: const Icon(Icons.content_paste, size: 18),
                  label: const Text('从剪贴板粘贴'),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (input == null || input.isEmpty) return;
    _urlCtrl.text = input;
    await _applyConfig(input);
  }

  /// 切换到集合配置中的另一条线路 (对照原版 "配置地址" 列表).
  Future<void> _switchLine(ConfigLine line) async {
    if (_busy) return;
    if (line.url == Config.loaded?.url) {
      _say('当前已在 "${line.name}" 线路');
      return;
    }
    final ok = await _applyConfig(line.url, keepLines: true);
    if (ok && mounted) {
      setState(() => _urlCtrl.text = line.url);
    }
  }

  Future<void> _clearCache() async {
    setState(() {
      _busy = true;
      _statusIsError = false;
    });
    _say('清理中...');
    await EngineChannel.unload();
    try {
      final support = await getApplicationSupportDirectory();
      final jar = File('${support.path}/main.jar');
      if (jar.existsSync()) jar.deleteSync();
    } catch (_) {}
    await Config.saveUrl(_urlCtrl.text.trim());
    if (!mounted) return;
    setState(() {
      Config.markLoaded(null);
      _busy = false;
      _statusIsError = false;
    });
    _say('已清理 jar/js 引擎缓存');
    _engine = '';
    await _refreshInfo();
  }

  Future<void> _clearData() async {
    setState(() {
      _busy = true;
      _statusIsError = false;
    });
    _say('清除数据中...');
    await History.clearAll();
    await WatchProgress.clearAll();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('favorites');
    if (!mounted) return;
    setState(() {
      _busy = false;
      _statusIsError = false;
    });
    _say('收藏/历史/播放进度已清除');
  }

  /// 引擎日志 (Kotlin 侧 Loge 写 filesDir/engine.log, path_provider 的
  /// getApplicationSupportDirectory 在 Android 上即 filesDir).
  Future<String> _readEngineLog() async {
    try {
      final support = await getApplicationSupportDirectory();
      final file = File('${support.path}/engine.log');
      if (!file.existsSync()) return '';
      return await file.readAsString();
    } catch (_) {
      return '';
    }
  }

  Future<void> _showEngineLog() async {
    final text = await _readEngineLog();
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('引擎日志'),
        content: SizedBox(
          width: 320,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? '暂无日志' : text,
              style: Theme.of(ctx).textTheme.bodySmall,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: text.isEmpty
                ? null
                : () {
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      const SnackBar(content: Text('日志已复制到剪贴板')),
                    );
                  },
            child: const Text('复制'),
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          const Text('配置', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          TextField(
            controller: _urlCtrl,
            decoration: InputDecoration(
              hintText: '远程配置地址 / 配置 JSON',
              isDense: true,
              border: const OutlineInputBorder(),
              suffixIcon: _busy
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : Icon(Icons.refresh_rounded, color: theme.colorScheme.primary),
            ),
            onSubmitted: (_) => _changeConfig(),
          ),
          const SizedBox(height: 6),
          FilledButton(
            onPressed: _busy ? null : _changeConfig,
            child: const Text('更换配置'),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _busy ? null : _showImportDialog,
            child: const Text('导入 TVBox 配置 (URL / JSON)'),
          ),
          if (_status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                _status,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _statusIsError ? theme.colorScheme.error : null,
                ),
              ),
            ),
          if (_lines.isNotEmpty) ...[
            const Divider(height: 24),
            Text('线路 (${_lines.length})', style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            ..._lines.map((line) => RadioListTile<String>(
                  value: line.url,
                  groupValue: Config.loaded?.url ?? '',
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(line.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(line.url, maxLines: 1, overflow: TextOverflow.ellipsis),
                  onChanged: (_) => _switchLine(line),
                )),
          ],
          const Divider(height: 24),
          const Text('首页', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          // 原版 ModelSettingFragment.llHomeRec: 首页列表数据三选一.
          ValueListenableBuilder<int>(
            valueListenable: HomePrefs.recNotifier,
            builder: (ctx, rec, _) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.home_outlined),
              title: const Text('首页列表数据'),
              subtitle: Text(HomePrefs.recName(rec)),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickHomeRec,
            ),
          ),
          const Divider(height: 24),
          const Text('引擎', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(_engine.isEmpty ? '...' : _engine,
              style: theme.textTheme.bodySmall),
          const SizedBox(height: 6),
          Row(
            children: [
              OutlinedButton(onPressed: _busy ? null : _clearCache, child: const Text('清理引擎缓存')),
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _busy ? null : _clearData, child: const Text('清除观看数据')),
            ],
          ),
          const SizedBox(height: 6),
          OutlinedButton.icon(
            onPressed: _busy ? null : _showEngineLog,
            icon: const Icon(Icons.article_outlined, size: 18),
            label: const Text('查看引擎日志'),
          ),
          const Divider(height: 24),
          const Text('关于', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(
            'NovaBox Flutter/Kotlin 混合版\n'
            '播放器: media_kit (mpv)\n'
            '爬虫引擎: QuickJS + OkHttp (Kotlin)\n'
            '本地代理端口: 9978',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
