package com.safri.timetracker;

import android.Manifest;
import android.app.Activity;
import android.content.ContentValues;
import android.content.Context;
import android.content.pm.PackageManager;
import android.media.MediaScannerConnection;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.provider.MediaStore;
import android.view.inputmethod.InputMethodManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;

import androidx.webkit.WebViewAssetLoader;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Thin native shell for the static PWA in assets/web/.
 *
 * The WebViewAssetLoader serves the bundled files from a secure https origin
 * (https://appassets.androidplatform.net/assets/web/). That origin is what
 * makes IndexedDB, the service worker and crypto.randomUUID available without
 * any network access or Google Play Services.
 */
public class MainActivity extends Activity {

    private static final String APP_URL =
            "https://appassets.androidplatform.net/assets/web/index.html";
    private static final int REQUEST_WRITE_STORAGE = 42;

    private WebView webView;
    private WebViewAssetLoader assetLoader;
    private String[] pendingCsv;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        assetLoader = new WebViewAssetLoader.Builder()
                .setDomain("appassets.androidplatform.net")
                .addPathHandler("/assets/", new WebViewAssetLoader.AssetsPathHandler(this))
                .build();

        webView = new WebView(this);
        setContentView(webView);

        WebSettings settings = webView.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setDatabaseEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setLoadWithOverviewMode(false);
        settings.setUseWideViewPort(true);
        settings.setCacheMode(WebSettings.LOAD_DEFAULT);

        webView.setFocusable(true);
        webView.setFocusableInTouchMode(true);

        webView.addJavascriptInterface(new NativeBridge(), "TimeTrackerNative");

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                return assetLoader.shouldInterceptRequest(request.getUrl());
            }
        });

        // The app saves CSV through the Javascript bridge below. This listener is
        // only a safety net in case a future version uses a normal download link.
        webView.setDownloadListener((url, userAgent, contentDisposition, mimeType, length) ->
                runOnUiThread(() -> Toast.makeText(this, "Export is handled inside the app",
                        Toast.LENGTH_SHORT).show()));

        if (savedInstanceState == null) {
            webView.loadUrl(APP_URL);
        } else {
            webView.restoreState(savedInstanceState);
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        webView.saveState(outState);
    }

    @Override
    public void onBackPressed() {
        // Close the text dialog first; otherwise leave the app.
        webView.evaluateJavascript(
                "(function(){var o=document.getElementById('keyboard-overlay');" +
                "if(o && !o.classList.contains('hidden')){" +
                "document.getElementById('kb-text').blur();" +
                "var c=document.querySelector('[data-action=cancel]');if(c)c.click();" +
                "return true;}return false;})()",
                value -> {
                    // evaluateJavascript JSON-encodes the result, so a boolean
                    // true may arrive as "true" (with quotes).
                    if (value == null || !value.contains("true")) finish();
                });
    }

    private void showKeyboard() {
        runOnUiThread(() -> {
            webView.requestFocus();
            InputMethodManager imm =
                    (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) {
                imm.showSoftInput(webView, InputMethodManager.SHOW_IMPLICIT);
            }
        });
    }

    private void hideKeyboard() {
        runOnUiThread(() -> {
            InputMethodManager imm =
                    (InputMethodManager) getSystemService(Context.INPUT_METHOD_SERVICE);
            if (imm != null) {
                imm.hideSoftInputFromWindow(webView.getWindowToken(), 0);
            }
            webView.clearFocus();
        });
    }

    private void saveCsv(String name, String text) {
        final String fileName = name.replaceAll("[^A-Za-z0-9._-]", "_");
        if (fileName.isEmpty()) {
            toast("Export failed: bad filename");
            return;
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            runOnUiThread(() -> {
                Uri uri = null;
                try {
                    ContentValues values = new ContentValues();
                    values.put(MediaStore.Downloads.DISPLAY_NAME, fileName);
                    values.put(MediaStore.Downloads.MIME_TYPE, "text/csv");
                    values.put(MediaStore.Downloads.IS_PENDING, 1);
                    uri = getContentResolver()
                            .insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
                    if (uri == null) throw new IOException("could not create Downloads entry");
                    try (OutputStream os = getContentResolver().openOutputStream(uri)) {
                        os.write(text.getBytes(StandardCharsets.UTF_8));
                    }
                    values.clear();
                    values.put(MediaStore.Downloads.IS_PENDING, 0);
                    getContentResolver().update(uri, values, null, null);
                    toast("Saved " + fileName + " to Downloads");
                } catch (Exception e) {
                    if (uri != null) getContentResolver().delete(uri, null, null);
                    toast("Export failed: " + e.getMessage());
                }
            });
            return;
        }

        if (checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                != PackageManager.PERMISSION_GRANTED) {
            pendingCsv = new String[]{fileName, text};
            requestPermissions(new String[]{Manifest.permission.WRITE_EXTERNAL_STORAGE},
                    REQUEST_WRITE_STORAGE);
            return;
        }
        writeLegacyCsv(fileName, text);
    }

    private void writeLegacyCsv(String fileName, String text) {
        runOnUiThread(() -> {
            try {
                File dir = Environment.getExternalStoragePublicDirectory(
                        Environment.DIRECTORY_DOWNLOADS);
                //noinspection ResultOfMethodCallIgnored
                dir.mkdirs();
                File file = new File(dir, fileName);
                try (FileOutputStream out = new FileOutputStream(file)) {
                    out.write(text.getBytes(StandardCharsets.UTF_8));
                }
                MediaScannerConnection.scanFile(this,
                        new String[]{file.getAbsolutePath()},
                        new String[]{"text/csv"}, null);
                toast("Saved " + fileName + " to Downloads");
            } catch (Exception e) {
                toast("Export failed: " + e.getMessage());
            }
        });
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(requestCode, permissions, results);
        if (requestCode == REQUEST_WRITE_STORAGE && pendingCsv != null) {
            String[] job = pendingCsv;
            pendingCsv = null;
            if (results.length > 0 && results[0] == PackageManager.PERMISSION_GRANTED) {
                writeLegacyCsv(job[0], job[1]);
            } else {
                toast("Storage permission denied");
            }
        }
    }

    private void toast(String message) {
        runOnUiThread(() -> Toast.makeText(this, message, Toast.LENGTH_LONG).show());
    }

    /** Called from web/app.js. All methods run on the UI thread when touching views. */
    public class NativeBridge {
        @JavascriptInterface
        public void showKeyboard() {
            MainActivity.this.showKeyboard();
        }

        @JavascriptInterface
        public void hideKeyboard() {
            MainActivity.this.hideKeyboard();
        }

        @JavascriptInterface
        public void saveCsv(String name, String text) {
            MainActivity.this.saveCsv(name, text);
        }
    }
}
