/// One shimmer implementation for every skeleton in the app.
///
/// 60fps budget: a single [AnimationController] per [Shimmer] subtree (use
/// one `Shimmer` around the whole skeleton *screen*, not one per row) and a
/// [ShaderMask] gradient sweep — no per-frame layout, no per-row tickers.
/// The sweep runs only while [AppMotion.ambientEnabled] (off under
/// `flutter test`), so suites relying on `pumpAndSettle` always settle.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Wraps [child] (typically a Column of [ShimmerBox]es) with one animated
/// highlight sweep. When ambient motion is disabled the child renders in the
/// flat base color — same geometry, zero timers.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});

  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    if (AppMotion.ambientEnabled) {
      _controller = AnimationController(
        vsync: this,
        duration: AppMotion.ambient,
      )..repeat();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final controller = _controller;
    if (controller == null) return widget.child;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: controller,
        child: widget.child,
        builder: (context, child) {
          // Sweep a soft highlight band across the subtree, direction-aware:
          // in RTL the band travels right→left so motion reads as "forward".
          final t = controller.value;
          final rtl = Directionality.of(context) == TextDirection.rtl;
          final dx = (t * 3 - 1.5) * (rtl ? -1 : 1);
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment(dx - 1, -0.3),
              end: Alignment(dx + 1, 0.3),
              colors: [
                tokens.shimmerBase,
                tokens.shimmerHighlight,
                tokens.shimmerBase,
              ],
              stops: const [0.35, 0.5, 0.65],
            ).createShader(bounds),
            child: child,
          );
        },
      ),
    );
  }
}

/// A skeleton block: rounded rect in the shimmer base color. Compose rows of
/// these under one [Shimmer].
class ShimmerBox extends StatelessWidget {
  const ShimmerBox({
    super.key,
    this.width,
    this.height = 14,
    this.radius = AppRadius.r8,
    this.shape = BoxShape.rectangle,
  });

  final double? width;
  final double height;
  final double radius;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: tokens.shimmerBase,
        shape: shape,
        borderRadius: shape == BoxShape.rectangle
            ? BorderRadius.circular(radius)
            : null,
      ),
    );
  }
}
