package com.kurubyinteractive.aimanga.data

import android.content.ContentValues
import android.content.Context
import android.graphics.Bitmap
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/** One image made in Anime Studio (iPad `GeneratedAnimeImage`). */
data class AnimeImage(
    val id: String,
    val created: Long,
    val prompt: String,
    val seed: Long,
    val modelId: String,
    val width: Int,
    val height: Int,
    val steps: Int,
) {
    val filename: String get() = "$id.png"
}

/** Generated images: `anime/<id>.png` plus the `anime/images.json` inventory. */
class AnimeStore(private val context: Context) {
    private val root = File(context.filesDir, "anime").apply { mkdirs() }
    private val inventory = File(root, "images.json")
    private val state = MutableStateFlow(load())
    val images: StateFlow<List<AnimeImage>> = state.asStateFlow()

    fun file(image: AnimeImage) = File(root, image.filename)

    suspend fun add(bitmap: Bitmap, prompt: String, seed: Long, modelId: String, steps: Int): AnimeImage =
        withContext(Dispatchers.IO) {
            val image = AnimeImage(UUID.randomUUID().toString(), System.currentTimeMillis(), prompt, seed, modelId, bitmap.width, bitmap.height, steps)
            val destination = file(image)
            destination.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            try {
                save(listOf(image) + state.value)
            } catch (error: Throwable) {
                destination.delete()
                throw error
            }
            image
        }

    /** Commits the inventory before unlinking PNGs, so no record points at a deleted image. */
    suspend fun delete(image: AnimeImage) = withContext(Dispatchers.IO) {
        save(state.value.filter { it.id != image.id })
        file(image).delete()
    }

    /** Copies an image into the shared Pictures collection (Android 10+). */
    suspend fun export(image: AnimeImage): Boolean = withContext(Dispatchers.IO) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return@withContext false
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "anime-${image.id.take(8)}.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/AI Manga Translator")
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values) ?: return@withContext false
        resolver.openOutputStream(uri)?.use { out -> file(image).inputStream().use { it.copyTo(out) } } != null
    }

    private fun save(images: List<AnimeImage>) {
        val temporary = File(root, "images.json.tmp")
        temporary.writeText(JSONArray(images.map { encode(it) }).toString())
        check(temporary.renameTo(inventory)) { "Could not save images" }
        state.value = images
    }

    private fun load(): List<AnimeImage> = runCatching {
        val array = JSONArray(inventory.readText())
        List(array.length()) { decode(array.getJSONObject(it)) }.filter { File(root, it.filename).exists() }
    }.getOrDefault(emptyList())

    private fun encode(image: AnimeImage) = JSONObject().apply {
        put("id", image.id); put("created", image.created); put("prompt", image.prompt); put("seed", image.seed)
        put("modelId", image.modelId); put("width", image.width); put("height", image.height); put("steps", image.steps)
    }

    private fun decode(json: JSONObject) = AnimeImage(
        json.getString("id"), json.getLong("created"), json.getString("prompt"), json.getLong("seed"),
        json.getString("modelId"), json.getInt("width"), json.getInt("height"), json.getInt("steps"),
    )
}
