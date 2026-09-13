const { config } = require('./weatherConfig');

function intervalMs() {
  const raw = process.env.WEATHER_NOTIFY_INTERVAL_MS;
  const n = raw !== undefined && raw !== '' ? Number(raw) : 3 * 3600 * 1000;
  return Number.isFinite(n) && n >= 60 * 1000 ? n : 3 * 3600 * 1000;
}

class WeatherNotifyScheduler {
  constructor({ runFn, logger } = {}) {
    this.runFn = runFn || null;
    this.logger = logger || console;
    this.timer = null;
    this._running = false;
  }

  _getRun() {
    if (this.runFn) return this.runFn;
    // Lazy require to avoid circular init with server.js
    return require('./weatherNotifyService').runWeatherNotify;
  }

  async _tick(io) {
    if (this._running) return { status: 'skipped-busy' };
    this._running = true;
    try {
      const run = this._getRun();
      const res = await run({ io });
      if (res && (res.notified > 0 || res.advisories > 0)) {
        this.logger.log(`[weatherScheduler] sweep notified=${res.notified} advisories=${res.advisories} checked=${res.checked}`);
      }
      return res;
    } catch (err) {
      this.logger.error(`[weatherScheduler] sweep error: ${err.message}`);
      return { status: 'failed', error: err.message };
    } finally {
      this._running = false;
    }
  }

  start(io, { interval = intervalMs(), immediate = true } = {}) {
    if (this.timer) clearInterval(this.timer);
    const jitter = Math.floor(Math.random() * 5 * 60 * 1000);
    const ms = interval + jitter;
    this.logger.log(`[weatherScheduler] start every ${Math.round(ms / 1000)}s (base ${Math.round(interval / 1000)}s + jitter ${Math.round(jitter / 1000)}s)`);
    if (immediate) {
      // Startup sweep — fire-and-forget, never blocks server listen
      setImmediate(() => this._tick(io).catch(() => {}));
    }
    this.timer = setInterval(() => this._tick(io).catch(() => {}), ms);
    if (this.timer.unref) this.timer.unref();
    return this.timer;
  }

  stop() {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  // For schedule/location event triggers — fire-and-forget single device
  trigger(deviceId, io) {
    if (!deviceId) return;
    setImmediate(() => {
      const run = this._getRun();
      run({ deviceId: String(deviceId), io }).catch((e) => this.logger.error(`[weatherScheduler] trigger ${deviceId}: ${e.message}`));
    });
  }
}

module.exports = new WeatherNotifyScheduler();
module.exports.WeatherNotifyScheduler = WeatherNotifyScheduler;
module.exports.intervalMs = intervalMs;
