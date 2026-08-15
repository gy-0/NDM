/**
 * NDM Download Engine Simulator
 * Accurately models multi-threaded segmented downloads, connection chunk progression,
 * bandwidth allocation, and real-time network waveforms.
 */
class DownloadEngine {
  constructor() {
    this.speedLimitMB = 0; // 0 = unlimited
    this.globalSpeed = 0;
    this.speedHistory = Array(40).fill(0);
    this.tasks = [];
    this.selectedTaskId = null;
    this.subscribers = new Set();
    
    this.initDefaultTasks();
    this.startTicker();
  }

  initDefaultTasks() {
    this.tasks = [
      {
        id: 'task-1',
        name: 'UnrealEngine-5.5.3-macOS-AppleSilicon.dmg',
        url: 'https://download.epicgames.com/builds/mac/UE5.5.3-arm64.dmg',
        size: 19845000000, // 19.84 GB
        downloaded: 13420000000, // 13.42 GB
        status: 'downloading',
        category: 'apps',
        connections: 16,
        chunks: this.generateChunks(16, 0.68),
        speed: 42.5 * 1024 * 1024,
        createdAt: Date.now() - 360000,
        domain: 'epicgames.com',
        savePath: '/Users/gaoyuan/Downloads/Applications',
        hash: 'sha256: 8f4e2b919a3c89df...',
        headers: {
          'Accept-Ranges': 'bytes',
          'Content-Type': 'application/x-apple-diskimage',
          'Server': 'Cloudflare / AWS CloudFront',
          'HTTP-Version': 'HTTP/2.0 TLS 1.3'
        },
        speedHistory: Array(25).fill(40)
      },
      {
        id: 'task-2',
        name: 'LLaMA-3.1-70B-Instruct-Q4_K_M.gguf',
        url: 'https://huggingface.co/bartowski/Meta-Llama-3.1-70B-Instruct-GGUF/resolve/main/llama-3.1-70b-instruct.Q4_K_M.gguf',
        size: 42680000000, // 42.68 GB
        downloaded: 18900000000, // 18.9 GB
        status: 'downloading',
        category: 'archives',
        connections: 32,
        chunks: this.generateChunks(32, 0.44),
        speed: 58.2 * 1024 * 1024,
        createdAt: Date.now() - 1200000,
        domain: 'huggingface.co',
        savePath: '/Users/gaoyuan/Downloads/Models',
        hash: 'sha256: d18b6e00192a54ff...',
        headers: {
          'Accept-Ranges': 'bytes',
          'Content-Type': 'application/octet-stream',
          'Server': 'Cloudflare CDN Edge',
          'HTTP-Version': 'HTTP/2.0 TLS 1.3'
        },
        speedHistory: Array(25).fill(55)
      },
      {
        id: 'task-3',
        name: 'BlackMyth_Wukong_4K_HDR_Benchmark_Raw.mp4',
        url: 'https://cdn.videocraft.io/samples/4k_hdr/bm_wukong_scene3.mp4',
        size: 4890000000, // 4.89 GB
        downloaded: 4890000000,
        status: 'completed',
        category: 'video',
        connections: 16,
        chunks: this.generateChunks(16, 1.0),
        speed: 0,
        createdAt: Date.now() - 7200000,
        domain: 'videocraft.io',
        savePath: '/Users/gaoyuan/Downloads/Videos',
        hash: 'sha256: e5c339a117b489aa...',
        headers: {
          'Accept-Ranges': 'bytes',
          'Content-Type': 'video/mp4'
        },
        speedHistory: Array(25).fill(0)
      },
      {
        id: 'task-4',
        name: 'Hans_Zimmer_Live_Prague_Master_FLAC.zip',
        url: 'https://hifi-lossless.net/albums/hans-zimmer-live-prague-24bit.zip',
        size: 3420000000, // 3.42 GB
        downloaded: 1850000000,
        status: 'paused',
        category: 'audio',
        connections: 8,
        chunks: this.generateChunks(8, 0.54),
        speed: 0,
        createdAt: Date.now() - 86400000,
        domain: 'hifi-lossless.net',
        savePath: '/Users/gaoyuan/Downloads/Music',
        hash: 'sha256: 3a92ff41cd56e...',
        headers: {
          'Accept-Ranges': 'bytes',
          'Content-Type': 'application/zip'
        },
        speedHistory: Array(25).fill(0)
      },
      {
        id: 'task-5',
        name: 'DeepSeek-R1-Technical-Report-v1.2.pdf',
        url: 'https://arxiv.org/pdf/2501.12948.pdf',
        size: 18500000, // 18.5 MB
        downloaded: 18500000,
        status: 'completed',
        category: 'documents',
        connections: 4,
        chunks: this.generateChunks(4, 1.0),
        speed: 0,
        createdAt: Date.now() - 172800000,
        domain: 'arxiv.org',
        savePath: '/Users/gaoyuan/Downloads/Documents',
        hash: 'sha256: bb7723af890123...',
        headers: {
          'Accept-Ranges': 'bytes',
          'Content-Type': 'application/pdf'
        },
        speedHistory: Array(25).fill(0)
      }
    ];

    this.selectedTaskId = this.tasks[0].id;
  }

  generateChunks(count, overallProgress) {
    const chunks = [];
    for (let i = 0; i < count; i++) {
      // Add slight organic variance per thread
      let chunkProgress;
      if (overallProgress >= 1.0) {
        chunkProgress = 1.0;
      } else {
        const variance = (Math.sin(i * 1.5) * 0.15);
        chunkProgress = Math.max(0.05, Math.min(0.99, overallProgress + variance));
      }
      chunks.push({
        id: i,
        threadIndex: i + 1,
        progress: chunkProgress,
        status: overallProgress >= 1.0 ? 'done' : (chunkProgress > 0.95 ? 'flushing' : 'active'),
        speedKB: Math.round(1800 + Math.random() * 2400)
      });
    }
    return chunks;
  }

