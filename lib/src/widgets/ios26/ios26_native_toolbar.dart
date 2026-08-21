import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../../utils/animation.dart';
import '../adaptive_app_bar_action.dart';
import 'ios26_toolbar_route_transition.dart';

/// Native iOS 26 UINavigationBar widget using platform views
/// Implements Liquid Glass design with native blur effects
class IOS26NativeToolbar extends StatefulWidget {
  const IOS26NativeToolbar({
    super.key,
    this.title,
    this.leading,
    this.leadingText,
    this.actions,
    this.onLeadingTap,
    this.onActionTap,
    this.titleWidget,
    this.tintColor,
    this.height = 44.0,
    this.showNativeView = true,
    this.routeTransitions = false,
  });

  final String? title;
  final Widget? leading;
  final String? leadingText;
  final List<AdaptiveAppBarAction>? actions;
  final VoidCallback? onLeadingTap;
  final ValueChanged<int>? onActionTap;

  /// Custom widget overlaid at the title position.
  /// When set, the native title is hidden and this widget is centered instead.
  final Widget? titleWidget;

  /// Tint color for bar button items (action buttons and back button)
  ///
  /// When set, this color is applied to the UINavigationBar's tintColor,
  /// which colors all UIBarButtonItem instances.
  /// If null, the system default tint color is used.
  final Color? tintColor;

  final double height;
  final bool showNativeView;

  /// Whether this bar takes part in pinned route transitions.
  ///
  /// When true, the enclosing scaffold holds the bar at its resting position over the page
  /// slide and crossfades it with the route ([IOS26ToolbarRouteTransition]), and this widget
  /// claims the chrome while its route is animating so every other toolbar hides its native
  /// view — the transitioning bar is the only copy on screen, exactly one set of glass
  /// buttons at the bar's position at any moment.
  final bool routeTransitions;

  @override
  State<IOS26NativeToolbar> createState() => _IOS26NativeToolbarState();
}

class _IOS26NativeToolbarState extends State<IOS26NativeToolbar> {
  MethodChannel? _channel;
  bool? _lastIsDark;
  bool? _lastIsRtl;
  int? _lastTint;
  List<AdaptiveAppBarAction>? _lastActions;

  ModalRoute<Object?>? _route;
  Animation<double>? _routeAnimation;
  bool _yieldedToForeignTransition = false;

  @override
  void initState() {
    super.initState();
    IOS26ToolbarRouteChrome.owner.addListener(_onChromeOwnerChanged);
    final owner = IOS26ToolbarRouteChrome.owner.value;
    _yieldedToForeignTransition = owner != null && !identical(owner, this);
  }

  /// The ambient Flutter direction — the app's locale, which may differ from the device's.
  bool get _isRtl => Directionality.of(context) == TextDirection.rtl;

  bool get _isDark =>
      MediaQuery.platformBrightnessOf(context) == Brightness.dark;

  int _colorToARGB(Color color) {
    // Resolve CupertinoDynamicColor if needed
    Color resolvedColor = color;
    if (color is CupertinoDynamicColor) {
      final brightness = MediaQuery.platformBrightnessOf(context);
      resolvedColor =
          brightness == Brightness.dark ? color.darkColor : color.color;
    }

    return ((resolvedColor.a * 255.0).round() & 0xff) << 24 |
        ((resolvedColor.r * 255.0).round() & 0xff) << 16 |
        ((resolvedColor.g * 255.0).round() & 0xff) << 8 |
        ((resolvedColor.b * 255.0).round() & 0xff);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _wireRoute();
    _syncPropsToNativeIfNeeded();
    _scheduleChromeSync();
  }

  void _wireRoute() {
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _route = route;
    _routeAnimation = route?.animation;
    _routeAnimation?.addStatusListener(_onRouteStatus);
  }

  void _onRouteStatus(AnimationStatus status) => _scheduleChromeSync();

