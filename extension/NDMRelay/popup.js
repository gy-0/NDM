// NDM Relay popup: connection status, per-tab media count, catcher toggle.
// The bridge probe runs here (not in the service worker) so the answer is
// always fresh even when the worker was suspended.
(function () {
    "use strict";

    var BRIDGE_URL = "ws://127.0.0.1:51873/ndm/download";
    var BRIDGE_PROTOCOL = "ndm.open.v1";
    var APP_URL = "ndm://open/relay";
    // The live probe outranks the worker's cached flag, which can describe a
    // socket that died while the worker was suspended.
    var probeSettled = false;

    function message(key, substitutions, fallback) {
        var text = "";
        try {
            text = chrome.i18n.getMessage(key, substitutions) || "";
        } catch (error) { /* an untranslated key is not worth failing over */ }
        return text || fallback || "";
    }

    function localize() {
        var nodes = document.querySelectorAll("[data-i18n]");
        for (var i = 0; i < nodes.length; i++) {
            var key = nodes[i].getAttribute("data-i18n");
            var text = chrome.i18n.getMessage(key);
            if (text) nodes[i].textContent = text;
        }
    }

    function setStatus(state) {
        var status = document.getElementById("status");
        var text = document.getElementById("status-text");
        var openApp = document.getElementById("open-app");
        // "checking" is the honest answer until either the cached background
        // flag or our own probe lands; never paint a false offline.
        status.dataset.state = state;
        text.textContent = state === "connected"
            ? message("popupConnected", null, "已连接 NDM")
            : state === "starting"
                ? message("popupOpening", null, "正在打开…")
            : state === "offline"
                ? message("popupOffline", null, "未连接")
                : message("popupChecking", null, "正在检查…");
        document.getElementById("offline-hint").hidden = state !== "offline";
        openApp.textContent = state === "connected"
            ? message("popupShowApp", null, "显示 NDM")
            : message("popupOpenApp", null, "打开 NDM");
        openApp.disabled = state === "starting";
    }

    function probeBridge(retries) {
        retries = Number(retries || 0);
        var settled = false;
        var socket;
        function settle(state) {
            if (settled) return;
            settled = true;
            try {
                if (socket && (socket.readyState === 0 || socket.readyState === 1)) socket.close();
            } catch (error) { /* the probe socket is disposable */ }
            if (state === "offline" && retries > 0) {
                setTimeout(function () { probeBridge(retries - 1); }, 550);
                return;
            }
            probeSettled = true;
            setStatus(state);
        }
        try {
            socket = new WebSocket(BRIDGE_URL, BRIDGE_PROTOCOL);
        } catch (error) {
            settle("offline");
            return;
        }
        socket.onopen = function () { settle("connected"); };
        socket.onerror = function () { settle("offline"); };
        setTimeout(function () { settle("offline"); }, 1500);
    }

    function launchApp() {
        setStatus("starting");
        try {
            chrome.tabs.create({ url: APP_URL }, function () {
                if (chrome.runtime.lastError) {
                    setStatus("offline");
                    return;
                }
                probeSettled = false;
                probeBridge(10);
            });
        } catch (error) {
            setStatus("offline");
        }
    }

    function activeTab(callback) {
        chrome.tabs.query({ active: true, currentWindow: true }, function (tabs) {
            callback(tabs && tabs.length ? tabs[0] : null);
        });
    }

    function describeMedia(count, sample) {
        var title = sample && sample.title ? String(sample.title).trim() : "";
        var host = sample && sample.host ? String(sample.host).replace(/^www\./, "") : "";
        if (title) {
            // The count is already on the badge; here the page's own name is
            // the more useful thing to say.
            return host
                ? message("popupMediaSampleHost", [title, host], title + " · " + host)
                : message("popupMediaSample", [title], title);
        }
        return message("popupMediaCount", [String(count)], count + " 项可下载");
    }

    function refreshState(tab) {
        chrome.runtime.sendMessage(
            { type: "relay:getState", tabId: tab ? tab.id : -1 },
            function (reply) {
                if (chrome.runtime.lastError || !reply) return;
                var catcher = document.getElementById("catcher");
                catcher.setAttribute("aria-checked", reply.catcherEnabled ? "true" : "false");
                // Seed from the worker's cached socket state so a known-live
                // bridge reads "connected" immediately; probeBridge still has
                // the final word a moment later.
                if (reply.connected && !probeSettled) setStatus("connected");
                var count = Number(reply.mediaCount || 0);
                if (count > 0) {
                    document.getElementById("media-card").hidden = false;
                    document.getElementById("media-count-line").textContent =
                        describeMedia(count, reply.mediaSample);
                }
            }
        );
    }

    document.getElementById("catcher").addEventListener("click", function () {
        var next = this.getAttribute("aria-checked") !== "true";
        this.setAttribute("aria-checked", next ? "true" : "false");
        chrome.runtime.sendMessage({ type: "relay:toggleCatcher", enabled: next });
    });

    document.getElementById("show-panel").addEventListener("click", function () {
        activeTab(function (tab) {
            if (tab && tab.id >= 0) {
                chrome.runtime.sendMessage({ type: "relay:showMediaPanel", tabId: tab.id });
            }
            window.close();
        });
    });

    document.getElementById("open-app").addEventListener("click", function () {
        // The worker re-dials the bridge and asks NDM to come forward. Its
        // reply is only the cached flag, and a reconnect it just started is
        // still pending, so re-probe rather than trust a falsy answer — that
        // race is exactly how a running NDM would get reported offline.
        setStatus("checking");
        chrome.runtime.sendMessage({ type: "relay:openApp" }, function (reply) {
            if (chrome.runtime.lastError) {
                launchApp();
                return;
            }
            if (reply && reply.connected) {
                setStatus("connected");
                return;
            }
            launchApp();
        });
    });

    function renderVersion() {
        // popupVersion takes a substitution, so localize() cannot fill it in;
        // read the real number from the manifest instead of hardcoding it twice
        // in the locale files where it would silently drift on every bump.
        var version = "";
        try {
            version = (chrome.runtime.getManifest() || {}).version || "";
        } catch (error) { /* fall back to the bare wordmark */ }
        document.getElementById("foot-note").textContent = version
            ? message("popupVersion", [version], "NDM Relay · v" + version)
            : "NDM Relay";
    }

    localize();
    renderVersion();
    setStatus("checking");
    probeBridge();
    activeTab(refreshState);
})();
