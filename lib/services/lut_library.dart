import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/color/builtin_luts.dart';
import '../core/color/lut.dart';

/// Built-in looks plus any `.cube` files the user imports. Imported LUTs are
/// copied into the app's documents folder so they survive restarts.
class LutLibrary extends ChangeNotifier {
  LutLibrary._();

  static final LutLibrary instance = LutLibrary._();

  final Map<String, Lut3D> _imported = {};
  Directory? _dir;

  List<String> get builtinNames => BuiltinLuts.names;
  List<String> get importedNames => _imported.keys.toList()..sort();
  List<String> get allNames => [...builtinNames, ...importedNames];

  Lut3D? byName(String? name) {
    if (name == null) return null;
    if (BuiltinLuts.names.contains(name)) return BuiltinLuts.byName(name);
    return _imported[name];
  }

  Future<void> load() async {
    final docs = await getApplicationDocumentsDirectory();
    _dir = Directory(p.join(docs.path, 'AutoFrame', 'luts'));
    await _dir!.create(recursive: true);
    for (final f in _dir!.listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.cube')) continue;
      try {
        final text = await f.readAsString();
        final lut = await compute(_parse, (text, p.basenameWithoutExtension(f.path)));
        _imported[_uniqueName(lut.title)] = lut;
      } catch (e) {
        debugPrint('Skipping unreadable LUT ${f.path}: $e');
      }
    }
    notifyListeners();
  }

  /// Import a `.cube` file. Returns the name it was registered under.
  Future<String> import(String path, {LutInputSpace? inputSpace}) async {
    final text = await File(path).readAsString();
    final parsed = await compute(_parse, (text, p.basenameWithoutExtension(path)));
    final name = _uniqueName(parsed.title);
    // Store under the unique name so reloads resolve to the same entry.
    final lut = Lut3D(
      size: parsed.size,
      data: parsed.data,
      title: name,
      inputSpace: inputSpace ?? parsed.inputSpace,
      domainMin: parsed.domainMin,
      domainMax: parsed.domainMax,
    );
    final dir = _dir;
    if (dir != null) {
      // Re-serialise so our input-space tag is preserved.
      await File(p.join(dir.path, '${_safe(name)}.cube')).writeAsString(lut.toCube());
    }
    _imported[name] = lut;
    notifyListeners();
    return name;
  }

  Future<void> remove(String name) async {
    _imported.remove(name);
    final dir = _dir;
    if (dir != null) {
      final f = File(p.join(dir.path, '${_safe(name)}.cube'));
      if (await f.exists()) await f.delete();
    }
    notifyListeners();
  }

  /// Export any LUT (e.g. a built-in look) as a `.cube` for Resolve/Premiere.
  Future<File> exportCube(String name) async {
    final lut = byName(name)!;
    final tmp = await getTemporaryDirectory();
    final f = File(p.join(tmp.path, '${_safe(name)}.cube'));
    return f.writeAsString(lut.toCube());
  }

  String _uniqueName(String base) {
    var name = base.trim().isEmpty ? 'Imported LUT' : base.trim();
    var i = 2;
    final taken = {...BuiltinLuts.names, ..._imported.keys};
    final root = name;
    while (taken.contains(name)) {
      name = '$root ($i)';
      i++;
    }
    return name;
  }

  static String _safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9 _().-]'), '_');

  static Lut3D _parse((String, String) args) => Lut3D.parseCube(args.$1, fallbackTitle: args.$2);
}
