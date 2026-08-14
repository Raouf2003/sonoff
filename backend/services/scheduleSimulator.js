function minutesOfDay(dt) {
  return dt.hour * 60 + dt.minute;
}

function steesDay(dt) {
  return (dt.weekday + 6) % 7;
}

function tasmotaDayPosition(steesDayValue) {
  return (steesDayValue + 1) % 7;
}

function minutesFromTime(hhmm) {
  if (typeof hhmm !== 'string') return null;
  const m = /^(\d{1,2}):([0-5]\d)$/.exec(hhmm);
  if (!m) return null;
  const h = parseInt(m[1], 10);
  if (h > 23) return null;
  return h * 60 + parseInt(m[2], 10);
}

function extractRuleActions(text) {
  const map = new Map();
  if (!text || typeof text !== 'string') return map;
  const clauseRe = /ON\s+Clock#Timer=(\d+)\s+DO\s+(.+?)\s+ENDON/gi;
  let clause;
  while ((clause = clauseRe.exec(text)) !== null) {
    const timerIndex = parseInt(clause[1], 10);
    const body = clause[2].trim();
    const actions = [];
    const commandRe = /Power(\d+)\s+(ON|OFF)/gi;
    let command;
    while ((command = commandRe.exec(body)) !== null) {
      actions.push({ channel: parseInt(command[1], 10), state: command[2].toUpperCase() });
    }
    if (actions.length) map.set(timerIndex, actions);
  }
  return map;
}

function simulateCompiledPlan(plan, dt) {
  if (!plan || !Array.isArray(plan.timers) || plan.timers.length === 0) return {};
  const dayPos = tasmotaDayPosition(steesDay(dt));
  const nowMin = minutesOfDay(dt);

  const actionsByTimer = new Map();
  for (const rule of plan.rules || []) {
    for (const [index, actions] of extractRuleActions(rule.text)) {
      actionsByTimer.set(index, actions);
    }
  }

  const events = [];
  for (const timer of plan.timers) {
    const config = timer.config || {};
    if (config.Enable === 0) continue;
    const mask = String(config.Days || '');
    if (!mask || mask[dayPos] !== '1') continue;
    const minutes = minutesFromTime(config.Time);
    if (minutes === null || minutes > nowMin) continue;
    const index = timer.index;
    if (config.Action === 1) {
      events.push({ order: minutes, key: index, channel: config.Output, state: 'ON' });
    } else if (config.Action === 0) {
      events.push({ order: minutes, key: index, channel: config.Output, state: 'OFF' });
    } else if (config.Action === 3) {
      const actions = actionsByTimer.get(index) || actionsByTimer.get(String(index)) || [];
      for (const action of actions) {
        events.push({ order: minutes, key: index, channel: action.channel, state: action.state });
      }
    }
  }

  events.sort((a, b) => a.order - b.order || a.key - b.key);
  const state = {};
  for (const event of events) state[event.channel] = event.state;
  return state;
}

module.exports = {
  simulateCompiledPlan,
  extractRuleActions,
  steesDay,
  tasmotaDayPosition,
  minutesOfDay,
  minutesFromTime,
};