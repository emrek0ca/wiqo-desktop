package com.wiqo.android.data.billing

import android.app.Activity
import android.content.Context
import com.android.billingclient.api.BillingClient
import com.android.billingclient.api.BillingClientStateListener
import com.android.billingclient.api.BillingFlowParams
import com.android.billingclient.api.BillingResult
import com.android.billingclient.api.PendingPurchasesParams
import com.android.billingclient.api.ProductDetails
import com.android.billingclient.api.ProductDetailsResponseListener
import com.android.billingclient.api.Purchase
import com.android.billingclient.api.QueryProductDetailsParams
import com.android.billingclient.api.QueryPurchasesParams
import com.wiqo.android.data.network.ApiException
import com.wiqo.android.data.network.WiqoApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import java.security.MessageDigest

data class PlayBillingState(
    val loading: Boolean = true,
    val available: Boolean = false,
    val busy: Boolean = false,
    val price: String? = null,
    val tier: String = "",
    val plans: List<PlanSummary> = emptyList(),
    val messageUsed: Int? = null,
    val messageLimit: Int? = null,
    val imageUsed: Int? = null,
    val imageLimit: Int? = null,
    val pcAllowed: Boolean? = null,
    val statusMessage: String? = null,
    val error: String? = null,
)

data class PlanSummary(val id: String, val label: String, val messagesPerDay: Int, val imagesPerDay: Int, val pcAllowed: Boolean)

