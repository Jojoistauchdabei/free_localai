// Debug helper: dump the Hive `settings` box of a copied settings.hive.
// Usage: dart run tool/dump_settings.dart <dir-with-settings.hive>
import 'dart:io';

import 'package:hive/hive.dart';

void main(List<String> args) async {
  final dir = args.isNotEmpty ? args[0] : '.';
  final box = await Hive.openBox('settings', path: dir);
  for (final key in box.keys) {
    stdout.writeln('$key = ${box.get(key)}');
  }
  exit(0);
}
