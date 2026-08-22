// Series registry. Every entry owns everything needed to source, extract,
// and label one racing series' calendar. Only Formula 1 ships today; the
// config shape is the extension point for future series (MotoGP, NASCAR, ...).
//
// A config provides:
//   seasonUrl / nextSeasonUrl(year)  - calendar endpoints
//   userAgent                        - sent with every request
//   raceList(parsed)                 - races array out of a parsed response
//   raceSeason / raceRound / raceName / circuitId / circuitName
//   locality / country               - location fields off a race
//   circuitLat / circuitLong          - circuit coordinates for timezone lookup
//   sessionSlots                     - ordered [{key, label}] the API can emit
//   raceSessionKey                   - which slot is the race itself
//   sessionsFromRace(race)           - [{key, label, dateISO}] actually present

var SERIES = {
  f1: {
    id: "f1",
    name: "Formula 1",
    shortName: "F1",
    sourceLabel: "Jolpica F1",
    sourceUrl: "https://api.jolpi.ca/ergast/f1/",
    userAgent: "salmun-nister.next-race/1.1 (omarchy plugin)", // keep version in sync with manifest.json
    seasonUrl: "https://api.jolpi.ca/ergast/f1/current/races.json?limit=30",
    nextSeasonUrl: function(year) {
      return "https://api.jolpi.ca/ergast/f1/" + year + "/1/races.json"
    },
    raceList: function(parsed) {
      if (!parsed || !parsed.MRData || !parsed.MRData.RaceTable) return null
      return parsed.MRData.RaceTable.Races
    },
    raceSeason: function(race) { return race ? race.season : "" },
    raceRound: function(race) { return race ? race.round : "" },
    raceName: function(race) { return race ? race.raceName : "" },
    circuitId: function(race) {
      return race && race.Circuit ? race.Circuit.circuitId : ""
    },
    circuitName: function(race) {
      return race && race.Circuit ? race.Circuit.circuitName : ""
    },
    locality: function(race) {
      return race && race.Circuit && race.Circuit.Location
        ? race.Circuit.Location.locality : ""
    },
    country: function(race) {
      return race && race.Circuit && race.Circuit.Location
        ? race.Circuit.Location.country : ""
    },
    circuitLat: function(race) {
      return race && race.Circuit && race.Circuit.Location
        ? parseFloat(race.Circuit.Location.lat) : null
    },
    circuitLong: function(race) {
      return race && race.Circuit && race.Circuit.Location
        ? parseFloat(race.Circuit.Location.long) : null
    },
    sessionSlots: [
      { key: "FirstPractice", label: "Practice 1" },
      { key: "SecondPractice", label: "Practice 2" },
      { key: "ThirdPractice", label: "Practice 3" },
      { key: "SprintQualifying", label: "Sprint Qualifying" },
      { key: "Sprint", label: "Sprint" },
      { key: "Qualifying", label: "Qualifying" },
      { key: "Race", label: "Race" }
    ],
    raceSessionKey: "Race",
    // Typical running windows in minutes. Jolpica publishes start times
    // only; these estimates keep a started event targeted as live until it
    // plausibly ends.
    sessionDurations: {
      FirstPractice: 60,
      SecondPractice: 60,
      ThirdPractice: 60,
      SprintQualifying: 60,
      Sprint: 45,
      Qualifying: 90,
      Race: 120
    },
    sessionsFromRace: function(race) {
      var out = []
      var slots = this.sessionSlots
      var raceKey = this.raceSessionKey
      for (var i = 0; i < slots.length; i++) {
        var date = null
        var time = null
        if (slots[i].key === raceKey) {
          // The race itself is the event object: its start lives on the
          // top-level `date`/`time`, not in a `Race` sub-object.
          date = race.date
          time = race.time
        } else {
          var session = race[slots[i].key]
          if (!session) continue
          date = session.date
          time = session.time
        }
        if (!date) continue
        out.push({
          key: slots[i].key,
          label: slots[i].label,
          date: date + "T" + (time || "00:00:00Z")
        })
      }
      return out
    }
  }
}

function configFor(id) {
  return SERIES[id] || SERIES.f1
}
