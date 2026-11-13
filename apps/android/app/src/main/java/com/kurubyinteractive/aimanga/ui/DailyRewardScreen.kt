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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material.icons.rounded.CheckCircle
import androidx.compose.material.icons.rounded.Redeem
import androidx.compose.material.icons.rounded.SmartDisplay
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.R
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * Daily reward (iPad `CreditPanel` without a pending request): today's
 * credits (free or Premium amount), the normal claim, and the rewarded video
 * that raises today's reward to ×2. Resets at 00:00 UTC.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun DailyRewardScreen(model: AppViewModel, onDismiss: () -> Unit) {
    val account by model.accountState.collectAsStateWithLifecycle()
    val rewarded by model.rewardedAds.status.collectAsStateWithLifecycle()
    val privacyRequired by model.rewardedAds.privacyOptionsRequired.collectAsStateWithLifecycle()
    val activity = LocalContext.current as? Activity
    val scope = rememberCoroutineScope()
    val credits = account.credits
    val busy = rewarded != null || account.working
    LaunchedEffect(Unit) { model.refreshCredits() }

    Dialog(
        onDismissRequest = { if (rewarded == null) onDismiss() },
        properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false),
    ) {
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
            Column(
                Modifier.fillMaxSize().verticalScroll(rememberScrollState()).statusBarsPadding().navigationBarsPadding().padding(20.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    IconButton(onClick = onDismiss, enabled = rewarded == null) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, contentDescription = stringResource(R.string.back)) }
                    Text(stringResource(R.string.daily_title), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                }
                Column(Modifier.widthIn(max = 600.dp).padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Icon(Icons.Rounded.Redeem, contentDescription = null, tint = BrandPink, modifier = Modifier.size(56.dp))
                    if (credits == null) {
                        LoadingIndicator()
                        return@Column
                    }
                    val premium = credits.accountType == "premium"
                    val daily = (if (premium) credits.dailyPremiumUser else credits.dailyFreeUser).toInt()
                    Text(pluralStringResource(R.plurals.cost_credits, credits.credit.toInt(), credits.credit.toInt()), style = MaterialTheme.typography.displaySmall, fontWeight = FontWeight.Bold)
                    Text(stringResource(R.string.daily_membership, stringResource(if (premium) R.string.account_premium else R.string.account_free)), color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (!premium) {
                        TextButton(onClick = { onDismiss(); model.subscriptions.showOffer() }) { Text(stringResource(R.string.daily_upgrade)) }
                    }
                    Column(
                        Modifier.fillMaxWidth().background(BrandPink.copy(alpha = 0.08f), RoundedCornerShape(20.dp)).padding(20.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(stringResource(R.string.daily_today), style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                            Text(pluralStringResource(R.plurals.cost_credits, daily, daily), style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.primary)
                        }
                        if (credits.canClaimDaily) {
                            Button(onClick = model::claimDaily, enabled = !busy, modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                                Icon(Icons.Rounded.Redeem, contentDescription = null, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(stringResource(R.string.daily_claim, daily))
                            }
                        } else {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Rounded.CheckCircle, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp))
                                Text(stringResource(R.string.daily_claimed), style = MaterialTheme.typography.bodyMedium)
                            }
                        }
                        val multiplier = credits.rewardVideoMultiplier.let { if (it % 1.0 == 0.0) it.toInt().toString() else it.toString() }
                        FilledTonalButton(
                            onClick = {
                                scope.launch {
                                    try {
                                        model.rewardedAds.watch(activity ?: return@launch, model.account, "daily", "translate", "local", false)
                                    } catch (error: Exception) {
                                        model.reportError(error)
                                    }
                                }
                            },
                            enabled = !busy && credits.dailyVideoAvailable && activity != null,
                            modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp),
                        ) {
                            Icon(Icons.Rounded.SmartDisplay, contentDescription = null, modifier = Modifier.size(18.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(stringResource(R.string.daily_video, multiplier))
                        }
                        Text(
                            if (credits.dailyVideoAvailable) stringResource(R.string.daily_video_hint, credits.dailyVideoBonus.toInt())
                            else stringResource(R.string.daily_video_done),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    rewarded?.let { status ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            LoadingIndicator(Modifier.size(28.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(stringResource(rewardedStatusText(status)))
                        }
                    }
                    val next = LocalDate.now(ZoneOffset.UTC).plusDays(1).atStartOfDay(ZoneOffset.UTC)
                        .withZoneSameInstant(java.time.ZoneId.systemDefault())
                        .format(DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT))
                    Text(stringResource(R.string.daily_next, next), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(stringResource(R.string.daily_rules), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (model.rewardedAds.testing) Text(stringResource(R.string.ads_testing), style = MaterialTheme.typography.labelSmall)
                    if (privacyRequired && activity != null) {
                        TextButton(onClick = { model.rewardedAds.showPrivacyOptions(activity) }) { Text(stringResource(R.string.ads_privacy)) }
                    }
                }
            }
        }
    }
}
