import Foundation
import Combine

struct LyricLine { let time: Double; let text: String }

/// Fetches synced (LRC) lyrics from the public LRCLIB service for the current track.
final class LyricsStore: ObservableObject {
    @Published var lines: [LyricLine] = []
    private var key = ""
    private var bag = Set<AnyCancellable>()
    private var cache: [String: [LyricLine]] = [:]

    init(music: NowPlaying) {
        music.$track.receive(on: DispatchQueue.main).sink { [weak self] t in self?.trackChanged(t) }.store(in: &bag)
    }

    private func trackChanged(_ t: Track?) {
        guard let t else { key = ""; lines = []; return }
        let k = "\(t.artist)|\(t.title)"
        guard k != key else { return }
        key = k
        if let c = cache[k] { lines = c; return }
        lines = []
        fetch(t, k)
    }

    private func fetch(_ t: Track, _ k: String) {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [.init(name: "artist_name", value: t.artist), .init(name: "track_name", value: t.title)]
        if t.duration > 0 { c.queryItems?.append(.init(name: "duration", value: String(Int(t.duration.rounded())))) }
        var req = URLRequest(url: c.url!); req.setValue("Rokaconnect/0.1", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lrc = j["syncedLyrics"] as? String else { return }
            let parsed = Self.parse(lrc)
            DispatchQueue.main.async {
                self?.cache[k] = parsed
                if self?.key == k { self?.lines = parsed }
            }
        }.resume()
    }

    static func parse(_ lrc: String) -> [LyricLine] {
        let re = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var out: [LyricLine] = []
        for raw in lrc.split(separator: "\n") {
            let line = String(raw), ns = line as NSString
            let ms = re.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = ms.last else { continue }
            let text = ns.substring(from: last.range.upperBound).trimmingCharacters(in: .whitespaces)
            for m in ms {
                let t = Double(ns.substring(with: m.range(at: 1)))! * 60 + Double(ns.substring(with: m.range(at: 2)))!
                out.append(LyricLine(time: t, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    func index(at pos: Double) -> Int? {
        guard Settings.shared.lyricsOn, !lines.isEmpty, pos >= lines[0].time else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if lines[mid].time <= pos { lo = mid } else { hi = mid - 1 } }
        return lo
    }

    func line(at pos: Double) -> String? {
        guard Settings.shared.lyricsOn, !lines.isEmpty, pos >= lines[0].time else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if lines[mid].time <= pos { lo = mid } else { hi = mid - 1 } }
        let t = lines[lo].text
        return t.isEmpty ? nil : t
    }
}
