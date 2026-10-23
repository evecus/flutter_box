import 'package:flutter/material.dart';

import '../tv/tv_focus.dart';
import '../tv/tv_mode.dart';
import 'danmaku_api.dart';
import 'danmaku_manager.dart';
import 'danmaku_settings.dart';

/// 弹幕对话框集合 (移植自 NovaTV):
///   DanmuFullSettingDialog — 开关/速度/字号/行数/透明度/行间距/顶边距
///   DanmuApiDialog        — 弹幕地址 (默认/自定义)
///   SearchDanmuDialog     — 云搜候选列表
class DanmuDialogs {
  DanmuDialogs._();

  // ---------------- 弹幕全量设置 ----------------

  static const List<double> _speeds = [2.4, 1.8, 1.5, 1.0];
  static const List<String> _speedNames = ['超慢', '慢', '适中', '快'];

  static Future<void> showFullSetting(BuildContext context) async {
    final tv = TvMode.isTV.value;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _FullSettingDialog(tv: tv),
    );
  }

  // ---------------- 弹幕地址 ----------------

  static Future<void> showApi(BuildContext context) async {
    final tv = TvMode.isTV.value;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _ApiDialog(tv: tv),
    );
  }

  // ---------------- 云搜 ----------------

  static Future<void> showSearch(
    BuildContext context, {
    required String initialWord,
    required String episode,
    required ValueChanged<String> onLoaded,
  }) async {
    final tv = TvMode.isTV.value;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _SearchDialog(
        tv: tv,
        initialWord: initialWord,
        episode: episode,
        onLoaded: onLoaded,
      ),
    );
  }
}

/// ---------------- 弹幕全量设置弹窗 ----------------

class _FullSettingDialog extends StatefulWidget {
  final bool tv;
  const _FullSettingDialog({required this.tv});

  @override
  State<_FullSettingDialog> createState() => _FullSettingDialogState();
}

class _FullSettingDialogState extends State<_FullSettingDialog> {
  late bool _open;
  late double _speed;
  late double _sizeScale;
  late int _maxLine;
  late double _alpha;
  late int _lineSpacing;
  late int _topMargin;

  @override
  void initState() {
    super.initState();
    final s = DanmuSettings.instance;
    _open = s.open;
    _speed = s.speed;
    _sizeScale = s.sizeScale;
    _maxLine = s.maxLine;
    _alpha = s.alpha;
    _lineSpacing = s.lineSpacingPx;
    _topMargin = s.topMarginPx;
  }

  Future<void> _applyOpen(bool v) async {
    setState(() => _open = v);
    await DanmuSettings.instance.setOpen(v);
    DanmakuManager.instance.applySettings();
  }

  Future<void> _applySpeed(double v) async {
    setState(() => _speed = v);
    await DanmuSettings.instance.setSpeed(v);
    DanmakuManager.instance.applySettings();
  }

  Future<void> _applySize(double v) async {
    setState(() => _sizeScale = v);
    await DanmuSettings.instance.setSizeScale(v);
    DanmakuManager.instance.applySettings();
  }

  Future<void> _applyLine(int v) async {
    setState(() => _maxLine = v);
    await DanmuSettings.instance.setMaxLine(v);
    DanmakuManager.instance.applySettings();
  }

  Future<void> _applyAlpha(double v) async {
    setState(() => _alpha = v);
    await DanmuSettings.instance.setAlpha(v);
    DanmakuManager.instance.applySettings();
  }

  Future<void> _applySpacing(int v) async {
    setState(() => _lineSpacing = v);
    await DanmuSettings.instance.setLineSpacingPx(v);
    DanmakuManager.instance.applySettings();
  }

  Future<void> _applyTopMargin(int v) async {
    setState(() => _topMargin = v);
    await DanmuSettings.instance.setTopMarginPx(v);
    DanmakuManager.instance.applySettings();
  }

