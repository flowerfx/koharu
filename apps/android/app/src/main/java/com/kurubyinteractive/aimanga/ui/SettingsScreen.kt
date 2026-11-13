package com.kurubyinteractive.aimanga.ui

import android.os.Build
import androidx.compose.foundation.Image
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarHost
import uniffi.koharu_core.backendTranslateCost
import androidx.compose.material3.TextButton
import androidx.compose.material3.AlertDialog
import androidx.compose.material.icons.rounded.AccountCircle
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.CloudSync
import androidx.compose.material.icons.rounded.ErrorOutline
import androidx.compose.material.icons.rounded.Info
import androidx.compose.material.icons.rounded.Palette
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.ExposedDropdownMenu
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.BuildConfig
import com.kurubyinteractive.aimanga.ModelState
import com.kurubyinteractive.aimanga.R
import com.kurubyinteractive.aimanga.data.ConfigStatus
import com.kurubyinteractive.aimanga.data.AppLanguage
import com.kurubyinteractive.aimanga.data.ReadingMode
import com.kurubyinteractive.aimanga.data.ThemeMode
import uniffi.koharu_core.providers
import uniffi.koharu_core.targetLanguages

@OptIn(ExperimentalMaterial3Api::class, ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SettingsScreen(model: AppViewModel, onBack: (() -> Unit)?) {
    val context = LocalContext.current
    val prefs by model.prefs.collectAsStateWithLifecycle()
    val key by model.apiKey.collectAsStateWithLifecycle()
    val models by model.models.collectAsStateWithLifecycle()
    val config by model.config.collectAsStateWithLifecycle()
    val enabled by model.enabledProviders.collectAsStateWithLifecycle()
    val uiLocale = LocalConfiguration.current.locales[0]
    val languages = remember(uiLocale) { targetLanguages() }
    val languageNames = remember(uiLocale) { targetNames(languages.map { it.tag }, uiLocale) }
    val provider = remember(prefs.provider) { providers().first { it.provider == prefs.provider } }
    val providerEnabled = enabled.any { it.provider == prefs.provider }
    val account by model.accountState.collectAsStateWithLifecycle()
    var emailDialog by rememberSaveable { mutableStateOf(false) }
    val snackbar = remember { SnackbarHostState() }
    LaunchedEffect(Unit) { model.errors.collect { snackbar.showSnackbar(errorText(context, it)) } }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbar) },
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.settings_title), fontWeight = FontWeight.SemiBold) },
                navigationIcon = {
                    if (onBack != null) {
                        IconButton(onClick = onBack) {
                            Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.back))
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
            )
        },
    ) { padding ->
        Column(
            Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (account.available) {
                Section(Icons.Rounded.AccountCircle, stringResource(R.string.section_account)) {
                    val user = account.user
                    if (user == null) {
                        Text(
                            stringResource(R.string.account_signed_out),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Button(onClick = model::signInGuest, enabled = !account.working, shapes = ButtonDefaults.shapes(), modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.account_guest))
                        }
                        OutlinedButton(onClick = { emailDialog = true }, enabled = !account.working, modifier = Modifier.fillMaxWidth()) {
                            Text(stringResource(R.string.account_email))
                        }
                        if (account.working) Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) { LoadingIndicator(Modifier.size(40.dp)) }
                    } else {
                        Detail(stringResource(R.string.account_user), user.email ?: stringResource(R.string.account_guest_name))
                        account.credits?.let { credits ->
                            Detail(
                                stringResource(R.string.account_credits),
                                stringResource(
                                    R.string.account_credit_value,
                                    credits.credit,
                                    stringResource(if (credits.accountType == "premium") R.string.account_premium else R.string.account_free),
                                ),
                            )
                            Detail(stringResource(R.string.account_cost), stringResource(R.string.account_cost_value, backendTranslateCost(credits)))
                            if (credits.canClaimDaily) {
                                Button(onClick = model::claimDaily, shapes = ButtonDefaults.shapes(), modifier = Modifier.fillMaxWidth()) {
                                    Text(stringResource(R.string.account_claim_daily))
                                }
                            }
                        }
                        if (account.offline) StatusLine(Icons.Rounded.ErrorOutline, stringResource(R.string.account_offline), error = true)
                        OutlinedButton(onClick = model::signOut, modifier = Modifier.fillMaxWidth()) { Text(stringResource(R.string.account_sign_out)) }
                    }
                }
            }

            Section(Icons.Rounded.Translate, stringResource(R.string.section_translation)) {
                Dropdown(
                    label = stringResource(R.string.provider),
                    selected = provider.name,
                    options = enabled.map { it.name },
                    onSelect = { model.selectProvider(enabled[it].provider) },
                    error = if (providerEnabled) null else stringResource(R.string.error_provider_disabled),
                )
                if (provider.needsServer) {
                    OutlinedTextField(
                        value = prefs.server,
                        onValueChange = { value -> model.update { it.copy(server = value) } },
                        label = { Text(stringResource(R.string.server)) },
                        supportingText = { Text(stringResource(R.string.server_hint)) },
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                        singleLine = true,
                        shape = MaterialTheme.shapes.medium,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                if (provider.needsAccount) {
                    Text(
                        stringResource(if (account.user == null) R.string.backend_needs_account else R.string.backend_uses_credits),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                var reveal by rememberSaveable { mutableStateOf(false) }
                if (!provider.needsAccount) OutlinedTextField(
                    value = key,
                    onValueChange = model::setApiKey,
                    label = { Text(stringResource(if (provider.needsKey) R.string.api_key else R.string.api_key_optional)) },
                    supportingText = { Text(stringResource(R.string.api_key_hint)) },
                    visualTransformation = if (reveal) VisualTransformation.None else PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    trailingIcon = {
                        IconButton(onClick = { reveal = !reveal }) {
                            Icon(if (reveal) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility, contentDescription = null)
                        }
                    },
                    singleLine = true,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth(),
                )
                if (!provider.needsAccount) {
                    Button(
                        onClick = model::loadModels,
                        enabled = models !is ModelState.Loading,
                        shapes = ButtonDefaults.shapes(),
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text(stringResource(R.string.load_models)) }
                    when (val state = models) {
                        ModelState.Loading -> Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            LoadingIndicator(Modifier.size(40.dp))
                        }
                        is ModelState.Loaded -> StatusLine(
                            Icons.Rounded.CheckCircle,
                            pluralStringResource(R.plurals.models_loaded, state.models.size, state.models.size),
                            error = false,
                        )
                        is ModelState.Failed -> StatusLine(Icons.Rounded.ErrorOutline, errorText(context, state.error), error = true)
                        ModelState.Idle -> {}
                    }
                    val loaded = (models as? ModelState.Loaded)?.models
                    if (loaded != null) {
                        Dropdown(
                            label = stringResource(R.string.model),
                            selected = prefs.model,
                            options = loaded.map { if (it.name == it.id) it.id else "${it.name} · ${it.id}" },
                            onSelect = { index -> model.update { it.copy(model = loaded[index].id) } },
                        )
                    } else {
                        OutlinedTextField(
                            value = prefs.model,
                            onValueChange = { value -> model.update { it.copy(model = value.trim()) } },
                            label = { Text(stringResource(R.string.model)) },
                            supportingText = { Text(stringResource(R.string.model_hint)) },
                            singleLine = true,
                            shape = MaterialTheme.shapes.medium,
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
                Dropdown(
                    label = stringResource(R.string.target_language),
                    selected = languages.indexOfFirst { it.tag == prefs.target }.takeIf { it >= 0 }?.let { languageNames[it] } ?: prefs.target,
                    options = languageNames,
                    onSelect = { index -> model.update { it.copy(target = languages[index].tag) } },
                )
                OutlinedTextField(
                    value = prefs.instructions,
                    onValueChange = { value -> model.update { it.copy(instructions = value) } },
                    label = { Text(stringResource(R.string.instructions)) },
                    minLines = 2,
                    shape = MaterialTheme.shapes.medium,
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            Section(Icons.Rounded.Palette, stringResource(R.string.section_appearance)) {
                val activity = LocalContext.current as? android.app.Activity
                var language by remember { mutableStateOf(AppLanguage.current(context)) }
                Dropdown(
                    label = stringResource(R.string.app_language),
                    selected = if (language == AppLanguage.SYSTEM) stringResource(R.string.system_default) else language.nativeName,
                    options = AppLanguage.entries.map { if (it == AppLanguage.SYSTEM) context.getString(R.string.system_default) else it.nativeName },
                    onSelect = { index ->
                        val chosen = AppLanguage.entries[index]
                        if (chosen != language) {
                            language = chosen
                            AppLanguage.apply(context, chosen)
                            // Android 13+ recreates the activity itself.
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) activity?.recreate()
                        }
                    },
                )
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Text(stringResource(R.string.theme), style = MaterialTheme.typography.labelLarge)
                val modes = listOf(
                    ThemeMode.SYSTEM to R.string.theme_system,
                    ThemeMode.LIGHT to R.string.theme_light,
                    ThemeMode.DARK to R.string.theme_dark,
                )
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    modes.forEachIndexed { index, (mode, label) ->
                        SegmentedButton(
                            selected = prefs.theme == mode,
                            onClick = { model.update { it.copy(theme = mode) } },
                            shape = SegmentedButtonDefaults.itemShape(index, modes.size),
                        ) { Text(stringResource(label), maxLines = 1) }
                    }
                }
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                Text(stringResource(R.string.reading_mode), style = MaterialTheme.typography.labelLarge)
                val readings = listOf(ReadingMode.HORIZONTAL to R.string.reading_horizontal, ReadingMode.VERTICAL to R.string.reading_vertical)
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                    readings.forEachIndexed { index, (mode, label) ->
                        SegmentedButton(
                            selected = prefs.reading == mode,
                            onClick = { model.update { it.copy(reading = mode) } },
                            shape = SegmentedButtonDefaults.itemShape(index, readings.size),
                        ) { Text(stringResource(label), maxLines = 1) }
                    }
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(stringResource(R.string.dynamic_color), style = MaterialTheme.typography.bodyLarge)
                            Text(
                                stringResource(R.string.dynamic_color_hint),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                        Spacer(Modifier.width(12.dp))
                        Switch(checked = prefs.dynamicColor, onCheckedChange = { on -> model.update { it.copy(dynamicColor = on) } })
                    }
                }
            }

            Section(Icons.Rounded.CloudSync, stringResource(R.string.section_configuration)) {
                Detail(stringResource(R.string.config_target), "${model.configEnvironment} · ${model.configVersion}")
                Detail(stringResource(R.string.config_status), stringResource(config.status.label()))
                config.etag?.let { Detail(stringResource(R.string.config_etag), it.trim('"')) }
                config.lastModified?.let { Detail(stringResource(R.string.config_modified), it) }
                OutlinedButton(
                    onClick = model::refreshConfig,
                    enabled = config.status != ConfigStatus.CHECKING,
                    modifier = Modifier.fillMaxWidth(),
                ) { Text(stringResource(R.string.config_check)) }
            }

            Section(Icons.Rounded.Info, stringResource(R.string.section_about)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Image(
                        painterResource(R.drawable.app_icon_art),
                        contentDescription = null,
                        modifier = Modifier.size(56.dp).clip(RoundedCornerShape(16.dp)),
                    )
                    Spacer(Modifier.width(16.dp))
                    Column {
                        Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        Text(
                            stringResource(R.string.version_label, BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                Text(
                    stringResource(R.string.about_body),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.size(8.dp))
        }
    }
    if (emailDialog) EmailSignIn(onDismiss = { emailDialog = false }, onSignIn = model::signInEmail)
}

@Composable
private fun EmailSignIn(onDismiss: () -> Unit, onSignIn: (String, String) -> Unit) {
    var email by rememberSaveable { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.account_email)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = email, onValueChange = { email = it }, singleLine = true,
                    label = { Text(stringResource(R.string.account_email_address)) },
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    shape = MaterialTheme.shapes.medium,
                )
                OutlinedTextField(
                    value = password, onValueChange = { password = it }, singleLine = true,
                    label = { Text(stringResource(R.string.account_password)) },
                    visualTransformation = PasswordVisualTransformation(),
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                    shape = MaterialTheme.shapes.medium,
                )
            }
        },
        confirmButton = {
            Button(enabled = email.isNotBlank() && password.length >= 8, onClick = { onSignIn(email, password); onDismiss() }) {
                Text(stringResource(R.string.account_sign_in))
            }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) } },
    )
}

