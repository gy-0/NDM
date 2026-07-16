/**
 * NeatDownloadManager Chrome Extension - Content Script
 * 
 * This script is injected into web pages to detect media elements (video/audio)
 * and display a floating download panel for users to download media files.
 * 
 * Main Components:
 * - MediaPanel: Floating UI panel displayed on top of media elements
 * - MediaDetector: Main class that detects media and manages panels
 */

// ==================== Constants ====================

/** Extension icon URL (16x16) */
const ICON_URL = chrome.runtime.getURL("img/icon16.png");

/** Close button icon URL (16x16) */
const CLOSE_ICON_URL = chrome.runtime.getURL("img/close16.png");

/** Display state mapping for expandable rows (-1 = hidden, 1 = visible) */
const DISPLAY_STATE_MAP = { "-1": "none", "1": "" };

// ==================== Utility Functions ====================

/**
 * Get element by ID
 * @param {string} id - Element ID
 * @returns {HTMLElement|null}
 */
function getElementById(id) {
    return document.getElementById(id);
}

// Expose globally for compatibility
window.el = getElementById;

/**
 * Check if current page is Facebook
 * @returns {boolean}
 */
function isFacebook() {
    const host = document.location.host.toLowerCase();
    const index = host.length - 12; // "facebook.com".length = 12
    return index >= 0 && host.indexOf("facebook.com", index) === index;
}

/**
 * Fetch text content from URL with no-cors mode
 * @param {Object} options - Options object
 * @param {string} options.url - URL to fetch
 * @param {Function} options.callback - Callback function with text content
 */
async function fetchText(options) {
    try {
        const response = await fetch(options.url, { mode: "no-cors" });
        if (response.ok) {
            const text = await response.text();
            (options.callback || function(){})(text);
        }
    } catch (error) {
        // Silently fail
    }
}

/**
 * Calculate hash value for a string
 * @param {string} str - Input string
 * @returns {number} Hash value
 */
function hashString(str) {
    let hash = 0;
    for (let i = 0; i < str.length; i++) {
        const char = str.charCodeAt(i);
        hash = ((hash << 5) - hash) + char;
        hash |= 0; // Convert to 32bit integer
    }
    return hash;
}

/**
 * Format byte size to human-readable string
 * @param {number} bytes - Byte size
 * @returns {string} Formatted size (e.g., "1.5 MB")
 */
function formatBytes(bytes) {
    if (!bytes || bytes < 0) return " ";
    if (bytes < 1000) return bytes + " Bytes";
    if (bytes < 1000000) return (bytes / 1024).toFixed(1) + " KB";
    if (bytes < 1000000000) return (bytes / 1048576).toFixed(2) + " MB";
    return (bytes / 1073741824).toFixed(3) + " GB";
}

/**
 * Get element's position relative to document
 * @param {HTMLElement} element - Target element
 * @returns {Object} Position {left, top}
 */
function getElementPosition(element) {
    if (!element) return { left: 0, top: 0 };
    try {
        const rect = element.getBoundingClientRect();
        if (rect) {
            return {
                left: Math.round(rect.left + window.pageXOffset),
                top: Math.round(rect.top + window.pageYOffset)
            };
        }
        return { left: 0, top: 0 };
    } catch (e) {
        return { left: 0, top: 0 };
    }
}

/**
 * Format media item title
 * @param {Object} media - Media object
 * @param {string} media.label - Display label
 * @param {string} media.extension - File extension
 * @param {number} media.size - File size
 * @param {string} media.duration - Duration string
 * @returns {string} Formatted title
 */
function formatMediaTitle(media) {
    if (!media) return "Media File";
    
    // Handle subtitle files (VTT/SRT)
    const ext = media.extension ? media.extension.toUpperCase() : "";
    if (!media.label && (ext === "VTT" || ext === "SRT")) {
        return ext + " Subtitles File " + (media.size ? formatBytes(media.size) : " ");
    }
    
    // Default format
    if (media.label) {
        return media.label;
    }
    
    return (ext || "MP4") + " File  " + (formatBytes(media.size) || media.duration);
}

// ==================== MediaPanel Class ====================

/**
 * Floating download panel displayed on top of media elements
 * Shows download options and allows user interaction
 */
