package com.kurubyinteractive.aimanga.ui

import android.app.Activity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.SmartDisplay
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.R
import com.kurubyinteractive.aimanga.data.RewardedStatus
import kotlinx.coroutines.launch
import uniffi.koharu_core.CreditStatus
import uniffi.koharu_core.Provider
import uniffi.koharu_core.animeActionCost
import uniffi.koharu_core.backendEnhancedCost
import uniffi.koharu_core.backendTranslateCost
import uniffi.koharu_core.providerCreditId

/**
 * A credit-priced action (iPad `CreditAction` + rerun) and its
 * `profile_reserve` action ID. Chapter translations always ask first; Anime
 * Studio actions only ask when the balance does not cover them.
 */
enum class CreditKind(val action: String, val rerun: Boolean, val alwaysAsk: Boolean) {
    TRANSLATE("translate", false, true),
    RERUN("translate", true, true),
    ENHANCED("translateEnhanced", false, true),
    IMAGE("image", false, false),
    PROMPT_ENHANCE("enhance", false, false),
    PROMPT_GENERATE("generatePrompt", false, false),
}

private fun CreditKind.provider(selected: Provider): String = when (this) {
    CreditKind.TRANSLATE, CreditKind.RERUN, CreditKind.ENHANCED -> "backend"
    CreditKind.IMAGE -> "local"
    CreditKind.PROMPT_ENHANCE, CreditKind.PROMPT_GENERATE -> providerCreditId(selected)
}

private fun CreditKind.cost(credits: CreditStatus, selected: Provider): Long = when (this) {
    CreditKind.TRANSLATE -> backendTranslateCost(credits)
    CreditKind.RERUN -> credits.costRerunBackend
    CreditKind.ENHANCED -> backendEnhancedCost(credits)
    CreditKind.IMAGE -> animeActionCost(credits, "image", false)
    CreditKind.PROMPT_ENHANCE -> animeActionCost(credits, "enhance", selected == Provider.BACKEND)
    CreditKind.PROMPT_GENERATE -> animeActionCost(credits, "generatePrompt", selected == Provider.BACKEND)
}

/**
 * Runs an action that spends credits (iPad `requestCredits` + `CreditPanel`).
 * When the balance or an earlier video pass covers it, the action runs (after
 * a confirmation for chapter translations). Otherwise the user can watch a
 * rewarded video: the server grants one pass for exactly this action, which
 * `profile_reserve` then uses instead of credits.
 */
@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
fun rememberCreditGate(model: AppViewModel): (CreditKind, () -> Unit) -> Unit {
    val prefs by model.prefs.collectAsStateWithLifecycle()
    val account by model.accountState.collectAsStateWithLifecycle()
    val rewarded by model.rewardedAds.status.collectAsStateWithLifecycle()
    val activity = LocalContext.current as? Activity
    val scope = rememberCoroutineScope()
    var pending by remember { mutableStateOf<Pair<CreditKind, () -> Unit>?>(null) }
    pending?.let { (kind, action) ->
        val credits = account.credits
        val cost = credits?.let { kind.cost(it, prefs.provider) }
        val fingerprint = "${kind.action}:${kind.provider(prefs.provider)}:${kind.rerun}"
        val affordable = credits == null || cost == null || credits.credit >= cost || (credits.videoAccess[fingerprint] ?: 0) > 0
        AlertDialog(
            onDismissRequest = { if (rewarded == null) pending = null },
            title = {
                Text(
                    stringResource(
                        when {
                            !affordable -> R.string.credit_not_enough_title
                            kind == CreditKind.ENHANCED -> R.string.enhanced_confirm_title
                            else -> R.string.credit_confirm_title
                        },
                    ),
                )
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (kind == CreditKind.ENHANCED) Text(stringResource(R.string.enhanced_explanation))
                    Text(
                        if (credits != null && cost != null) stringResource(R.string.credit_confirm_body, cost.toInt(), credits.credit.toInt())
                        else stringResource(R.string.credit_confirm_unknown),
                    )
                    if (!affordable) Text(stringResource(R.string.credit_video_explanation), style = MaterialTheme.typography.bodyMedium)
                    rewarded?.let { status ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            LoadingIndicator(Modifier.size(28.dp))
                            Spacer(Modifier.width(8.dp))
                            Text(stringResource(rewardedStatusText(status)), style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    if (model.rewardedAds.testing) Text(stringResource(R.string.ads_testing), style = MaterialTheme.typography.labelSmall)
                }
            },
            confirmButton = {
                if (affordable) {
                    Button(onClick = { pending = null; action() }) {
                        Text(stringResource(if (kind == CreditKind.ENHANCED) R.string.enhanced_translation else R.string.credit_continue))
                    }
                } else {
                    Button(
                        enabled = rewarded == null && activity != null,
                        onClick = {
                            scope.launch {
                                try {
                                    val earned = model.rewardedAds.watch(activity ?: return@launch, model.account, "action", kind.action, kind.provider(prefs.provider), kind.rerun)
                                    if (earned) {
                                        pending = null
                                        action()
                                    }
                                } catch (error: Exception) {
                                    model.reportError(error)
                                }
                            }
                        },
                    ) {
                        Icon(Icons.Rounded.SmartDisplay, contentDescription = null, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(6.dp))
                        Text(stringResource(R.string.credit_watch_continue))
                    }
                }
            },
            dismissButton = { TextButton(onClick = { pending = null }, enabled = rewarded == null) { Text(stringResource(R.string.cancel)) } },
        )
    }
    return { kind, action ->
        val charged = when (kind) {
            CreditKind.TRANSLATE, CreditKind.RERUN -> prefs.provider == Provider.BACKEND
            else -> true
        }
        val credits = account.credits
        if (!charged || account.user == null || credits == null) {
            // Signed out, the action itself reports that an account is needed.
            action()
        } else {
            val fingerprint = "${kind.action}:${kind.provider(prefs.provider)}:${kind.rerun}"
            val affordable = credits.credit >= kind.cost(credits, prefs.provider) || (credits.videoAccess[fingerprint] ?: 0) > 0
            if (affordable && !kind.alwaysAsk) {
                action()
            } else {
                model.refreshCredits()
                pending = kind to action
            }
        }
    }
}

fun rewardedStatusText(status: RewardedStatus): Int = when (status) {
    RewardedStatus.LOADING -> R.string.ads_loading
    RewardedStatus.WATCHING -> R.string.ads_watching
    RewardedStatus.UPDATING -> R.string.ads_updating
}

/** "N credits" price for [kind] with the current provider, or "Uses credits" before the profile loads. */
@Composable
fun creditCostLabel(model: AppViewModel, kind: CreditKind): String {
    val prefs by model.prefs.collectAsStateWithLifecycle()
    val account by model.accountState.collectAsStateWithLifecycle()
    if ((kind == CreditKind.TRANSLATE || kind == CreditKind.RERUN) && prefs.provider != Provider.BACKEND) return stringResource(R.string.cost_no_credits)
    val credits = account.credits ?: return stringResource(R.string.cost_uses_credits)
    val cost = kind.cost(credits, prefs.provider).toInt()
    return pluralStringResource(R.plurals.cost_credits, cost, cost)
}

/** A menu entry title with its credit price underneath. */
@Composable
fun CostText(title: String, cost: String) {
    Column {
        Text(title)
        Text(cost, style = androidx.compose.material3.MaterialTheme.typography.labelMedium, color = androidx.compose.material3.MaterialTheme.colorScheme.primary)
    }
}