/**
 * Translation targets named in the interface language. The country stays only
 * for real variants of one language (en-US/en-GB, pt-PT/pt-BR, zh-CN/zh-TW).
 */
private fun targetNames(tags: List<String>, ui: java.util.Locale): List<String> {
    val counts = tags.groupingBy { java.util.Locale.forLanguageTag(it).language }.eachCount()
    return tags.map { tag ->
        val locale = java.util.Locale.forLanguageTag(tag)
        val name = if ((counts[locale.language] ?: 0) > 1) locale.getDisplayName(ui) else locale.getDisplayLanguage(ui)
        name.replaceFirstChar { it.titlecase(ui) }
    }
}

private fun ConfigStatus.label() = when (this) {
    ConfigStatus.BUNDLED -> R.string.config_bundled
    ConfigStatus.SAVED -> R.string.config_saved
    ConfigStatus.CHECKING -> R.string.config_checking
    ConfigStatus.UNCHANGED -> R.string.config_unchanged
    ConfigStatus.UPDATED -> R.string.config_updated
    ConfigStatus.FAILED -> R.string.config_failed
}

@Composable
private fun Section(icon: ImageVector, title: String, content: @Composable () -> Unit) {
    Card(
        shape = MaterialTheme.shapes.extraLarge,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Surface(color = MaterialTheme.colorScheme.primaryContainer, shape = CircleShape) {
                    Icon(
                        icon,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.onPrimaryContainer,
                        modifier = Modifier.padding(8.dp).size(20.dp),
                    )
                }
                Spacer(Modifier.width(12.dp))
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            }
            content()
        }
    }
}

@Composable
private fun Detail(label: String, value: String) {
    Row {
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(0.4f),
        )
        Text(value, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(0.6f))
    }
}

@Composable
private fun StatusLine(icon: ImageVector, text: String, error: Boolean) {
    val color = if (error) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(8.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, color = if (error) color else MaterialTheme.colorScheme.onSurface)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun Dropdown(label: String, selected: String, options: List<String>, onSelect: (Int) -> Unit, error: String? = null) {
    var expanded by remember { mutableStateOf(false) }
    ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
        OutlinedTextField(
            value = selected,
            onValueChange = {},
            readOnly = true,
            singleLine = true,
            label = { Text(label) },
            isError = error != null,
            supportingText = error?.let { { Text(it) } },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
            shape = MaterialTheme.shapes.medium,
            modifier = Modifier.fillMaxWidth().menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            options.forEachIndexed { index, option ->
                DropdownMenuItem(text = { Text(option) }, onClick = { onSelect(index); expanded = false })
            }
        }
    }
}