class MediaPanel {
    /**
     * @param {MediaDetector} detector - Parent MediaDetector instance
     * @param {HTMLElement|null} mediaElement - Associated media element
     * @param {number} panelId - Unique panel ID
     */
    constructor(detector, mediaElement, panelId) {
        /** Reference to MediaDetector */
        this.detector = detector;
        
        // Register in detector's panel map
        detector.panelMap[panelId] = this;
        
        /** Unique panel ID */
        this.panelId = panelId;
        
        /** Table element ID */
        this.tableId = "neatTable" + panelId;
        
        /** Header cell element ID */
        this.headerCellId = "neatHCell" + panelId;
        
        /** Panel DOM element */
        this.element = null;
        
        /** Associated media element (null for fixed position) */
        this.mediaElement = mediaElement;
        
        /** Auto-hide timer ID */
        this.hideTimer = null;
        
        /** Panel position {left, top} */
        this.position = { left: 0, top: 0 };
        
        /** Expanded state (-1 = collapsed, 1 = expanded) */
        this.expandedState = -1;
        
        /** Array of media item IDs */
        this.mediaItemIds = [];
        
        /** Drag start X position */
        this.dragStartX = 0;
        
        /** Drag start Y position */
        this.dragStartY = 0;
        
        /** Is currently dragging */
        this.isDragging = false;
        
        /** Has moved during drag (distinguish click from drag) */
        this.hasMoved = false;
    }

    /**
     * Add event listener with automatic binding
     * @param {HTMLElement} element - Target element
     * @param {string} event - Event name
     * @param {Function} handler - Event handler
     */
    addEvent(element, event, handler) {
        const args = Array.prototype.slice.call(arguments);
        args[2] = args[2].bind(this);
        element.addEventListener.apply(element, args.slice(1));
    }

    /**
     * Update panel position based on current position values
     */
    updatePosition() {
        if (this.element) {
            this.element.style.left = this.position.left + "px";
            this.element.style.top = this.position.top + "px";
            this.element.style.zIndex = parseInt(this.element.style.zIndex || 100000000) + 500;
        }
    }

    /**
     * Handle download button click
     * @param {number} index - Media item index
     */
    downloadItem(index) {
        // Collapse panel first
        this.toggleExpand(true);
        
        // Send download request to detector
        const mediaId = this.mediaItemIds[index];
        this.detector.requestDownload(mediaId);
    }

    /**
     * Toggle panel expanded/collapsed state
     * @param {boolean} collapse - Force collapse if true
     */
    toggleExpand(collapse) {
        if (!collapse && this.expandedState === -1) return;
        
        const table = getElementById(this.tableId);
        if (!table) return;
        
        const rows = table.rows;
        this.expandedState = collapse ? -1 : -this.expandedState;
        
        // Show/hide all rows except header (row 0)
        for (let i = 1; i < rows.length; i++) {
            rows[i].style.display = DISPLAY_STATE_MAP[this.expandedState];
        }
    }

    /**
     * Add a media item to the panel
     * @param {number} index - Media item index
     */
    addItemToPanel(index) {
        const self = this;
        const table = getElementById(this.tableId);
        const mediaData = this.detector.getMediaData(this.mediaItemIds[index]);
        const title = formatMediaTitle(mediaData);
        
        // Create new row
        const row = table.insertRow(-1);
        row.cssText = "all:revert;padding:0px;margin:0px;width:100%;line-height:100% !important;height:19px !important";
        row.style.display = DISPLAY_STATE_MAP[self.expandedState];
        
        // Create cell
        const cell = row.insertCell(0);
        cell.style.cssText = "all:revert;letter-spacing:normal;line-height:100% !important;width:100%;height:19px !important;margin:0px;padding:0px;padding-left:5px;vertical-align:middle;color:black !important;cursor:default;border:dotted 1px black;background:#c9dff2 !important;direction:ltr;text-align:left;font-family:tahoma !important;font-style:normal;font-weight:bold;font-size:7pt !important";
        
        const displayTitle = " " + title;
        
        // First item - create header with icon and close button
        if (index === 0 && this.mediaItemIds.length === 1) {
            // Create nested table for header
            const headerTable = document.createElement("TABLE");
            headerTable.style.cssText = "all:revert;border-spacing:0px;border-collapse:separate;padding:0px;margin:0px;width:100%;border:solid 1px black;direction:ltr;line-height:100% !important";
            
            const headerRow = headerTable.insertRow(-1);
            headerRow.style.cssText = "all:revert;padding:0px;margin:0px;line-height:100% !important;height:19px !important";
            
            // Icon cell
            const iconCell = headerRow.insertCell(-1);
            iconCell.style.cssText = "all:revert;background:#c9dff2 !important;padding:0px;margin:0px;width:20px;height:19px !important;text-align:center;vertical-align:middle;line-height:100% !important";
            
            const iconImg = document.createElement("IMG");
            iconImg.src = ICON_URL;
            iconImg.onclick = function() {
                alert("NeatDownloadManager Video/Audio Panel.");
            };
            iconCell.appendChild(iconImg);
            
            // Title cell
            const titleCell = headerRow.insertCell(-1);
            titleCell.id = self.headerCellId;
            titleCell.style.cssText = "all:revert;letter-spacing:normal;padding:0px;margin:0px;vertical-align:middle;color:black !important;cursor:default;background:#c9dff2 !important;direction:ltr;text-align:center;font-family:tahoma !important;font-style:normal;font-weight:bold;font-size:7pt !important;height:19px !important;line-height:100% !important";
            
            // Close button cell
            const closeCell = headerRow.insertCell(-1);
            closeCell.style.cssText = "all:revert;background:#c9dff2 !important;padding:0px;margin:0px;width:20px;height:19px !important;text-align:center;vertical-align:middle;line-height:100% !important";
            
            const closeImg = document.createElement("IMG");
            closeImg.src = CLOSE_ICON_URL;
            closeImg.onclick = function() {
                self.element.style.display = "none";
            };
            closeCell.appendChild(closeImg);
            
            // Add to cell
            cell.appendChild(headerTable);
            cell.style.paddingLeft = "0px";
            
            // Setup title cell
            const headerElement = getElementById(self.headerCellId);
            headerElement.innerText = displayTitle;
            headerElement.onmouseover = function() {
                this.style.color = "red";
            };
            headerElement.onmouseout = function() {
                this.style.color = "black";
            };
            headerElement.onclick = function() {
                if (!self.hasMoved) {
                    self.downloadItem(0);
                }
                self.hasMoved = false;
            };
        } else {
            // Additional items - simple row
            cell.innerText = " " + (index + 1).toString() + "- " + displayTitle;
            cell.onmouseover = function() {
                this.style.background = "white";
                this.style.color = "red";
            };
            cell.onmouseout = function() {
                this.style.background = "#c9dff2";
                this.style.color = "black";
            };
            row.onmousedown = function() {
                self.downloadItem(index);
            };
        }
    }

