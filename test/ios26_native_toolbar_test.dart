import 'dart:async';

import 'package:adaptive_platform_ui/src/widgets/adaptive_app_bar_action.dart';
import 'package:adaptive_platform_ui/src/widgets/ios26/ios26_native_toolbar.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets(
      'native title clears real actions and a wide leading in $direction',
      (tester) async {
        final messenger = tester.binding.defaultBinaryMessenger;
        MethodChannel? channel;
        final configurations = <Map<Object?, Object?>>[];
        final reply = Completer<void>();
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
          call,
        ) async {
          if (call.method == 'create') {
            final id = (call.arguments as Map)['id'];
            channel = MethodChannel('adaptive_platform_ui/ios26_toolbar_$id');
            messenger.setMockMethodCallHandler(channel!, (call) async {
              configurations.add(call.arguments as Map<Object?, Object?>);
              // Reproduce a native reply arriving after the route has been disposed.
              await reply.future;
              return null;
            });
          }
          return null;
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(
            SystemChannels.platform_views,
            null,
          );
          if (channel != null) {
            messenger.setMockMethodCallHandler(channel!, null);
          }
        });

        Widget toolbar({List<AdaptiveAppBarAction> actions = const []}) =>
            CupertinoApp(
              home: Directionality(
                textDirection: direction,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 390,
                    child: IOS26NativeToolbar(
                      leading: const SizedBox(
                        key: Key('leading'),
                        width: 100,
                        height: 44,
                      ),
                      titleWidget: const Text(
                        'A long document title that must fit',
                        key: Key('title'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      actions: actions,
                    ),
                  ),
                ),
              ),
            );
        await tester.pumpWidget(toolbar());
        await tester.pump();
        expect(channel, isNotNull);
        Future<void> sendInsets() async {
          final completed = Completer<void>();
          messenger.handlePlatformMessage(
            channel!.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('onTitleInsetsChanged', {
                'left': direction == TextDirection.ltr ? 16.0 : 128.0,
                'right': direction == TextDirection.ltr ? 128.0 : 16.0,
              }),
            ),
            (_) => completed.complete(),
          );
          await completed.future;
        }

        await sendInsets();
        await tester.pump();
        final title = tester.getRect(find.byKey(const Key('title')));
        final leading = tester.getRect(find.byKey(const Key('leading')));
        expect(leading.center.dy, 22);
        if (direction == TextDirection.ltr) {
          expect(title.left, greaterThanOrEqualTo(leading.right + 8));
          expect(title.right, lessThanOrEqualTo(390 - 128));
        } else {
          expect(title.right, lessThanOrEqualTo(leading.left - 8));
          expect(title.left, greaterThanOrEqualTo(128));
        }
        // Empty → populated → disabled → empty must all reach UIKit without recreating the bar.
        AdaptiveAppBarAction action(bool enabled) => AdaptiveAppBarAction(
          title: 'Save',
          enabled: enabled,
          onPressed: () {},
        );
        await tester.pumpWidget(toolbar(actions: [action(true)]));
        await tester.pumpWidget(toolbar(actions: [action(false)]));
        await tester.pumpWidget(toolbar());
        expect(configurations.map((c) => (c['actions'] as List).length), [
          0,
          1,
          1,
          0,
        ]);
        expect(
          ((configurations[2]['actions'] as List).single as Map)['enabled'],
          isFalse,
        );
        await tester.pumpWidget(const SizedBox());
        reply.complete();
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(TargetPlatform.iOS),
    );
  }
}
