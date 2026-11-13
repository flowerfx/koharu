package com.kurubyinteractive.aimanga.ui

import android.text.format.Formatter
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Memory
import androidx.compose.material.icons.rounded.SaveAlt
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import com.kurubyinteractive.aimanga.AnimeBlock
import com.kurubyinteractive.aimanga.AnimeStudioModel
import com.kurubyinteractive.aimanga.R
import com.kurubyinteractive.aimanga.data.AnimeImage
import kotlinx.coroutines.launch

private val SIZES = listOf(512 to 512, 768 to 1024, 720 to 1280, 1024 to 1024, 1024 to 1280)

@OptIn(ExperimentalMaterial3ExpressiveApi::class, ExperimentalLayoutApi::class)
@Composable
fun AnimeStudioScreen(studio: AnimeStudioModel, safetyMode: String, translating: Boolean) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val model by studio.model.collectAsStateWithLifecycle()
    val generation by studio.generation.collectAsStateWithLifecycle()
    val images by studio.store.images.collectAsStateWithLifecycle()
    val config = studio.config
    var prompt by rememberSaveable { mutableStateOf("") }
    var size by rememberSaveable { mutableStateOf(SIZES.indexOfFirst { it.first == config?.width?.toInt() && it.second == config.height.toInt() }.coerceAtLeast(0)) }
    var steps by rememberSaveable { mutableStateOf(config?.steps?.toInt() ?: 6) }
    var viewing by remember { mutableStateOf<AnimeImage?>(null) }
    var confirmDeleteModel by remember { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(Unit) { studio.errors.collect { snackbar.showSnackbar(errorText(context, it)) } }
    val busy = generation != null
    val block = studio.deviceBlock ?: AnimeBlock.CONTENT_REVIEW.takeIf { safetyMode != "none-safe" }

    Box(Modifier.fillMaxSize()) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(150.dp),
            contentPadding = PaddingValues(16.dp, 0.dp, 16.dp, 24.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxSize(),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.statusBarsPadding().padding(top = 20.dp, bottom = 4.dp)) {
                    Text(stringResource(R.string.anime_title), style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.SemiBold)
                    Text(stringResource(R.string.anime_subtitle), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (block != null) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Notice(
                        Icons.Rounded.Info,
                        stringResource(
                            when (block) {
                                AnimeBlock.UNSUPPORTED_ABI -> R.string.anime_unsupported
                                AnimeBlock.MEMORY -> R.string.anime_memory
                                AnimeBlock.CONTENT_REVIEW -> R.string.anime_review_required
                            },
                        ),
                    )
                }
            }
            if (config != null) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    ModelCard(
                        name = config.name,
                        size = Formatter.formatFileSize(context, studio.totalBytes),
                        ready = model.ready,
                        downloading = model.downloading,
                        done = model.done,
                        total = model.total,
                        onDownload = studio::download,
                        onCancel = studio::cancelDownload,
                        onDelete = { confirmDeleteModel = true },
                        sizeText = { Formatter.formatFileSize(context, it) },
                    )
                }
            }
            item(span = { GridItemSpan(maxLineSpan) }) {
                Card(
                    shape = MaterialTheme.shapes.extraLarge,
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
                ) {
                    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                        OutlinedTextField(
                            value = prompt,
                            onValueChange = { if (it.length <= 4096) prompt = it },
                            label = { Text(stringResource(R.string.anime_prompt)) },
                            placeholder = { Text(stringResource(R.string.anime_prompt_hint)) },
                            supportingText = { Text("${prompt.length}/4096") },
                            minLines = 4,
                            shape = MaterialTheme.shapes.medium,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Text(stringResource(R.string.anime_size), style = MaterialTheme.typography.labelLarge)
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            SIZES.forEachIndexed { index, (w, h) ->
                                FilterChip(selected = size == index, onClick = { size = index }, label = { Text("$w × $h") })
                            }
                        }
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(stringResource(R.string.anime_steps), style = MaterialTheme.typography.labelLarge, modifier = Modifier.weight(1f))
                            Text("$steps", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                        }
                        Slider(value = steps.toFloat(), onValueChange = { steps = it.toInt() }, valueRange = 5f..20f, steps = 14)
                        AnimatedVisibility(generation != null) {
                            val g = generation
                            GenerationProgress(
                                text = when {
                                    g == null -> ""
                                    g.phase == 1 -> stringResource(R.string.anime_loading)
                                    g.phase == 3 -> stringResource(R.string.anime_saving)
                                    g.steps > 0 -> stringResource(R.string.anime_generating_step, g.step, g.steps)
                                    else -> stringResource(R.string.anime_generating)
                                },
                                fraction = g?.takeIf { it.steps > 0 }?.let { it.step.toFloat() / it.steps },
                                onCancel = studio::cancelGeneration,
                            )
                        }
                        Button(
                            onClick = {
                                val (w, h) = SIZES[size]
                                studio.generate(prompt, w, h, steps, safetyMode, translating)
                            },
                            enabled = model.ready && !busy && prompt.isNotBlank() && block == null && !translating,
                            shapes = ButtonDefaults.shapes(),
                            contentPadding = PaddingValues(vertical = 16.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Icon(Icons.Rounded.AutoAwesome, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(stringResource(R.string.anime_generate), style = MaterialTheme.typography.titleSmall)
                        }
                    }
                }
            }
            if (images.isNotEmpty()) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    Text(stringResource(R.string.anime_gallery), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
                }
            }
            items(images, key = { it.id }) { image ->
                AsyncImage(
                    model = studio.store.file(image),
                    contentDescription = image.prompt,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier
                        .aspectRatio(image.width.toFloat() / image.height)
                        .clip(MaterialTheme.shapes.large)
                        .background(MaterialTheme.colorScheme.surfaceContainerHighest)
                        .clickable { viewing = image },
                )
            }
        }
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(16.dp))
    }

    viewing?.let { image ->
        ImageViewer(
            image = image,
            file = studio.store.file(image),
            onDismiss = { viewing = null },
            onReuse = { prompt = image.prompt; viewing = null },
            onSave = {
                studio.export(image) { saved ->
                    scope.launch { snackbar.showSnackbar(context.getString(if (saved) R.string.anime_saved else R.string.anime_save_failed)) }
                }
            },
            onDelete = { studio.delete(image); viewing = null },
        )
    }
    if (confirmDeleteModel) {
        AlertDialog(
            onDismissRequest = { confirmDeleteModel = false },
            title = { Text(stringResource(R.string.anime_delete_model_title)) },
            text = { Text(stringResource(R.string.anime_delete_model_body, Formatter.formatFileSize(context, studio.totalBytes))) },
            confirmButton = {
                Button(
                    onClick = { studio.deleteModel(); confirmDeleteModel = false },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError),
                ) { Text(stringResource(R.string.delete)) }
            },
            dismissButton = { TextButton(onClick = { confirmDeleteModel = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

@Composable
private fun Notice(icon: ImageVector, text: String) {
    Card(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer, contentColor = MaterialTheme.colorScheme.onTertiaryContainer),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null)
            Spacer(Modifier.width(12.dp))
            Text(text, style = MaterialTheme.typography.bodyMedium)
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ModelCard(
    name: String,
    size: String,
    ready: Boolean,
    downloading: Boolean,
    done: Long,
    total: Long,
    onDownload: () -> Unit,
    onCancel: () -> Unit,
    onDelete: () -> Unit,
    sizeText: (Long) -> String,
) {
    Card(
        shape = MaterialTheme.shapes.extraLarge,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(color = MaterialTheme.colorScheme.primaryContainer, shape = CircleShape) {
                    Icon(Icons.Rounded.Memory, contentDescription = null, tint = MaterialTheme.colorScheme.onPrimaryContainer, modifier = Modifier.padding(8.dp).size(20.dp))
                }
                Spacer(Modifier.width(12.dp))
                Column(Modifier.weight(1f)) {
                    Text(name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(stringResource(R.string.anime_model_files, size), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (ready) Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            }
            when {
                downloading -> {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(
                                stringResource(R.string.anime_downloading, sizeText(done), sizeText(total)),
                                style = MaterialTheme.typography.bodyMedium,
                            )
                            LinearWavyProgressIndicator(progress = { if (total > 0) done.toFloat() / total else 0f }, modifier = Modifier.fillMaxWidth())
                        }
                        Spacer(Modifier.width(12.dp))
                        FilledTonalIconButton(onClick = onCancel) { Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.cancel)) }
                    }
                }
                ready -> TextButton(onClick = onDelete) {
                    Icon(Icons.Rounded.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.anime_delete_model))
                }
                else -> FilledTonalButton(onClick = onDownload, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Rounded.Download, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.anime_download_model, size))
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun GenerationProgress(text: String, fraction: Float?, onCancel: () -> Unit) {
    Card(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer, contentColor = MaterialTheme.colorScheme.onPrimaryContainer),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(text, style = MaterialTheme.typography.bodyMedium)
                if (fraction != null) LinearWavyProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
                else LinearWavyProgressIndicator(Modifier.fillMaxWidth())
            }
            Spacer(Modifier.width(12.dp))
            FilledTonalIconButton(onClick = onCancel) { Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.cancel)) }
        }
    }
}