    /**
     * Show panel for a media item
     * @param {string} mediaId - Media ID
     */
    showPanel(mediaId) {
        const self = this;
        const mediaData = this.detector.getMediaData(mediaId);
        const title = formatMediaTitle(mediaData);
        const positionType = this.mediaElement ? "absolute" : "fixed";
        
        // Calculate position based on media element
        let elementRect = null;
        if (this.mediaElement && !this.isDragging) {
            elementRect = getElementPosition(this.mediaElement);
        }
        
        if (elementRect) {
            this.position = {
                left: Math.max(0, elementRect.left - 1),
                top: Math.max(0, elementRect.top - 19 - 4)
            };
        }
        
        // Create panel if not exists
        if (!this.element) {
            this.element = document.createElement("DIV");
            this.element.style.cssText = "all:revert;padding:0px;margin:0px;position:" + positionType + ";z-index:100000000;width:215px;left:" + this.position.left + "px;top:" + this.position.top + "px;direction:ltr;text-align:center;background:#c9dff2 !important;line-height:100% !important;";
            this.element.id = "neatDiv" + this.panelId;
            this.element.style.display = this.detector.showMediaPanel ? "" : "none";
            document.body.appendChild(this.element);
            
            // Create table
            const table = document.createElement("TABLE");
            table.id = this.tableId;
            table.style.cssText = "all:revert;border-spacing:0px;border-collapse:separate;padding:0px;margin:0px;line-height:100% !important;direction:ltr;width:100%;";
            this.element.appendChild(table);
            
            // Add event listeners
            this.addEvent(self.element, "mousemove", self.onMouseMove);
            this.addEvent(self.element, "mousedown", self.onMouseDown);
            this.addEvent(self.element, "mouseup", self.onMouseUp);
            this.addEvent(self.element, "mouseout", self.onMouseOut);
            this.addEvent(self.element, "mouseover", self.onMouseOver);
            
            // Auto-fade after 30 seconds
            this.hideTimer = setTimeout(function() {
                self.hideTimer = null;
                if (self.element) {
                    self.element.style.opacity = 0.45;
                }
            }, 30000);
        } else {
            this.updatePosition();
        }
        
        // Check for duplicate
        if (this.mediaItemIds.indexOf(mediaId) >= 0) {
            this.element.style.display = this.detector.showMediaPanel ? "" : "none";
            this.updatePosition();
            return;
        }
        
        // Handle quality variants (HQ/LQ)
        const displayTitle = " " + title;
        for (let i = 0; i < this.mediaItemIds.length; i++) {
            const existingTitle = formatMediaTitle(this.detector.getMediaData(this.mediaItemIds[i]));
            if (displayTitle === " " + existingTitle) {
                // Replace with new one
                this.mediaItemIds[i] = mediaId;
                this.element.style.display = this.detector.showMediaPanel ? "" : "none";
                this.updatePosition();
                return;
            }
        }
        
        // Add new item
        this.mediaItemIds.push(mediaId);
        const itemIndex = this.mediaItemIds.length - 1;
        const rows = getElementById(self.tableId).rows;
        let headerElement = null;
        
        if (itemIndex > 0) {
            headerElement = getElementById(self.headerCellId);
        }
        
        // Render items
        if (itemIndex === 0) {
            this.addItemToPanel(0);
        } else if (itemIndex === 1) {
            this.addItemToPanel(0);
            this.addItemToPanel(1);
            
            headerElement.onclick = function(event) {
                event.stopPropagation();
                event.preventDefault();
                if (!self.hasMoved) {
                    self.toggleExpand();
                }
                self.hasMoved = false;
            };
            headerElement.innerText = " 2 Files";
        } else {
            this.addItemToPanel(itemIndex);
            headerElement.innerText = " " + (itemIndex + 1).toString() + " Files";
        }
        
        // Show header row
        rows[0].style.display = "";
    }

