import Testing
@testable import ThermacCore

@Suite("Sensor catalog")
struct CatalogTests {
    @Test func classifiesHIDNames() {
        #expect(SensorCatalog.classify(hid: "gas gauge battery #3") == .battery)
        #expect(SensorCatalog.classify(hid: "NAND CH0 temp") == .ssd)
        #expect(SensorCatalog.classify(hid: "PMU tdie12 #2") == .soc)
        #expect(SensorCatalog.classify(hid: "PMU tcal") == .calibration)
        #expect(SensorCatalog.classify(hid: "mystery") == .unknown)
    }

    @Test func classifiesSMCKeys() {
        #expect(SensorCatalog.classify(smc: "TB0T") == .battery)
        #expect(SensorCatalog.classify(smc: "TH0x") == .ssd)
        #expect(SensorCatalog.classify(smc: "Ts0P") == .skin)
        #expect(SensorCatalog.classify(smc: "TaLP") == .skin)
        #expect(SensorCatalog.classify(smc: "TDBP") == .display)
        #expect(SensorCatalog.classify(smc: "TD01") == .unknown)
        #expect(SensorCatalog.classify(smc: "TG0B") == .unknown)
        #expect(SensorCatalog.classify(smc: "Tp0A") == .soc)
        #expect(SensorCatalog.classify(smc: "TVA0") == .ambientCandidate)
        #expect(SensorCatalog.classify(smc: "TR0Z") == .calibration)
        #expect(SensorCatalog.classify(smc: "Ta01") == .unknown) // constant 8.3 °C on M4 Pro
        #expect(SensorCatalog.classify(smc: "PSTR") == .unknown)
    }

    @Test func baseNameStripsDuplicateSuffixOnly() {
        #expect(SensorCatalog.baseName("PMU tdie1 #3") == "PMU tdie1")
        #expect(SensorCatalog.baseName("NAND CH0 temp") == "NAND CH0 temp")
        #expect(SensorCatalog.baseName("odd #name") == "odd #name")
    }

    @Test func modelSelectionKeepsSlowSensorsAndCapsSoC() {
        let hid = ["NAND CH0 temp", "PMU tcal", "PMU tcal #2"]
            + (1...10).map { "PMU tdie\($0)" } + (1...10).map { "PMU tdie\($0) #2" }
            + ["gas gauge battery", "gas gauge battery #2"]
        let smc = ["TB0T", "TB1T", "TH0x", "Ts0P", "TVA0", "TR0Z", "Ta01",
                   "Te04", "Te05", "Tg0K", "Tp00", "Tp01", "Tf00", "TPD0", "TRD0"]
        let pick = SensorCatalog.select(hid: hid, smc: smc, all: false)

        #expect(pick.hid.contains("NAND CH0 temp"))
        #expect(pick.hid.contains("gas gauge battery"))
        #expect(!pick.hid.contains("gas gauge battery #2"))  // one instance per name
        #expect(!pick.hid.contains("PMU tcal"))               // calibration excluded
        #expect(pick.hid.filter { $0.hasPrefix("PMU tdie") }.count == SensorCatalog.socLimit)

        #expect(Set(["TB0T", "TB1T", "TH0x", "Ts0P", "TVA0"]).isSubset(of: Set(pick.smc)))
        #expect(!pick.smc.contains("TR0Z") && !pick.smc.contains("Ta01"))
        let soc = pick.smc.filter { SensorCatalog.classify(smc: $0) == .soc }
        #expect(soc.count == SensorCatalog.socLimit)
        #expect(Set(soc) == ["Tp00", "Te04", "Tg0K", "Tf00"]) // one per preferred family
    }

    @Test func allModeKeepsEverything() {
        let pick = SensorCatalog.select(hid: ["a", "b"], smc: ["Ta01"], all: true)
        #expect(pick.hid == ["a", "b"] && pick.smc == ["Ta01"])
    }
}

@Suite("Sample store")
struct StoreTests {
    let channels = [
        Channel(name: "smc:TB0T", kind: .temperature, category: .battery),
        Channel(name: "smc:PSTR", kind: .power, category: .unknown),
    ]

    @Test func registerIsIdempotent() throws {
        let store = try SampleStore(path: ":memory:")
        let a = try store.register(channels)
        let b = try store.register(channels.reversed())
        #expect(a == b.reversed())
        #expect(try store.channelNames().count == 2)
    }

    @Test func insertAndQuery() throws {
        let store = try SampleStore(path: ":memory:")
        let ids = try store.register(channels)
        try store.insert(time: 100, ids: ids, values: [30.5, 7.0])
        try store.insert(time: 105, ids: ids, values: [30.6, nil])  // nil skipped
        try store.insert(time: 110, ids: ids, values: [.nan, 8.0])   // NaN skipped

        #expect(try store.series("smc:TB0T").map(\.value) == [30.5, 30.6])
        #expect(try store.series("smc:PSTR").map(\.t) == [100, 110])
        #expect(try store.count() == 4)
        #expect(store.lastSampleTime() == 110)
        #expect(try store.rows(from: 105).count == 2)
    }

    @Test func compactionAveragesIntoMinuteBuckets() throws {
        let store = try SampleStore(path: ":memory:")
        let ids = try store.register([channels[0]])
        for i in 0..<24 { try store.insert(time: Double(i * 5), ids: ids, values: [Double(i)]) } // 0…115 s
        let removed = try store.compact(olderThan: 120, bucket: 60)

        let s = try store.series("smc:TB0T")
        #expect(s.map(\.t) == [30, 90])
        #expect(s.map(\.value) == [5.5, 17.5])   // mean of 0…11 and 12…23
        #expect(removed == 22)
        #expect(try store.compact(olderThan: 120, bucket: 60) == 0) // idempotent
    }

