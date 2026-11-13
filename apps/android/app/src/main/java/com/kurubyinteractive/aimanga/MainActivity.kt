package com.kurubyinteractive.aimanga

import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.Row
import androidx.compose.material3.NavigationRailItem
import androidx.compose.material3.NavigationRail
import com.kurubyinteractive.aimanga.data.DailyReminder
import androidx.activity.result.contract.ActivityResultContracts
import android.os.Build
import android.content.pm.PackageManager
import android.content.Intent
import android.Manifest
import android.graphics.Color
import android.content.Context
import android.os.Bundle
import kotlinx.coroutines.launch
import androidx.lifecycle.lifecycleScope
import com.kurubyinteractive.aimanga.data.AppLanguage
import com.kurubyinteractive.aimanga.data.CloudServices
import com.kurubyinteractive.aimanga.ui.SubscriptionOffer
import com.kurubyinteractive.aimanga.ui.DailyRewardScreen
import com.kurubyinteractive.aimanga.ui.UpdateRequired
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.viewModels
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.consumeWindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.CollectionsBookmark
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import com.kurubyinteractive.aimanga.ui.RawkumaBrowser
import com.kurubyinteractive.aimanga.ui.RawkumaScreen
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.kurubyinteractive.aimanga.ui.AnimeStudioScreen
import com.kurubyinteractive.aimanga.ui.ImportScreen
import com.kurubyinteractive.aimanga.ui.KoharuTheme
import com.kurubyinteractive.aimanga.ui.LibraryScreen
import com.kurubyinteractive.aimanga.ui.ReaderScreen
import com.kurubyinteractive.aimanga.ui.SettingsScreen
import com.kurubyinteractive.aimanga.ui.ShelfScreen
import com.kurubyinteractive.aimanga.ui.isDark

class MainActivity : ComponentActivity() {
    private val model: AppViewModel by viewModels()
    private val studio: AnimeStudioModel by viewModels()
    private val cloud by lazy { CloudServices(applicationContext) }

