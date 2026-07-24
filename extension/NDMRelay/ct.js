var k = chrome.runtime.getURL("img/icon16.png"),
    w = chrome.runtime.getURL("img/close16.png"),
    y = {
        242: "240p",
        243: "360p",
        244: "480p",
        246: "480p",
        247: "720p",
        248: "1080p",
        271: "1440p",
        272: "2160p",
        278: "144p",
        302: "720p-60f",
        303: "1080p-60f",
        308: "1440p-60f",
        313: "2160p",
        315: "2160p-60f",
        335: "1080p-60f",
        336: "1440p-60f",
        337: "2160p-60f"
    },
    z = [171, 172, 249, 250, 251];

function C(d) {
    return document.getElementById(d)
}
window.el = C;

function D() {
    var d = document.location.host.toLowerCase(),
        g = d.length - 12;
    return 0 <= g && d.indexOf("facebook.com", g) == g
}
async function E(d) {
    try {
        const g = await fetch(d["2"], {
            mode: "no-cors"
        });
        if (g.ok) {
            let a = await g.text();
            (d.ba || function() {})(a)
        }
    } catch (g) {}
}

function F(d) {
    var g = 0,
        a;
    var b = 0;
    for (a = d.length; b < a; b++) {
        var c = d.charCodeAt(b);
        g = (g << 5) - g + c;
        g |= 0
    }
    return g
}

function G(d) {
    return !d || 0 > d ? " " : 1E3 > d ? d + " Bytes" : 1E6 > d ? (d / 1024).toFixed(1) + " KB" : 1E9 > d ? (d / 1048576).toFixed(2) + " MB" : (d / 1073741824).toFixed(3) + " GB"
}

function H(d) {
    return d.replace(/\\u([\d\w]{4})/gi, function(g, a) {
        return String.fromCharCode(parseInt(a, 16))
    })
}

function I(d) {
    if (!d) return {
        left: 0,
        top: 0
    };
    try {
        var g = d.getBoundingClientRect();
        return g ? {
            left: Math.round(g.left + window.pageXOffset),
            top: Math.round(g.top + window.pageYOffset)
        } : {
            left: 0,
            top: 0
        }
    } catch (a) {
        return {
            left: 0,
            top: 0
        }
    }
}

function M(d) {
    return d ? !d.fEx || "VTT" != d.fEx.toUpperCase() && "SRT" != d.fEx.toUpperCase() ? d["4"] || (d.fEx.toUpperCase() || "MP4") + " File  " + (G(d.fS) || d.fDu) : d.fEx.toUpperCase() + " Subtitles File " + (d.fS ? G(d.fS) : " ") : "Media File"
}

var NDMRelayPolicy = globalThis.NDMRelayMediaPolicy;

function NDMRelayText(zh, en) {
    return String(navigator.language || "").toLowerCase().indexOf("zh") === 0 ? zh : en
}

