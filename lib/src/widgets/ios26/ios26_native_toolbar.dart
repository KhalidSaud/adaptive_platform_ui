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
  Map<String, dynamic>? _lastConfiguration;
  EdgeInsets? _nativeTitleInsets;
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
      resolvedColor = brightness == Brightness.dark
          ? color.darkColor
          : color.color;
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
      final pushing =
          animation.status == AnimationStatus.forward &&
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
    _channel?.setMethodCallHandler(null);
    _channel = null;
    super.dispose();
  }

  @override
  void didUpdateWidget(IOS26NativeToolbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncPropsToNativeIfNeeded();
  }

  Map<String, dynamic> get _configuration => {
    'title': widget.titleWidget == null ? widget.title : null,
    'hasTitleWidget': widget.titleWidget != null,
    'leading': widget.leading == null ? widget.leadingText : null,
    'reservesLeading': widget.leading != null,
    'isDark': _isDark,
    'isRtl': _isRtl,
    'tint': widget.tintColor == null ? null : _colorToARGB(widget.tintColor!),
  };

  void _syncPropsToNativeIfNeeded() {
    final channel = _channel;
    if (channel == null) return;
    final configuration = _configuration;
    if (mapEquals(_lastConfiguration, configuration) &&
        listEquals(_lastActions, widget.actions)) {
      return;
    }

    // Snapshot inherited values before dispatch. Channel messages are FIFO; no asynchronous
    // continuation reads this context after a route has been removed, or overwrites newer props.
    _lastConfiguration = configuration;
    _lastActions = widget.actions == null ? null : List.of(widget.actions!);
    unawaited(
      channel
          .invokeMethod<void>('updateConfiguration', {
            ...configuration,
            'actions':
                widget.actions?.map((a) => a.toNativeMap()).toList() ?? [],
          })
          .catchError((Object error) {
            // A native view may already be released while its route is being torn down.
            if (mounted && identical(channel, _channel)) {
              _lastConfiguration = null;
            }
          }),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.iOS) {
      return _buildFallbackToolbar();
    }

    final safePadding = MediaQuery.of(context).padding.top;

    final creationParams = <String, dynamic>{
      ..._configuration,
      'actions': widget.actions?.map((a) => a.toNativeMap()).toList() ?? [],
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
          Positioned(
            left: 16,
            right: 16,
            top: safePadding,
            bottom: 0,
            child: NavigationToolbar(
              leading:
                  widget.leading ??
                  (_nativeTitleInsets == null
                      ? null
                      : SizedBox(
                          width:
                              ((_isRtl
                                          ? _nativeTitleInsets!.right
                                          : _nativeTitleInsets!.left) -
                                      16)
                                  .clamp(0, double.infinity),
                        )),
              // UIKit measures its own item groups, including localised text actions.
              // NavigationToolbar then measures the Flutter leading and centres the title
              // where it fits, rather than reserving the wider group on both sides.
              middle: _nativeTitleInsets == null ? null : widget.titleWidget,
              trailing: _nativeTitleInsets == null
                  ? null
                  : SizedBox(
                      width:
                          ((_isRtl
                                      ? _nativeTitleInsets!.left
                                      : _nativeTitleInsets!.right) -
                                  16)
                              .clamp(0, double.infinity),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  void _onPlatformViewCreated(int id) {
    if (!mounted) return;
    _channel = MethodChannel('adaptive_platform_ui/ios26_toolbar_$id');
    _channel!.setMethodCallHandler(_handleMethodCall);
    _lastConfiguration = null;
    _syncPropsToNativeIfNeeded();
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (!mounted) return;
    switch (call.method) {
      case 'onTitleInsetsChanged':
        final args = Map<String, dynamic>.from(call.arguments as Map);
        final insets = EdgeInsets.only(
          left: (args['left'] as num).toDouble(),
          right: (args['right'] as num).toDouble(),
        );
        if (insets != _nativeTitleInsets) {
          setState(() => _nativeTitleInsets = insets);
        }
        break;
      case 'onLeadingTapped':
        widget.onLeadingTap?.call();
        break;
      case 'onActionTapped':
        if (call.arguments is Map) {
          final index = (call.arguments as Map)['index'] as int?;
          if (index != null &&
              index >= 0 &&
              index < (widget.actions?.length ?? 0) &&
              widget.actions![index].enabled) {
            widget.onActionTap?.call(index);
          }
        }
        break;
    }
  }

  Widget _buildFallbackToolbar() {
    return CupertinoNavigationBar(
      middle:
          widget.titleWidget ??
          (widget.title != null ? Text(widget.title!) : null),
      leading: widget.leading,
      trailing: widget.actions != null && widget.actions!.isNotEmpty
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: widget.actions!.map((action) {
                return CupertinoButton(
                  padding: EdgeInsets.zero,
                  onPressed: action.enabled ? action.onPressed : null,
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