/** Google Play adapter. Pro access is refreshed only after the backend verifies the purchase token. */
class PlayBillingRepository(context: Context, private val api: WiqoApi) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(PlayBillingState())
    val state = mutableState.asStateFlow()
    private var productDetails: ProductDetails? = null
    private var offerToken: String? = null

    fun clearAccountState() {
        mutableState.value = PlayBillingState(loading = false, available = productDetails != null && offerToken != null,
            price = mutableState.value.price, plans = mutableState.value.plans)
    }

    private val billingClient = BillingClient.newBuilder(context.applicationContext)
        .setListener { result, purchases -> handlePurchaseUpdate(result, purchases) }
        .enablePendingPurchases(PendingPurchasesParams.newBuilder().enableOneTimeProducts().build())
        .enableAutoServiceReconnection()
        .build()

    fun load() {
        mutableState.value = mutableState.value.copy(loading = true, error = null)
        refreshSubscription()
        scope.launch {
            runCatching { api.get("billing/plans") as? JsonObject }.getOrNull()?.let { root ->
                val plans = (root["plans"] as? JsonArray).orEmpty().mapNotNull { value ->
                    val item = value as? JsonObject ?: return@mapNotNull null
                    val id = item.scalar("id") ?: return@mapNotNull null
                    PlanSummary(id, item.scalar("label") ?: id,
                        item.scalar("messagesPerDay")?.toIntOrNull() ?: return@mapNotNull null,
                        item.scalar("imagesPerDay")?.toIntOrNull() ?: return@mapNotNull null,
                        item.scalar("pcAllowed") == "true")
                }
                mutableState.value = mutableState.value.copy(plans = plans)
            }
        }
        if (billingClient.isReady) {
            queryProduct()
            queryExistingPurchases()
            return
        }
        billingClient.startConnection(object : BillingClientStateListener {
            override fun onBillingSetupFinished(result: BillingResult) {
                if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                    mutableState.value = mutableState.value.copy(loading = false, available = false, error = "Google Play bağlantısı kurulamadı. Biraz sonra tekrar dene.")
                    return
                }
                queryProduct()
                queryExistingPurchases()
            }

            override fun onBillingServiceDisconnected() {
                mutableState.value = mutableState.value.copy(available = false, statusMessage = "Google Play bağlantısı kesildi.")
            }
        })
    }

    fun purchase(activity: Activity) {
        val details = productDetails
        val offer = offerToken
        val accountId = api.currentAccountId()
        if (details == null || offer == null || accountId == null) {
            mutableState.value = mutableState.value.copy(error = "Wiqo Pro şu anda satın alınamıyor. Hesabını ve Google Play bağlantını kontrol et.")
            return
        }
        val product = BillingFlowParams.ProductDetailsParams.newBuilder()
            .setProductDetails(details)
            .setOfferToken(offer)
            .build()
        val flow = BillingFlowParams.newBuilder()
            .setProductDetailsParamsList(listOf(product))
            .setObfuscatedAccountId(googlePlayAccountId(accountId))
            .build()
        val result = billingClient.launchBillingFlow(activity, flow)
        if (result.responseCode != BillingClient.BillingResponseCode.OK && result.responseCode != BillingClient.BillingResponseCode.USER_CANCELED) {
            mutableState.value = mutableState.value.copy(error = "Google Play satın alma ekranı açılamadı. Tekrar deneyebilirsin.")
        }
    }

    fun restore() {
        if (!billingClient.isReady) {
            load()
            mutableState.value = mutableState.value.copy(statusMessage = "Google Play bağlantısı kuruluyor. Biraz sonra tekrar dene.")
            return
        }
        mutableState.value = mutableState.value.copy(busy = true, error = null, statusMessage = null)
        queryExistingPurchases(restore = true)
    }

    private fun queryProduct() {
        val product = QueryProductDetailsParams.Product.newBuilder()
            .setProductId(PRODUCT_ID)
            .setProductType(BillingClient.ProductType.SUBS)
            .build()
        val params = QueryProductDetailsParams.newBuilder().setProductList(listOf(product)).build()
        billingClient.queryProductDetailsAsync(params, ProductDetailsResponseListener { result, response ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                mutableState.value = mutableState.value.copy(loading = false, available = false)
                return@ProductDetailsResponseListener
            }
            val details = response.productDetailsList.firstOrNull { it.productId == PRODUCT_ID }
            val offer = details?.subscriptionOfferDetails?.firstOrNull()
            val price = offer?.pricingPhases?.pricingPhaseList?.lastOrNull()?.formattedPrice
            productDetails = details
            offerToken = offer?.offerToken
            mutableState.value = mutableState.value.copy(loading = false, available = details != null && offer != null, price = price)
        })
    }

    private fun queryExistingPurchases(restore: Boolean = false) {
        val params = QueryPurchasesParams.newBuilder().setProductType(BillingClient.ProductType.SUBS).build()
        billingClient.queryPurchasesAsync(params) { result, purchases ->
            if (result.responseCode != BillingClient.BillingResponseCode.OK) {
                if (restore) mutableState.value = mutableState.value.copy(busy = false, statusMessage = "Satın alımlar şu anda kontrol edilemedi.")
                return@queryPurchasesAsync
            }
            val proPurchases = purchases.filter { PRODUCT_ID in it.products && it.purchaseState == Purchase.PurchaseState.PURCHASED }
            if (proPurchases.isEmpty()) {
                if (restore) mutableState.value = mutableState.value.copy(busy = false, statusMessage = "Geri yüklenecek Wiqo Pro satın alımı bulunamadı.")
                return@queryPurchasesAsync
            }
            verifyPurchases(proPurchases)
        }
    }

    private fun handlePurchaseUpdate(result: BillingResult, purchases: MutableList<Purchase>?) {
        when (result.responseCode) {
            BillingClient.BillingResponseCode.OK -> {
                val matching = purchases.orEmpty().filter { PRODUCT_ID in it.products }
                if (matching.any { it.purchaseState == Purchase.PurchaseState.PENDING }) {
                    mutableState.value = mutableState.value.copy(statusMessage = "Satın alma beklemede. Google Play onayladığında erişimin açılacak.")
                }
                verifyPurchases(matching.filter { it.purchaseState == Purchase.PurchaseState.PURCHASED })
            }
            BillingClient.BillingResponseCode.USER_CANCELED -> mutableState.value = mutableState.value.copy(statusMessage = "Satın alma iptal edildi.")
            else -> mutableState.value = mutableState.value.copy(error = "Google Play satın alımı tamamlayamadı. Tekrar deneyebilirsin.")
        }
    }

    private fun verifyPurchases(purchases: List<Purchase>) {
        if (purchases.isEmpty()) return
        val accountId = api.currentAccountId() ?: return
        mutableState.value = mutableState.value.copy(busy = true, error = null, statusMessage = "Satın alma Wiqo hesabınla doğrulanıyor…")
        scope.launch {
            var verified = false
            for (purchase in purchases) {
                if (api.currentAccountId() != accountId) break
                val purchaseAccount = purchase.accountIdentifiers?.obfuscatedAccountId
                if (purchaseAccount != null && purchaseAccount != googlePlayAccountId(accountId)) continue
                try {
                    api.verifyGooglePlayPurchase(purchase.purchaseToken)
                    verified = true
                    break
                } catch (error: ApiException) {
                    mutableState.value = mutableState.value.copy(error = error.message ?: "Satın alma doğrulanamadı.")
                } catch (_: Exception) {
                    mutableState.value = mutableState.value.copy(error = "Satın alma sunucuda doğrulanamadı. Biraz sonra tekrar dene.")
                }
            }
            if (api.currentAccountId() == accountId) {
                mutableState.value = mutableState.value.copy(busy = false, statusMessage = if (verified) "Wiqo Pro hesabına bağlandı." else null)
                if (verified) refreshSubscription()
            }
        }
    }

    private fun refreshSubscription() {
        val accountId = api.currentAccountId() ?: return
        scope.launch {
            runCatching { api.get("billing/subscription") as? JsonObject }
                .onSuccess { subscription ->
                    if (api.currentAccountId() != accountId) return@onSuccess
                    val tier = (subscription?.get("tier") as? JsonPrimitive)?.content
                        ?: (subscription?.get("subscriptionTier") as? JsonPrimitive)?.content
                        ?: mutableState.value.tier
                    val usage = subscription?.get("usage") as? JsonObject
                    val messages = usage?.get("messages") as? JsonObject
                    val images = usage?.get("images") as? JsonObject
                    mutableState.value = mutableState.value.copy(tier = tier,
                        messageUsed = messages?.scalar("used")?.toIntOrNull(),
                        messageLimit = messages?.scalar("limit")?.toIntOrNull(),
                        imageUsed = images?.scalar("used")?.toIntOrNull(),
                        imageLimit = images?.scalar("limit")?.toIntOrNull(),
                        pcAllowed = subscription?.scalar("pcAllowed") == "true")
                }
                .onFailure {
                    if (api.currentAccountId() == accountId) mutableState.value = mutableState.value.copy(
                        error = "Abonelik bilgisi şu anda alınamadı. Yeniden deneyebilirsin.")
                }
        }
    }

    companion object {
        const val PRODUCT_ID = "wiqo_pro_monthly"
    }
}

private fun JsonObject.scalar(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull

internal fun googlePlayAccountId(accountId: String): String = MessageDigest.getInstance("SHA-256")
    .digest("wiqo-account:$accountId".toByteArray(Charsets.UTF_8))
    .joinToString("") { byte -> "%02x".format(byte) }
