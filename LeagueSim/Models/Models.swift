import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 位置
// 五个位置固定不变。球员只能选其中之一，总评权重按位置走。
enum Position: String, Codable, CaseIterable, Identifiable {
    case pg = "PG"
    case sg = "SG"
    case sf = "SF"
    case pf = "PF"
    case c = "C"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .pg: return "控卫 PG"
        case .sg: return "分卫 SG"
        case .sf: return "小前 SF"
        case .pf: return "大前 PF"
        case .c: return "中锋 C"
        }
    }
}

// MARK: - 球员分项能力（12 项，全部 0-99）
// 注意：潜力 potential 只影响未来（P2 成长），不计入当前总评。
// 投射不是单独一项：三分与中投的均值，在 Rating.swift 里算。
struct Attributes: Codable, Equatable {
    var threePoint: Int = 70
    var midRange: Int = 70
    var finishing: Int = 70
    var freeThrow: Int = 70
    var playmaking: Int = 70
    var rebounding: Int = 70
    var perimeterDefense: Int = 70
    var rimProtection: Int = 70
    var athleticism: Int = 70
    var basketballIQ: Int = 70
    var durability: Int = 70
    var potential: Int = 70

    // 钳制到 0-99，防止滑杆/导入越界。
    func clamped() -> Attributes {
        var copy = self
        func clamp(_ v: Int) -> Int { min(99, max(0, v)) }
        copy.threePoint = clamp(threePoint)
        copy.midRange = clamp(midRange)
        copy.finishing = clamp(finishing)
        copy.freeThrow = clamp(freeThrow)
        copy.playmaking = clamp(playmaking)
        copy.rebounding = clamp(rebounding)
        copy.perimeterDefense = clamp(perimeterDefense)
        copy.rimProtection = clamp(rimProtection)
        copy.athleticism = clamp(athleticism)
        copy.basketballIQ = clamp(basketballIQ)
        copy.durability = clamp(durability)
        copy.potential = clamp(potential)
        return copy
    }
}

// MARK: - 名单状态
enum RosterStatus: String, Codable, CaseIterable, Identifiable {
    case starter = "首发"
    case bench = "替补"
    case inactive = "inactive"

    var id: String { rawValue }
    var isActive: Bool { self != .inactive }
}

// MARK: - 球员
// id 只在同一个存档内保证稳定：换存档后 id 不互通，跨存档不要拿 id 对人。
struct Player: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var jerseyNumber: Int
    var position: Position
    var age: Int
    var heightCm: Int
    var weightKg: Int
    var attributes: Attributes
    // 手动总评：nil = 按位置权重自动算；有值 = 用手动值（界面可开关）。
    var overallOverride: Int?

    init(id: UUID = UUID(), name: String, jerseyNumber: Int, position: Position,
         age: Int = 25, heightCm: Int = 195, weightKg: Int = 90,
         attributes: Attributes = Attributes(), overallOverride: Int? = nil) {
        self.id = id
        self.name = name
        self.jerseyNumber = jerseyNumber
        self.position = position
        self.age = age
        self.heightCm = heightCm
        self.weightKg = weightKg
        self.attributes = attributes.clamped()
        self.overallOverride = overallOverride.map { min(99, max(0, $0)) }
    }
}

// MARK: - 名单槽位：球员 + 在队内的角色与轮换顺序
struct RosterSlot: Codable, Equatable, Identifiable {
    // ForEach 直接用名单槽位时，SwiftUI 要一个稳定 id：就用球员 id，
    // 同一球员在同一队里只会出现一次，不会撞。
    var id: UUID { player.id }
    var player: Player
    var status: RosterStatus
    // 轮换顺序：数字越小越先上。首发 5 人默认 1-5，替补往后排。
    var rotationOrder: Int
}

// MARK: - 球队
// 固定 30 队：P0 不提供增删球队，只改球队资料与名单。
// 配色存十六进制字符串（如 "#E86018"），App 内颜色选择器可改；没有预置球队配色。
struct Team: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var abbreviation: String
    var division: String
    var arena: String
    var colorHex: String
    var roster: [RosterSlot]

    var activeRoster: [RosterSlot] {
        roster.filter { $0.status.isActive }.sorted { $0.rotationOrder < $1.rotationOrder }
    }
    var starters: [RosterSlot] {
        roster.filter { $0.status == .starter }.sorted { $0.rotationOrder < $1.rotationOrder }
    }
    var bench: [RosterSlot] {
        roster.filter { $0.status == .bench }.sorted { $0.rotationOrder < $1.rotationOrder }
    }
    var inactive: [RosterSlot] {
        roster.filter { $0.status == .inactive }.sorted { $0.rotationOrder < $1.rotationOrder }
    }

    func color() -> Color {
        Color(hex: colorHex) ?? Color.orange
    }
}

