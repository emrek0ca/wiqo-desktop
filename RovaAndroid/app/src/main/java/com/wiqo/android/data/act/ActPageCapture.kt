package com.wiqo.android.data.act

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.pdf.PdfDocument
import android.view.View
import android.view.ViewGroup
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import kotlin.coroutines.resume

/** Captures the full locally rendered page without loading network resources. */
object ActPageCapture {
    enum class Output { PNG, PDF }
    suspend fun capture(activity: Activity, html: String, width: Int = 390, output: Output): ByteArray = withContext(Dispatchers.Main) {
        require(width in 320..1600)
        val root = activity.window.decorView as? ViewGroup ?: throw IllegalStateException("Sayfa yakalama penceresi yok.")
        val view = WebView(activity)
        view.settings.javaScriptEnabled = true
        view.settings.domStorageEnabled = false // Capture must not mutate the preview's saved data.
        view.settings.allowFileAccess = false
        view.settings.allowContentAccess = false
        view.settings.javaScriptCanOpenWindowsAutomatically = false
        view.setLayerType(View.LAYER_TYPE_SOFTWARE, null)
        view.translationX = -10_000f
        root.addView(view, ViewGroup.LayoutParams(width, 844))
        view.layout(0, 0, width, 844)
        try {
            withTimeout(15_000) {
                suspendCancellableCoroutine<Unit> { continuation ->
                    view.webViewClient = object : WebViewClient() {
                        override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = true
                        override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? =
                            WebResourceResponse("text/plain", "UTF-8", ByteArrayInputStream(ByteArray(0)))
                        override fun onPageFinished(view: WebView?, url: String?) {
                            if (continuation.isActive) continuation.resume(Unit)
                        }
                    }
                    view.loadDataWithBaseURL("https://act.wiqo.local/", html, "text/html", "UTF-8", null)
                }
            }
            delay(1400)
            val measured = withTimeout(3000) { suspendCancellableCoroutine<Int> { continuation ->
                view.evaluateJavascript("Math.ceil(Math.max(document.documentElement.scrollHeight,document.body?document.body.scrollHeight:0))") { value ->
                    if (continuation.isActive) continuation.resume(value.toDoubleOrNull()?.toInt() ?: 844)
                }
            } }
            val height = measured.coerceIn(844, 8000)
            view.layoutParams = view.layoutParams.apply { this.width = width; this.height = height }
            view.measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(height, View.MeasureSpec.EXACTLY))
            view.layout(0, 0, width, height)
            delay(450)
            val stream = ByteArrayOutputStream()
            when (output) {
                Output.PNG -> {
                    val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                    try { view.draw(Canvas(bitmap)); check(bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)) }
                    finally { bitmap.recycle() }
                }
                Output.PDF -> {
                    val document = PdfDocument()
                    try {
                        val page = document.startPage(PdfDocument.PageInfo.Builder(width, height, 1).create())
                        view.draw(page.canvas)
                        document.finishPage(page)
                        document.writeTo(stream)
                    } finally { document.close() }
                }
            }
            stream.toByteArray().also { require(it.size > 100) { "Sayfa dışa aktarılamadı." } }
        } finally {
            view.stopLoading()
            root.removeView(view)
            view.destroy()
        }
    }
}
