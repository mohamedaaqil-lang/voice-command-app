// This is a basic Flutter widget test for the VoiceOS App.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voice_command_app/main.dart';

void main() {
  testWidgets('VoiceOS App smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(const VoiceOSApp());

    // Verify that the app builds a Scaffold
    expect(find.byType(Scaffold), findsOneWidget);
    
    // Verify that the scaffold has the correct background color when inactive/not minimized
    final Scaffold scaffold = tester.widget(find.byType(Scaffold));
    expect(scaffold.backgroundColor, const Color(0xFF0C0C12));
  });
}
