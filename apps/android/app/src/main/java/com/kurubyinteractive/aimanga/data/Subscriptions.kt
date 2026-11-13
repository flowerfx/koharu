package com.kurubyinteractive.aimanga.data

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.AcknowledgePurchaseParams
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import android.util.Log
import kotlin.coroutines.resume

/** What the Premium offer shows; `message` is a [SubscriptionMessage] or a server error text. */
data class SubscriptionState(
    val product: ProductDetails? = null,
    val loading: Boolean = false,
    val purchasing: Boolean = false,
    val message: SubscriptionMessage? = null,
    val error: String? = null,
    val showOffer: Boolean = false,
    val launchOfferFinished: Boolean = false,
)

enum class SubscriptionMessage { UNAVAILABLE, LOAD_FAILED, PENDING, PURCHASE_FAILED, NOT_VERIFIED, NOTHING_TO_RESTORE }

/**
 * Premium through Google Play Billing (port of iPad `SubscriptionStore`). Play
 * handles payment and renewal; Nakama reads each purchase token from Google
 * Play and binds it to the account (obfuscated account ID = Nakama user ID)
 * before Premium is unlocked. Purchases are acknowledged only after that.
 */
class SubscriptionStore(context: Context, private val account: BackendAccount, private val scope: CoroutineScope) {
    private val state = MutableStateFlow(SubscriptionState())
    val current: StateFlow<SubscriptionState> = state.asStateFlow()
    val hasPremium: Boolean get() = account.current.value.credits?.accountType == "premium"

