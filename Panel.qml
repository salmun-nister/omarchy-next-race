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
  // nested panel (same contract as the weather plugin).
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Series. Defaults to Formula 1; the value comes from the plugin's
  //      settings when one is written, and every other line in this file
  //      goes through the config so a future series only needs Series.js.
  readonly property string seriesId: String(root.setting("series", "f1"))
  readonly property var config: Series.configFor(seriesId)

  // ---- Clock. Ticks so the countdown and "now" markers track wall time.
  property var now: new Date()

  Timer {
    interval: 30 * 1000
    running: true
    repeat: true
    onTriggered: root.now = new Date()
  }

  // ---- Data. The last good calendar response is cached locally so the
  //      plugin degrades to showing stale-but-true races while offline.
  readonly property string cachePath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/next-race.json"
  readonly property string settingsPath: Quickshell.env("HOME") + "/.local/state/omarchy/settings/next-race-settings.json"

  property FileView cacheFile: FileView {
    path: root.cachePath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.ingest(Model.parseJson(text()))
    onLoadFailed: root.races = []
  }

  property FileView settingsFile: FileView {
    path: root.settingsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      var data = Model.parseJson(text())
      if (data && "useTrackTime" in data) root.useTrackTime = data.useTrackTime
    }
    onLoadFailed: {}
  }

  function saveSettings() {
    settingsFile.setText(JSON.stringify({ useTrackTime: root.useTrackTime }))
  }

  property var races: []
  property int fallbackYear: 0
  property bool fetching: false
  property int fetchRetries: 0

  // Season the requested URL belongs to: the current season's full list
  // normally, the next year's opening round once everything is in the past.
  readonly property bool usingFallbackSeason: root.fallbackYear > 0

  // ---- Derived.
  readonly property var nextRace: Model.nextRace(root.races, root.now)
  readonly property var nextSession: Model.nextSession(root.config, root.nextRace, root.now)
  readonly property real targetEpoch: root.nextSession ? Model.parseUtcDate(root.nextSession.date) : NaN
  readonly property bool nextSoon: isFinite(root.targetEpoch) && (root.targetEpoch - root.now.getTime()) < 24 * 3600 * 1000

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color accentColor: Style.selectedStateColor(root.contentForeground, Color.accent)

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

  // Time display mode: false = local time, true = track time.
  property bool useTrackTime: false
  onUseTrackTimeChanged: saveSettings()

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
  // next session once there is.
  readonly property string label: root.nextRace
    ? "\uf11e " + root.config.shortName + " " + Model.countdownText(root.targetEpoch, root.now.getTime())
    : ""

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
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Fetching. One curl at a time, on a 10s leash; failures back off
  //      (a few seconds each) up to a handful of attempts, and any cached
  //      response keeps the panel alive meanwhile.
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
    fetchProc.command = ["curl", "-fsS", "--max-time", "10",
      "-A", root.config.userAgent, url]
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
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.fetching = false
        var raw = String(text || "").trim()
        if (!raw) {
          root.scheduleRetry()
          return
        }
        var parsed = Model.parseJson(raw)
        if (!parsed || !root.config.raceList(parsed)) {
          root.scheduleRetry()
          return
        }
        root.fetchRetries = 0
        root.ingest(parsed)
        cacheFile.setText(JSON.stringify(parsed))
      }
    }
  }

  // Parsed response -> races, then a look-ahead: once the whole calendar is
  // in the past, hop to the next season's opening round for the countdown.
  function ingest(parsed) {
    root.races = Model.parseRaces(root.config, parsed)
    if (!root.races.length) return
    if (!Model.nextRace(root.races, root.now)) {
      var year = Model.nextSeasonYear(root.races, root.now)
      if (year !== null && year !== root.fallbackYear) {
        root.fallbackYear = year
        Qt.callLater(root.startFetch)
      }
    }
  }

  // Keep the calendar fresh while the shell runs; the panel also refreshes
  // every time it opens.
  Timer {
    interval: 30 * 60 * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 1500
    running: true
    onTriggered: { cacheFile.reload(); root.refresh() }
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
    openMeteoProc.command = ["curl", "-fsS", "--max-time", "10", url]
    openMeteoProc.running = true
  }

  Process {
    id: openMeteoProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) return
        var data
        try { data = JSON.parse(raw) } catch (e) { return }
        root.trackUtcOffset = data.utc_offset_seconds || 0
        root.trackTimezone = data.timezone || ""
        if (data.current && data.current.weather_code != null)
          root.trackWeatherIcon = Model.weatherIcon(data.current.weather_code)
        convertSessionTimes()
      }
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
    centerOnBar: true
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
                color: Qt.darker(root.contentForeground, 1.5)
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
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.nextRace ? root.nextRace.locality + ", " + root.nextRace.country : ""
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Text {
                id: countdownLine
                visible: !!root.nextSession
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.nextSession && root.nextRace
                  ? root.nextSession.label + " · " + Model.countdownLong(root.targetEpoch, root.now.getTime())
                  : ""
                color: root.nextSoon ? root.accentColor : Qt.darker(root.contentForeground, 1.35)
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
                  ctx.fillStyle = String(root.accentColor)
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
                    ctx.strokeStyle = String(root.accentColor)
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
              color: Qt.darker(root.contentForeground, 1.8)
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
                color: !root.useTrackTime ? root.accentColor : Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: !root.useTrackTime
                font.underline: !root.useTrackTime

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.useTrackTime = false
                }
              }

              Row {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  text: "<"
                  opacity: !root.useTrackTime ? 1 : 0
                  color: root.accentColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  text: "\uf017"
                  color: root.accentColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.useTrackTime = !root.useTrackTime
                  }
                }

                Text {
                  text: ">"
                  opacity: root.useTrackTime ? 1 : 0
                  color: root.accentColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Text {
                id: trackTimeText
                anchors.verticalCenter: parent.verticalCenter
                text: "track: " + (root.trackTimeString || "--:--")
                color: root.useTrackTime ? root.accentColor : Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                font.bold: root.useTrackTime
                font.underline: root.useTrackTime

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.useTrackTime = true
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
                text: parent.isRace ? parent.modelData.label.toUpperCase() : parent.modelData.label
                color: parent.isNext
                  ? root.accentColor
                  : (parent.past ? Qt.darker(root.contentForeground, 1.8) : root.contentForeground)
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
                color: parent.isNext
                  ? root.accentColor
                  : (parent.past ? Qt.darker(root.contentForeground, 1.8) : Qt.darker(root.contentForeground, 1.2))
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
            color: Qt.darker(root.contentForeground, 1.5)
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
              textFormat: Text.RichText
              text: "<style>a{color:" + Qt.darker(root.contentForeground, 1.8) + ";text-decoration:underline}</style>" +
                    "Race data via " + root.config.sourceLabel + " · Weather by <a href='https://open-meteo.com/'>Open-Meteo</a>"
              color: Qt.darker(root.contentForeground, 1.8)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              onLinkActivated: function(url) { Qt.openUrlExternally(url) }
            }
          }
        }
      }
    }
  }
}
