package com.kurubyinteractive.aimanga.ui

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.automirrored.rounded.ArrowForward
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Refresh
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material.icons.rounded.WarningAmber
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearWavyProgressIndicator
import androidx.compose.material3.MaterialTheme
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.webkit.ScriptHandler
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.R
import com.kurubyinteractive.aimanga.data.Chapter
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONArray
import uniffi.koharu_core.SeriesContext
import uniffi.koharu_core.SourceChapter
import uniffi.koharu_core.blockedGenreMatches
import uniffi.koharu_core.fetchSeries
import uniffi.koharu_core.parseSourceChapter
import uniffi.koharu_core.rawkumaAddress
import uniffi.koharu_core.rawkumaContains
import uniffi.koharu_core.rawkumaPath
import uniffi.koharu_core.rawkumaSeriesUrl
import kotlin.coroutines.resume

/** Same reader query the iPad and desktop use to list a chapter's page images. */
private const val CHAPTER_SCRIPT = """(() => {
  const reader = [...document.querySelectorAll('section[data-image-data] img')];
  const nodes = reader.length ? reader : [...document.querySelectorAll('img[alt*=" - Page "]')];
  const images = [];
  for (const image of nodes) {
    for (const source of [image.getAttribute('data-src'), image.getAttribute('data-original'), image.getAttribute('src'), image.currentSrc]) {
      if (!source) continue;
      try {
        const url = new URL(source, location.href);
        if (url.protocol === 'https:' && url.hostname === 'cdn.rawkuma.com' && !url.username && !url.password && !url.port) {
          if (!images.includes(url.href)) images.push(url.href);
          break;
        }
      } catch {}
    }
  }
  return JSON.stringify({url: location.href, title: document.title, images});
})()"""

/**
 * The Rawkuma source browser (port of the iPad `RawkumaBrowser`). It lives
 * for the whole activity so switching tabs keeps the page. Navigation stays on
 * the site configured in app-config.json; content-safety mode decides the
 * warning and genre check.
 */