    override fun attachBaseContext(newBase: Context) {
        super.attachBaseContext(AppLanguage.wrap(newBase))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        cloud.configure()
        if (savedInstanceState == null) lifecycleScope.launch { model.subscriptions.newLaunch() }
        if (intent?.getBooleanExtra(DailyReminder.EXTRA_OPEN_DAILY, false) == true) model.openDaily.value = true
        requestNotificationsOnce()
        enableEdgeToEdge()
        setContent {
            val prefs by model.prefs.collectAsStateWithLifecycle()
            val dark = isDark(prefs.theme)
            // System bar icons follow the app theme, which can differ from the system's.
            LaunchedEffect(dark) {
                val style = if (dark) SystemBarStyle.dark(Color.TRANSPARENT)
                else SystemBarStyle.light(Color.TRANSPARENT, Color.TRANSPARENT)
                enableEdgeToEdge(statusBarStyle = style, navigationBarStyle = style)
            }
            KoharuTheme(mode = prefs.theme, dynamicColor = prefs.dynamicColor) {
                val update by cloud.requiredUpdate.collectAsStateWithLifecycle()
                val required = update
                if (required != null) UpdateRequired(required, onCheckAgain = cloud::refresh) else App(model, studio, cloud)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (intent.getBooleanExtra(DailyReminder.EXTRA_OPEN_DAILY, false)) model.openDaily.value = true
    }

    /** Android 13+: ask once for notifications, used only by the daily-reset reminder. */
    private fun requestNotificationsOnce() {
        if (Build.VERSION.SDK_INT < 33) return
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        val prefs = getSharedPreferences("daily_reminder", MODE_PRIVATE)
        if (prefs.getBoolean("asked", false)) return
        prefs.edit().putBoolean("asked", true).apply()
        notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    private val notificationPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) {
        DailyReminder.schedule(this)
    }

    override fun onStart() {
        super.onStart()
        // Cold launch and every return to the foreground check app-config.json.
        model.refreshConfig()
    }
}

/**
 * Tabs ("library", "rawkuma", "anime", "settings") sit under a bottom navigation bar;
 * "import" and "reader:<chapter id>" open full screen over them. Back always
 * returns toward the Library tab.
 */
@Composable
private fun App(model: AppViewModel, studio: AnimeStudioModel, cloud: CloudServices) {
    val context = LocalContext.current
    var tab by rememberSaveable { mutableStateOf("library") }
    // Full-screen pages over the tabs, innermost last ("shelf:…", "reader:…", "import:<project>").
    var stack by rememberSaveable { mutableStateOf(listOf<String>()) }
    val push = { route: String -> stack = stack + route }
    val pop = { stack = stack.dropLast(1) }
    val config by model.config.collectAsStateWithLifecycle()
    val browser = remember { RawkumaBrowser(context) }
    LaunchedEffect(config.config) {
        browser.configure(config.config.rawkumaUrl, config.config.contentSafetyMode, config.config.blockedGenres)
    }
    // Library and reader links to a Rawkuma manga or chapter open it in the Rawkuma tab.
    val openSource = { url: String ->
        if (browser.site != null) {
            stack = emptyList(); tab = "rawkuma"; browser.go(url)
        }
    }
    val tabs = buildList {
        add(Triple("library", R.string.library_title, Icons.Rounded.CollectionsBookmark))
        if (browser.site != null) add(Triple("rawkuma", R.string.rawkuma_title, Icons.Rounded.Language))
        add(Triple("anime", R.string.anime_tab, Icons.Rounded.Palette))
        add(Triple("settings", R.string.settings_title, Icons.Rounded.Settings))
    }
    if (tabs.none { it.first == tab }) tab = "library"
    BackHandler(enabled = stack.isNotEmpty()) { pop() }
    BackHandler(enabled = stack.isEmpty() && tab == "rawkuma" && browser.canGoBack) { browser.back() }
    BackHandler(enabled = stack.isEmpty() && tab != "library" && !(tab == "rawkuma" && browser.canGoBack)) { tab = "library" }
    val overlay = stack.lastOrNull()
    // Material 3 expanded width (tablets in landscape, foldables open).
    val wide = LocalConfiguration.current.screenWidthDp >= 840
    val screen = overlay?.substringBefore(':') ?: tab
    LaunchedEffect(screen) { cloud.trackScreen(screen) }

    Box(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface)) {
        AnimatedContent(targetState = overlay, transitionSpec = { fadeIn() togetherWith fadeOut() }, label = "overlay") { current ->
            when {
                current != null && current.startsWith("import:") -> ImportScreen(
                    model,
                    nextChapter = model.library.chapters.value.size + 1,
                    projectId = current.removePrefix("import:").ifEmpty { null },
                    onBack = pop,
                )
                current != null && current.startsWith("reader:") ->
                    ReaderScreen(
                        model, current.removePrefix("reader:"), onBack = pop, onOpenSource = openSource,
                        // A translation into another language continues in a copy of the chapter.
                        onSwitchChapter = { id -> stack = stack.dropLast(1) + "reader:$id" },
                    )
                current != null && current.startsWith("shelf:") -> ShelfScreen(
                    model,
                    key = current.removePrefix("shelf:"),
                    onBack = pop,
                    onOpen = { push("reader:${it.id}") },
                    onImport = { push("import:$it") },
                    onOpenSource = openSource,
                )
                else -> Scaffold(
                    bottomBar = {
                        // Tablets and other wide windows use a navigation rail instead.
                        if (!wide) NavigationBar {
                            tabs.forEach { (id, label, icon) ->
                                NavigationBarItem(
                                    selected = tab == id,
                                    onClick = { tab = id },
                                    icon = { Icon(icon, contentDescription = null) },
                                    label = { Text(stringResource(label)) },
                                )
                            }
                        }
                    },
                    contentWindowInsets = WindowInsets(0),
                ) { padding ->
                    Row(Modifier.fillMaxSize().padding(padding).consumeWindowInsets(padding)) {
                    if (wide) NavigationRail(Modifier.fillMaxHeight(), containerColor = MaterialTheme.colorScheme.surfaceContainer) {
                        Spacer(Modifier.weight(1f))
                        tabs.forEach { (id, label, icon) ->
                            NavigationRailItem(
                                selected = tab == id,
                                onClick = { tab = id },
                                icon = { Icon(icon, contentDescription = null) },
                                label = { Text(stringResource(label)) },
                                modifier = Modifier.padding(vertical = 6.dp),
                            )
                        }
                        Spacer(Modifier.weight(1f))
                    }
                    Box(Modifier.weight(1f).fillMaxHeight()) {
                        when (tab) {
                            "rawkuma" -> RawkumaScreen(model, browser, onOpenChapter = { push("reader:${it.id}") })
                            "settings" -> SettingsScreen(model, onBack = null)
                            "anime" -> {
                                val run by model.run.collectAsStateWithLifecycle()
                                AnimeStudioScreen(studio, model, config.config.contentSafetyMode, translating = run != null)
                            }
                            else -> LibraryScreen(
                                model,
                                onOpen = { push("reader:${it.id}") },
                                onOpenShelf = { push("shelf:$it") },
                                onImport = { push("import:") },
                                onOpenSource = openSource,
                                // The site exists only in none-safe and half-safe with a configured URL.
                                onBrowse = if (browser.site != null) ({ tab = "rawkuma" }) else null,
                            )
                        }
                    }
                    }
                }
            }
        }
        SubscriptionOffer(model)
        val openDaily by model.openDaily.collectAsStateWithLifecycle()
        if (openDaily) DailyRewardScreen(model) { model.openDaily.value = false }
    }
}
