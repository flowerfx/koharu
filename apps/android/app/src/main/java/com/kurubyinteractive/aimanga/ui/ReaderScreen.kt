package com.kurubyinteractive.aimanga.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil3.compose.AsyncImage
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.rounded.AutoAwesome
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.ui.layout.ContentScale
import com.kurubyinteractive.aimanga.data.Chapter
import com.kurubyinteractive.aimanga.data.ReadingMode
import uniffi.koharu_core.Provider
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.R
import com.kurubyinteractive.aimanga.pipeline.Progress

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun ReaderScreen(
    model: AppViewModel,
    chapterId: String,
    onBack: () -> Unit,
    onOpenSource: (String) -> Unit,
    onSwitchChapter: (String) -> Unit,
) {
    val context = LocalContext.current
    val chapters by model.library.chapters.collectAsStateWithLifecycle()
    val chapter = chapters.firstOrNull { it.id == chapterId } ?: return onBack()
    val run by model.run.collectAsStateWithLifecycle()
    val running = run?.chapterId == chapterId
    val busyElsewhere = run != null && !running
    var showTranslated by rememberSaveable { mutableStateOf(true) }
    val pager = rememberPagerState { chapter.pages.size }
    val strip = rememberLazyListState()
    val prefs by model.prefs.collectAsStateWithLifecycle()
    val vertical = prefs.reading == ReadingMode.VERTICAL
    val currentPage = if (vertical) strip.firstVisibleItemIndex else pager.currentPage
    val snackbar = remember { SnackbarHostState() }
    val creditGate = rememberCreditGate(model)
    var menu by remember { mutableStateOf(false) }
    val enabledProviders by model.enabledProviders.collectAsStateWithLifecycle()
    val backendOffered = enabledProviders.any { it.provider == Provider.BACKEND }
    val translatedAll = chapter.pages.isNotEmpty() && chapter.translatedPages == chapter.pages.size
    val idle = !running && !busyElsewhere && chapter.pages.isNotEmpty()
    val switchTo = { copy: Chapter -> onSwitchChapter(copy.id) }
    LaunchedEffect(Unit) { model.errors.collect { snackbar.showSnackbar(errorText(context, it)) } }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.surfaceContainerLowest,
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(chapter.title, maxLines = 1, overflow = TextOverflow.Ellipsis, fontWeight = FontWeight.SemiBold)
                        Text(
                            stringResource(R.string.page_of, currentPage + 1, chapter.pages.size),
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.back))
                    }
                },
                actions = {
                    chapter.source?.let { source ->
                        IconButton(onClick = { onOpenSource(source) }) {
                            Icon(Icons.Rounded.Language, contentDescription = stringResource(R.string.open_chapter_rawkuma))
                        }
                    }
                    IconButton(onClick = { menu = true }, enabled = idle) {
                        Icon(Icons.Rounded.MoreVert, contentDescription = stringResource(R.string.translation_options))
                    }
                    DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.retranslate_chapter)) },
                            leadingIcon = { Icon(Icons.Rounded.Refresh, contentDescription = null) },
                            onClick = { menu = false; creditGate(CreditKind.RERUN) { model.translate(chapter, force = true, onChapter = switchTo) } },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.retranslate_page, currentPage + 1)) },
                            leadingIcon = { Icon(Icons.Rounded.Refresh, contentDescription = null) },
                            onClick = {
                                menu = false
                                val page = currentPage
                                creditGate(CreditKind.RERUN) { model.translate(chapter, force = true, page = page, onChapter = switchTo) }
                            },
                        )
                        if (backendOffered) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.enhanced_translation)) },
                                leadingIcon = { Icon(Icons.Rounded.AutoAwesome, contentDescription = null) },
                                onClick = { menu = false; creditGate(CreditKind.ENHANCED) { model.translate(chapter, enhanced = true, onChapter = switchTo) } },
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLowest),
            )
        },
        snackbarHost = { SnackbarHost(snackbar) },
    ) { padding ->
        Column(Modifier.fillMaxSize().padding(padding)) {
            Box(Modifier.weight(1f).fillMaxWidth()) {
                if (vertical) {
                    // Vertical scrolling: every page in one strip at full width.
                    LazyColumn(state = strip, modifier = Modifier.fillMaxSize()) {
                        items(chapter.pages.size) { index ->
                            val page = chapter.pages[index]
                            val name = if (showTranslated) page.translated ?: page.file else page.file
                            AsyncImage(
                                model = model.library.file(chapter, name),
                                contentDescription = stringResource(R.string.page_number, index + 1),
                                contentScale = ContentScale.FillWidth,
                                modifier = Modifier.fillMaxWidth(),
                            )
                        }
                    }
                } else
                // Manga reads right to left, so the next page is to the left.
                HorizontalPager(
                    state = pager,
                    reverseLayout = true,
                    pageSpacing = 12.dp,
                    modifier = Modifier.fillMaxSize(),
                ) { index ->
                    val page = chapter.pages[index]
                    val name = if (showTranslated) page.translated ?: page.file else page.file
                    AsyncImage(
                        model = model.library.file(chapter, name),
                        contentDescription = stringResource(R.string.page_number, index + 1),
                        modifier = Modifier.fillMaxSize().padding(horizontal = 8.dp),
                    )
                }
            }
            AnimatedVisibility(running) {
                ProgressCard(run?.progress, onCancel = model::cancel)
            }
            // Floating reader toolbar.
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainerHigh,
                shape = CircleShape,
                shadowElevation = 6.dp,
                modifier = Modifier
                    .fillMaxWidth()
                    .navigationBarsPadding()
                    .padding(horizontal = 12.dp, vertical = 10.dp),
            ) {
                Row(
                    Modifier.padding(6.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
                        SegmentedButton(
                            selected = !showTranslated,
                            onClick = { showTranslated = false },
                            shape = SegmentedButtonDefaults.itemShape(0, 2),
                            icon = {},
                        ) { Text(stringResource(R.string.original), maxLines = 1) }
                        SegmentedButton(
                            selected = showTranslated,
                            onClick = { showTranslated = true },
                            shape = SegmentedButtonDefaults.itemShape(1, 2),
                            icon = {},
                        ) { Text(stringResource(R.string.translated), maxLines = 1) }
                    }
                    Button(
                        onClick = {
                            if (translatedAll) creditGate(CreditKind.RERUN) { model.translate(chapter, force = true, onChapter = switchTo) }
                            else creditGate(CreditKind.TRANSLATE) { model.translate(chapter, onChapter = switchTo) }
                        },
                        enabled = idle,
                        shapes = ButtonDefaults.shapes(),
                        contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
                    ) {
                        Icon(Icons.Rounded.Translate, contentDescription = null, modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(if (translatedAll) R.string.retranslate else R.string.translate), maxLines = 1)
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ProgressCard(progress: Progress?, onCancel: () -> Unit) {
    Card(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        ),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    when (progress) {
                        is Progress.Reading -> stringResource(R.string.progress_reading, progress.page, progress.total)
                        is Progress.Translating -> stringResource(R.string.progress_translating, progress.segments)
                        is Progress.Rendering -> stringResource(R.string.progress_rendering, progress.page, progress.total)
                        null -> stringResource(R.string.progress_starting)
                    },
                    style = MaterialTheme.typography.bodyMedium,
                )
                Spacer(Modifier.height(10.dp))
                val fraction = when (progress) {
                    is Progress.Reading -> progress.page.toFloat() / progress.total
                    is Progress.Rendering -> progress.page.toFloat() / progress.total
                    else -> null
                }
                if (fraction != null) {
                    LinearWavyProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth())
                } else {
                    LinearWavyProgressIndicator(Modifier.fillMaxWidth())
                }
            }
            Spacer(Modifier.width(12.dp))
            FilledTonalIconButton(onClick = onCancel) {
                Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.cancel))
            }
        }
    }
}