    /**
     * Handle mouse down event (start drag)
     * @param {MouseEvent} event
     */
    onMouseDown(event) {
        if (event.button === 0) {
            this.isDragging = true;
            this.hasMoved = false;
            this.dragStartX = event.clientX;
            this.dragStartY = event.clientY;
            event.stopPropagation();
            event.preventDefault();
        }
    }

    /**
     * Handle mouse move event (dragging)
     * @param {MouseEvent} event
     */
    onMouseMove(event) {
        if (this.isDragging) {
            // Collapse panel during drag
            this.toggleExpand(true);
            
            const deltaX = event.clientX - this.dragStartX;
            const deltaY = event.clientY - this.dragStartY;
            
            // Detect if actually moved (distinguish from click)
            if (!this.hasMoved && (deltaX || deltaY)) {
                this.hasMoved = true;
            }
            
            this.position.left += deltaX;
            this.position.top += deltaY;
            this.dragStartX = event.clientX;
            this.dragStartY = event.clientY;
            this.updatePosition();
        } else {
            this.hasMoved = false;
        }
    }

    /**
     * Handle mouse out event (start fade timer)
     */
    onMouseOut() {
        this.isDragging = false;
        
        if (this.hideTimer) {
            clearTimeout(this.hideTimer);
            this.hideTimer = null;
        }
        
        const self = this;
        this.hideTimer = setTimeout(function() {
            if (self.element) {
                self.element.style.opacity = 0.45;
            }
            self.hideTimer = null;
        }, 15000);
    }

    /**
     * Handle mouse over event (restore opacity)
     */
    onMouseOver() {
        this.isDragging = false;
        
        if (this.hideTimer) {
            clearTimeout(this.hideTimer);
            this.hideTimer = null;
        }
        
        if (this.element) {
            this.element.style.opacity = 1;
        }
    }

    /**
     * Handle mouse up event (end drag)
     */
    onMouseUp() {
        this.isDragging = false;
    }
}

// ==================== MediaDetector Class ====================

/**
 * Main class for detecting media elements and managing download panels
 * Communicates with background script via chrome.runtime.connect
 */
class MediaDetector {
    constructor() {
        /** Current tab ID */
        this.currentTabId = null;
        
        /** Map of media ID -> media data */
        this.mediaDataMap = {};
        
        /** Map of panel ID -> MediaPanel instance */
        this.panelMap = {};
        
        /** Flag to prevent concurrent resize operations */
        this.isResizing = false;
        
        /** Mouse X position */
        this.mouseX = -1;
        
        /** Mouse Y position */
        this.mouseY = -1;
        
        /** Counter for generating unique element IDs */
        this.elementIdCounter = 1;
        
        /** Interval ID for position tracking */
        this.positionInterval = null;
        
        /** Counter for subtitle files (limit to 2) */
        this.subtitleCounter = 0;
        
        /** Whether to show media panels (from settings) */
        this.showMediaPanel = false;
        
        /** Array of registered event listeners for cleanup */
        this.eventListeners = [];
        
        /** Random base for ID generation */
        this.randomBase = Math.ceil(2000000 * Math.random());
        
        // Connect to background script
        this.port = chrome.runtime.connect({ name: "neat" });
        this.port.onMessage.addListener(this.onPortMessage.bind(this));
        this.port.onDisconnect.addListener(this.onPortDisconnect.bind(this));
        
        // Setup Facebook video detection
        if (isFacebook()) {
            const self = this;
            this.mutationObserver = new window.MutationObserver(function(mutations) {
                mutations.forEach(function(mutation) {
                    self.scanFacebookVideos(mutation.target);
                });
            });
            this.mutationObserver.observe(document, { childList: true, subtree: true });
        }
        
        // Register event listeners
        this.addListener(window, "keydown", this.onKeyEvent, true);
        this.addListener(window, "keyup", this.onKeyEvent, true);
        this.addListener(window, "mouseup", this.onMouseUp, true);
        this.addListener(window, "resize", this.onWindowResize);
        this.addListener(document, "DOMContentLoaded", this.onDomReady);
        this.addListener(document, "click", this.onDocumentClick);
        
        // Listen for settings changes
        const self = this;
        if (chrome.runtime.onMessage) {
            chrome.runtime.onMessage.addListener(function(message, sender, sendResponse) {
                if (message.type === 'SETTING_CHANGED' && message.key === 'ShowMediaPanel') {
                    self.showMediaPanel = message.value;
                    if (!self.showMediaPanel) {
                        self.hideAllPanels();
                    }
                }
            });
        }
    }

