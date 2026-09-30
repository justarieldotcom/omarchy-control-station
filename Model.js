// Model.js — pure parsers for justarieldotcom.control-station
// No side effects. Each function takes raw input and returns structured data.
// Run: node -e "require('./Model.js').selfCheck()"

// ============================================================ Yahoo Finance

function parseYahooSpark(json, orderList) {
  try {
    var data = typeof json === "string" ? JSON.parse(json) : json
    var result = []
    for (var key in data) {
      var entry = data[key]
      if (!entry || !entry.symbol) continue
      var close = entry.close
      var price = close && close.length > 0 ? close[close.length - 1] : null
      result.push({
        symbol: entry.symbol,
        price: price,
        change: Number(entry.fulldayChange || 0),
        changePercent: Number(entry.fulldayChangePercent || 0),
        isDown: Number(entry.fulldayChange || 0) < 0
      })
    }
    if (isList(orderList) && orderList.length > 0) {
      var rank = {}
      for (var o = 0; o < orderList.length; o++) {
        if (String(orderList[o] || "").trim() !== "") rank[String(orderList[o]).trim().toUpperCase()] = o
      }
      result.sort(function(a, b) {
        var ra = rank[a.symbol] !== undefined ? rank[a.symbol] : 100000
        var rb = rank[b.symbol] !== undefined ? rank[b.symbol] : 100000
        if (ra !== rb) return ra - rb
        return a.symbol.localeCompare(b.symbol)
      })
    } else {
      result.sort(function(a, b) { return a.symbol.localeCompare(b.symbol) })
    }
    return { symbols: result, checkedAt: formatTimeNow() }
  } catch (e) {
    return { symbols: [], checkedAt: "" }
  }
}

// ============================================================ Companies House

function parseCompaniesHouse(json) {
  try {
    var data = typeof json === "string" ? JSON.parse(json) : json
    var topic = data.primaryTopic || {}
    var accounts = topic.Accounts || {}
    var returns = topic.Returns || {}
    return {
      companyName: topic.CompanyName || "",
      accountsNextDue: accounts.NextDueDate || "",
      returnsNextDue: returns.NextDueDate || "",
      accountsUrgent: isDueSoon(accounts.NextDueDate),
      returnsUrgent: isDueSoon(returns.NextDueDate),
      checkedAt: formatTimeNow()
    }
  } catch (e) {
    return { companyName: "", accountsNextDue: "", returnsNextDue: "",
             accountsUrgent: false, returnsUrgent: false, checkedAt: "" }
  }
}

function parseCompaniesHouseBatch(text) {
  var chunks = String(text || "").split("@@CH@NEXT@@")
  var companies = []
  if (chunks.length === 1) {
    var single = parseCompaniesHouse(chunks[0])
    if (single.companyName !== "") companies.push(single)
  } else {
    for (var i = 0; i < chunks.length; i++) {
      var chunk = String(chunks[i] || "").trim()
      if (chunk === "") continue
      var c = parseCompaniesHouse(chunk)
      if (c.companyName !== "") companies.push(c)
    }
  }
  var seen = {}, out = []
  for (var j = 0; j < companies.length; j++) {
    var n = companies[j].companyName
    if (!n || seen[n]) continue
    seen[n] = true
    out.push(companies[j])
  }
  return { companies: out, checkedAt: formatTimeNow() }
}

function parseChDate(dateStr) {
  var parts = String(dateStr || "").split("/")
  if (parts.length !== 3) return null
  var day = Number(parts[0]), month = Number(parts[1]), year = Number(parts[2])
  if (!day || !month || !year) return null
  if (month < 1 || month > 12 || day < 1 || day > 31) return null
  var date = new Date(year, month - 1, day)
  return isNaN(date.getTime()) ? null : date
}

function isDueSoon(dateStr) {
  var due = parseChDate(dateStr)
  if (!due) return false
  var now = new Date()
  var diffMs = due.getTime() - now.getTime()
  var diffDays = diffMs / (1000 * 60 * 60 * 24)
  return diffDays <= 30 && diffDays >= 0
}

var MONTH_LABELS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]

function formatDateCh(dateStr) {
  if (!dateStr) return "\u2014"
  var date = parseChDate(dateStr)
  if (!date) return String(dateStr)
  return date.getDate() + " " + MONTH_LABELS[date.getMonth()] + " " + date.getFullYear()
}

// Year-less whenever the deadline lands in the current one, which is the only
// year a bar reader can already infer.
function formatDateChShort(dateStr) {
  var date = parseChDate(dateStr)
  if (!date) return formatDateCh(dateStr)
  if (date.getFullYear() === new Date().getFullYear())
    return date.getDate() + " " + MONTH_LABELS[date.getMonth()]
  return formatDateCh(dateStr)
}

// ============================================================ iCal / Google Calendar

// The secret iCal URL is a credential: in argv it is readable by any local
// user through ps or /proc/<pid>/cmdline. Panel.qml hands it to `curl -K -`
// over stdin instead, as this one config line. Anything but a single-line
// http(s) URL returns "", so a stray newline cannot smuggle in a second curl
// option (`output = ...`).
function curlConfigUrl(url) {
  var u = String(url || "").trim()
  if (!/^https?:\/\//i.test(u) || /[\r\n\u0000]/.test(u)) return ""
  return 'url = "' + u.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"\n'
}

function unfoldICalLines(text) {
  var lines = String(text || "").replace(/\r\n/g, "\n").split("\n")
  var result = []
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].match(/^[ \t]/) && result.length > 0) {
      result[result.length - 1] += lines[i].substring(1)
    } else {
      result.push(lines[i])
    }
  }
  return result
}

function parseICalDate(str) {
  var s = String(str || "").replace(/[^0-9T]/g, "")
  // An all-day event carries a bare date (VALUE=DATE, `20261225`), which is
  // what Google emits for birthdays, holidays and anything spanning whole
  // days. Midnight local is the right instant for it: the day is the fact.
  if (s.length === 8) {
    return new Date(Number(s.substring(0, 4)), Number(s.substring(4, 6)) - 1,
                    Number(s.substring(6, 8)))
  }
  if (s.length < 15) return null
  return new Date(
    Number(s.substring(0, 4)),
    Number(s.substring(4, 6)) - 1,
    Number(s.substring(6, 8)),
    Number(s.substring(9, 11)),
    Number(s.substring(11, 13))
  )
}

// A content line is `NAME` then optional `;PARAM=VALUE` pairs then `:VALUE`.
// Matching on `NAME:` alone silently drops `DTSTART;VALUE=DATE:20261225` and
// `DTSTART;TZID=Europe/London:20261225T093000` -- between them, most of a real
// Google feed. Returns null when this line is some other property.
function icalValue(line, name) {
  var text = String(line || "")
  if (text.substring(0, name.length) !== name) return null
  var next = text.charAt(name.length)
  if (next !== ":" && next !== ";") return null
  var colon = text.indexOf(":")
  if (colon < 0) return null
  return { value: text.substring(colon + 1), params: text.substring(name.length, colon) }
}

function isAllDayLine(line, name) {
  var part = icalValue(line, name)
  if (!part) return false
  if (part.params.indexOf("VALUE=DATE") >= 0) return true
  // A feed may leave the parameter off and simply give a bare date.
  return /^[0-9]{8}$/.test(part.value.trim())
}

function parseICal(text) {
  var lines = unfoldICalLines(text)
  var events = []
  var inEvent = false, summary = "", dtstart = null, dtend = null, allDay = false

  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line === "BEGIN:VEVENT") {
      inEvent = true; summary = ""; dtstart = null; dtend = null; allDay = false
    } else if (line === "END:VEVENT") {
      inEvent = false
      if (summary && dtstart) {
        events.push({
          summary: summary,
          dtstart: dtstart,
          dtend: dtend,
          allDay: allDay,
          // An all-day event has no time to show, and the card's time column is
          // too narrow for a word. Leaving it empty lets the date carry it and
          // keeps the summaries on one line.
          dtstartStr: allDay ? "" : formatEventTime(dtstart),
          dateStr: formatEventDate(dtstart)
        })
      }
    } else if (inEvent) {
      var summaryPart = icalValue(line, "SUMMARY")
      var startPart = icalValue(line, "DTSTART")
      var endPart = icalValue(line, "DTEND")
      if (summaryPart) summary = summaryPart.value
      else if (startPart) {
        dtstart = parseICalDate(startPart.value)
        allDay = isAllDayLine(line, "DTSTART")
      } else if (endPart) dtend = parseICalDate(endPart.value)
    }
  }

  var now = new Date()
  events.sort(function(a, b) { return a.dtstart.getTime() - b.dtstart.getTime() })
  var upcoming = []
  for (var j = 0; j < events.length; j++) {
    // A timed event stays listed for an hour after it starts; an all-day one
    // is current until its day is over, which is the whole point of it.
    var cutoff = events[j].allDay
      ? events[j].dtstart.getTime() + 86400000
      : events[j].dtstart.getTime() + 3600000
    if (cutoff >= now.getTime()) {
      upcoming.push(events[j])
      if (upcoming.length >= 5) break
    }
  }
  return { events: upcoming, checkedAt: formatTimeNow() }
}

function formatEventTime(date) {
  if (!date) return ""
  return String(date.getHours()).padStart(2, "0") + ":" + String(date.getMinutes()).padStart(2, "0")
}

function formatEventDate(date) {
  if (!date) return ""
  var now = new Date()
  var today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  var eventDay = new Date(date.getFullYear(), date.getMonth(), date.getDate())
  var diffDays = Math.round((eventDay.getTime() - today.getTime()) / 86400000)
  if (diffDays === 0) return "Today"
  if (diffDays === 1) return "Tomorrow"
  // A weekday name only locates a date inside the coming week. Beyond that it
  // is a guess -- "Fri" for a holiday three months out reads as this Friday --
  // so anything further away states the date instead.
  if (diffDays > 1 && diffDays < 7) {
    var days = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]
    return days[date.getDay()]
  }
  return date.getDate() + " " + MONTH_LABELS[date.getMonth()]
}

// ============================================================ System Stats

function parseSystemOutput(text) {
  var lines = String(text || "").split("\n")
  var cpuTotal = 0, cpuIdle = 0, memory = 0, load = 0
  var diskTotal = "", diskUsed = "", diskPercent = 0
  var tempRaw = 0

  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts[0] === "cpu" && parts.length >= 3) {
      cpuIdle = Number(parts[1]) || 0
      cpuTotal = Number(parts[2]) || 0
    } else if (parts[0] === "memory" && parts.length >= 2) {
      memory = Number(parts[1]) || 0
    } else if (parts[0] === "load" && parts.length >= 2) {
      load = Number(parts[1]) || 0
    } else if (parts[0] === "disk" && parts.length >= 4) {
      diskTotal = parts[1] || ""
      diskUsed = parts[2] || ""
      diskPercent = parseInt(String(parts[3]).replace("%", "")) || 0
    } else if (parts[0] === "temp" && parts.length >= 2) {
      tempRaw = Number(parts[1]) || 0
    }
  }

  return {
    cpuPercent: cpuTotal > 0 ? clampPercent(Math.round((1 - cpuIdle / cpuTotal) * 100)) : 0,
    memoryPercent: clampPercent(Math.round(memory)),
    loadAverage: clampZero(load),
    diskTotal: diskTotal,
    diskUsed: diskUsed,
    diskPercent: diskPercent,
    tempCelsius: tempRaw > 1000 ? Math.round(tempRaw / 1000) : (tempRaw > 0 ? Math.round(tempRaw) : -1)
  }
}

// ============================================================ Reminders

function parseRemindersJson(json) {
  try {
    var data = typeof json === "string" ? JSON.parse(json) : json
    return {
      count: Number(data.count || 0),
      active: !!data.active,
      reminders: Array.isArray(data.reminders) ? data.reminders : [],
      checkedAt: formatTimeNow()
    }
  } catch (e) {
    return { count: 0, active: false, reminders: [], checkedAt: "" }
  }
}

