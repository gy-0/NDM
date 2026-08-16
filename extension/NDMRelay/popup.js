// NDM Relay popup: connection status, per-tab media count, catcher toggle.
// The bridge probe runs here (not in the service worker) so the answer is
// always fresh even when the worker was suspended.
(function () {
    "use strict";

    var BRIDGE_URL = "ws://127.0.0.1:51873/ndm/download";
    var BRIDGE_PROTOCOL = "ndm.open.v1";

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
        status.dataset.state = state;
        text.textContent = chrome.i18n.getMessage(
            state === "connected" ? "popupConnected" : "popupOffline"
        ) || (state === "connected" ? "已连接 NDM" : "未连接");
        document.getElementById("offline-hint").hidden = state !== "offline";
    }

    function probeBridge() {
        var settled = false;
        var socket;
        function settle(state) {
            if (settled) return;
            settled = true;
            setStatus(state);
            try {
                if (socket && (socket.readyState === 0 || socket.readyState === 1)) socket.close();
            } catch (error) { /* the probe socket is disposable */ }
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

    function activeTab(callback) {
        chrome.tabs.query({ active: true, currentWindow: true }, function (tabs) {
            callback(tabs && tabs.length ? tabs[0] : null);
        });
    }

    function refreshState(tab) {
        chrome.runtime.sendMessage(
            { type: "relay:getState", tabId: tab ? tab.id : -1 },
            function (reply) {
                if (chrome.runtime.lastError || !reply) return;
                var catcher = document.getElementById("catcher");
                catcher.setAttribute("aria-checked", reply.catcherEnabled ? "true" : "false");
                var count = Number(reply.mediaCount || 0);
                var card = document.getElementById("media-card");
                if (count > 0) {
                    card.hidden = false;
                    document.getElementById("media-count-line").textContent =
                        (chrome.i18n.getMessage("popupMediaCount", [String(count)]) || count + " 项可下载");
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

    localize();
    probeBridge();
    activeTab(refreshState);
})();
