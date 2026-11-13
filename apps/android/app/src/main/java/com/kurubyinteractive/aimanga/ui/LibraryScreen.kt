package com.kurubyinteractive.aimanga.ui

import android.text.format.Formatter
import androidx.compose.material3.TextButton
import androidx.compose.material3.IconButton
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.DropdownMenu
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Checklist
import androidx.compose.material.icons.rounded.DeleteSweep
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Close
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.CreateNewFolder
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.LargeFlexibleTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
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
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.R
import com.kurubyinteractive.aimanga.data.Chapter
import com.kurubyinteractive.aimanga.data.Project
import com.kurubyinteractive.aimanga.data.Shelf
import com.kurubyinteractive.aimanga.data.shelves
import java.util.UUID

/**
 * Library tab with the iPad's two views: "By manga" groups Rawkuma chapters
 * by series and imported chapters by project; "All chapters" lists every chapter.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun LibraryScreen(
    model: AppViewModel,
    onOpen: (Chapter) -> Unit,
    onOpenShelf: (String) -> Unit,
    onImport: () -> Unit,
    onOpenSource: (String) -> Unit,
    /** Opens the Rawkuma tab; null while content safety (full-safe) or config removes it. */
    onBrowse: (() -> Unit)?,
) {
    val context = LocalContext.current
    val chapters by model.library.chapters.collectAsStateWithLifecycle()
    val projects by model.library.projects.collectAsStateWithLifecycle()
    val run by model.run.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    var byManga by rememberSaveable { mutableStateOf(true) }
    var creatingProject by remember { mutableStateOf(false) }
    val groups = remember(chapters, projects) { shelves(chapters, projects) }
    val prefs by model.prefs.collectAsStateWithLifecycle()
    val list = prefs.listLayout
    val sizes by model.chapterSizes.collectAsStateWithLifecycle()
    val totalSize = Formatter.formatShortFileSize(context, sizes.values.sum())
    val shelfBytes = { shelf: Shelf -> shelf.chapters.sumOf { sizes[it.id] ?: 0L } }
    // Selection mode: shelf keys in "By manga", chapter ids in "All chapters".
    var selecting by rememberSaveable { mutableStateOf(false) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var confirm by remember { mutableStateOf<Confirm?>(null) }
    var moreMenu by remember { mutableStateOf(false) }
    val keys = if (byManga) groups.map { it.key } else chapters.map { it.id }
    val toggle = { key: String -> selected = if (key in selected) selected - key else selected + key }
    val stopSelecting = { selecting = false; selected = emptySet() }
    val mark = { key: String -> if (selecting) key in selected else null }
    LaunchedEffect(byManga) { selected = emptySet() }
    LaunchedEffect(keys) { selected = selected intersect keys.toSet() }
    BackHandler(enabled = selecting) { stopSelecting() }

    LaunchedEffect(Unit) { model.errors.collect { snackbar.showSnackbar(errorText(context, it)) } }

    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        containerColor = MaterialTheme.colorScheme.surface,
        topBar = {
            LargeFlexibleTopAppBar(
                title = {
                    if (selecting) Text(pluralStringResource(R.plurals.selected_count, selected.size, selected.size), fontWeight = FontWeight.SemiBold)
                    else Text(stringResource(R.string.library_title), fontWeight = FontWeight.SemiBold)
                },
                subtitle = {
                    Text(
                        (if (byManga) pluralStringResource(R.plurals.library_manga, groups.size, groups.size)
                        else pluralStringResource(R.plurals.library_subtitle, chapters.size, chapters.size)) + " · " + stringResource(R.string.library_size, totalSize),
                    )
                },
                navigationIcon = {
                    if (selecting) IconButton(onClick = stopSelecting) { Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.cancel)) }
                    else Image(
                        painterResource(R.drawable.app_icon_art),
                        contentDescription = null,
                        modifier = Modifier.padding(start = 12.dp, end = 4.dp).size(40.dp).clip(RoundedCornerShape(12.dp)),
                    )
                },
                actions = {
                    if (selecting) {
                        TextButton(onClick = { selected = if (selected.size == keys.size) emptySet() else keys.toSet() }) {
                            Text(stringResource(if (selected.size == keys.size && keys.isNotEmpty()) R.string.deselect_all else R.string.select_all))
                        }
                        IconButton(onClick = { confirm = Confirm.SELECTED }, enabled = selected.isNotEmpty()) {
                            Icon(Icons.Rounded.Delete, contentDescription = stringResource(R.string.delete_selected))
                        }
                        return@LargeFlexibleTopAppBar
                    }
                    LayoutToggle(model)
                    if (onBrowse != null) {
                        FilledTonalIconButton(onClick = onBrowse) {
                            Icon(Icons.Rounded.Language, contentDescription = stringResource(R.string.open_rawkuma))
                        }
                    }
                    FilledTonalIconButton(onClick = { creatingProject = true }) {
                        Icon(Icons.Rounded.CreateNewFolder, contentDescription = stringResource(R.string.new_project))
                    }
                    if (chapters.isNotEmpty() || projects.isNotEmpty()) {
                        IconButton(onClick = { moreMenu = true }) { Icon(Icons.Rounded.MoreVert, contentDescription = stringResource(R.string.more_actions)) }
                        DropdownMenu(expanded = moreMenu, onDismissRequest = { moreMenu = false }) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.select)) },
                                leadingIcon = { Icon(Icons.Rounded.Checklist, contentDescription = null) },
                                onClick = { moreMenu = false; selecting = true },
                            )
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.delete_all), color = MaterialTheme.colorScheme.error) },
                                leadingIcon = { Icon(Icons.Rounded.DeleteSweep, contentDescription = null, tint = MaterialTheme.colorScheme.error) },
                                onClick = { moreMenu = false; confirm = Confirm.EVERYTHING },
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface,
                    scrolledContainerColor = MaterialTheme.colorScheme.surfaceContainer,
                ),
                scrollBehavior = scroll,
            )
        },
        floatingActionButton = {
            if ((chapters.isNotEmpty() || projects.isNotEmpty()) && !selecting) {
                ExtendedFloatingActionButton(
                    onClick = onImport,
                    icon = { Icon(Icons.Rounded.Add, contentDescription = null) },
                    text = { Text(stringResource(R.string.import_pages)) },
                    containerColor = MaterialTheme.colorScheme.primary,
                    contentColor = MaterialTheme.colorScheme.onPrimary,
                )
            }
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        if (chapters.isEmpty() && projects.isEmpty()) {
            EmptyLibrary(Modifier.padding(padding), onImport = onImport, onBrowse = onBrowse)
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(if (list) 340.dp else 160.dp),
                contentPadding = PaddingValues(16.dp, padding.calculateTopPadding() + 4.dp, 16.dp, 112.dp),
                horizontalArrangement = Arrangement.spacedBy(14.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                item(span = { GridItemSpan(maxLineSpan) }) {
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        SegmentedButton(selected = byManga, onClick = { byManga = true }, shape = SegmentedButtonDefaults.itemShape(0, 2)) {
                            Text(stringResource(R.string.by_manga))
                        }
                        SegmentedButton(selected = !byManga, onClick = { byManga = false }, shape = SegmentedButtonDefaults.itemShape(1, 2)) {
                            Text(stringResource(R.string.all_chapters))
                        }
                    }
                }
                if (byManga) {
                    items(groups, key = { it.key }) { shelf ->
                        when (shelf) {
                            is Shelf.Series -> ShelfCard(
                                model.cover(shelf.chapters.lastOrNull()), shelf.name, shelf.chapters.size, project = false,
                                onClick = { if (selecting) toggle(shelf.key) else onOpenShelf(shelf.key) },
                                list = list, pages = shelf.chapters.sumOf { it.pages.size }, detail = shelf.url, selected = mark(shelf.key), bytes = shelfBytes(shelf),
                            )
                            is Shelf.Folder -> ShelfCard(
                                model.cover(shelf.chapters.lastOrNull()), shelf.project.name, shelf.chapters.size, project = true,
                                onClick = { if (selecting) toggle(shelf.key) else onOpenShelf(shelf.key) },
                                list = list, pages = shelf.chapters.sumOf { it.pages.size }, detail = shelf.project.note, selected = mark(shelf.key), bytes = shelfBytes(shelf),
                            )
                            is Shelf.Loose -> ChapterCard(
                                model, shelf.chapter, run?.chapterId == shelf.chapter.id,
                                { if (selecting) toggle(shelf.key) else onOpen(shelf.chapter) }, onOpenSource, list = list, selected = mark(shelf.key),
                            )
                        }
                    }
                } else {
                    items(chapters, key = { it.id }) { chapter ->
                        ChapterCard(
                            model, chapter, run?.chapterId == chapter.id,
                            { if (selecting) toggle(chapter.id) else onOpen(chapter) }, onOpenSource, list = list, showsOrigin = true, selected = mark(chapter.id),
                        )
                    }
                }
            }
        }
    }

    confirm?.let { kind ->
        val shelvesChosen = groups.filter { it.key in selected }
        val count = when (kind) {
            Confirm.EVERYTHING -> chapters.size
            Confirm.SELECTED -> if (byManga) shelvesChosen.sumOf { it.chapters.size } else selected.size
        }
        DeleteDialog(
            title = stringResource(if (kind == Confirm.EVERYTHING) R.string.delete_library_title else R.string.delete_selected_title),
            body = if (kind == Confirm.EVERYTHING) pluralStringResource(R.plurals.delete_library_body, count, count, projects.size)
            else pluralStringResource(R.plurals.delete_chapters_body, count, count),
            onDismiss = { confirm = null },
        ) {
            when (kind) {
                Confirm.EVERYTHING -> model.deleteAll()
                Confirm.SELECTED -> if (byManga) model.deleteShelves(shelvesChosen) else model.deleteChapters(selected)
            }
            confirm = null
            stopSelecting()
        }
    }

    if (creatingProject) {
        ProjectDialog(project = null, onDismiss = { creatingProject = false }) { name, note ->
            model.saveProject(Project(UUID.randomUUID().toString(), name, note, System.currentTimeMillis()))
        }
    }
}