  void _onChromeOwnerChanged() {
    final owner = IOS26ToolbarRouteChrome.owner.value;
    final yielded = owner != null && !identical(owner, this);
    if (yielded == _yieldedToForeignTransition || !mounted) return;
    _yieldedToForeignTransition = yielded;
    // The notifier can fire mid-frame — a claim from a status listener, or a release while a
    // popped route's tree is being torn down (tree locked) — when setState is not allowed.
    switch (SchedulerBinding.instance.schedulerPhase) {
      case SchedulerPhase.idle:
      case SchedulerPhase.transientCallbacks:
      case SchedulerPhase.postFrameCallbacks:
        setState(() {});
      case SchedulerPhase.midFrameMicrotasks:
      case SchedulerPhase.persistentCallbacks:
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() {});
        });
    }
  }

  /// Claims the chrome while this bar's route is PUSHING and releases it in every other
  /// state — off the frame, because it is reached from build-phase hooks and the claim
  /// notifies every other toolbar.
  ///
  /// Only the push claims. On the way in, the bar underneath would otherwise stay legible at
  /// the same trailing position while this bar fades in over it — two sets of glass buttons.
  /// On the way out (pop or a back-swipe, which the framework reports as `forward` with a
  /// user gesture in progress), the revealed bar must be there from the first frame, exposed
  /// progressively by the sliding page edge — hiding it until the pop settles is what made
  /// its buttons blink in after the page had already landed.
  void _scheduleChromeSync() {
    if (!widget.routeTransitions) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final animation = _route?.animation;
      if (animation == null) return;
      final pushing = animation.status == AnimationStatus.forward &&
          !(_route?.navigator?.userGestureInProgress ?? false);
      if (pushing) {
        IOS26ToolbarRouteChrome.claim(this);
      } else {
        IOS26ToolbarRouteChrome.release(this);
      }
    });
  }

  @override
  void dispose() {
    // A microtask, not a direct call: dispose runs while a popped route's tree is being
    // finalized (tree locked), and releasing here notifies every other toolbar — whose
    // setState must land after the teardown, or the revealed bar stays hidden forever.
    if (widget.routeTransitions) {
      final candidate = this;
      scheduleMicrotask(() => IOS26ToolbarRouteChrome.release(candidate));
    }
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    IOS26ToolbarRouteChrome.owner.removeListener(_onChromeOwnerChanged);
    super.dispose();
  }

  @override
  void didUpdateWidget(IOS26NativeToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPropsToNativeIfNeeded();

    if (widget.title != oldWidget.title) {
      final ch = _channel;
      // Skip when a titleWidget overlay is shown — the native title stays hidden
      if (ch != null && widget.title != null && widget.titleWidget == null) {
        ch.invokeMethod('updateTitle', {'title': widget.title!});
      }
    }
  }

  Future<void> _syncPropsToNativeIfNeeded() async {
    final ch = _channel;
    if (ch == null) return;

    // Sync directionality — the native bar cannot see Flutter's Directionality on its own.
    final isRtl = _isRtl;
    if (_lastIsRtl != isRtl) {
      try {
        await ch.invokeMethod('setDirectionality', {'isRtl': isRtl});
        _lastIsRtl = isRtl;
      } catch (e) {
        // Ignore errors if platform view is not yet ready
      }
    }

    // Sync brightness
    final isDark = _isDark;
    if (_lastIsDark != isDark) {
      try {
        await ch.invokeMethod('setBrightness', {'isDark': isDark});
        _lastIsDark = isDark;
      } catch (e) {
        // Ignore errors if platform view is not yet ready
      }
    }

    // Sync actions (per-action tint, prominent, etc.)
    final actions = widget.actions;
    if (_lastActions != null && !_actionsEqual(_lastActions!, actions)) {
      try {
        final params = <String, dynamic>{
          if (actions != null && actions.isNotEmpty)
            'actions': actions.map((a) => a.toNativeMap()).toList(),
        };
        await ch.invokeMethod('updateActions', params);
        _lastActions = actions != null ? List.of(actions) : null;
      } catch (e) {
        // Ignore errors if platform view is not yet ready
      }
    }

    // Sync tint color
    final tint =
        widget.tintColor != null ? _colorToARGB(widget.tintColor!) : null;
    if (_lastTint != tint) {
      try {
        await ch.invokeMethod('setStyle', {'tint': tint});
        _lastTint = tint;
      } catch (e) {
        // Ignore errors if platform view is not yet ready
      }
    }
  }

  bool _actionsEqual(
      List<AdaptiveAppBarAction>? a, List<AdaptiveAppBarAction>? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return _buildFallbackToolbar();
    }

    final safePadding = MediaQuery.of(context).padding.top;

    final creationParams = <String, dynamic>{
      // Hide native title when a titleWidget overlay is provided
      if (widget.title != null && widget.titleWidget == null)
        'title': widget.title!,
      if (widget.leading == null && widget.leadingText != null)
        'leading': widget.leadingText!,
      if (widget.actions != null && widget.actions!.isNotEmpty)
        'actions': widget.actions!.map((a) => a.toNativeMap()).toList(),
      'isDark': _isDark,
      'isRtl': _isRtl,
      // The overlay draws the leading control; the native bar must still reserve its slot so
      // its own centred title truncates against it rather than running underneath.
      if (widget.leading != null) 'reservesLeading': true,
      if (widget.tintColor != null) 'tint': _colorToARGB(widget.tintColor!),
    };

    return AnimatedContainer(
      height: widget.height + safePadding,
      duration: const Duration(milliseconds: 1000),
      curve: const IOSSpringCurve(),
      child: Stack(
        children: [
          if (widget.showNativeView)
            // Offstage rather than removed while another bar's transition owns the chrome:
            // the platform view survives, so this bar reappears the same frame the
            // transition ends instead of re-initialising a UINavigationBar and flashing an
            // empty corner.
            Offstage(
              offstage: _yieldedToForeignTransition,
              child: UiKitView(
                viewType: 'adaptive_platform_ui/ios26_toolbar',
                creationParams: creationParams,
                creationParamsCodec: const StandardMessageCodec(),
                onPlatformViewCreated: _onPlatformViewCreated,
                hitTestBehavior: PlatformViewHitTestBehavior.translucent,
              ),
            ),
          if (widget.leading != null)
            PositionedDirectional(
              start: 16,
              bottom: 3,
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: widget.leading!,
              ),
            ),
          if (widget.titleWidget != null)
            Positioned(
              left: 0,
              right: 0,
              top: safePadding,
              bottom: 0,
              child: Center(child: widget.titleWidget!),
            ),
        ],
      ),
    );
  }

  void _onPlatformViewCreated(int id) {
    _channel = MethodChannel('adaptive_platform_ui/ios26_toolbar_$id');
    _channel!.setMethodCallHandler(_handleMethodCall);
    _lastIsDark = _isDark;
    _lastIsRtl = _isRtl;
    _lastTint =
        widget.tintColor != null ? _colorToARGB(widget.tintColor!) : null;
    _lastActions =
        widget.actions != null ? List.of(widget.actions!) : null;
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onLeadingTapped':
        widget.onLeadingTap?.call();
        break;
      case 'onActionTapped':
        if (call.arguments is Map) {
          final index = (call.arguments as Map)['index'] as int?;
          if (index != null) widget.onActionTap?.call(index);
        }
        break;
    }
  }

  Widget _buildFallbackToolbar() {
    return CupertinoNavigationBar(
      middle: widget.titleWidget ??
          (widget.title != null ? Text(widget.title!) : null),
      leading: widget.leading,
      trailing: widget.actions != null && widget.actions!.isNotEmpty
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: widget.actions!.map((action) {
                return CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: action.onPressed,
                  child: action.icon != null
                      ? Icon(action.icon)
                      : Text(action.title ?? ''),
                );
              }).toList(),
            )
          : null,
    );
  }
}
