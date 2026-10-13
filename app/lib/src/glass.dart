import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Design tokens for the glass system, in one place so the look is tunable
/// without hunting through widgets.
abstract final class Glass {
  /// Backdrop blur radius. Higher reads as thicker glass; lower keeps the
  /// background legible behind the panel.
  static const double blur = 24;

  /// Default corner radius. Large radii are what make a panel read as a poured
  /// surface rather than a card.
  static const double radius = 28;

  /// A tinted white, for everything that catches light.
  static Color tint(double alpha) => Color.fromRGBO(255, 255, 255, alpha);

  /// A tinted black, for everything that occludes it.
  static Color shade(double alpha) => Color.fromRGBO(0, 0, 0, alpha);

  /// Surface text colours, paired with the glass rather than Material's theme,
  /// because the panel tints shift what "onSurface" needs to be.
  static const Color textPrimary = Color.fromRGBO(255, 253, 250, 0.96);
  static const Color textSecondary = Color.fromRGBO(255, 250, 244, 0.72);
  static const Color textFaint = Color.fromRGBO(255, 248, 240, 0.52);
}

/// A frosted, translucent panel.
///
/// Built as a stack of thin layers because that is how real glass reads: the
/// blur is the body, a diagonal gradient gives it thickness, a rim border is
/// where it catches the light, and a specular streak along the top edge is the
/// highlight that sells it as a surface rather than a rectangle.
///
/// True refraction — bending the backdrop rather than blurring it — needs a
/// fragment shader sampling the backdrop texture. That is the next step; the
/// layering here is what a shader would modulate.
class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.radius = Glass.radius,
    this.blur = Glass.blur,
    this.padding = const EdgeInsets.all(18),
    this.tintStrength = 1.0,
    this.borderStrength = 1.0,
    this.showSpecular = true,
    this.shadow = true,
  });

  final Widget child;
  final double radius;
  final double blur;
  final EdgeInsetsGeometry padding;

  /// Scales the whole tint, for panels that should recede.
  final double tintStrength;

  /// Scales the rim light only.
  final double borderStrength;

  final bool showSpecular;
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: shadow
            ? <BoxShadow>[
                BoxShadow(
                  color: Glass.shade(0.30),
                  blurRadius: 36,
                  spreadRadius: -6,
                  offset: const Offset(0, 16),
                ),
              ]
            : null,
      ),
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Stack(
            children: <Widget>[
              // Body: thicker where the light enters, top-left.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: borderRadius,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: <Color>[
                        Glass.tint(0.30 * tintStrength),
                        Glass.tint(0.14 * tintStrength),
                        Glass.tint(0.06 * tintStrength),
                      ],
                      stops: const <double>[0.0, 0.42, 1.0],
                    ),
                  ),
                ),
              ),

              // Rim: the edge of the glass catching light all the way round.
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: borderRadius,
                    border: Border.all(
                      color: Glass.tint(0.28 * borderStrength),
                      width: 1,
                    ),
                  ),
                ),
              ),

              // Specular streak: brightest at the top edge, fading out at both
              // ends so it never looks like a painted line.
              if (showSpecular)
                Positioned(
                  top: 0,
                  left: radius * 0.5,
                  right: radius * 0.5,
                  height: 1.4,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: <Color>[
                          Glass.tint(0.0),
                          Glass.tint(0.85 * borderStrength),
                          Glass.tint(0.0),
                        ],
                        stops: const <double>[0.0, 0.5, 1.0],
                      ),
                    ),
                  ),
                ),

              Padding(padding: padding, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// A fully-rounded glass surface, for controls.
class GlassPill extends StatelessWidget {
  const GlassPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    this.tintStrength = 1.0,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double tintStrength;

  @override
  Widget build(BuildContext context) => GlassPanel(
    radius: 999,
    blur: 20,
    padding: padding,
    tintStrength: tintStrength,
    borderStrength: 0.9,
    showSpecular: false,
    shadow: false,
    child: child,
  );
}

/// The background image, drifting slowly so the glass has something to move
/// against. Motion is what separates "translucent" from "actually glass" —
/// a static blur reads as a flat translucent rectangle.
class LiquidBackground extends StatefulWidget {
  const LiquidBackground({super.key, required this.asset, required this.child});

  final String asset;
  final Widget child;

  @override
  State<LiquidBackground> createState() => _LiquidBackgroundState();
}

class _LiquidBackgroundState extends State<LiquidBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 24),
  )..repeat(reverse: true);

  late final Animation<double> _drift = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeInOut,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // Slightly oversized so the drift never exposes an edge.
        AnimatedBuilder(
          animation: _drift,
          builder: (BuildContext context, Widget? child) {
            final double t = _drift.value;
            return Transform.scale(
              scale: 1.07 + 0.05 * t,
              child: Transform.translate(
                offset: Offset(0, -14 + 28 * t),
                child: child,
              ),
            );
          },
          child: Image.asset(widget.asset, fit: BoxFit.cover),
        ),

        // Scrim: without it, text over the bright lower half is unreadable.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Glass.shade(0.46),
                Glass.shade(0.14),
                Glass.shade(0.52),
              ],
              stops: const <double>[0.0, 0.45, 1.0],
            ),
          ),
        ),

        widget.child,
      ],
    );
  }
}

/// A slow highlight travelling across its child, as if the surface were
/// catching a moving light source.
///
/// The band is a diagonal gradient in a full-size overlay; the parent's clip
/// does the masking, so this needs no shader and no layout negotiation.
class SheenSweep extends StatefulWidget {
  const SheenSweep({super.key, required this.child, this.period = const Duration(seconds: 8)});

  final Widget child;
  final Duration period;

  @override
  State<SheenSweep> createState() => _SheenSweepState();
}

class _SheenSweepState extends State<SheenSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _controller,
              builder: (BuildContext context, Widget? child) {
                // Travels from well before the leading edge to well past the
                // trailing edge, so the band enters and leaves rather than
                // popping in.
                final double t = _controller.value * 3.4 - 1.7;
                return DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment(t - 0.30, -1),
                      end: Alignment(t + 0.30, 1),
                      colors: <Color>[
                        Glass.tint(0.0),
                        Glass.tint(0.020),
                        Glass.tint(0.16),
                        Glass.tint(0.020),
                        Glass.tint(0.0),
                      ],
                      stops: const <double>[0.0, 0.38, 0.5, 0.62, 1.0],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
