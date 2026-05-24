import 'package:nocterm/nocterm.dart' hide BoxFit;
// TerminalCanvas is not part of nocterm's public API but is the only way to
// implement paint() in a custom RenderObject — same pattern used by nocterm itself.
import 'package:nocterm/src/framework/terminal_canvas.dart'; // ignore: implementation_imports

/// Defines how a child widget should be inscribed into the available space.
///
/// Mirrors Flutter's [BoxFit] semantics for nocterm terminal UIs.
enum BoxFit {
  /// Scale the child uniformly so it fits within the available space.
  /// May leave empty space (letterboxing/pillarboxing).
  contain,

  /// Scale the child uniformly so it fills the available space.
  /// May clip the child (cropping).
  cover,

  /// Stretch the child to fill the available space exactly.
  /// Ignores the child's aspect ratio.
  fill,

  /// Scale the child to fit the available width.
  /// Height is derived from the child's aspect ratio.
  fitWidth,

  /// Scale the child to fit the available height.
  /// Width is derived from the child's aspect ratio.
  fitHeight,

  /// Display the child at its intrinsic size with no scaling.
  none,

  /// Like [contain] but only scales down, never up.
  scaleDown,
}

/// Scales and positions a child widget within its allocated space according
/// to [fit] and [alignment].
///
/// Equivalent to Flutter's [FittedBox] for nocterm terminal UIs.
///
/// Example — keep the [NitroLogo] centred and fully visible regardless of
/// how large the surrounding [Expanded] area is:
/// ```dart
/// FittedBox(
///   fit: BoxFit.scaleDown,
///   child: NitroLogo(color: Colors.cyan),
/// )
/// ```
class FittedBox extends SingleChildRenderObjectComponent {
  const FittedBox({
    super.key,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
    super.child,
  });

  final BoxFit fit;
  final Alignment alignment;

  @override
  RenderObject createRenderObject(BuildContext context) {
    return RenderFittedBox(fit: fit, alignment: alignment);
  }

  @override
  void updateRenderObject(BuildContext context, RenderFittedBox renderObject) {
    renderObject
      ..fit = fit
      ..alignment = alignment;
  }
}

/// The [RenderObject] that backs [FittedBox].
///
/// Lays out its single [child] with unconstrained dimensions to discover its
/// natural size, then positions and clips it inside [constraints] according to
/// the [fit] and [alignment] parameters.
class RenderFittedBox extends RenderObject with RenderObjectWithChildMixin<RenderObject> {
  RenderFittedBox({required BoxFit fit, required Alignment alignment});

  BoxFit fit = BoxFit.contain;
  Alignment alignment = Alignment.center;

  // ── Layout ────────────────────────────────────────────────────────────────

  @override
  void performLayout() {
    if (child == null) {
      size = constraints.constrain(Size.zero);
      return;
    }

    // Give the child unbounded space so it can report its intrinsic size.
    child!.layout(const BoxConstraints(), parentUsesSize: true);
    final childSize = child!.size;

    final double childAspectRatio = childSize.width / childSize.height;
    final double availableWidth = constraints.maxWidth;
    final double availableHeight = constraints.maxHeight;
    final double availableAspectRatio = availableWidth / availableHeight;

    // Determine the target size based on [fit].
    final Size fittedSize = _computeFittedSize(
      fit: fit,
      childSize: childSize,
      childAspectRatio: childAspectRatio,
      availableWidth: availableWidth,
      availableHeight: availableHeight,
      availableAspectRatio: availableAspectRatio,
    );

    size = constraints.constrain(fittedSize);

    // Compute the alignment offset so the child is positioned correctly within
    // the fitted bounds.
    final double xOffset = alignment.x * (size.width - childSize.width) / 2;
    final double yOffset = alignment.y * (size.height - childSize.height) / 2;

    // Ensure the child's parent data is initialised before writing the offset.
    if (child!.parentData == null) {
      child!.parentData = BoxParentData();
    }
    (child!.parentData as BoxParentData).offset = Offset(xOffset, yOffset);
  }

  /// Computes the size to paint the child at for the given [fit].
  static Size _computeFittedSize({
    required BoxFit fit,
    required Size childSize,
    required double childAspectRatio,
    required double availableWidth,
    required double availableHeight,
    required double availableAspectRatio,
  }) {
    switch (fit) {
      case BoxFit.contain:
        if (childAspectRatio > availableAspectRatio) {
          return Size(availableWidth, availableWidth / childAspectRatio);
        } else {
          return Size(availableHeight * childAspectRatio, availableHeight);
        }

      case BoxFit.cover:
        if (childAspectRatio > availableAspectRatio) {
          return Size(availableHeight * childAspectRatio, availableHeight);
        } else {
          return Size(availableWidth, availableWidth / childAspectRatio);
        }

      case BoxFit.fill:
        return Size(availableWidth, availableHeight);

      case BoxFit.fitWidth:
        return Size(availableWidth, availableWidth / childAspectRatio);

      case BoxFit.fitHeight:
        return Size(availableHeight * childAspectRatio, availableHeight);

      case BoxFit.none:
        return childSize;

      case BoxFit.scaleDown:
        if (childSize.width <= availableWidth && childSize.height <= availableHeight) {
          return childSize;
        }
        if (childAspectRatio > availableAspectRatio) {
          return Size(availableWidth, availableWidth / childAspectRatio);
        } else {
          return Size(availableHeight * childAspectRatio, availableHeight);
        }
    }
  }

  // ── Painting ──────────────────────────────────────────────────────────────

  @override
  void paint(TerminalCanvas canvas, Offset offset) {
    if (child == null) {
      return;
    }

    // Clip to prevent the child from painting outside its allocated region.
    // The clip is positioned at our global `offset`.
    final clipRect = Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height);
    final clippedCanvas = canvas.clip(clipRect);

    // CRITICAL: The clippedCanvas now has its origin (area.topLeft) set to `offset`.
    // We must NOT add `offset` again when painting the child onto the clipped canvas,
    // otherwise it will be double-translated and disappear off-screen.
    final childLocalOffset = (child!.parentData as BoxParentData).offset;

    child!.paintWithContext(clippedCanvas, childLocalOffset);
    super.paint(canvas, offset);
  }

}
