const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const extensionRoot = path.join(__dirname, "..");
const background = fs.readFileSync(path.join(extensionRoot, "bg.js"), "utf8");
const manifest = JSON.parse(fs.readFileSync(path.join(extensionRoot, "manifest.json"), "utf8"));
const swiftConstants = fs.readFileSync(
    path.join(extensionRoot, "..", "..", "Sources", "NDMCore", "Bridge", "BridgeProtocol.swift"),
    "utf8"
);

test("extension targets the NDM-specific bridge contract", () => {
    assert.match(background, /ws:\/\/127\.0\.0\.1:51873\/ndm\/download/);
    assert.match(background, /"ndm\.open\.v1"/);
    assert.doesNotMatch(background, /127\.0\.0\.1:10007|neatextension\.v1/);

    assert.match(swiftConstants, /port: UInt16 = 51_873/);
    assert.match(swiftConstants, /path = "\/ndm\/download"/);
    assert.match(swiftConstants, /subprotocol = "ndm\.open\.v1"/);
});

test("NDM Relay has its own name and Yuan Gao author identity", () => {
    assert.equal(Object.hasOwn(manifest, "key"), false);
    assert.equal(Object.hasOwn(manifest, "homepage_url"), false);
    // The name is localized; both locales must still resolve to NDM Relay.
    assert.equal(manifest.name, "__MSG_extName__");
    for (const locale of ["zh_CN", "en"]) {
        const messages = JSON.parse(
            fs.readFileSync(path.join(extensionRoot, "_locales", locale, "messages.json"), "utf8")
        );
        assert.equal(messages.extName.message, "NDM Relay");
    }
    assert.equal(manifest.author, "Yuan Gao");
    assert.doesNotMatch(background, /Download by NeatDownloadManager/);
    assert.doesNotMatch(
        fs.readFileSync(path.join(extensionRoot, "ct.js"), "utf8"),
        /NeatDownloadManager Application/
    );
});