// MARK: - 联赛设置（每个存档独立一份）
struct LeagueSettings: Codable, Equatable {
    // 球队评分公式里的两项，P0 默认 70，界面可调。
    var chemistry: Int = 70
    var coachRating: Int = 70
    // 模拟参数：主场加分、随机波动幅度。
    var homeAdvantagePoints: Int = 2
    var randomVolatility: Int = 12
    // 上次用的种子，方便下次直接重跑。
    var lastSeed: Int64 = 1
}

// MARK: - 单场球员数据（box score）
struct PlayerGameStat: Codable, Equatable {
    var playerId: UUID
    var playerName: String
    var teamId: UUID
    var minutes: Int
    var points: Int
    var rebounds: Int
    var assists: Int
    var steals: Int
    var blocks: Int
}

// MARK: - 一场比赛
struct Game: Codable, Identifiable, Equatable {
    var id: UUID
    var homeTeamId: UUID
    var homeTeamName: String
    var awayTeamId: UUID
    var awayTeamName: String
    var homeScore: Int
    var awayScore: Int
    var boxScore: [PlayerGameStat]
}

// MARK: - 球队赛季统计
struct TeamSeasonStat: Codable, Identifiable, Equatable {
    var id: UUID { teamId }
    var teamId: UUID
    var teamName: String
    var division: String
    var wins: Int
    var losses: Int
    var pointsFor: Int
    var pointsAgainst: Int
    var pointDiff: Int { pointsFor - pointsAgainst }
}

// MARK: - 球员赛季统计（累计 + 场均都存，界面直接取，不用现算）
// 三元组 playerId + seasonId + teamId：赛季快照里存死，之后改名单不污染历史。
struct PlayerSeasonStat: Codable, Identifiable, Equatable {
    var id: UUID { playerId }
    var playerId: UUID
    var playerName: String
    var teamId: UUID
    var teamName: String
    var seasonId: UUID
    var games: Int
    var totalPoints: Int
    var totalRebounds: Int
    var totalAssists: Int
    var totalSteals: Int
    var totalBlocks: Int
    var totalMinutes: Int
    var pointsPerGame: Double { games > 0 ? Double(totalPoints) / Double(games) : 0 }
    var reboundsPerGame: Double { games > 0 ? Double(totalRebounds) / Double(games) : 0 }
    var assistsPerGame: Double { games > 0 ? Double(totalAssists) / Double(games) : 0 }
}

// MARK: - 赛季快照（赛季结束自动冻结）
// 快照是值类型深拷贝：球队名、球员名、比分、统计全部存进快照，
// 之后在球队/球员编辑器里怎么改，都不会改写已经跑完的赛季。
struct SeasonSnapshot: Codable, Identifiable, Equatable {
    var id: UUID
    var seasonNumber: Int
    var seed: Int64
    var settings: LeagueSettings
    var games: [Game]
    var teamStats: [TeamSeasonStat]
    var playerStats: [PlayerSeasonStat]
    var createdAt: Date
}

// MARK: - 联赛（一个存档 = 一个 League）
// 存档文件只含这一个对象；存档之间除了名字没有任何共享数据。
struct League: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var teams: [Team]
    var settings: LeagueSettings
    var seasons: [SeasonSnapshot]
    var nextSeasonNumber: Int
    var createdAt: Date
    var updatedAt: Date

    // 新存档：30 个空壳队，占位名“球队 1”到“球队 30”，不是真实球队，
// 用户在 App 内自己改队名、加球员。名单一开始是空的。
    static func emptyLeague(name: String) -> League {
        let teams: [Team] = (1...30).map { index in
            Team(id: UUID(), name: "球队 \(index)", abbreviation: "",
                 division: "", arena: "", colorHex: "#E86018", roster: [])
        }
        let now = Date()
        return League(id: UUID(), name: name, teams: teams, settings: LeagueSettings(),
                      seasons: [], nextSeasonNumber: 1, createdAt: now, updatedAt: now)
    }
}

// MARK: - 存档元数据（存档列表只读这个，不用把整个联赛读进内存）
struct ArchiveMeta: Codable, Equatable {
    var id: UUID
    var name: String
    var updatedAt: Date
    var teamCount: Int
    var seasonCount: Int
}

// MARK: - 颜色十六进制辅助
extension Color {
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt64(text, radix: 16) else { return nil }
        let red = Double((value >> 16) & 0xFF) / 255.0
        let green = Double((value >> 8) & 0xFF) / 255.0
        let blue = Double(value & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }

    func toHex() -> String? {
        // SwiftUI Color 转十六进制没有公开稳定 API：界面用 ColorPicker 时，
        // 用 UIColor 桥接取 RGB 分量（仅 iOS）。
        #if canImport(UIKit)
        let uiColor = UIColor(self)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(format: "#%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255))
        #else
        return nil
        #endif
    }
}
