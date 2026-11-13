package com.kurubyinteractive.aimanga.ui

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
    var projectMenu by remember { mutableStateOf(false) }
    var editing by remember { mutableStateOf(false) }
    var deleting by remember { mutableStateOf(false) }
    val name = when (shelf) {
        is Shelf.Series -> shelf.name
        is Shelf.Folder -> shelf.project.name
        is Shelf.Loose -> shelf.chapter.title
    }
    val series = shelf.chapters.firstNotNullOfOrNull { it.series }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(name, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold)
                        Text(
                            pluralStringResource(R.plurals.shelf_chapters, shelf.chapters.size, shelf.chapters.size),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.back)) }
                },
                actions = {
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
                    if (shelf is Shelf.Folder) {
                        IconButton(onClick = { projectMenu = true }) { Icon(Icons.Rounded.MoreVert, contentDescription = null) }
                        DropdownMenu(expanded = projectMenu, onDismissRequest = { projectMenu = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.edit_project)) },
                                leadingIcon = { Icon(Icons.Rounded.Edit, contentDescription = null) },
                                onClick = { projectMenu = false; editing = true },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.delete_project)) },
                                leadingIcon = { Icon(Icons.Rounded.Delete, contentDescription = null) },
                                onClick = { projectMenu = false; deleting = true },
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
            )
        },
    ) { padding ->
        LazyVerticalGrid(
            columns = GridCells.Adaptive(160.dp),
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
                ChapterCard(model, chapter, run?.chapterId == chapter.id, { onOpen(chapter) }, onOpenSource)
            }
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
