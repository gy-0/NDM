const test = require("node:test");
const assert = require("node:assert/strict");
const adapters = require("../site-adapters.js");

test("recognizes supported high-frequency video hosts", () => {
    assert.equal(adapters.siteForURL("https://x.com/home"), "x");
    assert.equal(adapters.siteForURL("https://mobile.twitter.com/user/status/1"), "x");
    assert.equal(adapters.siteForURL("https://www.youtube.com/watch?v=abc"), "youtube");
    assert.equal(adapters.siteForURL("https://www.bilibili.com/video/BV1abc"), "bilibili");
    assert.equal(adapters.siteForURL("https://vimeo.com/123"), "vimeo");
    assert.equal(adapters.siteForURL("https://www.instagram.com/reel/abc/"), "instagram");
    assert.equal(adapters.siteForURL("https://www.tiktok.com/@user/video/123"), "tiktok");
    assert.equal(adapters.siteForURL("https://www.douyin.com/video/123"), "douyin");
    assert.equal(adapters.siteForURL("https://example.com/video"), "");
});

test("canonicalizes Bilibili, Vimeo, Instagram, TikTok, and Douyin page links", () => {
    assert.equal(
        adapters.canonicalBilibiliURL("https://www.bilibili.com/video/BV1GJ411x7h7/?spm_id_from=333"),
        "https://www.bilibili.com/video/BV1GJ411x7h7"
    );
    assert.equal(
        adapters.canonicalVimeoURL("https://player.vimeo.com/video/76979871?autoplay=1"),
        "https://vimeo.com/76979871"
    );
    assert.equal(
        adapters.canonicalInstagramURL("https://www.instagram.com/reel/C9Example/?utm_source=ig_web_copy_link"),
        "https://www.instagram.com/reel/C9Example/"
    );
    assert.equal(
        adapters.canonicalTikTokURL("https://www.tiktok.com/@scout2015/video/6718335390845095173?lang=en"),
        "https://www.tiktok.com/@scout2015/video/6718335390845095173"
    );
    assert.equal(
        adapters.canonicalDouyinURL("https://www.douyin.com/video/7351234567890123456?modeFrom=userPost"),
        "https://www.douyin.com/video/7351234567890123456"
    );
});

test("extracts a canonical X status URL instead of an analytics or media URL", () => {
    assert.equal(
        adapters.canonicalPageURL("https://x.com/home", [
            "https://x.com/example/status/123/analytics",
            "https://video.twimg.com/media/file.mp4"
        ]),
        "https://x.com/example/status/123"
    );
});

test("canonicalizes YouTube watch, short, live, and youtu.be links", () => {
    assert.equal(
        adapters.canonicalYouTubeURL("https://www.youtube.com/watch?v=abc123&list=PL1&t=20"),
        "https://www.youtube.com/watch?v=abc123"
    );
    assert.equal(
        adapters.canonicalYouTubeURL("https://www.youtube.com/shorts/short123?feature=share"),
        "https://www.youtube.com/shorts/short123"
    );
    assert.equal(
        adapters.canonicalYouTubeURL("https://www.youtube.com/live/live123?si=token"),
        "https://www.youtube.com/live/live123"
    );
    assert.equal(
        adapters.canonicalYouTubeURL("https://youtu.be/abc123?t=9"),
        "https://www.youtube.com/watch?v=abc123"
    );
});

test("page-level adapters prefer in-page UI without waiting for inject", () => {
    assert.equal(adapters.prefersInlineUI("https://www.bilibili.com/video/BV1abc"), true);
    assert.equal(adapters.prefersInlineUI("https://www.youtube.com/watch?v=abc"), true);
    assert.equal(adapters.prefersInlineUI("https://www.bilibili.com/"), false);
    assert.equal(adapters.prefersInlineUI("https://app.bilibili.com/"), false);
    assert.equal(adapters.prefersInlineUI("https://x.com/user/status/123"), false);
    assert.equal(adapters.prefersInlineUI("https://example.com/watch"), false);
});

test("suppresses a floating candidate only after the nearby native action exists", () => {
    const button = {};
    const article = {
        querySelector(selector) {
            return selector === '[data-better-ndm-site-action="x"]' ? button : null;
        }
    };
    const video = { closest: selector => selector === "article" ? article : null };
    assert.equal(adapters.hasInlineAction(video, "https://x.com/user/status/123"), true);
    assert.equal(adapters.hasInlineAction({ closest: () => null }, "https://x.com/user/status/123"), false);
});

test("uses the page action for single-video sites and keeps a fallback when injection failed", () => {
    const withAction = {
        querySelector(selector) {
            return selector === '[data-better-ndm-site-action="youtube"]' ? {} : null;
        }
    };
    const withoutAction = { querySelector: () => null };
    assert.equal(adapters.hasInlineAction(null, "https://www.youtube.com/watch?v=abc", withAction), true);
    assert.equal(adapters.hasInlineAction(null, "https://www.youtube.com/watch?v=abc", withoutAction), false);
    assert.equal(adapters.hasInlineAction("https://www.youtube.com/watch?v=abc", undefined, withAction), true);
    assert.equal(adapters.hasInlineAction(null, "https://www.bilibili.com/video/BV1abc", {
        querySelector(selector) {
            return selector === '[data-better-ndm-site-action="bilibili"]' ? {} : null;
        }
    }), true);
});

test("treats a lone location href as the page URL when checking page-level injects", () => {
    const withAction = {
        querySelector(selector) {
            return selector === '[data-better-ndm-site-action="bilibili"]' ? {} : null;
        }
    };
    assert.equal(adapters.hasInlineAction("https://www.bilibili.com/video/BV1abc", undefined, withAction), true);
});
