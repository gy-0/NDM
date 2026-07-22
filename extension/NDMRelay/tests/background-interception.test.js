const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const policy = require("../media-policy.js");
const resourcePolicy = require("../resource-policy.js");

function loadBackground() {
    const listeners = {};
    const cookieRequests = [];
    const cancelledDownloads = [];
    const erasedDownloads = [];
    const event = name => ({
        addListener(listener) {
            listeners[name] = listener;
        }
    });

    const chrome = {
        action: {
            onClicked: event("actionClicked"),
            setBadgeBackgroundColor() {},
            setBadgeText() {},
            setTitle() {}
        },
        contextMenus: {
            onClicked: event("contextMenuClicked"),
            removeAll(callback) { callback(); },
            create() {},
            update(_id, _properties, callback) { if (callback) callback(); }
        },
        cookies: {
            getAll(details, callback) {
                cookieRequests.push(details.url);
                callback([]);
            }
        },
        downloads: {
            onCreated: event("downloadCreated"),
            cancel(id, callback) {
                cancelledDownloads.push(id);
                if (callback) callback();
            },
            erase(query, callback) {
                erasedDownloads.push(query.id);
                if (callback) callback();
            }
        },
        runtime: {
            lastError: null,
            onConnect: event("runtimeConnect")
        },
        storage: {
            local: {
                get(_keys, callback) { callback({}); },
                set() {}
            }
        },
        tabs: {
            query(_query, callback) { callback([]); },
            remove() {}
        },
        webNavigation: {
            onHistoryStateUpdated: event("historyStateUpdated")
        },
        webRequest: {
            onBeforeRequest: event("beforeRequest"),
            onBeforeSendHeaders: event("beforeSendHeaders"),
            onCompleted: event("requestCompleted"),
            onErrorOccurred: event("requestError"),
            onHeadersReceived: event("headersReceived")
        }
    };

    class MockWebSocket {
        send() {}
    }

    const context = {
        NDMRelayMediaPolicy: policy,
        NDMRelayResourcePolicy: resourcePolicy,
        Headers,
        URL,
        WebSocket: MockWebSocket,
        chrome,
        fetch: async () => ({ ok: false }),
        importScripts() {},
        setTimeout,
        unescape
    };
    context.globalThis = context;
    vm.runInNewContext(
        fs.readFileSync(path.join(__dirname, "..", "bg.js"), "utf8"),
        context,
        { filename: "bg.js" }
    );
    return { listeners, cookieRequests, cancelledDownloads, erasedDownloads };
}

function responseHeaders(contentType, disposition) {
    const headers = [
        { name: "Content-Type", value: contentType },
        { name: "Content-Length", value: "4096" }
    ];
    if (disposition) headers.push({ name: "Content-Disposition", value: disposition });
    return headers;
}

function simulateResponse(runtime, options) {
    runtime.listeners.beforeRequest({
        requestId: options.id,
        url: options.url,
        tabId: 10,
        frameId: options.type === "main_frame" ? 0 : 2,
        type: options.type,
        method: "GET"
    });
    runtime.listeners.headersReceived({
        requestId: options.id,
        url: options.url,
        tabId: 10,
        frameId: options.type === "main_frame" ? 0 : 2,
        type: options.type,
        method: "GET",
        statusLine: "HTTP/1.1 200 OK",
        responseHeaders: responseHeaders(options.contentType, options.disposition)
    });
}

test("background ignores DAT and BIN page subresources", () => {
    const runtime = loadBackground();
    simulateResponse(runtime, {
        id: "dat-resource",
        url: "https://example.com/telemetry/cache.dat",
        type: "other",
        contentType: "application/octet-stream"
    });
    simulateResponse(runtime, {
        id: "bin-resource",
        url: "https://example.com/assets/model.bin",
        type: "xmlhttprequest",
        contentType: "application/octet-stream",
        disposition: "attachment; filename=model.bin"
    });
    assert.deepEqual(runtime.cookieRequests, []);
});

test("background reports a useful embedded PDF without auto-downloading it", () => {
    const runtime = loadBackground();
    const messages = [];
    runtime.listeners.runtimeConnect({
        sender: {
            tab: { id: 10, title: "Research", url: "https://example.com/viewer" },
            frameId: 0,
            url: "https://example.com/viewer"
        },
        onMessage: { addListener() {} },
        onDisconnect: { addListener() {} },
        postMessage(message) { messages.push(message); }
    });
    simulateResponse(runtime, {
        id: "pdf-resource",
        url: "https://cdn.example.com/files/paper.pdf?range=0-4095",
        type: "xmlhttprequest",
        contentType: "application/pdf"
    });

    const resourceMessage = messages.find(message => message[0] === 19);
    assert.ok(resourceMessage);
    assert.equal(resourceMessage[1].fEx, "pdf");
    assert.equal(resourceMessage[1][6], "normal");
    assert.deepEqual(runtime.cookieRequests, []);
});

test("an iframe PDF is reported to the top-page resource shelf", () => {
    const runtime = loadBackground();
    const topMessages = [];
    const frameMessages = [];
    const connect = (frameId, messages) => runtime.listeners.runtimeConnect({
        sender: {
            tab: { id: 10, title: "Reader", url: "https://example.com/reader" },
            frameId,
            url: frameId ? "https://viewer.example.com/embed" : "https://example.com/reader"
        },
        onMessage: { addListener() {} },
        onDisconnect: { addListener() {} },
        postMessage(message) { messages.push(message); }
    });
    connect(0, topMessages);
    connect(2, frameMessages);
    simulateResponse(runtime, {
        id: "iframe-pdf-resource",
        url: "https://viewer.example.com/original.pdf",
        type: "xmlhttprequest",
        contentType: "application/pdf"
    });

    assert.equal(topMessages.some(message => message[0] === 19), true);
    assert.equal(frameMessages.some(message => message[0] === 19), false);
});

