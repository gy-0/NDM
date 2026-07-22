(function(root, factory) {
    var api = factory(root.NDMRelayResourcePolicy);
    if (typeof module === "object" && module.exports) module.exports = api;
    root.NDMRelayResourceShelf = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function(policy) {
    "use strict";

    function localText(zh, en) {
        return typeof navigator !== "undefined" && String(navigator.language || "").toLowerCase().indexOf("zh") === 0 ? zh : en;
    }

    function node(tag, className, textValue) {
        var element = document.createElement(tag);
        if (className) element.className = className;
        if (textValue !== undefined) element.textContent = textValue;
        return element;
    }

    function ResourceShelf(options) {
        this.options = options || {};
        this.items = [];
        this.expanded = false;
        this.host = null;
        this.shadow = null;
        this.mount();
    }

    ResourceShelf.prototype.mount = function() {
        if (typeof document === "undefined" || this.host) return;
        var host = node("div");
        host.id = "better-ndm-resource-shelf-host";
        host.style.cssText = "all:initial;display:none;position:fixed;right:16px;bottom:16px;z-index:2147483646;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;color-scheme:light dark";
        var shadow = host.attachShadow ? host.attachShadow({ mode: "open" }) : host;
        var style = node("style");
        style.textContent = [
            ":host{all:initial}",
            "*{box-sizing:border-box}",
            ".badge{appearance:none;border:1px solid rgba(60,60,67,.22);border-radius:10px;background:#f7f7f8;color:#202124;box-shadow:0 2px 8px rgba(0,0,0,.12);height:36px;padding:0 11px;display:flex;align-items:center;gap:8px;cursor:pointer;font:600 12px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}",
            ".badge:hover,.badge:focus-visible{background:#fff;outline:2px solid rgba(50,115,255,.5);outline-offset:2px}",
            ".badge-brand{font-weight:720;color:#1f66d1}.badge-count{color:#5f6368;font-weight:550}",
            ".panel{width:min(370px,calc(100vw - 32px));max-height:min(470px,calc(100vh - 68px));overflow:hidden;border:1px solid rgba(60,60,67,.22);border-radius:12px;background:#fafafa;color:#171719;box-shadow:0 8px 24px rgba(0,0,0,.18);display:none}",
            ".panel.open{display:block}",
            ".head{display:flex;align-items:center;padding:12px 12px 10px;gap:9px;border-bottom:1px solid rgba(60,60,67,.15)}",
            ".title{font-size:14px;font-weight:700;flex:1}.total{font-size:11px;color:#74747a}",
            ".close{appearance:none;border:0;border-radius:6px;background:transparent;color:#68686e;width:28px;height:28px;cursor:pointer;font-size:20px;line-height:1}.close:hover,.close:focus-visible{background:rgba(120,120,128,.12);outline:none}",
            ".list{padding:4px 10px 6px;overflow:auto;max-height:404px}",
            ".row{display:grid;grid-template-columns:34px minmax(0,1fr) auto;align-items:center;gap:10px;padding:10px 2px;border-bottom:1px solid rgba(60,60,67,.11)}",
            ".row:last-child{border-bottom:0}.row:hover{background:rgba(120,120,128,.055)}",
            ".file-icon{width:34px;color:#5f6368;display:grid;place-items:center;font-size:10px;font-weight:750;letter-spacing:.02em;text-transform:uppercase}",
            ".name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:13px;font-weight:650}.meta{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#77777d;font-size:11px;margin-top:3px}",
            ".download{appearance:none;border:0;border-radius:7px;background:#3478f6;color:white;height:30px;padding:0 10px;cursor:pointer;font:650 12px -apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif}.download:hover,.download:focus-visible{background:#2167e8;outline:2px solid rgba(52,120,246,.3);outline-offset:2px}",
            "@media(prefers-color-scheme:dark){.badge{background:#2c2c2e;color:#f3f3f4}.badge:hover{background:#353539}.badge-brand{color:#75a4ff}.badge-count{color:#b5b5ba}.panel{background:#262628;color:#f5f5f6}.meta,.total{color:#aaaab0}.file-icon{color:#b5b5ba}.row{border-bottom-color:rgba(235,235,245,.13)}}"
        ].join("");
        shadow.appendChild(style);
        this.badge = node("button", "badge");
        this.badge.type = "button";
        this.badge.addEventListener("click", this.show.bind(this));
        this.panel = node("section", "panel");
        this.panel.setAttribute("role", "dialog");
        this.panel.setAttribute("aria-label", localText("NDM 检测到的网页资源", "Resources detected by NDM"));
        shadow.appendChild(this.badge);
        shadow.appendChild(this.panel);
        (document.documentElement || document).appendChild(host);
        this.host = host;
        this.shadow = shadow;
        this.render();
    };

    ResourceShelf.prototype.add = function(item) {
        if (!item || !policy) return;
        this.items = policy.compactResources(this.items.concat([item]), 12);
        if (!this.host) this.mount();
        this.render();
    };

    ResourceShelf.prototype.render = function() {
        if (!this.host || !policy) return;
        this.host.style.display = this.items.length ? "block" : "none";
        while (this.badge.firstChild) this.badge.removeChild(this.badge.firstChild);
        this.badge.appendChild(node("span", "badge-brand", "NDM"));
        this.badge.appendChild(node("span", "badge-count", localText(this.items.length + " 项资源", this.items.length + " resource" + (this.items.length === 1 ? "" : "s"))));
        this.badge.setAttribute("aria-expanded", this.expanded ? "true" : "false");
        while (this.panel.firstChild) this.panel.removeChild(this.panel.firstChild);
        var head = node("div", "head");
        var heading = node("div", "");
        heading.appendChild(node("div", "title", localText("可下载资源", "Downloadable resources")));
        head.appendChild(heading);
        head.appendChild(node("div", "total", localText(this.items.length + " 项", this.items.length + " item" + (this.items.length === 1 ? "" : "s"))));
        var close = node("button", "close", "×");
        close.type = "button";
        close.setAttribute("aria-label", localText("收起资源面板", "Minimize resource panel"));
        close.addEventListener("click", this.hide.bind(this));
        head.appendChild(close);
        this.panel.appendChild(head);
        var list = node("div", "list");
        var shelf = this;
        this.items.forEach(function(item) {
            var row = node("div", "row");
            row.appendChild(node("div", "file-icon", String(item.fEx || "file").slice(0, 4)));
            var info = node("div", "");
            var name = node("div", "name", item.fileName || localText("未命名资源", "Unnamed resource"));
            name.title = item.fileName || "";
            info.appendChild(name);
            info.appendChild(node("div", "meta", policy.describeResource(item)));
            row.appendChild(info);
            var download = node("button", "download", localText("下载", "Download"));
            download.type = "button";
            download.setAttribute("aria-label", localText("使用 NDM 下载 ", "Download with NDM ") + (item.fileName || ""));
            download.addEventListener("click", function() {
                if (shelf.options.onDownload) shelf.options.onDownload(item);
            });
            row.appendChild(download);
            list.appendChild(row);
        });
        this.panel.appendChild(list);
        this.panel.classList.toggle("open", this.expanded);
        this.badge.style.display = this.expanded ? "none" : "flex";
    };

    ResourceShelf.prototype.show = function() { this.expanded = true; this.render(); };
    ResourceShelf.prototype.hide = function() { this.expanded = false; this.render(); };
    ResourceShelf.prototype.reset = function() { this.items = []; this.expanded = false; this.render(); };
    ResourceShelf.prototype.destroy = function() {
        if (this.host && this.host.parentNode) this.host.parentNode.removeChild(this.host);
        this.host = this.shadow = this.badge = this.panel = null;
        this.items = [];
    };

    function install(options) { return new ResourceShelf(options); }
    return { install: install, ResourceShelf: ResourceShelf };
});
