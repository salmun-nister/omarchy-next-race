import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Series.js" as Series
import "Model.js" as Model
import "Circuits.js" as Circuits

// The next-race panel: the coming round's hero (name, location, countdown,
// track diagram) over its weekend schedule, fed by a per-series calendar
// source (Formula 1 / Jolpica by default). The pill in the bar shows a
// countdown to the next session and is kept honest by the same data.
//
// BarWidget.qml owns the bar label and hands this panel the button to
// anchor against.
Panel {
  id: root
  moduleName: "salmun-nister.next-race"
  ipcTarget: "salmun-nister.next-race"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot — BarWidget.qml — not this
  // nested panel.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Series. Defaults to Formula 1; the value comes from the plugin's
  //      settings when one is written, and every other line in this file
  //      goes through the config so a future series only needs Series.js.
  readonly property string seriesId: String(root.setting("series", "f1"))
  readonly property var config: Series.configFor(seriesId)

  // ---- Clock. Ticks so the countdown and "now" markers track wall time, and
  // so the pill rolls over by itself when a race starts or a season ends.
  property var now: new Date()

  Timer {
    interval: 30 * 1000
    running: true
    repeat: true
    onTriggered: {
      root.now = new Date()
      if (!root.nextRace) root.hopToNextSeason()
    }
  }

  // ---- Data. The last good calendar response is cached locally so the
  //      plugin degrades to showing stale-but-true races while offline.
  readonly property string cachePath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/next-race.json"

  // Hard cap on every response the plugin pulls. Real payloads are ~14 KB
  // (calendar) and under 1 KB (weather); curl aborts the transfer past this,
  // so a hostile or broken endpoint cannot grow the shell's memory or the
  // on-disk cache. The cache read below is bound by the same number.
  readonly property int maxResponseBytes: 65536

  // Cache read and write both go through Processes rather than FileView.
  // The path is predictable, so FileView would pull an arbitrarily large
  // file — or block forever opening a FIFO — into the persistent shell
  // before any cap could be applied. `head -c` stops at the cap and the
  // timeout bounds a pipe that never closes; this is the same bound the
  // shell uses when it copies notification images. Nothing but this plugin
  // writes the cache, so one read at startup is enough.

  Process {
    id: cacheRead
    command: ["timeout", "5", "head", "-c", String(root.maxResponseBytes), "--", root.cachePath]
    running: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // An over-large, malformed or non-object cache is ignored rather
        // than replacing good in-memory races with it.
        var data = Model.parseJsonBounded(text, root.maxResponseBytes)
        if (data) root.ingest(data)
      }
    }
  }

  // Atomic save: write a temp file, then rename, so a torn write is never
  // the file the next shell start reads. The body arrives as a positional
  // parameter to printf, so it is never re-tokenized by the shell.
  readonly property string saveCacheScript:
    'mkdir -p -- "${2%/*}" && printf %s "$1" > "$2.tmp" && mv -f -- "$2.tmp" "$2"'

  function saveCache(body) {
    cacheSave.command = ["bash", "-c", root.saveCacheScript, "next-race-cache", body, root.cachePath]
    cacheSave.running = true
  }

  Process { id: cacheSave }

  property var races: []
  property int fallbackYear: 0
  property bool fetching: false
  property int fetchRetries: 0

  // Season the requested URL belongs to: the current season's full list
  // normally, the next year's opening round once everything is in the past.
  readonly property bool usingFallbackSeason: root.fallbackYear > 0

  // ---- Derived.
  readonly property var nextRace: Model.nextRace(root.config, root.races, root.now)
  readonly property var nextSession: Model.nextSession(root.config, root.nextRace, root.now)
  readonly property real targetEpoch: root.nextSession ? Model.parseUtcDate(root.nextSession.date) : NaN
  // The targeted session has started and sits inside its estimated running
  // window, so pill and hero say so instead of counting the next event.
  readonly property bool sessionLive: Model.sessionLive(root.config, root.nextSession, root.now.getTime())

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  // Theme-authored secondary tone; emphasis comes from weight, not shading.
  readonly property color mutedText: Color.muted

  readonly property var trackPoints: root.nextRace ? Circuits.circuitPoints(root.nextRace.circuitId) : undefined
  readonly property var trackPath: Model.normalizeTrack(root.trackPoints)

  // Bounding box of the normalized track points, used to size the Canvas
  // tightly around the actual geometry instead of assuming a fixed aspect ratio.
  readonly property var trackBounds: (function() {
    var pts = root.trackPath
    if (!pts || pts.length < 3) return { minX: 0, maxX: 1, minY: 0, maxY: 1, w: 1, h: 1, aspect: 0.6 }
    var minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity
    for (var i = 0; i < pts.length; i++) {
      if (pts[i][0] < minX) minX = pts[i][0]
      if (pts[i][0] > maxX) maxX = pts[i][0]
      if (pts[i][1] < minY) minY = pts[i][1]
      if (pts[i][1] > maxY) maxY = pts[i][1]
    }
    var w = maxX - minX || 1
    var h = maxY - minY || 1
    return { minX: minX, maxX: maxX, minY: minY, maxY: maxY, w: w, h: h, aspect: h / w }
  })()

  // Time display mode: false = local time, true = track time. An ordinary
  // widget option, so it lives on this entry's shell.json settings with
  // `series` rather than in a second file, and the panel just reads it back.
  readonly property bool useTrackTime: root.setting("useTrackTime", false) === true

  // Applied locally first so the panel redraws on the click itself; the
  // shell.json write comes back through the bar as the same value. With no
  // writable entry (the widget is not in the layout) it stays a session-only
  // preference rather than doing nothing.
  function setTrackTime(value) {
    var next = !!value
    if (next === root.useTrackTime) return
    var entry = { id: root.moduleName }
    for (var key in root.settings) if (key !== "id") entry[key] = root.settings[key]
    entry.useTrackTime = next

    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Locale-aware time format detection.
  readonly property bool use12Hour: {
    var fmt = Qt.locale().timeFormat(Locale.ShortFormat)
    return fmt.indexOf("AP") !== -1 || fmt.indexOf("ap") !== -1
  }
  onUse12HourChanged: convertSessionTimes()

  // Open-Meteo timezone data, populated when race changes.
  property string trackTimezone: ""
  property int trackUtcOffset: 0

  // Cached track session times and weather, populated by Process.
  property var trackSessionTimes: []
  property string trackWeatherIcon: ""

  // Current times for the toggle display.
  // Local time always uses HH:mm since Qt.locale() returns en-US (12hr)
  // even when the user's KDE desktop is set to 24hr. Session times below
  // respect use12Hour for display consistency with track-local formatting.
  readonly property string localTimeString: {
    var h = root.now.getHours()
    var m = root.now.getMinutes()
    return Model.pad2(h) + ":" + Model.pad2(m)
  }

  // Track time computed from root.now + UTC offset (no separate Process needed).
  // Always uses HH:mm for the same reason as localTimeString above.
  readonly property string trackTimeString: {
    if (!root.trackUtcOffset) return ""
    var trackMs = root.now.getTime() + root.trackUtcOffset * 1000
    var d = new Date(trackMs)
    var h = d.getUTCHours()
    var m = d.getUTCMinutes()
    return Model.pad2(h) + ":" + Model.pad2(m)
  }

  // The pill. Hidden until there is something to say; a countdown to the
  // next session once there is. A session in progress counts down to "now".
  readonly property string label: !root.nextRace ? "" : "\uf11e " + root.config.shortName + " " + Model.countdownText(root.targetEpoch, root.now.getTime())

  // ---- Open/close, mirroring the clock panel's contract.
  function open() {
    refresh()
    root.controller.show()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function openFromHotkey() {
    root.controller.show()
    refresh()
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && typeof root.bar.setCenterHoverRevealSuppressed === "function")
      root.bar.setCenterHoverRevealSuppressed(value)
    else if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Fetching. One curl at a time, on a 10s leash; failures back off
  //      (a few seconds each) up to a handful of attempts, and any cached
  //      response keeps the panel alive meanwhile.
  // Fetches once at load; after that the daily timer below plus the panel's
  // own open/refresh paths drive it.
  Component.onCompleted: refresh()

  function refresh() {
    if (fetchProc.running) return
    root.fetchRetries = 0
    startFetch()
  }

  function startFetch() {
    if (fetchProc.running) return
    root.fetching = true
    var url = root.usingFallbackSeason
      ? root.config.nextSeasonUrl(root.fallbackYear)
      : root.config.seasonUrl
    fetchProc.command = ["curl", "-q", "-fsS", "--max-time", "10",
      "--max-filesize", String(root.maxResponseBytes),
      "-A", root.config.userAgent, url]
    // The gate below needs both flags to describe this run alone. Kept from the
    // previous run, a stale exit code of 0 would let a request that is still
    // running, or has just failed, through the success check.
    fetchProc.exitCode = -1
    fetchProc.bodyDone = false
    fetchProc.running = true
  }

  function scheduleRetry() {
    if (root.fetchRetries >= 3) {
      root.fetching = false
      return
    }
    root.fetchRetries++
    retryTimer.restart()
  }

  Timer {
    id: retryTimer
    interval: 2500
    onTriggered: root.startFetch()
  }

  Process {
    id: fetchProc
    property int exitCode: -1
    property bool bodyDone: false

    onExited: (code) => {
      fetchProc.exitCode = code
      fetchProc.handleResponse()
    }

    stdout: StdioCollector {
      id: calendarBody
      waitForEnd: true
      onStreamFinished: {
        fetchProc.bodyDone = true
        fetchProc.handleResponse()
      }
    }

    // Whichever signal lands last completes the response. Both flags are reset
    // per run before the process starts, so the first call of a run sees
    // exitCode -1 and returns, and only the second, carrying the real exit
    // code, does any work.
    function handleResponse() {
      if (!fetchProc.bodyDone || fetchProc.exitCode < 0) return
      root.fetching = false
      var raw = String(calendarBody.text || "").trim()
      // A non-zero exit is a failure, and a body at the cap is a truncated one
      // (curl aborts the transfer past it). Neither is ever parsed or cached.
      // The length here is characters; curl's --max-filesize is the byte cap.
      if (fetchProc.exitCode !== 0 || !raw || raw.length >= root.maxResponseBytes) {
        root.scheduleRetry()
        return
      }
      var parsed = Model.parseJsonBounded(raw, root.maxResponseBytes)
      if (!parsed || !root.config.raceList(parsed)) {
        root.scheduleRetry()
        return
      }
      root.fetchRetries = 0
      root.ingest(parsed)
      root.saveCache(JSON.stringify(parsed))
    }
  }

  // Parsed response -> races, then a look-ahead: once the whole calendar is
  // in the past, hop to the next season's opening round for the countdown.
  function ingest(parsed) {
    root.races = Model.parseRaces(root.config, parsed)
    if (!root.races.length) return
    if (!Model.nextRace(root.config, root.races, root.now)) root.hopToNextSeason()
  }

  // Nothing left in the loaded calendar: fetch the next season's opener so
  // the pill keeps a real countdown instead of going blank. The fallback
  // year sticks, so this runs once per off-season rather than every tick.
  // The fetch goes out on the retry timer, not callLater: when a hop follows
  // a fetch, that process is still marked running here and startFetch would
  // bail out on it, leaving the pill blank with the year already spent.
  function hopToNextSeason() {
    var year = Model.nextSeasonYear(root.races, root.now)
    if (year === null || year === root.fallbackYear) return
    root.fallbackYear = year
    retryTimer.restart()
  }

  // Keep the calendar fresh while the shell runs. Daily is plenty for a
  // calendar that changes a few times per season, and it costs one request a
  // day. The panel also refreshes every time it opens or is middle-clicked.
  Timer {
    interval: 24 * 60 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  // ---- Open-Meteo: timezone + weather for the next race's circuit.
  onNextRaceChanged: fetchTrackData()

  function fetchTrackData() {
    if (!root.nextRace || root.nextRace.lat == null || root.nextRace.long == null) return
    var url = "https://api.open-meteo.com/v1/forecast"
      + "?latitude=" + root.nextRace.lat
      + "&longitude=" + root.nextRace.long
      + "&current=weather_code,temperature_2m"
      + "&timezone=auto"
    openMeteoProc.command = ["curl", "-q", "-fsS", "--max-time", "10",
      "--max-filesize", String(root.maxResponseBytes), url]
    openMeteoProc.exitCode = -1
    openMeteoProc.bodyDone = false
    openMeteoProc.running = true
  }

  Process {
    id: openMeteoProc
    property int exitCode: -1
    property bool bodyDone: false

    onExited: (code) => {
      openMeteoProc.exitCode = code
      openMeteoProc.handleResponse()
    }

    stdout: StdioCollector {
      id: weatherBody
      waitForEnd: true
      onStreamFinished: {
        openMeteoProc.bodyDone = true
        openMeteoProc.handleResponse()
      }
    }

    function handleResponse() {
      if (!openMeteoProc.bodyDone || openMeteoProc.exitCode < 0) return
      var raw = String(weatherBody.text || "").trim()
      if (openMeteoProc.exitCode !== 0 || !raw || raw.length >= root.maxResponseBytes) return
      var data = Model.parseJsonBounded(raw, root.maxResponseBytes)
      if (!data) return
      root.trackUtcOffset = data.utc_offset_seconds || 0
      root.trackTimezone = data.timezone || ""
      if (data.current && data.current.weather_code != null)
        root.trackWeatherIcon = Model.weatherIcon(data.current.weather_code)
      convertSessionTimes()
    }
  }

  function convertSessionTimes() {
    if (!root.nextRace || !root.nextRace.sessions) { root.trackSessionTimes = []; return }
    var out = []
    for (var i = 0; i < root.nextRace.sessions.length; i++) {
      var epoch = Model.parseUtcDate(root.nextRace.sessions[i].date)
      out.push(Model.formatSessionTimeWithOffset(epoch, root.trackUtcOffset, root.use12Hour))
    }
    root.trackSessionTimes = out
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: contentScroll
        anchors.fill: parent
        contentWidth: contentColumn.width
        contentHeight: contentColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height || contentWidth > width

        Column {
          id: contentColumn
          width: contentScroll.width
          spacing: Style.space(12)

          // ---- Hero: race heading across the top, track + countdown below.
          Column {
            width: parent.width
            spacing: Style.space(2)

            Column {
              width: parent.width
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(2)

              Text {
                id: seasonLine
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.nextRace
                  ? root.nextRace.season + " SEASON · ROUND " + root.nextRace.round
                  : ""
                textFormat: Text.PlainText
                color: root.mutedText
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.letterSpacing: 1
                font.bold: true
              }

              Text {
                id: raceName
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.nextRace ? root.nextRace.name : ""
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.nextRace ? root.nextRace.locality + ", " + root.nextRace.country : ""
                textFormat: Text.PlainText
                color: root.mutedText
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                id: countdownLine
                visible: !!root.nextSession
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.nextSession && root.nextRace
                  ? root.nextSession.label + " · " + (root.sessionLive ? "live" : Model.countdownLong(root.targetEpoch, root.now.getTime()))
                  : ""
                textFormat: Text.PlainText
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
              }
            }

            Item { width: 1; height: Style.space(2) }

            Canvas {
              id: trackCanvas
              width: parent.width
              height: width * root.trackBounds.aspect

              readonly property real pad: Style.space(2)

                readonly property color fg: root.contentForeground
                onFgChanged: requestPaint()
                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()

                Connections {
                  target: root
                  function onTrackPathChanged() { trackCanvas.requestPaint() }
                  function onNowChanged() { trackCanvas.requestPaint() }
                }

                onPaint: {
                  var ctx = getContext("2d")
                  ctx.reset()
                  var pts = root.trackPath
                  if (!pts || pts.length < 3) return

                  var pad = trackCanvas.pad
                  var b = root.trackBounds
                  var s = Math.min((width - pad * 2) / b.w, (height - pad * 2) / b.h)
                  var ox = pad + (width - pad * 2 - b.w * s) / 2 - b.minX * s
                  var oy = pad + (height - pad * 2 - b.h * s) / 2 - b.minY * s

                  function px(p) { return ox + p[0] * s }
                  function py(p) { return oy + p[1] * s }

                  ctx.strokeStyle = String(root.contentForeground)
                  ctx.lineWidth = 2
                  ctx.lineJoin = "round"
                  ctx.lineCap = "round"
                  ctx.beginPath()
                  ctx.moveTo(px(pts[0]), py(pts[0]))
                  for (var i = 1; i < pts.length; i++) ctx.lineTo(px(pts[i]), py(pts[i]))
                  ctx.closePath()
                  ctx.stroke()

                  // Start/finish: the ring's first point, marked as a filled
                  // dot so the diagram reads which way the lap goes.
                  ctx.fillStyle = String(Color.accent)
                  ctx.beginPath()
                  ctx.arc(px(pts[0]), py(pts[0]), 3.5, 0, Math.PI * 2)
                  ctx.fill()

                  // Direction of travel: the ring is ordered along the racing
                  // line, so pts[0] -> pts[2] gives a stable tangent. Draw a
                  // small ">" just after the start/finish dot, centered on the
                  // track path and pointing the way the lap goes.
                  var tx = pts[2][0] - pts[0][0]
                  var ty = pts[2][1] - pts[0][1]
                  var tl = Math.sqrt(tx * tx + ty * ty)
                  if (tl > 1e-6) {
                    tx /= tl
                    ty /= tl
                    var nx = -ty
                    var ny = tx
                    var cx = px(pts[0]) + tx * 7
                    var cy = py(pts[0]) + ty * 7
                    ctx.strokeStyle = String(Color.accent)
                    ctx.lineWidth = 2
                    ctx.lineCap = "round"
                    ctx.beginPath()
                    ctx.moveTo(cx + tx * 3, cy + ty * 3)
                    ctx.lineTo(cx - tx * 2 + nx * 2.5, cy - ty * 2 + ny * 2.5)
                    ctx.moveTo(cx + tx * 3, cy + ty * 3)
                    ctx.lineTo(cx - tx * 2 - nx * 2.5, cy - ty * 2 - ny * 2.5)
                    ctx.stroke()
                  }
                }

                Text {
                  visible: !root.trackPoints || root.trackPoints.length < 3
                  anchors.centerIn: parent
                  text: "no track data"
                  textFormat: Text.PlainText
                  color: Qt.darker(root.contentForeground, 1.8)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // ---- Circuit name + weather icon.
            Text {
              visible: !!root.nextRace
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: (root.nextRace ? root.nextRace.circuitName : "") +
                    (root.trackWeatherIcon !== "" ? "  " + root.trackWeatherIcon : "")
              textFormat: Text.PlainText
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.heading
              font.letterSpacing: 1
            }

            // ---- Time zone toggle.
            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(16)

              Text {
                id: localTimeText
                anchors.verticalCenter: parent.verticalCenter
                text: "local: " + root.localTimeString
                textFormat: Text.PlainText
                color: !root.useTrackTime ? root.contentForeground : root.mutedText
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: !root.useTrackTime
                font.underline: !root.useTrackTime

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setTrackTime(false)
                }
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  text: "<"
                  textFormat: Text.PlainText
                  opacity: !root.useTrackTime ? 1 : 0
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  text: "\uf017"
                  textFormat: Text.PlainText
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.setTrackTime(!root.useTrackTime)
                  }
                }

                Text {
                  text: ">"
                  textFormat: Text.PlainText
                  opacity: root.useTrackTime ? 1 : 0
                  color: Color.accent
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                id: trackTimeText
                anchors.verticalCenter: parent.verticalCenter
                text: "track: " + (root.trackTimeString || "--:--")
                textFormat: Text.PlainText
                color: root.useTrackTime ? root.contentForeground : root.mutedText
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.useTrackTime
                font.underline: root.useTrackTime

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.setTrackTime(true)
                }
              }
            }

          // ---- Session rows.
          Repeater {
            model: root.nextRace ? root.nextRace.sessions : []

            Item {
              required property var modelData

              width: contentColumn.width
              height: Math.max(sessionName.implicitHeight, sessionTime.implicitHeight)

              readonly property bool isNext: root.nextSession && modelData.key === root.nextSession.key
              readonly property bool isRace: modelData.key === root.config.raceSessionKey
              readonly property bool past: Model.parseUtcDate(modelData.date) < root.now.getTime()

              Text {
                id: sessionName
                anchors.left: parent.left
                anchors.leftMargin: Style.space(16)
                anchors.verticalCenter: parent.verticalCenter
                text: parent.modelData.label
                textFormat: Text.PlainText
                color: parent.past ? root.mutedText : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: parent.isRace || parent.isNext
                font.letterSpacing: parent.isRace ? 1 : 0
              }

              Text {
                id: sessionTime
                anchors.right: parent.right
                anchors.rightMargin: Style.space(20)
                anchors.verticalCenter: parent.verticalCenter
                text: root.useTrackTime
                  ? (root.trackSessionTimes.length > parent.index
                      ? root.trackSessionTimes[parent.index]
                      : Model.formatSessionTimeWithOffset(Model.parseUtcDate(parent.modelData.date), root.trackUtcOffset, root.use12Hour))
                  : Model.formatSessionTime(Model.parseUtcDate(parent.modelData.date), root.use12Hour)
                textFormat: Text.PlainText
                color: parent.past ? root.mutedText : root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: parent.isNext
              }
            }
          }

          // ---- Empty states.
          Text {
            visible: !root.nextRace
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.fetching
              ? "Fetching " + root.config.sourceLabel + "…"
              : "No upcoming races"
            textFormat: Text.PlainText
            color: root.mutedText
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.bodySmall
            font.italic: true
          }

          // ---- Footer.
          Rectangle {
            width: parent.width
            height: Style.spacing.hairline
            color: root.contentForeground
            opacity: 0.12
          }

          Row {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(16)
            anchors.right: parent.right
            anchors.rightMargin: Style.space(20)
            spacing: Style.space(8)

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: "Race data via " + root.config.sourceLabel + " · Weather by Open-Meteo"
              color: Qt.darker(root.contentForeground, 1.8)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }
    }
  }
}