  @override
  Widget build(BuildContext context) {
    final tv = widget.tv;
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Text('弹幕设置', style: TextStyle(fontSize: tv ? 22 : 20)),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      content: SizedBox(
        width: tv ? 560 : 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _label('弹幕开关', tv),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: _chip(tv, '开启', _open, () => _applyOpen(true)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _chip(tv, '关闭', !_open, () => _applyOpen(false)),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              _label('滚动速度', tv),
              const SizedBox(height: 6),
              Row(
                children: [
                  for (var i = 0; i < DanmuDialogs._speedNames.length; i++) ...[
                    if (i > 0) const SizedBox(width: 6),
                    Expanded(
                      child: _chip(
                        tv,
                        DanmuDialogs._speedNames[i],
                        (_speed - DanmuDialogs._speeds[i]).abs() < 0.001,
                        () => _applySpeed(DanmuDialogs._speeds[i]),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              _label('弹幕字号', tv),
              _floatStepper(tv, _sizeScale, 0.4, 2.4, 0.1,
                  (v) => '${v.toStringAsFixed(1)}x', _applySize),
              const SizedBox(height: 10),
              _label('弹幕行数', tv),
              _intStepper(tv, _maxLine, 1, 30, 1, (v) => '$v行', _applyLine),
              const SizedBox(height: 10),
              _label('弹幕透明度', tv),
              _floatStepper(tv, _alpha, 0.1, 1.0, 0.1,
                  (v) => '${(v * 100).round()}%', _applyAlpha),
              const SizedBox(height: 10),
              _label('行间距', tv),
              _intStepper(tv, _lineSpacing, 0, 32, 4, (v) => '${v}px', _applySpacing),
              const SizedBox(height: 10),
              _label('顶部边距', tv),
              _intStepper(tv, _topMargin, 0, 300, 20, (v) => '${v}px', _applyTopMargin),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
      actions: [
        if (tv)
          TvButton(
            label: '完成',
            height: 44,
            fontSize: 16,
            onTap: () => Navigator.of(context).pop(),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
      ],
    );
  }

  Widget _label(String text, bool tv) => Text(
        text,
        style: TextStyle(
          fontSize: tv ? 17 : 14,
          color: Colors.white70,
        ),
      );

  Widget _chip(bool tv, String text, bool selected, VoidCallback onTap) {
    if (tv) {
      return TvButton(
        label: text,
        selected: selected,
        height: 46,
        fontSize: 16,
        onTap: onTap,
      );
    }
    final color = Theme.of(context).colorScheme.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? color : const Color(0xFF3A3A3A),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 14,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            color: selected ? Colors.white : Colors.white70,
          ),
        ),
      ),
    );
  }

  Widget _floatStepper(bool tv, double value, double min, double max, double step,
      String Function(double) format, Future<void> Function(double) onSet) {
    return _StepperRow(
      tv: tv,
      valueText: format(value),
      onMinus: value > min + 0.001
          ? () => onSet(double.parse((value - step).toStringAsFixed(1)).clamp(min, max).toDouble())
          : null,
      onPlus: value < max - 0.001
          ? () => onSet(double.parse((value + step).toStringAsFixed(1)).clamp(min, max).toDouble())
          : null,
    );
  }

  Widget _intStepper(bool tv, int value, int min, int max, int step,
      String Function(int) format, Future<void> Function(int) onSet) {
    return _StepperRow(
      tv: tv,
      valueText: format(value),
      onMinus: value > min ? () => onSet((value - step).clamp(min, max).toInt()) : null,
      onPlus: value < max ? () => onSet((value + step).clamp(min, max).toInt()) : null,
    );
  }
}

class _StepperRow extends StatelessWidget {
  final bool tv;
  final String valueText;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;

  const _StepperRow({
    required this.tv,
    required this.valueText,
    this.onMinus,
    this.onPlus,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Expanded(child: _stepButton(tv, '－', onMinus)),
          SizedBox(
            width: 90,
            child: Text(
              valueText,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: tv ? 18 : 15,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          Expanded(child: _stepButton(tv, '＋', onPlus)),
        ],
      ),
    );
  }

  Widget _stepButton(bool tv, String text, VoidCallback? onTap) {
    if (tv) {
      return TvButton(
        label: text,
        height: 44,
        fontSize: 18,
        onTap: onTap,
      );
    }
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white70,
        side: const BorderSide(color: Colors.white24),
      ),
      child: Text(text, style: const TextStyle(fontSize: 18)),
    );
  }
}

/// ---------------- 弹幕地址弹窗 ----------------

class _ApiDialog extends StatefulWidget {
  final bool tv;
  const _ApiDialog({required this.tv});

