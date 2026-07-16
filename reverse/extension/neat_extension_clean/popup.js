// 设置管理
const SETTINGS = {
    CATCH_DOWNLOADS: 'CatchDownloads',
    SHOW_MEDIA_PANEL: 'ShowMediaPanel'
};

// 默认设置
const DEFAULTS = {
    [SETTINGS.CATCH_DOWNLOADS]: true,   // 默认开启下载捕获
    [SETTINGS.SHOW_MEDIA_PANEL]: false  // 默认关闭媒体面板（用户要求）
};

// 获取设置
async function getSetting(key) {
    const result = await chrome.storage.local.get(key);
    return result[key] !== undefined ? result[key] : DEFAULTS[key];
}

// 保存设置
async function setSetting(key, value) {
    await chrome.storage.local.set({ [key]: value });
}

// 更新 Badge 状态
async function updateBadge() {
    const catchEnabled = await getSetting(SETTINGS.CATCH_DOWNLOADS);
    const text = catchEnabled ? "" : "OFF";
    const title = catchEnabled 
        ? "NeatDownloadManager - 下载捕获已开启"
        : "NeatDownloadManager - 下载捕获已关闭\n点击扩展图标可切换";
    
    await chrome.action.setBadgeText({ text });
    await chrome.action.setTitle({ title });
}

// 通知所有标签页设置变更
async function notifyTabs(settingKey, value) {
    const tabs = await chrome.tabs.query({});
    for (const tab of tabs) {
        try {
            await chrome.tabs.sendMessage(tab.id, {
                type: 'SETTING_CHANGED',
                key: settingKey,
                value: value
            });
        } catch (e) {
            // 忽略无法访问的标签页
        }
    }
}

// 初始化
document.addEventListener('DOMContentLoaded', async () => {
    const catchToggle = document.getElementById('catchDownloads');
    const mediaToggle = document.getElementById('showMediaPanel');
    const mediaStatus = document.getElementById('mediaStatus');

    // 加载当前设置
    catchToggle.checked = await getSetting(SETTINGS.CATCH_DOWNLOADS);
    mediaToggle.checked = await getSetting(SETTINGS.SHOW_MEDIA_PANEL);
    
    // 更新状态文字
    function updateStatus() {
        if (mediaToggle.checked) {
            mediaStatus.textContent = '媒体嗅探已开启 - 将显示下载按钮';
            mediaStatus.className = 'status on';
        } else {
            mediaStatus.textContent = '媒体嗅探已关闭 - 页面保持清爽';
            mediaStatus.className = 'status off';
        }
    }
    updateStatus();

    // 监听下载捕获开关
    catchToggle.addEventListener('change', async () => {
        const enabled = catchToggle.checked;
        await setSetting(SETTINGS.CATCH_DOWNLOADS, enabled);
        await updateBadge();
        
        // 通知 background script
        chrome.runtime.sendMessage({
            type: 'TOGGLE_DOWNLOAD_CATCH',
            enabled: enabled
        });
    });

    // 监听媒体面板开关
    mediaToggle.addEventListener('change', async () => {
        const enabled = mediaToggle.checked;
        await setSetting(SETTINGS.SHOW_MEDIA_PANEL, enabled);
        updateStatus();
        
        // 通知 background script
        chrome.runtime.sendMessage({
            type: 'TOGGLE_MEDIA_PANEL',
            enabled: enabled
        });
    });
});
