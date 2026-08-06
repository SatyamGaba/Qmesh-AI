package ai.qmesh.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.net.Uri;
import android.os.Bundle;
import android.util.Log;
import android.view.ViewGroup;
import android.webkit.ConsoleMessage;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.Collections;
import java.util.Locale;

/**
 * QMesh shell: a single full-screen WebView hosting the PWA.
 *
 * <p>The UI is the Next static export in {@code assets/www}, served by
 * {@link #serveFromAssets} on the <b>http</b> origin {@code http://appassets.androidplatform.net}.
 * http rather than https is deliberate: the three engines are plain-http
 * ({@code localhost:8082}, {@code localhost:8081}, the laptop on the hotspot), and an https
 * page calling them would be mixed content. Same scheme on both sides leaves only ordinary
 * CORS in play, which the engines already satisfy.
 *
 * <p>Trade-off of the http origin: it is not a secure context, so the Serwist service worker
 * will not register. Offline still holds — the bundle ships inside the APK.
 *
 * <p>Assets are served with an explicit MIME map rather than the platform's guess. Chrome
 * enforces {@code text/css} on stylesheets in standards mode and silently drops anything
 * else, which renders the app completely unstyled while the JS still runs.
 *
 * <p>This app does not start the engines. Android blocks apps from exec'ing binaries out of
 * /data/local/tmp, so llama-server is still adb-launched.
 */
public class MainActivity extends Activity {

    private static final String TAG = "QMesh";

    /** false → load the Next dev server instead (needs `adb reverse tcp:3000 tcp:3000`). */
    private static final boolean USE_BUNDLED_UI = true;

    private static final String ASSET_HOST = "appassets.androidplatform.net";
    private static final String ASSET_ROOT = "www";
    private static final String BUNDLED_URL = "http://" + ASSET_HOST + "/index.html";
    private static final String DEV_URL = "http://localhost:3000/";

    private WebView web;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);   // localStorage — the picker persists the mode here
        s.setDatabaseEnabled(true);     // IndexedDB — Dexie thread history
        s.setMediaPlaybackRequiresUserGesture(false);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view,
                                                              WebResourceRequest request) {
                Uri url = request.getUrl();
                if (ASSET_HOST.equals(url.getHost())) {
                    return serveFromAssets(url.getPath());
                }
                return null; // engine calls go to the network untouched
            }
        });

        // Surface page console output in logcat so verification does not need chrome://inspect.
        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage m) {
                Log.i(TAG, m.messageLevel() + " " + m.message()
                        + " @" + m.sourceId() + ":" + m.lineNumber());
                return true;
            }
        });

        WebView.setWebContentsDebuggingEnabled(true);

        setContentView(web, new ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT));

        if (savedInstanceState == null) {
            web.loadUrl(USE_BUNDLED_UI ? BUNDLED_URL : DEV_URL);
        } else {
            web.restoreState(savedInstanceState);
        }
    }

    /** Map a request path onto {@code assets/www/...}, with a correct Content-Type. */
    private WebResourceResponse serveFromAssets(String path) {
        String rel = path == null ? "" : path;
        if (rel.startsWith("/")) {
            rel = rel.substring(1);
        }
        if (rel.isEmpty() || rel.endsWith("/")) {
            rel = rel + "index.html";
        }
        String asset = ASSET_ROOT + "/" + rel;
        try {
            InputStream in = getAssets().open(asset);
            return new WebResourceResponse(mimeOf(asset), "utf-8", in);
        } catch (IOException e) {
            Log.w(TAG, "asset miss: " + asset);
            return new WebResourceResponse("text/plain", "utf-8", 404, "Not Found",
                    Collections.emptyMap(), new ByteArrayInputStream(new byte[0]));
        }
    }

    private static String mimeOf(String path) {
        int dot = path.lastIndexOf('.');
        String ext = dot < 0 ? "" : path.substring(dot + 1).toLowerCase(Locale.US);
        switch (ext) {
            case "html":
            case "htm":
                return "text/html";
            case "js":
            case "mjs":
                return "text/javascript";
            case "css":
                return "text/css";
            case "json":
                return "application/json";
            case "webmanifest":
                return "application/manifest+json";
            case "svg":
                return "image/svg+xml";
            case "png":
                return "image/png";
            case "jpg":
            case "jpeg":
                return "image/jpeg";
            case "webp":
                return "image/webp";
            case "ico":
                return "image/x-icon";
            case "woff2":
                return "font/woff2";
            case "woff":
                return "font/woff";
            case "ttf":
                return "font/ttf";
            case "txt":
                return "text/plain";
            default:
                return "application/octet-stream";
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        web.saveState(outState);
    }

    @Override
    public void onBackPressed() {
        if (web.canGoBack()) {
            web.goBack();
        } else {
            super.onBackPressed();
        }
    }
}