function N(d, g, a) {
    this.D = d;
    d.i[a] = this;
    this.ua = a;
    this.h = null;
    this.badge = null;
    this.badgeLabel = null;
    this.count = null;
    this.p = null;
    this.panel = null;
    this.m = g;
    this.j = null;
    this.hover = !1;
    this.position = {
        left: 0,
        top: 0
    };
    this.toolbarPinned = !1;
    this.items = [];
    this.visibleItems = [];
    this.showAlternatives = !1
}
var O = N.prototype;
O.G = function(d) {
    var g = Array.prototype.slice.call(arguments);
    g[2] = g[2].bind(this);
    d.addEventListener.apply(d, g.slice(1))
};
O.v = function() {
    this.h && (this.h.style.left = (this.toolbarPinned ? 16 : this.position.left) + "px", this.h.style.top = (this.toolbarPinned ? 16 : this.position.top) + "px")
};
O.Y = function(d) {
    this.K(!0);
    this.D.oa(this.visibleItems[d])
};
O.K = function(d) {
    this.p && (this.p.style.display = d ? "none" : "none" == this.p.style.display ? "flex" : "none")
};
O.siteHasInlineUI = function() {
    if (!globalThis.NDMRelaySiteAdapters) return false;
    var href = window.location.href;
    // Page-level adapters: suppress the float as soon as we are on a known
    // video URL. Waiting for the inject to land was too late — media sniffs
    // already mounted overlays during Bilibili/YouTube boot.
    if (NDMRelaySiteAdapters.prefersInlineUI(href)) return true;
    return Boolean(NDMRelaySiteAdapters.siteForURL(href) &&
        NDMRelaySiteAdapters.hasInlineAction(this.m, href));
};
O.show = function(d) {
    if (!this.h) return;
    // Adapted sites (Bilibili/YouTube/…) use the in-page button. Never resurrect
    // the floating strip once that native action is present.
    if (this.siteHasInlineUI()) {
        this.h.style.display = "none";
        this.h.setAttribute("aria-hidden", "true");
        this.h.style.pointerEvents = "none";
        return;
    }
    this.h.style.display = this.D.H ? "" : "none";
    this.h.removeAttribute("aria-hidden");
    this.h.style.opacity = 1;
    this.h.style.pointerEvents = "";
    d && this.p && (this.p.style.display = "flex");
    this.fade(d ? 6E3 : 1800)
};
O.theme = function() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: light)").matches ? {
        bg: "#f7f7f8",
        fg: "#202124",
        muted: "#5f6368",
        bd: "rgba(60, 60, 67, 0.24)",
        hbg: "#3478f6"
    } : {
        bg: "#2c2c2e",
        fg: "#f5f5f7",
        muted: "#c7c7cc",
        bd: "rgba(235, 235, 245, 0.22)",
        hbg: "#3f82f7"
    }
};
O.fade = function(delay) {
    var g = this;
    this.j && clearTimeout(this.j);
    this.j = setTimeout(function() {
        g.j = null;
        g.h && (g.p.style.display = "none", g.h.style.opacity = 0, g.h.style.pointerEvents = "none")
    }, delay || 1800)
};
O.wake = function() {
    this.hover || !this.h || this.show(!1)
};
O.I = function(d) {
    var g = this,
        t = this.theme(),
        e = this.D.N(this.visibleItems[d]),
        b = NDMRelayPolicy ? NDMRelayPolicy.describeCandidate(e, {
            locale: navigator.language,
            recommended: 0 == d
        }) : M(e),
        a = document.createElement("BUTTON");
    a.type = "button";
    a.style.cssText = "all:unset;box-sizing:border-box;display:flex;align-items:center;width:100%;max-width:360px;min-height:32px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:5px 10px;margin:0px;border-radius:8px;border:solid 1px " + t.bd + ";background:" + (0 == d ? t.hbg : t.bg) + ";color:" + (0 == d ? "white" : t.fg) + ";cursor:pointer;font-family:-apple-system, BlinkMacSystemFont, 'Segoe UI' !important;font-size:12px;line-height:18px;font-weight:" + (0 == d ? "650" : "500") + ";direction:ltr;text-align:left;user-select:none;box-shadow:0 2px 8px rgba(0,0,0,0.12)";
    a.innerText = b.trim();
    a.title = b.trim();
    a.setAttribute("aria-label", b.trim());
    a.onmouseover = function() {
        this.style.background = t.hbg;
        this.style.color = "white"
    };
    a.onmouseout = function() {
        this.style.background = 0 == d ? t.hbg : t.bg;
        this.style.color = 0 == d ? "white" : t.fg
    };
    a.onfocus = function() {
        this.style.outline = "2px solid rgba(64, 156, 255, 0.95)";
        this.style.outlineOffset = "2px"
    };
    a.onblur = function() {
        this.style.outline = "none"
    };
    a.onclick = function(e) {
        e.stopPropagation();
        e.preventDefault();
        g.Y(d)
    };
    this.panel.appendChild(a)
};
O.render = function() {
    if (!this.panel || !this.h) return;
    var d = this,
        raw = this.items.map(function(g) {
            return d.D.N(g)
        }).filter(Boolean),
        visible = NDMRelayPolicy ? NDMRelayPolicy.compactCandidates(raw, 6) : raw,
        allItemIds = visible.map(function(g) {
            return g.id
        });
    this.visibleItems = this.showAlternatives ? allItemIds : allItemIds.slice(0, 1);
    this.panel.replaceChildren();
    for (var g = 0; g < this.visibleItems.length; g++) this.I(g);
    var a = allItemIds.length;
    if (1 < a) {
        var e = this,
            t = this.theme(),
            more = document.createElement("BUTTON");
        more.type = "button";
        more.style.cssText = "all:unset;box-sizing:border-box;min-height:28px;padding:4px 10px;border-radius:6px;color:" + t.muted + ";cursor:pointer;font-family:-apple-system, BlinkMacSystemFont, 'Segoe UI' !important;font-size:11px;line-height:18px;font-weight:550;text-align:left";
        more.innerText = this.showAlternatives ? NDMRelayText("收起其他格式", "Hide other formats") : NDMRelayText("其他格式（" + (a - 1) + "）", "Other formats (" + (a - 1) + ")");
        more.setAttribute("aria-expanded", this.showAlternatives ? "true" : "false");
        more.onclick = function(f) {
            f.stopPropagation();
            e.showAlternatives = !e.showAlternatives;
            e.render();
            e.show(!0)
        };
        this.panel.appendChild(more)
    }
    this.count.innerText = a;
    this.count.style.display = 1 < a ? "" : "none";
    this.badge.setAttribute("aria-label", NDMRelayText("显示检测到的 " + a + " 个视频下载选项", "Show " + a + " detected video download options"));
    // Pass the media element so X/Instagram can scope to the nearby article;
    // page-level adapters (YouTube/Bilibili/…) query document for the inject.
    var siteHasInlineUI = this.siteHasInlineUI();
    var shouldFloat = a && this.D.H && !siteHasInlineUI;
    this.h.style.display = shouldFloat ? "" : "none";
    shouldFloat ? this.h.removeAttribute("aria-hidden") : this.h.setAttribute("aria-hidden", "true");
    if (!shouldFloat) {
        this.h.style.pointerEvents = "none";
        this.p && (this.p.style.display = "none");
    }
    this.D.updateMediaCount();
    this.v()
};
O.L = function(d) {
    var g = this,
        a = this.D.N(d),
        b = null,
        c = this.m ? "absolute" : "fixed";
    this.m && (b = I(this.m));
    b && (this.position = {
        left: Math.max(0, b.left + 8),
        top: Math.max(0, b.top + 8)
    });
    this.m || (this.position = {
        left: 16,
        top: 16
    });
    if (this.h) this.v();
    else {
        var t = this.theme();
        this.h = document.createElement("DIV");
        this.h.style.cssText = "padding:0px;margin:0px;position:" + c + ";z-index:100000000;left:" + this.position.left + "px;top:" + this.position.top + "px;direction:ltr;line-height:100% !important;opacity:1;transition:opacity 0.35s";
        this.h.id = "neatDiv" + this.ua;
        this.h.style.display = this.D.H ? "" : "none";
        var row = document.createElement("DIV");
        row.style.cssText = "display:flex;flex-direction:row;align-items:flex-start;gap:5px";
        this.h.appendChild(row);
        this.badge = document.createElement("BUTTON");
        this.badge.type = "button";
        this.badge.style.cssText = "all:unset;display:flex;align-items:center;justify-content:center;height:30px;min-width:48px;padding:0px 8px;box-sizing:border-box;border-radius:9px;border:solid 1px " + t.bd + ";background:" + t.bg + ";cursor:pointer;user-select:none;box-shadow:0 2px 8px rgba(0,0,0,0.14)";
        this.badge.setAttribute("aria-label", NDMRelayText("显示视频下载选项", "Show video download options"));
        var e = document.createElement("IMG");
        e.src = k;
        e.width = 14;
        e.height = 14;
        e.style.cssText = "display:block;pointer-events:none";
        this.badge.appendChild(e);
        this.badgeLabel = document.createElement("SPAN");
        this.badgeLabel.innerText = "NDM";
        this.badgeLabel.style.cssText = "display:block;margin-left:5px;color:" + t.fg + ";font-family:-apple-system, BlinkMacSystemFont, 'Segoe UI' !important;font-size:10px;line-height:1;font-weight:700;letter-spacing:0.01em";
        this.badge.appendChild(this.badgeLabel);
        this.count = document.createElement("SPAN");
        this.count.style.cssText = "display:none;margin-left:4px;color:" + t.muted + ";font-family:-apple-system, BlinkMacSystemFont, 'Segoe UI' !important;font-size:10px;font-weight:600";
        this.badge.appendChild(this.count);
        this.badge.onclick = function(f) {
            f.stopPropagation();
            g.K();
            g.show(!1)
        };
        row.appendChild(this.badge);
        this.p = document.createElement("DIV");
        this.p.style.cssText = "display:none;flex-direction:row;align-items:flex-start;gap:4px";
        this.panel = document.createElement("DIV");
        this.panel.style.cssText = "display:flex;flex-direction:column;align-items:stretch;gap:5px;max-width:min(360px,calc(100vw - 72px))";
        this.p.appendChild(this.panel);
        var cls = document.createElement("BUTTON");
        cls.type = "button";
        cls.style.cssText = "all:unset;display:flex;align-items:center;justify-content:center;width:26px;height:26px;box-sizing:border-box;border-radius:7px;border:solid 1px " + t.bd + ";background:" + t.bg + ";cursor:pointer";
        cls.setAttribute("aria-label", NDMRelayText("收起视频下载选项", "Minimize video download options"));
        var f = document.createElement("IMG");
        f.src = w;
        f.width = 10;
        f.height = 10;
        f.style.cssText = "display:block;pointer-events:none";
        cls.appendChild(f);
        cls.onclick = function(ev) {
            ev.stopPropagation();
            g.K(!0);
            g.h.style.opacity = 0;
            g.h.style.pointerEvents = "none"
        };
        this.p.appendChild(cls);
        row.appendChild(this.p);
        this.h.addEventListener("mouseenter", function() {
            g.hover = !0;
            g.j && (clearTimeout(g.j), g.j = null);
            g.h.style.opacity = 1
        });
        this.h.addEventListener("mouseleave", function() {
            g.hover = !1;
            g.fade(1200)
        });
        this.m && this.G(this.m, "mousemove", this.wake);
        document.body.appendChild(this.h);
        this.fade(1800)
    }
    if (-1 < this.items.indexOf(d)) return;
    this.items.push(d);
    this.D.ensurePageResolver(this);
    this.render()
};
if (!window.o) {
    var P = function() {
        this.ea = null;
        this.A = {};
        this.i = {};
        this.g = [];
        this.P = !1;
        this.$ = this.Z = -1;
        this.Counter = 1;
        this.l = null;
        this.H = !0;
        this.ja = [];
        this.port = chrome.runtime.connect({
            name: "neat"
        });
        this.ga = Math.ceil(2E6 * Math.random());
        this.port.onMessage.addListener(this.aa.bind(this));
        this.port.onDisconnect.addListener(this.ca.bind(this));
        if (D()) {
            var a = this;
            this.sa = new window.MutationObserver(function(b) {
                b.forEach(function(c) {
                    a.pa(c.target)
                })
            });
            this.sa.observe(document, {
                childList: !0,
                subtree: !0
            })
        }
        this.o(window,
            "keydown", this.W, !0);
        this.o(window, "keyup", this.W, !0);
        this.o(window, "mouseup", this.T, !0);
        this.o(window, "resize", this.ta);
        this.o(document, "DOMContentLoaded", this.da);
        this.o(document, "click", this.ra);
        this.siteAdapters = null;
        this.resourceShelf = null;
        if (window.top === window && globalThis.NDMRelaySiteAdapters) {
            try {
                this.siteAdapters = NDMRelaySiteAdapters.install({
                    onDownload: this.downloadSitePage.bind(this),
                    onActionReady: this.refreshSitePanels.bind(this)
                })
            } catch (a) {
                this.siteAdapters = null
            }
        }
        if (window.top === window && globalThis.NDMRelayResourceShelf) {
            try {
                this.resourceShelf = NDMRelayResourceShelf.install({
                    onDownload: this.downloadResource.bind(this)
                })
            } catch (a) {
                this.resourceShelf = null
            }
        }
    };
    window.o = !0;
    O = P.prototype;
    O.qa = function(a, b) {
        b.hd && this.B({
            id: F(b.hd),
            1: "GET",
            2: b.hd,
            fEx: "mp4",
            4: " MP4 File HQ"
        }, window.location.href, a, !1);
        b.sd && this.B({
            id: F(b.sd),
            1: "GET",
            2: b.sd,
            fEx: "mp4",
            4: " MP4 File LQ"
        }, window.location.href, a, !1)
    };
    O.la = function(a) {
        for (;
            (a = a.parentElement) && 1 > a.querySelectorAll("video").length;);
        if (a) return a.querySelectorAll("video")[0]
    };
    O.ia = function(a, b) {
        var c = this;
        E({
            2: "https://www.facebook.com/video/embed?video_id=" + b,
            ba: function(f) {
                var e = /"sd_src_no_ratelimit":"(.*?)"/.exec(f),
                    h = /"hd_src_no_ratelimit":"(.*?)"/.exec(f);
                e && e.length || (e = /"sd_src":"(.*?)"/.exec(f));
                h && h.length || (h = /"hd_src":"(.*?)"/.exec(f));
                f = {
                    sd: e && e.length ? e[1].replace(/\\/g, "") : "",
                    hd: h && h.length ? h[1].replace(/\\/g, "") : ""
                };
                e = c.la(a);
                void 0 !== e && c.qa(e, f)
            }
        })
    };
    O.pa = function(a) {
        var b = this;
        a = a.querySelectorAll('a[href*="/videos/"]');
        a.length && Array.from(a, function(c) {
            if (!c.getAttribute("NEAT_DM")) {
                c.setAttribute("NEAT_DM", 1);
                var f = c.href.match(/.*\/videos\/(\d+)\/.*/i);
                f && b.ia(c, f[1])
            }
        })
    };
    O.N = function(a) {
        return this.A[a]
    };
    O.refreshSitePanels = function() {
        for (var a in this.i) {
            if (this.i[a] && this.i[a].render) this.i[a].render()
        }
    };
    O.updateMediaCount = function() {
        // Do not badge adapted tabs where the in-page action already owns download.
        var count = 0;
        for (var key in this.i) {
            var panel = this.i[key];
            if (!panel || !panel.items || !panel.items.length) continue;
            if (panel.siteHasInlineUI && panel.siteHasInlineUI()) continue;
            count += panel.items.length
        }
        this.port.postMessage([21, Math.min(99, count)])
    };
    O.downloadSitePage = function(a) {
        if (!a || !a.url) return;
        var b = {
            id: F("NDMRelaySite:" + a.url),
            1: "GET",
            2: a.url,
            6: "media-page",
            fEx: "mp4",
            4: a.label || NDMRelayText("使用 NDM 下载", "Download with NDM"),
            betterPageResolver: !0
        };
        this.A[b.id] = b;
        this.oa(b.id)
    };
    O.downloadResource = function(a) {
        if (!a || !a["2"]) return;
        // Shelf rows are ordinary files. Keep the item URL in field 2 and mark
        // ltype normal so the Mac host does not rewrite it to the tab's video
        // page (the previous bug turned web.txt / .dmg clicks into yt-dlp probes).
        var item = {};
        for (var key in a) {
            if (Object.prototype.hasOwnProperty.call(a, key)) item[key] = a[key]
        }
        var b = item.id || F(item.resourceKey || item["2"]);
        item.id = b;
        item["6"] = "normal";
        item.betterPageResolver = !1;
        this.A[b] = item;
        this.oa(b)
    };
    O.socialVideoPageURL = function(a) {
        var b = String(window.location.hostname || "").toLowerCase();
        if (!(b == "x.com" || b.endsWith(".x.com") || b == "twitter.com" || b.endsWith(".twitter.com"))) return "";

        function c(f) {
            var e = String(f || "").match(/^(https?:\/\/(?:[^/.]+\.)?(?:x|twitter)\.com\/[^/?#]+\/status\/\d+)/i);
            return e ? e[1] : ""
        }
        var d = c(window.location.href);
        if (d) return d;
        var e = a && a.closest ? a.closest("article") : null;
        e ||= document;
        var g = e.querySelectorAll('a[href*="/status/"]');
        for (var h = 0; h < g.length; h++) {
            d = c(g[h].href);
            if (d) return d
        }
        return ""
    };
    O.ensurePageResolver = function(a) {
        var b = globalThis.NDMRelaySiteAdapters ? NDMRelaySiteAdapters.pageURLForElement(a.m, window.location) : this.socialVideoPageURL(a.m);
        if (!b) return;
        var c = F("NDMRelayPage:" + b);
        this.A[c] || (this.A[c] = {
            id: c,
            1: "GET",
            2: b,
            6: "media-page",
            fEx: "mp4",
            4: NDMRelayText("推荐 · 选择画质并下载", "Recommended · Choose quality and download"),
            betterPageResolver: !0
        });
        -1 == a.items.indexOf(c) && a.items.unshift(c)
    };
    O.showAllPanels = function() {
        var a = null,
            b = Number.POSITIVE_INFINITY;
        for (var c in this.i) {
            var d = this.i[c];
            if (!d || !d.h || !d.visibleItems.length) continue;
            // Prefer the embedded site button; skip floating recovery when it exists.
            if (d.siteHasInlineUI && d.siteHasInlineUI()) continue;
            var e = d.m && d.m.getBoundingClientRect ? d.m.getBoundingClientRect() : null;
            var g = e && e.bottom >= 0 && e.top <= window.innerHeight ? Math.abs(e.top) : 1E12;
            g < b && (a = d, b = g)
        }
        if (a) {
            a.toolbarPinned = b >= 1E12;
            a.h.style.position = a.toolbarPinned ? "fixed" : a.m ? "absolute" : "fixed";
            a.v();
            a.show(!0)
        }
    };
    O.Ba = function() {
        this.port.postMessage([2, this.ea, window.location.href, this.getTitle()])
    };
    O.da = function(a) {
        for (var b = this, c = document.getElementsByTagName("SCRIPT"), f, e, h, l, m = !1, q = /"progressive":\s*\[/, r = 0; r < c.length; r++) {
            var n = c[r];
            f = n.innerText;
            if (a && !m && -1 < f.indexOf("itag") && 0 > f.indexOf("signatureCipher")) {
                for (var p = ['"formats"', "adaptiveFormats"], t = 0; t < p.length; t++) e = f, h = e.indexOf(p[t]), 0 > h || (e = e.substr(h), h = e.indexOf("["), l = e.indexOf("]"), 0 > h || 0 > l || l <= h || (e = e.substr(h + 1, l - h - 1), m = this.M(e, 1 == t)));
                if (this.Ca) break
            }
            if (0 <= document.location.host.toLowerCase().indexOf("vimeo") && !n.src && q.test(n.innerText) && (e = n.innerText, h = e.indexOf('"progressive"'), !(0 > h || (l = e.indexOf("]", h), 0 > l)))) {
                e = e.substr(h, l - h + 1);
                f = null;
                try {
                    f = JSON.parse("{" + e + "}")
                } catch (v) {}
                if (f) {
                    var u = f.progressive;
                    u && setTimeout(function() {
                        for (var v = 0; v <
                            u.length; v++) b.B({
                            id: F(u[v].url),
                            1: "GET",
                            2: u[v].url,
                            fEx: "mp4",
                            4: "MP4 File " + u[v].quality
                        }, window.location.href, null, !1)
                    }, 2E3);
                    break
                }
            }
        }
    };
    O.M = function(a, b) {
        var c = this,
            f = {
                18: {
                    e: "MP4",
                    s: "360p"
                },
                22: {
                    e: "MP4",
                    s: "720p"
                },
                37: {
                    e: "MP4",
                    s: "1080p"
                },
                38: {
                    e: "MP4",
                    s: "1080p"
                },
                82: {
                    e: "MP4",
                    s: "360p"
                },
                84: {
                    e: "MP4",
                    s: "720p"
                },
                132: {
                    e: "MP4",
                    s: "240p"
                },
                151: {
                    e: "MP4",
                    s: "144p"
                }
            };
        a = H(a);
        a = a.replace(/\\/g, "");
        var e = [],
            h = "";
        a = a.split("}");
        if (1 > a.length) return !1;
        for (var l = 0; l < a.length; l++) {
            var m = a[l].trim(),
                q = {},
                r;
            if (m && !(0 > m.indexOf("itag"))) {
                var n =
                    m.indexOf('"url"');
                if (!(0 > n)) {
                    n = m.indexOf('"', n + 5);
                    var p = m.indexOf('"', n + 1);
                    if (!(0 > n || 0 > p || p <= n || (m = q.url = decodeURIComponent(m.substr(n + 1, p - n - 1)), n = m.indexOf("?"), 0 > n))) {
                        n = m.substring(n + 1).split("&");
                        for (p = 0; p < n.length; p++) 0 == n[p].indexOf("itag=") && (r = q.itag = parseInt(n[p].split("=").pop())), 0 == n[p].indexOf("dur=") && (q.dur = parseFloat(n[p].split("=").pop())), 0 == n[p].indexOf("ei=") && (q.mK = n[p].split("=").pop());
                        m && r && (0 < m.indexOf("signature=") || 0 < m.indexOf("sig=")) && (!b || q.dur) && (b || f[r]) && (!b || y[r] ||
                            -1 < z.indexOf(r)) && (b ? e.push({
                            2: m,
                            mme: 0 > z.indexOf(r) ? "video" : "audio",
                            ig: r,
                            du: q.dur,
                            mK: q.mK,
                            purl: window.location.href
                        }) : (m = parseInt(q.dur), h = q.timeStr = 60 > m ? m + " sec" : parseInt(m / 60) + " min " + (parseInt(m % 60) ? parseInt(m % 60) + " sec" : ""), e.push(q)))
                    }
                }
            }
        }
        if (!e.length) return !1;
        b ? setTimeout(function() {
            for (var t = e.length - 1; 0 <= t; t--) c.X(e[t], "DTC")
        }, 1800) : (this.Aa(), setTimeout(function() {
            for (var t = 0; t < e.length; t++) {
                var u = e[t];
                c.B({
                    id: F(u.url),
                    ig: u.itag,
                    1: "GET",
                    2: u.url,
                    fEx: f[u.itag].e,
                    4: f[u.itag].e + " File " + f[u.itag].s +
                        ", " + (u.timeStr || h)
                }, window.location.href, null, !1)
            }
        }, 1500));
        return !0
    };
    O.Aa = function() {
        this.g = [];
        for (var a in this.i)
            for (var b = this.i[a], c = 0; c < b.items.length; c++) {
                var f = this.A[b.items[c]];
                if (f && f.ig) {
                    this.U(a, !0);
                    break
                }
            }
    };
    O.U = function(a, b) {
        var c = this.i[a];
        if (c) {
            if (b)
                for (b = 0; b < c.items.length; b++) delete this.A[c.items[b]];
            try {
                document.body.removeChild(c.h), c.j && clearTimeout(c.j)
            } catch (f) {}
            delete this.i[a];
            this.updateMediaCount()
        }
    };
    O.oa = function(a) {
        (a = this.A[a]) && this.port.postMessage([6, a, window.location.href, this.getTitle(),
            M(a)
        ])
    };
    O.ka = function(a, b) {
        var c = null,
            f = ["VIDEO", "AUDIO", "OBJECT", "EMBED"];
        try {
            var e = document.activeElement,
                h = 0,
                l, m, q = e && 0 <= f.indexOf(e.tagName) ? e : null;
            q ||= (e = document.elementFromPoint(this.Z, this.$)) && 0 <= f.indexOf(e.tagName) ? e : null;
            for (var r = 0; r < f.length; r++) {
                for (var n = document.getElementsByTagName(f[r]), p = 0; p < n.length; p++)
                    if (e = n[p], 3 != r || "application/x-shockwave-flash" == e.type.toLowerCase()) {
                        var t = e.src || e.data;
                        if (t && (t == a || t == b)) {
                            var u = e;
                            break
                        }
                        if (q || v) var v = e;
                        else {
                            var A = e.clientWidth,
                                B = e.clientHeight;
                            if (A && B) {
                                var J = window.getComputedStyle(e);
                                if (!J || "hidden" != J.visibility) {
                                    var K = A * B;
                                    B < 1.4 * A && A < 3 * B && K > h && (h = K, l = e);
                                    m ||= e
                                }
                            }
                        }
                    } if (u) break
            }(c = u || q || v || l || m) || (c = document.querySelectorAll("video,audio")[0]);
            if (!c) return null;
            if ("EMBED" == c.tagName && !c.clientWidth && !c.clientHeight) {
                var L = c.parentElement;
                "OBJECT" == L.tagName && (c = L)
            }
            return c
        } catch (Q) {
            return null
        }
    };
    O.ma = function(a) {
        try {
            var b = parseInt(a.getAttribute("JM_NEAT"));
            b || (b = this.ga << 10 | this.Counter++, a.setAttribute("JM_NEAT", b));
            return b
        } catch (c) {}
    };
    O.getTitle = function() {
        var a = "";
        try {
            a = document.title || document.getElementsByTagName("title")[0].innerText, a = a.trim()
        } catch (b) {}
        return a ? a = a.replace(/[ \t\r\n\u25B6]+/g, " ").trim() : ""
    };
    O.W = function(a) {
        8 != a.keyCode && 46 != a.keyCode || this.port.postMessage([4, "keydown" == a.type])
    };
    O.T = function(a) {
        0 == a.button && (this.Z = a.clientX, this.$ = a.clientY)
    };
    O.ta = function() {
        if (!this.P) {
            this.P = !0;
            var a = this;
            window.setTimeout(function() {
                for (var b in a.i) {
                    var c = a.i[b],
                        f = null;
                    c.m && (f = I(c.m));
                    if (f) {
                        try {
                            document.body.removeChild(c.h)
                        } catch (e) {}
                        c.position.left =
                            Math.max(0, f.left + 8);
                        c.position.top = Math.max(0, f.top + 8);
                        document.body.appendChild(c.h)
                    }
                    c.v()
                }
                a.P = !1
            }, 500)
        }
    };

    function d(a, b) {
        return 18 > Math.abs(a.left - b.left) && 18 > Math.abs(a.top - b.top)
    }

    function g(a) {
        a = I(a.m);
        return !a || 0 > a.left || 0 > a.top
    }
    O.B = function(a, b, c, f) {
        var e = this,
            h = -1,
            l = null,
            m;
        // Adapted video pages download via the in-page button. Never create the
        // legacy float here: logged-in Bilibili tabs emit many media sniffs and
        // mounting overlays during Vue hydration blacked out the player.
        if (globalThis.NDMRelaySiteAdapters && NDMRelaySiteAdapters.prefersInlineUI(window.location.href)) {
            a.id || (a.id = F(a["2"]));
            e.A[a.id] = a;
            e.updateMediaCount();
            return;
        }
        f = f && RegExp(".*facebook.com$|.*vimeo.com$|.*youtube.com$", "i").test(window.location.host) && !(a.fEx && "VTT" == a.fEx.toUpperCase()) && !(!a.fS || 4194304 < a.fS);
        a.id || (a.id = F(a["2"]));
        c ||= this.ka(a["2"], b);
        if (!c)
            for (m in this.i) {
                l =
                    this.i[m];
                h = m;
                break
            }
        if (!c && !l) {
            if (f) return;
            l = new N(e, null, 0)
        } else if (!l)
            if (h = this.ma(c), l = this.i[h], !l) {
                if (f) return;
                l = new N(e, c, h);
                b = I(c);
                c = {
                    left: Math.max(0, b.left + 8),
                    top: Math.max(0, b.top + 8)
                };
                for (m in this.i)
                    if (m && m != h && (b = this.i[m], d(c, b.position))) {
                        for (c = 0; c < b.items.length; c++) l.L(b.items[c]);
                        this.U(m, !1);
                        break
                    } if (0 != h && this.i[0]) {
                    b = this.i[0];
                    for (c = 0; c < b.items.length; c++) l.L(b.items[c]);
                    this.U(0, !1)
                }
            } else {
                if (f) {
                    l.v();
                    return
                }
            }
        else if (f) {
            l.v();
            return
        }
        e.A[a.id] = a;
        l.L(a.id);
        l.m && g(l) && !this.l && (e.l =
            setInterval(function() {
                e.ha(l)
            }, 1200))
    };
    O.ha = function(a) {
        if (a && a.m) {
            var b = I(a.m);
            b && (a.position = {
                left: Math.max(0, b.left + 8),
                top: Math.max(0, b.top + 8)
            }, a.v());
            !b || 0 > b.left || 0 > b.top || (clearInterval(this.l), this.l = null)
        } else clearInterval(this.l), this.l = null
    };
    O.V = function(a, b) {
        var c = this,
            f = a.du,
            e = "";
        e = 60 > f ? parseInt(f) + " sec" : parseInt(f / 60) + " min " + (parseInt(f % 60) ? parseInt(f % 60) + " sec" : "");
        var h = {
            id: F(a["2"] + b["2"]),
            2: a["2"],
            3: b["2"],
            ig: a.ig,
            4: "MKV File " + y[a.ig] + ", " + e
        };
        setTimeout(function() {
            c.B(h, a.purl,
                null, !1)
        }, 2200)
    };
    O.X = function(a, b) {
        if ("https://www.youtube.com/" != window.location.href.toLowerCase() && ("video" != a.mme || y[a.ig])) {
            a.mode = b;
            for (b = 0; b < this.g.length; b++)
                if (a.ig == this.g[b].ig && (a.mK == this.g[b].mK || 2 > Math.abs(a.du - this.g[b].du))) return;
            a.used = !1;
            if ("video" == a.mme) {
                var c = null;
                for (b = 0; b < this.g.length; b++)
                    if ("audio" == this.g[b].mme && !this.g[b].used && (a.mK == this.g[b].mK || 2 > Math.abs(a.du - this.g[b].du))) {
                        this.g[b].used = !0;
                        c = this.g[b];
                        break
                    } if (!c)
                    for (b = 0; b < this.g.length; b++)
                        if ("audio" == this.g[b].mme &&
                            (a.mK == this.g[b].mK || 2 > Math.abs(a.du - this.g[b].du))) {
                            this.g[b].used = !0;
                            c = this.g[b];
                            break
                        } c && (a.used = !0, this.V(a, c))
            } else {
                c = null;
                for (b = 0; b < this.g.length; b++)
                    if ("video" == this.g[b].mme && 0 == this.g[b].used && (a.mK == this.g[b].mK || 2 > Math.abs(a.du - this.g[b].du))) {
                        this.g[b].used = !0;
                        c = this.g[b];
                        break
                    } c && (a.used = !0, this.V(c, a))
            }
            this.g.push(a)
        }
    };
    O.na = function(a) {
        var b = this;
        E({
            2: a,
            ba: function(c) {
                for (var f = ['"formats"', "adaptiveFormats"], e = 0; e < f.length; e++) {
                    var h = c,
                        l = h.indexOf(f[e]);
                    if (!(0 > l || -1 < h.indexOf("signatureCipher"))) {
                        h =
                            h.substr(l);
                        l = h.indexOf("[");
                        var m = h.indexOf("]");
                        if (0 > l || 0 > m || m <= l) break;
                        h = h.substr(l + 1, m - l - 1);
                        b.M(h, 1 == e)
                    }
                }
            }
        })
    };
    O.aa = function(a) {
        var b = this;
        switch (a[0]) {
            case 1:
                b.B(a[1], a[2], null, !0);
                break;
            case 3:
                var c = a[1];
                c && (b.ea = c);
                b.Ba();
                break;
            case 5:
                b.fa();
                break;
            case 7:
                b.M(a[1], a[2]);
                break;
            case 9:
                setTimeout(function() {
                    b.X(a[1], "BGH")
                }, 1400);
                break;
            case 11:
                b.resourceShelf && b.resourceShelf.reset();
                b.za();
                b.siteAdapters && b.siteAdapters.refresh();
                c = new URL(window.location.href);
                var f = c.pathname;
                if (!(0 <= c.hostname.toLowerCase().indexOf("youtube."))) {
                    setTimeout(function() {
                        b.da()
                    }, 2500);
                    break
                }
                0 ==
                    f.toLowerCase().indexOf("/watch") && b.na(a[1]);
                break;
            case 13:
                c = a[1];
                c != b.H && (b.H = c, b.fa());
                break;
            case 17:
                b.H = !0;
                b.showAllPanels();
                b.resourceShelf && b.resourceShelf.show();
                break;
            case 19:
                b.resourceShelf && b.resourceShelf.add(a[1]);
                break;
            case 15:
                alert("The browser extension can't connect to NDM. You can: \r\n1- Check that NDM is running.\r\n2- Hold down Delete and click the download link.\r\n3- Temporarily disable the NDM browser extension.")
        }
    };
    O.o = function(a) {
        var b = Array.prototype.slice.call(arguments);
        b[2] = b[2].bind(this);
        this.ja.push(b);
        a.addEventListener.apply(a, b.slice(1))
    };
    O.ra = function() {
        for (var a in this.i) this.i[a].K(!0)
    };
    O.za = function() {
        try {
            for (var a in this.i) this.i[a].j && clearTimeout(this.i[a].j), document.body.removeChild(this.i[a].h)
        } catch (b) {}
        this.i = {};
        this.updateMediaCount();
        this.A = {};
        this.g = [];
        this.l && clearInterval(this.l);
        this.l = null
    };
    O.fa = function() {
        try {
            for (var b in this.i) {
                var panel = this.i[b];
                if (panel && panel.render) panel.render();
                else if (panel && panel.h) panel.h.style.display = this.H ? "" : "none"
            }
        } catch (c) {}
    };
    O.ca = function() {
        this.port = chrome.runtime.connect({
            name: "neat"
        });
        this.port.onMessage.addListener(this.aa.bind(this));
        this.port.onDisconnect.addListener(this.ca.bind(this))
    };
    new P
};
