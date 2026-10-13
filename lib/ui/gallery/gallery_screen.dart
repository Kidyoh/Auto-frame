import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:video_player/video_player.dart';

import '../../services/media_store.dart';
import '../common/widgets.dart';
import '../editor/editor_screen.dart';
import '../theme.dart';

/// The Auto Frame library: everything you shot or edited, plus import from
/// the system photo library.
class GalleryScreen extends StatelessWidget {
  const GalleryScreen({super.key});

  Future<void> _import(BuildContext context) async {
    // imageQuality forces a JPEG (HEIC on iOS otherwise).
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 100,
      requestFullMetadata: false,
    );
    if (picked == null || !context.mounted) return;
    final dest = MediaStore.instance.newPath('AF_IMPORT', 'jpg');
    await File(picked.path).copy(dest);
    await MediaStore.instance.refresh();
    if (!context.mounted) return;
    await Navigator.of(context)
        .push(MaterialPageRoute(builder: (_) => EditorScreen(file: File(dest))));
  }

  void _open(BuildContext context, MediaItem item) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => item.kind == MediaKind.photo
            ? EditorScreen(file: item.file)
            : _VideoPage(file: item.file),
      ),
    );
  }

  Future<void> _actions(BuildContext context, MediaItem item) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Save to Photos'),
              onTap: () => Navigator.pop(context, 'export'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: AfColors.warn),
              title: const Text('Delete from Auto Frame'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'export') {
      final ok = await MediaStore.instance.exportToGallery(item.file, item.kind);
      if (context.mounted) showToast(context, ok ? 'Saved to Photos' : 'Permission needed to save');
    } else if (action == 'delete') {
      await MediaStore.instance.delete(item);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LIBRARY'),
        actions: [
          IconButton(
            tooltip: 'Import from Photos',
            icon: const Icon(Icons.add_photo_alternate_outlined),
            onPressed: () => _import(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: MediaStore.instance,
        builder: (context, _) {
          final items = MediaStore.instance.items;
          if (items.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.camera_outlined, size: 48, color: AfColors.textDim),
                  const SizedBox(height: 12),
                  const Text('Nothing here yet', style: TextStyle(color: AfColors.textDim)),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => _import(context),
                    child: const Text('Import a photo to edit'),
                  ),
                ],
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(2),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 2,
              crossAxisSpacing: 2,
            ),
            itemCount: items.length,
            itemBuilder: (context, i) {
              final item = items[i];
              return GestureDetector(
                onTap: () => _open(context, item),
                onLongPress: () => _actions(context, item),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (item.kind == MediaKind.photo)
                      Image.file(item.file, fit: BoxFit.cover, cacheWidth: 300)
                    else
                      const ColoredBox(
                        color: AfColors.surfaceHigh,
                        child: Icon(Icons.movie_outlined, color: AfColors.textDim),
                      ),
                    if (item.kind == MediaKind.video)
                      const Positioned(
                        right: 6,
                        bottom: 6,
                        child: Icon(Icons.play_circle_fill_rounded, size: 20),
                      ),
                    if (item.sidecar.existsSync())
                      const Positioned(
                        left: 6,
                        bottom: 6,
                        child: Icon(Icons.tune_rounded, size: 16, color: AfColors.gold),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _VideoPage extends StatefulWidget {
  const _VideoPage({required this.file});

  final File file;

  @override
  State<_VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<_VideoPage> {
  late final VideoPlayerController _c = VideoPlayerController.file(widget.file);

  @override
  void initState() {
    super.initState();
    _c
      ..setLooping(true)
      ..initialize().then((_) {
        if (mounted) {
          setState(() {});
          _c.play();
        }
      });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(),
      body: Center(
        child: _c.value.isInitialized
            ? GestureDetector(
                onTap: () => setState(() => _c.value.isPlaying ? _c.pause() : _c.play()),
                child: AspectRatio(aspectRatio: _c.value.aspectRatio, child: VideoPlayer(_c)),
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
