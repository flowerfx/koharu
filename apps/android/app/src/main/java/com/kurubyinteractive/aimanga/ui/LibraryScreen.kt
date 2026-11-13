package com.kurubyinteractive.aimanga.ui

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

    LaunchedEffect(Unit) { model.errors.collect { snackbar.showSnackbar(errorText(context, it)) } }

    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        containerColor = MaterialTheme.colorScheme.surface,
        topBar = {
            LargeFlexibleTopAppBar(
                title = { Text(stringResource(R.string.library_title), fontWeight = FontWeight.SemiBold) },
                subtitle = {
                    Text(
                        if (byManga) pluralStringResource(R.plurals.library_manga, groups.size, groups.size)
                        else pluralStringResource(R.plurals.library_subtitle, chapters.size, chapters.size),
                    )
                },
                navigationIcon = {
                    Image(
                        painterResource(R.drawable.app_icon_art),
                        contentDescription = null,
                        modifier = Modifier.padding(start = 12.dp, end = 4.dp).size(40.dp).clip(RoundedCornerShape(12.dp)),
                    )
                },
                actions = {
                    if (onBrowse != null) {
                        FilledTonalIconButton(onClick = onBrowse) {
                            Icon(Icons.Rounded.Language, contentDescription = stringResource(R.string.open_rawkuma))
                        }
                    }
                    FilledTonalIconButton(onClick = { creatingProject = true }, modifier = Modifier.padding(end = 8.dp)) {
                        Icon(Icons.Rounded.CreateNewFolder, contentDescription = stringResource(R.string.new_project))
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
            if (chapters.isNotEmpty() || projects.isNotEmpty()) {
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
                columns = GridCells.Adaptive(160.dp),
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
                            is Shelf.Series -> ShelfCard(model.cover(shelf.chapters.lastOrNull()), shelf.name, shelf.chapters.size, project = false) { onOpenShelf(shelf.key) }
                            is Shelf.Folder -> ShelfCard(model.cover(shelf.chapters.lastOrNull()), shelf.project.name, shelf.chapters.size, project = true) { onOpenShelf(shelf.key) }
                            is Shelf.Loose -> ChapterCard(model, shelf.chapter, run?.chapterId == shelf.chapter.id, { onOpen(shelf.chapter) }, onOpenSource)
                        }
                    }
                } else {
                    items(chapters, key = { it.id }) { chapter ->
                        ChapterCard(model, chapter, run?.chapterId == chapter.id, { onOpen(chapter) }, onOpenSource)
                    }
                }
            }
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
