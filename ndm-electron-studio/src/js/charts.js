/**
 * Real-time Canvas Visualizers: Sparklines, Waveforms, Speedometer
 */
class VisualizerRenderer {
  static drawSparkline(canvas, data, options = {}) {
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const width = canvas.width = canvas.offsetWidth * (window.devicePixelRatio || 1);
    const height = canvas.height = canvas.offsetHeight * (window.devicePixelRatio || 1);
    
    ctx.clearRect(0, 0, width, height);
    if (!data || data.length < 2) return;

    const max = Math.max(...data, 10);
    const step = width / (data.length - 1);

    const strokeColor = options.strokeColor || 'rgba(59, 130, 246, 0.9)';
    const fillColorStart = options.fillColorStart || 'rgba(59, 130, 246, 0.25)';
    const fillColorEnd = options.fillColorEnd || 'rgba(59, 130, 246, 0.0)';

    // Path
    ctx.beginPath();
    data.forEach((val, i) => {
      const x = i * step;
      const y = height - (val / max) * (height * 0.82) - 4;
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        // Smooth bezier curve
        const prevX = (i - 1) * step;
        const prevY = height - (data[i - 1] / max) * (height * 0.82) - 4;
        const cpX = (prevX + x) / 2;
        ctx.bezierCurveTo(cpX, prevY, cpX, y, x, y);
      }
    });

    // Fill area under curve
    ctx.save();
    const lastX = (data.length - 1) * step;
    const lastY = height - (data[data.length - 1] / max) * (height * 0.82) - 4;
    ctx.lineTo(lastX, height);
    ctx.lineTo(0, height);
    ctx.closePath();

    const gradient = ctx.createLinearGradient(0, 0, 0, height);
    gradient.addColorStop(0, fillColorStart);
    gradient.addColorStop(1, fillColorEnd);
    ctx.fillStyle = gradient;
    ctx.fill();
    ctx.restore();

    // Stroke line
    ctx.lineWidth = 2 * (window.devicePixelRatio || 1);
    ctx.strokeStyle = strokeColor;
    ctx.lineCap = 'round';
    ctx.lineJoin = 'round';
    ctx.stroke();

    // Pulse dot at the latest point
    const currentVal = data[data.length - 1];
    const dotX = (data.length - 1) * step;
    const dotY = height - (currentVal / max) * (height * 0.82) - 4;

    ctx.beginPath();
    ctx.arc(dotX, dotY, 3.5 * (window.devicePixelRatio || 1), 0, Math.PI * 2);
    ctx.fillStyle = strokeColor;
    ctx.shadowColor = strokeColor;
    ctx.shadowBlur = 8;
    ctx.fill();
  }

  static drawCyberGauge(canvas, currentSpeedMB, maxSpeedMB = 150) {
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    const width = canvas.width = canvas.offsetWidth * dpr;
    const height = canvas.height = canvas.offsetHeight * dpr;

    ctx.clearRect(0, 0, width, height);

    const centerX = width / 2;
    const centerY = height * 0.75;
    const radius = Math.min(width * 0.42, height * 0.65);

    const startAngle = Math.PI * 0.8;
    const endAngle = Math.PI * 2.2;
    const totalAngle = endAngle - startAngle;

    const ratio = Math.min(1, Math.max(0, currentSpeedMB / maxSpeedMB));
    const currentAngle = startAngle + totalAngle * ratio;

    // Background track ticks
    ctx.lineWidth = 4 * dpr;
    ctx.strokeStyle = 'rgba(255, 255, 255, 0.08)';
    ctx.beginPath();
    ctx.arc(centerX, centerY, radius, startAngle, endAngle);
    ctx.stroke();

    // Active progress arc
    if (ratio > 0.01) {
      const grad = ctx.createLinearGradient(0, 0, width, 0);
      grad.addColorStop(0, '#06b6d4');
      grad.addColorStop(0.5, '#3b82f6');
      grad.addColorStop(1, '#10b981');

      ctx.lineWidth = 6 * dpr;
      ctx.strokeStyle = grad;
      ctx.shadowColor = '#10b981';
      ctx.shadowBlur = 12 * dpr;
      ctx.lineCap = 'round';
      ctx.beginPath();
      ctx.arc(centerX, centerY, radius, startAngle, currentAngle);
      ctx.stroke();
      ctx.shadowBlur = 0;
    }

    // Dial needle or center read
    ctx.fillStyle = '#ffffff';
    ctx.font = `700 ${18 * dpr}px -apple-system, system-ui, sans-serif`;
    ctx.textAlign = 'center';
    ctx.textBaseline = 'middle';
    ctx.fillText(`${currentSpeedMB.toFixed(1)}`, centerX, centerY - 8 * dpr);

    ctx.fillStyle = 'rgba(255, 255, 255, 0.45)';
    ctx.font = `500 ${9 * dpr}px -apple-system, system-ui, sans-serif`;
    ctx.fillText('MB/S TURBO', centerX, centerY + 14 * dpr);
  }
}

window.VisualizerRenderer = VisualizerRenderer;
