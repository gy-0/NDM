const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function element(attributes = {}) {
    const listeners = {};
    const values = new Map(Object.entries(attributes));
    return {
        dataset: {},
        hidden: false,
        disabled: false,
        textContent: "",
        setAttribute(name, value) { values.set(name, String(value)); },
        getAttribute(name) { return values.has(name) ? values.get(name) : null; },
        removeAttribute(name) {
            values.delete(name);
            if (name === "data-state") delete this.dataset.state;
        },
        addEventListener(name, listener) { listeners[name] = listener; },
        click() { listeners.click.call(this); }
    };
}

function loadPopupWithFailedToggle() {
    const nodes = {
        status: element(),
        "status-text": element(),
        "open-app": element(),
        "offline-hint": element(),
        catcher: element({ "aria-checked": "true" }),
        "catcher-sub": element(),
        "show-panel": element(),
        "media-card": element(),
        "media-count-line": element(),
        "foot-note": element()
    };
    const messages = {
        popupCatcherSub: "Ordinary downloads hand off to NDM",
        popupSettingFailed: "Couldn't save the setting. Try again."
    };
    const chrome = {
        i18n: { getMessage(key) { return messages[key] || ""; } },
        runtime: {
            lastError: null,
            getManifest() { return { version: "1.4.0" }; },
            sendMessage(request, callback) {
                if (request.type === "relay:getState") {
                    callback({ catcherEnabled: true, mediaCount: 0, connected: false });
                    return;
                }
                if (request.type === "relay:toggleCatcher") {
                    this.lastError = { message: "storage unavailable" };
                    callback();
                    this.lastError = null;
                }
            }
        },
        tabs: {
            query(_query, callback) { callback([{ id: 7 }]); },
            remove() {},
            create() {}
        }
    };
    class MockWebSocket {}
    const context = {
        chrome,
        document: {
            querySelectorAll() { return []; },
            getElementById(id) { return nodes[id]; }
        },
        window: { close() {} },
        WebSocket: MockWebSocket,
        setTimeout() {}
    };
    vm.runInNewContext(
        fs.readFileSync(path.join(__dirname, "..", "popup.js"), "utf8"),
        context,
        { filename: "popup.js" }
    );
    return nodes;
}

test("popup restores the catcher switch and explains a failed settings write", () => {
    const nodes = loadPopupWithFailedToggle();

    nodes.catcher.click();

    assert.equal(nodes.catcher.disabled, false);
    assert.equal(nodes.catcher.getAttribute("aria-busy"), "false");
    assert.equal(nodes.catcher.getAttribute("aria-checked"), "true");
    assert.equal(nodes["catcher-sub"].dataset.state, "error");
    assert.equal(nodes["catcher-sub"].textContent, "Couldn't save the setting. Try again.");
});
