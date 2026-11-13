package com.kurubyinteractive.aimanga.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.kurubyinteractive.aimanga.AppViewModel
import com.kurubyinteractive.aimanga.R
import uniffi.koharu_core.Provider
import uniffi.koharu_core.backendEnhancedCost
import uniffi.koharu_core.backendTranslateCost

/** What a chapter action costs with Backend API (iPad `CreditAction` + rerun). */
enum class CreditKind { TRANSLATE, RERUN, ENHANCED }

/**
 * Runs an action that translates a chapter; when it is charged through
 * Backend API it first shows the price and balance (iPad `requestCredits`).
 * Enhanced translation always uses Backend API; other providers run directly.
 */
@Composable
fun rememberCreditGate(model: AppViewModel): (CreditKind, () -> Unit) -> Unit {
    val prefs by model.prefs.collectAsStateWithLifecycle()
    val account by model.accountState.collectAsStateWithLifecycle()
    var pending by remember { mutableStateOf<Pair<CreditKind, () -> Unit>?>(null) }
    pending?.let { (kind, action) ->
        val credits = account.credits
        val cost = credits?.let {
            when (kind) {
                CreditKind.TRANSLATE -> backendTranslateCost(it)
                CreditKind.RERUN -> it.costRerunBackend
                CreditKind.ENHANCED -> backendEnhancedCost(it)
            }
        }
        AlertDialog(
            onDismissRequest = { pending = null },
            title = {
                Text(stringResource(if (kind == CreditKind.ENHANCED) R.string.enhanced_confirm_title else R.string.credit_confirm_title))
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    if (kind == CreditKind.ENHANCED) Text(stringResource(R.string.enhanced_explanation))
                    Text(
                        if (credits != null && cost != null) stringResource(R.string.credit_confirm_body, cost, credits.credit)
                        else stringResource(R.string.credit_confirm_unknown),
                    )
                }
            },
            confirmButton = {
                Button(
                    enabled = credits == null || cost == null || credits.credit >= cost,
                    onClick = { pending = null; action() },
                ) { Text(stringResource(if (kind == CreditKind.ENHANCED) R.string.enhanced_translation else R.string.translate)) }
            },
            dismissButton = { TextButton(onClick = { pending = null }) { Text(stringResource(R.string.cancel)) } },
        )
    }
    return { kind, action ->
        val charged = kind == CreditKind.ENHANCED || prefs.provider == Provider.BACKEND
        if (charged && account.user != null) {
            model.refreshCredits()
            pending = kind to action
        } else {
            // Signed out, the action itself reports that Backend API needs an account.
            action()
        }
    }
}
