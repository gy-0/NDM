const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

function source(name) {
    return fs.readFileSync(path.join(__dirname, "..", name), "utf8");
}

test("resource shelf uses a solid restrained surface instead of decorative glass", () => {
    const shelf = source("resource-shelf.js");
    assert.doesNotMatch(shelf, /backdrop-filter|linear-gradient/i);
    assert.doesNotMatch(shelf, /border-radius:\s*999/i);
    assert.match(shelf, /badge-brand[^\n]+NDM|"badge-brand", "NDM"/);
    assert.match(shelf, /可下载资源/);
});

test("generic media control gets out of the way and remains toolbar-recoverable", () => {
    const content = source("ct.js");
    assert.doesNotMatch(content, /backdrop-filter/i);
    assert.match(content, /badgeLabel\.innerText = "NDM"/);
    assert.match(content, /style\.opacity = 0/);
    assert.match(content, /showAllPanels/);
    assert.match(content, /siteForURL\(window\.location\.href\)/);
    assert.match(content, /postMessage\(\[21,/);
    assert.doesNotMatch(content, /style\.opacity = 0\.82/);
    const background = source("bg.js");
    assert.match(background, /updateMediaBadge/);
    assert.match(background, /case 21:/);
});

test("site-native actions retain explicit accessible labels", () => {
    const adapters = source("site-adapters.js");
    assert.match(adapters, /button\.setAttribute\("aria-label", button\.title\)/);
    assert.match(adapters, /正在打开 NDM/);
});
