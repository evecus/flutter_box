import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// 全局焦点环 (TV 模式): 叠在整个 Navigator 之上, 跟随 [FocusManager.primaryFocus]
/// 绘制一圈醒目的描边 + 光晕.
///
/// 为什么做成全局的:
///   各页面用的控件五花八门 (ListTile / IconButton / Chip / TextField / Switch / 自绘卡片),
///   Material 默认的焦点态只是一层很淡的半透明叠色, 电视 3 米外几乎看不见; 逐个控件改装饰
///   既改不完也容易漏. 这里统一按"当前焦点节点的屏幕矩形"画环, 对所有可聚焦控件一视同仁,
///   并带平滑移动动画, 滚动时也能跟住 (每帧重新取矩形).
class TvFocusRing extends StatefulWidget {
  final Widget child;

  const TvFocusRing({super.key, required this.child});

  @override
  State<TvFocusRing> createState() => _TvFocusRingState();
}

class _TvFocusRingState extends State<TvFocusRing> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Rect? _current;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Rect? _targetRect() {
    final node = FocusManager.instance.primaryFocus;
    if (node == null || node is FocusScopeNode || !node.hasPrimaryFocus) return null;
    final ctx = node.context;
    if (ctx == null || !ctx.mounted) return null;
    final ro = ctx.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return null;
    final r = node.rect;
    if (r.isEmpty || !r.isFinite) return null;
    final size = MediaQuery.sizeOf(context);
    // 近乎整屏的"容器型"焦点节点 (兜底 Focus 等) 不画环.
    if (r.width > size.width * 0.9 && r.height > size.height * 0.8) return null;
    return r;
  }

  void _onTick(Duration _) {
    final target = _targetRect();
    if (target == null) {
      if (_current != null) setState(() => _current = null);
      return;
    }
    final cur = _current;
    Rect next;
    if (cur == null) {
      next = target;
    } else {
      next = Rect.lerp(cur, target, 0.42)!;
      if ((next.left - target.left).abs() < 0.5 &&
          (next.top - target.top).abs() < 0.5 &&
          (next.right - target.right).abs() < 0.5 &&
          (next.bottom - target.bottom).abs() < 0.5) {
        next = target;
      }
    }
    if (next != cur) setState(() => _current = next);
  }

  @override
  Widget build(BuildContext context) {
    final rect = _current;
    return Stack(
      textDirection: TextDirection.ltr,
      children: [
        Positioned.fill(child: widget.child),
        if (rect != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _RingPainter(
                  rect,
                  glow: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  final Rect rect;
  final Color glow;

  const _RingPainter(this.rect, {required this.glow});

  @override
  void paint(Canvas canvas, Size size) {
    final rrect = RRect.fromRectAndRadius(rect.inflate(3), const Radius.circular(12));
    // 外层光晕
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = Color.lerp(glow, Colors.white, 0.35)!.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    // 实心白环
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.rect != rect || old.glow != glow;
}
