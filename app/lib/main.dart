import 'dart:convert';

import 'package:decanter_core/decanter_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'src/home_screen.dart';

/// The card shipped in assets, so the app has something real to open on a fresh
/// install and the parsing path is exercised the moment it launches.
const String _sampleCardAsset = 'assets/cards/mira_vance.json';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(DecanterApp(card: await _loadSampleCard()));
}

Future<TavernCard> _loadSampleCard() async {
  try {
    final String raw = await rootBundle.loadString(_sampleCardAsset);
    return TavernCard.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  } catch (error) {
    // A broken bundled asset should still produce a usable app, not a red
    // screen with no explanation of which asset failed.
    return TavernCard.fromJson(<String, dynamic>{
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': <String, dynamic>{
        'name': 'Sample card unreadable',
        'description': 'The bundled card could not be parsed:\n\n$error',
        'first_mes': '*Nothing loaded.*',
        'creator_notes': 'Fallback card, generated at runtime.',
      },
    });
  }
}

class DecanterApp extends StatelessWidget {
  const DecanterApp({super.key, required this.card});

  final TavernCard card;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Decanter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color.fromRGBO(12, 9, 8, 1),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color.fromRGBO(214, 140, 74, 1),
          brightness: Brightness.dark,
        ),
      ),
      home: HomeScreen(card: card),
    );
  }
}