  @override
  State<_ApiDialog> createState() => _ApiDialogState();
}

class _ApiDialogState extends State<_ApiDialog> {
  late final TextEditingController _input;
  late String _hint;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: DanmuSettings.instance.customApi);
    final display = DanmakuApi.getDisplayApiUrl();
    _hint = display.isEmpty ? '请输入弹幕搜索地址' : display;
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _saveCustom() async {
    await DanmuSettings.instance.setCustomApi(_input.text);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _saveDefault() async {
    await DanmuSettings.instance.setUseDefault(true);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final tv = widget.tv;
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Text('弹幕地址', style: TextStyle(fontSize: tv ? 22 : 20)),
      content: SizedBox(
        width: tv ? 560 : 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _input,
              style: TextStyle(fontSize: tv ? 17 : 14),
              decoration: InputDecoration(
                hintText: _hint,
                hintStyle: const TextStyle(fontSize: 13, color: Colors.white38),
                filled: true,
                fillColor: const Color(0xFF2C2C2C),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: (_) => _saveCustom(),
            ),
            const SizedBox(height: 8),
            Text(
              '留空并确定 = 使用默认地址; 支持 {name}/{episode} 占位',
              style: TextStyle(fontSize: tv ? 14 : 12, color: Colors.white54),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: tv
                      ? TvButton(
                          label: '恢复默认',
                          height: 46,
                          fontSize: 16,
                          onTap: _saveDefault,
                        )
                      : OutlinedButton(
                          onPressed: _saveDefault,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white70,
                            side: const BorderSide(color: Colors.white24),
                          ),
                          child: const Text('恢复默认'),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: tv
                      ? TvButton(
                          label: '确定',
                          height: 46,
                          fontSize: 16,
                          onTap: _saveCustom,
                        )
                      : ElevatedButton(
                          onPressed: _saveCustom,
                          child: const Text('确定'),
                        ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// ---------------- 云搜弹窗 ----------------

class _SearchDialog extends StatefulWidget {
  final bool tv;
  final String initialWord;
  final String episode;
  final ValueChanged<String> onLoaded;

  const _SearchDialog({
    required this.tv,
    required this.initialWord,
    required this.episode,
    required this.onLoaded,
  });

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  late final TextEditingController _input;
  late final FocusNode _inputFocus;
  List<DanmuSearchResult> _results = [];
  bool _loading = false;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    _input = TextEditingController(text: widget.initialWord);
    _inputFocus = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // 对照 NovaTV: 打开即用当前片名自动搜索.
      _search(_input.text.trim());
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  Future<void> _search(String word) async {
    if (word.isEmpty) {
      _toast('输入内容不能为空');
      return;
    }
    setState(() {
      _loading = true;
      _results = [];
    });
    final results = await DanmakuApi.searchList(word, widget.episode);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _searched = true;
      _results = results;
    });
    if (results.isEmpty) _toast('未查询到匹配弹幕');
  }

  Future<void> _load(DanmuSearchResult result) async {
    setState(() => _loading = true);
    final source = await DanmakuApi.loadSearchResult(result);
    if (!mounted) return;
    if (source.isEmpty) {
      setState(() => _loading = false);
      _toast('弹幕加载失败');
      return;
    }
    Navigator.of(context).pop();
    widget.onLoaded(source);
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tv = widget.tv;
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: Text('弹幕云搜', style: TextStyle(fontSize: tv ? 22 : 20)),
      contentPadding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      content: SizedBox(
        width: tv ? 560 : 360,
        height: tv ? 460 : 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    style: TextStyle(fontSize: tv ? 17 : 14),
                    decoration: InputDecoration(
                      hintText: '输入片名搜索弹幕',
                      hintStyle: const TextStyle(fontSize: 13, color: Colors.white38),
                      filled: true,
                      fillColor: const Color(0xFF2C2C2C),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: _search,
                  ),
                ),
                const SizedBox(width: 10),
                tv
                    ? TvButton(
                        label: '搜索',
                        height: 48,
                        fontSize: 16,
                        onTap: () => _search(_input.text.trim()),
                      )
                    : ElevatedButton(
                        onPressed: () => _search(_input.text.trim()),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(0, 48),
                        ),
                        child: const Text('搜索'),
                      ),
              ],
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Expanded(
                child: Center(
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  ),
                ),
              )
            else if (_results.isEmpty && _searched)
              const Expanded(
                child: Center(
                  child: Text('未查询到匹配弹幕',
                      style: TextStyle(color: Colors.white54)),
                ),
              )
            else
              Expanded(
                child: ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (ctx, i) {
                    final r = _results[i];
                    if (tv) {
                      return TvFocusable(
                        radius: 8,
                        focusBackground: false,
                        onTap: () => _load(r),
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4),
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0x6C3D3D3D),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            r.name.isEmpty ? r.url : r.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
                      );
                    }
                    return ListTile(
                      dense: true,
                      title: Text(
                        r.name.isEmpty ? r.url : r.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 14),
                      ),
                      onTap: () => _load(r),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        if (tv)
          TvButton(
            label: '取消',
            height: 44,
            fontSize: 16,
            onTap: () => Navigator.of(context).pop(),
          )
        else
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
      ],
    );
  }
}