    private val billing = BillingClient.newBuilder(context)
        .setListener { result, purchases ->
            when (result.responseCode) {
                BillingClient.BillingResponseCode.OK -> scope.launch { purchases.orEmpty().forEach { receive(it) } }
                BillingClient.BillingResponseCode.USER_CANCELED -> {}
                BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> scope.launch { refreshEntitlements() }
                else -> state.update { it.copy(message = SubscriptionMessage.PURCHASE_FAILED) }
            }
            state.update { it.copy(purchasing = false) }
        }
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().enablePrepaidPlans().build())
        .enableAutoServiceReconnection()
        .build()

    private suspend fun connected(): Boolean {
        if (billing.isReady) return true
        return withTimeoutOrNull(10_000) { connect() } ?: false
    }

    private suspend fun connect(): Boolean {
        return suspendCancellableCoroutine { continuation ->
            billing.startConnection(object : BillingClientStateListener {
                override fun onBillingSetupFinished(result: BillingResult) {
                    if (result.responseCode != BillingClient.BillingResponseCode.OK) Log.w("Billing", "setup ${result.responseCode} ${result.debugMessage}")
                    if (continuation.isActive) continuation.resume(result.responseCode == BillingClient.BillingResponseCode.OK)
                }

                override fun onBillingServiceDisconnected() {
                    if (continuation.isActive) continuation.resume(false)
                }
            })
        }
    }

    /**
     * Called once the credit profile is loaded; every app launch offers Premium
     * to a free account. The server-owned tier decides, so a slow or missing
     * Play connection never delays or hides the offer.
     */
    suspend fun prepareLaunchOffer() {
        if (state.value.launchOfferFinished || state.value.showOffer) return
        if (account.current.value.credits == null) return
        state.update { if (hasPremium) it.copy(launchOfferFinished = true) else it.copy(showOffer = true) }
        loadProduct()
        refreshEntitlements()
    }

    /** A new app launch (fresh activity, not a rotation): offer Premium again to a free account. */
    suspend fun newLaunch() {
        state.update { it.copy(launchOfferFinished = false) }
        prepareLaunchOffer()
    }

    fun showOffer() {
        state.update { it.copy(showOffer = true, message = null, error = null) }
        scope.launch { loadProduct() }
    }

    fun continueWithoutSubscription() = state.update { it.copy(showOffer = false, launchOfferFinished = true) }

    fun resetAccount() = state.update { SubscriptionState(product = it.product) }

    suspend fun refresh() {
        refreshEntitlements()
        loadProduct()
    }

    private suspend fun loadProduct() {
        if (state.value.loading) return
        state.update { it.copy(loading = true) }
        try {
            if (!connected()) {
                state.update { it.copy(message = SubscriptionMessage.LOAD_FAILED) }
                return
            }
            val params = QueryProductDetailsParams.newBuilder().setProductList(
                listOf(QueryProductDetailsParams.Product.newBuilder().setProductId(PRODUCT_ID).setProductType(BillingClient.ProductType.SUBS).build()),
            ).build()
            val (result, products) = suspendCancellableCoroutine { continuation ->
                billing.queryProductDetailsAsync(params) { result, details ->
                    if (continuation.isActive) continuation.resume(result to details.productDetailsList)
                }
            }
            val product = products.firstOrNull { it.productId == PRODUCT_ID && basePlan(it) != null }
            state.update {
                it.copy(
                    product = product,
                    message = when {
                        result.responseCode != BillingClient.BillingResponseCode.OK -> SubscriptionMessage.LOAD_FAILED
                        product == null -> SubscriptionMessage.UNAVAILABLE
                        else -> it.message.takeUnless { m -> m == SubscriptionMessage.UNAVAILABLE || m == SubscriptionMessage.LOAD_FAILED }
                    },
                )
            }
        } finally {
            state.update { it.copy(loading = false) }
        }
    }

    /** Sends every owned Play subscription to Nakama, then reloads the server-owned tier. */
    suspend fun refreshEntitlements() {
        if (account.current.value.user == null || !connected()) return
        val purchases = suspendCancellableCoroutine { continuation ->
            billing.queryPurchasesAsync(QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build()) { _, list ->
                if (continuation.isActive) continuation.resume(list)
            }
        }
        purchases.forEach { receive(it) }
        // A subscription bought on another device stays a server-owned entitlement.
        runCatching { account.refreshCredits() }
        if (hasPremium) state.update { it.copy(showOffer = false, launchOfferFinished = true) }
    }

    private suspend fun receive(purchase: Purchase) {
        if (PRODUCT_ID !in purchase.products) return
        if (purchase.purchaseState == Purchase.PurchaseState.PENDING) {
            state.update { it.copy(message = SubscriptionMessage.PENDING) }
            return
        }
        if (purchase.purchaseState != Purchase.PurchaseState.PURCHASED) return
        try {
            account.validateGoogleSubscription(purchase.originalJson)
        } catch (error: Exception) {
            state.update { it.copy(message = SubscriptionMessage.NOT_VERIFIED, error = error.message) }
            return
        }
        if (hasPremium) state.update { it.copy(showOffer = false, launchOfferFinished = true, message = null, error = null) }
        // Acknowledge only after Nakama has verified and stored the purchase;
        // Play refunds purchases that stay unacknowledged for three days.
        if (!purchase.isAcknowledged) {
            suspendCancellableCoroutine { continuation ->
                billing.acknowledgePurchase(AcknowledgePurchaseParams.newBuilder().setPurchaseToken(purchase.purchaseToken).build()) {
                    if (continuation.isActive) continuation.resume(Unit)
                }
            }
        }
    }

    fun purchase(activity: Activity) {
        val product = state.value.product ?: return
        val offer = basePlan(product) ?: return
        val user = account.current.value.user ?: return
        if (state.value.purchasing) return
        state.update { it.copy(purchasing = true, message = null, error = null) }
        val params = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(
                listOf(BillingFlowParams.ProductDetailsParams.newBuilder().setProductDetails(product).setOfferToken(offer.offerToken).build()),
            )
            // Nakama only accepts the purchase for the account named here.
            .setObfuscatedAccountId(user.id)
            .build()
        val result = billing.launchBillingFlow(activity, params)
        if (result.responseCode != BillingClient.BillingResponseCode.OK) {
            state.update { it.copy(purchasing = false, message = SubscriptionMessage.PURCHASE_FAILED) }
        }
    }

    suspend fun restore() {
        if (state.value.purchasing) return
        state.update { it.copy(purchasing = true, message = null, error = null) }
        try {
            refreshEntitlements()
            if (!hasPremium && state.value.message == null) state.update { it.copy(message = SubscriptionMessage.NOTHING_TO_RESTORE) }
        } finally {
            state.update { it.copy(purchasing = false) }
        }
    }

    companion object {
        /** iPad uses `com.kurubyInteractive.aimanga.premium.monthly`; Play product IDs must be lowercase. */
        const val PRODUCT_ID = "com.kurubyinteractive.aimanga.premium"
        private const val BASE_PLAN = "monthly"

        /** The base plan's US list price, shown until Play returns the buyer's localized price. */
        const val LIST_PRICE = "US$15.00"

        /** The plain monthly base plan: no trial or introductory offer. */
        fun basePlan(product: ProductDetails): ProductDetails.SubscriptionOfferDetails? =
            product.subscriptionOfferDetails?.firstOrNull { it.basePlanId == BASE_PLAN && it.offerId == null }

        fun monthlyPrice(product: ProductDetails): String? =
            basePlan(product)?.pricingPhases?.pricingPhaseList?.lastOrNull()?.formattedPrice
    }
}