    /**
     * Add Facebook video to detector
     * @param {HTMLElement} element - Video element
     * @param {Object} urls - Video URLs {hd, sd}
     */
    addFacebookVideo(element, urls) {
        if (urls.hd) {
            this.notifyMedia({
                id: hashString(urls.hd),
                method: "GET",
                url: urls.hd,
                extension: "mp4",
                label: " MP4 File HQ"
            }, window.location.href, element, false);
        }
        
        if (urls.sd) {
            this.notifyMedia({
                id: hashString(urls.sd),
                method: "GET",
                url: urls.sd,
                extension: "mp4",
                label: " MP4 File LQ"
            }, window.location.href, element, false);
        }
    }

    /**
     * Get video element from a container element
     * @param {HTMLElement} element - Container element
     * @returns {HTMLVideoElement|null}
     */
    getVideoElement(element) {
        while (element && element.parentElement) {
            element = element.parentElement;
            const videos = element.querySelectorAll("video");
            if (videos.length > 0) {
                return videos[0];
            }
        }
        return null;
    }

    /**
     * Parse Facebook video and extract download URLs
     * @param {HTMLElement} linkElement - Link element
     * @param {string} videoId - Facebook video ID
     */
    parseFacebookVideo(linkElement, videoId) {
        const self = this;
        
        fetchText({
            url: "https://www.facebook.com/video/embed?video_id=" + videoId,
            callback: function(html) {
                // Extract HD and SD URLs from embed page
                let hdMatch = /"hd_src_no_ratelimit":"(.*?)"/.exec(html);
                let sdMatch = /"sd_src_no_ratelimit":"(.*?)"/.exec(html);
                
                // Fallback to regular src if no ratelimit version
                if (!hdMatch || !hdMatch.length) {
                    hdMatch = /"hd_src":"(.*?)"/.exec(html);
                }
                if (!sdMatch || !sdMatch.length) {
                    sdMatch = /"sd_src":"(.*?)"/.exec(html);
                }
                
                const urls = {
                    sd: sdMatch && sdMatch.length ? sdMatch[1].replace(/\\/g, "") : "",
                    hd: hdMatch && hdMatch.length ? hdMatch[1].replace(/\\/g, "") : ""
                };
                
                const videoElement = self.getVideoElement(linkElement);
                if (videoElement !== undefined) {
                    self.addFacebookVideo(videoElement, urls);
                }
            }
        });
    }

    /**
     * Scan for Facebook video links
     * @param {HTMLElement} container - Container element to scan
     */
    scanFacebookVideos(container) {
        const self = this;
        const links = container.querySelectorAll('a[href*="/videos/"]');
        
        if (!links.length) return;
        
        Array.from(links, function(link) {
            if (!link.getAttribute("NEAT_DM")) {
                link.setAttribute("NEAT_DM", "1");
                const match = link.href.match(/.*\/videos\/(\d+)\/.*/i);
                if (match) {
                    self.parseFacebookVideo(link, match[1]);
                }
            }
        });
    }

    /**
     * Get media data by ID
     * @param {string} mediaId - Media ID
     * @returns {Object|null}
     */
    getMediaData(mediaId) {
        return this.mediaDataMap[mediaId];
    }

    /**
     * Send ready message to background script
     */
    notifyReady() {
        this.port.postMessage([
            2, // Message type: READY
            this.currentTabId,
            window.location.href,
            this.getPageTitle()
        ]);
    }

