package com.kurubyinteractive.aimanga.data

import android.Manifest
import android.content.ContentUris
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class DeviceImage(val uri: Uri, val name: String, val albumId: Long, val album: String, val modified: Long)

data class Album(val id: Long, val name: String, val cover: Uri, val images: List<DeviceImage>)

enum class MediaAccess { NONE, PARTIAL, FULL }

/** Images the app may read through MediaStore, grouped into their folders. */
object DeviceImages {
    /** Permissions requested for in-app browsing, by platform version. */
    val permissions: Array<String> = when {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE ->
            arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU -> arrayOf(Manifest.permission.READ_MEDIA_IMAGES)
        else -> arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

    fun access(context: Context): MediaAccess {
        fun granted(permission: String) =
            ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
        return when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && granted(Manifest.permission.READ_MEDIA_IMAGES) -> MediaAccess.FULL
            Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU && granted(Manifest.permission.READ_EXTERNAL_STORAGE) -> MediaAccess.FULL
            // Android 14+: the user shared only some photos.
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE &&
                granted(Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) -> MediaAccess.PARTIAL
            else -> MediaAccess.NONE
        }
    }

    /** Albums, most recently changed first; images inside an album in page (file-name) order. */
    suspend fun albums(context: Context, compare: (String, String) -> Int): List<Album> = withContext(Dispatchers.IO) {
        val projection = arrayOf(
            MediaStore.Images.Media._ID,
            MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.BUCKET_ID,
            MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
            MediaStore.Images.Media.DATE_MODIFIED,
        )
        val images = mutableListOf<DeviceImage>()
        context.contentResolver.query(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val id = cursor.getLong(0)
                images += DeviceImage(
                    uri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id),
                    name = cursor.getString(1).orEmpty(),
                    albumId = cursor.getLong(2),
                    album = cursor.getString(3).orEmpty(),
                    modified = cursor.getLong(4),
                )
            }
        }
        images.groupBy { it.albumId }.map { (id, items) ->
            val sorted = items.sortedWith { a, b -> compare(a.name, b.name) }
            Album(id, items.first().album, sorted.first().uri, sorted)
        }.sortedByDescending { album -> album.images.maxOf { it.modified } }
    }
}
