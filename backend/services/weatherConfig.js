const APP_TIMEZONE = process.env.APP_TIMEZONE || 'Africa/Algiers';

function numEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;
  const n = Number(raw);
  return Number.isFinite(n) ? n : fallback;
}

function boolEnv(name, fallback) {
  const raw = process.env[name];
  if (raw === undefined || raw === null || raw === '') return fallback;
  return String(raw).toLowerCase() === 'true';
}

const config = {
  enabled: boolEnv('WEATHER_ENABLED', true),
  cacheTtlSeconds: numEnv('WEATHER_CACHE_TTL_SECONDS', 3600),
  rainMmThreshold: numEnv('WEATHER_RAIN_MM_THRESHOLD', 2),
  rainProbabilityThreshold: numEnv('WEATHER_RAIN_PROBABILITY_THRESHOLD', 50),
  adjacentWindowMinutes: numEnv('WEATHER_ADJACENT_MINUTES', 60),
  forecastDays: numEnv('WEATHER_FORECAST_DAYS', 3),
  requestTimeoutMs: numEnv('WEATHER_REQUEST_TIMEOUT_MS', 8000),
  timezone: APP_TIMEZONE,
};

function isValidCoords(lat, lon) {
  return (
    typeof lat === 'number' &&
    typeof lon === 'number' &&
    Number.isFinite(lat) &&
    Number.isFinite(lon) &&
    lat >= -90 &&
    lat <= 90 &&
    lon >= -180 &&
    lon <= 180
  );
}

module.exports = { config, isValidCoords, APP_TIMEZONE };
