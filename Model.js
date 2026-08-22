// Series-agnostic data model for the plugin. Every function here takes the
// series config it is operating on, so adding a series only means adding a
// config to Series.js — nothing else needs to know its shape.

function parseJson(text) {
  if (!text) return null
  try {
    return JSON.parse(String(text))
  } catch (e) {
    return null
  }
}

// "YYYY-MM-DD" or "YYYY-MM-DDTHH:MM:SSZ" -> a UTC ms epoch. NaN when garbage.
function parseUtcDate(text) {
  if (!text) return NaN
  text = String(text).trim()
  if (text.indexOf("T") === -1) text += "T00:00:00Z"
  if (text.charAt(text.length - 1) !== "Z") text += "Z"
  return Date.parse(text)
}

function parseRaces(series, raw) {
  var races = series.raceList(raw)
  if (!races || !races.length) return []
  var now = Date.now()
  var out = []
  for (var i = 0; i < races.length; i++) {
    var race = races[i]
    var dateISO = (race.date || "") + "T" + (race.time || "00:00:00Z")
    var epoch = parseUtcDate(dateISO)
    if (isNaN(epoch)) continue
    out.push({
      season: series.raceSeason(race),
      round: series.raceRound(race),
      name: series.raceName(race),
      circuitId: series.circuitId(race),
      circuitName: series.circuitName(race),
      locality: series.locality(race),
      country: series.country(race),
      lat: series.circuitLat(race),
      long: series.circuitLong(race),
      dateISO: dateISO,
      epoch: epoch,
      stale: epoch < now,
      sessions: series.sessionsFromRace(race)
    })
  }
  return out
}

// First race whose race moment is now or later; null when everything is over.
function nextRace(races, now) {
  if (!races) return null
  for (var i = 0; i < races.length; i++) {
    if (!races[i].stale) return races[i]
  }
  return null
}

// Typical running window in ms for a session key; 0 when the series
// doesn't estimate one.
function sessionDurationMs(series, key) {
  var minutes = series && series.sessionDurations ? series.sessionDurations[key] : 0
  return (minutes || 0) * 60000
}

// True while a started session sits inside its estimated running window,
// so an event in progress can read as live instead of "over".
function sessionLive(series, session, now) {
  if (!session) return false
  var start = parseUtcDate(session.date)
  if (!isFinite(start) || start > now) return false
  var end = start + sessionDurationMs(series, session.key)
  return end > start && now < end
}

// The session after (or at) `now` for a race; a started session stays the
// target until its estimated end so the countdown holds on it while it runs.
// Falls back to the race session so there is always a sensible target.
function nextSession(series, race, now) {
  if (!race || !race.sessions || !race.sessions.length) return null
  var raceKey = series.raceSessionKey
  var raceSession = null
  for (var i = 0; i < race.sessions.length; i++) {
    var session = race.sessions[i]
    if (session.key === raceKey) raceSession = session
    if (parseUtcDate(session.date) >= now) return session
    if (sessionLive(series, session, now)) return session
  }
  return raceSession
}

// Season this race list belongs to; year+1 when the whole list is in the past.
function nextSeasonYear(races, now) {
  if (!races || !races.length) return null
  var season = parseInt(races[0].season, 10)
  if (isNaN(season)) return null
  return season + 1
}

function pad2(n) { return n < 10 ? "0" + n : "" + n }

// Compact bar countdown: "6d", "18h", "45m", "now". Negative -> "now".
function countdownText(targetEpoch, now) {
  if (!isFinite(targetEpoch)) return ""
  var diff = targetEpoch - now
  if (diff < 0) diff = 0
  var msPerMinute = 60 * 1000
  var msPerHour = 60 * msPerMinute
  var msPerDay = 24 * msPerHour
  var days = Math.floor(diff / msPerDay)
  if (days > 0) return days + "d"
  var hours = Math.floor(diff / msPerHour)
  if (hours > 0) return hours + "h"
  var minutes = Math.floor(diff / msPerMinute)
  if (minutes > 0) return minutes + "m"
  return "now"
}