class RawkumaBrowser(context: Context) {
    @SuppressLint("SetJavaScriptEnabled")
    val webView = WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.setSupportMultipleWindows(false)
        settings.javaScriptCanOpenWindowsAutomatically = false
    }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val navigationScript = context.assets.open("rawkuma-navigation.js").bufferedReader().use { it.readText() }
    private var scriptHandler: ScriptHandler? = null

    var site by mutableStateOf<String?>(null); private set
    var mode by mutableStateOf("none-safe"); private set
    private var blockedGenres: List<String> = emptyList()

    var addressPath by mutableStateOf("")
    var loading by mutableStateOf(false); private set
    var hasLoaded by mutableStateOf(false); private set
    var chapter by mutableStateOf<SourceChapter?>(null); private set
    var series by mutableStateOf<SeriesContext?>(null); private set
    var genreMessage by mutableStateOf<Int?>(null); private set
    var showsWarning by mutableStateOf(false); private set
    var showsBlocked by mutableStateOf(false); private set
    var pageHidden by mutableStateOf(false); private set
    var canGoBack by mutableStateOf(false); private set
    var canGoForward by mutableStateOf(false); private set
    private var genresVerified by mutableStateOf(false)
    private var acceptedWarning = false
    private var pendingAddress: String? = null
    private var inspection: Job? = null
    /** The blank page shown after a reset must not become a Back destination. */
    private var resetHistory = false

    val canTranslate: Boolean get() = mode == "none-safe" || (mode == "half-safe" && genresVerified)
    val isCurrentAddress: Boolean get() = site?.let { rawkumaAddress(it, addressPath) } == webView.url

    init {
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val allowed = site?.let { rawkumaContains(it, request.url.toString()) } == true
                return !(allowed && (mode != "half-safe" || acceptedWarning))
            }

            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                loading = true; chapter = null; inspection?.cancel()
                genresVerified = false; genreMessage = null
                if (mode == "half-safe") pageHidden = true
                updateHistory()
            }

            override fun onPageFinished(view: WebView, url: String) {
                loading = false
                if (resetHistory && url != "about:blank") {
                    view.clearHistory(); resetHistory = false
                }
                updateHistory()
                val current = site ?: return
                val path = rawkumaPath(current, url) ?: return
                addressPath = path
                inspection?.cancel()
                inspection = scope.launch { afterLoad(current, url) }
            }
        }
    }

    /** Applies the active configuration; a changed site restarts browsing. */
    fun configure(site: String?, mode: String, blocked: List<String>) {
        this.mode = mode
        blockedGenres = blocked
        val usable = site.takeIf { mode != "full-safe" }
        if (usable == this.site) return
        this.site = usable
        scriptHandler?.remove()
        scriptHandler = null
        if (usable != null && WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            scriptHandler = WebViewCompat.addDocumentStartJavaScript(webView, navigationScript, setOf(usable.trimEnd('/')))
        }
        suspendBrowsing()
    }

    fun start() {
        if (!hasLoaded) site?.let { go(it) }
    }

    fun goPath() {
        val current = site ?: return
        rawkumaAddress(current, addressPath)?.let { go(it) }
    }

    fun go(address: String) {
        val current = site ?: return
        if (!rawkumaContains(current, address)) return
        if (mode == "half-safe" && !acceptedWarning) {
            pendingAddress = address; showsWarning = true; return
        }
        rawkumaPath(current, address)?.let { addressPath = it }
        chapter = null; hasLoaded = true
        pageHidden = mode == "half-safe"
        webView.loadUrl(address)
    }

    fun reload() = if (isCurrentAddress) webView.reload() else goPath()
    fun back() { if (webView.canGoBack()) webView.goBack() }
    fun forward() { if (webView.canGoForward()) webView.goForward() }

    fun acceptWarning() {
        acceptedWarning = true; showsWarning = false
        pendingAddress?.let { go(it) }
        pendingAddress = null
    }

    fun dismissWarning() {
        showsWarning = false; pendingAddress = null
    }

    fun returnHome() {
        showsBlocked = false
        site?.let { go(it) }
    }

    private fun suspendBrowsing() {
        inspection?.cancel(); webView.stopLoading(); webView.loadUrl("about:blank"); resetHistory = true
        chapter = null; series = null; loading = false; hasLoaded = false; addressPath = ""
        acceptedWarning = false; pendingAddress = null; showsWarning = false; showsBlocked = false
        genresVerified = false; genreMessage = null; pageHidden = false
    }

    private fun updateHistory() {
        canGoBack = webView.canGoBack(); canGoForward = webView.canGoForward()
    }

    private suspend fun afterLoad(current: String, url: String) {
        series = null
        if (mode == "half-safe" && rawkumaSeriesUrl(current, url) != null) {
            genreMessage = R.string.rawkuma_checking_genres
            val context = runCatching { fetchSeries(current, url) }.getOrNull()
            if (webView.url != url) return
            when {
                context == null || (blockedGenres.isNotEmpty() && context.genres.isEmpty()) -> {
                    genreMessage = R.string.rawkuma_genres_unavailable; pageHidden = false; return
                }
                blockedGenreMatches(context.genres, blockedGenres).isNotEmpty() -> {
                    genreMessage = R.string.rawkuma_blocked; showsBlocked = true; return
                }
                else -> { series = context; genresVerified = true; genreMessage = null }
            }
        }
        pageHidden = false
        repeat(15) {
            inspect(current)
            if (chapter != null) return
            delay(1000)
        }
    }

    private suspend fun inspect(current: String) {
        val url = webView.url ?: return
        if (!rawkumaContains(current, url) || loading) return
        val result = suspendCancellableCoroutine { continuation ->
            webView.evaluateJavascript(CHAPTER_SCRIPT) { continuation.resume(it) }
        }
        // evaluateJavascript returns the JSON encoding of the script's string result.
        val json = runCatching { JSONArray("[$result]").getString(0) }.getOrNull() ?: return
        val candidate = runCatching { parseSourceChapter(current, json) }.getOrNull() ?: return
        if (candidate.url == webView.url) chapter = candidate
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun RawkumaScreen(model: AppViewModel, browser: RawkumaBrowser, onOpenChapter: (Chapter) -> Unit) {
    val context = LocalContext.current
    val download by model.download.collectAsStateWithLifecycle()
    val run by model.run.collectAsStateWithLifecycle()
    val snackbar = remember { SnackbarHostState() }
    val creditGate = rememberCreditGate(model)
    LaunchedEffect(Unit) {
        browser.start()
        model.errors.collect { snackbar.showSnackbar(errorText(context, it)) }
    }

    Box(Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            AddressBar(browser)
            if (browser.mode == "half-safe") {
                Notice(stringResource(R.string.rawkuma_external_warning))
            }
            browser.genreMessage?.let { Notice(stringResource(it)) }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                AndroidView(
                    factory = { (browser.webView.parent as? ViewGroup)?.removeView(browser.webView); browser.webView },
                    modifier = Modifier.fillMaxSize(),
                )
                if (browser.pageHidden) {
                    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {}
                }
            }
            val chapter = browser.chapter
            val progress = download
            when {
                progress != null -> DownloadCard(progress.done, progress.total, onCancel = model::cancelDownload)
                chapter != null -> ChapterBar(
                    pages = chapter.images.size,
                    enabled = browser.canTranslate && run == null && !browser.loading,
                    onTranslate = { creditGate(CreditKind.TRANSLATE) { model.importSource(chapter, browser.series, onOpenChapter) } },
                )
                else -> Text(
                    stringResource(R.string.rawkuma_hint),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 10.dp),
                )
            }
        }
        SnackbarHost(snackbar, Modifier.align(Alignment.BottomCenter).padding(bottom = 72.dp))
    }

    if (browser.showsWarning) {
        AlertDialog(
            onDismissRequest = browser::dismissWarning,
            icon = { Icon(Icons.Rounded.WarningAmber, contentDescription = null) },
            title = { Text(stringResource(R.string.rawkuma_warning_title)) },
            text = { Text(stringResource(R.string.rawkuma_external_warning)) },
            confirmButton = { Button(onClick = browser::acceptWarning) { Text(stringResource(R.string.rawkuma_continue)) } },
            dismissButton = { TextButton(onClick = browser::dismissWarning) { Text(stringResource(R.string.cancel)) } },
        )
    }
    if (browser.showsBlocked) {
        AlertDialog(
            onDismissRequest = browser::returnHome,
            title = { Text(stringResource(R.string.rawkuma_blocked_title)) },
            text = { Text(stringResource(R.string.rawkuma_blocked)) },
            confirmButton = { Button(onClick = browser::returnHome) { Text(stringResource(R.string.back)) } },
        )
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun AddressBar(browser: RawkumaBrowser) {
    val focus = LocalFocusManager.current
    Surface(color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.statusBarsPadding()) {
            Row(Modifier.padding(horizontal = 4.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                IconButton(onClick = browser::back, enabled = browser.canGoBack) {
                    Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.back))
                }
                IconButton(onClick = browser::forward, enabled = browser.canGoForward) {
                    Icon(Icons.AutoMirrored.Rounded.ArrowForward, contentDescription = stringResource(R.string.rawkuma_forward))
                }
                Surface(
                    shape = CircleShape,
                    color = MaterialTheme.colorScheme.surfaceContainerHighest,
                    modifier = Modifier.weight(1f).height(44.dp),
                ) {
                    Row(Modifier.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Rounded.Language, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        // The origin is fixed by app-config.json; only the path is editable.
                        Text(
                            browser.site.orEmpty().removePrefix("https://"),
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = FontFamily.Monospace,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                        )
                        BasicTextField(
                            value = browser.addressPath,
                            onValueChange = { browser.addressPath = it },
                            singleLine = true,
                            textStyle = MaterialTheme.typography.bodyMedium.copy(color = MaterialTheme.colorScheme.onSurface),
                            cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, imeAction = ImeAction.Go, autoCorrectEnabled = false),
                            keyboardActions = KeyboardActions(onGo = { focus.clearFocus(); browser.goPath() }),
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
                IconButton(onClick = { focus.clearFocus(); browser.reload() }) {
                    Icon(
                        if (browser.isCurrentAddress) Icons.Rounded.Refresh else Icons.AutoMirrored.Rounded.ArrowForward,
                        contentDescription = stringResource(R.string.rawkuma_reload),
                    )
                }
            }
            AnimatedVisibility(browser.loading) {
                LinearWavyProgressIndicator(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 2.dp))
            }
        }
    }
}

