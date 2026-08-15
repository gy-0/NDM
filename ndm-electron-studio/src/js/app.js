/**
 * NDM Main Application Controller
 */

// Utility formatters
function formatBytes(bytes, decimals = 1) {
  if (!bytes || bytes === 0) return '0 B';
  const k = 1024;
  const dm = decimals < 0 ? 0 : decimals;
  const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + ' ' + sizes[i];
}

function formatSpeed(bytesPerSec) {
  if (!bytesPerSec || bytesPerSec === 0) return '0 KB/s';
  const mb = bytesPerSec / (1024 * 1024);
  if (mb >= 1) return mb.toFixed(1) + ' MB/s';
  return (bytesPerSec / 1024).toFixed(0) + ' KB/s';
}

function formatETA(remainingBytes, speed) {
  if (!speed || speed === 0 || !remainingBytes || remainingBytes <= 0) return '--';
  const seconds = Math.ceil(remainingBytes / speed);
  if (seconds < 60) return `${seconds}秒`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}分${seconds % 60}秒`;
  return `${Math.floor(seconds / 3600)}小时${Math.floor((seconds % 3600) / 60)}分`;
}

function getFileIconSVG(category) {
  switch (category) {
    case 'video':
      return `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="3" rx="2"/><path d="m9 8 6 4-6 4Z"/></svg>`;
    case 'audio':
      return `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></svg>`;
    case 'archives':
      return `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="20" height="5" x="2" y="3" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/></svg>`;
    case 'apps':
      return `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2v20"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/></svg>`;
    case 'documents':
      return `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/></svg>`;
    default:
      return `<svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" x2="12" y1="15" y2="3"/></svg>`;
  }
}

class AppController {
  constructor() {
    this.currentTheme = 'linear';
    this.currentFilter = 'all'; // all, downloading, completed, paused, trash
    this.currentType = null; // video, audio, archives, apps, documents
    this.searchQuery = '';
    this.viewMode = 'list'; // list or grid
    this.isDrawerOpen = false;

    this.initDOM();
    this.initEvents();
    this.setTheme('linear');
    
    // Subscribe to engine updates
    window.downloadEngine.subscribe((engine) => this.render(engine));
  }

  initDOM() {
    this.dom = {
      appContainer: document.getElementById('app'),
      themeButtons: document.querySelectorAll('.theme-btn'),
      themeInfoPill: document.getElementById('theme-info-badge'),
      filterButtons: document.querySelectorAll('.nav-filter-btn'),
      typeButtons: document.querySelectorAll('.nav-type-btn'),
      searchInput: document.getElementById('search-input'),
      taskList: document.getElementById('task-list-container'),
      emptyState: document.getElementById('empty-state'),
      globalSpeedVal: document.getElementById('stat-global-speed'),
      activeThreadsVal: document.getElementById('stat-active-threads'),
      completedTodayVal: document.getElementById('stat-completed-today'),
      globalSparkline: document.getElementById('global-speed-canvas'),
      cyberGaugeCanvas: document.getElementById('cyber-gauge-canvas'),
      speedLimitSelect: document.getElementById('speed-limit-select'),
      newDownloadModal: document.getElementById('modal-new-download'),
      taskDetailDrawer: document.getElementById('task-detail-drawer'),
      drawerCloseBtn: document.getElementById('drawer-close-btn'),
      soundToggleBtn: document.getElementById('sound-toggle-btn')
    };
  }

