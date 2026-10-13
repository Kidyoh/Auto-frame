# Auto Frame

**A camera on steroids.** Auto Frame composes your shot with on-device AI, brackets exposure and aperture, records in its own log profile with LUTs, and develops photos with a Lightroom-style editor. It's built with Flutter for iOS and Android.

## Features

### Capture modes
| Mode | What it does |
| --- | --- |
| **AUTO FRAME** | A live composition coach tracks faces and shows a 0–100 frame score with hints ("Pan right", "Level the horizon"). After the shot, the app proposes crops in several aspect ratios: rule of thirds, golden ratio, eye line, headroom, lead room, no cut-off limbs and automatic horizon straightening. The **smart shutter** fires by itself once the frame is composed and level. |
| **PHOTO** | Natural capture. The active look is saved as a non-destructive edit, and a graded copy goes to Photos. |
| **HDR+** | Takes a 3-shot exposure bracket (−2 / 0 / +2 EV), aligns the frames (median-threshold bitmaps) and merges them with Mertens exposure fusion. No tone-mapping halos. |
| **APERTURE** | Renders one capture at f/1.4, f/2, f/2.8, f/4 and f/8. Synthetic depth of field uses ML Kit person segmentation (or detected subjects), a depth proxy and linear-light bokeh. |
| **VIDEO** | Records with the look previewed live. Save it as shot, as flat **AF-Log**, or with the LUT burned in. |

### AF-Log and LUTs
- **AF-Log** is Auto Frame's own log curve: `y = 0.075·log2(x + 0.01) + 0.5997`. 18% grey sits at 0.42, it covers about 14 stops, and black is lifted to about 0.10 for grading.
- Live **AF-Log monitoring**, **LUT preview**, **zebras** and **focus peaking** run as GPU shaders on the viewfinder.
- Built-in looks: AF-Log → Rec.709, AF Cinematic, Teal & Orange, Golden Hour Film, Nordic Fade, Chroma Pop, Bleach Bypass, Noir.
- Import any `.cube` file (3D or 1D) and tag it as Rec.709-input or AF-Log-input. Any look exports as `.cube` for Resolve or Premiere.
- Video LUT baking is native: **Media3 Transformer** on Android, **AVFoundation + Core Image** on iOS.

### Develop (Lightroom-style editor)
- **Light:** exposure, contrast, highlights, shadows, whites, blacks
- **Color:** temperature, tint, vibrance (skin-protecting), saturation
- **Effects:** clarity, dehaze, vignette, film grain and grain size. **Detail:** sharpening
- **HSL:** eight bands × hue, saturation and luminance
- **Point curves:** RGB plus R, G and B (monotone cubic, so tones never invert)
- **Color grading:** shadow and highlight wheels, plus balance
- **Looks:** LUT thumbnails with an intensity slider
- **Presets:** Natural, Vivid, Moody, Film, Airy, Portrait Glow, B&W Matte
- **Crop & straighten**, with an **Auto Frame** button for any aspect ratio
- Live histogram, press-and-hold to compare, undo/redo
- Edits are non-destructive and stored as `photo.jpg.af.json` sidecars
- The preview and the full-resolution export use the **same GPU shader**, so what you see is what you save.

Everything runs on the device. No photo ever leaves the phone.

## Architecture

```
lib/
  core/                 Pure Dart, unit-tested, no Flutter UI
    color/              AF-Log curve, 3D LUTs (.cube I/O, trilinear, GPU atlas), built-in looks
    composition/        Composition engine (crop search and scoring, live guidance), saliency
    processing/         HDR exposure fusion + MTB alignment, synthetic aperture, image planes
    edit/               EditParams (non-destructive recipe), tone curves, presets
  services/             Camera, ML Kit vision, motion/level, shaders, media library,
                        capture pipeline, background isolates, native video LUT channel
  ui/                   Camera, review screens, editor, library
shaders/
  camera_look.frag      Viewfinder: AF-Log, LUT, zebras, peaking (ImageFilter.shader)
  develop.frag          Full develop pipeline (preview + export)
android/.../MainActivity.kt   Media3 video LUT baking
ios/Runner/AppDelegate.swift  AVFoundation video LUT baking
```

Heavy CPU work (HDR fusion, aperture renders, saliency, JPEG encoding) runs in background isolates.

## Running

Requirements: Flutter 3.47+, Xcode 16+ (iOS 15.5+) or the Android SDK (minSdk 24).

```bash
flutter pub get
flutter test             # 39 tests: core algorithms + GPU shader parity
flutter run              # on a physical device (the camera needs real hardware)
```

On iOS, run `cd ios && pod install` once after `flutter pub get`.

## Known limitations
- **Log video is a re-encode.** AF-Log video is encoded *after* recording from the phone's standard video stream. The flat profile grades well, but its dynamic range is bounded by what the sensor pipeline delivered. Native Apple Log / vendor log capture (iPhone 15 Pro+, some Android phones) would need a custom native camera session.
- **Phone apertures are fixed.** Aperture mode simulates depth of field. Person segmentation is precise; other subjects use a soft elliptical mask.
- **HDR+ size and alignment.** HDR+ merges at up to 3000 px on the long side to keep memory in check. Alignment corrects handheld shift, not rotation.
- **Shaders need Impeller** (the default on iOS and modern Android) for the live viewfinder look. The editor works everywhere.
- **Manual ISO and shutter speed** are not exposed by the Flutter `camera` plugin. Exposure compensation is.
