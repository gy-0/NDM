const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('electronAPI', {
  getPlatform: () => ipcRenderer.invoke('app:get-platform'),
  selectFolder: () => ipcRenderer.invoke('app:select-folder'),
  openExternal: (url) => ipcRenderer.invoke('app:open-external', url),
  showItemInFolder: (path) => ipcRenderer.invoke('app:show-item-in-folder', path),
  showNotification: (payload) => ipcRenderer.invoke('app:show-notification', payload)
});
