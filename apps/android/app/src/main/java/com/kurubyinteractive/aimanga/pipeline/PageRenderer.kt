package com.kurubyinteractive.aimanga.pipeline

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import com.kurubyinteractive.aimanga.data.Segment
import uniffi.koharu_core.Rect
import uniffi.koharu_core.bubbleGroups
import java.io.File
import kotlin.math.max
import kotlin.math.min

/** Decodes a page, bounding its longest side so OCR and rendering stay in memory. */
fun decodePage(file: File, maxSide: Int = 3072): Bitmap {
    val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
    BitmapFactory.decodeFile(file.path, bounds)
    var sample = 1
    while (max(bounds.outWidth, bounds.outHeight) / sample > maxSide) sample *= 2
    val options = BitmapFactory.Options().apply {
        inSampleSize = sample
        inPreferredConfig = Bitmap.Config.ARGB_8888
        inMutable = true
    }
    return requireNotNull(BitmapFactory.decodeFile(file.path, options)) { "Could not decode ${file.name}" }
}

/**
 * Port of the iPad white-box cleanup and text placement: erase each translated
 * OCR region, then letter the translation into its speech bubble (found by the
 * Rust core) or, outside a closed bubble, into the padded OCR box.
 */
object PageRenderer {
    fun render(source: Bitmap, segments: List<Segment>): Bitmap {
        val width = source.width
        val height = source.height
        val shown = segments.filter { it.translation != null }
        val output = source.copy(Bitmap.Config.ARGB_8888, true)
        val canvas = Canvas(output)

        // Bubbles are found on the untouched page, before any region is erased.
        val boxes = shown.map { pixels(it, width, height, pad = 2.0) }
        val groups = bubbleGroups(luminance(source), width.toUInt(), height.toUInt(), boxes.map { it.toRect() })
        val inBubble = groups.filter { it.members.size > 1 || it.rect != boxes[it.members[0].toInt()].toRect() }
            .flatMap { it.members }.map { it.toInt() }.toSet()

        // Cover every padded OCR mask before drawing any translation, so
        // overlapping regions never erase text drawn for another region.
        // Divergence from iPad: the grey outline is drawn only outside a closed
        // bubble; inside one, the white card already matches the bubble.
        val fill = Paint().apply { color = Color.WHITE }
        val stroke = Paint().apply { color = Color.rgb(128, 128, 128); style = Paint.Style.STROKE; strokeWidth = 1f }
        for ((index, segment) in shown.withIndex()) {
            val box = pixels(segment, width, height, pad = 3.0)
            canvas.drawRect(box, fill)
            if (index !in inBubble && box.width() > 1 && box.height() > 1) {
                canvas.drawRect(RectF(box).apply { inset(0.5f, 0.5f) }, stroke)
            }
        }
        val paint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
            color = Color.BLACK
            typeface = Typeface.DEFAULT_BOLD
        }
        val maxText = max(10f, width * 0.045f)
        for (group in groups) {
            val text = group.members.mapNotNull { shown[it.toInt()].translation }.filter { it.isNotEmpty() }.joinToString(" ")
            val r = group.rect
            if (text.isEmpty() || r.width <= 1 || r.height <= 1) continue
            val boxWidth = max(1, (r.width - 4).toInt())
            val boxHeight = max(1, (r.height - 2).toInt())
            val layout = fit(text, paint, boxWidth, boxHeight, maxText)
            canvas.save()
            canvas.translate((r.x + 2).toFloat(), (r.y + r.height / 2 - layout.height / 2.0).toFloat())
            layout.draw(canvas)
            canvas.restore()
        }
        return output
    }

    private fun RectF.toRect() = Rect(left.toDouble(), top.toDouble(), width().toDouble(), height().toDouble())

    private fun pixels(segment: Segment, width: Int, height: Int, pad: Double): RectF {
        val left = max(0.0, segment.x * width - pad)
        val top = max(0.0, segment.y * height - pad)
        val right = min(width.toDouble(), (segment.x + segment.width) * width + pad)
        val bottom = min(height.toDouble(), (segment.y + segment.height) * height + pad)
        return RectF(left.toFloat(), top.toFloat(), max(left, right).toFloat(), max(top, bottom).toFloat())
    }

    private fun luminance(bitmap: Bitmap): ByteArray {
        val pixels = IntArray(bitmap.width * bitmap.height)
        bitmap.getPixels(pixels, 0, bitmap.width, 0, 0, bitmap.width, bitmap.height)
        return ByteArray(pixels.size) { i ->
            val p = pixels[i]
            ((299 * (p shr 16 and 0xFF) + 587 * (p shr 8 and 0xFF) + 114 * (p and 0xFF)) / 1000).toByte()
        }
    }

    /** Largest text size whose wrapped layout fits the box. */
    private fun fit(text: String, paint: TextPaint, width: Int, height: Int, maxSize: Float): StaticLayout {
        fun layout(size: Float): StaticLayout {
            paint.textSize = size
            return StaticLayout.Builder.obtain(text, 0, text.length, TextPaint(paint), width)
                .setAlignment(Layout.Alignment.ALIGN_CENTER)
                .setBreakStrategy(Layout.BREAK_STRATEGY_HIGH_QUALITY)
                .setHyphenationFrequency(Layout.HYPHENATION_FREQUENCY_NORMAL)
                .setIncludePad(false)
                .setLineSpacing(0f, 0.95f)
                .build()
        }
        var lo = 6f
        var hi = max(lo, min(maxSize, height.toFloat()))
        repeat(10) {
            val mid = (lo + hi) / 2
            if (layout(mid).height <= height) lo = mid else hi = mid
        }
        return layout(lo)
    }
}
