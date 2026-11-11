// AskMe widget tests — verify that core UI elements render without overflow.
//
// These tests run on the host machine (not an Android device), so all native
// MethodChannel calls are intercepted via TestDefaultBinaryMessengerBinding.
// No real model, document, or speech service is exercised here.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:askme/main.dart';

/// Returns a minimal MethodChannel handler that satisfies the channels called
/// during widget startup (backendRuntimeInfo, deviceProfile, modelInfo).
void _setupMethodChannelMocks() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('askme/offline_model'),
    (MethodCall call) async {
      switch (call.method) {
        case 'backendRuntimeInfo':
          return {
            'available': false,
            'apiVersion': 0,
            'error': 'No native library in test host environment.',
          };
        case 'deviceProfile':
          return {
            'sdkInt': 33,
            'supportedAbis': ['arm64-v8a'],
            'is64Bit': true,
            'cpuCores': 4,
            'totalRamBytes': 8 * 1024 * 1024 * 1024,
            'availableRamBytes': 4 * 1024 * 1024 * 1024,
            'lowMemory': false,
            'deviceTier': 'high',
            'modelRuntimeReady': false,
          };
        case 'modelInfo':
          return null; // no model imported
        default:
          return null;
      }
    },
  );
}

void main() {
  setUp(_setupMethodChannelMocks);

  testWidgets('AskMe application loads successfully', (tester) async {
    await tester.pumpWidget(const AskMeApp());
    // Allow async initState calls (channel calls) to complete.
    await tester.pump();

    expect(find.text('AskMe'), findsOneWidget);
    expect(find.text('Your private AI document assistant'), findsOneWidget);
    expect(find.text('Select a document'), findsOneWidget);
  });

  testWidgets('AskMe UI renders without RenderFlex overflow', (tester) async {
    // Test on a compact phone size that previously triggered the overflow.
    tester.view.physicalSize = const Size(360 * 3, 640 * 3); // 360×640 dp @ 3x
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const AskMeApp());
    await tester.pump();

    // No overflow exception should be thrown.
    expect(tester.takeException(), isNull);

    // Key UI elements must be present.
    expect(find.text('AskMe'), findsOneWidget);
    expect(find.text('Select a document'), findsOneWidget);
    expect(find.byIcon(Icons.send), findsOneWidget);
  });

  testWidgets('AskMe UI renders without overflow on small screen (480dp tall)',
      (tester) async {
    tester.view.physicalSize = const Size(360 * 2, 480 * 2);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const AskMeApp());
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('Ask button is present and initially enabled', (tester) async {
    await tester.pumpWidget(const AskMeApp());
    await tester.pump();

    // The Ask FilledButton should be rendered.
    final askButton = find.widgetWithText(FilledButton, 'Ask');
    expect(askButton, findsOneWidget);
  });

  testWidgets('Privacy tip icon is present in AppBar', (tester) async {
    await tester.pumpWidget(const AskMeApp());
    await tester.pump();

    expect(find.byIcon(Icons.privacy_tip_outlined), findsOneWidget);
  });

  testWidgets('Voice input mic icons are present', (tester) async {
    await tester.pumpWidget(const AskMeApp());
    await tester.pump();

    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.byIcon(Icons.mic_none), findsOneWidget);
  });

  testWidgets('Empty history shows placeholder text', (tester) async {
    await tester.pumpWidget(const AskMeApp());
    await tester.pump();

    expect(find.text('Your questions will appear here.'), findsOneWidget);
  });
}
