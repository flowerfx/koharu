package com.kurubyinteractive.aimanga.ui

import android.net.Uri
import androidx.activity.compose.BackHandler
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.FolderOpen
import androidx.compose.material.icons.rounded.PhotoLibrary
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.LifecycleResumeEffect
import coil3.compose.AsyncImage
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.R
import com.kurubyinteractive.aimanga.data.Album
import com.kurubyinteractive.aimanga.data.DeviceImages
import com.kurubyinteractive.aimanga.data.MediaAccess
import com.kurubyinteractive.aimanga.naturalCompare

/**
 * In-app page import in the app's own theme: device folders, then pages in
 * file-name order with multi-select. The system file picker remains for
 * sources MediaStore does not index (cloud drives, other apps).
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ImportScreen(model: AppViewModel, nextChapter: Int, projectId: String?, onBack: () -> Unit) {
    val context = LocalContext.current
    var access by remember { mutableStateOf(DeviceImages.access(context)) }
    var albums by remember { mutableStateOf<List<Album>?>(null) }
    var openAlbum by rememberSaveable { mutableStateOf<Long?>(null) }
    var selected by remember { mutableStateOf<List<Uri>>(emptyList()) }
    var pending by remember { mutableStateOf<Pair<List<Uri>, String>?>(null) }
    var fromFiles by remember { mutableStateOf(false) }

    // Access can change in system settings while the app is in the background.
    LifecycleResumeEffect(Unit) {
        access = DeviceImages.access(context)
        onPauseOrDispose {}
    }
    LaunchedEffect(access) {
        albums = if (access == MediaAccess.NONE) null else DeviceImages.albums(context, ::naturalCompare)
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        access = DeviceImages.access(context)
    }
    val files = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        if (uris.isNotEmpty()) fromFiles = true
        if (uris.isNotEmpty()) pending = uris to context.getString(R.string.default_chapter_title, nextChapter)
    }

    val album = albums?.firstOrNull { it.id == openAlbum }
    val closeAlbum = { openAlbum = null; selected = emptyList() }
    BackHandler(enabled = album != null, onBack = closeAlbum)

    Scaffold(
        containerColor = MaterialTheme.colorScheme.surface,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(album?.name ?: stringResource(R.string.import_pages), fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        if (album != null) {
                            Text(
                                pluralStringResource(R.plurals.album_count, album.images.size, album.images.size),
                                style = MaterialTheme.typography.labelMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = if (album != null) closeAlbum else onBack) {
                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
                actions = {
                    if (album != null) {
                        val all = selected.size == album.images.size
                        TextButton(onClick = { selected = if (all) emptyList() else album.images.map { it.uri } }) {
                            Text(stringResource(if (all) R.string.import_clear else R.string.import_select_all))
                        }
                    } else {
                        IconButton(onClick = { files.launch(arrayOf("image/*")) }) {
                            Icon(Icons.Rounded.FolderOpen, contentDescription = stringResource(R.string.import_browse_files))
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
            )
        },
        bottomBar = {
            AnimatedVisibility(selected.isNotEmpty(), enter = slideInVertically { it }, exit = slideOutVertically { it }) {
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainerHigh,
                    shape = CircleShape,
                    shadowElevation = 6.dp,
                    modifier = Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 12.dp, vertical = 10.dp),
                ) {
                    Row(Modifier.padding(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            pluralStringResource(R.plurals.import_selected, selected.size, selected.size),
                            style = MaterialTheme.typography.titleSmall,
                            modifier = Modifier.weight(1f).padding(start = 16.dp),
                        )
                        Button(
                            onClick = { fromFiles = false; pending = selected to (album?.name ?: context.getString(R.string.default_chapter_title, nextChapter)) },
                            shapes = ButtonDefaults.shapes(),
                            contentPadding = PaddingValues(horizontal = 22.dp, vertical = 12.dp),
                        ) { Text(stringResource(R.string.import_action)) }
                    }
                }
            }
        },
    ) { padding ->
        Box(Modifier.fillMaxSize().padding(padding)) {
            when {
                access == MediaAccess.NONE -> AccessPrompt(
                    onAllow = { permission.launch(DeviceImages.permissions) },
                    onBrowse = { files.launch(arrayOf("image/*")) },
                )
                albums == null -> LoadingIndicator(Modifier.align(Alignment.Center).size(64.dp))
                album == null -> AlbumGrid(
                    albums = albums.orEmpty(),
                    partial = access == MediaAccess.PARTIAL,
                    onMore = { permission.launch(DeviceImages.permissions) },
                    onBrowse = { files.launch(arrayOf("image/*")) },
                    onOpen = { openAlbum = it.id; selected = emptyList() },
                )
                else -> PageGrid(album, selected, onToggle = { uri ->
                    selected = if (uri in selected) selected - uri else selected + uri
                })
            }
        }
    }

    pending?.let { (uris, suggested) ->
        var title by rememberSaveable(uris) { mutableStateOf(suggested) }
        AlertDialog(
            onDismissRequest = { pending = null },
            icon = { Icon(Icons.Rounded.PhotoLibrary, contentDescription = null) },
            title = { Text(stringResource(R.string.new_chapter)) },
            text = {
                Column {
                    Text(pluralStringResource(R.plurals.pages_selected, uris.size, uris.size))
                    Spacer(Modifier.height(16.dp))
                    OutlinedTextField(
                        value = title,
                        onValueChange = { title = it },
                        singleLine = true,
                        shape = MaterialTheme.shapes.medium,
                        label = { Text(stringResource(R.string.chapter_title)) },
                    )
                }
            },
            confirmButton = {
                Button(enabled = title.isNotBlank(), onClick = {
                    model.import(title.trim(), uris, sortByName = fromFiles, projectId = projectId)
                    pending = null
                    onBack()
                }) { Text(stringResource(R.string.add)) }
            },
            dismissButton = { TextButton(onClick = { pending = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun AccessPrompt(onAllow: () -> Unit, onBrowse: () -> Unit) {
    Column(
        Modifier.fillMaxSize().padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Image(
            painterResource(R.drawable.app_icon_art),
            contentDescription = null,
            modifier = Modifier.size(112.dp).clip(RoundedCornerShape(28.dp)),
        )
        Spacer(Modifier.height(24.dp))
        Text(stringResource(R.string.import_access_title), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.import_access_body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(24.dp))
        Button(onClick = onAllow, contentPadding = PaddingValues(horizontal = 28.dp, vertical = 14.dp)) {
            Icon(Icons.Rounded.PhotoLibrary, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.import_allow))
        }
        Spacer(Modifier.height(8.dp))
        OutlinedButton(onClick = onBrowse) { Text(stringResource(R.string.import_browse_files)) }
    }
}

@Composable
private fun AlbumGrid(albums: List<Album>, partial: Boolean, onMore: () -> Unit, onBrowse: () -> Unit, onOpen: (Album) -> Unit) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(150.dp),
        contentPadding = PaddingValues(16.dp),
        horizontalArrangement = Arrangement.spacedBy(14.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        if (partial) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Card(
                    shape = MaterialTheme.shapes.large,
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer),
                ) {
                    Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text(stringResource(R.string.import_partial), style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                        TextButton(onClick = onMore) { Text(stringResource(R.string.import_more)) }
                    }
                }
            }
        }
        if (albums.isEmpty()) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.fillMaxWidth().padding(vertical = 48.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(stringResource(R.string.import_no_images), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.height(12.dp))
                    OutlinedButton(onClick = onBrowse) { Text(stringResource(R.string.import_browse_files)) }
                }
            }
        }
        items(albums, key = { it.id }) { album ->
            Column(Modifier.clip(MaterialTheme.shapes.large).clickable { onOpen(album) }.padding(bottom = 6.dp)) {
                AsyncImage(
                    model = album.cover,
                    contentDescription = null,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .fillMaxWidth()
                        .aspectRatio(1f)
                        .clip(MaterialTheme.shapes.large)
                        .background(MaterialTheme.colorScheme.surfaceContainerHighest),
                )
                Spacer(Modifier.height(8.dp))
                Text(album.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(horizontal = 4.dp))
                Text(
                    pluralStringResource(R.plurals.album_count, album.images.size, album.images.size),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(horizontal = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun PageGrid(album: Album, selected: List<Uri>, onToggle: (Uri) -> Unit) {
    LazyVerticalGrid(
        columns = GridCells.Adaptive(108.dp),
        contentPadding = PaddingValues(12.dp, 12.dp, 12.dp, 96.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        items(album.images, key = { it.uri.toString() }) { image ->
            val order = selected.indexOf(image.uri)
            val chosen = order >= 0
            Box(
                Modifier
                    .aspectRatio(0.7f)
                    .clip(MaterialTheme.shapes.medium)
                    .then(if (chosen) Modifier.border(3.dp, MaterialTheme.colorScheme.primary, MaterialTheme.shapes.medium) else Modifier)
                    .clickable { onToggle(image.uri) },
            ) {
                AsyncImage(
                    model = image.uri,
                    contentDescription = image.name,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceContainerHighest),
                )
                Text(
                    image.name,
                    style = MaterialTheme.typography.labelSmall,
                    color = Color.White,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.align(Alignment.BottomStart).fillMaxWidth()
                        .background(Color.Black.copy(alpha = 0.55f)).padding(horizontal = 6.dp, vertical = 3.dp),
                )
                // Selection number is the page order of the new chapter.
                Box(
                    Modifier
                        .align(Alignment.TopEnd)
                        .padding(6.dp)
                        .size(26.dp)
                        .clip(CircleShape)
                        .background(if (chosen) MaterialTheme.colorScheme.primary else Color.Black.copy(alpha = 0.35f))
                        .border(2.dp, Color.White, CircleShape),
                    contentAlignment = Alignment.Center,
                ) {
                    if (chosen) {
                        Text("${order + 1}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onPrimary)
                    }
                }
            }
        }
    }
}
