package com.kurubyinteractive.aimanga.ui

import androidx.compose.ui.platform.LocalContext
import android.text.format.Formatter
import androidx.compose.material.icons.rounded.RadioButtonUnchecked
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.IconButton
import androidx.compose.material.icons.automirrored.rounded.ViewList
import androidx.compose.material.icons.rounded.GridView
import androidx.compose.ui.draw.clip
import com.kurubyinteractive.aimanga.data.seriesName
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.DriveFileMove
import androidx.compose.material.icons.rounded.Folder
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import uniffi.koharu_core.Provider
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.R
import com.kurubyinteractive.aimanga.data.Chapter
import com.kurubyinteractive.aimanga.data.Project
import java.io.File

/** Cover of a chapter: the translated first page when there is one. */
fun AppViewModel.cover(chapter: Chapter?): File? =
    chapter?.pages?.firstOrNull()?.let { library.file(chapter, it.translated ?: it.file) }

/** Poster card with a bottom scrim, shared by chapter and manga/project cards. */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun PosterCard(
    cover: File?,
    title: String,
    subtitle: String,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)?,
    badge: @Composable (Modifier) -> Unit = {},
    placeholder: ImageVector? = null,
    progress: Float? = null,
    overlay: @Composable (Modifier) -> Unit = {},
    selected: Boolean? = null,
) {
    Card(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        border = if (selected == true) BorderStroke(3.dp, MaterialTheme.colorScheme.primary) else null,
        modifier = Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick.takeIf { selected == null }),
    ) {
        Box(Modifier.fillMaxWidth().aspectRatio(0.68f).background(MaterialTheme.colorScheme.surfaceContainerHighest)) {
            if (cover != null) {
                AsyncImage(model = cover, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
            } else if (placeholder != null) {
                Icon(
                    placeholder, contentDescription = null, tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.align(Alignment.Center).size(64.dp),
                )
            }
            // Scrim keeps the title readable over any cover.
            Box(Modifier.fillMaxSize().background(Brush.verticalGradient(0.45f to Color.Transparent, 1f to Color.Black.copy(alpha = 0.78f))))
            if (selected != null) SelectionMark(selected, Modifier.align(Alignment.TopEnd).padding(10.dp), onImage = true)
            else badge(Modifier.align(Alignment.TopEnd).padding(10.dp))
            overlay(Modifier.align(Alignment.Center))
            Column(Modifier.align(Alignment.BottomStart).padding(14.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.85f), maxLines = 2)
            }
        }
        if (progress != null) LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
    }
}

/**
 * List layout (iPad `LibraryChapterRow` / `SeriesRow` / `ProjectRow`): a small
 * cover, the full title and info lines, with an optional progress bar.
 */
@Composable
private fun PosterRow(
    cover: File?,
    title: String,
    lines: List<Pair<String, Boolean>>,
    onClick: () -> Unit,
    onLongClick: (() -> Unit)?,
    placeholder: ImageVector? = null,
    progress: Float? = null,
    trailing: @Composable () -> Unit = {},
    selected: Boolean? = null,
) {
    Card(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        border = if (selected == true) BorderStroke(3.dp, MaterialTheme.colorScheme.primary) else null,
        modifier = Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = onLongClick.takeIf { selected == null }),
    ) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier.size(width = 60.dp, height = 88.dp).clip(MaterialTheme.shapes.medium)
                    .background(MaterialTheme.colorScheme.surfaceContainerHighest),
            ) {
                if (cover != null) AsyncImage(model = cover, contentDescription = null, contentScale = ContentScale.Crop, modifier = Modifier.fillMaxSize())
                else if (placeholder != null) Icon(placeholder, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.align(Alignment.Center).size(32.dp))
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                lines.forEach { (text, accent) ->
                    Text(
                        text,
                        style = MaterialTheme.typography.bodySmall,
                        color = if (accent) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (progress != null) LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth().padding(top = 4.dp))
            }
            if (selected != null) SelectionMark(selected, Modifier) else trailing()
        }
    }
}

/** Selection-mode check: filled when chosen, an empty circle otherwise. */
@Composable
private fun SelectionMark(selected: Boolean, modifier: Modifier, onImage: Boolean = false) {
    Icon(
        if (selected) Icons.Rounded.CheckCircle else Icons.Rounded.RadioButtonUnchecked,
        contentDescription = null,
        tint = if (selected) MaterialTheme.colorScheme.primary else if (onImage) Color.White else MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = modifier.size(28.dp).background(if (onImage) Color.Black.copy(alpha = 0.35f) else Color.Transparent, CircleShape),
    )
}

@Composable
private fun Pill(icon: ImageVector, text: String?, modifier: Modifier) {
    Surface(color = MaterialTheme.colorScheme.primary, contentColor = MaterialTheme.colorScheme.onPrimary, shape = CircleShape, modifier = modifier) {
        Row(Modifier.padding(horizontal = 10.dp, vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, contentDescription = null, modifier = Modifier.size(14.dp))
            if (text != null) {
                Spacer(Modifier.width(4.dp))
                Text(text, style = MaterialTheme.typography.labelSmall)
            }
        }
    }
}