test("background does not expose JavaScript or unknown DAT traffic as resources", () => {
    const runtime = loadBackground();
    const messages = [];
    runtime.listeners.runtimeConnect({
        sender: {
            tab: { id: 10, title: "App", url: "https://example.com" },
            frameId: 0,
            url: "https://example.com"
        },
        onMessage: { addListener() {} },
        onDisconnect: { addListener() {} },
        postMessage(message) { messages.push(message); }
    });
    simulateResponse(runtime, {
        id: "javascript-resource",
        url: "https://example.com/app.js",
        type: "xmlhttprequest",
        contentType: "text/javascript"
    });
    simulateResponse(runtime, {
        id: "dat-resource-panel",
        url: "https://example.com/cache.dat",
        type: "other",
        contentType: "application/octet-stream"
    });
    assert.equal(messages.some(message => message[0] === 19), false);
});

test("background cancels a suspicious hidden DAT download created by Chrome", () => {
    const runtime = loadBackground();
    const url = "https://example.com/telemetry/cache.dat";
    simulateResponse(runtime, {
        id: "dat-resource",
        url,
        type: "other",
        contentType: "application/octet-stream"
    });
    runtime.listeners.downloadCreated({ id: 41, url });

    assert.deepEqual(runtime.cancelledDownloads, [41]);
    assert.deepEqual(runtime.erasedDownloads, [41]);
    assert.deepEqual(runtime.cookieRequests, []);
});

test("background never cancels an explicitly opened top-level DAT download", () => {
    const runtime = loadBackground();
    const url = "https://example.com/manual.dat";
    simulateResponse(runtime, {
        id: "top-level-dat",
        url,
        type: "main_frame",
        contentType: "application/octet-stream",
        disposition: "attachment; filename=manual.dat"
    });
    runtime.listeners.downloadCreated({ id: 42, url });

    assert.deepEqual(runtime.cancelledDownloads, []);
    assert.deepEqual(runtime.erasedDownloads, []);
});

test("background ignores attachment downloads started by hidden frames", () => {
    const runtime = loadBackground();
    simulateResponse(runtime, {
        id: "hidden-frame",
        url: "https://example.com/automatic.zip",
        type: "sub_frame",
        contentType: "application/zip",
        disposition: "attachment; filename=automatic.zip"
    });
    assert.deepEqual(runtime.cookieRequests, []);
});

test("background still hands an intentional top-level attachment to NDM", () => {
    const runtime = loadBackground();
    simulateResponse(runtime, {
        id: "user-download",
        url: "https://example.com/manual.zip",
        type: "main_frame",
        contentType: "application/zip",
        disposition: "attachment; filename=manual.zip"
    });
    assert.deepEqual(runtime.cookieRequests, ["https://example.com/manual.zip"]);
});

test("concurrent top-level handoffs survive unrelated Chrome downloads", () => {
    const runtime = loadBackground();
    const first = "https://example.com/first.zip";
    const second = "https://example.com/second.dmg";
    simulateResponse(runtime, {
        id: "first-download",
        url: first,
        type: "main_frame",
        contentType: "application/zip",
        disposition: "attachment; filename=first.zip"
    });
    simulateResponse(runtime, {
        id: "second-download",
        url: second,
        type: "main_frame",
        contentType: "application/octet-stream",
        disposition: "attachment; filename=second.dmg"
    });

    runtime.listeners.downloadCreated({ id: 50, url: "https://example.com/unrelated.pdf" });
    runtime.listeners.downloadCreated({ id: 51, url: first });
    runtime.listeners.downloadCreated({ id: 52, finalUrl: second, url: second + "?redirected=1" });

    assert.deepEqual(runtime.cancelledDownloads, [51, 52]);
    assert.deepEqual(runtime.erasedDownloads, [51, 52]);
    assert.deepEqual(runtime.cookieRequests, [first, second]);
});

test("a user can still explicitly send a DAT link from the context menu", () => {
    const runtime = loadBackground();
    runtime.listeners.contextMenuClicked({
        menuItemId: "NDM_CtxMenu",
        linkUrl: "https://example.com/manual.dat",
        pageUrl: "https://example.com/downloads"
    }, {
        id: 10,
        title: "Downloads",
        url: "https://example.com/downloads"
    });
    assert.deepEqual(runtime.cookieRequests, ["https://example.com/manual.dat"]);
});

test("toolbar action restores the current tab's nearest media panel", () => {
    const runtime = loadBackground();
    const messages = [];
    const port = {
        sender: {
            tab: { id: 10, title: "Video", url: "https://x.com/example/status/123" },
            frameId: 0,
            url: "https://x.com/example/status/123"
        },
        onMessage: { addListener() {} },
        onDisconnect: { addListener() {} },
        postMessage(message) { messages.push(message); }
    };

    runtime.listeners.runtimeConnect(port);
    runtime.listeners.actionClicked({ id: 10 });

    assert.deepEqual(Array.from(messages[messages.length - 1]), [17]);
});