// Spelled-out variant for the panel hero: "in 6 days", "in 18 hours",
// "in 45 minutes", "starting now".
function countdownLong(targetEpoch, now) {
  if (!isFinite(targetEpoch)) return ""
  var diff = targetEpoch - now
  if (diff < 0) diff = 0
  var msPerMinute = 60 * 1000
  var msPerHour = 60 * msPerMinute
  var msPerDay = 24 * msPerHour
  var days = Math.floor(diff / msPerDay)
  if (days > 0) return "in " + days + (days === 1 ? " day" : " days")
  var hours = Math.floor(diff / msPerHour)
  if (hours > 0) return "in " + hours + (hours === 1 ? " hour" : " hours")
  var minutes = Math.floor(diff / msPerMinute)
  if (minutes > 0) return "in " + minutes + (minutes === 1 ? " minute" : " minutes")
  return "starting now"
}

// "Sat 16:30" or "Sat 4:30 PM" in the viewer's local zone. "" when unparseable.
function formatSessionTime(epoch, use12Hour) {
  if (!isFinite(epoch)) return ""
  var date = new Date(epoch)
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var h = date.getHours()
  var m = date.getMinutes()
  var timeStr = use12Hour ? format12Hour(h, m) : pad2(h) + ":" + pad2(m)
  return days[date.getDay()] + " " + timeStr
}

// "Sat 16:30" or "Sat 4:30 PM" in track-local time. The API returns UTC session
// times; we add the track's UTC offset (in seconds) to get local time at the circuit.
function formatSessionTimeWithOffset(epoch, utcOffsetSeconds, use12Hour) {
  if (!isFinite(epoch)) return ""
  var trackMs = epoch + utcOffsetSeconds * 1000
  var date = new Date(trackMs)
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var h = date.getUTCHours()
  var m = date.getUTCMinutes()
  var timeStr = use12Hour ? format12Hour(h, m) : pad2(h) + ":" + pad2(m)
  return days[date.getUTCDay()] + " " + timeStr
}

// Format hours:minutes as "4:30 PM" or "04:30" depending on locale.
function format12Hour(h, m) {
  var period = h >= 12 ? "PM" : "AM"
  var h12 = h % 12 || 12
  return h12 + ":" + pad2(m) + " " + period
}

// Map WMO weather codes to Nerd Font icon strings (E300 weather range).
function weatherIcon(code) {
  if (code === 0) return "\ue30d"        // clear sky -> day-sunny
  if (code <= 2) return "\ue302"         // partly cloudy -> day-cloudy
  if (code === 3) return "\ue312"        // overcast -> cloudy
  if (code === 45 || code === 48) return "\ue303"  // fog -> day-fog
  if (code >= 51 && code <= 57) return "\ue319"    // drizzle -> showers
  if (code >= 61 && code <= 67) return "\ue319"    // rain -> showers
  if (code >= 71 && code <= 77) return "\ue31a"    // snow -> snow
  if (code >= 80 && code <= 82) return "\ue319"    // showers -> showers
  if (code >= 85 && code <= 86) return "\ue31a"    // snow showers -> snow
  if (code >= 95 && code <= 99) return "\ue31d"    // thunderstorm -> thunderstorm
  return ""
}

// "Sat 16 Aug" for the hero subtitle.
function formatSessionDate(epoch) {
  if (!isFinite(epoch)) return ""
  var date = new Date(epoch)
  var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return days[date.getDay()] + " " + date.getDate() + " " + months[date.getMonth()]
}

// Turn a raw [[lon,lat],...] ring into a [0..1] x [0..1] path that fits the
// unit square. Y is flipped so north points up. Returns [] on bad input.
function normalizeTrack(points) {
  if (!points || points.length < 3) return []
  var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
  var i, x, y
  for (i = 0; i < points.length; i++) {
    if (!points[i] || points[i].length < 2) return []
    x = points[i][0]
    y = points[i][1]
    if (!isFinite(x) || !isFinite(y)) return []
    if (x < minX) minX = x
    if (x > maxX) maxX = x
    if (y < minY) minY = y
    if (y > maxY) maxY = y
  }
  var spanX = maxX - minX
  var spanY = maxY - minY
  if (spanX === 0 || spanY === 0) return []
  var scale = Math.min(1 / spanX, 1 / spanY) * 0.92
  var outW = 1 - spanX * scale
  var outH = 1 - spanY * scale
  var out = []
  for (i = 0; i < points.length; i++) {
    x = (points[i][0] - minX) * scale + outW / 2
    y = 1 - ((points[i][1] - minY) * scale + outH / 2)
    out.push([x, y])
  }
  return out
}
