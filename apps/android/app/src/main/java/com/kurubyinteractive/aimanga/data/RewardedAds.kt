package com.kurubyinteractive.aimanga.data

import android.app.Activity
import com.google.android.gms.ads.AdError
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.FullScreenContentCallback
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.MobileAds
import com.google.android.gms.ads.rewarded.RewardedAd
import com.google.android.gms.ads.rewarded.RewardedAdLoadCallback
import com.google.android.ump.ConsentRequestParameters
import com.google.android.ump.UserMessagingPlatform
import com.kurubyinteractive.aimanga.BuildConfig
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** The ad could not be loaded or shown; nothing was granted. */
class RewardedAdUnavailableException : IllegalStateException()

/** What the rewarded flow is doing, for a progress line. */
enum class RewardedStatus { LOADING, WATCHING, UPDATING }

/**
 * AdMob rewarded videos (port of iPad `RewardedAds`): UMP consent, load,
 * then a Nakama ticket (`profile_video_start`), show, and only after the SDK's
 * earned callback `profile_video_complete`. `daily` adds the ×2 daily bonus;
 * `action` grants one pass for `action:provider:rerun` that `profile_reserve`
 * uses instead of credits. Debug builds always use Google's test unit.
 */
class RewardedAds {
    val testing: Boolean = BuildConfig.DEBUG
    private val unit = if (testing) TEST_UNIT else UNIT
    private var initialized = false
    private val state = MutableStateFlow<RewardedStatus?>(null)
    val status: StateFlow<RewardedStatus?> = state.asStateFlow()
    private val privacy = MutableStateFlow(false)
    /** UMP says this user must be able to reopen the ad privacy form. */
    val privacyOptionsRequired: StateFlow<Boolean> = privacy.asStateFlow()

    /** Returns true when the reward was earned and recorded; false when the ad was closed early. */
    suspend fun watch(activity: Activity, account: BackendAccount, purpose: String, action: String, provider: String, rerun: Boolean): Boolean {
        if (state.value != null) return false
        val user = account.current.value.user?.id ?: throw RewardedAdUnavailableException()
        state.value = RewardedStatus.LOADING
        try {
            val ad = try {
                consent(activity)
                if (!initialized) {
                    suspendCancellableCoroutine { c -> MobileAds.initialize(activity) { if (c.isActive) c.resume(Unit) } }
                    initialized = true
                }
                load(activity)
            } catch (error: RewardedAdUnavailableException) {
                throw error
            } catch (error: Exception) {
                throw RewardedAdUnavailableException()
            }
            val ticket = account.startVideo(purpose, action, provider, rerun)
            if (account.current.value.user?.id != user) return false
            state.value = RewardedStatus.WATCHING
            val earned = suspendCancellableCoroutine { continuation ->
                var rewarded = false
                ad.fullScreenContentCallback = object : FullScreenContentCallback() {
                    override fun onAdDismissedFullScreenContent() {
                        if (continuation.isActive) continuation.resume(rewarded)
                    }

                    override fun onAdFailedToShowFullScreenContent(error: AdError) {
                        if (continuation.isActive) continuation.resumeWithException(RewardedAdUnavailableException())
                    }
                }
                ad.show(activity) { rewarded = true }
            }
            // Closing before the SDK's reward event earns nothing.
            if (!earned || account.current.value.user?.id != user) return false
            state.value = RewardedStatus.UPDATING
            account.completeVideo(ticket)
            return true
        } finally {
            state.value = null
        }
    }

    private suspend fun consent(activity: Activity) {
        val info = UserMessagingPlatform.getConsentInformation(activity)
        suspendCancellableCoroutine { c ->
            info.requestConsentInfoUpdate(activity, ConsentRequestParameters.Builder().build(),
                { if (c.isActive) c.resume(Unit) },
                { if (c.isActive) c.resume(Unit) })
        }
        suspendCancellableCoroutine { c ->
            UserMessagingPlatform.loadAndShowConsentFormIfRequired(activity) { if (c.isActive) c.resume(Unit) }
        }
        privacy.value = info.privacyOptionsRequirementStatus == com.google.android.ump.ConsentInformation.PrivacyOptionsRequirementStatus.REQUIRED
        if (!info.canRequestAds()) throw RewardedAdUnavailableException()
    }

    fun showPrivacyOptions(activity: Activity) {
        UserMessagingPlatform.showPrivacyOptionsForm(activity) {
            privacy.value = UserMessagingPlatform.getConsentInformation(activity).privacyOptionsRequirementStatus ==
                com.google.android.ump.ConsentInformation.PrivacyOptionsRequirementStatus.REQUIRED
        }
    }

    private suspend fun load(activity: Activity): RewardedAd = suspendCancellableCoroutine { c ->
        RewardedAd.load(activity, unit, AdRequest.Builder().build(), object : RewardedAdLoadCallback() {
            override fun onAdLoaded(ad: RewardedAd) {
                if (c.isActive) c.resume(ad)
            }

            override fun onAdFailedToLoad(error: LoadAdError) {
                if (c.isActive) c.resumeWithException(RewardedAdUnavailableException())
            }
        })
    }

    private companion object {
        const val UNIT = "ca-app-pub-9623603115892772/2752821574"
        /** Google's public Android rewarded test unit. */
        const val TEST_UNIT = "ca-app-pub-3940256099942544/5224354917"
    }
}
