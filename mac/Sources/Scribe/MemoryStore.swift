import Foundation
import CryptoKit
import SQLite3
import USearch

/// What Bolkit heard, for agents: memory/memory.sqlite (sources, chunks, FTS5) and
/// memory/vectors.usearch (HNSW over chunk vectors, keyed by chunk id). Not thread-safe.
final class MemoryStore {
  typealias Embed = (_ text: String, _ isQuery: Bool) -> [Float]?
  static let dims = 384
  static let vectorVersion = 2

  struct Chunk: Equatable {
    var speaker: String
    var startMs: Int?
    var endMs: Int?
    var text: String
  }

  struct Filters {
    var person: String?
    var from: String?
    var to: String?
    var kind: String?
    var isEmpty: Bool { person == nil && from == nil && to == nil && kind == nil }
    var args: [Any?] { [person, from, to, kind] }
  }

  struct Hit {
    let id: Int
    let ref: String
    let kind: String
    let title: String
    let startedAt: String?
    let speaker: String
    let startMs: Int?
    let endMs: Int?
    let snippet: String
  }

  struct Source {
    let ref: String
    let kind: String
    let title: String
    let startedAt: String?
    let endedAt: String?
    let speakers: [String]
    let chunks: Int
  }

  static var defaultDir: URL {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--memory-dir"), args.count > i + 1 {
      return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Scribe/memory", isDirectory: true)
  }

  let dir: URL
  private(set) var trigram = false
  private var db: OpaquePointer?
  private var view: USearchIndex?
  private var viewStamp: Date?
  private var vectorPath: String { dir.appendingPathComponent("vectors.usearch").path }

  /// `readOnly` never creates the database and refuses writes (the MCP side).
  init?(dir: URL = MemoryStore.defaultDir, readOnly: Bool = false) {
    self.dir = dir
    let path = dir.appendingPathComponent("memory.sqlite").path
    if readOnly {
      guard FileManager.default.fileExists(atPath: path) else { return nil }
    } else {
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let flags = SQLITE_OPEN_READWRITE | (readOnly ? 0 : SQLITE_OPEN_CREATE)
    guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
      sqlite3_close(db)
      return nil
    }
    sqlite3_busy_timeout(db, 5000)
    if readOnly { exec("PRAGMA query_only = 1") } else { createSchema() }
    rows("SELECT sql FROM sqlite_master WHERE name = 'chunk_fts'") { self.trigram = self.text($0, 0)?.contains("trigram") == true }
  }

  deinit { sqlite3_close(db) }

  private var storedVectorVersion: Int {
    var v = 0
    rows("PRAGMA user_version") { v = self.int($0, 0) ?? 0 }
    return v
  }

  private func createSchema() {
    exec("PRAGMA journal_mode = WAL")
    exec("""
      CREATE TABLE IF NOT EXISTS source(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL,
        ref TEXT NOT NULL UNIQUE, title TEXT, started_at TEXT, ended_at TEXT, hash TEXT);
      CREATE TABLE IF NOT EXISTS chunk(id INTEGER PRIMARY KEY AUTOINCREMENT,
        source_id INTEGER NOT NULL REFERENCES source(id), speaker TEXT, start_ms INTEGER, end_ms INTEGER,
        text TEXT NOT NULL, vec INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS chunk_source ON chunk(source_id);
      CREATE INDEX IF NOT EXISTS chunk_pending ON chunk(vec) WHERE vec = 0;
      """)
    let fts = "CREATE VIRTUAL TABLE IF NOT EXISTS chunk_fts USING fts5(text, content='chunk', content_rowid='id', tokenize="
    if !exec(fts + "'trigram')") { exec(fts + "'unicode61 remove_diacritics 2')") }
    exec("""
      CREATE TRIGGER IF NOT EXISTS chunk_ai AFTER INSERT ON chunk BEGIN
        INSERT INTO chunk_fts(rowid, text) VALUES (new.id, new.text);
      END;
      CREATE TRIGGER IF NOT EXISTS chunk_ad AFTER DELETE ON chunk BEGIN
        INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES ('delete', old.id, old.text);
      END;
      """)
    if storedVectorVersion != Self.vectorVersion {
      try? FileManager.default.removeItem(atPath: vectorPath)
      exec("UPDATE chunk SET vec = 0 WHERE vec != 0")
      exec("PRAGMA user_version = \(Self.vectorVersion)")
    }
  }