  initEvents() {
    // Theme Switcher
    this.dom.themeButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        const theme = btn.dataset.theme;
        this.setTheme(theme);
      });
    });

    // Navigation Filters
    this.dom.filterButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        this.dom.filterButtons.forEach(b => b.classList.remove('active'));
        this.dom.typeButtons.forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        this.currentFilter = btn.dataset.filter;
        this.currentType = null;
        if (window.soundEngine) window.soundEngine.playClick();
        this.render(window.downloadEngine);
      });
    });

    // Type Category Filters
    this.dom.typeButtons.forEach(btn => {
      btn.addEventListener('click', () => {
        this.dom.filterButtons.forEach(b => b.classList.remove('active'));
        this.dom.typeButtons.forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        this.currentFilter = null;
        this.currentType = btn.dataset.type;
        if (window.soundEngine) window.soundEngine.playClick();
        this.render(window.downloadEngine);
      });
    });

    // Search Input
    this.dom.searchInput.addEventListener('input', (e) => {
      this.searchQuery = e.target.value.toLowerCase().trim();
      this.render(window.downloadEngine);
    });

    // Speed Limiter Pills
    document.querySelectorAll('.speed-limit-pill').forEach(pill => {
      pill.addEventListener('click', () => {
        document.querySelectorAll('.speed-limit-pill').forEach(p => p.classList.remove('active'));
        pill.classList.add('active');
        const limit = parseInt(pill.dataset.limit, 10);
        window.downloadEngine.setSpeedLimit(limit);
      });
    });

    // Sound Toggle
    this.dom.soundToggleBtn.addEventListener('click', () => {
      const enabled = window.soundEngine.toggle();
      this.dom.soundToggleBtn.classList.toggle('muted', !enabled);
      this.dom.soundToggleBtn.title = enabled ? '声音已开启' : '静音模式';
      if (enabled) window.soundEngine.playPop();
    });

    // Global Action Buttons
    document.getElementById('btn-new-task').addEventListener('click', () => this.openNewModal());
    document.getElementById('btn-pause-all')?.addEventListener('click', () => window.downloadEngine.pauseAll());
    document.getElementById('btn-resume-all')?.addEventListener('click', () => window.downloadEngine.resumeAll());
    
    // View Toggle
    document.getElementById('btn-view-list')?.addEventListener('click', () => {
      this.viewMode = 'list';
      document.getElementById('btn-view-list').classList.add('active');
      document.getElementById('btn-view-grid').classList.remove('active');
      this.render(window.downloadEngine);
    });
    document.getElementById('btn-view-grid')?.addEventListener('click', () => {
      this.viewMode = 'grid';
      document.getElementById('btn-view-grid').classList.add('active');
      document.getElementById('btn-view-list').classList.remove('active');
      this.render(window.downloadEngine);
    });

    // Drawer Close
    this.dom.drawerCloseBtn.addEventListener('click', () => {
      this.closeDrawer();
    });

    // Modal Form
    const modalForm = document.getElementById('form-new-download');
    modalForm.addEventListener('submit', (e) => {
      e.preventDefault();
      const url = document.getElementById('input-url').value;
      const name = document.getElementById('input-filename').value;
      const category = document.getElementById('select-category').value;
      const threads = parseInt(document.getElementById('input-threads').value, 10) || 16;
      
      if (url) {
        window.downloadEngine.addTask({
          url,
          name: name || url.split('/').pop().split('?')[0] || 'New_Download',
          category,
          connections: threads,
          size: Math.round((1.5 + Math.random() * 8) * 1024 * 1024 * 1024)
        });
        this.closeNewModal();
      }
    });

    document.getElementById('btn-modal-cancel').addEventListener('click', () => {
      this.closeNewModal();
    });

    // Quick Sample URL buttons inside Modal
    document.querySelectorAll('.sample-url-tag').forEach(tag => {
      tag.addEventListener('click', () => {
        document.getElementById('input-url').value = tag.dataset.url;
        document.getElementById('input-filename').value = tag.dataset.name;
        document.getElementById('select-category').value = tag.dataset.cat;
        if (window.soundEngine) window.soundEngine.playPop();
      });
    });

    // Keyboard Shortcuts
    window.addEventListener('keydown', (e) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'n') {
        e.preventDefault();
        this.openNewModal();
      } else if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'f') {
        e.preventDefault();
        this.dom.searchInput.focus();
      } else if (e.key === 'Escape') {
        this.closeNewModal();
        this.closeDrawer();
      } else if (e.altKey && ['1','2','3','4'].includes(e.key)) {
        const themeMap = { '1': 'linear', '2': 'glass', '3': 'turbo', '4': 'bento' };
        this.setTheme(themeMap[e.key]);
      }
    });
  }

  setTheme(themeName) {
    this.currentTheme = themeName;
    document.body.className = `theme-${themeName}`;
    
    this.dom.themeButtons.forEach(b => {
      b.classList.toggle('active', b.dataset.theme === themeName);
    });

    const themeMeta = {
      'linear': {
        name: '⚡ Linear Dark',
        desc: 'Raycast / Linear 极简暗黑工程美学 · 极致信息密度与微发光'
      },
      'glass': {
        name: '💎 Liquid Glass',
        desc: 'macOS Sequoia / VisionOS 超细毛玻璃 · 液态渐变与拟物高光'
      },
      'turbo': {
        name: '🚀 Turbo Matrix',
        desc: '极速多线程机能风 · 32 线程实时分块矩阵与脉冲波形'
      },
      'bento': {
        name: '🍱 Bento Studio',
        desc: '包豪斯温润极简工作室 · Bento 便当盒多维卡片架构'
      }
    };

    if (this.dom.themeInfoPill) {
      this.dom.themeInfoPill.innerHTML = `<strong>${themeMeta[themeName].name}</strong> · <span>${themeMeta[themeName].desc}</span>`;
    }

    if (window.soundEngine) window.soundEngine.playSwitch();
    this.render(window.downloadEngine);
  }

  openNewModal() {
    this.dom.newDownloadModal.classList.add('active');
    document.getElementById('input-url').focus();
    if (window.soundEngine) window.soundEngine.playPop();
  }

  closeNewModal() {
    this.dom.newDownloadModal.classList.remove('active');
  }

  openDrawer(taskId) {
    window.downloadEngine.selectTask(taskId);
    this.isDrawerOpen = true;
    this.dom.taskDetailDrawer.classList.add('active');
  }

  closeDrawer() {
    this.isDrawerOpen = false;
    this.dom.taskDetailDrawer.classList.remove('active');
    if (window.soundEngine) window.soundEngine.playClick();
  }

  getFilteredTasks(tasks) {
    return tasks.filter(task => {
      // Status filter
      if (this.currentFilter && this.currentFilter !== 'all') {
        if (this.currentFilter === 'downloading' && task.status !== 'downloading') return false;
        if (this.currentFilter === 'completed' && task.status !== 'completed') return false;
        if (this.currentFilter === 'paused' && task.status !== 'paused') return false;
        if (this.currentFilter === 'trash') return false; // not in trash
      }

      // Type filter
      if (this.currentType && task.category !== this.currentType) {
        return false;
      }

      // Search query
      if (this.searchQuery) {
        return task.name.toLowerCase().includes(this.searchQuery) ||
               task.domain.toLowerCase().includes(this.searchQuery);
      }

      return true;
    });
  }

  render(engine) {
    // 1. Render Stats
    const speedMB = engine.globalSpeed / (1024 * 1024);
    if (this.dom.globalSpeedVal) {
      this.dom.globalSpeedVal.innerHTML = `<span class="stat-num">${speedMB.toFixed(1)}</span> <span class="stat-unit">MB/s</span>`;
    }

    let activeThreads = 0;
    engine.tasks.filter(t => t.status === 'downloading').forEach(t => activeThreads += t.connections);
    if (this.dom.activeThreadsVal) {
      this.dom.activeThreadsVal.textContent = activeThreads;
    }

    // 2. Render Canvas Sparklines & Gauges
    let strokeColor = 'rgba(59, 130, 246, 0.95)';
    let fillStart = 'rgba(59, 130, 246, 0.2)';
    if (this.currentTheme === 'turbo') {
      strokeColor = '#10b981';
      fillStart = 'rgba(16, 185, 129, 0.3)';
    } else if (this.currentTheme === 'glass') {
      strokeColor = '#38bdf8';
      fillStart = 'rgba(56, 189, 248, 0.25)';
    } else if (this.currentTheme === 'bento') {
      strokeColor = '#6366f1';
      fillStart = 'rgba(99, 102, 241, 0.2)';
    }

    if (this.dom.globalSparkline) {
      VisualizerRenderer.drawSparkline(this.dom.globalSparkline, engine.speedHistory, {
        strokeColor,
        fillColorStart: fillStart,
        fillColorEnd: 'rgba(0,0,0,0)'
      });
    }

    if (this.currentTheme === 'turbo' && this.dom.cyberGaugeCanvas) {
      VisualizerRenderer.drawCyberGauge(this.dom.cyberGaugeCanvas, speedMB);
    }

    // 3. Render Badges
    const countMap = {
      all: engine.tasks.length,
      downloading: engine.tasks.filter(t => t.status === 'downloading').length,
      completed: engine.tasks.filter(t => t.status === 'completed').length,
      paused: engine.tasks.filter(t => t.status === 'paused').length
    };
    Object.keys(countMap).forEach(key => {
      const badge = document.getElementById(`count-${key}`);
      if (badge) badge.textContent = countMap[key];
    });

    // 4. Render Task List
    const filteredTasks = this.getFilteredTasks(engine.tasks);
    if (filteredTasks.length === 0) {
      this.dom.taskList.innerHTML = `
        <div class="empty-state">
          <div class="empty-icon">📥</div>
          <h3>暂无匹配的下载任务</h3>
          <p>点击上方“+ 新建下载”或按 ⌘N 添加下载链接</p>
        </div>
      `;
    } else {
      this.dom.taskList.className = `task-container ${this.viewMode}-mode`;
      this.dom.taskList.innerHTML = filteredTasks.map(task => this.renderTaskCard(task)).join('');

      // Bind item event handlers
      filteredTasks.forEach(task => {
        const itemEl = document.getElementById(`item-${task.id}`);
        if (!itemEl) return;

        // Click on row to open drawer
        itemEl.addEventListener('click', (e) => {
          if (e.target.closest('.action-btn')) return; // Ignore if clicked action
          this.openDrawer(task.id);
        });

        // Toggle action
        const toggleBtn = itemEl.querySelector('.btn-toggle-task');
        if (toggleBtn) {
          toggleBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            window.downloadEngine.toggleTask(task.id);
          });
        }

        // Delete action
        const deleteBtn = itemEl.querySelector('.btn-delete-task');
        if (deleteBtn) {
          deleteBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            window.downloadEngine.deleteTask(task.id);
          });
        }

        // Reveal in folder action
        const folderBtn = itemEl.querySelector('.btn-folder-task');
        if (folderBtn) {
          folderBtn.addEventListener('click', (e) => {
            e.stopPropagation();
            if (window.electronAPI && window.electronAPI.showItemInFolder) {
              window.electronAPI.showItemInFolder(task.savePath);
            }
          });
        }
      });
    }

    // 5. Render Detail Drawer if open
    if (this.isDrawerOpen) {
      const selected = engine.getSelectedTask();
      if (selected) {
        this.renderDrawerContent(selected);
      }
    }
  }

  renderTaskCard(task) {
    const percent = Math.min(100, Math.round((task.downloaded / task.size) * 100));
    const isDownloading = task.status === 'downloading';
    const isCompleted = task.status === 'completed';
    const isPaused = task.status === 'paused';

    let statusTag = '';
    let actionIcon = '';
    let actionTitle = '';

    if (isDownloading) {
      statusTag = `<span class="status-pill downloading"><span class="pulse-dot"></span> 下载中</span>`;
      actionIcon = `<svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor"><rect width="4" height="16" x="6" y="4" rx="1"/><rect width="4" height="16" x="14" y="4" rx="1"/></svg>`;
      actionTitle = '暂停';
    } else if (isCompleted) {
      statusTag = `<span class="status-pill completed">✓ 已完成</span>`;
      actionIcon = `<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"/><polyline points="22 4 12 14.01 9 11.01"/></svg>`;
      actionTitle = '已就绪';
    } else if (isPaused) {
      statusTag = `<span class="status-pill paused">❚❚ 已暂停</span>`;
      actionIcon = `<svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor"><polygon points="5 3 19 12 5 21 5 3"/></svg>`;
      actionTitle = '恢复';
    }

    // Mini Chunk Bars for Turbo / Linear mode
    const miniChunksHtml = task.chunks.slice(0, 16).map(c => `
      <div class="chunk-slice ${c.status}" style="width: ${100/16}%;">
        <div class="chunk-fill" style="width: ${c.progress * 100}%;"></div>
      </div>
    `).join('');

    return `
      <div class="task-card ${task.status} ${window.downloadEngine.selectedTaskId === task.id ? 'selected' : ''}" id="item-${task.id}">
        <div class="card-left">
          <div class="file-icon-box cat-${task.category}">
            ${getFileIconSVG(task.category)}
          </div>
        </div>

        <div class="card-center">
          <div class="file-header-row">
            <div class="file-title-group">
              <span class="file-name" title="${task.name}">${task.name}</span>
              <span class="domain-tag">${task.domain}</span>
            </div>
            <div class="status-badge-group">
              ${statusTag}
              <span class="thread-badge">⚡ ${task.connections} 线程</span>
            </div>
          </div>

          <!-- Progress Visualizer Bar -->
          <div class="progress-bar-wrapper">
            <div class="progress-bar-track">
              <div class="progress-bar-fill" style="width: ${percent}%;">
                <div class="liquid-glimmer"></div>
              </div>
            </div>
          </div>

          <!-- Multi-thread Mini Matrix -->
          <div class="mini-chunk-matrix">
            ${miniChunksHtml}
          </div>

          <div class="file-meta-row">
            <div class="meta-left">
              <span class="meta-size">${formatBytes(task.downloaded)} / ${formatBytes(task.size)}</span>
              <span class="meta-percent">${percent}%</span>
            </div>
            <div class="meta-right">
              ${isDownloading ? `<span class="meta-speed">${formatSpeed(task.speed)}</span>` : ''}
              ${isDownloading ? `<span class="meta-eta">剩余 ${formatETA(task.size - task.downloaded, task.speed)}</span>` : ''}
              ${isCompleted ? `<span class="meta-time">已保存至下载目录</span>` : ''}
              ${isPaused ? `<span class="meta-time">任务已挂起</span>` : ''}
            </div>
          </div>
        </div>

        <div class="card-right-actions">
          ${!isCompleted ? `
            <button class="action-btn btn-toggle-task" title="${actionTitle}">
              ${actionIcon}
            </button>
          ` : ''}
          <button class="action-btn btn-folder-task" title="在访达中打开">
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M20 20a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2h-7.9a2 2 0 0 1-1.69-.9L9.6 3.9A2 2 0 0 0 7.93 3H4a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2Z"/></svg>
          </button>
          <button class="action-btn btn-delete-task danger" title="删除任务">
            <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><path d="M3 6h18"/><path d="M19 6v14c0 1-1 2-2 2H7c-1 0-2-1-2-2V6"/><path d="M8 6V4c0-1 1-2 2-2h4c1 0 2 1 2 2v2"/></svg>
          </button>
        </div>
      </div>
    `;
  }

  renderDrawerContent(task) {
    const percent = Math.min(100, Math.round((task.downloaded / task.size) * 100));
    
    document.getElementById('drawer-file-name').textContent = task.name;
    document.getElementById('drawer-file-domain').textContent = task.domain;
    document.getElementById('drawer-file-size').textContent = `${formatBytes(task.downloaded)} / ${formatBytes(task.size)} (${percent}%)`;
    document.getElementById('drawer-file-speed').textContent = formatSpeed(task.speed);
    document.getElementById('drawer-file-hash').textContent = task.hash;
    document.getElementById('drawer-file-path').textContent = task.savePath;

    // Render full 32-chunk grid
    const chunkGrid = document.getElementById('drawer-chunk-grid');
    if (chunkGrid) {
      chunkGrid.innerHTML = task.chunks.map(chunk => `
        <div class="chunk-cell ${chunk.status}">
          <div class="chunk-inner-fill" style="width: ${chunk.progress * 100}%;"></div>
          <div class="chunk-tooltip">
            <span>T#${chunk.threadIndex}</span>
            <span>${(chunk.progress * 100).toFixed(0)}%</span>
            <span>${chunk.speedKB} KB/s</span>
          </div>
        </div>
      `).join('');
    }

    // Render Drawer Sparkline
    const drawerCanvas = document.getElementById('drawer-sparkline-canvas');
    if (drawerCanvas) {
      VisualizerRenderer.drawSparkline(drawerCanvas, task.speedHistory, {
        strokeColor: '#38bdf8',
        fillColorStart: 'rgba(56, 189, 248, 0.3)',
        fillColorEnd: 'rgba(0,0,0,0)'
      });
    }
  }
}

// Instantiate on DOM load
window.addEventListener('DOMContentLoaded', () => {
  window.app = new AppController();
});
