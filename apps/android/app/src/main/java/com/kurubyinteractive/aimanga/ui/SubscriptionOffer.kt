package com.kurubyinteractive.aimanga.ui

import android.app.Activity
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Language
import androidx.compose.material.icons.rounded.Redeem
import androidx.compose.material.icons.rounded.Translate
import androidx.compose.material.icons.rounded.WorkspacePremium
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.R
import com.kurubyinteractive.aimanga.data.SubscriptionMessage
import com.kurubyinteractive.aimanga.data.SubscriptionStore
import kotlinx.coroutines.launch

/**
 * Full-screen Premium offer (port of iPad `SubscriptionOfferScreen`): shown on
 * launch at most once a day to a free account, and from Settings. Closing it
 * means "Continue for free".
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun SubscriptionOffer(model: AppViewModel) {
    val store = model.subscriptions
    val state by store.current.collectAsStateWithLifecycle()
    val account by model.accountState.collectAsStateWithLifecycle()
    if (!state.showOffer) return
    val credits = account.credits
    val activity = LocalContext.current as? Activity
    val scope = rememberCoroutineScope()
    val uri = LocalUriHandler.current

    Dialog(
        onDismissRequest = store::continueWithoutSubscription,
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            Column(
                Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .statusBarsPadding()
                    .navigationBarsPadding()
                    .padding(24.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(20.dp),
            ) {
                Column(Modifier.widthIn(max = 600.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(20.dp)) {
                    Spacer(Modifier.size(8.dp))
                    Icon(Icons.Rounded.WorkspacePremium, contentDescription = null, tint = BrandPink, modifier = Modifier.size(56.dp))
                    Text(stringResource(R.string.sub_unlock), style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                    Text(stringResource(R.string.sub_tagline), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                    Column(
                        Modifier
                            .fillMaxWidth()
                            .background(BrandPink.copy(alpha = 0.08f), RoundedCornerShape(20.dp))
                            .padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(16.dp),
                    ) {
                        if (credits != null) {
                            Benefit(Icons.Rounded.Redeem, stringResource(R.string.sub_daily, credits.dailyPremiumUser, credits.dailyFreeUser))
                            Benefit(
                                Icons.Rounded.Translate,
                                stringResource(
                                    R.string.sub_translate_cost,
                                    credits.costTranslatePremium + credits.costBackendSurcharge,
                                    credits.costTranslateFree + credits.costBackendSurcharge,
                                ),
                            )
                        }
                        Benefit(Icons.Rounded.Language, stringResource(R.string.sub_providers))
                    }
                    Text(stringResource(R.string.sub_footnote), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (state.loading) LoadingIndicator(Modifier.size(40.dp))
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        val product = state.product
                        Text(product?.name ?: stringResource(R.string.sub_title), style = MaterialTheme.typography.titleMedium)
                        val price = product?.let(SubscriptionStore::monthlyPrice) ?: SubscriptionStore.LIST_PRICE
                        Text(stringResource(R.string.sub_per_month, price), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = BrandPink)
                    }
                    state.message?.let { message ->
                        Text(
                            stringResource(
                                when (message) {
                                    SubscriptionMessage.UNAVAILABLE -> R.string.sub_unavailable
                                    SubscriptionMessage.LOAD_FAILED -> R.string.sub_load_failed
                                    SubscriptionMessage.PENDING -> R.string.sub_pending
                                    SubscriptionMessage.PURCHASE_FAILED -> R.string.sub_failed
                                    SubscriptionMessage.NOT_VERIFIED -> R.string.sub_not_verified
                                    SubscriptionMessage.NOTHING_TO_RESTORE -> R.string.sub_restore_none
                                },
                            ),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            textAlign = TextAlign.Center,
                        )
                    }
                    Button(
                        onClick = { activity?.let(store::purchase) },
                        enabled = state.product != null && !state.loading && !state.purchasing && account.user != null,
                        modifier = Modifier.fillMaxWidth().heightIn(min = 52.dp),
                    ) {
                        if (state.purchasing) LoadingIndicator(Modifier.size(24.dp)) else Text(stringResource(R.string.sub_subscribe), style = MaterialTheme.typography.titleMedium)
                    }
                    TextButton(onClick = store::continueWithoutSubscription, modifier = Modifier.fillMaxWidth()) {
                        Text(stringResource(R.string.sub_continue), style = MaterialTheme.typography.titleMedium)
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = { scope.launch { store.restore() } }, enabled = !state.purchasing) { Text(stringResource(R.string.sub_restore)) }
                        if (state.product == null) {
                            TextButton(onClick = { scope.launch { store.refresh() } }, enabled = !state.loading && !state.purchasing) { Text(stringResource(R.string.sub_try_again)) }
                        }
                    }
                    Text(stringResource(R.string.sub_disclosure), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = { uri.openUri("https://www.kuruby.com/privacy-policy") }) { Text(stringResource(R.string.sub_privacy)) }
                        TextButton(onClick = { uri.openUri("https://www.kuruby.com/terms-of-service") }) { Text(stringResource(R.string.sub_terms)) }
                    }
                }
            }
        }
    }
}

@Composable
private fun Benefit(icon: ImageVector, text: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = BrandPink, modifier = Modifier.size(28.dp))
        Spacer(Modifier.size(12.dp))
        Text(text, style = MaterialTheme.typography.bodyLarge)
    }
}
