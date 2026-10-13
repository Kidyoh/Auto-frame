import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/camera_service.dart';
import 'services/capture_pipeline.dart';
import 'services/lut_library.dart';
import 'services/media_store.dart';
import 'services/motion_service.dart';
import 'services/shader_service.dart';
import 'services/vision_service.dart';
import 'ui/camera/camera_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);

  await Future.wait([
    MediaStore.instance.init(),
    LutLibrary.instance.load(),
    ShaderService.instance.load(),
  ]);

  final vision = VisionService();
  final motion = MotionService();
  runApp(
    AutoFrameApp(
      camera: CameraService(vision: vision, motion: motion),
      motion: motion,
      pipeline: CapturePipeline(vision: vision),
    ),
  );
}

class AutoFrameApp extends StatelessWidget {
  const AutoFrameApp({
    super.key,
    required this.camera,
    required this.motion,
    required this.pipeline,
  });

  final CameraService camera;
  final MotionService motion;
  final CapturePipeline pipeline;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Auto Frame',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      darkTheme: buildTheme(),
      themeMode: ThemeMode.dark,
      home: CameraScreen(camera: camera, motion: motion, pipeline: pipeline),
    );
  }
}