  // MARK: - chunking

  /// Consecutive turns merged up to `maxWords`, cut only at a turn or sentence end; one line per turn.
  static func chunks(_ d: MeetingDetail, maxWords: Int = 220) -> [Chunk] {
    typealias Segment = (speaker: String, words: ArraySlice<Substring>, start: Double?, end: Double?)
    var segments: [Segment] = []
    for (i, turn) in d.turns.enumerated() {
      let words = turn.text.split(whereSeparator: \.isWhitespace)
      guard !words.isEmpty else { continue }
      // ponytail: meetings saved before turns carried an end take the next turn's start, or 0.4 s a word.
      let end = turn.end ?? d.turns[(i + 1)...].lazy.compactMap(\.start).first ?? turn.start.map { $0 + Double(words.count) * 0.4 }
      for piece in sentencePieces(words, maxWords: maxWords) {
        func at(_ w: Int) -> Double? {
          guard let s = turn.start, let e = end else { return turn.start }
          return s + (e - s) * Double(w) / Double(words.count)
        }
        segments.append((d.agentName(turn.speaker), words[piece], at(piece.lowerBound), at(piece.upperBound)))
      }
    }
    var out: [Chunk] = []
    var current: [Segment] = []
    func flush() {
      guard let first = current.first, let last = current.last else { return }
      var speakers: [String] = []
      for s in current where !speakers.contains(s.speaker) { speakers.append(s.speaker) }
      out.append(Chunk(
        speaker: speakers.joined(separator: ", "),
        startMs: first.start.map { Int($0 * 1000) }, endMs: last.end.map { Int($0 * 1000) },
        text: current.map { "\($0.speaker): " + $0.words.joined(separator: " ") }.joined(separator: "\n")))
      current = []
    }
    for segment in segments {
      if current.reduce(0, { $0 + $1.words.count }) + segment.words.count > maxWords { flush() }
      current.append(segment)
    }
    flush()
    return out
  }

  private static func sentencePieces(_ words: [Substring], maxWords: Int) -> [Range<Int>] {
    var out: [Range<Int>] = []
    var start = 0
    while words.count - start > maxWords {
      let cut = (start..<(start + maxWords)).last { i in
        [".", "?", "!", "।"].contains { words[i].hasSuffix($0) }
      }.map { $0 + 1 }
      let end = cut.flatMap { $0 - start > maxWords / 3 ? $0 : nil } ?? start + maxWords
      out.append(start..<end)
      start = end
    }
    out.append(start..<words.count)
    return out
  }

  // MARK: - indexing

  /// Indexes a saved meeting folder; false when it has no transcript or nothing changed.
  @discardableResult
  func indexMeeting(_ dir: URL) -> Bool {
    guard let d = MeetingDetail.load(dir) else { return false }
    let created = try? dir.resourceValues(forKeys: [.creationDateKey]).creationDate
    return index(d, ref: dir.lastPathComponent, fallbackDate: created)
  }

  @discardableResult
  func index(_ d: MeetingDetail, ref: String, fallbackDate: Date?) -> Bool {
    let chunks = Self.chunks(d)
    guard !chunks.isEmpty else { return false }
    let started = Self.folderFormat.date(from: ref) ?? fallbackDate
    let ended = started.flatMap { s in
      (d.duration ?? chunks.last?.endMs.map { Double($0) / 1000 }).map { s.addingTimeInterval($0) }
    }
    let title = d.title ?? d.summary.flatMap(MeetingRecorder.preview).map { String($0.prefix(120)) }
      ?? "Meeting " + (started.map { Self.stamp($0).prefix(16) } ?? ref[...])
    return upsert(kind: "meeting", ref: ref, title: title,
                  startedAt: started.map(Self.stamp), endedAt: ended.map(Self.stamp), chunks: chunks)
  }

