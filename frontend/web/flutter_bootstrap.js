// Custom Flutter web bootstrap (Flutter replaces the {{...}} placeholders at
// build time; see flutter_tools/lib/src/web/bootstrap.dart).
//
// Why this file exists: the default bootstrap loads CanvasKit from
// www.gstatic.com and lets the engine fetch Roboto / CJK fallback fonts from
// fonts.gstatic.com. Both hosts are unreachable from mainland China, which
// leaves the editor stuck on the loading screen (and, for the fallback-font
// path, in an endless retry loop). We serve both from the same origin instead.
//
// - canvasKitBaseUrl: "canvaskit/" -> use the local build output (also set by
//   `flutter build web --no-web-resources-cdn`).
// - fontFallbackBaseUrl: "fallback_fonts/" -> tools/fetch_web_fallback_fonts.py
//   mirrors the Noto/Roboto slices into the release build. For plain
//   `flutter build web` (no mirror) the probe below falls back to the Google
//   host so local development keeps working.
//
// 启动失败（脚本 404 / 引擎初始化异常 / CanvasKit 下载被拦）一律交给
// index.html 的 window.__editorBootFail：加载屏会切成「加载失败 + 重新加载」，
// 而不是永远停在「正在加载…」。
{{flutter_js}}
{{flutter_build_config}}

(function () {
  function fail(reason) {
    if (window.__editorBootFail) window.__editorBootFail(reason);
    else console.error('[boot] ' + reason);
  }

  // Probe in parallel with the 5 MB main bundle; by the time the engine
  // initializer is ready this promise has long settled, so it costs no extra
  // round trip on the critical path. (GET, not HEAD: the static route only
  // implements GET. A 304 still proves the mirror exists; only a 404 or a
  // transport error means "no mirror, fall back to Google".)
  var localFallbackFonts =
    fetch("fallback_fonts/manifest.json", { cache: "no-cache" })
      .then(function (res) { return res.status !== 404; })
      .catch(function () { return false; });

  var serviceWorkerVersion = {{flutter_service_worker_version}};
  var loadOptions = {
    config: {
      canvasKitBaseUrl: "canvaskit/",
    },
    onEntrypointLoaded: async function (engineInitializer) {
      var useLocalFonts = await localFallbackFonts;
      var appRunner = await engineInitializer.initializeEngine({
        fontFallbackBaseUrl: useLocalFonts
          ? "fallback_fonts/"
          : "https://fonts.gstatic.com/s/",
      });
      await appRunner.runApp();
    },
  };
  // Debug/`--pwa-strategy=none` builds substitute null: don't register a
  // service worker that was never emitted.
  if (serviceWorkerVersion) {
    loadOptions.serviceWorkerSettings = {
      serviceWorkerVersion: serviceWorkerVersion,
    };
  }
  try {
    _flutter.loader.load(loadOptions).catch(function (e) {
      fail("编辑器启动失败（" + (e && e.message ? e.message : e) + "）");
    });
  } catch (e) {
    fail("编辑器启动失败（" + (e && e.message ? e.message : e) + "）");
  }
})();
