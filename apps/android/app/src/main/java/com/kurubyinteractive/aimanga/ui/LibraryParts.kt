package com.kurubyinteractive.aimanga.ui

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
) {
    Card(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        modifier = Modifier.combinedClickable(onClick = onClick, onLongClick = onLongClick),
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
            badge(Modifier.align(Alignment.TopEnd).padding(10.dp))
            overlay(Modifier.align(Alignment.Center))
            Column(Modifier.align(Alignment.BottomStart).padding(14.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = Color.White.copy(alpha = 0.85f), maxLines = 1)
            }
        }
        if (progress != null) LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth())
    }
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
) {
    var menu by remember { mutableStateOf(false) }
    var moving by remember { mutableStateOf(false) }
    val creditGate = rememberCreditGate(model)
    val run by model.run.collectAsStateWithLifecycle()
    val enabledProviders by model.enabledProviders.collectAsStateWithLifecycle()
    var deleting by remember { mutableStateOf(false) }
    val total = chapter.pages.size
    val done = chapter.translatedPages
    Box {
        PosterCard(
            cover = model.cover(chapter),
            title = chapter.title,
            subtitle = pluralStringResource(R.plurals.chapter_progress, total, total, done),
            onClick = onOpen,
            onLongClick = { menu = true },
            badge = { if (total > 0 && done == total) Pill(Icons.Rounded.CheckCircle, stringResource(R.string.translated), it) },
            progress = if (total > 0 && done in 1 until total) done.toFloat() / total else null,
            overlay = { if (running) LoadingIndicator(it.size(64.dp)) },
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
                    text = { Text(stringResource(if (done > 0) R.string.retranslate_chapter else R.string.translate)) },
                    leadingIcon = { Icon(Icons.Rounded.Refresh, contentDescription = null) },
                    onClick = {
                        menu = false
                        if (done > 0) creditGate(CreditKind.RERUN) { model.translate(chapter, force = true) }
                        else creditGate(CreditKind.TRANSLATE) { model.translate(chapter) }
                    },
                )
                if (enabledProviders.any { it.provider == Provider.BACKEND }) {
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.enhanced_translation)) },
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

/** A Rawkuma manga or a project in the "By manga" library. */
@Composable
fun ShelfCard(cover: File?, name: String, chapters: Int, project: Boolean, onClick: () -> Unit) {
    PosterCard(
        cover = cover,
        title = name,
        subtitle = pluralStringResource(R.plurals.shelf_chapters, chapters, chapters),
        onClick = onClick,
        onLongClick = null,
        badge = { Pill(if (project) Icons.Rounded.Folder else Icons.Rounded.Language, null, it) },
        placeholder = Icons.Rounded.Folder,
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
