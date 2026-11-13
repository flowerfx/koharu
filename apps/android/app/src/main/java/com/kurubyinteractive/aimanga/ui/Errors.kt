package com.kurubyinteractive.aimanga.ui

import android.content.Context
import com.kurubyinteractive.aimanga.AnimeBlock
import com.kurubyinteractive.aimanga.AnimeBlockedException
import com.kurubyinteractive.aimanga.AnimeStorageException
import com.kurubyinteractive.aimanga.ProviderDisabledException
import com.kurubyinteractive.aimanga.R
import uniffi.koharu_core.AnimeException
import uniffi.koharu_core.BackendException
import uniffi.koharu_core.RawkumaException
import uniffi.koharu_core.TranslateException

/** Localized text for a Rust core or platform failure. */
fun errorText(context: Context, error: Throwable): String = when (error) {
    is RawkumaException.NotChapter -> context.getString(R.string.error_not_chapter)
    is RawkumaException.SeriesUnavailable -> context.getString(R.string.error_series_unavailable)
    is RawkumaException.Download -> context.getString(R.string.error_page_download, error.page.toInt())
    is RawkumaException.Storage -> context.getString(R.string.error_storage)
    is AnimeBlockedException -> context.getString(
        when (error.reason) {
            AnimeBlock.UNSUPPORTED_ABI -> R.string.anime_unsupported
            AnimeBlock.MEMORY -> R.string.anime_memory
            AnimeBlock.PROVIDER -> R.string.anime_prompt_provider
            AnimeBlock.UPSCALER -> R.string.anime_upscaler_missing
            AnimeBlock.SIGN_IN -> R.string.anime_sign_in
            AnimeBlock.RESTRICTED -> R.string.anime_restricted
            AnimeBlock.REVIEW_UNAVAILABLE -> R.string.anime_review_unavailable
            AnimeBlock.CONSENT -> R.string.anime_review_consent_needed
        },
    )
    is com.kurubyinteractive.aimanga.data.RewardedAdUnavailableException -> context.getString(R.string.ads_unavailable)
    is AnimeStorageException -> context.getString(
        R.string.anime_error_storage, error.file,
        android.text.format.Formatter.formatFileSize(context, error.needed), android.text.format.Formatter.formatFileSize(context, error.free),
    )
    is AnimeException.Download -> context.getString(R.string.anime_error_download, error.file)
    is AnimeException.Checksum -> context.getString(R.string.anime_error_checksum, error.file)
    is AnimeException.Unavailable -> context.getString(R.string.anime_unsupported)
    is AnimeException.InvalidSettings -> context.getString(R.string.anime_error_settings)
    is AnimeException.Native -> context.getString(R.string.anime_error_native, error.detail)
    is AnimeException.Storage -> context.getString(R.string.error_storage)
    is TranslateException.Backend -> errorText(context, error.error)
    is BackendException.NotConfigured -> context.getString(R.string.backend_not_configured)
    is BackendException.SignedOut -> context.getString(R.string.backend_needs_account)
    is BackendException.Unauthorized -> context.getString(R.string.backend_unauthorized)
    is BackendException.EmailRejected -> context.getString(R.string.backend_email_rejected)
    is BackendException.NotEnoughCredits -> context.getString(R.string.backend_not_enough_credits)
    is BackendException.Network -> context.getString(R.string.backend_unreachable)
    is BackendException.Http -> context.getString(R.string.backend_http, error.status.toInt())
    is BackendException.InvalidResponse -> context.getString(R.string.backend_invalid)
    is BackendException.AiFailed -> context.getString(
        when (error.code) {
            "no_active_provider" -> R.string.backend_ai_no_provider
            "content_refused" -> R.string.backend_ai_refused
            "request_too_large" -> R.string.backend_too_large
            "worker_interrupted" -> R.string.backend_ai_interrupted
            else -> R.string.backend_ai_failed
        },
    )
    is BackendException.TooLarge -> context.getString(R.string.backend_too_large)
    is BackendException.Timeout -> context.getString(R.string.backend_timeout)
    is ProviderDisabledException -> context.getString(R.string.error_provider_disabled)
    is TranslateException.MissingKey -> context.getString(R.string.error_missing_key)
    is TranslateException.InvalidSettings -> context.getString(R.string.error_invalid_settings)
    is TranslateException.MissingModel -> context.getString(R.string.error_missing_model)
    is TranslateException.Unauthorized -> context.getString(R.string.error_unauthorized)
    is TranslateException.Quota -> context.getString(R.string.error_quota)
    is TranslateException.RateLimited -> context.getString(R.string.error_rate_limited)
    is TranslateException.Http -> context.getString(R.string.error_http, error.status.toInt())
    is TranslateException.Network -> context.getString(R.string.error_network, error.detail)
    is TranslateException.InvalidResponse -> context.getString(R.string.error_invalid_response)
    is TranslateException.InvalidTranslation -> context.getString(R.string.error_invalid_translation)
    is TranslateException.SegmentTooLarge -> context.getString(R.string.error_segment_too_large)
    is TranslateException.UnsupportedLanguage -> context.getString(R.string.error_unsupported_language)
    is TranslateException.NoModels -> context.getString(R.string.error_no_models)
    else -> error.localizedMessage ?: error.javaClass.simpleName
}
