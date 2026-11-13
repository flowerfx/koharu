package com.kurubyinteractive.aimanga.ui

import androidx.compose.ui.platform.LocalContext
import android.text.format.Formatter
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material.icons.rounded.Checklist
import androidx.compose.material.icons.rounded.DeleteSweep
import androidx.compose.material.icons.rounded.Close
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.Sort
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.R
import com.kurubyinteractive.aimanga.data.Chapter
import com.kurubyinteractive.aimanga.data.Shelf
import com.kurubyinteractive.aimanga.data.ShelfSort
import com.kurubyinteractive.aimanga.data.apply
import com.kurubyinteractive.aimanga.data.shelves

/** Chapters of one Rawkuma manga or one project (iPad `ShelfScreen`). */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class, ExperimentalLayoutApi::class)
@Composable
fun ShelfScreen(
    model: AppViewModel,
    key: String,
    onBack: () -> Unit,
    onOpen: (Chapter) -> Unit,
    onImport: (projectId: String) -> Unit,
    onOpenSource: (String) -> Unit,
) {
    val chapters by model.library.chapters.collectAsStateWithLifecycle()
    val projects by model.library.projects.collectAsStateWithLifecycle()
    val run by model.run.collectAsStateWithLifecycle()
    val shelf = remember(chapters, projects, key) { shelves(chapters, projects).firstOrNull { it.key == key } }
    if (shelf == null) return onBack()
    val isSeries = shelf is Shelf.Series
    // Chapter-number orders apply to manga; a project starts in date order.
    var sort by rememberSaveable { mutableStateOf(if (isSeries) ShelfSort.CHAPTER_DESCENDING else ShelfSort.NEWEST) }
    var sortMenu by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    val name = when (shelf) {
        is Shelf.Series -> shelf.name
        is Shelf.Folder -> shelf.project.name
        is Shelf.Loose -> shelf.chapter.title
    }
    val series = shelf.chapters.firstNotNullOfOrNull { it.series }

    val prefs by model.prefs.collectAsStateWithLifecycle()
    val list = prefs.listLayout
    val sizes by model.chapterSizes.collectAsStateWithLifecycle()
    var selecting by rememberSaveable { mutableStateOf(false) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var confirmSelected by remember { mutableStateOf(false) }
    var confirmAll by remember { mutableStateOf(false) }
    var moreMenu by remember { mutableStateOf(false) }
    val ids = shelf.chapters.map { it.id }
    LaunchedEffect(ids) { selected = selected intersect ids.toSet() }
    val stopSelecting = { selecting = false; selected = emptySet() }
    BackHandler(enabled = selecting) { stopSelecting() }
    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            if (selecting) pluralStringResource(R.plurals.selected_count, selected.size, selected.size) else name,
                            maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold,
                        )
                        if (!selecting) Text(
                            pluralStringResource(R.plurals.shelf_chapters, shelf.chapters.size, shelf.chapters.size) + " · " +
                                Formatter.formatShortFileSize(LocalContext.current, shelf.chapters.sumOf { sizes[it.id] ?: 0L }),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                navigationIcon = {
                    if (selecting) IconButton(onClick = stopSelecting) { Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.cancel)) }
                    else IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.back)) }
                },
                actions = {
                    if (selecting) {
                        TextButton(onClick = { selected = if (selected.size == ids.size) emptySet() else ids.toSet() }) {
                            Text(stringResource(if (selected.size == ids.size && ids.isNotEmpty()) R.string.deselect_all else R.string.select_all))
                        }
                        IconButton(onClick = { confirmSelected = true }, enabled = selected.isNotEmpty()) {
                            Icon(Icons.Rounded.Delete, contentDescription = stringResource(R.string.delete_selected))
                        }
                        return@TopAppBar
                    }
                    LayoutToggle(model)
                    IconButton(onClick = { sortMenu = true }) { Icon(Icons.AutoMirrored.Rounded.Sort, contentDescription = stringResource(R.string.sort)) }
                    DropdownMenu(expanded = sortMenu, onDismissRequest = { sortMenu = false }) {
                        listOf(
                            ShelfSort.CHAPTER_DESCENDING to R.string.sort_latest_chapter,
                            ShelfSort.CHAPTER_ASCENDING to R.string.sort_first_chapter,
                            ShelfSort.NEWEST to R.string.sort_newest,
                            ShelfSort.OLDEST to R.string.sort_oldest,
                        ).forEach { (value, label) ->
                            DropdownMenuItem(text = { Text(stringResource(label)) }, onClick = { sort = value; sortMenu = false })
                        }
                    }
                    IconButton(onClick = { moreMenu = true }) { Icon(Icons.Rounded.MoreVert, contentDescription = stringResource(R.string.more_actions)) }
                    DropdownMenu(expanded = moreMenu, onDismissRequest = { moreMenu = false }) {
                        if (shelf.chapters.isNotEmpty()) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.select)) },
                                leadingIcon = { Icon(Icons.Rounded.Checklist, contentDescription = null) },
                                onClick = { moreMenu = false; selecting = true },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.delete_all_chapters), color = MaterialTheme.colorScheme.error) },
                                leadingIcon = { Icon(Icons.Rounded.DeleteSweep, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                                onClick = { moreMenu = false; confirmAll = true },
                            )
                        }
                        if (shelf is Shelf.Folder) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.edit_project)) },
                                leadingIcon = { Icon(Icons.Rounded.Edit, contentDescription = null) },
                                onClick = { moreMenu = false; editing = true },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.delete_project)) },
                                leadingIcon = { Icon(Icons.Rounded.Delete, contentDescription = null) },
                                onClick = { moreMenu = false; deleting = true },
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
            )
        },
    ) { padding ->
        LazyVerticalGrid(
            columns = GridCells.Adaptive(if (list) 340.dp else 160.dp),
            contentPadding = PaddingValues(16.dp, padding.calculateTopPadding() + 4.dp, 16.dp, 32.dp),
            horizontalArrangement = Arrangement.spacedBy(14.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Card(
                    shape = MaterialTheme.shapes.extraLarge,
                    colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
                ) {
                    Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        when (shelf) {
                            is Shelf.Series -> {
                                series?.alternativeTitles?.firstOrNull()?.let {
                                    Text(it, style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                if (!series?.genres.isNullOrEmpty()) {
                                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                        series.genres.forEach { AssistChip(onClick = {}, label = { Text(it) }) }
                                    }
                                }
                                series?.synopsis?.takeIf { it.isNotBlank() }?.let {
                                    Text(it, style = MaterialTheme.typography.bodyMedium, maxLines = 6, overflow = TextOverflow.Ellipsis)
                                }
                                Button(
                                    onClick = { onOpenSource(shelf.url) },
                                    shapes = ButtonDefaults.shapes(),
                                    modifier = Modifier.fillMaxWidth(),
                                ) {
                                    Icon(Icons.Rounded.Language, contentDescription = null)
                                    Spacer(Modifier.width(8.dp))
                                    Text(stringResource(R.string.open_manga_rawkuma))
                                }
                            }
                            is Shelf.Folder -> {
                                Text(
                                    shelf.project.note.ifBlank { stringResource(R.string.project_hint) },
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                                Button(onClick = { onImport(shelf.project.id) }, shapes = ButtonDefaults.shapes(), modifier = Modifier.fillMaxWidth()) {
                                    Icon(Icons.Rounded.Add, contentDescription = null)
                                    Spacer(Modifier.width(8.dp))
                                    Text(stringResource(R.string.import_into_project))
                                }
                            }
                            is Shelf.Loose -> {}
                        }
                    }
                }
            }
            items(sort.apply(shelf.chapters), key = { it.id }) { chapter ->
                ChapterCard(
                    model, chapter, run?.chapterId == chapter.id,
                    {
                        if (selecting) selected = if (chapter.id in selected) selected - chapter.id else selected + chapter.id
                        else onOpen(chapter)
                    },
                    onOpenSource, list = list, selected = if (selecting) chapter.id in selected else null,
                )
            }
        }
    }

    if (confirmSelected || confirmAll) {
        val count = if (confirmAll) ids.size else selected.size
        DeleteDialog(
            title = stringResource(if (confirmAll) R.string.delete_all_chapters_title else R.string.delete_selected_title),
            body = pluralStringResource(R.plurals.delete_chapters_body, count, count),
            onDismiss = { confirmSelected = false; confirmAll = false },
        ) {
            model.deleteChapters(if (confirmAll) ids else selected)
            confirmSelected = false; confirmAll = false
            stopSelecting()
        }
    }

    if (shelf is Shelf.Folder) {
        if (editing) {
            ProjectDialog(shelf.project, onDismiss = { editing = false }) { newName, note ->
                model.saveProject(shelf.project.copy(name = newName, note = note))
            }
        }
        if (deleting) {
            AlertDialog(
                onDismissRequest = { deleting = false },
                title = { Text(stringResource(R.string.delete_project_title)) },
                text = { Text(stringResource(R.string.delete_project_body)) },
                confirmButton = {
                    Button(
                        onClick = { deleting = false; model.deleteProject(shelf.project.id); onBack() },
                        colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error, contentColor = MaterialTheme.colorScheme.onError),
                    ) { Text(stringResource(R.string.delete_project)) }
                },
                dismissButton = { TextButton(onClick = { deleting = false }) { Text(stringResource(R.string.cancel)) } },
            )
        }
    }
}