// ============================================================ Weather Current

function parseWeatherCurrent(json, townName) {
  try {
    var data = typeof json === "string" ? JSON.parse(json) : json
    var current = data.current || {}
    if (!current.temperature_2m && current.temperature_2m !== 0) return { weather: null }
    return {
      weather: {
        town: String(townName || ""),
        temp: Number(current.temperature_2m),
        humidity: Number(current.relative_humidity_2m || 0),
        wind: Number(current.wind_speed_10m || 0),
        code: Number(current.weather_code || 0),
        isDay: Number(current.is_day || 1) === 1,
        icon: weatherIconForCode(current.weather_code, Number(current.is_day || 1) === 1),
        forecast: buildForecast(data.daily),
        checkedAt: formatTimeNow()
      }
    }
  } catch (e) {
    return { weather: null }
  }
}

function buildForecast(daily) {
  if (!daily) return []
  var times = daily.time || []
  var codes = daily.weather_code || []
  var maxs = daily.temperature_2m_max || []
  var mins = daily.temperature_2m_min || []
  var out = []
  var start = 1
  var end = Math.min(4, times.length)
  if (end <= start) { start = 0; end = 1 }
  if (times.length === 0) return []
  for (var i = start; i < end; i++) {
    out.push({
      day: formatDayLabel(times[i]),
      icon: weatherIconForCode(codes[i] !== undefined ? codes[i] : 0, true),
      max: Math.round(Number(maxs[i] || 0)),
      min: Math.round(Number(mins[i] || 0))
    })
  }
  return out
}

function formatDayLabel(isoStr) {
  var m = String(isoStr || "").match(/^(\d{4})-(\d{2})-(\d{2})/)
  if (!m) return ""
  var d = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]))
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  return days[d.getDay()]
}

function parseGeocodingResults(json) {
  try {
    var data = typeof json === "string" ? JSON.parse(json) : json
    var results = data.results || []
    var out = []
    for (var i = 0; i < results.length; i++) {
      if (!results[i] || !results[i].name) continue
      var parts = []
      if (results[i].admin1) parts.push(String(results[i].admin1))
      if (results[i].country) parts.push(String(results[i].country))
      out.push({
        name: String(results[i].name),
        latitude: Number(results[i].latitude),
        longitude: Number(results[i].longitude),
        description: parts.join(", ")
      })
    }
    return out
  } catch (e) {
    return []
  }
}

// ============================================================ Market presets

var MARKET_PRESETS = {
  "Stocks": ["AAPL", "MSFT", "TSLA", "NVDA", "GOOGL", "AMZN"],
  "Crypto": ["BTC-USD", "ETH-USD", "SOL-USD"],
  "Metals": ["GC=F", "SI=F"]
}
var DEFAULT_SYMBOLS = "AAPL,MSFT,TSLA,NVDA,BTC-USD,ETH-USD"

function toggleSymbolsPreset(currentSymbols, presetKey) {
  var preset = MARKET_PRESETS[presetKey]
  if (!preset) return String(currentSymbols || DEFAULT_SYMBOLS)
  var list = String(currentSymbols || "").split(",").map(function(s) { return s.trim() }).filter(function(s) { return s !== "" })
  var set = {}
  for (var i = 0; i < list.length; i++) set[list[i]] = true
  var allActive = true
  for (var j = 0; j < preset.length; j++) if (!set[preset[j]]) { allActive = false; break }
  for (var k = 0; k < preset.length; k++) {
    if (allActive) delete set[preset[k]]
    else set[preset[k]] = true
  }
  var result = Object.keys(set)
  if (result.length === 0) result = DEFAULT_SYMBOLS.split(",")
  return result.join(",")
}

function isPresetActive(currentSymbols, presetKey) {
  var preset = MARKET_PRESETS[presetKey]
  if (!preset) return false
  var list = String(currentSymbols || "").split(",").map(function(s) { return s.trim() })
  var set = {}
  for (var i = 0; i < list.length; i++) set[list[i]] = true
  for (var j = 0; j < preset.length; j++) if (!set[preset[j]]) return false
  return true
}

// ============================================================ Repos

// Newline or comma separated, `~` expanded against the caller's home, order
// kept, repeats dropped.
function parseRepoPaths(raw, home) {
  var out = [], seen = {}
  var root = String(home || "")
  var text = String(raw === undefined || raw === null ? "" : raw)
  var parts = text.split(/[\n,]/)
  for (var i = 0; i < parts.length; i++) {
    var value = String(parts[i] || "").trim()
    if (value === "") continue
    if (value.charAt(0) === "~") {
      if (root === "") continue
      value = value === "~" ? root : root + value.substring(1)
    }
    value = value.replace(/\/+$/, "") || "/"
    if (seen[value]) continue
    seen[value] = true
    out.push(value)
  }
  return out
}

// `--porcelain=v2 --branch` answers ahead/behind in the header, so one call per
// repo is the whole story. The XY pair per file splits staged (X) from working
// tree (Y), which is the difference between "1 change" and "1 staged".
function parseGitStatus(text) {
  var lines = String(text || "").split("\n")
  var branch = "", upstream = "", ahead = 0, behind = 0, error = ""
  var changed = 0, untracked = 0, staged = 0
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.indexOf("fatal:") === 0 || line.indexOf("error:") === 0) {
      if (error === "") error = gitStatusError(line)
      continue
    }
    if (line.indexOf("# branch.head ") === 0) branch = line.substring(14).trim()
    else if (line.indexOf("# branch.upstream ") === 0) upstream = line.substring(18).trim()
    else if (line.indexOf("# branch.ab ") === 0) {
      var ab = line.substring(13).trim().split(/\s+/)
      ahead = Math.max(0, parseInt(ab[0], 10) || 0)
      behind = Math.max(0, parseInt(ab[1], 10) || 0)
    } else if (line === "" || line.charAt(0) === "#") continue
    else if (line.indexOf("? ") === 0) untracked++
    else if (line.indexOf("1 ") === 0 || line.indexOf("2 ") === 0 || line.indexOf("u ") === 0) {
      changed++
      if (line.charAt(2) !== ".") staged++
    }
  }
  return {
    branch: branch,
    upstream: upstream,
    ahead: ahead,
    behind: behind,
    changed: changed,
    staged: staged,
    untracked: untracked,
    // Nothing to push, nothing to pull, nothing edited: the row can be calm.
    dirty: changed + untracked + ahead + behind > 0,
    error: error
  }
}

function gitStatusError(stderr) {
  var text = String(stderr || "")
  if (text.indexOf("not a git repository") !== -1) return "not a repo"
  if (text === "") return "no answer"
  return text.split("\n")[0].trim().substring(0, 40)
}

// One shell call walks the repos in turn and prints `@@REPO@@<path>` ahead of
// each block, which is what makes a serial batch attributable per repo.
function parseRepoBatch(text) {
  var rows = []
  var chunks = String(text || "").split("@@REPO@@")
  for (var i = 1; i < chunks.length; i++) {
    var block = chunks[i]
    var split = block.indexOf("\n")
    var path = (split === -1 ? block : block.substring(0, split)).trim()
    var body = split === -1 ? "" : block.substring(split + 1)
    if (path === "") continue
    var status = parseGitStatus(body)
    status.path = path
    status.name = path.split("/").filter(function(s) { return s !== "" }).pop() || path
    rows.push(status)
  }
  return rows
}

// ============================================================ Containers

// One `docker ps -a` call: name, state, human status. Nothing to parse beyond
// the tab split, so the parser is the whole cost.
function parseDockerPs(text) {
  var lines = String(text || "").split("\n")
  var rows = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    var parts = line.split("\t")
    if (parts.length < 2 || parts[0] === "") continue
    var state = String(parts[1] || "").toLowerCase()
    rows.push({
      name: String(parts[0]),
      state: state,
      running: state === "running",
      status: parts.length > 2 ? String(parts[2]) : "",
      error: ""
    })
  }
  return { rows: rows, running: countRunning(rows), total: rows.length, checkedAt: formatTimeNow() }
}

function countRunning(rows) {
  var n = 0
  for (var i = 0; i < (rows || []).length; i++) if (rows[i] && rows[i].running) n++
  return n
}

// Docker fails loudly and specifically, and the difference matters to whoever
// reads the card: no socket, no permission, or no binary at all.
function dockerErrorText(stderr, exitCode) {
  var text = String(stderr || "")
  if (text.indexOf("Cannot connect to the Docker daemon") !== -1
    || text.indexOf("Is the docker daemon running") !== -1) return "daemon not running"
  if (text.indexOf("permission denied") !== -1) return "permission denied"
  if (text.indexOf("docker: not found") !== -1 || text.indexOf("command not found") !== -1
    || text.indexOf("No such file or directory") !== -1) return "docker not installed"
  var line = text.split("\n").filter(function(s) { return String(s).trim() !== "" })[0]
  if (line) return line.trim().substring(0, 44)
  return "unavailable (exit " + (parseInt(exitCode, 10) || 0) + ")"
}

// ============================================================ VPN

// nmcli's VPN profiles, emitted by the panel under a backend header. Sections
// split on an @@VPN@@ marker so a second backend can be appended later without
// reshaping the emitter; a section whose header is not a known backend is
// skipped rather than guessed at.
function parseVpnListings(text) {
  var out = { backends: [], connections: [] }
  var sections = String(text || "").split("@@VPN@@")
  for (var s = 0; s < sections.length; s++) {
    var lines = sections[s].split("\n")
    var at = 0
    while (at < lines.length && String(lines[at]).trim() === "") at++
    if (at >= lines.length) continue
    var kind = String(lines[at]).trim()
    if (kind !== "openvpn") continue
    out.backends.push(kind)
    for (var i = at + 1; i < lines.length; i++) {
      var line = lines[i].trim()
      if (line === "") continue
      var parts = line.split("|")
      if (parts.length < 2) continue
      var name = String(parts[0]).replace(/\\:/g, ":").trim()
      if (name === "") continue
      var state = parts.length > 2 ? String(parts[2]).toLowerCase() : ""
      out.connections.push({
        kind: kind,
        name: name,
        state: state,
        active: state === "activated",
        // nmcli keeps the row in "activating" while it dials out, so the card
        // can hold a fast poll until the tunnel settles.
        activating: state === "activating" || state === "deactivating"
      })
    }
  }
  return out
}

// ============================================================ Inbox

// The notification service archives one JSON object per line in its history
// directory; `awk 1 *.json` concatenates them. Newest first, and a file that is
// not an object is skipped rather than losing the rest of the list.
function parseInboxHistory(text, limit) {
  var rows = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (line === "") continue
    var entry = null
    try { entry = JSON.parse(line) } catch (e) { entry = null }
    if (!entry || typeof entry !== "object") continue
    var summary = String(entry.summary || "").trim()
    if (summary === "") continue
    rows.push({
      app: String(entry.app || ""),
      summary: summary,
      body: String(entry.body || ""),
      glyph: String(entry.glyph || ""),
      appIcon: String(entry.appIcon || ""),
      urgency: parseInt(entry.urgency, 10) || 0,
      at: Number(entry.timestamp || 0)
    })
  }
  rows.sort(function(a, b) { return b.at - a.at })
  var max = Math.max(1, parseInt(limit, 10) || 5)
  return rows.length > max ? rows.slice(0, max) : rows
}

function relativeTime(stampMs, nowMs) {
  var at = Number(stampMs || 0)
  if (!(at > 0)) return ""
  var seconds = Math.round((Number(nowMs || 0) - at) / 1000)
  if (seconds < 0) return "now"
  if (seconds < 60) return "now"
  if (seconds < 3600) return Math.floor(seconds / 60) + "m"
  if (seconds < 86400) return Math.floor(seconds / 3600) + "h"
  return Math.floor(seconds / 86400) + "d"
}

// ============================================================ Timer

