package com.kurubyinteractive.aimanga.pipeline

import android.graphics.Bitmap
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import kotlinx.coroutines.suspendCancellableCoroutine
import uniffi.koharu_core.OcrLine
import uniffi.koharu_core.Rect
import java.io.Closeable
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** On-device Japanese OCR (bundled ML Kit model, no network). */
class JapaneseOcr : Closeable {
    private val recognizer = TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())

    /** Lines in page-normalized coordinates, ready for the Rust region merge. */
    suspend fun lines(bitmap: Bitmap): List<OcrLine> = suspendCancellableCoroutine { continuation ->
        val width = bitmap.width.toDouble()
        val height = bitmap.height.toDouble()
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { text ->
                val lines = text.textBlocks.flatMap { it.lines }.mapNotNull { line ->
                    val box = line.boundingBox ?: return@mapNotNull null
                    if (line.text.isBlank()) return@mapNotNull null
                    // ML Kit reports no writing direction; a tall multi-character
                    // line is a vertical column.
                    val vertical = box.height() > box.width() * 1.3 && line.text.length > 1
                    OcrLine(
                        rect = Rect(box.left / width, box.top / height, box.width() / width, box.height() / height),
                        text = line.text,
                        vertical = vertical,
                    )
                }
                continuation.resume(lines)
            }
            .addOnFailureListener { continuation.resumeWithException(it) }
    }

    override fun close() = recognizer.close()
}