    /**
     * Handle DOM ready event
     */
    onDomReady() {
        const self = this;
        
        // Look for Vimeo videos in script tags
        const scripts = document.getElementsByTagName("SCRIPT");
        const progressiveRegex = /"progressive":\s*\[/;
        
        for (let i = 0; i < scripts.length; i++) {
            const script = scripts[i];
            
            // Only process Vimeo pages with inline scripts containing progressive data
            if (document.location.host.toLowerCase().indexOf("vimeo") < 0) {
                continue;
            }
            if (script.src) {
                continue; // Skip external scripts
            }
            if (!progressiveRegex.test(script.innerText)) {
                continue;
            }
            
            // Extract progressive video data
            const scriptText = script.innerText;
            const startIndex = scriptText.indexOf('"progressive"');
            if (startIndex < 0) continue;
            
            const endIndex = scriptText.indexOf("]", startIndex);
            if (endIndex < 0) continue;
            
            const jsonText = scriptText.substr(startIndex, endIndex - startIndex + 1);
            let data = null;
            
            try {
                data = JSON.parse("{" + jsonText + "}");
            } catch (e) {
                continue;
            }
            
            if (data && data.progressive) {
                const videos = data.progressive;
                setTimeout(function() {
                    for (let j = 0; j < videos.length; j++) {
                        self.notifyMedia({
                            id: hashString(videos[j].url),
                            method: "GET",
                            url: videos[j].url,
                            extension: "mp4",
                            label: "MP4 File " + videos[j].quality
                        }, window.location.href, null, false);
                    }
                }, 2000);
                break;
            }
        }
    }

    /**
     * Remove a panel by ID
     * @param {number} panelId - Panel ID
     */
    removePanel(panelId) {
        const panel = this.panelMap[panelId];
        if (panel) {
            try {
                document.body.removeChild(panel.element);
                if (panel.hideTimer) {
                    clearTimeout(panel.hideTimer);
                }
            } catch (e) {
                // Ignore removal errors
            }
            delete this.panelMap[panelId];
        }
    }

    /**
     * Request download for a media item
     * @param {string} mediaId - Media ID
     */
    requestDownload(mediaId) {
        const media = this.mediaDataMap[mediaId];
        if (media) {
            this.port.postMessage([
                6, // Message type: DOWNLOAD
                media,
                window.location.href,
                this.getPageTitle(),
                formatMediaTitle(media)
            ]);
        }
    }

    /**
     * Find media element at current mouse position
     * @param {string} url1 - Primary URL to match
     * @param {string} url2 - Secondary URL to match
     * @returns {HTMLElement|null}
     */
    findMediaElement(url1, url2) {
        const mediaTags = ["VIDEO", "AUDIO", "OBJECT", "EMBED"];
        let bestMatch = null;
        let focusedElement = null;
        let maxArea = 0;
        let firstMedia = null;
        let fallbackMedia = null;
        
        try {
            // Get currently focused element
            const activeElement = document.activeElement;
            if (activeElement && mediaTags.indexOf(activeElement.tagName) >= 0) {
                focusedElement = activeElement;
            }
            
            // Get element at mouse position
            if (!focusedElement) {
                const elementAtPoint = document.elementFromPoint(this.mouseX, this.mouseY);
                if (elementAtPoint && mediaTags.indexOf(elementAtPoint.tagName) >= 0) {
                    focusedElement = elementAtPoint;
                }
            }
            
            // Scan all media elements
            for (let i = 0; i < mediaTags.length; i++) {
                const elements = document.getElementsByTagName(mediaTags[i]);
                
                for (let j = 0; j < elements.length; j++) {
                    const element = elements[j];
                    
                    // Skip OBJECT elements that aren't Flash
                    if (i === 2) { // OBJECT
                        if (element.type.toLowerCase() !== "application/x-shockwave-flash") {
                            continue;
                        }
                    }
                    
                    // Check for URL match
                    const src = element.src || element.data;
                    if (src && (src === url1 || src === url2)) {
                        bestMatch = element;
                        break;
                    }
                    
                    // Track focused or largest visible element
                    if (focusedElement) {
                        fallbackMedia = element;
                    } else {
                        const width = element.clientWidth;
                        const height = element.clientHeight;
                        
                        if (width && height) {
                            const computedStyle = window.getComputedStyle(element);
                            if (!computedStyle || computedStyle.visibility !== "hidden") {
                                const area = width * height;
                                
                                // Prefer elements with reasonable aspect ratio
                                if (height < 1.4 * width && width < 3 * height) {
                                    if (area > maxArea) {
                                        maxArea = area;
                                        firstMedia = element;
                                    }
                                }
                                
                                if (!fallbackMedia) {
                                    fallbackMedia = element;
                                }
                            }
                        }
                    }
                }
                
                if (bestMatch) break;
            }
            
            // Return best match or fallback
            let result = bestMatch || focusedElement || fallbackMedia || firstMedia;
            
            // Handle EMBED with no dimensions (use parent OBJECT)
            if (!result) {
                result = document.querySelectorAll("video,audio")[0];
            }
            
            if (!result) return null;
            
            if (result.tagName === "EMBED" && !result.clientWidth && !result.clientHeight) {
                const parent = result.parentElement;
                if (parent && parent.tagName === "OBJECT") {
                    result = parent;
                }
            }
            
            return result;
        } catch (e) {
            return null;
        }
    }

    /**
     * Get unique ID for an element
     * @param {HTMLElement} element - DOM element
     * @returns {number} Unique ID
     */
    getElementId(element) {
        try {
            let id = parseInt(element.getAttribute("JM_NEAT"));
            if (!id) {
                id = (this.randomBase << 10) | this.elementIdCounter++;
                element.setAttribute("JM_NEAT", id);
            }
            return id;
        } catch (e) {
            return 0;
        }
    }

    /**
     * Get current page title
     * @returns {string}
     */
    getPageTitle() {
        let title = "";
        try {
            title = document.title || document.getElementsByTagName("title")[0].innerText;
            title = title.trim();
        } catch (e) {
            // Ignore
        }
        
        if (title) {
            // Clean up title
            return title.replace(/[ \t\r\n\u25B6]+/g, " ").trim();
        }
        return "";
    }

    /**
     * Handle key down/up events
     * @param {KeyboardEvent} event
     */
    onKeyEvent(event) {
        // Delete (8) or Backspace (46) keys
        if (event.keyCode === 8 || event.keyCode === 46) {
            this.port.postMessage([
                4, // Message type: KEY_EVENT
                event.type === "keydown"
            ]);
        }
    }

    /**
     * Handle mouse up event
     * @param {MouseEvent} event
     */
    onMouseUp(event) {
        if (event.button === 0) {
            this.mouseX = event.clientX;
            this.mouseY = event.clientY;
        }
    }

    /**
     * Handle window resize event
     */
    onWindowResize() {
        if (this.isResizing) return;
        
        this.isResizing = true;
        const self = this;
        
        window.setTimeout(function() {
            for (const panelId in self.panelMap) {
                const panel = self.panelMap[panelId];
                let rect = null;
                
                if (panel.mediaElement) {
                    rect = getElementPosition(panel.mediaElement);
                }
                
                if (rect) {
                    try {
                        document.body.removeChild(panel.element);
                    } catch (e) {
                        // Ignore
                    }
                    
                    panel.position.left = Math.max(0, rect.left - 1);
                    panel.position.top = Math.max(0, rect.top - 19 - 4);
                    document.body.appendChild(panel.element);
                }
                
                panel.updatePosition();
            }
            
            self.isResizing = false;
        }, 500);
    }

    /**
     * Check if two positions are close (within 18px)
     * @param {Object} pos1 - Position {left, top}
     * @param {Object} pos2 - Position {left, top}
     * @returns {boolean}
     */
    isPositionClose(pos1, pos2) {
        return Math.abs(pos1.left - pos2.left) < 18 && 
               Math.abs(pos1.top - pos2.top) < 18;
    }

    /**
     * Check if element is off-screen
     * @param {MediaPanel} panel - Panel to check
     * @returns {boolean}
     */
    isElementOffScreen(panel) {
        const pos = getElementPosition(panel.mediaElement);
        return !pos || pos.left < 0 || pos.top < 0;
    }

    /**
     * Notify detector of new media
     * @param {Object} media - Media object
     * @param {string} pageUrl - Page URL
     * @param {HTMLElement|null} element - Associated element
     * @param {boolean} fromContent - Whether from content script
     */
    notifyMedia(media, pageUrl, element, fromContent) {
        if (!this.showMediaPanel) return;
        
        const self = this;
        let elementId = -1;
        let existingPanel = null;
        
        // Check if this is a special site that needs element matching
        const host = window.location.host;
        const isSpecialSite = fromContent && 
            /.*facebook.com$|.*vimeo.com$|.*youtube.com$/i.test(host) &&
            !(media.extension && media.extension.toUpperCase() === "VTT") &&
            (!media.size || media.size <= 5242880);
        
        // Limit subtitle files
        if (media.extension) {
            const ext = media.extension.toUpperCase();
            if (ext === "VTT" || ext === "SRT") {
                // Skip YouTube subtitles
                if (host.toLowerCase().indexOf("youtube.") >= 0) {
                    return;
                }
                this.subtitleCounter++;
                if (this.subtitleCounter > 2) {
                    return;
                }
            }
        }
        
        // Skip YouTube (handled separately)
        if (host.toLowerCase().indexOf("youtube.com") >= 0) {
            return;
        }
        
        // Generate ID if not provided
        if (!media.id) {
            media.id = hashString(media.url);
        }
        
        // Find associated element
        element = element || this.findMediaElement(media.url, pageUrl);
        
        // Get first available panel if no element found
        if (!element) {
            for (const id in this.panelMap) {
                existingPanel = this.panelMap[id];
                elementId = id;
                break;
            }
        }
        
        // Create or get panel
        if (!element && !existingPanel) {
            if (isSpecialSite) return;
            existingPanel = new MediaPanel(self, null, 0);
        } else if (!existingPanel) {
            elementId = this.getElementId(element);
            existingPanel = this.panelMap[elementId];
            
            if (!existingPanel) {
                if (isSpecialSite) return;
                existingPanel = new MediaPanel(self, element, elementId);
                
                // Check for nearby panels to merge
                const elementRect = getElementPosition(element);
                const newPos = {
                    left: Math.max(0, elementRect.left - 1),
                    top: Math.max(0, elementRect.top - 19 - 4)
                };
                
                for (const pid in this.panelMap) {
                    if (pid && pid != elementId) {
                        const otherPanel = this.panelMap[pid];
                        if (this.isPositionClose(newPos, otherPanel.position)) {
                            // Merge items
                            for (let i = 0; i < otherPanel.mediaItemIds.length; i++) {
                                existingPanel.showPanel(otherPanel.mediaItemIds[i]);
                            }
                            this.removePanel(pid);
                            break;
                        }
                    }
                }
                
                // Merge with panel 0 if exists
                if (elementId !== 0 && this.panelMap[0]) {
                    const panel0 = this.panelMap[0];
                    for (let i = 0; i < panel0.mediaItemIds.length; i++) {
                        existingPanel.showPanel(panel0.mediaItemIds[i]);
                    }
                    this.removePanel(0);
                }
            } else if (isSpecialSite) {
                existingPanel.updatePosition();
                return;
            }
        } else if (isSpecialSite) {
            existingPanel.updatePosition();
            return;
        }
        
        // Store media data and show panel
        this.mediaDataMap[media.id] = media;
        existingPanel.showPanel(media.id);
        
        // Start position tracking if element is off-screen
        if (existingPanel.mediaElement && this.isElementOffScreen(existingPanel) && !this.positionInterval) {
            this.positionInterval = setInterval(function() {
                self.trackPanelPosition(existingPanel);
            }, 1200);
        }
    }

    /**
     * Track panel position and update if element moves
     * @param {MediaPanel} panel - Panel to track
     */
    trackPanelPosition(panel) {
        if (panel && panel.mediaElement) {
            const rect = getElementPosition(panel.mediaElement);
            if (rect) {
                panel.position = {
                    left: Math.max(0, rect.left - 1),
                    top: Math.max(0, rect.top - 19 - 4)
                };
                panel.updatePosition();
            }
            
            // Stop tracking if element is visible
            if (rect && rect.left >= 0 && rect.top >= 0) {
                clearInterval(this.positionInterval);
                this.positionInterval = null;
            }
        } else {
            clearInterval(this.positionInterval);
            this.positionInterval = null;
        }
    }

    /**
     * Handle messages from background script
     * @param {Array} message - Message array
     */
    onPortMessage(message) {
        const self = this;
        
        switch (message[0]) {
            case 1: // ADD_MEDIA
                self.notifyMedia(message[1], message[2], null, true);
                break;
                
            case 3: // SET_TAB_ID
                if (message[1]) {
                    self.currentTabId = message[1];
                }
                self.notifyReady();
                break;
                
            case 5: // UPDATE_VISIBILITY
                self.updatePanelVisibility();
                break;
                
            case 11: // INIT
                self.hideAllPanels();
                const hostname = new URL(window.location.href).hostname.toLowerCase();
                if (hostname.indexOf("youtube.") < 0) {
                    setTimeout(function() {
                        self.onDomReady();
                    }, 2500);
                }
                break;
                
            case 13: // SET_VISIBILITY
                const visible = message[1];
                if (visible !== self.showMediaPanel) {
                    self.showMediaPanel = visible;
                    self.updatePanelVisibility();
                }
                break;
                
            case 15: // CONNECTION_ERROR
                alert("Extension Can't Connect to NeatDownloadManager Application, You Can : \r\n" +
                      "1- Check If NeatDownloadManager is Running.\r\n" +
                      "2- or Hold down Delete-Key and click on the Download link.\r\n" +
                      "3- or Disable NeatDownloadManager Extension temporarily.");
                break;
        }
    }

    /**
     * Add event listener with tracking for cleanup
     * @param {HTMLElement} target - Event target
     * @param {string} event - Event name
     * @param {Function} handler - Event handler
     * @param {boolean} useCapture - Use capture phase
     */
    addListener(target, event, handler, useCapture) {
        const args = Array.prototype.slice.call(arguments);
        args[2] = args[2].bind(this);
        this.eventListeners.push(args);
        target.addEventListener.apply(target, args.slice(1));
    }

    /**
     * Handle document click - collapse all panels
     */
    onDocumentClick() {
        for (const panelId in this.panelMap) {
            this.panelMap[panelId].toggleExpand(true);
        }
    }

    /**
     * Hide all panels and clean up
     */
    hideAllPanels() {
        try {
            for (const panelId in this.panelMap) {
                const panel = this.panelMap[panelId];
                if (panel.hideTimer) {
                    clearTimeout(panel.hideTimer);
                }
                document.body.removeChild(panel.element);
            }
        } catch (e) {
            // Ignore errors
        }
        
        this.panelMap = {};
        this.mediaDataMap = {};
        
        if (this.positionInterval) {
            clearInterval(this.positionInterval);
            this.positionInterval = null;
        }
    }

    /**
     * Update visibility of all panels based on setting
     */
    updatePanelVisibility() {
        const display = this.showMediaPanel ? "" : "none";
        try {
            for (const panelId in this.panelMap) {
                this.panelMap[panelId].element.style.display = display;
            }
        } catch (e) {
            // Ignore errors
        }
    }

    /**
     * Handle port disconnect - reconnect
     */
    onPortDisconnect() {
        this.port = chrome.runtime.connect({ name: "neat" });
        this.port.onMessage.addListener(this.onPortMessage.bind(this));
        this.port.onDisconnect.addListener(this.onPortDisconnect.bind(this));
    }
}

// ==================== Initialize ====================

// Prevent duplicate initialization
if (!window.mediaDetectorInitialized) {
    window.mediaDetectorInitialized = true;
    new MediaDetector();
}
