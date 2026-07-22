(function(root, factory) {
    var api = factory();
    if (typeof module === "object" && module.exports) module.exports = api;
    root.NDMRelaySiteAdapters = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function() {
    "use strict";

    function hostFor(value) {
        try { return new URL(String(value || "")).hostname.toLowerCase(); }
        catch (_) { return ""; }
    }

    function siteForURL(value) {
        var host = hostFor(value);
        if (host === "x.com" || host.endsWith(".x.com") ||
            host === "twitter.com" || host.endsWith(".twitter.com")) return "x";
        if (host === "youtu.be" || host === "youtube.com" || host.endsWith(".youtube.com")) return "youtube";
        if (host === "bilibili.com" || host.endsWith(".bilibili.com")) return "bilibili";
        if (host === "vimeo.com" || host.endsWith(".vimeo.com")) return "vimeo";
        if (host === "instagram.com" || host.endsWith(".instagram.com")) return "instagram";
        if (host === "tiktok.com" || host.endsWith(".tiktok.com")) return "tiktok";
        if (host === "douyin.com" || host.endsWith(".douyin.com")) return "douyin";
        return "";
    }

    function canonicalXURL(value) {
        var match = String(value || "").match(/^(https?:\/\/(?:[^/.]+\.)?(?:x|twitter)\.com\/[^/?#]+\/status\/\d+)/i);
        return match ? match[1].replace(/^http:/i, "https:") : "";
    }

    function canonicalYouTubeURL(value) {
        try {
            var url = new URL(String(value || ""));
            var host = url.hostname.toLowerCase();
            if (host === "youtu.be") {
                var shortID = url.pathname.split("/").filter(Boolean)[0];
                return shortID ? "https://www.youtube.com/watch?v=" + encodeURIComponent(shortID) : "";
            }
            if (!(host === "youtube.com" || host.endsWith(".youtube.com"))) return "";
            if (url.pathname === "/watch") {
                var videoID = url.searchParams.get("v");
                return videoID ? "https://www.youtube.com/watch?v=" + encodeURIComponent(videoID) : "";
            }
            var pathMatch = url.pathname.match(/^\/(shorts|live)\/([^/?#]+)/i);
            return pathMatch ? "https://www.youtube.com/" + pathMatch[1].toLowerCase() + "/" + encodeURIComponent(pathMatch[2]) : "";
        } catch (_) {
            return "";
        }
    }

    function canonicalBilibiliURL(value) {
        try {
            var url = new URL(String(value || ""));
            if (!(url.hostname === "bilibili.com" || url.hostname.endsWith(".bilibili.com"))) return "";
            var match = url.pathname.match(/^\/video\/((?:BV[0-9A-Za-z]+)|(?:av\d+))/i);
            return match ? "https://www.bilibili.com/video/" + match[1] : "";
        } catch (_) { return ""; }
    }

    function canonicalVimeoURL(value) {
        try {
            var url = new URL(String(value || ""));
            if (!(url.hostname === "vimeo.com" || url.hostname.endsWith(".vimeo.com"))) return "";
            var match = url.pathname.match(/\/(?:video\/)?(\d+)(?:\/|$)/);
            return match ? "https://vimeo.com/" + match[1] : "";
        } catch (_) { return ""; }
    }

    function canonicalInstagramURL(value) {
        try {
            var url = new URL(String(value || ""));
            if (!(url.hostname === "instagram.com" || url.hostname.endsWith(".instagram.com"))) return "";
            var match = url.pathname.match(/^\/(reel|p|tv)\/([^/?#]+)/i);
            return match ? "https://www.instagram.com/" + match[1].toLowerCase() + "/" + match[2] + "/" : "";
        } catch (_) { return ""; }
    }

    function canonicalTikTokURL(value) {
        try {
            var url = new URL(String(value || ""));
            if (!(url.hostname === "tiktok.com" || url.hostname.endsWith(".tiktok.com"))) return "";
            var match = url.pathname.match(/^\/@([^/]+)\/video\/(\d+)/i);
            return match ? "https://www.tiktok.com/@" + match[1] + "/video/" + match[2] : "";
        } catch (_) { return ""; }
    }

    function canonicalDouyinURL(value) {
        try {
            var url = new URL(String(value || ""));
            if (!(url.hostname === "douyin.com" || url.hostname.endsWith(".douyin.com"))) return "";
            var match = url.pathname.match(/^\/video\/(\d+)/i);
            return match ? "https://www.douyin.com/video/" + match[1] : "";
        } catch (_) { return ""; }
    }

    function canonicalForSite(site, value) {
        if (site === "x") return canonicalXURL(value);
        if (site === "youtube") return canonicalYouTubeURL(value);
        if (site === "bilibili") return canonicalBilibiliURL(value);
        if (site === "vimeo") return canonicalVimeoURL(value);
        if (site === "instagram") return canonicalInstagramURL(value);
        if (site === "tiktok") return canonicalTikTokURL(value);
        if (site === "douyin") return canonicalDouyinURL(value);
        return "";
    }

    function canonicalPageURL(value, candidateLinks) {
        var site = siteForURL(value);
        if (!site) return "";
        var direct = canonicalForSite(site, value);
        if (direct) return direct;
        var links = candidateLinks || [];
        for (var i = 0; i < links.length; i++) {
            direct = canonicalForSite(site, links[i]);
            if (direct) return direct;
        }
        return "";
    }

    function pageURLForElement(element, locationValue) {
        var rawLocation = String(locationValue && locationValue.href || locationValue || "");
        var site = siteForURL(rawLocation);
        if (site !== "x" && site !== "instagram") return canonicalPageURL(rawLocation);
        var article = element && element.closest ? element.closest('article[data-testid="tweet"], article') : null;
        var scope = article || element || (typeof document !== "undefined" ? document : null);
        var links = [];
        if (scope && scope.querySelectorAll) {
            links = Array.from(scope.querySelectorAll('a[href*="/status/"],a[href*="/reel/"],a[href*="/p/"],a[href*="/tv/"]')).map(function(link) {
                return link.href || link.getAttribute("href") || "";
            });
        }
        return canonicalPageURL(rawLocation, links);
    }

    /// True only after the site-native action actually exists. Callers use
    /// this to suppress the legacy floating media strip without risking a
    /// dead end when a site changes its DOM and injection fails.
    function hasInlineAction(element, locationValue, documentValue) {
        var rawLocation = String(locationValue && locationValue.href || locationValue || "");
        var site = siteForURL(rawLocation);
        if (!site) return false;
        var selector = '[data-better-ndm-site-action="' + site + '"]';
        if (site === "x" || site === "instagram") {
            var article = element && element.closest ? element.closest("article") : null;
            return Boolean(article && article.querySelector && article.querySelector(selector));
        }
        var doc = documentValue || (typeof document !== "undefined" ? document : null);
        return Boolean(doc && doc.querySelector && doc.querySelector(selector));
    }

    function text(zh, en) {
        return typeof navigator !== "undefined" && String(navigator.language || "").toLowerCase().indexOf("zh") === 0 ? zh : en;
    }

    function addStyles() {
        if (!document.head || document.getElementById("better-ndm-site-adapter-style")) return;
        var style = document.createElement("style");
        style.id = "better-ndm-site-adapter-style";
        style.textContent = [
            // X action-bar icon button: icon-only inside a circular hover, like
            // the native Share/Bookmark. Color is synced from a sibling native
            // button at inject time (theme-exact); the vars are the fallback.
            ".better-ndm-x-action{display:flex;align-items:center;min-width:0}",
            ".better-ndm-x-button{all:unset;box-sizing:border-box;display:inline-flex;align-items:center;justify-content:center;width:34.75px;height:34.75px;border-radius:9999px;color:var(--better-ndm-x-color,rgb(83,100,113));cursor:pointer;transition:color .2s ease,background-color .2s ease}",
            ".better-ndm-x-button:hover,.better-ndm-x-button:focus-visible{color:rgb(29,155,240);background:rgba(29,155,240,.1);outline:none}",
            ".better-ndm-x-button svg{width:18.75px;height:18.75px;fill:currentColor;flex:none}",
            ".better-ndm-x-label{display:none}",
            // YouTube: match the native mono action chip (Share/Download).
            ".better-ndm-youtube-action{display:inline-flex;align-items:center;margin-left:8px;vertical-align:middle}",
            // Values verified against YouTube's live 分享/Share chip: 40px tall,
            // 20px radius, 0 16px padding, rgba(0,0,0,.05) bg, 14px Roboto.
            ".better-ndm-youtube-button{all:unset;box-sizing:border-box;display:inline-flex;align-items:center;justify-content:center;gap:6px;height:40px;padding:0 16px;border-radius:20px;background:var(--yt-spec-badge-chip-background,rgba(0,0,0,.05));color:var(--yt-spec-text-primary,#0f0f0f);cursor:pointer;font:500 14px/40px Roboto,Arial,sans-serif;white-space:nowrap;transition:background-color .15s ease}",
            ".better-ndm-youtube-button:hover,.better-ndm-youtube-button:focus-visible{background:var(--yt-spec-button-chip-background-hover,rgba(0,0,0,.1));outline:none}",
            ".better-ndm-youtube-button svg{width:24px;height:24px;fill:currentColor;flex:none;margin-left:-4px}",
            ".better-ndm-bilibili-action{display:inline-flex;align-items:center;margin-left:24px}",
            ".better-ndm-bilibili-button{all:unset;box-sizing:border-box;display:flex;align-items:center;gap:7px;color:#61666d;cursor:pointer;font:500 14px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;white-space:nowrap;transition:color .15s}",
            ".better-ndm-bilibili-button:hover,.better-ndm-bilibili-button:focus-visible{color:#00aeec;outline:none}",
            ".better-ndm-bilibili-button svg{width:24px;height:24px;fill:currentColor}",
            ".better-ndm-site-inline-action{display:inline-flex;align-items:center;margin-left:8px}",
            ".better-ndm-site-inline-button{all:unset;box-sizing:border-box;display:inline-flex;align-items:center;justify-content:center;gap:6px;min-height:34px;padding:0 12px;border:1px solid rgba(120,120,128,.25);border-radius:8px;background:rgba(120,120,128,.08);color:inherit;cursor:pointer;font:600 13px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;white-space:nowrap}",
            ".better-ndm-site-inline-button:hover,.better-ndm-site-inline-button:focus-visible{background:rgba(53,120,246,.12);border-color:rgba(53,120,246,.45);color:#3478f6;outline:none}",
            ".better-ndm-site-inline-button svg{width:18px;height:18px;fill:currentColor;flex:none}",
            ".better-ndm-site-busy{opacity:.68;pointer-events:none}"
        ].join("");
        document.head.appendChild(style);
    }

    function makeIcon() {
        var namespace = "http://www.w3.org/2000/svg";
        var svg = document.createElementNS(namespace, "svg");
        svg.setAttribute("viewBox", "0 0 24 24");
        svg.setAttribute("aria-hidden", "true");
        var path = document.createElementNS(namespace, "path");
        path.setAttribute("d", "M11 3a1 1 0 0 1 2 0v9.59l2.3-2.3a1 1 0 1 1 1.4 1.42l-4 4a1 1 0 0 1-1.4 0l-4-4a1 1 0 0 1 1.4-1.42l2.3 2.3V3ZM5 17a1 1 0 0 1 1 1v1h12v-1a1 1 0 1 1 2 0v2a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1v-2a1 1 0 0 1 1-1Z");
        svg.appendChild(path);
        return svg;
    }

    function SiteAdapterManager(options) {
        this.options = options || {};
        this.observer = null;
        this.timer = null;
        this.start();
    }

    SiteAdapterManager.prototype.start = function() {
        if (typeof document === "undefined" || typeof window === "undefined") return;
        if (!siteForURL(window.location.href)) return;
        var manager = this;
        var ready = function() {
            addStyles();
            manager.scan();
            if (!manager.observer && window.MutationObserver) {
                manager.observer = new MutationObserver(function() { manager.schedule(); });
                manager.observer.observe(document.documentElement, { childList: true, subtree: true });
            }
        };
        if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", ready, { once: true });
        else ready();
    };

    SiteAdapterManager.prototype.schedule = function() {
        var manager = this;
        if (this.timer) return;
        this.timer = setTimeout(function() {
            manager.timer = null;
            manager.scan();
        }, 80);
    };

    SiteAdapterManager.prototype.notifyActionReady = function() {
        if (this.options.onActionReady) this.options.onActionReady();
    };

    SiteAdapterManager.prototype.scan = function() {
        var site = siteForURL(window.location.href);
        if (site === "x") this.scanX();
        else if (site === "youtube") this.scanYouTube();
        else if (site === "bilibili") this.scanBilibili();
        else if (site === "vimeo") this.scanVimeo();
        else if (site === "instagram") this.scanInstagram();
        else if (site === "tiktok") this.scanTikTok();
        else if (site === "douyin") this.scanDouyin();
    };

    SiteAdapterManager.prototype.makeButton = function(site, urlProvider) {
        var manager = this;
        var button = document.createElement("button");
        button.type = "button";
        button.dataset.betterNdmSiteAction = site;
        button.className = site === "x" ? "better-ndm-x-button" : site === "youtube" ? "better-ndm-youtube-button" : site === "bilibili" ? "better-ndm-bilibili-button" : "better-ndm-site-inline-button";
        var label = site === "x" ? "NDM" : site === "bilibili" ? text("NDM 下载", "NDM Download") : text("使用 NDM 下载", "Download with NDM");
        var labelNode = document.createElement("span");
        labelNode.className = "better-ndm-" + site + "-label";
        labelNode.textContent = label;
        button.appendChild(makeIcon());
        button.appendChild(labelNode);
        button.title = text("使用 NDM 下载此视频", "Download this video with NDM");
        button.setAttribute("aria-label", button.title);
        button.addEventListener("click", function(event) {
            event.preventDefault();
            event.stopPropagation();
            var url = urlProvider();
            if (!url || button.disabled) return;
            button.disabled = true;
            button.classList.add("better-ndm-site-busy");
            button.setAttribute("aria-busy", "true");
            if (labelNode) labelNode.textContent = text("正在打开 NDM…", "Opening NDM…");
            try {
                if (manager.options.onDownload) manager.options.onDownload({
                    site: site,
                    url: url,
                    label: text("使用 NDM 下载", "Download with NDM")
                });
            } finally {
                setTimeout(function() {
                    button.disabled = false;
                    button.classList.remove("better-ndm-site-busy");
                    button.removeAttribute("aria-busy");
                    if (labelNode) labelNode.textContent = label;
                }, 1400);
            }
        });
        return button;
    };

    SiteAdapterManager.prototype.scanX = function() {
        var manager = this;
        Array.from(document.querySelectorAll('article[data-testid="tweet"]')).forEach(function(article) {
            if (article.querySelector('[data-better-ndm-site-action="x"]')) return;
            if (!article.querySelector('video,[data-testid="videoPlayer"]')) return;
            var actionGroups = Array.from(article.querySelectorAll('[role="group"]'));
            var group = actionGroups.find(function(candidate) {
                return candidate.querySelector('[data-testid="reply"],[data-testid="retweet"],[data-testid="like"]');
            });
            if (!group) return;
            var pageURL = pageURLForElement(article, window.location);
            if (!pageURL) return;
            var wrapper = document.createElement("div");
            wrapper.className = "better-ndm-x-action";
            wrapper.dataset.betterNdmSiteAction = "x-wrapper";
            var button = manager.makeButton("x", function() {
                return pageURLForElement(article, window.location) || pageURL;
            });
            // Theme-exact resting color: copy it from a native action-bar icon
            // (X's dim / lights-out / light themes each use a different gray,
            // and it isn't the OS color scheme). Falls back to the CSS var.
            var nativeIcon = group.querySelector('[data-testid="reply"] svg, [data-testid="retweet"] svg, [data-testid="like"] svg');
            if (nativeIcon) {
                var nativeColor = window.getComputedStyle(nativeIcon).color;
                if (nativeColor) button.style.setProperty("--better-ndm-x-color", nativeColor);
            }
            wrapper.appendChild(button);
            group.appendChild(wrapper);
            manager.notifyActionReady();
        });
    };

    SiteAdapterManager.prototype.scanYouTube = function() {
        if (!canonicalYouTubeURL(window.location.href)) return;
        var actions = document.querySelector('ytd-watch-metadata #top-level-buttons-computed');
        if (!actions || actions.querySelector('[data-better-ndm-site-action="youtube"]')) return;
        var wrapper = document.createElement("div");
        wrapper.className = "better-ndm-youtube-action";
        wrapper.dataset.betterNdmSiteAction = "youtube-wrapper";
        wrapper.appendChild(this.makeButton("youtube", function() {
            return canonicalYouTubeURL(window.location.href);
        }));
        actions.appendChild(wrapper);
        this.notifyActionReady();
    };

    SiteAdapterManager.prototype.scanBilibili = function() {
        var pageURL = canonicalBilibiliURL(window.location.href);
        if (!pageURL || !document.querySelector("video")) return;
        var actions = document.querySelector("#arc_toolbar_report .video-toolbar-left-main, .video-toolbar-left-main");
        if (!actions || actions.querySelector('[data-better-ndm-site-action="bilibili"]')) return;
        var wrapper = document.createElement("div");
        wrapper.className = "better-ndm-bilibili-action";
        wrapper.dataset.betterNdmSiteAction = "bilibili-wrapper";
        wrapper.appendChild(this.makeButton("bilibili", function() { return canonicalBilibiliURL(window.location.href) || pageURL; }));
        actions.appendChild(wrapper);
        this.notifyActionReady();
    };

    SiteAdapterManager.prototype.scanVimeo = function() {
        var pageURL = canonicalVimeoURL(window.location.href);
        if (!pageURL || !document.querySelector("video")) return;
        var actions = document.querySelector('[data-testid="video-actions"], [class*="video_actions"], [class*="action-bar"]');
        if (!actions) {
            var heading = document.querySelector("main h1, h1");
            actions = heading && heading.parentElement;
        }
        this.addInlineAction(actions, "vimeo", function() { return canonicalVimeoURL(window.location.href) || pageURL; });
    };

    SiteAdapterManager.prototype.scanInstagram = function() {
        var manager = this;
        Array.from(document.querySelectorAll("article")).forEach(function(article) {
            if (!article.querySelector("video") || article.querySelector('[data-better-ndm-site-action="instagram"]')) return;
            var pageURL = pageURLForElement(article, window.location);
            if (!pageURL) return;
            var actions = Array.from(article.querySelectorAll("section")).find(function(section) {
                return section.querySelectorAll("button").length >= 2;
            });
            manager.addInlineAction(actions, "instagram", function() { return pageURLForElement(article, window.location) || pageURL; });
        });
    };

    SiteAdapterManager.prototype.scanTikTok = function() {
        var pageURL = canonicalTikTokURL(window.location.href);
        if (!pageURL || !document.querySelector("video")) return;
        var share = document.querySelector('[data-e2e="share-icon"], [data-e2e="video-share"], [data-e2e="browse-share-group"]');
        var actions = share && (share.closest("section") || share.parentElement);
        this.addInlineAction(actions, "tiktok", function() { return canonicalTikTokURL(window.location.href) || pageURL; });
    };

    SiteAdapterManager.prototype.scanDouyin = function() {
        var pageURL = canonicalDouyinURL(window.location.href);
        if (!pageURL || !document.querySelector("video")) return;
        var actions = document.querySelector('[data-e2e="video-action-bar"], [class*="video-action"], [class*="action-bar"]');
        this.addInlineAction(actions, "douyin", function() { return canonicalDouyinURL(window.location.href) || pageURL; });
    };

    SiteAdapterManager.prototype.addInlineAction = function(actions, site, urlProvider) {
        if (!actions || actions.querySelector('[data-better-ndm-site-action="' + site + '"]')) return;
        var wrapper = document.createElement("span");
        wrapper.className = "better-ndm-site-inline-action";
        wrapper.dataset.betterNdmSiteAction = site + "-wrapper";
        wrapper.appendChild(this.makeButton(site, urlProvider));
        actions.appendChild(wrapper);
        this.notifyActionReady();
    };

    SiteAdapterManager.prototype.refresh = function() {
        this.schedule();
    };

    SiteAdapterManager.prototype.destroy = function() {
        if (this.observer) this.observer.disconnect();
        if (this.timer) clearTimeout(this.timer);
        this.observer = null;
        this.timer = null;
    };

    function install(options) {
        return new SiteAdapterManager(options);
    }

    return {
        canonicalPageURL: canonicalPageURL,
        canonicalBilibiliURL: canonicalBilibiliURL,
        canonicalDouyinURL: canonicalDouyinURL,
        canonicalInstagramURL: canonicalInstagramURL,
        canonicalTikTokURL: canonicalTikTokURL,
        canonicalVimeoURL: canonicalVimeoURL,
        canonicalXURL: canonicalXURL,
        canonicalYouTubeURL: canonicalYouTubeURL,
        hasInlineAction: hasInlineAction,
        install: install,
        pageURLForElement: pageURLForElement,
        siteForURL: siteForURL
    };
});
