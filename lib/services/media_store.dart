import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/edit/edit_params.dart';

enum MediaKind { photo, video }

class MediaItem {
  MediaItem(this.file, this.kind, this.modified);

  final File file;
  final MediaKind kind;
  final DateTime modified;

  String get name => p.basename(file.path);

  /// Non-destructive edit sidecar (`photo.jpg.af.json`).
  File get sidecar => File('${file.path}.af.json');
}

/// The Auto Frame library: originals, sidecar edits and exports in the app's
/// documents directory, mirrored to the system gallery on save.
class MediaStore extends ChangeNotifier {
  MediaStore._();

  static final MediaStore instance = MediaStore._();
  static const album = 'Auto Frame';

  late Directory _root;
  List<MediaItem> _items = [];

  List<MediaItem> get items => _items;
  Directory get root => _root;

  Future<void> init() async {
    final docs = await getApplicationDocumentsDirectory();
    _root = Directory(p.join(docs.path, 'AutoFrame', 'library'));
    await _root.create(recursive: true);
    await refresh();
  }

  Future<void> refresh() async {
    final files = _root.listSync().whereType<File>().where((f) {
      final ext = p.extension(f.path).toLowerCase();
      return ['.jpg', '.jpeg', '.png', '.mp4', '.mov'].contains(ext);
    });
    _items = [
      for (final f in files)
        MediaItem(
          f,
          ['.mp4', '.mov'].contains(p.extension(f.path).toLowerCase())
              ? MediaKind.video
              : MediaKind.photo,
          f.lastModifiedSync(),
        ),
    ]..sort((a, b) => b.modified.compareTo(a.modified));
    notifyListeners();
  }

  String newPath(String prefix, String ext) {
    final ts = DateTime.now().toIso8601String().replaceAll(RegExp(r'[:.]'), '-');
    return p.join(_root.path, '${prefix}_$ts.$ext');
  }

  /// Move a captured file into the library.
  Future<File> ingest(String path, {String prefix = 'AF'}) async {
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    final dest = newPath(prefix, ext.isEmpty ? 'jpg' : ext);
    File out;
    try {
      out = await File(path).rename(dest);
    } on FileSystemException {
      out = await File(path).copy(dest);
    }
    await refresh();
    return out;
  }

  Future<File> writeBytes(Uint8List bytes, {String prefix = 'AF', String ext = 'jpg'}) async {
    final f = File(newPath(prefix, ext));
    await f.writeAsBytes(bytes, flush: true);
    await refresh();
    return f;
  }

  Future<void> saveEdit(MediaItem item, EditParams params) async {
    await item.sidecar.writeAsString(jsonEncode(params.toJson()));
  }

  Future<EditParams?> loadEdit(File photo) async {
    final f = File('${photo.path}.af.json');
    if (!await f.exists()) return null;
    try {
      return EditParams.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Copy to the system Photos / Gallery app.
  Future<bool> exportToGallery(File file, MediaKind kind) async {
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        if (!await Gal.requestAccess(toAlbum: true)) return false;
      }
      if (kind == MediaKind.video) {
        await Gal.putVideo(file.path, album: album);
      } else {
        await Gal.putImage(file.path, album: album);
      }
      return true;
    } on GalException catch (e) {
      debugPrint('Gallery export failed: ${e.type.message}');
      return false;
    }
  }

  Future<void> delete(MediaItem item) async {
    if (await item.file.exists()) await item.file.delete();
    if (await item.sidecar.exists()) await item.sidecar.delete();
    await refresh();
  }
}
