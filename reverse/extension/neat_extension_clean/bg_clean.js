/**
 * NeatDownloadManager Chrome Extension - Background Script
 * 
 * 功能：拦截浏览器下载请求并通过 WebSocket 发送到本地 NDM 客户端
 * 
 * 主要功能：
 * 1. WebSocket 连接到本地 NDM (ws://127.0.0.1:10007)
 * 2. webRequest API 监听网络请求，识别可下载的资源
 * 3. 右键菜单集成 - 通过 NDM 下载链接
 * 4. HLS/M3U8 流媒体解析
 * 5. 与内容脚本通信，显示媒体面板
 */

// ============================================
// 全局标志变量
// ============================================

/** 是否按下了 Delete 键（用于取消下载） */
let deleteKeyPressed = false;

// ============================================
// 正则表达式常量 - 用于匹配和解析
// ============================================

/** Content-Range 头格式正则：bytes 0-1023/1234 */
const contentRangeRegex = /^bytes [0-9]+-[0-9]+\/([0-9]+)$/;

/** 需要拦截的资源类型列表 */
const resourceTypes = [
    "object", "xmlhttprequest", "media", "other",
    "main_frame", "sub_frame", "image"
];

/** 可以下载的资源类型 */
const downloadableResourceTypes = ["object", "xmlhttprequest", "media", "other"];