@Composable
private fun EmptyLibrary(modifier: Modifier, onImport: () -> Unit, onBrowse: (() -> Unit)?) {
    Column(
        modifier = modifier.fillMaxSize().padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Image(
            painterResource(R.drawable.app_icon_art),
            contentDescription = null,
            modifier = Modifier
                .size(148.dp)
                .shadow(16.dp, RoundedCornerShape(36.dp), spotColor = BrandPink)
                .clip(RoundedCornerShape(36.dp)),
        )
        Spacer(Modifier.height(28.dp))
        Text(stringResource(R.string.empty_title), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.height(8.dp))
        Text(
            stringResource(R.string.empty_body),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
        )
        Spacer(Modifier.height(24.dp))
        Button(onClick = onImport, contentPadding = PaddingValues(horizontal = 28.dp, vertical = 16.dp)) {
            Icon(Icons.Rounded.Add, contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.import_pages), style = MaterialTheme.typography.titleSmall)
        }
        if (onBrowse != null) {
            Spacer(Modifier.height(12.dp))
            OutlinedButton(onClick = onBrowse, contentPadding = PaddingValues(horizontal = 28.dp, vertical = 16.dp)) {
                Icon(Icons.Rounded.Language, contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.open_rawkuma), style = MaterialTheme.typography.titleSmall)
            }
        }
        Spacer(Modifier.height(48.dp))
    }
}

private enum class Confirm { SELECTED, EVERYTHING }
