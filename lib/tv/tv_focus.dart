import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tv_mode.dart';

/// 遥控器可聚焦控件: 焦点态为白色 2px 描边 + 轻微放大
/// (对照原版 NovaTV res/drawable/shape_user_focus: focused 时白色 stroke,
///  背景 #6C3D3D3D; 未聚焦无描边).
///
/// 同时兼容触摸: onTap 对点击与遥控器 OK/确定键 (enter/select/space/gameButtonA)
/// 都生效. 手机模式下行为退化为普通 InkWell (无额外焦点装饰).
class TvFocusable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 进入页面时自动获取焦点 (TV 模式下用于把焦点放到入口控件).
  final bool autofocus;

  /// 描边圆角.
  final double radius;

  /// 焦点态缩放比例.
  final double focusScale;

  /// 焦点描边外的留白 (避免描边被相邻控件裁切).
  final double focusMargin;

  /// 是否显示焦点背景色 (NovaTV 焦点态带 #6C3D3D3D 半透明底).
  final bool focusBackground;

  /// 手机模式也强制启用焦点装饰 (调试用).
  final bool force;

  const TvFocusable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.autofocus = false,
    this.radius = 10,
    this.focusScale = 1.04,
    this.focusMargin = 1,
    this.focusBackground = true,
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
    return Focus(
      focusNode: _node,
      canRequestFocus: true,
      onFocusChange: (v) => setState(() => _focused = v),
      onKeyEvent: _onKey,
      child: GestureDetector(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _focused ? widget.focusScale : 1.0,
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: EdgeInsets.all(widget.focusMargin),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              border: _focused
                  ? Border.all(color: Colors.white, width: 2)
                  : null,
              color: _focused && widget.focusBackground
                  ? const Color(0x6C3D3D3D)
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// 遥控器按钮: 图标 + 文字, 焦点态白描边 (对照 NovaTV 顶部图标按钮 /
/// 搜索页 tvSearch / tvClear 按钮: shape_user_focus 背景 + 居中文字).
class TvButton extends StatelessWidget {
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
    this.height = 44,
    this.fontSize = 14,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return TvFocusable(
      onTap: onTap,
      autofocus: autofocus,
      radius: 8,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? scheme.primaryContainer : const Color(0x6C3D3D3D),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: fontSize + 4, color: Colors.white70),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: selected ? FontWeight.bold : FontWeight.w500,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
