/// Inspects a character card or world-info file using decanter_core.
///
///   dart run tool/inspect_card.dart <file.png|file.json>
///
/// Prints what the parser actually understood, which is the fastest way to tell
/// a format bug from a bad file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:decanter_core/decanter_core.dart';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr
        .writeln('usage: dart run tool/inspect_card.dart <file.png|file.json>');
    exit(2);
  }

  final path = args.first;
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('no such file: $path');
    exit(2);
  }
  final Uint8List bytes = file.readAsBytesSync();
  final isPng = path.toLowerCase().endsWith('.png');

  try {
    if (isPng) {
      final chunks = readPngTextChunks(bytes);
      stdout.writeln('PNG: ${bytes.length} bytes');
      stdout.writeln('text chunks: ${chunks.length}');
      for (final c in chunks) {
        stdout.writeln('  ${c.type} "${c.keyword}" '
            '(${c.text.length} chars)');
      }
      final chosen = <String>[
        for (final k in tavernCardKeywords)
          if (chunks.any((c) => c.keyword == k)) k,
      ];
      stdout.writeln('card chunk selected: '
          '${chosen.isEmpty ? "(none)" : chosen.first}');
      stdout.writeln('');
      report(parseCard(bytes));
    } else {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map) {
        stderr.writeln('top level is ${json.runtimeType}, expected an object');
        exit(1);
      }
      final map = Map<String, dynamic>.from(json);
      final looksLikeBook =
          map.containsKey('entries') && !map.containsKey('spec');
      if (looksLikeBook) {
        reportBook(CharacterBook.fromNativeJson(map));
      } else {
        report(TavernCard.fromJson(map));
      }
    }
  } on CardFormatException catch (e) {
    stderr.writeln('CARD ERROR: ${e.message}');
    exit(1);
  } on PngFormatException catch (e) {
    stderr.writeln('PNG ERROR: ${e.message}');
    exit(1);
  } on FormatException catch (e) {
    stderr.writeln('FORMAT ERROR: ${e.message}');
    exit(1);
  }
}

TavernCard parseCard(Uint8List bytes) => TavernCard.fromPng(bytes);

void report(TavernCard card) {
  stdout.writeln('CARD');
  stdout.writeln(
      '  spec            ${card.spec.id} (spec_version "${card.specVersion}")');
  stdout.writeln('  name            ${card.name}');
  stdout.writeln(
      '  creator         ${card.creator.isEmpty ? "-" : card.creator}');
  stdout.writeln(
      '  char version    ${card.characterVersion.isEmpty ? "-" : card.characterVersion}');
  stdout.writeln(
      '  tags            ${card.tags.isEmpty ? "-" : card.tags.join(", ")}');
  stdout.writeln('  description     ${_ellipsis(card.description)}');
  stdout.writeln('  personality     ${_ellipsis(card.personality)}');
  stdout.writeln('  scenario        ${_ellipsis(card.scenario)}');
  stdout.writeln('  first_mes       ${_ellipsis(card.firstMes)}');
  stdout.writeln('  mes_example     ${_ellipsis(card.mesExample)}');
  stdout.writeln('  system_prompt   ${_ellipsis(card.systemPrompt)}');
  stdout
      .writeln('  post_history    ${_ellipsis(card.postHistoryInstructions)}');
  stdout.writeln('  greetings       ${card.greetings.length} total');
  for (var i = 0; i < card.greetings.length; i++) {
    stdout.writeln('    [$i] ${_ellipsis(card.greetings[i], 70)}');
  }
  stdout.writeln('  extensions      ${card.extensions.keys.toList()}');
  stdout.writeln('  linked world    ${card.linkedWorldName ?? "-"}');
  stdout.writeln('  unmodelled keys ${card.dataExtras.keys.toList()}');
  if (card.characterBook != null) {
    stdout.writeln('');
    reportBook(card.characterBook!);
  }
}

void reportBook(CharacterBook book) {
  stdout.writeln('WORLD INFO / CHARACTER BOOK');
  stdout.writeln('  name            ${book.name.isEmpty ? "-" : book.name}');
  stdout.writeln(
      '  entries         ${book.entries.length} (${book.active.length} active)');
  stdout.writeln('  scan_depth      ${book.scanDepth ?? "-"}');
  stdout.writeln('  token_budget    ${book.tokenBudget ?? "-"}');
  stdout.writeln('  recursive       ${book.recursiveScanning}');
  stdout.writeln('');
  stdout.writeln('  uid  pos               const  keys');
  for (final e in book.entries.take(40)) {
    stdout.writeln('  ${e.uid.toString().padRight(4)} '
        '${e.position.name.padRight(17)} '
        '${(e.constant ? "yes" : "no").padRight(6)} '
        '${e.keys.join(", ")}');
  }
  if (book.entries.length > 40) {
    stdout.writeln('  ... ${book.entries.length - 40} more');
  }
}

String _ellipsis(String s, [int max = 60]) {
  if (s.isEmpty) return '-';
  final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max)}...';
}