    @Test func eventsAndMeta() throws {
        let store = try SampleStore(path: ":memory:")
        try store.add(RecordedEvent(time: 1, type: "sleep"))
        try store.add(RecordedEvent(time: 2, type: "wake", detail: "{}"))
        #expect(try store.events().map(\.type) == ["sleep", "wake"])
        #expect(try store.events(type: "wake").count == 1)
        #expect(try store.events(from: 1.5).count == 1)
        try store.setMeta("last_wake", "2")
        #expect(store.meta("last_wake") == "2")
        #expect(store.meta("schema_version") == "1")
    }
}

@Suite("Power events")
struct PowerEventTests {
    @Test func firstUpdateRecordsWake() {
        var t = PowerEventTracker(lastKnownWake: nil)
        let e = t.update(wake: 1000, sleep: 900, now: 1010, onAC: false, charging: false)
        #expect(e.map(\.type) == ["sleep", "wake"])
        #expect(e[1].detail == "{\"slept_s\":100,\"late_s\":10}")
    }

    @Test func sameWakeIsNotRepeated() {
        var t = PowerEventTracker(lastKnownWake: 1000)
        #expect(t.update(wake: 1000.4, sleep: 900, now: 2000, onAC: nil, charging: nil).isEmpty)
    }

    @Test func longSleepIsAnchorOnceUseIsSustained() {
        var t = PowerEventTracker(lastKnownWake: 0)
        let e = t.update(wake: 50_000, sleep: 50_000 - 8 * 3600, now: 50_005, onAC: true, charging: true)
        #expect(e.map(\.type) == ["sleep", "wake"])          // could still be a DarkWake
        #expect(t.update(wake: 50_000, sleep: nil, now: 50_100, onAC: true, charging: true).isEmpty)
        let later = t.update(wake: 50_000, sleep: nil, now: 50_200, onAC: true, charging: true)
        #expect(later.map(\.type) == ["cold_start"])
        #expect(later[0].time == 50_000)                       // timestamped at the wake
        #expect(later[0].detail == "{\"slept_s\":28800,\"session_s\":28800,\"wakes\":1,\"awake_s\":0,\"on_ac\":true,\"charging\":true}")
        #expect(t.session == nil)
    }

    @Test func shortSleepIsNotAnchor() {
        var t = PowerEventTracker(lastKnownWake: 0)
        _ = t.update(wake: 10_000, sleep: 10_000 - 3600, now: 10_001, onAC: false, charging: false)
        let e = t.update(wake: 10_000, sleep: nil, now: 11_000, onAC: false, charging: false)
        #expect(!e.contains { $0.type == "cold_start" })
    }

    /// The real pattern of 2026-11-12: ~15 min sleeps split by 5–10 s DarkWakes.
    func darkWakeNight(start: Double, hours: Double) -> [(sleep: Double, wake: Double)] {
        var out: [(Double, Double)] = []
        var t = start
        while t < start + hours * 3600 {
            out.append((t, t + 900))
            t += 900 + 7
        }
        return out
    }

    @Test func darkWakesAccumulateIntoOneAnchor() throws {
        var t = PowerEventTracker(lastKnownWake: 0)
        var anchors: [RecordedEvent] = []
        for (s, w) in darkWakeNight(start: 100_000, hours: 9) {
            anchors += t.update(wake: w, sleep: s, now: w + 2, onAC: false, charging: false)
                .filter { $0.type == "cold_start" }
        }
        #expect(anchors.isEmpty)                               // nothing mid-night
        let last = try #require(t.session)
        #expect(last.wakes == 36 && last.slept == 36 * 900)
        anchors += t.update(wake: last.lastWake, sleep: nil, now: last.lastWake + 600, onAC: false, charging: false)
        #expect(anchors.count == 1 && anchors[0].time == last.lastWake)
        #expect(last.sleepFraction > 0.99)
    }

    @Test func useBetweenSleepsSplitsSessions() {
        var t = PowerEventTracker(lastKnownWake: 0)
        _ = t.update(wake: 5000, sleep: 1000, now: 5001, onAC: nil, charging: nil)
        _ = t.update(wake: 9000, sleep: 5000 + 600, now: 9001, onAC: nil, charging: nil) // 10 min of use
        #expect(t.session?.start == 5600 && t.session?.wakes == 1)
    }

    @Test func groupsRecordedEventsIntoSessions() {
        var events: [RecordedEvent] = []
        for (s, w) in darkWakeNight(start: 0, hours: 3) {
            events += [RecordedEvent(time: s, type: "sleep"), RecordedEvent(time: w, type: "wake")]
        }
        events += [RecordedEvent(time: 20_000, type: "sleep"), RecordedEvent(time: 20_500, type: "wake")]
        let sessions = SleepSession.group(events)
        #expect(sessions.count == 2)
        #expect(sessions[0].slept == 12 * 900 && sessions[0].wakes == 12)
        #expect(sessions[1].slept == 500)
    }

    @Test func noWakeSinceBoot() {
        var t = PowerEventTracker(lastKnownWake: nil)
        #expect(t.update(wake: nil, sleep: nil, now: 1, onAC: nil, charging: nil).isEmpty)
    }
}

@Suite("Gap analysis")
struct GapTests {
    @Test func sleepAndStopExplainGaps() {
        let ticks: [Double] = [0, 5, 10, 500, 505, 900, 905, 2000]
        let events = [RecordedEvent(time: 200, type: "sleep"), RecordedEvent(time: 950, type: "stop")]
        let gaps = GapAnalysis.unexplainedGaps(ticks: ticks, events: events, threshold: 15)
        #expect(gaps == [GapAnalysis.Gap(start: 505, end: 900)])
    }
}