var TIMER_MODES = [
  { id: "focus", label: "FOCUS", seconds: 25 * 60, sessions: 4 },
  { id: "break", label: "BREAK", seconds: 5 * 60, sessions: 1 },
  { id: "stopwatch", label: "STOPWATCH", seconds: 0, sessions: 1 }
]

function timerMode(id) {
  for (var i = 0; i < TIMER_MODES.length; i++) if (TIMER_MODES[i].id === id) return TIMER_MODES[i]
  return TIMER_MODES[0]
}

// A running timer persists as an absolute deadline, so closing the panel or
// restarting the shell resumes it where it actually is; a stopped one persists
// the seconds left.
function parseTimerState(raw) {
  var data = {}
  try {
    var parsed = JSON.parse(String(raw || ""))
    if (parsed && typeof parsed === "object") data = parsed
  } catch (e) { data = {} }
  var mode = timerMode(String(data.mode || ""))
  var running = data.running === true
  var now = Date.now()
  var remaining = parseInt(data.remaining, 10)
  if (running) {
    var endsAt = Number(data.endsAt || 0)
    remaining = endsAt > 0 ? Math.ceil((endsAt - now) / 1000) : (isFinite(remaining) ? remaining : 0)
  } else if (!isFinite(remaining) || remaining < 0) {
    remaining = mode.seconds
  }
  var elapsed = Math.max(0, parseInt(data.elapsed, 10) || 0)
  return {
    mode: mode.id,
    label: mode.label,
    running: running,
    remaining: Math.max(0, remaining),
    total: mode.seconds > 0 ? mode.seconds : Math.max(remaining, elapsed),
    sessions: Math.max(1, parseInt(data.sessions, 10) || 1),
    done: Math.max(0, Math.min(63, parseInt(data.done, 10) || 0)),
    elapsed: elapsed
  }
}

function formatClock(seconds) {
  var total = Math.max(0, Math.round(Number(seconds) || 0))
  var hours = Math.floor(total / 3600)
  var minutes = Math.floor((total % 3600) / 60)
  var secs = total % 60
  function two(n) { return (n < 10 ? "0" : "") + n }
  return hours > 0 ? hours + ":" + two(minutes) + ":" + two(secs) : two(minutes) + ":" + two(secs)
}

// ============================================================ Card registry

// The one list of cards. Panel.qml reads titles, groups, and the enable set from
// here, so adding a card is one entry here plus its body component.
//   default  ships in the enabled set when the `cards` setting is absent
//   bar      makes sense as a bar glyph, so it may be picked in `barItems`
//   glyph    the static bar mark; "" means the card brings its own state glyph
//   needs    what must be true before the picker offers it. `key` is a setting
//            name or a probe result the panel feeds in under the same name.
var CARDS = [
  { id: "weather", title: "WEATHER", group: "Dashboard", summary: "Current conditions and 3-day forecast",
    default: true, bar: true, glyph: "",
    needs: [{ key: "weatherTown", why: "Set a location in settings" }] },
  { id: "market", title: "MARKET", group: "Dashboard", summary: "Quotes for the symbols in settings",
    default: true, bar: true, glyph: "\uf080", needs: [] },
  { id: "calendar", title: "CALENDAR", group: "Dashboard", summary: "Next events from your iCal feed",
    default: true, bar: true, glyph: "\uf133",
    needs: [{ key: "calendarIcalUrl", why: "Add an iCal URL in settings" }] },
  { id: "companies", title: "COMPANY", group: "Dashboard", summary: "Companies House filing deadlines",
    default: true, bar: true, glyph: "\uf1ad",
    needs: [{ key: "companiesHouseNumber", why: "Add a company number in settings" }] },
  { id: "reminders", title: "REMINDERS", group: "Dashboard", summary: "Omarchy reminders still waiting",
    default: true, bar: true, glyph: "\uf0f3", needs: [] },
  { id: "system", title: "SYSTEM", group: "Dashboard", summary: "CPU, memory, disk, temperature",
    default: true, bar: true, glyph: "\uf108", needs: [] },

  { id: "media", title: "MEDIA", group: "Now", summary: "Now playing, with transport",
    default: false, bar: true, glyph: "\uf03e4", needs: [] },
  { id: "timer", title: "TIMER", group: "Now", summary: "Focus timer and stopwatch",
    default: false, bar: true, glyph: "\uf017", needs: [] },
  { id: "inbox", title: "INBOX", group: "Now", summary: "Recent notifications, plus do-not-disturb",
    default: false, bar: true, glyph: "\uf01e", needs: [] },

  { id: "vpn", title: "VPN", group: "System", summary: "NetworkManager VPN connections",
    default: false, bar: true, glyph: "\uf132",
    needs: [{ key: "vpnBackend", why: "No VPN backend found" }] },
  { id: "containers", title: "CONTAINERS", group: "System", summary: "Docker containers and their state",
    default: false, bar: true, glyph: "\uf187",
    needs: [{ key: "dockerBin", why: "Docker is not installed" }] },
  { id: "repos", title: "REPOS", group: "System", summary: "Git working trees and their branch state",
    default: false, bar: false, glyph: "",
    needs: [{ key: "repoPaths", why: "Add repo paths in settings" }] }
]

function cardById(id) {
  for (var i = 0; i < CARDS.length; i++) if (CARDS[i].id === id) return CARDS[i]
  return null
}

function defaultCardIds() {
  var out = []
  for (var i = 0; i < CARDS.length; i++) if (CARDS[i].default) out.push(CARDS[i].id)
  return out
}

// A settings value can be a real array (the gear view), a JSON array (a hand
// edit or `omarchy bar set --json`), or a comma string; all three name cards.
// A setting read out of shell.json is a QML sequence type: `typeof` says
// "object" and `Array.isArray` says false, so code that checks for a real array
// quietly treats a user's list as something else. Anything list-shaped counts.
function isList(value) {
  if (value === null || value === undefined) return false
  if (Array.isArray(value)) return true
  if (typeof value === "string") return false
  return typeof value.length === "number"
}

// A plain JS array copy, because sequence types have no map/filter/slice.
function toList(value) {
  var out = []
  if (!isList(value)) return out
  for (var i = 0; i < value.length; i++) out.push(value[i])
  return out
}

function idList(raw) {
  if (isList(raw)) return toList(raw)
  var text = String(raw === undefined || raw === null ? "" : raw).trim()
  if (text === "") return []
  if (text.charAt(0) === "[") {
    try {
      var parsed = JSON.parse(text)
      if (Array.isArray(parsed)) return parsed
    } catch (e) { return [] }
  }
  return text.split(",")
}

// The enabled set, in display order. Nothing is force-appended: a card the user
// switched off stays off, and an id that is not in the registry drops out. The
// registry defaults apply only when neither the current nor the legacy setting
// names a card, which is what a fresh install and a pre-registry upgrade both
// look like. An explicit empty array is an answer, not an absence: it is the
// picker saying "no cards".
function enabledCards(raw, legacy) {
  var list = idList(raw)
  var out = knownIds(list)
  if (out.length > 0) return out
  // An empty result means two different things. A setting that holds an empty
  // container ("[]", from a shell.json edit as much as from the picker) is someone
  // deliberately choosing no cards, so honour it -- reading that as "never set"
  // quietly hands their cards back on the next restart. A setting that is
  // absent, blank, or full of ids that no longer exist is a value we cannot
  // act on, so fall back.
  // An array is always a deliberate value, even an empty one -- note that
  // String([]) is "", so the blank-string test cannot decide this.
  var written = isList(raw)
    || (raw !== undefined && raw !== null && String(raw).trim() !== "")
  if (list.length === 0 && written) return []
  out = knownIds(idList(legacy))
  if (out.length === 0) return defaultCardIds()
  return out
}

function knownIds(wanted) {
  var seen = {}, out = []
  var list = wanted === undefined || wanted === null
    ? CARDS.map(function(card) { return card.id })
    : wanted
  for (var i = 0; i < list.length; i++) {
    var id = String(list[i] || "").trim()
    if (seen[id] || !cardById(id)) continue
    seen[id] = true
    out.push(id)
  }
  return out
}

function moveCard(enabled, id, delta) {
  var list = enabledCards(enabled)
  var at = list.indexOf(id)
  if (at === -1) return list
  var to = at + (Number(delta) < 0 ? -1 : 1)
  if (to < 0 || to >= list.length) return list
  list.splice(to, 0, list.splice(at, 1)[0])
  return list
}

// Drag-and-drop drops a card *on* a position, so the panel needs a move-to-index
// beside moveCard's one-step nudge. An out-of-range target clamps to the ends
// rather than dropping the move: a chip dragged past the last one means last.
function reorderCard(enabled, id, toIndex) {
  var list = enabledCards(enabled)
  var at = list.indexOf(id)
  var want = parseInt(toIndex, 10)
  if (at === -1 || !isFinite(want)) return list
  var to = Math.max(0, Math.min(want, list.length - 1))
  if (to === at) return list
  list.splice(to, 0, list.splice(at, 1)[0])
  return list
}

function toggleCard(enabled, id) {
  if (!cardById(id)) return enabledCards(enabled)
  var list = enabledCards(enabled)
  var at = list.indexOf(id)
  if (at !== -1) { list.splice(at, 1); return list }
  // A new card lands in its registry position rather than at the end, so
  // enabling Repos does not strand it below System.
  var registry = []
  for (var r = 0; r < CARDS.length; r++) registry.push(CARDS[r].id)
  var to = 0
  while (to < list.length && registry.indexOf(list[to]) < registry.indexOf(id)) to++
  list.splice(to, 0, id)
  return list
}

// The reason a card cannot be picked yet, or "" when it can. `values` is a plain
// object of setting values and probe results, keyed like the registry's `needs`.
function missingNeeds(id, values) {
  var card = cardById(id)
  if (!card || !card.needs) return ""
  for (var i = 0; i < card.needs.length; i++) {
    var need = card.needs[i]
    var value = values ? values[need.key] : undefined
    var met = typeof value === "boolean" ? value
      : String(value === undefined || value === null ? "" : value).trim() !== ""
    if (!met) return String(need.why || "Not configured yet")
  }
  return ""
}

// [{ group, cards: [...] }] for the picker, registry order preserved.
function grouped() {
  var order = [], byGroup = {}
  for (var i = 0; i < CARDS.length; i++) {
    var group = CARDS[i].group
    if (!byGroup[group]) { byGroup[group] = []; order.push(group) }
    byGroup[group].push(CARDS[i])
  }
  var out = []
  for (var j = 0; j < order.length; j++) out.push({ group: order[j], cards: byGroup[order[j]] })
  return out
}

// ============================================================ Weather Icon

function weatherIconForCode(code, isDay) {
  var c = parseInt(String(code || "0"), 10)
  if (c === 0) return isDay ? "\uf185" : "\ue346"
  if (c === 1) return isDay ? "\uf185" : "\ue346"
  if (c === 2) return isDay ? "\uf185" : "\ue346"
  if (c === 3) return "\uf0c2"
  if (c === 45 || c === 48) return "\ue313"
  if (c >= 51 && c <= 57) return "\uf094"
  if (c >= 61 && c <= 67) return "\uf094"
  if (c >= 71 && c <= 77) return "\uf076"
  if (c >= 80 && c <= 82) return "\uf094"
  if (c >= 85 && c <= 86) return "\uf076"
  if (c >= 95 && c <= 99) return "\uf0e7"
  return "\uf0c2"
}

// ============================================================ Bar face

// The shell's own media transport marks, so a card that shows transport agrees
// with the bar pill glyph for glyph.
var GLYPH_PLAY = "\uf03e4"
var GLYPH_PAUSE = "\uf040a"
var GLYPH_NEXT = "\uf04ad"
var GLYPH_PREVIOUS = "\uf04ae"
var GLYPH_DND = "\uf009b"
var GLYPH_TIMER = "\uf017"
var GLYPH_INBOX = "\uf01e"
var GLYPH_VPN = "\uf132"
var GLYPH_CONTAINER = "\uf187"

