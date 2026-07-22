(function(root, factory) {
    var api = factory();
    if (typeof module === "object" && module.exports) module.exports = api;
    root.BetterNDMResourcePolicy = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function() {
    "use strict";

    var MIME_EXTENSIONS = {
        "application/pdf": "pdf",
        "application/epub+zip": "epub",
        "application/msword": "doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.ms-excel": "xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
        "application/vnd.ms-powerpoint": "ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "text/csv": "csv",
        "application/zip": "zip",
        "application/x-7z-compressed": "7z",
        "application/x-rar": "rar",
        "application/x-rar-compressed": "rar",
        "application/x-tar": "tar",
        "application/gzip": "gz",
        "application/x-gzip": "gz",
        "application/x-apple-diskimage": "dmg",
        "application/vnd.apple.installer+xml": "pkg",
        "application/x-newton-compatible-pkg": "pkg"
    };
    var TYPES = {
        pdf: ["document", "PDF"], epub: ["ebook", "EPUB"], mobi: ["ebook", "MOBI"], azw3: ["ebook", "AZW3"],
        doc: ["document", "Word"], docx: ["document", "Word"], rtf: ["document", "RTF"], txt: ["document", "TXT"],
        xls: ["spreadsheet", "Excel"], xlsx: ["spreadsheet", "Excel"], csv: ["spreadsheet", "CSV"],
        ppt: ["presentation", "PowerPoint"], pptx: ["presentation", "PowerPoint"],
        zip: ["archive", "ZIP"], rar: ["archive", "RAR"], "7z": ["archive", "7Z"], tar: ["archive", "TAR"], gz: ["archive", "GZ"], tgz: ["archive", "TGZ"],
        dmg: ["installer", "DMG"], pkg: ["installer", "PKG"]
    };
    var VOLATILE_QUERY_KEYS = /^(?:bytestart|byteend|range|rn|rbuf|sq|part|chunk|fragment|token|signature|sig|expires|policy|key-pair-id|googleaccessid|x-amz-.+)$/i;

    function rawValue(item, key, fallback) {
        return item && item[key] !== undefined && item[key] !== null ? item[key] : fallback;
    }

    function contentTypeFor(item) {
        return String(rawValue(item, "8", rawValue(item, "contentType", "")) || "").split(";", 1)[0].trim().toLowerCase();
    }

    function cleanFilename(value) {
        var name = String(value || "").trim();
        try { name = decodeURIComponent(name); } catch (_) {}
        name = name.split(/[?#]/, 1)[0].split("/").pop().trim();
        return name.replace(/[\u0000-\u001f]/g, "").slice(0, 220);
    }

    function filenameFor(item) {
        var explicit = cleanFilename(rawValue(item, "fileName", rawValue(item, "3", "")));
        if (explicit) return explicit;
        try { return cleanFilename(new URL(String(rawValue(item, "2", rawValue(item, "url", "")) || "")).pathname); }
        catch (_) { return ""; }
    }

    function extensionFor(item) {
        var explicit = String(rawValue(item, "fEx", rawValue(item, "extension", "")) || "").replace(/^\./, "").trim().toLowerCase();
        if (TYPES[explicit]) return explicit;
        var filename = filenameFor(item);
        var dot = filename.lastIndexOf(".");
        if (dot >= 0) {
            var fromName = filename.slice(dot + 1).toLowerCase();
            if (TYPES[fromName]) return fromName;
        }
        return MIME_EXTENSIONS[contentTypeFor(item)] || "";
    }

    function sizeFor(item) {
        return Number(rawValue(item, "fS", rawValue(item, "7", rawValue(item, "size", 0)))) || 0;
    }

    function resourceKey(item) {
        var raw = String(rawValue(item, "2", rawValue(item, "url", "")) || "");
        try {
            var parsed = new URL(raw);
            Array.from(parsed.searchParams.keys()).forEach(function(key) {
                if (VOLATILE_QUERY_KEYS.test(key)) parsed.searchParams.delete(key);
            });
            parsed.hash = "";
            return parsed.origin + parsed.pathname + (parsed.search ? parsed.search : "");
        } catch (_) {
            return raw.split("#", 1)[0];
        }
    }

    // Signed mirrors and viewer backends often expose the same file through
    // different hosts or paths. When filename, type, and a meaningful byte
    // size all agree, that is a stronger user-facing identity than the CDN URL.
    // Keep URL identity as the conservative fallback when metadata is sparse.
    function resourceIdentity(item) {
        var name = filenameFor(item).toLowerCase().replace(/\s+/g, " ");
        var extension = extensionFor(item);
        var size = sizeFor(item);
        if (name && extension && size >= 64 * 1024) {
            return ["file", extension, size, name].join(":");
        }
        return "url:" + String(item && item.resourceKey || resourceKey(item));
    }

    function candidateScore(item) {
        var score = 0;
        if (item && item.isAttachment) score += 10000;
        if (filenameFor(item)) score += 1000;
        var size = sizeFor(item);
        if (size) score += Math.min(900, Math.log(size) * 50);
        return score;
    }

    function candidateFromResponse(meta) {
        meta = meta || {};
        var requestType = String(meta.requestType || "");
        if (["object", "xmlhttprequest", "other", "sub_frame", "main_frame"].indexOf(requestType) < 0) return null;
        var extension = extensionFor(meta);
        if (!extension || !TYPES[extension]) return null;
        var url = String(rawValue(meta, "2", rawValue(meta, "url", "")) || "");
        if (!/^https?:\/\//i.test(url)) return null;
        var type = TYPES[extension];
        var name = filenameFor(meta) || (type[1] + " resource." + extension);
        if (name.toLowerCase().slice(-(extension.length + 1)) !== "." + extension) name += "." + extension;
        var host = "";
        try { host = new URL(url).hostname.replace(/^www\./i, ""); } catch (_) {}
        var candidate = {
            1: String(rawValue(meta, "1", "GET") || "GET"),
            2: url,
            6: "normal",
            7: sizeFor(meta),
            8: String(rawValue(meta, "8", rawValue(meta, "contentType", "")) || ""),
            fEx: extension,
            fS: sizeFor(meta),
            fileName: name,
            3: name,
            4: type[1] + " · " + name,
            resourceKey: resourceKey(meta),
            resourceKind: type[0],
            resourceTypeLabel: type[1],
            resourceHost: host,
            isAttachment: Boolean(meta.isAttachment)
        };
        candidate.resourceIdentity = resourceIdentity(candidate);
        return candidate;
    }

    function compactResources(items, limit) {
        // Pass 1 preserves the strongest response for one canonical URL even
        // when its partial range has a different byte count. Pass 2 then
        // collapses true mirrors across hosts using the stronger file identity.
        var bestByURL = Object.create(null);
        (items || []).forEach(function(item) {
            if (!item || !item.resourceKey) return;
            var current = bestByURL[item.resourceKey];
            if (!current || candidateScore(item) > candidateScore(current)) bestByURL[item.resourceKey] = item;
        });
        var best = Object.create(null);
        Object.keys(bestByURL).forEach(function(key) {
            var item = bestByURL[key];
            var identity = resourceIdentity(item);
            var current = best[identity];
            if (!current || candidateScore(item) > candidateScore(current)) best[identity] = item;
        });
        var result = Object.keys(best).map(function(key) { return best[key]; });
        result.sort(function(a, b) { return candidateScore(b) - candidateScore(a); });
        return result.slice(0, Math.max(1, Number(limit) || 12));
    }

    function formatSize(bytes) {
        if (!bytes || bytes < 1) return "";
        var units = ["B", "KB", "MB", "GB"];
        var value = bytes;
        var unit = 0;
        while (value >= 1024 && unit < units.length - 1) { value /= 1024; unit++; }
        return (value >= 10 || unit === 0 ? value.toFixed(0) : value.toFixed(1)) + " " + units[unit];
    }

    function describeResource(item) {
        return [item.resourceTypeLabel || String(item.fEx || "").toUpperCase(), formatSize(sizeFor(item)), item.resourceHost || ""].filter(Boolean).join(" · ");
    }

    return {
        candidateFromResponse: candidateFromResponse,
        compactResources: compactResources,
        contentTypeFor: contentTypeFor,
        describeResource: describeResource,
        extensionFor: extensionFor,
        filenameFor: filenameFor,
        formatSize: formatSize,
        resourceKey: resourceKey,
        resourceIdentity: resourceIdentity,
        sizeFor: sizeFor
    };
});