  @discardableResult
  func indexDictation(_ text: String, at date: Date?) -> Bool {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return false }
    let title = clean.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
    return upsert(kind: "dictation", ref: "d-" + Self.sha256(clean).prefix(16), title: title,
                  startedAt: date.map(Self.stamp), endedAt: nil,
                  chunks: [Chunk(speaker: "You", startMs: nil, endMs: nil, text: clean)])
  }

  /// Replaces a source's chunks and vectors when its content changed.
  @discardableResult
  func upsert(kind: String, ref: String, title: String, startedAt: String?, endedAt: String?,
              chunks: [Chunk]) -> Bool {
    let hash = Self.sha256(chunks.map { "\($0.speaker)|\($0.startMs ?? -1)|\($0.endMs ?? -1)|\($0.text)" }
      .joined(separator: "\n"))
    var existing: (id: Int, hash: String?)?
    rows("SELECT id, hash FROM source WHERE ref = ?", [ref]) { existing = (self.int($0, 0) ?? 0, self.text($0, 1)) }
    if existing?.hash == hash { return false }
    if let id = existing?.id { dropVectors(sourceId: id) }
    exec("BEGIN IMMEDIATE")
    var ok: Bool
    var sourceId: Int
    if let id = existing?.id {
      sourceId = id
      ok = rows("DELETE FROM chunk WHERE source_id = ?", [id])
        && rows("UPDATE source SET title = ?, started_at = ?, ended_at = ?, hash = ? WHERE id = ?",
                [title, startedAt, endedAt, hash, id])
    } else {
      ok = rows("INSERT INTO source(kind, ref, title, started_at, ended_at, hash) VALUES (?, ?, ?, ?, ?, ?)",
                [kind, ref, title, startedAt, endedAt, hash])
      sourceId = Int(sqlite3_last_insert_rowid(db))
    }
    for c in chunks where ok {
      ok = rows("INSERT INTO chunk(source_id, speaker, start_ms, end_ms, text) VALUES (?, ?, ?, ?, ?)",
                [sourceId, c.speaker, c.startMs, c.endMs, c.text])
    }
    exec(ok ? "COMMIT" : "ROLLBACK")
    return ok
  }

  func remove(ref: String) {
    var id: Int?
    rows("SELECT id FROM source WHERE ref = ?", [ref]) { id = self.int($0, 0) }
    guard let id else { return }
    dropVectors(sourceId: id)
    exec("BEGIN IMMEDIATE")
    let ok = rows("DELETE FROM chunk WHERE source_id = ?", [id]) && rows("DELETE FROM source WHERE id = ?", [id])
    exec(ok ? "COMMIT" : "ROLLBACK")
  }

  func refs(kind: String) -> [String] {
    var out: [String] = []
    rows("SELECT ref FROM source WHERE kind = ?", [kind]) { out.append(self.text($0, 0) ?? "") }
    return out
  }

  func reset() {
    exec("BEGIN IMMEDIATE; DELETE FROM chunk; DELETE FROM source; COMMIT")
    try? FileManager.default.removeItem(atPath: vectorPath)
  }

  func counts() -> (meetings: Int, dictations: Int, chunks: Int, vectors: Int) {
    var kinds: [String: Int] = [:]
    rows("SELECT kind, count(*) FROM source GROUP BY kind") { kinds[self.text($0, 0) ?? ""] = self.int($0, 1) }
    var chunks = 0
    var vectors = 0
    rows("SELECT count(*), coalesce(sum(vec), 0) FROM chunk") {
      chunks = self.int($0, 0) ?? 0
      vectors = self.int($0, 1) ?? 0
    }
    return (kinds["meeting"] ?? 0, kinds["dictation"] ?? 0, chunks, vectors)
  }

  // MARK: - vectors

  private static func newIndex() throws -> USearchIndex {
    try USearchIndex.make(metric: .cos, dimensions: UInt32(dims), connectivity: 16, quantization: .f16)
  }

  /// Loaded into RAM for writing; a missing or unreadable file starts over and re-embeds everything.
  private func writableIndex() -> USearchIndex? {
    if FileManager.default.fileExists(atPath: vectorPath),
       let index = try? Self.newIndex(), (try? index.load(path: vectorPath)) != nil {
      return index
    }
    rows("UPDATE chunk SET vec = 0 WHERE vec != 0")
    return try? Self.newIndex()
  }

  /// Written beside and renamed over, so a reader's memory map never sees a half-written file.
  private func save(_ index: USearchIndex) -> Bool {
    let tmp = vectorPath + ".tmp"
    guard (try? index.save(path: tmp)) != nil else { return false }
    return rename(tmp, vectorPath) == 0
  }

  private func dropVectors(sourceId: Int) {
    var keys: [USearchKey] = []
    rows("SELECT id FROM chunk WHERE source_id = ? AND vec = 1", [sourceId]) { keys.append(USearchKey(self.int($0, 0) ?? 0)) }
    guard !keys.isEmpty, FileManager.default.fileExists(atPath: vectorPath), let index = writableIndex() else { return }
    for key in keys { _ = try? index.remove(key: key) }
    _ = save(index)
  }

  /// Embeds chunks that have no vector yet, `batch` per save. Returns how many were added.
  @discardableResult
  func embedPending(_ embed: Embed, batch: Int = 64, pause: TimeInterval = 0) -> Int {
    func todo() -> [(id: Int, text: String)] {
      var out: [(id: Int, text: String)] = []
      rows("SELECT id, text FROM chunk WHERE vec = 0 ORDER BY id") { out.append((self.int($0, 0) ?? 0, self.text($0, 1) ?? "")) }
      return out
    }
    guard !todo().isEmpty || !FileManager.default.fileExists(atPath: vectorPath), let index = writableIndex() else { return 0 }
    let pending = todo()
    var added = 0
    for start in stride(from: 0, to: pending.count, by: batch) {
      let slice = pending[start..<min(start + batch, pending.count)]
      try? index.reserve(UInt32(((try? index.count) ?? 0) + slice.count))
      var done: [Int] = []
      for c in slice {
        guard let v = embed(c.text, false), v.count == Self.dims else { continue }
        let key = USearchKey(c.id)
        if (try? index.contains(key: key)) == true { _ = try? index.remove(key: key) }
        if (try? index.add(key: key, vector: v)) != nil { done.append(c.id) }
      }
      guard !done.isEmpty else { continue }
      guard save(index) else { break }
      rows("UPDATE chunk SET vec = 1 WHERE id IN (\(done.map(String.init).joined(separator: ",")))")
      added += done.count
      if pause > 0 { Thread.sleep(forTimeInterval: pause) }
    }
    return added
  }

  /// Memory-mapped, reopened when the app saves a new file.
  private func readableIndex() -> USearchIndex? {
    let stamp = (try? FileManager.default.attributesOfItem(atPath: vectorPath))?[.modificationDate] as? Date
    guard let stamp, storedVectorVersion == Self.vectorVersion else { return nil }
    if stamp != viewStamp || view == nil {
      guard let index = try? Self.newIndex(), (try? index.view(path: vectorPath)) != nil else { return nil }
      view = index
      viewStamp = stamp
    }
    return view
  }

  static func normalized(_ v: [Float]) -> [Float] {
    let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    return norm > 0 ? v.map { $0 / norm } : v
  }

  // MARK: - retrieval

  private static let filterSQL = """
    AND (?2 IS NULL OR c.speaker LIKE '%' || ?2 || '%')
    AND (?3 IS NULL OR date(s.started_at) >= date(?3))
    AND (?4 IS NULL OR date(s.started_at) <= date(?4))
    AND (?5 IS NULL OR s.kind = ?5)
    """

  /// FTS5 bm25 top 40 and vector top 40, fused with reciprocal rank (k = 60).
  func search(_ query: String, filters: Filters = Filters(), limit: Int = 8, embed: Embed? = nil) -> [Hit] {
    let terms = Self.terms(query)
    var lexical: [Int] = []
    if let match = Self.ftsQuery(terms, trigram: trigram) {
      rows("""
        SELECT c.id FROM chunk_fts JOIN chunk c ON c.id = chunk_fts.rowid JOIN source s ON s.id = c.source_id
        WHERE chunk_fts MATCH ?1 \(Self.filterSQL) ORDER BY bm25(chunk_fts) LIMIT 40
        """, [match] + filters.args) { lexical.append(self.int($0, 0) ?? 0) }
    }
    var semantic: [Int] = []
    if let embed, let index = readableIndex(), let q = embed(query, true), q.count == Self.dims {
      if filters.isEmpty {
        semantic = ((try? index.search(vector: q, count: 40))?.0 ?? []).map { Int($0) }
      } else {
        // ponytail: the allowed set is one indexed scan per filtered query; fine to ~1M chunks.
        var allowed = Set<USearchKey>()
        rows("SELECT c.id FROM chunk c JOIN source s ON s.id = c.source_id WHERE 1 \(Self.filterSQL)",
             [nil] + filters.args) { allowed.insert(USearchKey(self.int($0, 0) ?? 0)) }
        semantic = ((try? index.filteredSearch(vector: q, count: 40) { allowed.contains($0) })?.0 ?? []).map { Int($0) }
      }
    }
    var score: [Int: Double] = [:]
    for list in [lexical, semantic] {
      for (rank, id) in list.enumerated() { score[id, default: 0] += 1 / Double(61 + rank) }
    }
    return Array(score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
      .lazy.compactMap { self.hit($0.key, terms: terms) }
      .prefix(limit))
  }

  private func hit(_ id: Int, terms: [String]) -> Hit? {
    var out: Hit?
    rows("""
      SELECT s.ref, s.kind, s.title, s.started_at, c.speaker, c.start_ms, c.end_ms, c.text,
        (SELECT p.text FROM chunk p WHERE p.source_id = c.source_id AND p.id < c.id ORDER BY p.id DESC LIMIT 1),
        (SELECT n.text FROM chunk n WHERE n.source_id = c.source_id AND n.id > c.id ORDER BY n.id LIMIT 1)
      FROM chunk c JOIN source s ON s.id = c.source_id WHERE c.id = ?
      """, [id]) { s in
      out = Hit(
        id: id, ref: self.text(s, 0) ?? "", kind: self.text(s, 1) ?? "", title: self.text(s, 2) ?? "",
        startedAt: self.text(s, 3), speaker: self.text(s, 4) ?? "", startMs: self.int(s, 5), endMs: self.int(s, 6),
        snippet: Self.snippet(prev: self.text(s, 8), text: self.text(s, 7) ?? "", next: self.text(s, 9), terms: terms))
    }
    return out
  }

  /// A `budget`-word window around the first query term, spilling into the chunks either side.
  static func snippet(prev: String?, text: String, next: String?, terms: [String], budget: Int = 120) -> String {
    let before = prev?.split(separator: " ") ?? []
    let body = text.split(separator: " ")
    let all = before + body + (next?.split(separator: " ") ?? [])
    let at = body.firstIndex { word in
      let w = word.lowercased()
      return terms.contains { $0.count >= 3 && w.contains($0) }
    } ?? body.count / 2
    let lo = max(0, min(before.count + at - budget / 2, all.count - budget))
    let hi = min(all.count, lo + budget)
    return (lo > 0 ? "... " : "") + all[lo..<hi].joined(separator: " ") + (hi < all.count ? " ..." : "")
  }

  static func terms(_ query: String) -> [String] {
    var out: [String] = []
    for w in query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    where !out.contains(w) { out.append(w) }
    return out
  }

  /// Trigram: each word as a substring plus its trigrams, so typos and ASR spellings still score.
  static func ftsQuery(_ terms: [String], trigram: Bool) -> String? {
    var parts: [String] = []
    func add(_ s: String) { if !parts.contains(s) { parts.append(s) } }
    for w in terms {
      if !trigram { add("\"\(w)\"*"); continue }
      guard w.count >= 3 else { continue }
      add("\"\(w)\"")
      let c = Array(w)
      if c.count >= 5 { for i in 0...(c.count - 3) { add("\"\(String(c[i..<(i + 3)]))\"") } }
    }
    return parts.isEmpty ? nil : parts.prefix(64).joined(separator: " OR ")
  }

  func sources(filters: Filters, limit: Int, ref: String? = nil) -> [Source] {
    var out: [Source] = []
    rows("""
      SELECT s.ref, s.kind, s.title, s.started_at, s.ended_at, group_concat(c.speaker, ', '), count(c.id)
      FROM source s JOIN chunk c ON c.source_id = s.id
      WHERE (?2 IS NULL OR s.id IN (SELECT source_id FROM chunk WHERE speaker LIKE '%' || ?2 || '%'))
        AND (?3 IS NULL OR date(s.started_at) >= date(?3))
        AND (?4 IS NULL OR date(s.started_at) <= date(?4))
        AND (?5 IS NULL OR s.kind = ?5) AND (?7 IS NULL OR s.ref = ?7)
      GROUP BY s.id ORDER BY s.started_at DESC LIMIT ?6
      """, [nil] + filters.args + [limit, ref]) { s in
      var speakers: [String] = []
      for name in (self.text(s, 5) ?? "").components(separatedBy: ", ") where !name.isEmpty && !speakers.contains(name) {
        speakers.append(name)
      }
      out.append(Source(ref: self.text(s, 0) ?? "", kind: self.text(s, 1) ?? "", title: self.text(s, 2) ?? "",
                        startedAt: self.text(s, 3), endedAt: self.text(s, 4), speakers: speakers, chunks: self.int(s, 6) ?? 0))
    }
    return out
  }

  /// Chunks of one source overlapping [fromMs, toMs]; `nextMs` is set when more follow.
  func span(ref: String, fromMs: Int?, toMs: Int?, maxChunks: Int = 20)
    -> (source: Source, chunks: [Chunk], nextMs: Int?)? {
    guard let source = sources(filters: Filters(), limit: 1, ref: ref).first else { return nil }
    var chunks: [Chunk] = []
    rows("""
      SELECT speaker, start_ms, end_ms, text FROM chunk
      WHERE source_id = (SELECT id FROM source WHERE ref = ?1)
        AND (?2 IS NULL OR end_ms IS NULL OR end_ms >= ?2) AND (?3 IS NULL OR start_ms IS NULL OR start_ms <= ?3)
      ORDER BY id LIMIT ?4
      """, [ref, fromMs, toMs, maxChunks + 1]) {
      chunks.append(Chunk(speaker: self.text($0, 0) ?? "", startMs: self.int($0, 1), endMs: self.int($0, 2), text: self.text($0, 3) ?? ""))
    }
    let next = chunks.count > maxChunks ? chunks.removeLast().startMs : nil
    return (source, chunks, next)
  }

  // MARK: - sqlite

  @discardableResult
  private func exec(_ sql: String) -> Bool {
    let rc = sqlite3_exec(db, sql, nil, nil, nil)
    if rc != SQLITE_OK { dlog("memory sql: \(String(cString: sqlite3_errmsg(db)))") }
    return rc == SQLITE_OK
  }

  @discardableResult
  private func rows(_ sql: String, _ args: [Any?] = [], _ each: (OpaquePointer) -> Void = { _ in }) -> Bool {
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
      dlog("memory sql: \(String(cString: sqlite3_errmsg(db)))")
      return false
    }
    defer { sqlite3_finalize(stmt) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, arg) in args.enumerated() {
      let n = Int32(i + 1)
      switch arg {
      case let v as Int: sqlite3_bind_int64(stmt, n, Int64(v))
      case let v as String: sqlite3_bind_text(stmt, n, v, -1, transient)
      default: sqlite3_bind_null(stmt, n)
      }
    }
    var rc = sqlite3_step(stmt)
    while rc == SQLITE_ROW {
      each(stmt)
      rc = sqlite3_step(stmt)
    }
    if rc != SQLITE_DONE { dlog("memory sql: \(String(cString: sqlite3_errmsg(db)))") }
    return rc == SQLITE_DONE
  }

  private func text(_ s: OpaquePointer, _ i: Int32) -> String? {
    sqlite3_column_text(s, i).map { String(cString: $0) }
  }

  private func int(_ s: OpaquePointer, _ i: Int32) -> Int? {
    sqlite3_column_type(s, i) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, i))
  }

  /// Meeting folders are named by local start time.
  static let folderFormat = posix("yyyy-MM-dd_HHmm-ss")
  private static let stampFormat = posix("yyyy-MM-dd HH:mm:ss")
  static func stamp(_ d: Date) -> String { stampFormat.string(from: d) }
  static func stampDate(_ s: String) -> Date? { stampFormat.date(from: s) }

  private static func posix(_ format: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = format
    return f
  }

  private static func sha256(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

/// Keeps the memory index in step with saved meetings and dictations, on a utility queue.
final class MemoryIndex: ObservableObject, @unchecked Sendable {
  static let shared = MemoryIndex()

  @Published private(set) var status = "Not built yet"
  @Published private(set) var busy = false

  private let queue = DispatchQueue(label: "ai.scribe.memory", qos: .background)
  private var store: MemoryStore?
  private var embed: MemoryStore.Embed?
  private var evict: DispatchWorkItem?

  private var enabled: Bool { UserDefaults.standard.object(forKey: "memoryIndex") as? Bool ?? true }

  func indexMeeting(_ dir: URL) {
    guard enabled, dir.deletingLastPathComponent().standardizedFileURL == MeetingRecorder.root.standardizedFileURL
    else { return }
    run { $0.indexMeeting(dir) }
  }

  func addDictation(_ text: String) {
    guard enabled else { return }
    let now = Date()
    run { $0.indexDictation(text, at: now) }
  }

  func remove(meeting dir: URL) { run(embedAfter: false) { $0.remove(ref: dir.lastPathComponent) } }

  func clearDictations() { run(embedAfter: false) { s in s.refs(kind: "dictation").forEach { s.remove(ref: $0) } } }

  /// Every saved meeting and the dictation history; meetings whose folder is gone are dropped.
  func backfill() {
    guard enabled else { return }
    run { s in
      let dirs = (try? FileManager.default.contentsOfDirectory(
        at: MeetingRecorder.root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
      for dir in dirs { s.indexMeeting(dir) }
      let names = Set(dirs.map(\.lastPathComponent))
      for ref in s.refs(kind: "meeting") where !names.contains(ref) { s.remove(ref: ref) }
      if UserDefaults.standard.object(forKey: "saveHistory") as? Bool ?? true {
        for text in (UserDefaults.standard.stringArray(forKey: "history") ?? []).reversed() {
          s.indexDictation(text, at: nil)
        }
      }
    }
  }

  func rebuild() {
    run(embedAfter: false) { $0.reset() }
    backfill()
  }

  func embedPending() {
    guard enabled else { return }
    run { _ in }
  }

  func releaseEmbedder() { queue.async { self.embed = nil } }

  func refresh() { run(embedAfter: false) { _ in } }

  private func run(embedAfter: Bool = true, _ work: @escaping (MemoryStore) -> Void) {
    queue.async {
      if self.store == nil { self.store = MemoryStore() }
      guard let store = self.store else { return }
      DispatchQueue.main.async { self.busy = true }
      work(store)
      if embedAfter, let embed = self.loadEmbedder() { store.embedPending(embed, batch: 16, pause: 1) }
      let c = store.counts()
      let text = "\(c.meetings) meetings · \(c.dictations) dictations · \(c.chunks) passages · \(c.vectors) with meaning vectors"
      DispatchQueue.main.async {
        self.status = text
        self.busy = false
      }
    }
  }

  /// Loaded on demand and dropped after a minute idle, so the app does not hold it between meetings.
  private func loadEmbedder() -> MemoryStore.Embed? {
    if embed == nil { embed = GraniteEmbedding.load() }
    evict?.cancel()
    let w = DispatchWorkItem { [weak self] in self?.embed = nil }
    evict = w
    queue.asyncAfter(deadline: .now() + 60, execute: w)
    return embed
  }
}