/** 从 URL 中提取文件名的正则 */
const urlFilenameRegex = /:\/\/.+\/([^\/]+?(?:\.([^./]+?))?) (?= [?#]|$)/;

/** HTTP 重定向状态码 */
const redirectCodes = [301, 302, 303, 307, 308];

/** 强制下载的 MIME 类型 */
const forceDownloadTypes = /^(?:application\/x-apple-diskimage|application\/download|application\/force-download|application\/x-msdownload|binary\/octet-stream)$/i;

/** 媒体文件扩展名 */
const mediaExtensions = /^(?:FLV|SWF|MP3|MP4|M4V|F4F|F4V|M4A|MPG|MPEG|MPEG4|MPE|AVI|WMV|WMA|WAV|WAVE|ASF|RM|RAM|OGG|OGV|OGM|OGA|MOV|MID|MIDI|3GP|3GPP|QT|WEBM|TS|MKV|AAC|MP2T|MPEGTS|RMVB|VTT|SRT)$/i;

/** 非下载类型的文件扩展名（网页、图片、字体等） */
const nonDownloadExtensions = /^(?:HTM|HTML|MHT|MHTML|SHTML|SHTM|XHT|XHTM|XHTML|XML|TXT|CSS|JS|JSON|GIF|ICO|JPEG|JPG|PNG|WEBP|BMP|SVG|TIF|TIFF|PDF|PHP|ASP|ASPX|EOT|TTF|WOF|WOFF|WOFF2|MSG|PEM|BR|OTF|ACZ|AZC|CGI|TPL|OSD|M3U8|DO|DICT)$/i;

/** 传统媒体格式（旧版视频格式） */
const legacyMediaFormats = /^(?:FLV|AVI|MPG|MPE|WMV|QT|MOV|RM|RAM|WMA|MID|MIDI|AAC|MKV|RMVB)$/i;

/** 流式传输段格式（如 F4F、TS 等分段视频） */
const streamSegmentFormats = /^(?:F4F|MPEGTS|TS|MP2T)$/i;

/** MIME 类型到文件扩展名的映射表 */
const mimeToExtension = {
    "application/x-apple-diskimage": "DMG",
    "application/cert-chain+cbor": "MSG",
    "application/epub+zip": "EPUB",
    "application/java-archive": "JAR",
    "video/x-matroska": "MKV",
    "text/html": "HTML|HTM",
    "text/css": "CSS",
    "text/javascript": "JS|JSON",
    "text/mspg-legacyinfo": "MSI|MSP",
    "text/plain": "TXT|SRT",
    "text/srt": "SRT",
    "text/vtt": "VTT|SRT",
    "text/xml": "XML|F4M|TTML",
    "text/x-javascript": "JS|JSON",
    "text/x-json": "JSON",
    "application/f4m+xml": "F4M",
    "application/gzip": "GZ",
    "application/javascript": "JS",
    "application/json": "JSON",
    "application/msword": "DOC|DOCX|DOT|DOTX",
    "application/pdf": "PDF",
    "application/ttaf+xml": "DFXP",
    "application/vnd.apple.mpegurl": "M3U8",
    "application/zip": "ZIP",
    "application/x-7z-compressed": "7Z",
    "application/x-aim": "PLJ",
    "application/x-compress": "Z",
    "application/x-compress-7z": "7Z",
    "application/x-compressed": "ARJ",
    "application/x-gtar": "TAR",
    "application/x-msi": "MSI",
    "application/x-msp": "MSP",
    "application/x-gzip": "GZ",
    "application/x-gzip-compressed": "GZ",
    "application/x-javascript": "JS",
    "application/x-mpegurl": "M3U8",
    "application/x-msdos-program": "EXE|DLL",
    "application/vnd.apple.installer+xml": "MPKG",
    "application/x-ole-storage": "MSI|MSP",
    "application/x-rar": "RAR",
    "application/x-rar-compressed": "RAR",
    "application/x-sdlc": "EXE|SDLC",
    "application/x-shockwave-flash": "SWF",
    "application/x-silverlight-app": "XAP",
    "application/x-subrip": "SRT",
    "application/x-tar": "TAR",
    "application/x-zip": "ZIP",
    "application/x-zip-compressed": "ZIP",
    "video/3gpp": "3GP|3GPP",
    "video/3gpp2": "3GP|3GPP",
    "video/avi": "AVI",
    "video/f4f": "F4F",
    "video/f4m": "F4M",
    "video/flv": "FLV",
    "video/mp2t": "TS|M3U8",
    "video/mp4": "MP4|M4V",
    "video/mpeg": "MPG|MPEG|MPE",
    "video/mpegurl": "M3U8|M3U",
    "video/mpg4": "MP4|M4V",
    "video/msvideo": "AVI",
    "video/quicktime": "MOV|QT",
    "video/webm": "WEBM",
    "video/x-flash-video": "FLV",
    "video/x-flv": "FLV",
    "video/x-mp4": "MP4|M4V",
    "video/x-mpegurl": "M3U8|M3U",
    "video/x-mpg4": "MP4|M4V",
    "video/x-ms-asf": "ASF",
    "video/x-ms-wmv": "WMV",
    "video/x-msvideo": "AVI",
    "audio/3gpp": "3GP|3GPP",
    "audio/3gpp2": "3GP|3GPP",
    "audio/mp3": "MP3",
    "audio/mp4": "M4A|MP4",
    "audio/mp4a-latm": "M4A|MP4",
    "audio/mpeg": "MP3",
    "audio/mpeg4-generic": "M4A|MP4",
    "audio/mpegurl": "M3U8|M3U",
    "image/svg+xml": "SVG|SVGZ",
    "audio/webm": "WEBM",
    "audio/wav": "WAV",
    "audio/x-mpeg": "MP3",
    "audio/x-mpegurl": "M3U8|M3U",
    "audio/x-ms-wma": "WMA",
    "audio/x-wav": "WAV",
    "ilm/tm": "MP3",
    "image/gif": "GIF|GFA",
    "image/icon": "ICO|CUR",
    "image/jpg": "JPG|JPEG",
    "image/jpeg": "JPG|JPEG",
    "image/png": "PNG|APNG",
    "image/tiff": "TIF|TIFF",
    "image/vnd.microsoft.icon": "ICO|CUR",
    "image/webp": "WEBP",
    "image/x-icon": "ICO|CUR",
    "flv-application/octet-stream": "FLV",
    "image/x-xbitmap": "XBM",
    "audio/x-mp3": "MP3",
    "audio/x-hx-aac-adts": "AAC",
    "audio/aac": "AAC",
    "audio/x-aac": "AAC",
    "application/vnd.rn-realmedia-vbr": "RMVB"
};

// ============================================
// 工具函数
// ============================================

/**
 * 解析 Content-Type 头，提取 MIME 类型
 * @param {string} contentType - Content-Type 头值
 * @returns {string} 清理后的 MIME 类型
 */
function parseContentType(contentType) {
    return contentType && unescape(contentType.split(";", 1).shift().trim()) || "";
}

/**
 * 从 URL 中提取文件名
 * @param {string} url - URL 地址
 * @returns {string} 文件名
 */
function extractFilenameFromUrl(url) {
    const match = urlFilenameRegex.exec(url);
    return match ? match[1] || "" : "";
}

/**
 * 获取文件扩展名
 * @param {string} filename - 文件名
 * @returns {string} 扩展名（不含点）
 */
function getFileExtension(filename) {
    return filename.indexOf(".") > -1 ? filename.split(".").pop() : "";
}

/**
 * 根据扩展名查找对应的 MIME 类型
 * @param {string} ext - 文件扩展名
 * @returns {string} MIME 类型
 */
function findMimeByExtension(ext) {
    const upperExt = ext.toUpperCase();
    for (const mime in mimeToExtension) {
        if (mimeToExtension[mime].split("|").indexOf(upperExt) > -1) {
            return mime;
        }
    }
    return "";
}

/**
 * 在请求/响应头中查找指定名称的头部值
 * @param {Array} headers - 头部数组
 * @param {string} name - 头部名称
 * @returns {string|null} 头部值
 */
function findHeader(headers, name) {
    if (!headers) return null;
    for (let i = 0; i < headers.length; i++) {
        if (headers[i].name.toLowerCase() === name.toLowerCase()) {
            return headers[i].value || headers[i].binaryValue || null;
        }
    }
    return null;
}

/**
 * 合并多个对象
 * @param {...Object} objects - 要合并的对象
 * @returns {Object} 合并后的对象
 */
function mergeObjects() {
    const result = {};
    for (let i = 0; i < arguments.length; i++) {
        const obj = arguments[i];
        for (const key in obj) {
            if (obj.hasOwnProperty(key)) {
                result[key] = obj[key];
            }
        }
    }
    return result;
}

/**
 * 检查字符串是否以指定前缀开头
 * @param {string} str - 原字符串
 * @param {string} prefix - 前缀
 * @returns {boolean}
 */
function startsWith(str, prefix) {
    return str && prefix && str.indexOf(prefix) === 0;
}

/**
 * 检查字符串是否以指定后缀结尾
 * @param {string} str - 原字符串
 * @param {string} suffix - 后缀
 * @returns {boolean}
 */
function endsWith(str, suffix) {
    if (!str || !suffix) return false;
    const index = str.length - suffix.length;
    return index >= 0 && str.indexOf(suffix, index) === index;
}

/**
 * 检查字符串是否包含指定子串
 * @param {string} str - 原字符串
 * @param {string} substring - 子串
 * @returns {boolean}
 */
function contains(str, substring) {
    return str && substring && str.indexOf(substring) >= 0;
}

/**
 * 获取 URL 的协议部分
 * @param {string} url - URL
 * @returns {string} 协议（如 http, https, ftp）
 */
function getProtocol(url) {
    return contains(url, "://") ? url.split("://", 1).shift().toLowerCase() || "" : "http";
}

/**
 * 获取 URL 参数值
 * @param {string} str - 包含参数的字符串（如 Content-Type 头）
 * @param {string} name - 参数名
 * @returns {string|null} 参数值
 */
function getUrlParam(str, name) {
    if (!str) return null;
    const lowerName = name.toLowerCase();
    const parts = str.split(";");
    parts.shift(); // 移除第一部分（主值）
    
    for (let i = 0; i < parts.length; i++) {
        const part = parts[i];
        const eqIndex = part.indexOf("=");
        
        if (eqIndex > 0) {
            let key = part.substr(0, eqIndex).trim().toLowerCase();
            const hasStar = key[key.length - 1] === "*";
            if (hasStar) {
                key = key.substr(0, key.length - 1).trimRight();
            }
            
            if (key === lowerName) {
                let value = part.substr(eqIndex + 1).trim();
                const lastChar = value.length - 1;
                if (value[0] === '"' && value[lastChar] === '"') {
                    value = value.substring(1, lastChar);
                }
                if (hasStar) {
                    value = value.split("'", 3).pop();
                }
                return unescape(value);
            }
        } else if (eqIndex < 0 && part.trim().toLowerCase() === lowerName) {
            return "";
        }
    }
    return null;
}

/**
 * 提取 POST 请求数据
 * @param {Object} requestBody - Chrome webRequest 的 requestBody 对象
 * @param {string} contentType - Content-Type 头
 * @returns {string|null} POST 数据字符串
 */
function extractPostData(requestBody, contentType) {
    if (!requestBody) return null;
    
    // 处理原始数据（raw bytes）
    const raw = requestBody.raw;
    if (raw) {
        let result = "";
        for (let i = 0; i < raw.length; i++) {
            const bytes = raw[i].bytes;
            if (!bytes) return null;
            const arr = new Uint8Array(bytes);
            for (let j = 0; j < arr.length; j++) {
                result += String.fromCharCode(arr[j]);
            }
        }
        return result;
    }
    
    // 处理表单数据
    const formData = requestBody.formData;
    if (!formData) return null;
    
    const parsedContentType = parseContentType(contentType);
    const lowerContentType = parsedContentType && parsedContentType.toLowerCase();
    const result = [];
    
    if (lowerContentType === "application/x-www-form-urlencoded") {
        // URL 编码表单
        for (const key in formData) {
            const values = formData[key];
            const encodedKey = key.split(" ").map(encodeURIComponent).join("+");
            for (let i = 0; i < values.length; i++) {
                if (result.length) result.push("&");
                result.push(encodedKey, "=", values[i].split(" ").map(encodeURIComponent).join("+"));
            }
        }
        return result.join("");
    } else if (lowerContentType === "multipart/form-data") {
        // 多部分表单
        let boundary = getUrlParam(contentType, "boundary");
        if (!boundary) {
            boundary = "----WebKitFormBoundary" + Math.random().toString(36).substr(2);
        }
        for (const key in formData) {
            const values = formData[key];
            for (let i = 0; i < values.length; i++) {
                result.push("--", boundary, '\r\nContent-Disposition: form-data; name="', key, '"\r\n\r\n', values[i], "\r\n");
            }
        }
        result.push("--", boundary, "--\r\n");
        return result.join("");
    }
    
    return null;
}

/**
 * 异步获取资源内容
 * @param {Object} target - 包含 URL 和回调的对象
 * @param {Object} requestInfo - 请求信息对象
 */
async function fetchResourceContent(target, requestInfo) {
    let postBody = null;
    const headers = {};
    const method = requestInfo && requestInfo["1"] || "GET";
    
    // 添加自定义 X- 头部
    if (requestInfo && requestInfo.o) {
        const requestHeaders = requestInfo.o;
        for (let i = 0; i < requestHeaders.length; i++) {
            if (startsWith(requestHeaders[i].name.toLowerCase(), "x-")) {
                headers[requestHeaders[i].name] = requestHeaders[i].value;
            }
        }
    }
    
    // 处理 POST 请求
    if (method === "POST" && requestInfo) {
        try {
            processPostData(requestInfo, requestInfo);
            if (requestInfo["10"]) {
                headers["Content-Type"] = requestInfo["10"];
            }
        } catch (e) {}
        if (requestInfo && requestInfo.postData) {
            postBody = requestInfo.postData;
        }
    }
    
    try {
        const response = await fetch(target["2"], {
            method: method,
            credentials: "include",
            headers: new Headers(headers),
            body: postBody
        });
        
        if (response.ok) {
            const text = await response.text();
            if (target.S) target.S(text);
        }
    } catch (e) {}
}

/**
 * 处理 POST 请求数据
 * @param {Object} source - 源请求对象
 * @param {Object} target - 目标请求对象
 */
function processPostData(source, target) {
    const contentType = findHeader(source.o, "Content-Type");
    const contentDisposition = findHeader(source.o, "Content-Disposition");
    let postData = extractPostData(source.ja, contentType);
    
    if (!postData || postData.length < 1) {
        postData = null;
    }
    
    target.postData = postData;
    if (contentType) target["10"] = contentType.trim();
    if (contentDisposition) target["11"] = contentDisposition.trim();
}

/**
 * 复制自定义 X- 头部到下载请求
 * @param {Object} source - 源请求对象
 * @param {Object} target - 目标请求对象
 */
function copyCustomHeaders(source, target) {
    if (source.o) {
        for (let i = 0; i < source.o.length; i++) {
            if (startsWith(source.o[i].name.toLowerCase(), "x-")) {
                target[source.o[i].name] = source.o[i].value;
            }
        }
    }
}

// ============================================
// DownloadRequest 类 - 表示一个下载请求
// ============================================

/**
 * DownloadRequest 类
 * 
 * 属性说明（使用数字键名保持与原始代码兼容）：
 * ["1"] - HTTP 方法 (GET/POST)
 * ["2"] - URL
 * ["3"] - 文件名
 * ["4"] - 页面标题
 * ["5"] - Referer/来源页面 URL
 * ["6"] - 下载类型 (normal/media/hls)
 * ["7"] - 文件大小（字节）
 * ["8"] - Content-Type
 * ["9"] - 用户代理（User-Agent）
 * ["10"] - Content-Type（请求头）
 * ["11"] - Content-Disposition
 * cookies - Cookie 字符串
 * postData - POST 数据
 */
function DownloadRequest() {
    this["1"] = "GET";          // method
    this["2"] = "";             // url
    this["3"] = "";             // filename
    this["4"] = "";             // pageTitle
    this["5"] = "";             // referer
    this["6"] = "normal";       // downloadType
    this["7"] = 0;              // fileSize
    this["8"] = "";             // contentType
    this["9"] = "";             // userAgent
    this["10"] = "";            // requestContentType
    this["11"] = "";            // contentDisposition
    this.cookies = "";          // cookies
    this.postData = null;       // postData
}

// ============================================
// HlsParser 类 - 解析 M3U8/HLS 流媒体
// ============================================

/**
 * HlsParser 类 - 解析 M3U8 播放列表文件
 * 
 * HLS (HTTP Live Streaming) 是 Apple 开发的流媒体协议，
 * 使用 M3U8 播放列表文件描述媒体段。
 */
function HlsParser(manager) {
    this.manager = manager;
}

const HlsParserProto = HlsParser.prototype;

/**
 * 解析 EXT-X-STREAM-INF 标签中的属性
 * @param {string} tags - 标签字符串
 * @returns {string} 格式化的带宽和分辨率信息
 */
HlsParserProto.parseStreamInfo = function(tags) {
    let result = "";
    if (!tags) return result;
    
    const parts = tags.split(",");
    if (!parts || !parts.length) return result;
    
    for (let i = 0; i < parts.length; i++) {
        const kv = parts[i].split("=");
        if (kv && kv.length === 2) {
            const key = kv[0].toString().trim();
            if (key === "BANDWIDTH") {
                result += parseInt(parseInt(kv[1]) / 1024) + " Kbps ";
            }
            if (key === "RESOLUTION") {
                result += kv[1] + " ";
            }
        }
    }
    return result.trim();
};

/**
 * 解析 M3U8 内容
 * @param {Object} baseRequest - 基础请求对象
 * @param {string} content - M3U8 文件内容
 */
HlsParserProto.parse = function(baseRequest, content) {
    const streams = [];
    let duration = 0;
    let segmentUrl = "";
    const parser = this;
    
    const lines = content.split(/[\r\n]+/);
    if (lines.length === 0 || lines[0].trim() !== "#EXTM3U") {
        return; // 不是有效的 M3U8 文件
    }
    
    let hasExtInf = false;
    let hasStreamInf = false;
    let hasByteRange = false;
    let currentTags = "";
    const tagPattern = /^#(EXT[^\s:]+)(?::(.*))/;
    
    for (let i = 1; i < lines.length; i++) {
        const line = lines[i].trim();
        if (!line) continue;
        
        if (line[0] === "#") {
            // 处理 EXT 标签
            if (line.indexOf("#EXT") === 0) {
                const match = tagPattern.exec(line);
                if (match) {
                    if (!hasExtInf && match[1] === "EXTINF") {
                        hasExtInf = true;
                        currentTags = match[2];
                    }
                    if (!hasStreamInf && match[1] === "EXT-X-STREAM-INF") {
                        hasStreamInf = true;
                        currentTags = match[2];
                    }
                    if (!hasByteRange) {
                        hasByteRange = (match[1] === "EXT-X-BYTERANGE");
                    }
                }
            }
        } else {
            // 处理媒体段 URL
            if (hasExtInf) {
                duration += parseFloat(currentTags);
                hasExtInf = false;
            }
            if (hasStreamInf) {
                streams.push({
                    "2": new URL(line, baseRequest["2"]).href,
                    tags: currentTags
                });
                hasStreamInf = false;
            }
            if (hasByteRange && !segmentUrl) {
                segmentUrl = new URL(line, baseRequest["2"]).href;
            }
        }
    }
    
    // 处理字节范围流（单个 TS 文件）
    if (segmentUrl) {
        let durationStr = "";
        if (duration) {
            if (duration > 60) {
                durationStr += parseInt(duration / 60) + " min ";
            }
            durationStr += parseInt(duration % 60) && parseInt(duration % 60) + " sec";
        }
        
        let downloadRequest = {
            "6": "media",
            fEx: "ts",
            "4": "TS File " + durationStr,
            fDu: durationStr
        };
        downloadRequest = mergeObjects(downloadRequest, {
            "1": baseRequest["1"],
            "2": segmentUrl,
            tabId: baseRequest.tabId,
            frameId: baseRequest.frameId,
            fS: baseRequest["7"],
            fileName: baseRequest.fileName
        });
        
        copyCustomHeaders(baseRequest, downloadRequest);
        if (downloadRequest["1"] === "POST") {
            processPostData(baseRequest, downloadRequest);
        }
        
        setTimeout(function() {
            parser.manager.addDownload(downloadRequest);
        }, 2500);
    } else if (streams.length) {
        // 处理多码率流
        setTimeout(function() {
            for (let i = 0; i < streams.length; i++) {
                parser.manager.addDownload(mergeObjects({
                    tabId: baseRequest.tabId,
                    frameId: baseRequest.frameId
                }, {
                    "1": "GET",
                    "2": streams[i]["2"],
                    "6": "hls",
                    fEx: "ts",
                    "4": "TS File " + parser.parseStreamInfo(streams[i].tags)
                }));
            }
        }, 2500);
    } else if (duration > 0) {
        // 只有时长信息（可能是主播放列表）
        let durationStr = "";
        if (duration > 60) {
            durationStr += parseInt(duration / 60) + " min ";
        }
        durationStr += parseInt(duration % 60) && parseInt(duration % 60) + " sec";
        
        let downloadRequest = {
            "6": "hls",
            fEx: "ts",
            "4": "TS File " + durationStr,
            fDu: durationStr
        };
        downloadRequest = mergeObjects(downloadRequest, {
            "1": baseRequest["1"],
            "2": baseRequest["2"],
            tabId: baseRequest.tabId,
            frameId: baseRequest.frameId,
            fS: baseRequest["7"],
            fileName: baseRequest.fileName
        });
        
        copyCustomHeaders(baseRequest, downloadRequest);
        if (downloadRequest["1"] === "POST") {
            processPostData(baseRequest, downloadRequest);
        }
        
        setTimeout(function() {
            parser.manager.addDownload(downloadRequest);
        }, 2500);
    }
};

// ============================================
// DownloadManager 类 - 下载管理器主类
// ============================================

/**
 * DownloadManager 类 - 管理下载拦截和 WebSocket 通信
 * 
 * 主要功能：
 * 1. 监听 Chrome webRequest API 事件拦截下载
 * 2. 通过 WebSocket 与本地 NDM 客户端通信
 * 3. 管理右键菜单和浏览器工具栏按钮
 * 4. 与内容脚本通信显示媒体面板
 */
function DownloadManager() {
    // 绑定所有方法到实例
    const proto = this.constructor.prototype;
    for (const key in proto) {
        this[key] = proto[key].bind(this);
    }
    
    // 连接的内容脚本端口
    this.ports = {};
    
    // 待处理的请求（按 requestId）
    this.pendingRequests = {};
    
    // 标签页框架到端口的映射
    this.tabFramePorts = {};
    
    // 端口 ID 计数器
    this.portIdCounter = 1;
    
    // 当前待发送到 NDM 的下载请求
    this.currentDownload = "";
    
    // 是否等待服务器响应（用于 HEAD 请求优化）
    this.waitingForServer = false;
    
    // WebSocket 连接
    this.ws = null;
    
    // 是否已连接
    this.isConnected = false;
    
    // 下载拦截是否启用
    this.catchingEnabled = false;
    
    // 媒体面板是否显示
    this.showMediaPanel = false;
    
    // 注册事件监听器
    this.registerEventListeners();
    
    // 初始化工具栏按钮
    this.toggleCatching();
    
    // 加载设置
    this.loadSettings();
    
    // 初始化 WebSocket 连接
    this.initWebSocket();
    
    // 注册运行时消息监听
    this.registerRuntimeMessages();
}

const DownloadManagerProto = DownloadManager.prototype;

/**
 * 注册 Chrome 事件监听器
 */
DownloadManagerProto.registerEventListeners = function() {
    // 创建右键菜单
    chrome.contextMenus.removeAll();
    chrome.contextMenus.create({
        title: "Download by NeatDownloadManager",
        id: "NDM_CtxMenu",
        contexts: ["link", "image"]
    });
    
    // 监听菜单点击
    this.addListener(chrome.contextMenus.onClicked, this.onContextMenuClicked);
    
    // 监听浏览器下载事件
    this.addListener(chrome.downloads.onCreated, this.onDownloadCreated);
    
    // 监听内容脚本连接
    this.addListener(chrome.runtime.onConnect, this.onPortConnected);
    
    // 监听网络请求
    this.addListener(chrome.webRequest.onBeforeRequest, this.onBeforeRequest, 
        { urls: ["http://*/*", "https://*/*", "ftp://*/*"], types: resourceTypes }, 
        ["requestBody"]);
    
    this.addListener(chrome.webRequest.onBeforeSendHeaders, this.onBeforeSendHeaders,
        { urls: ["https://*/*", "http://*/*"], types: resourceTypes },
        ["requestHeaders"]);
    
    this.addListener(chrome.webRequest.onHeadersReceived, this.onHeadersReceived,
        { urls: ["<all_urls>"], types: resourceTypes },
        ["responseHeaders"]);
    
    this.addListener(chrome.webRequest.onCompleted, this.onRequestCompleted,
        { urls: ["<all_urls>"] });
    
    this.addListener(chrome.webRequest.onErrorOccurred, this.onRequestCompleted,
        { urls: ["<all_urls>"] });
    
    // 监听历史状态更新（SPA 页面导航）
    this.addListener(chrome.webNavigation.onHistoryStateUpdated, this.onHistoryStateUpdated);
    
    // 工具栏按钮点击
    chrome.action.onClicked.addListener(this.toggleCatching);
};

/**
 * 添加事件监听器（辅助函数）
 * @param {Object} event - Chrome 事件对象
 * @param {Function} listener - 监听器函数
 * @param {Object} filter - 过滤器（可选）
 * @param {Array} extraInfo - 额外信息（可选）
 */
DownloadManagerProto.addListener = function(event, listener, filter, extraInfo) {
    const args = [listener];
    if (filter) args.push(filter);
    if (extraInfo) args.push(extraInfo);
    event.addListener.apply(event, args);
};

/**
 * 切换下载拦截开关
 */
DownloadManagerProto.toggleCatching = function() {
    this.catchingEnabled = !this.catchingEnabled;
    const badgeText = this.catchingEnabled ? "" : "Off";
    chrome.action.setTitle({
        title: this.catchingEnabled ? "" : "Download catcher is Off\r\nClick to toggle catching"
    });
    chrome.action.setBadgeText({ text: badgeText });
};

/**
 * 监听历史状态更新（处理 SPA）
 * @param {Object} details - 导航详情
 */
DownloadManagerProto.onHistoryStateUpdated = function(details) {
    const port = this.tabFramePorts[[details.tabId, details.frameId]];
    if (port && port["2"] !== details.url) {
        port.postMessage([11, details.url]);
        port["2"] = details.url;
    }
};

/**
 * 监听浏览器下载事件
 * @param {Object} downloadItem - 下载项
 */
DownloadManagerProto.onDownloadCreated = function(downloadItem) {
    if (deleteKeyPressed || !this.catchingEnabled) {
        this.currentDownload = "";
        return;
    }
    
    if (this.currentDownload !== downloadItem.finalUrl && this.currentDownload !== downloadItem.url) {
        this.currentDownload = "";
        return;
    }
    
    // 取消浏览器默认下载，使用 NDM
    this.currentDownload = "";
    chrome.downloads.cancel(downloadItem.id);
    chrome.downloads.erase({ id: downloadItem.id });
};

/**
 * 发送下载请求到 NDM
 * @param {Object} request - 下载请求对象
 */
DownloadManagerProto.sendToNDM = async function(request) {
    if (!this.isConnected) {
        // 未连接，暂存请求
        this.pendingRequest = request;
        this.initWebSocket();
        return;
    }
    
    // 构建 NDM 协议消息
    let message = "1:" + request["1"] + "\r\n";
    message += "2:" + request["2"] + "\r\n";
    
    if (request["3"]) {
        message += "3:" + request["3"] + "\r\n";
    }
    
    message += "6:" + (request["6"] || "normal") + "\r\n";
    
    if (request["4"]) {
        message += "4:" + request["4"] + "\r\n";
    }
    
    // 添加 Origin
    if (request.pageUrl) {
        let pageUrl = request.pageUrl;
        let origin = "";
        pageUrl &&= pageUrl.trim();
        if (pageUrl) {
            origin = new URL(pageUrl).origin;
        }
        message += "Origin: " + origin + "\r\n";
    }
    
    // 添加 Referer
    if (request.pageUrl) {
        let referer = request.pageUrl;
        const hashIndex = referer.lastIndexOf("#");
        if (hashIndex < 0 || hashIndex < referer.indexOf("?")) {
            // 保留完整 URL
        } else {
            referer = referer.substr(0, hashIndex);
        }
        message += "Referer: " + referer + "\r\n";
    }
    
    if (request["5"]) {
        message += "5:" + request["5"] + "\r\n";
    }
    
    if (request.cookies) {
        message += "Cookie: " + request.cookies + "\r\n";
    }
    
    if (request["10"]) {
        message += "Content-Type: " + request["10"] + "\r\n";
    }
    
    if (request["11"]) {
        message += "Content-Disposition: " + request["11"] + "\r\n";
    }
    
    if (request["9"]) {
        message += "9:" + request["9"] + "\r\n";
    }
    
    // 添加自定义 X- 头部
    for (const key in request) {
        if (startsWith(key.toLowerCase(), "x-")) {
            message += key + ": " + request[key] + "\r\n";
        }
    }
    
    // 处理 POST 数据
    if (request["1"] === "POST") {
        if (request["7"]) {
            message += "7:" + request["7"] + "\r\n";
        }
        if (request["8"]) {
            message += "8:" + request["8"] + "\r\n";
        }
        if (request.postData) {
            message += "__0NeatPostData9__:" + request.postData;
        } else {
            message += "Content-Length: 0\r\n";
        }
    }
    
    // 检查消息大小限制（约 116KB）
    if (message.length > 118784) {
        return;
    }
    
    // 如果有文件名，直接发送
    if (request["3"]) {
        this.ws.send(message);
        this.pendingRequest = null;
        return;
    }
    
    // POST 请求或非等待模式，直接发送
    if (request["1"] === "POST" || !this.waitingForServer || (request["7"] && request["8"])) {
        if (request["1"] !== "POST" && this.waitingForServer) {
            message += "8:" + request["8"] + "\r\n";
            message += "7:" + request["7"] + "\r\n";
        }
        this.ws.send(message);
        this.pendingRequest = null;
        return;
    }
    
    // 发送 HEAD 请求获取文件信息
    try {
        const response = await fetch(request["2"], {
            method: "HEAD",
            credentials: "include"
        });
        
        if (response.ok) {
            request["8"] = request["8"] || response.headers.get("content-type") || "";
            request["7"] = request["7"] || response.headers.get("Content-Length") || 0;
            message += "8:" + request["8"] + "\r\n";
            message += "7:" + request["7"] + "\r\n";
            this.ws.send(message);
            this.pendingRequest = null;
        }
    } catch (e) {}
};

/**
 * 初始化 WebSocket 连接
 */
DownloadManagerProto.initWebSocket = function() {
    const ws = new WebSocket("ws://127.0.0.1:10007/download", "neatextension.v1");
    ws.onopen = this.onWebSocketOpen;
    ws.onclose = this.onWebSocketClose;
    ws.onmessage = this.onWebSocketMessage;
    ws.onerror = this.onWebSocketError;
    this.ws = ws;
};

/**
 * WebSocket 连接打开
 */
DownloadManagerProto.onWebSocketOpen = function() {
    this.isConnected = true;
    if (this.pendingRequest) {
        this.sendToNDM(this.pendingRequest);
    }
};

/**
 * WebSocket 连接关闭
 */
DownloadManagerProto.onWebSocketClose = function() {
    this.isConnected = false;
    this.pendingRequest = null;
};

/**
 * 接收 WebSocket 消息
 * @param {MessageEvent} event - 消息事件
 */
DownloadManagerProto.onWebSocketMessage = function(event) {
    const data = event.data;
    
    if (data === "waiting") {
        this.waitingForServer = true;
    } else if (data === "nowaiting") {
        this.waitingForServer = false;
    } else if (!contains(data, "Version") && startsWith(data, "ShowPanelChrome")) {
        const showPanel = data.split("=")[1] === "1";
        if (showPanel !== this.showMediaPanel) {
            this.showMediaPanel = showPanel;
            chrome.storage.local.set({ showMediaPanelFlag: showPanel ? 1 : -1 }, function() {});
            this.broadcastToAllPorts([13, this.showMediaPanel]);
        }
    }
};

/**
 * WebSocket 错误
 */
DownloadManagerProto.onWebSocketError = function() {
    this.isConnected = false;
    
    if (this.pendingRequest) {
        const manager = this;
        chrome.tabs.query({ currentWindow: true, active: true }, function(tabs) {
            if (tabs && tabs.length) {
                const port = manager.tabFramePorts[[tabs[0].id, 0]];
                if (port) {
                    port.postMessage([15]); // 通知 NDM 未运行
                }
            }
        });
    }
    
    this.pendingRequest = null;
};

/**
 * 设置 Cookie 并发送下载请求
 * @param {Array} cookies - Cookie 数组
 */
DownloadManagerProto.setCookiesAndSend = function(cookies) {
    if (!this.pendingRequest) return;
    
    let cookieStr = "";
    if (cookies && cookies.length > 0) {
        for (let i = 0; i < cookies.length; i++) {
            cookieStr += cookies[i].name + "=" + cookies[i].value;
            if (i < cookies.length - 1) {
                cookieStr += "; ";
            }
        }
    }
    cookieStr = cookieStr.trim();
    
    this.pendingRequest.cookies = cookieStr;
    this.sendToNDM(this.pendingRequest);
};

/**
 * 右键菜单点击处理
 * @param {Object} info - 菜单信息
 * @param {Object} tab - 标签页
 */
DownloadManagerProto.onContextMenuClicked = function(info, tab) {
    const protocol = getProtocol(info.linkUrl);
    
    if (!protocol) return;
    if (protocol !== "ftp" && protocol !== "http" && protocol !== "https") return;
    if (protocol === "ftp" && !extractFilenameFromUrl(info.linkUrl)) return;
    
    const request = new DownloadRequest();
    request["2"] = info.linkUrl || info.srcUrl;
    request.pageUrl = info.pageUrl;
    request["4"] = tab && tab.title || "";
    
    if (tab && tab.url) {
        request["5"] = tab.url;
    }
    if (!request["5"]) {
        request["5"] = info.pageUrl;
    }
    
    this.pendingRequest = request;
    chrome.cookies.getAll({ url: request["2"] }, this.setCookiesAndSend);
};

/**
 * 添加下载请求到内容脚本显示
 * @param {Object} request - 下载请求
 */
DownloadManagerProto.addDownload = function(request) {
    if (!this.showMediaPanel) return;
    
    let port = this.tabFramePorts[[request.tabId, request.frameId]];
    if (!port) {
        port = this.tabFramePorts[[request.tabId, 0]];
        if (!port) return;
    }
    
    // 生成唯一 ID（基于 URL 的简单哈希）
    const url = request["2"];
    let hash = 0;
    for (let i = 0; i < url.length; i++) {
        const char = url.charCodeAt(i);
        hash = ((hash << 5) - hash) + char;
        hash |= 0;
    }
    request.id = hash;
    
    port.postMessage([1, request, port["2"]]);
};

/**
 * 请求完成或出错时清理
 * @param {Object} details - 请求详情
 */
DownloadManagerProto.onRequestCompleted = function(details) {
    delete this.pendingRequests[details.requestId];
};

/**
 * 监听请求发送前（用于获取请求头）
 * @param {Object} details - 请求详情
 */
DownloadManagerProto.onBeforeSendHeaders = function(details) {
    if (details.tabId < 0 || details.frameId < 0) return;
    
    const request = this.pendingRequests[details.requestId];
    if (request) {
        request.o = details.requestHeaders;
    }
};

/**
 * 监听请求发送前（用于获取 POST 数据）
 * @param {Object} details - 请求详情
 */
DownloadManagerProto.onBeforeRequest = function(details) {
    if (details.tabId < 0 || details.frameId < 0) return;
    
    const protocol = getProtocol(details.url);
    
    // 处理 FTP 链接
    if (protocol === "ftp") {
        if (extractFilenameFromUrl(details.url) && !deleteKeyPressed) {
            const request = new DownloadRequest();
            const mainPort = this.tabFramePorts[[details.tabId, 0]];
            
            if (mainPort && mainPort["2"]) {
                request["5"] = mainPort["2"];
                request.pageUrl = mainPort["2"];
            }
            if (mainPort && mainPort["4"]) {
                request["4"] = mainPort["4"];
            }
            
            request["2"] = details.url;
            this.sendToNDM(request);
        }
        return;
    }
    
    // 存储请求信息
    const requestId = details.requestId;
    let pendingRequest = this.pendingRequests[requestId] || {
        id: requestId,
        "2": details.url,
        tabId: details.tabId,
        frameId: details.frameId
    };
    
    // 保存 POST 数据
    if (details.method.toUpperCase() === "POST") {
        pendingRequest.ja = details.requestBody;
    }
    
    this.pendingRequests[requestId] = pendingRequest;
};

/**
 * 监听响应头接收（主要下载检测逻辑）
 * @param {Object} details - 请求详情
 */
DownloadManagerProto.onHeadersReceived = function(details) {
    const requestId = details.requestId;
    const pendingRequest = this.pendingRequests[requestId];
    
    if (!pendingRequest) return;
    
    const url = details.url;
    const resourceType = details.type;
    const isDownloadableType = downloadableResourceTypes.indexOf(resourceType) >= 0;
    const method = details.method.toUpperCase();
    const protocol = getProtocol(url);
    
    // 只处理 HTTP/HTTPS 的 GET/POST 请求
    if (!protocol || (protocol !== "http" && protocol !== "https") || 
        (method !== "GET" && method !== "POST")) {
        delete this.pendingRequests[requestId];
        return;
    }
    
    // 保存响应头
    pendingRequest.B = details.responseHeaders;
    
    const contentType = findHeader(pendingRequest.B, "Content-Type");
    const parsedContentType = parseContentType(contentType).toLowerCase();
    
    // 过滤图片请求
    if (resourceType === "image" && parsedContentType && 
        startsWith(parsedContentType.toLowerCase(), "image/")) {
        delete this.pendingRequests[requestId];
        return;
    }
    
    const contentDisposition = findHeader(pendingRequest.B, "Content-Disposition");
    const isAttachment = parseContentType(contentDisposition).toLowerCase() === "attachment";
    const statusCode = parseInt(details.statusLine.split(" ", 2).pop()) || 0;
    
    // 检查是否是重定向
    pendingRequest.isRedirect = redirectCodes.indexOf(statusCode) >= 0;
    
    if (!pendingRequest.isRedirect) {
        if (statusCode === 200 || statusCode === 206) {
            // 获取文件大小
            let contentLength = findHeader(pendingRequest.B, "Content-Length");
            const contentRange = findHeader(pendingRequest.B, "Content-Range");
            let fileSize = null;
            
            if (contentRange) {
                const rangeMatch = contentRangeRegex.exec(contentRange);
                if (rangeMatch) {
                    fileSize = rangeMatch[1];
                }
            }
            
            if (contentLength) {
                fileSize = contentLength;
            }
            
            if (fileSize !== null) {
                fileSize = parseInt(fileSize);
            }
            
            // 跳过空文件
            if (fileSize === 0) {
                delete this.pendingRequests[requestId];
                return;
            }
            
            // 填充请求信息
            pendingRequest["2"] = url;
            pendingRequest["8"] = contentType;
            pendingRequest["7"] = fileSize;
            pendingRequest.type = resourceType;
            pendingRequest.protocol = protocol;
            pendingRequest["1"] = method;
            pendingRequest.isFrame = endsWith(resourceType, "_frame");
            
            // 解析 URL 获取文件名
            const urlObj = new URL(url);
            const hostname = urlObj.hostname;
            const pathname = urlObj.pathname;
            
            const pathParts = pathname.split("/");
            let filenameFromUrl = pathParts.pop().trim();
            if (filenameFromUrl) {
                filenameFromUrl = filenameFromUrl.split("?").shift().trim();
            }
            
            pendingRequest.l = filenameFromUrl || "";
            pendingRequest.s = getFileExtension(pendingRequest.l);
            
            // 从 Content-Disposition 获取文件名
            pendingRequest.K = getUrlParam(contentDisposition, "filename") || 
                               getUrlParam(contentType, "name");
            pendingRequest.P = pendingRequest.K ? getFileExtension(pendingRequest.K) : "";
            
            // 确定文件扩展名（优先级：MIME 映射 > CD 文件名 > URL 扩展名）
            const mimeExtension = parsedContentType ? mimeToExtension[parsedContentType] : false;
            pendingRequest.O = mimeExtension ? mimeExtension.split("|").shift().toLowerCase() : "";
            pendingRequest.g = pendingRequest.O || pendingRequest.P || pendingRequest.s || "";
            
            // 处理最终文件名
            pendingRequest.fileName = pendingRequest.K || pendingRequest.l || "";
            if (pendingRequest.fileName) {
                const dotIndex = pendingRequest.fileName.lastIndexOf(".");
                if (dotIndex > -1) {
                    pendingRequest.fileName = pendingRequest.fileName.substr(0, dotIndex).trim();
                }
            }
            if (pendingRequest.fileName && pendingRequest.g) {
                pendingRequest.fileName += "." + pendingRequest.g;
            }
            
            // 如果没有 Content-Type 但有扩展名，尝试查找 MIME
            if (!parsedContentType && pendingRequest.g) {
                parsedContentType = findMimeByExtension(pendingRequest.g);
            }
            
            // 检查是否是主框架的媒体文件
            const isMainFrameMedia = pendingRequest.type === "main_frame" && 
                                     mediaExtensions.test(pendingRequest.g) && 
                                     !streamSegmentFormats.test(pendingRequest.g);
            
            // 排除列表
            const excludedExtensions = ["js", "txt", "dict"];
            const isExcluded = excludedExtensions.indexOf(pendingRequest.g) > -1 ||
                              excludedExtensions.indexOf(pendingRequest.s) > -1;
            
            // 检查各种排除条件
            const hasManifest = contains(pendingRequest.l.toLowerCase(), "manif");
            const isFavicon = contains(pendingRequest.l.toLowerCase(), "favicon.ico");
            const isPemMsg = contains(pendingRequest.l.toLowerCase(), "pem.msg");
            const isWasm = endsWith(pendingRequest.l.toLowerCase(), ".wasm");
            const isJsonFile = contains(pendingRequest.l.toLowerCase(), ".json");
            const isJsonMime = contains(pendingRequest.O.toLowerCase(), "json");
            const isJsonFromCd = contains(pendingRequest.P.toLowerCase(), "json");
            const isDictFile = endsWith(pendingRequest.l.toLowerCase(), ".dict");
            
            // 综合判断是否应该拦截
            const shouldIntercept = !(
                hasManifest || isFavicon || isPemMsg || isWasm || isJsonFile || 
                isJsonMime || isJsonFromCd || isDictFile ||
                !(isMainFrameMedia ||
                  (pendingRequest.type === "other" && mediaExtensions.test(pendingRequest.g)) ||
                  ((pendingRequest.isFrame || !isDownloadableType) && legacyMediaFormats.test(pendingRequest.g)) ||
                  ((pendingRequest.isFrame || pendingRequest.type === "other") &&
                   ((isAttachment && !isExcluded) || forceDownloadTypes.test(parsedContentType) ||
                    (pendingRequest.g && !mediaExtensions.test(pendingRequest.g) && 
                     !nonDownloadExtensions.test(pendingRequest.g))))
                )
            );
            
            if (shouldIntercept) {
                // 检查是否是字幕文件
                const isSubtitle = pendingRequest.g.toLowerCase() === "vtt" ||
                                  pendingRequest.s.toLowerCase() === "vtt" ||
                                  pendingRequest.g.toLowerCase() === "srt" ||
                                  pendingRequest.s.toLowerCase() === "srt";
                
                let hlsParser = null;
                
                // 检查是否是 M3U8 播放列表
                if (pendingRequest.g.toLowerCase() === "m3u8" || 
                    pendingRequest.s.toLowerCase() === "m3u8") {
                    hlsParser = new HlsParser(this);
                } else if (!isSubtitle && method !== "POST" && 
                          !contains(hostname.toLowerCase(), "vimeo") &&
                          !contains(hostname.toLowerCase(), "youtube") &&
                          !contains(hostname.toLowerCase(), "google") &&
                          (pendingRequest.g.toLowerCase() === "txt" || 
                           pendingRequest.g.toLowerCase() === "js") &&
                          pendingRequest.type === "xmlhttprequest" &&
                          (!pendingRequest["7"] || pendingRequest["7"] > 307200)) {
                    // 可能是 HLS 播放列表
                    hlsParser = new HlsParser(this);
                }
                
                const manager = this;
                
                if (hlsParser) {
                    // 获取并解析 M3U8 内容
                    fetchResourceContent(
                        { "2": pendingRequest["2"], S: function(text) {
                            hlsParser.parse(mergeObjects({}, pendingRequest), text);
                        }},
                        mergeObjects({}, pendingRequest)
                    );
                } else if (isDownloadableType && hostname === "player.vimeo.com" &&
                          startsWith(pathname, "/video/") &&
                          parsedContentType === "application/json") {
                    // Vimeo 视频解析
                    fetchResourceContent(
                        { "2": pendingRequest["2"], S: function(text) {
                            let json = null;
                            try {
                                json = JSON.parse(text);
                            } catch (e) {}
                            
                            if (json && json.request && json.request.files && 
                                json.request.files.progressive) {
                                const progressive = json.request.files.progressive;
                                setTimeout(function() {
                                    for (let i = 0; i < progressive.length; i++) {
                                        manager.addDownload({
                                            "1": "GET",
                                            "2": progressive[i].url,
                                            "6": "media",
                                            tabId: pendingRequest.tabId,
                                            frameId: pendingRequest.frameId,
                                            fEx: "mp4",
                                            "4": "MP4 File " + progressive[i].quality
                                        });
                                    }
                                }, 2500);
                            }
                        }},
                        pendingRequest
                    );
                } else if ((isDownloadableType || isSubtitle) &&
                          (mediaExtensions.test(pendingRequest.g) || mediaExtensions.test(pendingRequest.s)) &&
                          !streamSegmentFormats.test(pendingRequest.g) &&
                          (!pendingRequest["7"] || pendingRequest["7"] > 512000 || isSubtitle) &&
                          !(pendingRequest.g === "ASF" && pendingRequest["7"] <= 2560000) &&
                          findHeader(pendingRequest.B, "Server") !== "DCLK-AdSvr") {
                    // 普通媒体文件
                    const downloadRequest = {
                        "2": pendingRequest["2"],
                        "6": "media",
                        "1": pendingRequest["1"],
                        tabId: pendingRequest.tabId,
                        frameId: pendingRequest.frameId,
                        fEx: mediaExtensions.test(pendingRequest.g) ? pendingRequest.g : pendingRequest.s,
                        "7": pendingRequest["7"],
                        "8": pendingRequest["8"],
                        fS: pendingRequest["7"],
                        fileName: pendingRequest.fileName
                    };
                    
                    if (downloadRequest["1"] === "POST") {
                        processPostData(pendingRequest, downloadRequest);
                    }
                    
                    copyCustomHeaders(pendingRequest, downloadRequest);
                    
                    setTimeout(function() {
                        manager.addDownload(downloadRequest);
                    }, 2000);
                }
            } else if (deleteKeyPressed || !this.catchingEnabled) {
                // 不拦截，使用浏览器默认下载
                this.currentDownload = "";
            } else {
                // 发送到 NDM
                this.currentDownload = pendingRequest["2"];
                
                const mainPort = this.tabFramePorts[[pendingRequest.tabId, 0]];
                const framePort = this.tabFramePorts[[pendingRequest.tabId, pendingRequest.frameId]];
                
                const downloadRequest = mergeObjects(new DownloadRequest(), {
                    "2": pendingRequest["2"],
                    "1": pendingRequest["1"],
                    "4": (mainPort && mainPort["4"]) || (framePort && framePort["4"]),
                    "5": (mainPort && mainPort["2"]) || (framePort && framePort["2"]),
                    "7": pendingRequest["7"],
                    "8": pendingRequest["8"],
                    pageUrl: (framePort && framePort["2"]) || pendingRequest["2"]
                });
                
                // 检查是否需要关闭标签页（媒体文件的主框架）
                chrome.tabs.query({ active: true, currentWindow: true }, function(tabs) {
                    if (tabs && tabs.length &&
                        (pendingRequest["2"] === tabs[0].pendingUrl || 
                         pendingRequest["2"] === tabs[0].url) &&
                        !downloadRequest["5"] && tabs[0].openerTabId) {
                        const openerPort = manager.tabFramePorts[[tabs[0].openerTabId, 0]];
                        downloadRequest["5"] = openerPort && openerPort["2"];
                        downloadRequest["4"] = openerPort && openerPort["4"];
                        
                        if (mediaExtensions.test(pendingRequest.g)) {
                            chrome.tabs.remove(tabs[0].id);
                            downloadRequest["6"] = "media";
                        }
                    }
                });
                
                if (downloadRequest["1"] === "POST") {
                    processPostData(pendingRequest, downloadRequest);
                }
                
                copyCustomHeaders(pendingRequest, downloadRequest);
                
                this.pendingRequest = downloadRequest;
                chrome.cookies.getAll({ url: downloadRequest["2"] }, this.setCookiesAndSend);
            }
        }
    }
    
    delete this.pendingRequests[requestId];
};

/**
 * 内容脚本端口连接处理
 * @param {Object} port - 端口对象
 */
DownloadManagerProto.onPortConnected = function(port) {
    const tab = port.sender.tab;
    if (!tab || tab.id < 0) return;
    
    const frameId = port.sender.frameId;
    const portId = port.id || this.portIdCounter++;
    const tabId = tab.id;
    
    port.id = portId;
    port["4"] = tab.title;
    port.tabId = tabId;
    port.frameId = frameId;
    port.isMainFrame = frameId === 0;
    port["2"] = port.sender.url || (port.isMainFrame && tab.url) || null;
    
    port.onMessage.addListener(this.onPortMessage.bind(this, port));
    port.onDisconnect.addListener(this.onPortDisconnect.bind(this, port));
    
    this.ports[portId] = port;
    this.tabFramePorts[[tabId, frameId]] = port;
    
    // 发送初始化消息
    port.postMessage([3, port.id]);
    port.postMessage([13, this.showMediaPanel]);
    
    port.sender = null; // 释放内存
};

/**
 * 处理内容脚本消息
 * @param {Object} port - 端口对象
 * @param {Array} message - 消息数组
 */
DownloadManagerProto.onPortMessage = function(port, message) {
    switch (message[0]) {
        case 2:
            // 更新 URL 和标题
            const newUrl = message[2];
            const newTitle = message[3];
            const targetPort = this.ports[message[1]];
            if (targetPort) {
                if (newUrl) targetPort["2"] = newUrl;
                if (newTitle) targetPort["4"] = newTitle;
            }
            break;
            
        case 4:
            // Delete 键状态
            deleteKeyPressed = message[1];
            break;
            
        case 6:
            // 内容脚本发起的下载请求
            const data = message[1];
            const pageUrl = message[2];
            const pageTitle = message[3];
            const userAgent = message[4];
            
            const mainPort = port.tabId && this.tabFramePorts[[port.tabId, 0]];
            const request = new DownloadRequest();
            
            request["1"] = data["1"] || "GET";
            request["2"] = data["2"];
            if (data["3"]) request["3"] = data["3"];
            request.pageUrl = pageUrl;
            request["4"] = pageTitle || (mainPort && mainPort["4"]) || "";
            request["5"] = (mainPort && mainPort["2"]) || request.pageUrl;
            request["9"] = userAgent;
            if (data["7"]) request["7"] = data["7"];
            if (data["8"]) request["8"] = data["8"];
            request["6"] = data["6"] || "media";
            
            // 字幕文件特殊处理
            if (!data.fEx || (data.fEx.toLowerCase() !== "vtt" && data.fEx.toLowerCase() !== "srt")) {
                // 保持 media 类型
            } else {
                request["6"] = "normal";
            }
            
            if (data.postData) request.postData = data.postData;
            if (data["10"]) request["10"] = data["10"];
            if (data["11"]) request["11"] = data["11"];
            
            // 复制自定义 X- 头部
            for (const key in data) {
                if (startsWith(key.toLowerCase(), "x-")) {
                    request[key] = data[key];
                }
            }
            
            this.pendingRequest = request;
            chrome.cookies.getAll({ url: request["2"] }, this.setCookiesAndSend);
            break;
    }
};

/**
 * 端口断开连接处理
 * @param {Object} port - 端口对象
 */
DownloadManagerProto.onPortDisconnect = function(port) {
    // 清理标签页映射
    for (const key in this.tabFramePorts) {
        if (this.tabFramePorts[key] === port) {
            delete this.tabFramePorts[key];
        }
    }
    // 清理端口
    delete this.ports[port.id];
};

/**
 * 发送消息到特定标签页的所有框架
 * @param {number} tabId - 标签页 ID
 * @param {Array} message - 消息
 */
DownloadManagerProto.sendToTabFrames = function(tabId, message) {
    const prefix = tabId.toString() + ",";
    for (const key in this.tabFramePorts) {
        if (startsWith(key, prefix)) {
            this.tabFramePorts[key].postMessage(message);
        }
    }
};

/**
 * 广播消息到所有端口
 * @param {Array} message - 消息
 */
DownloadManagerProto.broadcastToAllPorts = function(message) {
    for (const key in this.tabFramePorts) {
        this.tabFramePorts[key].postMessage(message);
    }
};

/**
 * 加载设置
 */
DownloadManagerProto.loadSettings = function() {
    const manager = this;
    chrome.storage.local.get(["ShowMediaPanel"], function(result) {
        if (result.ShowMediaPanel !== undefined) {
            manager.showMediaPanel = result.ShowMediaPanel;
        } else {
            manager.showMediaPanel = false;
        }
    });
    
    chrome.action.setBadgeBackgroundColor({ color: "#FF3333" });
};

/**
 * 注册运行时消息监听（来自 popup）
 */
DownloadManagerProto.registerRuntimeMessages = function() {
    const manager = this;
    chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
        if (message.type === "TOGGLE_DOWNLOAD_CATCH") {
            manager.catchingEnabled = message.enabled;
            manager.toggleCatching();
        } else if (message.type === "TOGGLE_MEDIA_PANEL") {
            manager.showMediaPanel = message.enabled;
            manager.broadcastToAllPorts([13, manager.showMediaPanel]);
        }
    });
};

// ============================================
// 初始化
// ============================================

// 创建下载管理器实例
new DownloadManager();