/**
 * A chapter card; long-press opens its actions: open on Rawkuma (source
 * chapters), move to a project (imported chapters) and delete.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ChapterCard(
    model: AppViewModel,
    chapter: Chapter,
    running: Boolean,
    onOpen: () -> Unit,
    onOpenSource: (String) -> Unit,
    list: Boolean = false,
    /** In flat lists, also name the manga or project the chapter belongs to. */
    showsOrigin: Boolean = false,
    /** Selection mode: null when off, otherwise whether this chapter is chosen; taps then toggle via [onOpen]. */
    selected: Boolean? = null,
) {
    var menu by remember { mutableStateOf(false) }
    var moving by remember { mutableStateOf(false) }
    val creditGate = rememberCreditGate(model)
    val run by model.run.collectAsStateWithLifecycle()
    val enabledProviders by model.enabledProviders.collectAsStateWithLifecycle()
    var deleting by remember { mutableStateOf(false) }
    val total = chapter.pages.size
    val done = chapter.translatedPages
    val projects by model.library.projects.collectAsStateWithLifecycle()
    val sizes by model.chapterSizes.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val size = sizes[chapter.id]?.let { " · " + Formatter.formatShortFileSize(context, it) }.orEmpty()
    Box {
        if (list) {
            val origin = when {
                !showsOrigin -> null
                chapter.isImported -> projects.firstOrNull { it.id == chapter.projectId }
                    ?.let { stringResource(R.string.imported_in, it.name) } ?: stringResource(R.string.imported)
                else -> chapter.seriesName
            }
            val language = chapter.target?.let { java.util.Locale.forLanguageTag(it).getDisplayName(java.util.Locale.getDefault()) }
            PosterRow(
                cover = model.cover(chapter),
                title = chapter.title,
                lines = listOfNotNull(
                    origin?.let { it to !chapter.isImported },
                    (pluralStringResource(R.plurals.chapter_progress, total, total, done) + size + (language?.let { " · $it" } ?: "")) to false,
                ),
                onClick = onOpen,
                onLongClick = { menu = true },
                progress = if (total > 0) done.toFloat() / total else null,
                trailing = {
                    if (running) LoadingIndicator(Modifier.size(40.dp))
                    else if (total > 0 && done == total) Icon(Icons.Rounded.CheckCircle, contentDescription = stringResource(R.string.translated), tint = MaterialTheme.colorScheme.primary)
                },
                selected = selected,
            )
        } else PosterCard(
            cover = model.cover(chapter),
            title = chapter.title,
            subtitle = pluralStringResource(R.plurals.chapter_progress, total, total, done) + size,
            onClick = onOpen,
            onLongClick = { menu = true },
            badge = { if (total > 0 && done == total) Pill(Icons.Rounded.CheckCircle, stringResource(R.string.translated), it) },
            progress = if (total > 0 && done in 1 until total) done.toFloat() / total else null,
            overlay = { if (running) LoadingIndicator(it.size(64.dp)) },
            selected = selected,
        )
        DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
            chapter.source?.let { source ->
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.open_chapter_rawkuma)) },
                    leadingIcon = { Icon(Icons.Rounded.Language, contentDescription = null) },
                    onClick = { menu = false; onOpenSource(source) },
                )
            }
            if (run == null && total > 0) {
                DropdownMenuItem(
                    text = { CostText(stringResource(if (done > 0) R.string.retranslate_chapter else R.string.translate), creditCostLabel(model, if (done > 0) CreditKind.RERUN else CreditKind.TRANSLATE)) },
                    leadingIcon = { Icon(Icons.Rounded.Refresh, contentDescription = null) },
                    onClick = {
                        menu = false
                        if (done > 0) creditGate(CreditKind.RERUN) { model.translate(chapter, force = true) }
                        else creditGate(CreditKind.TRANSLATE) { model.translate(chapter) }
                    },
                )
                if (enabledProviders.any { it.provider == Provider.BACKEND }) {
                    DropdownMenuItem(
                        text = { CostText(stringResource(R.string.enhanced_translation), creditCostLabel(model, CreditKind.ENHANCED)) },
                        leadingIcon = { Icon(Icons.Rounded.AutoAwesome, contentDescription = null) },
                        onClick = { menu = false; creditGate(CreditKind.ENHANCED) { model.translate(chapter, enhanced = true) } },
                    )
                }
            }
            if (chapter.isImported) {
                DropdownMenuItem(
                    text = { Text(stringResource(R.string.move_to_project)) },
                    leadingIcon = { Icon(Icons.Rounded.DriveFileMove, contentDescription = null) },
                    onClick = { menu = false; moving = true },
                )
            }
            DropdownMenuItem(
                text = { Text(stringResource(R.string.delete)) },
                leadingIcon = { Icon(Icons.Rounded.Delete, contentDescription = null) },
                onClick = { menu = false; deleting = true },
            )
        }
    }
    if (moving) MoveDialog(model, chapter, onDismiss = { moving = false })
    if (deleting) {
        AlertDialog(
            onDismissRequest = { deleting = false },
            title = { Text(stringResource(R.string.delete_chapter_title)) },
            text = { Text(stringResource(R.string.delete_chapter_body, chapter.title)) },
            confirmButton = {
                Button(
                    onClick = { model.delete(chapter); deleting = false },
                    colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError),
                ) { Text(stringResource(R.string.delete)) }
            },
            dismissButton = { TextButton(onClick = { deleting = false }) { Text(stringResource(R.string.cancel)) } },
        )
    }
}

