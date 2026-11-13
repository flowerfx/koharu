package com.kurubyinteractive.aimanga.ui

import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.wrapContentWidth
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import com.kurubyinteractive.aimanga.UpscaleState
import androidx.compose.material3.LoadingIndicator
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material.icons.rounded.VerifiedUser
import androidx.compose.material.icons.rounded.Casino
import androidx.compose.material.icons.rounded.AutoFixHigh
import androidx.compose.ui.res.pluralStringResource
import uniffi.koharu_core.animeActionCost
import uniffi.koharu_core.Provider
import uniffi.koharu_core.PromptOperation
import com.kurubyinteractive.aimanga.PromptSuggestion
import com.kurubyinteractive.aimanga.AppViewModel
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
import uniffi.koharu_core.AnimaConfig
import com.kurubyinteractive.aimanga.AnimaModelState
import androidx.compose.material3.HorizontalDivider
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
fun AnimeStudioScreen(studio: AnimeStudioModel, app: AppViewModel, safetyMode: String, translating: Boolean) {
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
    val assisting by studio.assisting.collectAsStateWithLifecycle()
    val upscale by studio.upscale.collectAsStateWithLifecycle()
    val suggestion by studio.suggestion.collectAsStateWithLifecycle()
    val needsConsent by studio.needsConsent.collectAsStateWithLifecycle()
    val account by app.accountState.collectAsStateWithLifecycle()
    val prefs by app.prefs.collectAsStateWithLifecycle()
    val enabledProviders by app.enabledProviders.collectAsStateWithLifecycle()
    val busy = generation != null || assisting
    val block = studio.deviceBlock
    // half-safe and full-safe review every prompt with Kuruby before use (iPad ContentSafety).
    val safe = safetyMode != "none-safe"
    val providerName = enabledProviders.firstOrNull { it.provider == prefs.provider }?.name ?: prefs.provider.name
    val credits = account.credits
    @Composable
    fun price(action: String): String {
        val cost = credits?.let { animeActionCost(it, action, prefs.provider == Provider.BACKEND).toInt() }
        return if (cost == null) stringResource(R.string.cost_uses_credits) else pluralStringResource(R.plurals.cost_credits, cost, cost)
    }
    val imagePrice = price("image")
    val creditGate = rememberCreditGate(app)
    val enhancePrice = price("enhance")
    val promptPrice = price("generatePrompt")

    Box(Modifier.fillMaxSize()) {
        LazyVerticalGrid(
            columns = GridCells.Adaptive(150.dp),
            contentPadding = PaddingValues(16.dp, 0.dp, 16.dp, 24.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
            // On tablets the studio keeps a readable width, centered.
            modifier = Modifier.fillMaxSize().wrapContentWidth(Alignment.CenterHorizontally).widthIn(max = 1000.dp),
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
                                else -> R.string.anime_unsupported
                            },
                        ),
                    )
                }
            }
            if (config != null) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    ModelCard(
                        config = config,
                        state = model,
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
                        Text(stringResource(R.string.anime_assist_title, providerName), style = MaterialTheme.typography.labelLarge)
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            FilledTonalButton(
                                onClick = { creditGate(CreditKind.PROMPT_ENHANCE) { studio.assist(PromptOperation.ENHANCE, prompt, app.account, app.translatorConfig(), safe) } },
                                enabled = !busy && prompt.isNotBlank() && !translating,
                                modifier = Modifier.weight(1f),
                            ) { AssistLabel(Icons.Rounded.AutoFixHigh, stringResource(R.string.anime_assist_enhance), enhancePrice) }
                            FilledTonalButton(
                                onClick = { creditGate(CreditKind.PROMPT_GENERATE) { studio.assist(PromptOperation.RANDOM_ORIGINAL, "", app.account, app.translatorConfig(), safe) } },
                                enabled = !busy && !translating,
                                modifier = Modifier.weight(1f),
                            ) { AssistLabel(Icons.Rounded.Casino, stringResource(R.string.anime_assist_original), promptPrice) }
                        }
                        if (assisting) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                LoadingIndicator(Modifier.size(32.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(stringResource(R.string.anime_assisting, providerName), style = MaterialTheme.typography.bodyMedium)
                            }
                        }
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
                        UpscaleSection(
                            studio = studio,
                            state = upscale,
                            size = SIZES[size],
                            enabled = !busy && !model.downloading,
                            sizeText = { Formatter.formatFileSize(context, it) },
                        )
                        AnimatedVisibility(generation != null) {
                            val g = generation
                            GenerationProgress(
                                text = when {
                                    g == null -> ""
                                    g.phase == 0 -> stringResource(R.string.anime_reviewing)
                                    g.phase == 1 -> stringResource(R.string.anime_loading)
                                    g.phase == 3 -> stringResource(R.string.anime_saving)
                                    g.phase == 4 -> stringResource(R.string.anime_upscaling)
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
                                creditGate(CreditKind.IMAGE) { studio.generate(prompt, w, h, steps, safe, translating, app.account) }
                            },
                            enabled = model.ready && !busy && prompt.isNotBlank() && block == null && !translating && (!upscale.enabled || upscale.selectedReady),
                            shapes = ButtonDefaults.shapes(),
                            contentPadding = PaddingValues(vertical = 16.dp),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Icon(Icons.Rounded.AutoAwesome, contentDescription = null)
                            Spacer(Modifier.width(8.dp))
                            Text(stringResource(R.string.anime_generate) + " · " + imagePrice, style = MaterialTheme.typography.titleSmall)
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
    suggestion?.let { current ->
        SuggestionDialog(
            suggestion = current,
            providerName = providerName,
            generatePrice = imagePrice,
            canGenerate = model.ready && block == null && !translating && (!upscale.enabled || upscale.selectedReady),
            onDismiss = studio::dismissSuggestion,
        ) { text, generate ->
            prompt = text
            studio.dismissSuggestion()
            if (generate) {
                val (w, h) = SIZES[size]
                creditGate(CreditKind.IMAGE) { studio.generate(text, w, h, steps, safe, translating, app.account) }
            }
        }
    }
    if (needsConsent) {
        AlertDialog(
            onDismissRequest = { studio.resolveConsent(false) },
            icon = { Icon(Icons.Rounded.VerifiedUser, contentDescription = null) },
            title = { Text(stringResource(R.string.anime_review_title)) },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(stringResource(R.string.anime_review_body))
                    Text(stringResource(R.string.anime_review_privacy), style = MaterialTheme.typography.bodySmall)
                }
            },
            confirmButton = { Button(onClick = { studio.resolveConsent(true) }) { Text(stringResource(R.string.anime_review_allow)) } },
            dismissButton = { TextButton(onClick = { studio.resolveConsent(false) }) { Text(stringResource(R.string.anime_review_decline)) } },
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

/**
 * The Anima download card (iPad `AnimeStudioScreen` model section): the
 * diffusion model, text encoder and VAE each with size, file name, status and
 * their own download button; then the total, "Download all" and delete.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ModelCard(
    config: AnimaConfig,
    state: AnimaModelState,
    onDownload: (String?) -> Unit,
    onCancel: () -> Unit,
    onDelete: () -> Unit,
    sizeText: (Long) -> String,
) {
    val total = config.components.sumOf { it.file.bytes.toLong() }
    val missing = config.components.filter { state.parts[it.role] != true }.sumOf { it.file.bytes.toLong() }
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
                    Text(config.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(stringResource(R.string.anime_model_files, sizeText(total)), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                if (state.ready) Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
            }
            config.components.forEach { component ->
                ComponentRow(
                    title = stringResource(
                        when (component.role) {
                            "diffusion" -> R.string.anime_part_diffusion
                            "textEncoder" -> R.string.anime_part_text_encoder
                            else -> R.string.anime_part_vae
                        },
                    ),
                    file = component.file.path,
                    size = sizeText(component.file.bytes.toLong()),
                    ready = state.parts[component.role] == true,
                    active = state.active == component.role,
                    busy = state.downloading,
                    done = state.done,
                    total = state.total,
                    sizeText = sizeText,
                    onDownload = { onDownload(component.role) },
                    onCancel = onCancel,
                )
            }
            HorizontalDivider()
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(stringResource(R.string.anime_total_download), style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
                Text(sizeText(total), style = MaterialTheme.typography.titleSmall)
            }
            when {
                state.ready -> TextButton(onClick = onDelete, enabled = !state.downloading) {
                    Icon(Icons.Rounded.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.anime_delete_models))
                }
                else -> FilledTonalButton(onClick = { onDownload(null) }, enabled = !state.downloading, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Rounded.Download, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.anime_download_all, sizeText(missing)))
                }
            }
            Text(stringResource(R.string.anime_sha_note), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/** One Anima file: name, size, and its download/progress/ready state. */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ComponentRow(
    title: String,
    file: String,
    size: String,
    ready: Boolean,
    active: Boolean,
    busy: Boolean,
    done: Long,
    total: Long,
    sizeText: (Long) -> String,
    onDownload: () -> Unit,
    onCancel: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleSmall)
                Text("$size · $file", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.width(8.dp))
            when {
                ready -> Icon(Icons.Rounded.CheckCircle, contentDescription = stringResource(R.string.anime_part_ready), tint = MaterialTheme.colorScheme.primary)
                active -> FilledTonalIconButton(onClick = onCancel) { Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.cancel)) }
                else -> FilledTonalIconButton(onClick = onDownload, enabled = !busy) {
                    Icon(Icons.Rounded.Download, contentDescription = stringResource(R.string.anime_download_part, title))
                }
            }
        }
        if (active) {
            Text(stringResource(R.string.anime_downloading, sizeText(done), sizeText(total)), style = MaterialTheme.typography.bodySmall)
            LinearWavyProgressIndicator(progress = { if (total > 0) done.toFloat() / total else 0f }, modifier = Modifier.fillMaxWidth())
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

@Composable
private fun AssistLabel(icon: ImageVector, title: String, price: String) {
    Icon(icon, contentDescription = null, modifier = Modifier.size(18.dp))
    Spacer(Modifier.width(6.dp))
    Column {
        Text(title, style = MaterialTheme.typography.labelLarge, maxLines = 2)
        Text(price, style = MaterialTheme.typography.labelSmall)
    }
}

/**
 * Review of a provider-written prompt (iPad `AnimePromptReview`): editable;
 * the user's own prompt stays unchanged until "Use prompt".
 */
@Composable
private fun SuggestionDialog(
    suggestion: PromptSuggestion,
    providerName: String,
    generatePrice: String,
    canGenerate: Boolean,
    onDismiss: () -> Unit,
    onApply: (String, Boolean) -> Unit,
) {
    var draft by rememberSaveable(suggestion) { mutableStateOf(suggestion.prompt) }
    val valid = draft.isNotBlank() && draft.length <= 4096
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.anime_suggestion_title)) },
        text = {
            Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(stringResource(R.string.anime_suggestion_provider, providerName), style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                if (suggestion.character.isNotBlank()) Text(suggestion.character, style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(
                    value = draft,
                    onValueChange = { if (it.length <= 4096) draft = it },
                    label = { Text(stringResource(R.string.anime_suggestion_label)) },
                    minLines = 6,
                    modifier = Modifier.fillMaxWidth(),
                )
                Text(stringResource(R.string.anime_suggestion_note), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Button(onClick = { onApply(draft.trim(), true) }, enabled = valid && canGenerate, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Rounded.AutoAwesome, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text(stringResource(R.string.anime_suggestion_generate, generatePrice))
                }
            }
        },
        confirmButton = { TextButton(onClick = { onApply(draft.trim(), false) }, enabled = valid) { Text(stringResource(R.string.anime_suggestion_use)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/**
 * Upscale on/off and the RealESRGAN choice (iPad Anime Studio upscaler
 * section). Off keeps the generated size; on needs the selected model.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun UpscaleSection(studio: AnimeStudioModel, state: UpscaleState, size: Pair<Int, Int>, enabled: Boolean, sizeText: (Long) -> String) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(stringResource(R.string.anime_upscale), style = MaterialTheme.typography.labelLarge)
                val factor = if (state.enabled) 4 else 1
                Text(
                    stringResource(R.string.anime_upscale_output, size.first * factor, size.second * factor),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Switch(checked = state.enabled, onCheckedChange = studio::setUpscale, enabled = enabled)
        }
        if (!state.enabled) return@Column
        Text(stringResource(R.string.anime_upscale_hint), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        studio.upscalers.forEach { upscaler ->
            val selected = state.selected == upscaler.id
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth().clip(MaterialTheme.shapes.medium).clickable(enabled = enabled) { studio.selectUpscaler(upscaler.id) }.padding(vertical = 4.dp),
            ) {
                RadioButton(selected = selected, onClick = { studio.selectUpscaler(upscaler.id) }, enabled = enabled)
                Column(Modifier.weight(1f)) {
                    Text(upscaler.name, style = MaterialTheme.typography.titleSmall)
                    Text(
                        sizeText(upscaler.file.bytes.toLong()) + " · " + stringResource(if (upscaler.id == "anime4") R.string.anime_upscaler_anime else R.string.anime_upscaler_general),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (state.ready[upscaler.id] == true) Icon(Icons.Rounded.CheckCircle, contentDescription = stringResource(R.string.anime_part_ready), tint = MaterialTheme.colorScheme.primary)
            }
        }
        val chosen = studio.upscalers.first { it.id == state.selected }
        when {
            state.downloading != null -> Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Text(stringResource(R.string.anime_downloading, sizeText(state.done), sizeText(state.total)), style = MaterialTheme.typography.bodySmall)
                    LinearWavyProgressIndicator(progress = { if (state.total > 0) state.done.toFloat() / state.total else 0f }, modifier = Modifier.fillMaxWidth())
                }
                Spacer(Modifier.width(8.dp))
                FilledTonalIconButton(onClick = studio::cancelDownload) { Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.cancel)) }
            }
            !state.selectedReady -> {
                Text(stringResource(R.string.anime_upscaler_missing), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
                FilledTonalButton(onClick = studio::downloadUpscaler, enabled = enabled, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.Rounded.Download, contentDescription = null)
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(R.string.anime_upscaler_download, sizeText(chosen.file.bytes.toLong())))
                }
            }
            else -> TextButton(onClick = studio::deleteUpscalers, enabled = enabled) {
                Icon(Icons.Rounded.Delete, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text(stringResource(R.string.anime_upscaler_delete))
            }
        }
    }
}