// Cards that make sense as a bar glyph, in registry order.
var BAR_ITEM_IDS = []
for (var _b = 0; _b < CARDS.length; _b++) if (CARDS[_b].bar) BAR_ITEM_IDS.push(CARDS[_b].id)
var DEFAULT_BAR_ITEMS = ["weather"]
var MAX_BAR_SYMBOLS = 3

// Weather supplies its own condition glyph; the rest get a static mark.
function barItemLabel(id) {
  var card = cardById(id)
  return card ? card.title : String(id || "").toUpperCase()
}

function barItemGlyph(id) {
  var card = cardById(id)
  return card && card.glyph ? card.glyph : ""
}

function splitList(raw) {
  var out = []
  var parts = String(raw === undefined || raw === null ? "" : raw).split(",")
  for (var i = 0; i < parts.length; i++) {
    var value = String(parts[i] || "").trim()
    if (value !== "") out.push(value)
  }
  return out
}

// Takes the settings array, a JSON array, or a comma string, so the same
// reader works for the gear view, `omarchy bar set --json`, and a hand edit.
// Order is display order; unknown ids and repeats drop out.
function parseBarItems(raw, fallback) {
  // Only a real array is taken at face value, empty included: that is the gear
  // view saying "icon only". Anything else that names no valid card is junk
  // and falls back to the default.
  var explicit = isList(raw)
  var source = null
  if (explicit) {
    source = toList(raw)
  } else {
    var text = String(raw === undefined || raw === null ? "" : raw).trim()
    if (text !== "") {
      if (text.charAt(0) === "[") {
        try {
          var parsed = JSON.parse(text)
          if (Array.isArray(parsed)) source = parsed
        } catch (e) { source = null }
      }
      if (source === null) source = splitList(text)
    }
  }

  var result = [], seen = {}
  for (var i = 0; source !== null && i < source.length; i++) {
    var id = String(source[i] || "").trim().toLowerCase()
    if (BAR_ITEM_IDS.indexOf(id) === -1 || seen[id]) continue
    seen[id] = true
    result.push(id)
  }

  if (result.length === 0 && !explicit) {
    var base = isList(fallback) ? toList(fallback) : DEFAULT_BAR_ITEMS
    for (var j = 0; j < base.length; j++) {
      var candidate = String(base[j] || "").trim().toLowerCase()
      if (BAR_ITEM_IDS.indexOf(candidate) === -1 || seen[candidate]) continue
      seen[candidate] = true
      result.push(candidate)
    }
  }
  return result
}

// A filter over the panel's own symbol list, never a second source of truth: a
// symbol the market fetch never asked for has no price to show.
function parseBarSymbols(raw, allSymbols, max) {
  var pool = splitList(allSymbols)
  var limit = Math.max(1, Math.min(parseInt(max, 10) || 2, MAX_BAR_SYMBOLS))
  var wanted = splitList(raw)
  if (wanted.length === 0) return pool.slice(0, limit)
  var result = []
  for (var i = 0; i < wanted.length && result.length < limit; i++) {
    if (pool.indexOf(wanted[i]) !== -1) result.push(wanted[i])
  }
  return result
}

function toggleBarItem(current, id) {
  var list = parseBarItems(current).slice()
  var at = list.indexOf(id)
  if (at !== -1) list.splice(at, 1)
  else list.push(id)
  return list
}

function moveBarItem(current, id, delta) {
  var list = parseBarItems(current).slice()
  var at = list.indexOf(id)
  if (at === -1) return list
  var to = at + (Number(delta) < 0 ? -1 : 1)
  if (to < 0 || to >= list.length) return list
  list.splice(to, 0, list.splice(at, 1)[0])
  return list
}

// The bar-face twin of reorderCard: same clamp, same no-op rules.
function reorderBarItem(current, id, toIndex) {
  var list = parseBarItems(current).slice()
  var at = list.indexOf(id)
  var want = parseInt(toIndex, 10)
  if (at === -1 || !isFinite(want)) return list
  var to = Math.max(0, Math.min(want, list.length - 1))
  if (to === at) return list
  list.splice(to, 0, list.splice(at, 1)[0])
  return list
}

// One chip of the bar face. `hasData` false means the card has nothing to say
// yet, so the bar drops it rather than showing a placeholder.
// The panel owns the state; the bar only renders it. This is the one place
// that knows how panel properties map onto the names barChip reads, so the
// two entry points cannot drift apart over a rename.
function barData(panel) {
  var p = panel || {}
  var countdown = p.timerModeId !== "stopwatch"
  return {
    weather: p.weather,
    market: p.market,
    companies: p.companies,
    calendar: p.calendar,
    system: p.system,
    reminders: p.reminders,
    mediaPlayer: p.mediaPlayer,
    // One number, two readings: `timerSeconds` is the stopwatch's elapsed time
    // or the countdown's time left, depending on the mode.
    timer: {
      mode: p.timerModeId,
      running: !!p.timerRunning,
      elapsed: countdown ? 0 : p.timerSeconds,
      remaining: countdown ? p.timerSeconds : 0,
      total: p.timerTotal
    },
    inboxRows: p.inboxRows,
    dnd: !!p.inboxDnd,
    vpnConnections: p.vpnConnections,
    containers: p.containers
  }
}

function barChip(id, data, options) {
  var d = data || {}
  var o = options || {}
  var chip = { id: String(id || ""), icon: barItemGlyph(id), text: "", urgent: false, hasData: false }

  if (chip.id === "weather") {
    var weather = d.weather
    if (!weather || weather.temp === undefined || weather.temp === null) return chip
    var temp = Number(weather.temp)
    if (!isFinite(temp)) return chip
    if (weather.icon) chip.icon = String(weather.icon)
    chip.text = Math.round(temp) + "\u00b0"
    chip.hasData = true
    return chip
  }

  if (chip.id === "market") {
    var quotes = (d.market && Array.isArray(d.market.symbols)) ? d.market.symbols : []
    var wanted = Array.isArray(o.symbols) ? o.symbols : []
    var picked = []
    for (var i = 0; i < wanted.length; i++) {
      for (var j = 0; j < quotes.length; j++) {
        if (String(quotes[j].symbol) === String(wanted[i])) { picked.push(quotes[j]); break }
      }
    }
    if (picked.length === 0 && wanted.length > 0) picked = quotes.slice(0, 1)
    if (picked.length === 0) return chip
    var parts = [], down = false
    for (var k = 0; k < picked.length; k++) {
      if (picked[k].isDown) down = true
      var figures = [String(picked[k].symbol), formatPrice(picked[k].price),
                     formatPct(picked[k].changePercent)]
      parts.push(figures.filter(function(part) { return String(part) !== "" }).join(" "))
    }
    chip.text = parts.join("  ")
    chip.urgent = down
    chip.hasData = true
    return chip
  }

  if (chip.id === "companies") {
    var companies = Array.isArray(d.companies) ? d.companies : []
    var soonest = null, soonestText = ""
    for (var c = 0; c < companies.length; c++) {
      var company = companies[c]
      if (!company) continue
      var dates = [company.accountsNextDue, company.returnsNextDue]
      for (var f = 0; f < dates.length; f++) {
        var due = parseChDate(dates[f])
        if (!due) continue
        if (soonest === null || due.getTime() < soonest.getTime()) {
          soonest = due
          soonestText = String(dates[f])
        }
      }
    }
    if (soonest === null) return chip
    chip.text = "CH " + formatDateChShort(soonestText)
    chip.urgent = isDueSoon(soonestText)
    chip.hasData = true
    return chip
  }

  if (chip.id === "calendar") {
    var events = (d.calendar && Array.isArray(d.calendar.events)) ? d.calendar.events : []
    if (events.length === 0) return chip
    var event = events[0]
    var when = [event.dateStr, event.dtstartStr].filter(function(part) {
      return String(part || "") !== ""
    }).join(" ")
    chip.text = (when + " " + truncateText(event.summary, 18)).replace(/\s+/g, " ").trim()
    chip.urgent = String(event.dateStr) === "Today"
    chip.hasData = true
    return chip
  }

  if (chip.id === "system") {
    var sys = d.system || {}
    var readings = []
    if (isFinite(Number(sys.cpuPercent)) && Number(sys.cpuPercent) >= 0)
      readings.push("CPU " + Math.round(Number(sys.cpuPercent)) + "%")
    if (isFinite(Number(sys.memoryPercent)) && Number(sys.memoryPercent) >= 0)
      readings.push("MEM " + Math.round(Number(sys.memoryPercent)) + "%")
    if (isFinite(Number(sys.tempCelsius)) && Number(sys.tempCelsius) > 0)
      readings.push(Math.round(Number(sys.tempCelsius)) + "\u00b0C")
    if (readings.length === 0) return chip
    chip.text = readings.join(" ")
    chip.hasData = true
    return chip
  }

  if (chip.id === "reminders") {
    var reminders = d.reminders || {}
    var count = Number(reminders.count || 0)
    if (!isFinite(count) || count <= 0) return chip
    chip.text = String(Math.round(count))
    chip.urgent = true
    chip.hasData = true
    return chip
  }

  if (chip.id === "media") {
    var player = d.mediaPlayer || null
    if (!player) return chip
    var title = String(player.trackTitle || player.trackArtist || "")
    if (title === "") return chip
    chip.icon = player.isPlaying ? GLYPH_PLAY : GLYPH_PAUSE
    chip.text = truncateText(title, 22)
    chip.urgent = false
    chip.hasData = true
    return chip
  }

  if (chip.id === "timer") {
    var timer = d.timer || null
    if (!timer) return chip
    if (timer.mode === "stopwatch") {
      chip.text = formatClock(timer.elapsed)
      chip.hasData = timer.elapsed > 0
    } else {
      chip.text = formatClock(timer.remaining)
      chip.urgent = timer.running
      chip.hasData = timer.running || timer.remaining !== timer.total
    }
    if (chip.hasData) chip.icon = GLYPH_TIMER
    return chip
  }

  if (chip.id === "inbox") {
    var rows = Array.isArray(d.inboxRows) ? d.inboxRows : []
    if (d.dnd === true) {
      chip.icon = GLYPH_DND
      chip.text = "DND"
      chip.urgent = true
      chip.hasData = true
      return chip
    }
    if (rows.length === 0) return chip
    chip.icon = GLYPH_INBOX
    chip.text = String(rows.length)
    chip.urgent = rows[0].urgency >= 2
    chip.hasData = true
    return chip
  }

  if (chip.id === "vpn") {
    var conns = Array.isArray(d.vpnConnections) ? d.vpnConnections : []
    var live = null
    for (var v = 0; v < conns.length; v++) if (conns[v] && conns[v].active) { live = conns[v]; break }
    if (live) {
      chip.icon = GLYPH_VPN
      chip.text = String(live.name)
      chip.hasData = true
      return chip
    }
    if (conns.length > 0) {
      chip.icon = GLYPH_VPN
      chip.text = "OFF"
      chip.hasData = true
      return chip
    }
    return chip
  }

  if (chip.id === "containers") {
    var dock = d.containers || null
    if (!dock) return chip
    var running = Number(dock.running || 0)
    var total = Number(dock.total || 0)
    if (total === 0) return chip
    chip.icon = GLYPH_CONTAINER
    chip.text = running + "/" + total
    chip.urgent = false
    chip.hasData = true
    return chip
  }

  return chip
}

// ============================================================ Helpers

function formatPrice(v) {
  var n = Number(v)
  return isFinite(n) ? n.toFixed(2) : "\u2014"
}

function formatPct(v) {
  var n = Number(v)
  if (!isFinite(n)) return ""
  return (n > 0 ? "+" : "") + n.toFixed(1) + "%"
}

function truncateText(text, max) {
  var value = String(text || "").trim()
  var limit = Math.max(1, parseInt(max, 10) || 12)
  return value.length <= limit ? value : value.substring(0, limit - 1).trim() + "\u2026"
}