/** A Rawkuma manga or a project in the "By manga" library; [detail] is the series address or project note. */
@Composable
fun ShelfCard(cover: File?, name: String, chapters: Int, project: Boolean, onClick: () -> Unit, list: Boolean = false, pages: Int = 0, detail: String? = null, selected: Boolean? = null, bytes: Long? = null) {
    val size = bytes?.let { " · " + Formatter.formatShortFileSize(LocalContext.current, it) }.orEmpty()
    if (list) {
        PosterRow(
            cover = cover,
            title = name,
            lines = listOfNotNull(
                (pluralStringResource(R.plurals.shelf_chapters, chapters, chapters) + " · " + pluralStringResource(R.plurals.rawkuma_pages, pages, pages) + size) to false,
                detail?.takeIf { it.isNotBlank() }?.let { it to false },
            ),
            onClick = onClick,
            onLongClick = null,
            placeholder = if (project) Icons.Rounded.Folder else Icons.Rounded.Language,
            trailing = { Icon(if (project) Icons.Rounded.Folder else Icons.Rounded.Language, contentDescription = null, tint = MaterialTheme.colorScheme.primary) },
            selected = selected,
        )
        return
    }
    PosterCard(
        cover = cover,
        title = name,
        subtitle = pluralStringResource(R.plurals.shelf_chapters, chapters, chapters) + size,
        onClick = onClick,
        onLongClick = null,
        badge = { Pill(if (project) Icons.Rounded.Folder else Icons.Rounded.Language, null, it) },
        placeholder = Icons.Rounded.Folder,
        selected = selected,
    )
}

@Composable
private fun MoveDialog(model: AppViewModel, chapter: Chapter, onDismiss: () -> Unit) {
    val projects = model.library.projects.value
    var selected by remember { mutableStateOf(chapter.projectId) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.move_to_project)) },
        text = {
            Column {
                (listOf<Project?>(null) + projects).forEach { project ->
                    Row(
                        Modifier.fillMaxWidth().clickable { selected = project?.id }.padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        RadioButton(selected = selected == project?.id, onClick = { selected = project?.id })
                        Text(project?.name ?: stringResource(R.string.no_project))
                    }
                }
                if (projects.isEmpty()) {
                    Text(stringResource(R.string.no_projects_yet), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        },
        confirmButton = { Button(onClick = { model.move(chapter, selected); onDismiss() }) { Text(stringResource(R.string.move)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** Creates (null [project]) or edits a project. */
@Composable
fun ProjectDialog(project: Project?, onDismiss: () -> Unit, onSave: (String, String) -> Unit) {
    var name by rememberSaveable { mutableStateOf(project?.name.orEmpty()) }
    var note by rememberSaveable { mutableStateOf(project?.note.orEmpty()) }
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Rounded.Folder, contentDescription = null) },
        title = { Text(stringResource(if (project == null) R.string.new_project else R.string.edit_project)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(value = name, onValueChange = { name = it }, singleLine = true, shape = MaterialTheme.shapes.medium, label = { Text(stringResource(R.string.project_name)) })
                OutlinedTextField(value = note, onValueChange = { note = it }, minLines = 2, shape = MaterialTheme.shapes.medium, label = { Text(stringResource(R.string.project_note)) })
            }
        },
        confirmButton = { Button(enabled = name.isNotBlank(), onClick = { onSave(name, note); onDismiss() }) { Text(stringResource(R.string.save)) } },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/** Switches chapter and manga lists between cover grid and rows; the choice is saved. */
@Composable
fun LayoutToggle(model: AppViewModel) {
    val prefs by model.prefs.collectAsStateWithLifecycle()
    IconButton(onClick = { model.update { it.copy(listLayout = !it.listLayout) } }) {
        if (prefs.listLayout) Icon(Icons.Rounded.GridView, contentDescription = stringResource(R.string.layout_grid))
        else Icon(Icons.AutoMirrored.Rounded.ViewList, contentDescription = stringResource(R.string.layout_list))
    }
}

/** Confirmation for deleting chapters, manga or projects; the action cannot be undone. */
@Composable
fun DeleteDialog(title: String, body: String, onDismiss: () -> Unit, onConfirm: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        icon = { Icon(Icons.Rounded.Delete, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
        title = { Text(title) },
        text = { Text(body) },
        confirmButton = {
            Button(
                onClick = onConfirm,
                colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError),
            ) { Text(stringResource(R.string.delete)) }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}