@Composable
private fun Notice(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onTertiaryContainer,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp),
    )
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun ChapterBar(pages: Int, enabled: Boolean, onTranslate: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = CircleShape,
        shadowElevation = 6.dp,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Row(Modifier.padding(6.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(
                pluralStringResource(R.plurals.rawkuma_pages, pages, pages),
                style = MaterialTheme.typography.titleSmall,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f).padding(start = 16.dp),
            )
            Button(
                onClick = onTranslate,
                enabled = enabled,
                shapes = ButtonDefaults.shapes(),
                contentPadding = PaddingValues(horizontal = 18.dp, vertical = 12.dp),
            ) {
                Icon(Icons.Rounded.Translate, contentDescription = null, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.rawkuma_translate_chapter), fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun DownloadCard(done: Int, total: Int, onCancel: () -> Unit) {
    Card(
        shape = MaterialTheme.shapes.large,
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer,
            contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
        ),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(stringResource(R.string.rawkuma_downloading, done, total), style = MaterialTheme.typography.bodyMedium)
                LinearWavyProgressIndicator(progress = { if (total == 0) 0f else done.toFloat() / total }, modifier = Modifier.fillMaxWidth())
            }
            Spacer(Modifier.width(12.dp))
            FilledTonalIconButton(onClick = onCancel) { Icon(Icons.Rounded.Close, contentDescription = stringResource(R.string.cancel)) }
        }
    }
}
