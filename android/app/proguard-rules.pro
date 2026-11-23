# The WebView JavascriptInterface methods are called by name from app.js.
-keepclassmembers class com.safri.timetracker.MainActivity$NativeBridge {
    @android.webkit.JavascriptInterface <methods>;
}
-keepattributes JavascriptInterface