  startTicker() {
    setInterval(() => {
      this.tick();
    }, 500);
  }

  tick() {
    let totalSpeed = 0;
    const downloadingTasks = this.tasks.filter(t => t.status === 'downloading');

    downloadingTasks.forEach(task => {
      // Base speed with organic noise
      const targetSpeed = (task.id === 'task-1' ? 44 : 62) * (0.88 + Math.random() * 0.24);
      let currentSpeedMB = targetSpeed;

      // Apply limit if set
      if (this.speedLimitMB > 0) {
        const perTaskLimit = this.speedLimitMB / Math.max(1, downloadingTasks.length);
        currentSpeedMB = Math.min(currentSpeedMB, perTaskLimit);
      }

      task.speed = currentSpeedMB * 1024 * 1024;
      totalSpeed += task.speed;

      // Advance downloaded bytes (500ms interval = 0.5s)
      const deltaBytes = Math.round(task.speed * 0.5);
      task.downloaded = Math.min(task.size, task.downloaded + deltaBytes);

      // Advance chunks
      const overallRatio = task.downloaded / task.size;
      task.chunks.forEach(c => {
        if (c.progress < 1) {
          c.progress = Math.min(1, c.progress + (deltaBytes / task.size) * (0.8 + Math.random() * 0.4));
          c.speedKB = Math.round((task.speed / 1024 / task.connections) * (0.85 + Math.random() * 0.3));
        } else {
          c.status = 'done';
          c.speedKB = 0;
        }
      });

      // Update task speed history
      task.speedHistory.push(currentSpeedMB);
      if (task.speedHistory.length > 30) task.speedHistory.shift();

      // Check for completion
      if (task.downloaded >= task.size) {
        task.status = 'completed';
        task.speed = 0;
        task.chunks.forEach(c => { c.progress = 1; c.status = 'done'; c.speedKB = 0; });
        if (window.soundEngine) window.soundEngine.playComplete();
        if (window.electronAPI && window.electronAPI.showNotification) {
          window.electronAPI.showNotification({
            title: 'NDM 下载完成',
            body: `${task.name} 已成功下载并校验完毕！`
          });
        }
      }
    });

    this.globalSpeed = totalSpeed;
    const globalSpeedMB = totalSpeed / (1024 * 1024);
    this.speedHistory.push(globalSpeedMB);
    if (this.speedHistory.length > 40) this.speedHistory.shift();

    this.notify();
  }

  subscribe(fn) {
    this.subscribers.add(fn);
    return () => this.subscribers.delete(fn);
  }

  notify() {
    this.subscribers.forEach(fn => fn(this));
  }

  addTask({ name, url, category, connections = 16, size = 2500000000 }) {
    let detectedDomain = 'unknown.host';
    try {
      detectedDomain = new URL(url).hostname;
    } catch (e) {
      detectedDomain = 'download.server.com';
    }

    const newTask = {
      id: 'task-' + Date.now(),
      name: name || 'Downloaded_File_' + Date.now().toString().slice(-4),
      url: url,
      size: size,
      downloaded: 0,
      status: 'downloading',
      category: category || 'others',
      connections: connections,
      chunks: this.generateChunks(connections, 0.02),
      speed: 35 * 1024 * 1024,
      createdAt: Date.now(),
      domain: detectedDomain,
      savePath: '/Users/gaoyuan/Downloads',
      hash: 'sha256: calculating...',
      headers: {
        'Accept-Ranges': 'bytes',
        'Content-Type': 'application/octet-stream',
        'Server': 'NDM Turbo Multi-Connection Node'
      },
      speedHistory: Array(25).fill(25)
    };

    this.tasks.unshift(newTask);
    this.selectedTaskId = newTask.id;
    if (window.soundEngine) window.soundEngine.playPop();
    this.notify();
  }

  toggleTask(taskId) {
    const task = this.tasks.find(t => t.id === taskId);
    if (!task) return;

    if (task.status === 'downloading') {
      task.status = 'paused';
      task.speed = 0;
      task.chunks.forEach(c => c.speedKB = 0);
    } else if (task.status === 'paused' || task.status === 'error') {
      task.status = 'downloading';
    }
    if (window.soundEngine) window.soundEngine.playClick();
    this.notify();
  }

  pauseAll() {
    this.tasks.forEach(t => {
      if (t.status === 'downloading') {
        t.status = 'paused';
        t.speed = 0;
        t.chunks.forEach(c => c.speedKB = 0);
      }
    });
    if (window.soundEngine) window.soundEngine.playClick();
    this.notify();
  }

  resumeAll() {
    this.tasks.forEach(t => {
      if (t.status === 'paused') {
        t.status = 'downloading';
      }
    });
    if (window.soundEngine) window.soundEngine.playClick();
    this.notify();
  }

  deleteTask(taskId) {
    this.tasks = this.tasks.filter(t => t.id !== taskId);
    if (this.selectedTaskId === taskId) {
      this.selectedTaskId = this.tasks[0]?.id || null;
    }
    if (window.soundEngine) window.soundEngine.playClick();
    this.notify();
  }

  setSpeedLimit(limitMB) {
    this.speedLimitMB = limitMB;
    if (window.soundEngine) window.soundEngine.playSwitch();
    this.notify();
  }

  selectTask(taskId) {
    this.selectedTaskId = taskId;
    if (window.soundEngine) window.soundEngine.playClick();
    this.notify();
  }

  getSelectedTask() {
    return this.tasks.find(t => t.id === this.selectedTaskId) || this.tasks[0] || null;
  }
}

window.downloadEngine = new DownloadEngine();
