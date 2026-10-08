package com.wiqo.android.data.act

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.webkit.ConsoleMessage
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.ByteArrayInputStream
import kotlin.coroutines.resume

/** Runs a generated page in a network-blocked WebView before accepting it. */
class ActWebVerifier(private val context: Context) {
    data class Result(val passed: Boolean, val available: Boolean, val errors: List<String>)

    suspend fun verify(html: String): Result = withContext(Dispatchers.Main) {
        withTimeoutOrNull(12_000) {
            suspendCancellableCoroutine { continuation ->
                val errors = mutableListOf<String>()
                val view = try { WebView(context.applicationContext) } catch (_: Exception) {
                    continuation.resume(Result(passed = false, available = false, errors = emptyList()))
                    return@suspendCancellableCoroutine
                }
                var finished = false
                fun finish(result: Result) {
                    if (finished) return
                    finished = true
                    view.stopLoading()
                    view.destroy()
                    if (continuation.isActive) continuation.resume(result)
                }
                continuation.invokeOnCancellation { Handler(Looper.getMainLooper()).post { if (!finished) { finished = true; view.stopLoading(); view.destroy() } } }
                view.settings.javaScriptEnabled = true
                view.settings.domStorageEnabled = true
                view.settings.allowFileAccess = false
                view.settings.allowContentAccess = false
                view.settings.javaScriptCanOpenWindowsAutomatically = false
                view.webChromeClient = object : WebChromeClient() {
                    override fun onConsoleMessage(message: ConsoleMessage?): Boolean {
                        if (message?.messageLevel() == ConsoleMessage.MessageLevel.ERROR && errors.size < 20)
                            errors.add(message.message().take(1000))
                        return true
                    }
                }
                view.webViewClient = object : WebViewClient() {
                    override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = true
                    override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? =
                        WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
                    override fun onPageFinished(view: WebView?, url: String?) {
                        Handler(Looper.getMainLooper()).postDelayed({
                            if (finished) return@postDelayed
                            view?.evaluateJavascript("Boolean(document.body && (document.body.children.length || document.body.textContent.trim().length))") { value ->
                                finish(Result(passed = value == "true" && errors.isEmpty(), available = true, errors = errors.toList()))
                            } ?: finish(Result(passed = false, available = false, errors = errors.toList()))
                        }, 600)
                    }
                    override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: android.webkit.WebResourceError?) {
                        if (request?.isForMainFrame == true && errors.size < 20) errors.add("Sayfa yüklenemedi.")
                    }
                }
                view.layout(0, 0, 390, 844)
                view.loadDataWithBaseURL("https://act.wiqo.local/", html, "text/html", "UTF-8", null)
            }
        } ?: Result(passed = false, available = false, errors = emptyList())
    }
}