@Composable
private fun ImageViewer(
    image: AnimeImage,
    file: java.io.File,
    onDismiss: () -> Unit,
    onReuse: () -> Unit,
    onSave: () -> Unit,
    onDelete: () -> Unit,
) {
    Dialog(onDismissRequest = onDismiss, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(color = MaterialTheme.colorScheme.surfaceContainerLowest, modifier = Modifier.fillMaxSize()) {
            Column(Modifier.fillMaxSize().statusBarsPadding()) {
                Row(Modifier.fillMaxWidth().padding(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    FilledTonalIconButton(onClick = onDismiss) { Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.back)) }
                    Spacer(Modifier.weight(1f))
                    FilledTonalIconButton(onClick = onSave) { Icon(Icons.Rounded.SaveAlt, contentDescription = stringResource(R.string.anime_save)) }
                    Spacer(Modifier.width(8.dp))
                    FilledTonalIconButton(onClick = onDelete) { Icon(Icons.Rounded.Delete, contentDescription = stringResource(R.string.delete)) }
                }
                AsyncImage(
                    model = file,
                    contentDescription = image.prompt,
                    modifier = Modifier.weight(1f).fillMaxWidth().padding(horizontal = 8.dp),
                )
                Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(image.prompt, style = MaterialTheme.typography.bodyMedium, maxLines = 4, overflow = TextOverflow.Ellipsis)
                    Text(
                        "${image.width} × ${image.height} · ${image.steps} steps · seed ${image.seed}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.height(4.dp))
                    FilledTonalButton(onClick = onReuse) { Text(stringResource(R.string.anime_reuse_prompt)) }
                }
            }
        }
    }
}
