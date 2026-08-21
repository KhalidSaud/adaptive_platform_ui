import 'package:flutter/cupertino.dart';

/// Coordination between per-route native toolbars while one of them is transitioning.
///
/// One fact lives here, app-global because only one screen is visually current at a time:
/// [owner] — the toolbar whose route is currently animating (push, pop, or an interactive pop
/// drag). While set, every other toolbar hides its native view: the transitioning bar is held
/// at the bar's resting position and crossfades there, so it is the one authoritative copy —
/// leaving a neighbour's own bar visible would show two sets of glass buttons sliding through
/// each other in the page parallax.
abstract final class IOS26ToolbarRouteChrome {
  /// Identity of the toolbar state that owns the chrome during a transition, or null when
  /// everything is settled.
  static final ValueNotifier<Object?> owner = ValueNotifier<Object?>(null);

  static void claim(Object candidate) {
    if (!identical(owner.value, candidate)) owner.value = candidate;
  }

  static void release(Object candidate) {
    if (identical(owner.value, candidate)) owner.value = null;
  }
}

// The slide the framework applies to a horizontally-transitioning Cupertino page, reproduced
// so the toolbar can apply its exact inverse. Values match flutter/lib/src/cupertino/route.dart
// (_kRightMiddleTween, _kMiddleLeftTween and the curves in _CupertinoPageTransitionState);
// during an interactive pop the framework drops the curves, and so does this.
const double _kEnterFraction = 1.0;
const double _kExitFraction = -1.0 / 3.0;

/// Holds a route's toolbar at the bar's resting position while the page it belongs to slides,
/// and crossfades it in and out with the route.
///
/// A native iOS push keeps the navigation bar still and transitions only its contents; a
/// Flutter push slides the whole page, bar included. This is also how Flutter's own
/// [CupertinoNavigationBar] behaves with `transitionBetweenRoutes` — the bar transitions above
/// the sliding routes rather than inside them. This widget applies the exact inverse of the
/// Cupertino page offset to its child so the bar reads as one fixed piece of chrome, and
/// drives the bar's opacity from the same route animations: in with the push, out with the
/// pop, out as another route covers it. Routes that do not slide horizontally (full-screen
/// dialogs, non-page routes) are left untouched.
class IOS26ToolbarRouteTransition extends StatefulWidget {
  const IOS26ToolbarRouteTransition({
    required this.enabled,
    required this.child,
    super.key,
  });

  final bool enabled;
  final Widget child;

  @override
  State<IOS26ToolbarRouteTransition> createState() =>
      _IOS26ToolbarRouteTransitionState();
}

class _IOS26ToolbarRouteTransitionState
    extends State<IOS26ToolbarRouteTransition> {
  ModalRoute<Object?>? _route;
  CurvedAnimation? _enterCurve;
  CurvedAnimation? _exitCurve;
  CurvedAnimation? _fadeInCurve;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    _disposeCurves();
    _route = route;
    final animation = route?.animation;
    final secondary = route?.secondaryAnimation;
    if (animation != null) {
      _enterCurve = CurvedAnimation(
        parent: animation,
        curve: Curves.fastEaseInToSlowEaseOut,
        reverseCurve: Curves.fastEaseInToSlowEaseOut.flipped,
      );
      // The bar is fully readable well before the page has settled — iOS crossfades bar
      // contents quickly while the content is still travelling. On the way out (a pop), the
      // reverse interval empties the bar in the first half of the slide, before the moving
      // page edge uncovers the revealed screen's own bar underneath — so the two bars are
      // never legible at once.
      _fadeInCurve = CurvedAnimation(
        parent: animation,
        curve: const Interval(0.0, 0.55, curve: Curves.easeOut),
        reverseCurve: const Interval(0.55, 1.0, curve: Curves.easeIn),
      );
    }
    if (secondary != null) {
      _exitCurve = CurvedAnimation(
        parent: secondary,
        curve: Curves.linearToEaseOut,
        reverseCurve: Curves.easeInToLinear,
      );
    }
  }

  void _disposeCurves() {
    _enterCurve?.dispose();
    _exitCurve?.dispose();
    _fadeInCurve?.dispose();
    _enterCurve = null;
    _exitCurve = null;
    _fadeInCurve = null;
  }

  @override
  void dispose() {
    _disposeCurves();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final route = _route;
    if (!widget.enabled ||
        route is! PageRoute ||
        route.fullscreenDialog ||
        route.animation == null ||
        route.secondaryAnimation == null) {
      return widget.child;
    }

    final isRtl = Directionality.of(context) == TextDirection.rtl;
    return AnimatedBuilder(
      animation:
          Listenable.merge([route.animation!, route.secondaryAnimation!]),
      builder: (context, child) {
        final linear = route.navigator?.userGestureInProgress ?? false;
        final enter =
            linear ? route.animation!.value : _enterCurve?.value ?? 1.0;
        final exit =
            linear ? route.secondaryAnimation!.value : _exitCurve?.value ?? 0.0;
        // Where the framework has put the page, as a fraction of its width. Always the same
        // widget shape — collapsing to the bare child at zero would reparent the platform
        // view at the transition's endpoints and destroy the native bar mid-animation.
        var pageDx = (1.0 - enter) * _kEnterFraction + exit * _kExitFraction;
        if (isRtl) pageDx = -pageDx;
        final fadeIn =
            linear ? route.animation!.value : _fadeInCurve?.value ?? 1.0;
        final opacity =
            (fadeIn * (1.0 - route.secondaryAnimation!.value)).clamp(0.0, 1.0);
        return FractionalTranslation(
          translation: Offset(-pageDx, 0),
          child: Opacity(opacity: opacity, child: child),
        );
      },
      child: widget.child,
    );
  }
}
