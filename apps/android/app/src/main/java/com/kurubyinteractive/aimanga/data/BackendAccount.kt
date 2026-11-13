package com.kurubyinteractive.aimanga.data

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import org.json.JSONObject
import uniffi.koharu_core.BackendClient
import uniffi.koharu_core.BackendException
import uniffi.koharu_core.BackendSession
import uniffi.koharu_core.BackendUser
import uniffi.koharu_core.CreditStatus
import java.util.UUID

data class AccountState(
    /** False when this build has no backend identity or the server is inactive. */
    val available: Boolean,
    val user: BackendUser? = null,
    val credits: CreditStatus? = null,
    val working: Boolean = false,
    /** Signed in from a saved session while the backend was unreachable. */
    val offline: Boolean = false,
)

/**
 * The Kuruby account (port of iPad `NakamaAuthentication` + `CreditStore`):
 * guest sign-in with a per-install device ID or an existing email account.
 * Session tokens and the device ID are sealed with the Android Keystore,
 * scoped by the connection's credential namespace.
 */
class BackendAccount(context: Context, private val settings: SettingsStore) {
    private val identity = runCatching {
        val json = JSONObject(context.assets.open("nakama-connection.json").bufferedReader().use { it.readText() })
        val certificate = context.assets.open("nakama-connection.cer").use { it.readBytes() }
        Triple(json.getString("server_key"), json.getString("credential_namespace"), certificate)
    }.getOrNull()

    /** Whether this build carries the backend identity files. */
    val hasIdentity: Boolean get() = identity != null

    private var endpoint: String? = null
    var client: BackendClient? = null
        private set
    private val state = MutableStateFlow(AccountState(available = false))
    val current: StateFlow<AccountState> = state.asStateFlow()

    private val scope: String get() = identity?.second ?: "nakama"

    /** Applies app-config.json's `server`; a changed endpoint signs in again from the saved session. */
    suspend fun configure(active: Boolean, serverEndpoint: String) {
        val id = identity
        if (!active || id == null) {
            client = null; endpoint = null
            state.value = AccountState(available = false)
            return
        }
        if (serverEndpoint == endpoint && client != null) return
        endpoint = serverEndpoint
        client = runCatching { BackendClient(serverEndpoint, id.first, id.third) }.getOrNull()
        state.value = AccountState(available = client != null)
        restore()
    }

    private suspend fun restore() {
        val client = client ?: return
        val saved = loadSession() ?: return
        client.setSession(saved)
        run {
            try {
                val user = client.restore()
                state.update { it.copy(user = user, offline = false) }
                refreshCredits()
            } catch (error: BackendException.Network) {
                // Revalidated on the next backend command.
                state.update { it.copy(offline = true) }
            } catch (error: BackendException) {
                clearSession()
            }
        }
    }

    suspend fun signInGuest() = signIn { it.signInDevice(deviceId()) }

    suspend fun signInEmail(email: String, password: String) = signIn { it.signInEmail(email, password) }

    private suspend fun signIn(action: suspend (BackendClient) -> BackendUser) {
        val client = client ?: throw BackendException.NotConfigured()
        state.update { it.copy(working = true) }
        try {
            val user = action(client)
            saveSession(client.session())
            state.update { it.copy(user = user, offline = false) }
            refreshCredits()
        } finally {
            state.update { it.copy(working = false) }
        }
    }

    suspend fun signOut() {
        client?.signOut()
        clearSession()
    }

    suspend fun refreshCredits() {
        val client = client ?: return
        if (state.value.user == null) return
        val credits = client.credits()
        saveSession(client.session())
        state.update { it.copy(credits = credits, offline = false) }
    }

    suspend fun claimDaily() {
        val client = client ?: return
        val credits = client.claimDaily()
        state.update { it.copy(credits = credits) }
    }

    /** Opens a rewarded-video ticket; see [RewardedAds]. */
    suspend fun startVideo(purpose: String, action: String, provider: String, rerun: Boolean): String {
        val client = client ?: throw BackendException.NotConfigured()
        try {
            return client.startVideo(purpose, action, provider, rerun)
        } finally {
            afterCall()
        }
    }

    /** Records an earned reward and refreshes the balance and video passes. */
    suspend fun completeVideo(videoId: String) {
        val client = client ?: throw BackendException.NotConfigured()
        val credits = try {
            client.completeVideo(videoId)
        } finally {
            afterCall()
        }
        state.update { it.copy(credits = credits) }
    }

    /** Nakama verifies a Play purchase (its `originalJson`) and returns the updated tier. */
    suspend fun validateGoogleSubscription(purchaseJson: String) {
        val client = client ?: throw BackendException.NotConfigured()
        val credits = try {
            client.validateGoogleSubscription(purchaseJson)
        } finally {
            afterCall()
        }
        state.update { it.copy(credits = credits) }
    }

    /** Persists tokens refreshed during a backend call; a rejected session signs out. */
    fun afterCall() {
        val session = client?.session()
        if (session == null && state.value.user != null) clearSession() else saveSession(session)
    }

    private fun deviceId(): String {
        var id = settings.secret("$scope:device")
        if (id.isEmpty()) {
            id = UUID.randomUUID().toString() + UUID.randomUUID().toString()
            settings.setSecret("$scope:device", id)
        }
        return id
    }

    private fun loadSession(): BackendSession? = runCatching {
        val json = JSONObject(settings.secret("$scope:session"))
        BackendSession(json.getString("token"), json.getString("refresh_token"))
    }.getOrNull()

    private fun saveSession(session: BackendSession?) {
        if (session == null) return
        settings.setSecret("$scope:session", JSONObject().put("token", session.token).put("refresh_token", session.refreshToken).toString())
    }

    private fun clearSession() {
        client?.setSession(null)
        settings.setSecret("$scope:session", "")
        state.update { it.copy(user = null, credits = null, offline = false) }
    }
}
