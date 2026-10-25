import Foundation

// MARK: - 多存档存储：全离线，不联网、不登录、不调任何网络接口
// 每个存档一个独立目录：Documents/LeagueSim/Archives/<存档ID>/league.json + meta.json
// 存档之间不共享任何数据；球员 ID 只在同存档内有意义。
// 切换存档必须先保存当前存档再加载另一个（LeagueStore.enterArchive 里保证顺序）。
// 本文件没有任何 URLSession / 网络请求 / 云同步代码——P0 飞行模式下全部可用。
enum ArchiveStore {
    private static var baseURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("LeagueSim/Archives", isDirectory: true)
    }

    private static var currentIdURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("LeagueSim/currentArchiveId.json", isDirectory: false)
    }

    private static func archiveDir(for id: UUID) -> URL {
        baseURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    // 关键修复：保存时日期用 iso8601 编码，读取时必须用同样的 iso8601 解码。
    // 之前读取用默认解码器（期望数字时间戳），读 iso8601 字符串会失败，
    // 导致存档文件其实已写进 Documents，但列表读回时全部跳过、显示 0 个，
    // 新建看起来像“弄不了”，切换存档也会读不到联赛。
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func meta(for league: League) -> ArchiveMeta {
        ArchiveMeta(id: league.id, name: league.name, updatedAt: league.updatedAt,
                    teamCount: league.teams.count, seasonCount: league.seasons.count)
    }

    // 存档列表：只读 meta.json，不用把每个联赛全文读进内存。
    static func listArchives() -> [ArchiveMeta] {
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: nil) else { return [] }
        var result: [ArchiveMeta] = []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json", isDirectory: false)
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? decoder().decode(ArchiveMeta.self, from: data) else { continue }
            result.append(meta)
        }
        return result.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func loadLeague(id: UUID) -> League? {
        let url = archiveDir(for: id).appendingPathComponent("league.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let league = try? decoder().decode(League.self, from: data) else { return nil }
        return league
    }

    // 保存：先写 league.json 再写 meta.json；失败不抛错，界面按返回值提示。
    @discardableResult
    static func saveLeague(_ league: League) -> Bool {
        let dir = archiveDir(for: league.id)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let leagueData = try encoder.encode(league)
            try leagueData.write(to: dir.appendingPathComponent("league.json", isDirectory: false),
                                 options: .atomic)
            let metaData = try encoder.encode(meta(for: league))
            try metaData.write(to: dir.appendingPathComponent("meta.json", isDirectory: false),
                               options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func deleteArchive(id: UUID) -> Bool {
        do {
            try FileManager.default.removeItem(at: archiveDir(for: id))
            if loadCurrentArchiveId() == id { clearCurrentArchiveId() }
            return true
        } catch {
            return false
        }
    }

    static func saveCurrentArchiveId(_ id: UUID) {
        do {
            try FileManager.default.createDirectory(
                at: currentIdURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(id)
            try data.write(to: currentIdURL, options: .atomic)
        } catch {
            // 当前存档标记写失败不影响联赛本身保存；下次打开回到存档列表重选即可。
        }
    }

    static func loadCurrentArchiveId() -> UUID? {
        guard let data = try? Data(contentsOf: currentIdURL),
              let id = try? JSONDecoder().decode(UUID.self, from: data) else { return nil }
        return id
    }

    private static func clearCurrentArchiveId() {
        try? FileManager.default.removeItem(at: currentIdURL)
    }
}
