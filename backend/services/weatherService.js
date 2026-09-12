const { config, isValidCoords, APP_TIMEZONE } = require('./weatherConfig');

const BASE_URL = 'https://api.open-meteo.com/v1/forecast';

// In-memory cache: key `${lat},${lon},${timezone}` -> { expiresAt, data }.
// Shared across devices at the same farm so 10 devices on one coordinate
// produce exactly 1 Open-Meteo request per TTL window.
const cache = new Map();

function cacheKey(lat, lon, timezone) {
  return `${Number(lat).toFixed(4)},${Number(lon).toFixed(4)},${timezone}`;
}

function clearCache() {
  cache.clear();
}

function cacheStats() {
  return { entries: cache.size };
}

function buildUrl(lat, lon, timezone, forecastDays) {
  const params = new URLSearchParams({
    latitude: String(lat),
    longitude: String(lon),
    hourly: 'temperature_2m,precipitation,precipitation_probability',
    timezone,
    forecast_days: String(forecastDays),
  });
  return `${BASE_URL}?${params.toString()}`;
}

function normalizeHourly(payload, timezone) {
  const hourly = (payload && payload.hourly) || {};
  const times = hourly.time || [];
  const temps = hourly.temperature_2m || [];
  const precips = hourly.precipitation || [];
  const probs = hourly.precipitation_probability || [];
  const out = [];
  for (let i = 0; i < times.length; i++) {
    out.push({
      localTime: String(times[i]),
      temperature: typeof temps[i] === 'number' ? temps[i] : null,
      precipitationMm: typeof precips[i] === 'number' ? precips[i] : 0,
      precipitationProbability: typeof probs[i] === 'number' ? probs[i] : 0,
    });
  }
  return { timezone, hourly: out };
}

async function fetchWithTimeout(url, timeoutMs, fetchFn) {
  const impl = fetchFn || fetch;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await impl(url, { signal: controller.signal });
    if (!res || typeof res.ok === 'boolean' && !res.ok) {
      const err = new Error(`Open-Meteo HTTP ${res ? res.status : 'unknown'}`);
      err.code = 'WEATHER_HTTP';
      throw err;
    }
    return res.json();
  } catch (err) {
    if (err && err.name === 'AbortError') {
      const e = new Error('Open-Meteo request timed out');
      e.code = 'WEATHER_TIMEOUT';
      throw e;
    }
    throw err;
  } finally {
    clearTimeout(timer);
  }
}

// Advisory-only fetch. NEVER throws into irrigation/control code paths:
// callers should catch, but this also guards unknown shapes. Returns null
// when disabled, unconfigured, or on any provider failure.
async function getForecast({ lat, lon, timezone, fetchFn, nowMs } = {}) {
  const tz = timezone || APP_TIMEZONE;
  if (!config.enabled) return null;
  if (!isValidCoords(lat, lon)) return null;
  const key = cacheKey(lat, lon, tz);
  const now = nowMs !== undefined ? nowMs : Date.now();
  const hit = cache.get(key);
  if (hit && hit.expiresAt > now) return hit.data;

  const url = buildUrl(lat, lon, tz, config.forecastDays);
  let payload;
  try {
    payload = await fetchWithTimeout(url, config.requestTimeoutMs, fetchFn);
  } catch (err) {
    console.warn(`[weather] provider failed (${err && err.code ? err.code : err && err.message}): no advisory`);
    return null;
  }
  const data = normalizeHourly(payload, tz);
  cache.set(key, { expiresAt: now + config.cacheTtlSeconds * 1000, data });
  return data;
}

module.exports = {
  getForecast,
  normalizeHourly,
  buildUrl,
  cacheKey,
  clearCache,
  cacheStats,
  BASE_URL,
};
