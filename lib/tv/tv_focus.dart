import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tv_mode.dart';

/// 遥控器可聚焦控件 (TV 焦点效果对照 dart_simple_live 的 HighlightWidget):
///   焦点态 = AnimatedScale 1.1 (200ms) + 主题色光晕阴影 (blur 10 / spread 2)
///            + 白色填充; 无描边.
/// 同时兼容触摸: onTap 对点击与遥控器 OK/确定键 (enter/select/space/gameButtonA)
/// 都生效. 手机模式下行为退化为普通 InkWell (无额外焦点装饰).
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 进入页面时自动获取焦点 (TV 模式下用于把焦点放到入口控件).
  final bool autofocus;

  /// 焦点态缩放比例 (参考实现 1.1).
  final double focusScale;

  /// 焦点态填充色 (参考实现白色; 子部件自带深色底时可设为 false 关闭).
  final bool focusBackground;
  final Color? focusColor;

  /// 光晕颜色 (默认取主题 primary).
  final Color? glowColor;

  /// 焦点变化回调 (供 TvButton 等翻转文字颜色).
  final ValueChanged<bool>? onFocusChange;

  /// 圆角.
  final double radius;

  /// 焦点填充外的留白 (避免被相邻控件裁切).
  final double focusMargin;

  /// 手机模式也强制启用焦点装饰 (调试用).
  final bool force;

  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.focusScale = 1.05,
    this.focusBackground = false,
    this.focusColor,
    this.glowColor,
    this.onFocusChange,
    this.radius = 10,
    this.focusMargin = 1,
    this.force = false,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  final _node = FocusNode(debugLabel: 'TvFocusable');
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _node.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  void _activate() {
    widget.onTap?.call();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isSelect = key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA;
    if (!isSelect) return KeyEventResult.ignored;
    _activate();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final tv = widget.force || TvMode.isTV.value;
    if (!tv) {
      // 手机模式: 退化为普通 InkWell, 保持原有触摸交互.
      return InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        borderRadius: BorderRadius.circular(widget.radius),
        child: widget.child,
      );
    }
    // 焦点高亮由全局 TvFocusRing 统一绘制 (白色描边 + 光晕, 不会被子控件的不透明背景盖住,
    // 也不会被 ListView/GridView 裁切). 这里只负责: 可聚焦 + OK 键触发 + 轻微放大.
    return Focus(
      focusNode: _node,
      canRequestFocus: true,
      onFocusChange: (v) {
        setState(() => _focused = v);
        widget.onFocusChange?.call(v);
      },
      onKeyEvent: _onKey,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _focused ? widget.focusScale : 1.0,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          child: Container(
            margin: EdgeInsets.all(widget.focusMargin),
            decoration: _focused && widget.focusBackground
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(widget.radius),
                    color: widget.focusColor ?? Colors.white,
                  )
                : null,
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// 遥控器按钮: 图标 + 文字 (对照 dart_simple_live 的 HighlightButton):
/// 焦点/选中态 = 白底黑字, 平时 = 深灰底白字.
class TvButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool autofocus;
  final bool selected;
  final double height;
  final double fontSize;

  const TvButton({
    super.key,
    required this.label,
    this.icon,
    this.onTap,
    this.autofocus = false,
    this.selected = false,
    this.height = 52,
    this.fontSize = 16,
  });

  @override
  State<TvButton> createState() => _TvButtonState();
}

class _TvButtonState extends State<TvButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final active = _focused || widget.selected;
    return TvFocusable(
      onTap: widget.onTap,
      autofocus: widget.autofocus,
      radius: 8,
      onFocusChange: (v) => setState(() => _focused = v),
      child: Container(
        height: widget.height,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? Colors.white : const Color(0x6C3D3D3D),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.icon != null) ...[
              Icon(widget.icon,
                  size: widget.fontSize + 6,
                  color: active ? Colors.black : Colors.white70),
              const SizedBox(width: 6),
            ],
            Text(
              widget.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: widget.fontSize,
                fontWeight: active ? FontWeight.bold : FontWeight.w500,
                color: active ? Colors.black : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
