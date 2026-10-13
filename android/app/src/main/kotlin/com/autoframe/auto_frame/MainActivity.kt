package com.autoframe.auto_frame

import android.net.Uri
import androidx.annotation.OptIn
import androidx.media3.common.MediaItem
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.SingleColorLut
import androidx.media3.transformer.Composition
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.Transformer
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.math.roundToInt

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "bake" -> bake(call, result)
                    "isSupported" -> result.success(true)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * Re-encodes a recorded clip with a 3D LUT applied to every frame.
     *
     * Arguments: input/output paths, LUT size N and N^3*3 floats in .cube
     * order (red fastest, then green, then blue).
     */
    @OptIn(UnstableApi::class)
    private fun bake(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("input")
        val output = call.argument<String>("output")
        val size = call.argument<Int>("size")
        val data = call.argument<FloatArray>("data")
        if (input == null || output == null || size == null || data == null ||
            data.size != size * size * size * 3
        ) {
            result.error("bad_args", "input, output, size and data (N^3*3 floats) are required", null)
            return
        }

        // Media3 indexes the cube as [r][g][b] of packed ARGB ints.
        val cube = Array(size) { Array(size) { IntArray(size) } }
        var i = 0
        for (b in 0 until size) {
            for (g in 0 until size) {
                for (r in 0 until size) {
                    val rr = to8(data[i]); val gg = to8(data[i + 1]); val bb = to8(data[i + 2])
                    cube[r][g][b] = (0xFF shl 24) or (rr shl 16) or (gg shl 8) or bb
                    i += 3
                }
            }
        }

        File(output).delete()
        val edited = EditedMediaItem.Builder(MediaItem.fromUri(Uri.fromFile(File(input))))
            .setEffects(Effects(listOf(), listOf(SingleColorLut.createFromCube(cube))))
            .build()

        val transformer = Transformer.Builder(this)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    result.success(output)
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    result.error("export_failed", exportException.message, null)
                }
            })
            .build()
        transformer.start(edited, output)
    }

    private fun to8(v: Float): Int = (v.coerceIn(0f, 1f) * 255f).roundToInt()

    companion object {
        private const val CHANNEL = "auto_frame/video_lut"
    }
}