function formatTimeNow() {
  var now = new Date()
  return String(now.getHours()).padStart(2, "0") + ":" + String(now.getMinutes()).padStart(2, "0")
}

function clampPercent(v) {
  return Math.max(0, Math.min(100, Math.round(v) || 0))
}

function clampZero(v) {
  var n = Number(v) || 0
  return n > 0 ? n : 0
}

function formatCountdown(totalSeconds) {
  if (!(totalSeconds > 0)) return "now"
  var minutes = Math.floor(totalSeconds / 60)
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return days + "d " + (hours % 24) + "h"
  if (hours > 0) return hours + "h " + (minutes % 60) + "m"
  return Math.max(1, minutes) + "m"
}

function escapeHtml(text) {
  return String(text || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
}

// ============================================================ Self-Check

function selfCheck() {
  function assert(condition, message) {
    if (!condition) throw new Error("Assertion failed: " + message)
  }

  // ---- barData + the six new chips
  // The bar is a second entry point onto the same state, so the adapter and
  // every chip branch built on top of it get checked here rather than by
  // squinting at a 40px strip.
  var barPanel = {
    weather: { temp: 12.4, icon: "\uF00D" },
    mediaPlayer: { trackTitle: "Song", trackArtist: "Band", isPlaying: true },
    timerModeId: "focus", timerRunning: true, timerSeconds: 1250, timerTotal: 1500,
    inboxRows: [{ title: "a", urgency: 2 }], inboxDnd: false,
    vpnConnections: [{ name: "work", active: true }, { name: "home", active: false }],
    containers: { running: 2, total: 5 }
  }
  var bar = barData(barPanel)
  assert(bar.weather.temp === 12.4, "barData: weather passed through")
  assert(bar.dnd === false, "barData: dnd mirrors inboxDnd")
  assert(bar.timer.running === true && bar.timer.remaining === 1250 && bar.timer.elapsed === 0,
         "barData: a countdown reports remaining, not elapsed")
  assert(barData({ timerModeId: "stopwatch", timerSeconds: 42, timerTotal: 0 }).timer.elapsed === 42,
         "barData: a stopwatch reports elapsed")
  assert(barData(undefined).weather === undefined, "barData: no panel is not a crash")

  var mediaChip = barChip("media", bar, {})
  assert(mediaChip.hasData && mediaChip.text === "Song", "chip media: the track title")
  assert(mediaChip.icon === GLYPH_PLAY, "chip media: playing is the play glyph")
  assert(barChip("media", barData({}), {}).hasData === false, "chip media: no player, no chip")

  var timerChip = barChip("timer", bar, {})
  assert(timerChip.hasData && timerChip.text === formatClock(1250), "chip timer: the time left")
  assert(timerChip.urgent === true, "chip timer: a running timer is urgent")
  assert(barChip("timer", barData({ timerModeId: "focus", timerRunning: false,
      timerSeconds: 1500, timerTotal: 1500 }), {}).hasData === false,
         "chip timer: an untouched timer stays hidden")

  var inboxChip = barChip("inbox", bar, {})
  assert(inboxChip.hasData && inboxChip.text === "1" && inboxChip.urgent === true,
         "chip inbox: the count, urgent on the top row's urgency")
  var dndChip = barChip("inbox", barData({ inboxDnd: true }), {})
  assert(dndChip.hasData && dndChip.text === "DND" && dndChip.icon === GLYPH_DND,
         "chip inbox: DND wins over the count")
  assert(barChip("inbox", barData({}), {}).hasData === false, "chip inbox: empty is no chip")

  var vpnChip = barChip("vpn", bar, {})
  assert(vpnChip.hasData && vpnChip.text === "work", "chip vpn: the active connection")
  var vpnOff = barChip("vpn", barData({ vpnConnections: [{ name: "home", active: false }] }), {})
  assert(vpnOff.hasData && vpnOff.text === "OFF", "chip vpn: known but down reads OFF")
  assert(barChip("vpn", barData({ vpnConnections: [] }), {}).hasData === false,
         "chip vpn: no connections at all is no chip")

  var boxChip = barChip("containers", bar, {})
  assert(boxChip.hasData && boxChip.text === "2/5", "chip containers: running over total")
  assert(barChip("containers", barData({ containers: { running: 0, total: 0 } }), {}).hasData === false,
         "chip containers: no containers is no chip")

  var yahoo = parseYahooSpark('{"AAPL":{"symbol":"AAPL","close":[150.0],"fulldayChange":2.5,"fulldayChangePercent":1.69},"MSFT":{"symbol":"MSFT","close":[300.0],"fulldayChange":-1.0,"fulldayChangePercent":-0.33}}')
  assert(yahoo.symbols.length === 2, "yahoo: symbol count")
  assert(yahoo.symbols[0].price === 150.0, "yahoo: price")
  assert(yahoo.symbols[0].isDown === false, "yahoo: positive not down")
  assert(yahoo.symbols[1].isDown === true, "yahoo: negative is down")
  assert(yahoo.checkedAt.match(/^\d{2}:\d{2}$/), "yahoo: checkedAt format")
  var yahooOrdered = parseYahooSpark(JSON.stringify({AAPL: {symbol: "AAPL", close: [150.0], fulldayChange: 1, fulldayChangePercent: 1}, MSFT: {symbol: "MSFT", close: [300.0], fulldayChange: 1, fulldayChangePercent: 1}}), ["MSFT", "AAPL"])
  assert(yahooOrdered.symbols[0].symbol === "MSFT", "yahoo: order list respected")

  function ddmm(daysFromNow) {
    var d = new Date()
    d.setDate(d.getDate() + daysFromNow)
    return d.getDate() + "/" + (d.getMonth() + 1) + "/" + d.getFullYear()
  }

  var soonStr = ddmm(20)
  var laterStr = ddmm(120)
  var ch = parseCompaniesHouse('{"primaryTopic":{"CompanyName":"TEST CO","Accounts":{"NextDueDate":"' + soonStr + '"},"Returns":{"NextDueDate":"' + laterStr + '"}}}')
  assert(ch.companyName === "TEST CO", "ch: company name")
  assert(ch.accountsNextDue === soonStr, "ch: accounts due")
  assert(isDueSoon(soonStr) === true, "isDueSoon: within 30 days")
  assert(isDueSoon(laterStr) === false, "isDueSoon: beyond 30 days")
  assert(formatDateCh("15/10/2026") === "15 Oct 2026", "formatDateCh: format")
  assert(formatDateCh("") === "\u2014", "formatDateCh: empty")

  var batch = parseCompaniesHouseBatch("\n@@CH@NEXT@@\n{\"primaryTopic\":{\"CompanyName\":\"ALPHA LTD\",\"Accounts\":{\"NextDueDate\":\"31/01/2027\"},\"Returns\":{\"NextDueDate\":\"31/01/2027\"}}}\n@@CH@NEXT@@\n{\"primaryTopic\":{\"CompanyName\":\"BETA LTD\",\"Accounts\":{\"NextDueDate\":\"30/04/2027\"},\"Returns\":{\"NextDueDate\":\"30/04/2027\"}}}\n@@CH@NEXT@@")
  assert(batch.companies.length >= 2, "chbatch: two companies")
  assert(batch.companies[0].companyName === "ALPHA LTD" || batch.companies[1].companyName === "ALPHA LTD", "chbatch: alpha present")
  assert(formatDayLabel("2026-09-14") === "Mon", "dayLabel: fixed date")

  // parseICal drops anything already started, so the fixture has to be built
  // relative to now — a hardcoded date made this assertion expire on its own.
  function icalMoment(daysFromNow, hour) {
    var when = new Date()
    when.setDate(when.getDate() + daysFromNow)
    when.setHours(hour, 0, 0, 0)
    function two(n) { return (n < 10 ? "0" : "") + n }
    return {
      stamp: when.getFullYear() + two(when.getMonth() + 1) + two(when.getDate())
        + "T" + two(hour) + "0000Z",
      date: when
    }
  }

  var meeting = icalMoment(1, 14)
  var meetingEnd = icalMoment(1, 15)
  var ical = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Test Meeting\nDTSTART:" + meeting.stamp
    + "\nDTEND:" + meetingEnd.stamp + "\nEND:VEVENT\nEND:VCALENDAR"
  // ---- curlConfigUrl: the iCal URL goes to curl over stdin, never argv
  assert(curlConfigUrl(" https://calendar.google.com/calendar/ical/a%40b/private-x/basic.ics ")
         === 'url = "https://calendar.google.com/calendar/ical/a%40b/private-x/basic.ics"\n',
         "curlConfigUrl: trims and quotes a plain URL")
  assert(curlConfigUrl('https://x/a"b\\c') === 'url = "https://x/a\\"b\\\\c"\n',
         "curlConfigUrl: escapes quotes and backslashes")
  assert(curlConfigUrl("https://x/a\noutput = /tmp/pwn") === "", "curlConfigUrl: rejects an embedded newline")
  assert(curlConfigUrl("https://x/a\rb") === "", "curlConfigUrl: rejects an embedded CR")
  assert(curlConfigUrl("file:///etc/passwd") === "", "curlConfigUrl: rejects a non-http scheme")
  assert(curlConfigUrl("") === "" && curlConfigUrl(undefined) === "", "curlConfigUrl: empty in, empty out")

  var ev = parseICal(ical)
  assert(ev.events.length === 1, "ical: event count")
  assert(ev.events[0].summary === "Test Meeting", "ical: summary")
  var start = ev.events[0].dtstart
  assert(start.getFullYear() === meeting.date.getFullYear()
         && start.getMonth() === meeting.date.getMonth()
         && start.getDate() === meeting.date.getDate()
         && start.getHours() === 14, "ical: start components")
  assert(parseICal("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Past\nDTSTART:" + icalMoment(-3, 14).stamp
         + "\nEND:VEVENT\nEND:VCALENDAR").events.length === 0, "ical: a started event is not upcoming")

  // Property parameters. A feed that writes `DTSTART;TZID=...` or
  // `SUMMARY;LANGUAGE=...` is writing ordinary iCal, not an edge case.
  var tzMoment = icalMoment(2, 11)
  var tzIcal = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY;LANGUAGE=en-gb:Parametered\n"
    + "DTSTAMP:" + icalMoment(-9, 9).stamp + "\n"
    + "DTSTART;TZID=Europe/London:" + tzMoment.stamp.replace("Z", "") + "\nEND:VEVENT\nEND:VCALENDAR"
  var tzEv = parseICal(tzIcal)
  assert(tzEv.events.length === 1, "ical: parameters do not hide an event")
  assert(tzEv.events[0].summary === "Parametered", "ical: SUMMARY with a parameter")
  assert(tzEv.events[0].dtstart.getHours() === 11, "ical: DTSTART with a TZID keeps its time")
  assert(tzEv.events[0].allDay === false, "ical: a timed event is not all-day")

  // All-day events (VALUE=DATE), which is how Google writes holidays,
  // birthdays and anything spanning whole days.
  function icalDay(daysFromNow) {
    var when = new Date()
    when.setDate(when.getDate() + daysFromNow)
    function two(n) { return (n < 10 ? "0" : "") + n }
    return when.getFullYear() + two(when.getMonth() + 1) + two(when.getDate())
  }
  var allDayIcal = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Christmas Day\n"
    + "DTSTART;VALUE=DATE:" + icalDay(3) + "\nDTEND;VALUE=DATE:" + icalDay(4)
    + "\nEND:VEVENT\nEND:VCALENDAR"
  var allDayEv = parseICal(allDayIcal)
  assert(allDayEv.events.length === 1, "ical: an all-day event is parsed")
  assert(allDayEv.events[0].allDay === true, "ical: all-day flagged")
  assert(allDayEv.events[0].dtstartStr === "", "ical: all-day shows no time")
  assert(allDayEv.events[0].dtstart.getHours() === 0, "ical: all-day starts at midnight")

  // Today's all-day event is current all day. Reading it as a midnight start
  // dropped it from the card at 01:00 every day.
  var todayAllDay = parseICal("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Bank Holiday\n"
    + "DTSTART;VALUE=DATE:" + icalDay(0) + "\nEND:VEVENT\nEND:VCALENDAR")
  assert(todayAllDay.events.length === 1, "ical: today's all-day event is still upcoming")
  assert(todayAllDay.events[0].dateStr === "Today", "ical: today's all-day event says Today")

  // A bare date with no VALUE=DATE parameter is still a date.
  assert(parseICal("BEGIN:VCALENDAR\nBEGIN:VEVENT\nSUMMARY:Bare\nDTSTART:" + icalDay(2)
         + "\nEND:VEVENT\nEND:VCALENDAR").events[0].allDay === true, "ical: bare date is all-day")

  assert(icalValue("DTSTAMP:20260101T000000Z", "DTSTART") === null, "icalValue: DTSTAMP is not DTSTART")
  assert(icalValue("DTSTART:20260101T090000", "DTSTART").value === "20260101T090000",
         "icalValue: plain property")
  assert(icalValue("DTSTART;VALUE=DATE:20260101", "DTSTART").params === ";VALUE=DATE",
         "icalValue: parameters kept")

  var farOff = new Date()
  farOff.setDate(farOff.getDate() + 90)
  assert(formatEventDate(farOff) === farOff.getDate() + " " + MONTH_LABELS[farOff.getMonth()],
         "eventDate: beyond a week states the date")
  var thisWeek = new Date()
  thisWeek.setDate(thisWeek.getDate() + 3)
  assert(["Sun","Mon","Tue","Wed","Thu","Fri","Sat"].indexOf(formatEventDate(thisWeek)) >= 0,
         "eventDate: inside the week names the day")

  var folded = "BEGIN:VCALENDAR\nDESCRIPTION:Long line that\n gets folded\nEND:VCALENDAR"
  var unfolded = unfoldICalLines(folded)
  assert(unfolded.length === 3, "unfold: count")
  assert(unfolded[1].indexOf("folded") >= 0, "unfold: joined")

  var sys = parseSystemOutput("cpu\t700\t1000\nmemory\t45.2\nload\t1.50\ndisk\t100G\t60G\t60%\ntemp\t52000")
  assert(sys.cpuPercent === 30, "sys: cpu")
  assert(sys.memoryPercent === 45, "sys: mem")
  assert(sys.loadAverage === 1.5, "sys: load")
  assert(sys.diskPercent === 60, "sys: disk")
  assert(sys.tempCelsius === 52, "sys: temp")
  var sysNeg = parseSystemOutput("cpu\t999999\t800000\nmemory\t45.2\nload\t-2\n")
  assert(sysNeg.cpuPercent === 0, "sys: cpu never negative")
  assert(sysNeg.loadAverage === 0, "sys: load never negative")

  var rem = parseRemindersJson('{"count":1,"active":true,"reminders":[{"label":"Test","remaining":"5m","remainingSeconds":300,"atTime":"14:30"}]}')
  assert(rem.count === 1, "rem: count")
  assert(rem.active === true, "rem: active")
  assert(rem.reminders[0].label === "Test", "rem: label")

  assert(formatCountdown(300) === "5m", "cd: minutes")
  assert(formatCountdown(3661) === "1h 1m", "cd: hours+min")
  assert(formatCountdown(90000) === "1d 1h", "cd: days+hours")
  assert(formatCountdown(0) === "now", "cd: zero")

  var current = parseWeatherCurrent('{"current":{"temperature_2m":17.2,"relative_humidity_2m":63,"wind_speed_10m":11.5,"weather_code":3,"is_day":1},"daily":{"time":["2026-09-13","2026-09-14","2026-09-15","2026-09-16"],"weather_code":[3,2,61,80],"temperature_2m_max":[18,19,16,15],"temperature_2m_min":[10,11,9,8]}}', "London")
  assert(current.weather !== null, "weather: parsed")
  assert(current.weather.temp === 17.2, "weather: temp")
  assert(current.weather.humidity === 63, "weather: humidity")
  assert(current.weather.isDay === true, "weather: isDay")
  assert(current.weather.forecast.length === 3, "weather: 3-day forecast")
  assert(current.weather.forecast[0].day === "Mon", "weather: forecast skips today")
  assert(current.weather.forecast[0].max === 19, "weather: forecast max")
  assert(current.weather.forecast[0].icon !== "", "weather: forecast icon")
  var bare = parseWeatherCurrent('{"current":{"temperature_2m":17.2,"relative_humidity_2m":63,"wind_speed_10m":11.5,"weather_code":3,"is_day":1}}', "X")
  assert(bare.weather.forecast.length === 0, "weather: no daily -> empty forecast")

  var geo = parseGeocodingResults('{"results":[{"name":"London","latitude":51.5072,"longitude":-0.1276,"admin1":"England","country":"United Kingdom"},{"name":"London","latitude":42.9834,"longitude":-81.233,"admin1":"Ontario","country":"Canada"}]}')
  assert(geo.length === 2, "geo: count")
  assert(geo[0].latitude === 51.5072, "geo: lat")
  assert(geo[0].description.indexOf("England") >= 0, "geo: description")

  assert(toggleSymbolsPreset("AAPL,BTC-USD", "Stocks").indexOf("MSFT") >= 0, "toggle: adds preset")
  var allActive = isPresetActive("AAPL,MSFT,TSLA,NVDA,GOOGL,AMZN,BTC-USD", "Stocks")
  assert(allActive === true, "preset: active")
  assert(isPresetActive("AAPL,BTC-USD", "Stocks") === false, "preset: inactive")

  // ---- registry
  assert(CARDS.length === 12, "registry: six original + six new cards")
  var ids = {}
  for (var c = 0; c < CARDS.length; c++) {
    var entry = CARDS[c]
    assert(!ids[entry.id], "registry: unique id " + entry.id)
    ids[entry.id] = true
    assert(entry.title !== "" && entry.group !== "" && entry.summary !== "", "registry: " + entry.id + " is fully described")
  }
  assert(defaultCardIds().join(",") === "weather,market,calendar,companies,reminders,system",
         "registry: default enable set")
  assert(cardById("repos").title === "REPOS", "registry: lookup")
  assert(cardById("nope") === null, "registry: unknown id")
  assert(BAR_ITEM_IDS.indexOf("repos") === -1 && BAR_ITEM_IDS.indexOf("timer") !== -1,
         "registry: only glyph-shaped cards reach the bar")
  assert(barItemLabel("containers") === "CONTAINERS", "registry: bar label from the registry")
  assert(barItemGlyph("media") === "\uf03e4", "registry: bar glyph from the registry")
  assert(barItemGlyph("weather") === "", "registry: weather defers to its condition")
  assert(barItemGlyph("nope") === "", "registry: unknown glyph is empty")

  // ---- enabled set: the whole point is that nothing is force-appended
  assert(enabledCards("").join(",") === defaultCardIds().join(","), "cards: absent setting -> defaults")
  assert(enabledCards(null, null).length === 6, "cards: both settings absent -> defaults")
  assert(enabledCards('["system","weather"]').join(",") === "system,weather", "cards: custom order kept")
  assert(enabledCards('["system","weather"]').length === 2, "cards: no force-append")
  assert(enabledCards('["system","weather"]', '["market"]').join(",") === "system,weather", "cards: written setting wins over legacy")
  assert(enabledCards(null, '["market","system"]').join(",") === "market,system", "cards: legacy layout migrates")
  assert(enabledCards('["system","bogus","system","weather"]').join(",") === "system,weather", "cards: unknown + dupe drop")
  assert(enabledCards("system,weather").join(",") === "system,weather", "cards: csv string")
  assert(enabledCards(["weather", "media"]).indexOf("media") !== -1, "cards: an opt-in card can be enabled")
  assert(enabledCards('["system"]').indexOf("system") !== -1 && enabledCards('["system"]').indexOf("weather") === -1,
         "cards: a card the user switched off stays off")

  assert(moveCard(["weather", "market", "system"], "system", -1).join(",") === "weather,system,market", "move: earlier")
  assert(moveCard(["weather", "market", "system"], "weather", -1).join(",") === "weather,market,system", "move: clamped at start")
  assert(moveCard(["weather", "market", "system"], "system", 1).join(",") === "weather,market,system", "move: clamped at end")
  assert(moveCard(["weather"], "media", 1).join(",") === "weather", "move: a disabled card is not in the list")

  // ---- reorder: the drag-and-drop move, which lands on an index
  assert(reorderCard(["weather", "market", "system"], "weather", 2).join(",") === "market,system,weather", "reorder: to the end")
  assert(reorderCard(["weather", "market", "system"], "system", 0).join(",") === "system,weather,market", "reorder: to the front")
  assert(reorderCard(["weather", "market", "system"], "market", 9).join(",") === "weather,system,market", "reorder: past the end clamps")
  assert(reorderCard(["weather", "market", "system"], "market", -3).join(",") === "market,weather,system", "reorder: before the front clamps")
  assert(reorderCard(["weather", "market", "system"], "market", 1).join(",") === "weather,market,system", "reorder: onto itself is a no-op")
  assert(reorderCard(["weather", "market"], "media", 0).join(",") === "weather,market", "reorder: a disabled card is not in the list")

  assert(toggleCard(["weather", "market"], "system").join(",") === "weather,market,system", "toggle: enables in registry position")
  assert(toggleCard(["weather", "market"], "repos").join(",") === "weather,market,repos", "toggle: last card appends")
  assert(toggleCard(["weather", "repos", "market"], "repos").join(",") === "weather,market", "toggle: disables")
  assert(toggleCard(["weather", "market", "system"], "nope").join(",") === "weather,market,system", "toggle: unknown id is a no-op")
  assert(enabledCards([]).length === 0, "cards: an explicit empty array means no cards")
  // The string form is what a shell.json edit actually produces.
  assert(enabledCards("[]").length === 0, "cards: the string \"[]\" also means no cards")
  assert(enabledCards("[]", '["market"]').length === 0, "cards: string \"[]\" beats the legacy layout")
  assert(enabledCards("  ").join(",") === defaultCardIds().join(","),
         "cards: a blank setting is the same as never having set it")
  // Stand-in for the QML sequence type a shell.json list arrives as: indexable
  // with a length, but not an Array as far as Array.isArray is concerned.
  function sequenceType(list) {
    var out = { length: list.length }
    for (var i = 0; i < list.length; i++) out[i] = list[i]
    return out
  }
  assert(enabledCards(sequenceType([])).length === 0,
         "cards: an empty QML sequence means no cards")
  assert(enabledCards(sequenceType(["system", "weather"])).join(",") === "system,weather",
         "cards: a QML sequence of ids is honoured")
  assert(parseBarItems(sequenceType([]), []).length === 0,
         "barItems: an empty QML sequence means no chips")
  assert(parseBarItems(sequenceType(["weather"]), []).join(",") === "weather",
         "barItems: a QML sequence of ids is honoured")
  assert(enabledCards([], '["market"]').length === 0, "cards: explicit empty beats the legacy layout")
  assert(enabledCards("nonsense").length === 6, "cards: junk falls back to the defaults")

  // ---- needs gating
  var ready = { weatherTown: "Birmingham", calendarIcalUrl: "https://x/basic.ics",
                companiesHouseNumber: "00445790", repoPaths: "~/Work", vpnBackend: true, dockerBin: true }
  for (var n = 0; n < CARDS.length; n++) {
    var why = missingNeeds(CARDS[n].id, ready)
    assert(why === "", "needs: " + CARDS[n].id + " is selectable when configured")
  }
  assert(missingNeeds("weather", {}).indexOf("location") !== -1, "needs: weather wants a location")
  assert(missingNeeds("calendar", ready) === "", "needs: calendar satisfied")
  assert(missingNeeds("repos", {}) === "Add repo paths in settings", "needs: repos wants paths")
  assert(missingNeeds("vpn", { vpnBackend: false }) === "No VPN backend found", "needs: probe false blocks")
  assert(missingNeeds("market", {}) === "", "needs: a card with no needs is always selectable")
  assert(missingNeeds("nope", {}) === "", "needs: unknown id is not blocked")

  var groups = grouped()
  assert(groups.length === 3, "grouped: three groups")
  assert(groups[0].group === "Dashboard" && groups[0].cards.length === 6, "grouped: dashboard has six")
  assert(groups[1].group === "Now" && groups[1].cards.length === 3, "grouped: now has three")
  assert(groups[2].group === "System" && groups[2].cards.length === 3, "grouped: system has three")
  var flat = 0
  for (var g = 0; g < groups.length; g++) flat += groups[g].cards.length
  assert(flat === CARDS.length, "grouped: every card is in exactly one group")
  // ---- bar face
  assert(parseBarItems(["weather", "market"]).join(",") === "weather,market", "barItems: array order kept")
  assert(parseBarItems('["market","weather"]')[0] === "market", "barItems: json array")
  assert(parseBarItems("calendar, weather").join(",") === "calendar,weather", "barItems: csv string")
  assert(parseBarItems('["weather","bogus","weather"]').join(",") === "weather", "barItems: unknown + dupe drop")
  assert(parseBarItems([]).length === 0, "barItems: explicit empty means icon only")
  assert(parseBarItems("").join(",") === "weather", "barItems: missing falls back")
  assert(parseBarItems(null, ["system", "reminders"]).join(",") === "system,reminders", "barItems: custom fallback")
  assert(parseBarItems("nonsense").join(",") === "weather", "barItems: junk falls back")

  assert(parseBarSymbols("", "AAPL,MSFT,TSLA", 2).join(",") === "AAPL,MSFT", "barSymbols: first N of pool")
  assert(parseBarSymbols("TSLA,AAPL", "AAPL,MSFT,TSLA", 2).join(",") === "TSLA,AAPL", "barSymbols: filter keeps order")
  assert(parseBarSymbols("NOPE", "AAPL,MSFT", 2).length === 0, "barSymbols: outside the pool is dropped")
  assert(parseBarSymbols("AAPL,MSFT,TSLA", "AAPL,MSFT,TSLA", 9).length === 3, "barSymbols: capped")

  assert(toggleBarItem(["weather"], "market").join(",") === "weather,market", "toggle: adds")
  assert(toggleBarItem(["weather", "market"], "weather").join(",") === "market", "toggle: removes")
  assert(toggleBarItem([], "system").join(",") === "system", "toggle: from empty")
  assert(moveBarItem(["weather", "market", "system"], "system", -1).join(",") === "weather,system,market", "move: earlier")
  assert(moveBarItem(["weather", "market", "system"], "weather", -1).join(",") === "weather,market,system", "move: clamped at start")
  assert(moveBarItem(["weather", "market", "system"], "system", 1).join(",") === "weather,market,system", "move: clamped at end")
  assert(moveBarItem(["weather"], "system", 1).join(",") === "weather", "move: unknown id is a no-op")
  assert(reorderBarItem(["weather", "market", "system"], "weather", 2).join(",") === "market,system,weather", "reorder: bar item to the end")
  assert(reorderBarItem(["weather", "market", "system"], "system", 0).join(",") === "system,weather,market", "reorder: bar item to the front")
  assert(reorderBarItem(["weather", "market", "system"], "market", 7).join(",") === "weather,system,market", "reorder: bar item clamps")
  assert(reorderBarItem(["weather", "market"], "timer", 0).join(",") === "weather,market", "reorder: bar item not on the bar is a no-op")

  var chipData = {
    weather: { temp: 17.4, icon: "\uf0c2" },
    market: { symbols: [
      { symbol: "AAPL", price: 232.5, changePercent: 1.69, isDown: false },
      { symbol: "MSFT", price: 300, changePercent: -0.33, isDown: true }
    ] },
    companies: [{ companyName: "ALPHA", accountsNextDue: ddmm(20), returnsNextDue: ddmm(200) }],
    calendar: { events: [{ summary: "Standup and roadmap review", dateStr: "Today", dtstartStr: "14:30" }] },
    system: { cpuPercent: 12, memoryPercent: 45, tempCelsius: 52 },
    reminders: { count: 2, reminders: [] }
  }

  var weatherChip = barChip("weather", chipData, {})
  assert(weatherChip.hasData === true, "chip weather: has data")
  assert(weatherChip.text === "17\u00b0", "chip weather: rounded temp")
  assert(weatherChip.icon === "\uf0c2", "chip weather: condition glyph")

  var marketChip = barChip("market", chipData, { symbols: ["AAPL", "MSFT"] })
  assert(marketChip.text === "AAPL 232.50 +1.7%  MSFT 300.00 -0.3%", "chip market: quotes")
  assert(marketChip.urgent === true, "chip market: urgent when a quote is down")
  assert(barChip("market", chipData, { symbols: ["AAPL"] }).urgent === false, "chip market: calm when quotes rise")

  var soon = barChip("companies", chipData, {})
  assert(soon.hasData === true && soon.urgent === true, "chip companies: due soon is urgent")
  assert(soon.text.indexOf("CH ") === 0, "chip companies: prefixed")
  assert(barChip("companies", { companies: [{ accountsNextDue: ddmm(200), returnsNextDue: ddmm(300) }] }, {}).urgent === false,
         "chip companies: distant deadline is calm")

  var eventChip = barChip("calendar", chipData, {})
  assert(eventChip.text === "Today 14:30 Standup and roadm\u2026", "chip calendar: next event, truncated")
  assert(eventChip.urgent === true, "chip calendar: today is urgent")

  var systemChip = barChip("system", chipData, {})
  assert(systemChip.text === "CPU 12% MEM 45% 52\u00b0C", "chip system: readings")
  assert(systemChip.urgent === false, "chip system: never urgent")
  assert(barChip("system", { system: { cpuPercent: 0, memoryPercent: 0, tempCelsius: -1 } }, {}).text === "CPU 0% MEM 0%",
         "chip system: a real zero still shows, a missing sensor does not")

  var remChip = barChip("reminders", chipData, {})
  assert(remChip.text === "2" && remChip.urgent === true, "chip reminders: count is urgent")
  assert(barChip("reminders", { reminders: { count: 0 } }, {}).hasData === false, "chip reminders: silent at zero")

  assert(barChip("weather", {}, {}).hasData === false, "chip: empty data hides the chip")
  assert(barChip("market", { market: { symbols: [] } }, { symbols: ["AAPL"] }).hasData === false, "chip market: no quotes")
  assert(barChip("nope", chipData, {}).hasData === false, "chip: unknown id hides")
  assert(barChip("calendar", { calendar: { events: [] } }, {}).hasData === false, "chip calendar: nothing upcoming")
  assert(barChip("companies", { companies: [] }, {}).hasData === false, "chip companies: none configured")

  assert(formatPrice(232.456) === "232.46", "price: 2dp")
  assert(formatPrice("nope") === "\u2014", "price: junk")
  assert(formatPct(1.69) === "+1.7%", "pct: signed")
  assert(formatPct(0) === "0.0%", "pct: zero unsigned")
  assert(formatPct("nope") === "", "pct: junk")
  assert(truncateText("short", 18) === "short", "truncate: under the limit")
  assert(truncateText("Standup and roadmap review", 18) === "Standup and roadm\u2026", "truncate: over the limit")
  assert(truncateText("abcdef", 1) === "\u2026", "truncate: minimum length")
  assert(barItemLabel("market") === "MARKET", "label: known id")
  assert(barItemGlyph("calendar") !== "", "glyph: calendar has a mark")
  assert(barItemGlyph("weather") === "", "glyph: weather defers to its condition")
  assert(parseChDate("") === null && parseChDate("31/02/2026") !== null, "ch date: rejects junk")
  assert(parseChDate("13/13/2026") === null, "ch date: rejects impossible month")
  assert(formatDateChShort(ddmm(20)).indexOf(String(new Date().getFullYear())) === -1, "short date: drops this year's year")

  // ---- repos
  assert(parseRepoPaths("~/Work\n~/Work", "/home/you").join(",") === "/home/you/Work",
         "repos: ~ expanded, repeat dropped")
  assert(parseRepoPaths(" /a/b/ , /c ,", "/home/you").join(",") === "/a/b,/c", "repos: csv, trimmed, trailing slash gone")
  assert(parseRepoPaths("", "/home/you").length === 0, "repos: empty")
  assert(parseRepoPaths(null, null).length === 0, "repos: null")
  assert(parseRepoPaths("~x", "").length === 0, "repos: ~ with no home drops the path")

  var dirtyRepo = parseGitStatus("# branch.oid 19eb3f\n# branch.head main\n"
    + "1 .M N... 100644 100644 100644 45b98 45b98 f.txt\n? g.txt\n")
  assert(dirtyRepo.branch === "main", "git: branch")
  assert(dirtyRepo.changed === 1 && dirtyRepo.untracked === 1, "git: changed + untracked")
  assert(dirtyRepo.staged === 0, "git: nothing staged")
  assert(dirtyRepo.dirty === true, "git: dirty")
  var aheadRepo = parseGitStatus("# branch.head master\n# branch.upstream origin/master\n# branch.ab +1 -0\n")
  assert(aheadRepo.ahead === 1 && aheadRepo.behind === 0, "git: ahead/behind from the header")
  assert(aheadRepo.dirty === true, "git: unpushed work counts as dirty")
  var stagedRepo = parseGitStatus("# branch.head main\n1 A. N... 100644 100644 100644 45b98 45b98 new.txt\n")
  assert(stagedRepo.staged === 1 && stagedRepo.changed === 1, "git: staged from the X column")
  var cleanRepo = parseGitStatus("# branch.oid abc\n# branch.head main\n")
  assert(cleanRepo.dirty === false && cleanRepo.changed === 0, "git: clean")
  assert(parseGitStatus("").dirty === false, "git: empty is calm, not broken")
  assert(gitStatusError("fatal: not a git repository (or any of the parent directories): .git") === "not a repo",
         "git: error is named, not thrown")
  assert(gitStatusError("") === "no answer", "git: no answer")
  assert(gitStatusError("fatal: could not read Username for 'https://github.com'").indexOf("fatal: could not read") === 0,
         "git: first stderr line, capped for the card")

  // ---- containers (sample shape taken from `docker ps -a --format`)
  var dock = parseDockerPs("api\trunning\tUp 6 days\npostgres\trunning\tUp 6 days\n"
    + "redis\texited\tExited (2) 2 hours ago\n")
  assert(dock.rows.length === 3 && dock.running === 2 && dock.total === 3, "docker: counts")
  assert(dock.rows[2].running === false && dock.rows[2].status.indexOf("Exited") === 0, "docker: exited row")
  assert(parseDockerPs("").rows.length === 0, "docker: empty is no rows, not a parse failure")
  assert(parseDockerPs("garbage\n\n").rows.length === 0, "docker: junk row drops")
  assert(parseDockerPs("n1\trunning").rows[0].status === "", "docker: missing status is allowed")
  assert(dockerErrorText("Cannot connect to the Docker daemon at unix:///var/run/docker.sock. Is the docker daemon running?", 1)
         === "daemon not running", "docker: daemon down is named")
  assert(dockerErrorText("permission denied while trying to connect to the docker API socket", 1)
         === "permission denied", "docker: socket permission is named")
  assert(dockerErrorText("", 127) === "unavailable (exit 127)", "docker: bare exit code still says something")

  // ---- repos as one batch call
  var batch = parseRepoBatch("@@REPO@@/home/you/.local/share/hyprflow\n"
    + "# branch.head main\n? new.txt\n"
    + "@@REPO@@/tmp\nfatal: not a git repository (or any of the parent directories): .git\n"
    + "@@REPO@@/srv/app\n# branch.head trunk\n1 M. N... 100644 100644 100644 aaa aaa x.c\n")
  assert(batch.length === 3, "repos: one row per marker")
  assert(batch[0].name === "hyprflow" && batch[0].untracked === 1, "repos: name from the path, untracked counted")
  assert(batch[1].error === "not a repo", "repos: a bad path is a row, not a lost card")
  assert(batch[2].branch === "trunk" && batch[2].staged === 1, "repos: second repo still parsed")
  assert(parseRepoBatch("").length === 0, "repos: no markers, no rows")

  // ---- vpn (nmcli's profiles under a backend header, sections split on a marker)
  var vpn = parseVpnListings("openvpn\nhomelab-uk|openvpn|activated\noffice|openvpn|\ndialling|openvpn|activating\n")
  assert(vpn.backends.join(",") === "openvpn", "vpn: backend found")
  assert(vpn.connections.length === 3, "vpn: one row per nmcli profile")
  assert(vpn.connections[0].active === true, "vpn: active connection")
  assert(vpn.connections[1].active === false, "vpn: inactive connection")
  assert(vpn.connections[2].active === false && vpn.connections[2].activating === true,
         "vpn: a dialling connection is activating, not yet active")
  assert(parseVpnListings("").connections.length === 0, "vpn: nothing found")
  // A section whose header is not a backend we drive is skipped, not guessed at.
  var vpnUnknown = parseVpnListings("openvpn\nhomelab-uk|openvpn|activated\n@@VPN@@\nnordvpn\n")
  assert(vpnUnknown.backends.join(",") === "openvpn", "vpn: unknown backend is not a backend")
  assert(vpnUnknown.connections.length === 1, "vpn: unknown backend adds no rows")
  assert(parseVpnListings("openvpn\nmy\\:net|openvpn|activated\n").connections[0].name === "my:net",
         "vpn: nmcli escapes colons in names")

  // ---- inbox (the notification service writes one JSON object per line)
  var now = Date.now()
  var inboxText = '{"app":"Signal","summary":"Message from Ari","urgency":2,"timestamp":' + (now - 120000) + '}\n'
    + '{"app":"omarchy-action","summary":"Build finished","urgency":0,"timestamp":' + (now - 900000) + '}\n'
    + '{"app":"clock","summary":"","timestamp":1}\n'
    + '{"app":"terminal","summary":"Build finished","urgency":0,"timestamp":' + (now - 3000000) + '}\n'
    + "not json at all\n"
  var inbox = parseInboxHistory(inboxText, 5)
  assert(inbox.length === 3, "inbox: junk and empty summaries drop")
  assert(inbox[0].summary === "Message from Ari", "inbox: newest first")
  assert(inbox[0].urgency === 2, "inbox: urgency kept")
  assert(inbox[1].summary === "Build finished", "inbox: then the next newest")
  assert(parseInboxHistory(inboxText, 2).length === 2, "inbox: limit")
  assert(parseInboxHistory("", 5).length === 0, "inbox: no history is empty, not broken")
  assert(relativeTime(now - 30000, now) === "now", "relative: under a minute")
  assert(relativeTime(now - 120000, now) === "2m", "relative: minutes")
  assert(relativeTime(now - 7200000, now) === "2h", "relative: hours")
  assert(relativeTime(now - 172800000, now) === "2d", "relative: days")
  assert(relativeTime(0, now) === "", "relative: no stamp")

  // ---- timer
  assert(formatClock(17 * 60 + 32) === "17:32", "clock: mm:ss")
  assert(formatClock(3661) === "1:01:01", "clock: h:mm:ss")
  assert(formatClock(-5) === "00:00", "clock: never negative")
  assert(timerMode("break").seconds === 300, "timer: break length")
  assert(timerMode("nope").id === "focus", "timer: unknown mode falls back to focus")
  var freshTimer = parseTimerState("")
  assert(freshTimer.mode === "focus" && freshTimer.remaining === 1500 && freshTimer.running === false,
         "timer: empty state is a fresh focus session")
  var liveTimer = parseTimerState('{"mode":"break","running":true,"endsAt":' + (Date.now() + 90000) + '}')
  assert(liveTimer.running === true && liveTimer.remaining >= 89 && liveTimer.remaining <= 91,
         "timer: a running session resumes from its deadline")
  var doneTimer = parseTimerState('{"mode":"break","running":true,"endsAt":' + (Date.now() - 5000) + '}')
  assert(doneTimer.remaining === 0, "timer: an expired deadline reads zero")
  var heldTimer = parseTimerState('{"mode":"stopwatch","running":false,"elapsed":95,"remaining":0}')
  assert(heldTimer.mode === "stopwatch" && heldTimer.elapsed === 95, "timer: a held stopwatch keeps its elapsed")
  assert(parseTimerState("junk").mode === "focus", "timer: junk state is a fresh session")

  // ---- knownIds: no argument means the whole registry, which is what the
  // card picker asks for when it lists what is not on the dashboard
  assert(knownIds().length === CARDS.length, "knownIds: no argument is every card")
  assert(knownIds().join(",") === CARDS.map(function(c) { return c.id }).join(","),
         "knownIds: registry order, not alphabetical")
  assert(knownIds(["repos", "nope", "repos", "", null]).join(",") === "repos",
         "knownIds: a given list is filtered to real, unique ids")

  // ---- the manifest and the registry are two hand-maintained lists of the same
  // cards, so the one place both are readable is the check that keeps them equal.
  // Under QML there is no require(); selfCheck only ever runs from node.
  if (typeof require === "function" && typeof module !== "undefined") {
    var fs = require("fs")
    var manifest = JSON.parse(fs.readFileSync(__dirname + "/manifest.json", "utf8"))
    var schema = manifest.barWidget.schema
    var cardsKey = null, barKey = null
    for (var s = 0; s < schema.length; s++) {
      if (schema[s].key === "cards") cardsKey = schema[s]
      if (schema[s].key === "barItems") barKey = schema[s]
    }
    assert(cardsKey !== null, "manifest: a `cards` multiselect exists")
    assert(barKey !== null, "manifest: a `barItems` multiselect exists")
    var manifestIds = []
    for (var o = 0; o < cardsKey.options.length; o++) manifestIds.push(cardsKey.options[o].value)
    var registryIds = []
    for (var m = 0; m < CARDS.length; m++) registryIds.push(CARDS[m].id)
    assert(manifestIds.join(",") === registryIds.join(","),
           "manifest: `cards` options match the registry (" + manifestIds.join(",") + " vs " + registryIds.join(",") + ")")
    var barIds = []
    for (var b = 0; b < barKey.options.length; b++) barIds.push(barKey.options[b].value)
    assert(barIds.join(",") === BAR_ITEM_IDS.join(","),
           "manifest: `barItems` options match the registry bar set")
    var defaults = manifest.barWidget.defaults || {}
    assert(JSON.stringify(defaults.cards) === JSON.stringify(defaultCardIds()),
           "manifest: the `cards` default is the registry's default enable set")
    assert((defaults.barItems || []).join(",") === DEFAULT_BAR_ITEMS.join(","),
           "manifest: the `barItems` default matches the registry")
    for (var d2 in defaults) {
      var value = defaults[d2]
      if (d2 === "cards" || d2 === "barItems" || !Array.isArray(value)) continue
      for (var v = 0; v < value.length; v++)
        assert(!!cardById(String(value[v])), "manifest: default " + d2 + " names a known card")
    }
    // `schema` drives the settings editor and `defaults` is what the bar starts
    // from, so a setting that lives in only one of them is invisible in the
    // other. Every entry must be complete and the two must agree exactly.
    var schemaKeys = []
    for (var e = 0; e < schema.length; e++) {
      var entry = schema[e]
      var where = "manifest: schema[" + e + "]"
      assert(typeof entry.key === "string" && entry.key !== "", where + " has a `key`")
      where = "manifest: schema `" + entry.key + "`"
      assert(schemaKeys.indexOf(entry.key) === -1, where + " is declared once")
      schemaKeys.push(entry.key)
      assert(typeof entry.label === "string" && entry.label !== "", where + " has a `label`")
      assert(typeof entry.type === "string" && entry.type !== "", where + " has a `type`")
      assert(entry.defaultValue !== undefined, where + " has a `defaultValue`")
      // A stray `default` is the shape of the bug this block exists to catch:
      // it reads right, the editor ignores it, and the setting has no default.
      assert(entry["default"] === undefined, where + " uses `defaultValue`, not `default`")
      assert(Object.prototype.hasOwnProperty.call(defaults, entry.key),
             where + " has a matching `defaults` entry")
      assert(JSON.stringify(defaults[entry.key]) === JSON.stringify(entry.defaultValue),
             where + " agrees with `defaults` (" + JSON.stringify(entry.defaultValue)
             + " vs " + JSON.stringify(defaults[entry.key]) + ")")
    }
    for (var dk in defaults)
      assert(schemaKeys.indexOf(dk) !== -1, "manifest: default `" + dk + "` has a `schema` entry")
  }

  console.log("Model.selfCheck: all assertions passed")
}

if (typeof module !== "undefined") {
  module.exports = {
    parseYahooSpark: parseYahooSpark,
    parseCompaniesHouse: parseCompaniesHouse,
    parseCompaniesHouseBatch: parseCompaniesHouseBatch,
    parseChDate: parseChDate,
    isDueSoon: isDueSoon,
    formatDateCh: formatDateCh,
    formatDateChShort: formatDateChShort,
    unfoldICalLines: unfoldICalLines,
    parseICalDate: parseICalDate,
    icalValue: icalValue,
    isAllDayLine: isAllDayLine,
    parseICal: parseICal,
    curlConfigUrl: curlConfigUrl,
    formatEventTime: formatEventTime,
    formatEventDate: formatEventDate,
    parseSystemOutput: parseSystemOutput,
    parseRemindersJson: parseRemindersJson,
    parseWeatherCurrent: parseWeatherCurrent,
    parseGeocodingResults: parseGeocodingResults,
    toggleSymbolsPreset: toggleSymbolsPreset,
    isPresetActive: isPresetActive,
    CARDS: CARDS,
    cardById: cardById,
    defaultCardIds: defaultCardIds,
    enabledCards: enabledCards,
    moveCard: moveCard,
    reorderCard: reorderCard,
    toggleCard: toggleCard,
    missingNeeds: missingNeeds,
    grouped: grouped,
    knownIds: knownIds,
    formatTimeNow: formatTimeNow,
    parseRepoPaths: parseRepoPaths,
    parseGitStatus: parseGitStatus,
    gitStatusError: gitStatusError,
    parseRepoBatch: parseRepoBatch,
    dockerErrorText: dockerErrorText,
    parseDockerPs: parseDockerPs,
    parseVpnListings: parseVpnListings,
    parseInboxHistory: parseInboxHistory,
    relativeTime: relativeTime,
    parseTimerState: parseTimerState,
    timerMode: timerMode,
    formatClock: formatClock,
    TIMER_MODES: TIMER_MODES,
    MARKET_PRESETS: MARKET_PRESETS,
    DEFAULT_SYMBOLS: DEFAULT_SYMBOLS,
    weatherIconForCode: weatherIconForCode,
    formatDayLabel: formatDayLabel,
    formatTimeNow: formatTimeNow,
    formatCountdown: formatCountdown,
    formatPrice: formatPrice,
    formatPct: formatPct,
    truncateText: truncateText,
    BAR_ITEM_IDS: BAR_ITEM_IDS,
    DEFAULT_BAR_ITEMS: DEFAULT_BAR_ITEMS,
    MAX_BAR_SYMBOLS: MAX_BAR_SYMBOLS,
    barItemLabel: barItemLabel,
    barItemGlyph: barItemGlyph,
    splitList: splitList,
    parseBarItems: parseBarItems,
    parseBarSymbols: parseBarSymbols,
    toggleBarItem: toggleBarItem,
    moveBarItem: moveBarItem,
    reorderBarItem: reorderBarItem,
    barData: barData,
    barChip: barChip,
    escapeHtml: escapeHtml,
    selfCheck: selfCheck
  }
}
