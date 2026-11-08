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
        case .pg: return "控卫"
        case .sg: return "分卫"
        case .sf: return "小前"
        case .pf: return "大前"
        case .c: return "中锋"
        }
    }
}

// MARK: - 球员分项能力（12 项，全部 0-99）
// 潜力 potential 不计入当前总评。
// 投射不是单独一项：三分与中投的均值，在 Rating.swift 里算。
struct Attributes: Codable, Equatable {
    enum CodingKeys: String, CodingKey { case threePoint, midRange, finishing, freeThrow, playmaking, rebounding, perimeterDefense, rimProtection, athleticism, basketballIQ, durability, potential }
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

// MARK: - 球员个人荣誉
// 一条荣誉 = 一个奖项/一次夺冠/一次 FMVP，带赛季号和球队名，夺冠次数、FMVP 次数就是按类型计数。
struct PlayerHonor: Codable, Equatable, Identifiable {
    var id: UUID
    var type: String
    var seasonNumber: Int
    var teamName: String
    var detail: String

    init(id: UUID = UUID(), type: String, seasonNumber: Int, teamName: String, detail: String = "") {
        self.id = id; self.type = type; self.seasonNumber = seasonNumber; self.teamName = teamName; self.detail = detail
    }
}

// MARK: - 球员出手倾向
// 内线：内线出手占比高；外线：外线出手占比高；综合：正常比例。
enum PlayerTendency: String, Codable, CaseIterable, Identifiable {
    case inside = "内线"
    case outside = "外线"
    case balanced = "综合"
    var id: String { rawValue }
    var name: String { rawValue }
}

// MARK: - 球员
// id 只在同一个存档内保证稳定：换存档后 id 不互通，跨存档不要拿 id 对人。
struct Player: Codable, Identifiable, Equatable {
    enum CodingKeys: String, CodingKey { case id, name, jerseyNumber, position, age, attributes, overallOverride, honors, tendency, isRetired }
    var id: UUID
    var name: String
    // 球衣号用字符串存：“00”和“0”是两个不同的号。
    var jerseyNumber: String
    var position: Position
    var age: Int
    var tendency: PlayerTendency = .balanced
    // 退役：年龄>=37 且单赛季场均<5 分时赛季结束自动退役，数据不清除，状态改 inactive，不可交易。
    var isRetired: Bool = false
    var attributes: Attributes
    // 手动总评：nil = 按位置权重自动算；有值 = 用手动值（界面可开关）。
    var overallOverride: Int?
    // 个人荣誉：MVP、得分王、最佳阵容、总冠军、FMVP 等，赛季结束时记入，换队不丢（球员 ID 不变）。
    var honors: [PlayerHonor] = []

    init(id: UUID = UUID(), name: String, jerseyNumber: String, position: Position,
         age: Int = 25, attributes: Attributes = Attributes(), overallOverride: Int? = nil,
         honors: [PlayerHonor] = [], tendency: PlayerTendency = .balanced, isRetired: Bool = false) {
        self.id = id
        self.name = name
        self.jerseyNumber = jerseyNumber
        self.position = position
        self.age = age
        self.tendency = tendency
        self.isRetired = isRetired
        self.attributes = attributes.clamped()
        self.overallOverride = overallOverride.map { min(99, max(0, $0)) }
        self.honors = honors
    }
}

// MARK: - 名单槽位：球员 + 在队内的角色与轮换顺序
struct RosterSlot: Codable, Equatable, Identifiable {
    enum CodingKeys: String, CodingKey { case player, status, rotationOrder }
    // ForEach 直接用名单槽位时，SwiftUI 要一个稳定 id：就用球员 id，
    // 同一球员在同一队里只会出现一次，不会撞。
    var id: UUID { player.id }
    var player: Player
    var status: RosterStatus
    // 轮换顺序：数字越小越先上。首发 5 人默认 1-5，替补往后排。
    var rotationOrder: Int
}

// MARK: - 东西部
// 季后赛按东西部分组：东部前 8、西部前 8，各打 7 局 4 胜。
// 未定 = 用户没选、分区名也推不出来时，模拟时按联赛顺序前后对半分，
// 这样 30 队空壳队也能直接跑 82 场 + 季后赛，不用先把 30 队一个个填东西部。
enum Conference: String, Codable, CaseIterable, Identifiable {
    case east = "东部"
    case west = "西部"
    case unknown = "未定"

    var id: String { rawValue }
}

// MARK: - 球队
// 固定 30 队：不提供增删球队，只改球队资料与名单。
// 配色存十六进制字符串（如 "#E86018"），App 内颜色选择器可改；没有预置球队配色。
// conference 默认未定：老存档 JSON 里没有这个键时，
// 带默认值的 Codable 解码会用未定补上，不会把老存档读坏。
struct Team: Codable, Identifiable, Equatable {
    enum CodingKeys: String, CodingKey { case id, name, abbreviation, division, conference, arena, colorHex, roster }
    var id: UUID
    var name: String
    var abbreviation: String
    var division: String
    var conference: Conference = .unknown
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
    enum CodingKeys: String, CodingKey { case chemistry, coachRating, homeAdvantagePoints, randomVolatility, lastSeed, developmentMode, autoTradeEnabled }
    // 球员成长模式：“永久”= 不改能力；“真实”= 23-30 岁按潜力和赛季数据小幅上涨，35 岁起每赛季下滑。
    var developmentMode: String = "永久"
    // 自动交易开关：开启后赛季结束有概率自动换队，仍可手动交易。
    var autoTradeEnabled: Bool = false
    // 球队评分公式里的两项，默认 70，界面可调。
    var chemistry: Int = 70
    var coachRating: Int = 70
    var homeAdvantagePoints: Int = 2
    var randomVolatility: Int = 12
    // 上次用的种子，方便下次直接重跑。
    var lastSeed: Int64 = 1
}

// MARK: - 单场球员数据（box score）
// 投篮字段默认 0：老快照的 box 里没有这些键时解码补 0，
// 老比赛打开就是投篮 0 中 0，不会读坏；新比赛才有真实出手/命中。
// 约束（引擎保证）：总命中 = 两分命中 + 三分命中；得分 = 两分命中*2 + 三分命中*3 + 罚球命中。
struct PlayerGameStat: Codable, Equatable {
    enum CodingKeys: String, CodingKey { case playerId, playerName, teamId, minutes, points, rebounds, assists, steals, blocks, fieldGoalsMade, fieldGoalsAttempted, threeMade, threeAttempted, freeThrowsMade, freeThrowsAttempted, fouls }
    var playerId: UUID
    var playerName: String
    var teamId: UUID
    var minutes: Int
    var points: Int
    var rebounds: Int
    var assists: Int
    var steals: Int
    var blocks: Int
    var fieldGoalsMade: Int = 0
    var fieldGoalsAttempted: Int = 0
    var threeMade: Int = 0
    var threeAttempted: Int = 0
    var freeThrowsMade: Int = 0
    var freeThrowsAttempted: Int = 0
    var fouls: Int = 0
    var fouledOut: Bool { fouls >= 6 }

    var fieldGoalPercentage: Double {
        fieldGoalsAttempted > 0 ? Double(fieldGoalsMade) / Double(fieldGoalsAttempted) : 0
    }
    var threePercentage: Double {
        threeAttempted > 0 ? Double(threeMade) / Double(threeAttempted) : 0
    }
    var freeThrowPercentage: Double {
        freeThrowsAttempted > 0 ? Double(freeThrowsMade) / Double(freeThrowsAttempted) : 0
    }
}

// MARK: - 一场比赛
struct Game: Codable, Identifiable, Equatable {
    enum CodingKeys: String, CodingKey { case id, homeTeamId, homeTeamName, awayTeamId, awayTeamName, homeScore, awayScore, boxScore }
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
// 常规赛统计：季后赛胜负不计入这里，季后赛结果看 playoffSeries。
// conference 默认空：老快照里没有它时解码补空，历史页按分区照常看。
struct TeamSeasonStat: Codable, Identifiable, Equatable {
    enum CodingKeys: String, CodingKey { case teamId, teamName, division, conference, wins, losses, pointsFor, pointsAgainst }
    var id: UUID { teamId }
    var teamId: UUID
    var teamName: String
    var division: String
    var conference: String = ""
    var wins: Int
    var losses: Int
    var pointsFor: Int
    var pointsAgainst: Int
    var pointDiff: Int { pointsFor - pointsAgainst }
}

// MARK: - 球员赛季统计（累计 + 场均都存，界面直接取，不用现算）
// 三元组 playerId + seasonId + teamId：赛季快照里存死，之后改名单不污染历史。
struct PlayerSeasonStat: Codable, Identifiable, Equatable {
    enum CodingKeys: String, CodingKey { case playerId, playerName, teamId, teamName, seasonId, games, totalPoints, totalRebounds, totalAssists, totalSteals, totalBlocks, totalMinutes, totalFieldGoalsMade, totalFieldGoalsAttempted, totalThreeMade, totalThreeAttempted, totalFreeThrowsMade, totalFreeThrowsAttempted, totalFouls, position, tripleDoubles, doubleDoubles }
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
    // 赛季投篮累计（默认 0，老快照补 0）：只算常规赛，季后赛不并进来。
    var totalFieldGoalsMade: Int = 0
    var totalFieldGoalsAttempted: Int = 0
    var totalThreeMade: Int = 0
    var totalThreeAttempted: Int = 0
    var totalFreeThrowsMade: Int = 0
    var totalFreeThrowsAttempted: Int = 0
    var totalFouls: Int = 0
    // 单赛季三双/两双次数（默认 0，老快照补 0）：由 aggregatePlayerStats 从单场 box 现算，三双不计入两双。
    var tripleDoubles: Int = 0
    var doubleDoubles: Int = 0
    var position: String = ""
    var foulsPerGame: Double { games > 0 ? Double(totalFouls) / Double(games) : 0 }
    var stealsPerGame: Double { games > 0 ? Double(totalSteals) / Double(games) : 0 }
    var blocksPerGame: Double { games > 0 ? Double(totalBlocks) / Double(games) : 0 }
    var fieldGoalPercentage: Double {
        totalFieldGoalsAttempted > 0 ? Double(totalFieldGoalsMade) / Double(totalFieldGoalsAttempted) : 0
    }
    var threePercentage: Double {
        totalThreeAttempted > 0 ? Double(totalThreeMade) / Double(totalThreeAttempted) : 0
    }
    var freeThrowPercentage: Double {
        totalFreeThrowsAttempted > 0 ? Double(totalFreeThrowsMade) / Double(totalFreeThrowsAttempted) : 0
    }
    var pointsPerGame: Double { games > 0 ? Double(totalPoints) / Double(games) : 0 }
    var reboundsPerGame: Double { games > 0 ? Double(totalRebounds) / Double(games) : 0 }
    var assistsPerGame: Double { games > 0 ? Double(totalAssists) / Double(games) : 0 }
}

// MARK: - 季后赛系列赛（一轮 7 局 4 胜）
// 只存结果与比赛 ID，不重复存 box：单场数据只在 playoffGames 里存一份，
// 这样 82 场 + 最多约 105 场季后赛也不会把快照翻倍。
// higherSeed 是常规赛排名更好的那支（种子号更小），lowerSeed 是另一支；
// winnerTeamId / winnerTeamName 是这轮的胜者；gameIds 按比赛顺序排。
struct PlayoffSeries: Codable, Identifiable, Equatable {
    var id: UUID
    var round: String
    var conference: String
    var higherSeed: Int
    var higherSeedTeamId: UUID
    var higherSeedTeamName: String
    var lowerSeed: Int
    var lowerSeedTeamId: UUID
    var lowerSeedTeamName: String
    var higherWins: Int
    var lowerWins: Int
    var winnerTeamId: UUID
    var winnerTeamName: String
    var gameIds: [UUID]
}

// MARK: - 赛季奖项与历史之王
struct SeasonAward: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var playerId: UUID?
    var playerName: String
    var teamName: String
    var valueText: String
    init(id: UUID = UUID(), title: String, playerId: UUID? = nil, playerName: String, teamName: String, valueText: String = "") {
        self.id = id; self.title = title; self.playerId = playerId; self.playerName = playerName; self.teamName = teamName; self.valueText = valueText
    }
}
struct AllNBAEntry: Codable, Equatable {
    var playerName: String
    var teamName: String
    var position: String
    // 最佳阵容按东西部分两组：东部/西部，老快照没有这个键时补空。
    var conference: String = ""
}
struct SeasonLeader: Codable, Equatable {
    var category: String
    var playerName: String
    var teamName: String
    var perGame: Double
    var valueText: String
}

// MARK: - 进行中的赛季（对战表先生成，逐场打，可随时暂停看排名）
// playoffRound：0=常规赛进行中，1=季后赛首轮待确认，2=分区半决赛待确认，3=分区决赛待确认，4=总决赛待确认，5=已完成（此时已转快照，ongoing 会被清空）。
struct ScheduledGame: Codable, Equatable, Identifiable {
    var id: UUID
    var index: Int
    var homeTeamId: UUID
    var awayTeamId: UUID
    var playedGameId: UUID? = nil
}
struct OngoingSeason: Codable, Equatable, Identifiable {
    var id: UUID
    var seasonNumber: Int
    var seed: Int64
    var settings: LeagueSettings
    var schedule: [ScheduledGame]
    var playedGames: [Game] = []
    var playoffGames: [Game] = []
    var playoffSeries: [PlayoffSeries] = []
    var playoffRound: Int = 0
    var restCounts: [String: Int] = [:]
}

// MARK: - 赛季快照（赛季结束自动冻结）
// 快照是值类型深拷贝：球队名、球员名、比分、统计全部存进快照，
// 之后在球队/球员编辑器里怎么改，都不会改写已经跑完的赛季。
// games 永远是常规赛（老快照的 29 场、新快照的 82 场/队）；季后赛单独放
// playoffGames + playoffSeries，球员场均榜仍只算常规赛，季后赛看单场 box。
// playoff* 与 champion* 默认空：老快照解码时补空，
// 老赛季打开就是“无季后赛”，不会读坏、不用迁移。
struct SeasonSnapshot: Codable, Identifiable, Equatable {
    enum CodingKeys: String, CodingKey { case id, seasonNumber, seed, settings, games, teamStats, playerStats, playoffGames, playoffSeries, championTeamId, championTeamName, createdAt, awards, allNBAFirst, allNBASecond, allNBAThird, seasonLeaders, playoffPlayerStats }
    var id: UUID
    var seasonNumber: Int
    var seed: Int64
    var settings: LeagueSettings
    var games: [Game]
    var teamStats: [TeamSeasonStat]
    var playerStats: [PlayerSeasonStat]
    var playoffGames: [Game] = []
    var playoffSeries: [PlayoffSeries] = []
    var championTeamId: UUID? = nil
    var championTeamName: String? = nil
    var awards: [SeasonAward] = []
    var allNBAFirst: [AllNBAEntry] = []
    var allNBASecond: [AllNBAEntry] = []
    var allNBAThird: [AllNBAEntry] = []
    var seasonLeaders: [SeasonLeader] = []
    var playoffPlayerStats: [PlayerSeasonStat] = []
    var createdAt: Date
}

// MARK: - 交易记录（手动和自动交易都记，自动交易必有记录）
struct TradeRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var seasonNumber: Int
    var fromTeamName: String
    var toTeamName: String
    var outPlayerNames: [String]
    var inPlayerNames: [String]
    var isAuto: Bool
    var createdAt: Date
    init(id: UUID = UUID(), seasonNumber: Int, fromTeamName: String, toTeamName: String, outPlayerNames: [String], inPlayerNames: [String], isAuto: Bool, createdAt: Date = Date()) {
        self.id = id; self.seasonNumber = seasonNumber; self.fromTeamName = fromTeamName; self.toTeamName = toTeamName; self.outPlayerNames = outPlayerNames; self.inPlayerNames = inPlayerNames; self.isAuto = isAuto; self.createdAt = createdAt
    }
}

// MARK: - 联赛（一个存档 = 一个 League）
// 存档文件只含这一个对象；存档之间除了名字没有任何共享数据。
struct League: Codable, Identifiable, Equatable {
    enum CodingKeys: String, CodingKey { case id, name, teams, settings, seasons, nextSeasonNumber, createdAt, updatedAt, ongoingSeason, tradeHistory }
    var id: UUID
    var name: String
    var teams: [Team]
    var settings: LeagueSettings
    var seasons: [SeasonSnapshot]
    var nextSeasonNumber: Int
    var ongoingSeason: OngoingSeason? = nil
    var tradeHistory: [TradeRecord] = []
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

// MARK: - 容错解码
// 每个结构都用 decodeIfPresent + 默认值，缺哪个键补哪个，旧存档照常打开；
// 这些 init 都写在 extension 里，不会顶掉原有的成员初始化器。
extension Attributes {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threePoint = try c.decodeIfPresent(Int.self, forKey: .threePoint) ?? 70
        midRange = try c.decodeIfPresent(Int.self, forKey: .midRange) ?? 70
        finishing = try c.decodeIfPresent(Int.self, forKey: .finishing) ?? 70
        freeThrow = try c.decodeIfPresent(Int.self, forKey: .freeThrow) ?? 70
        playmaking = try c.decodeIfPresent(Int.self, forKey: .playmaking) ?? 70
        rebounding = try c.decodeIfPresent(Int.self, forKey: .rebounding) ?? 70
        perimeterDefense = try c.decodeIfPresent(Int.self, forKey: .perimeterDefense) ?? 70
        rimProtection = try c.decodeIfPresent(Int.self, forKey: .rimProtection) ?? 70
        athleticism = try c.decodeIfPresent(Int.self, forKey: .athleticism) ?? 70
        basketballIQ = try c.decodeIfPresent(Int.self, forKey: .basketballIQ) ?? 70
        durability = try c.decodeIfPresent(Int.self, forKey: .durability) ?? 70
        potential = try c.decodeIfPresent(Int.self, forKey: .potential) ?? 70
    }
}

extension Player {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        // 球衣号兼容读：17 版之前存的是数字（如 23），17 版之后存的是文字（如 "00"）。
        // 注意 decodeIfPresent 遇到类型不对会直接抛错、不会返回 nil，所以不能用它做类型分支，
        // 必须用 try? 逐个试：先试文字，失败再试数字，都失败才补 "0"。
        if let raw = try? c.decode(String.self, forKey: .jerseyNumber) {
            jerseyNumber = raw
        } else if let num = try? c.decode(Int.self, forKey: .jerseyNumber) {
            jerseyNumber = "\(num)"
        } else {
            jerseyNumber = "0"
        }
        if let raw = try c.decodeIfPresent(String.self, forKey: .position), let pos = Position(rawValue: raw) {
            position = pos
        } else {
            position = .pg
        }
        age = try c.decodeIfPresent(Int.self, forKey: .age) ?? 25
        if let raw = try c.decodeIfPresent(String.self, forKey: .tendency), let ten = PlayerTendency(rawValue: raw) {
            tendency = ten
        } else {
            tendency = .balanced
        }
        isRetired = try c.decodeIfPresent(Bool.self, forKey: .isRetired) ?? false
        attributes = try c.decodeIfPresent(Attributes.self, forKey: .attributes) ?? Attributes()
        overallOverride = try c.decodeIfPresent(Int.self, forKey: .overallOverride)
        honors = try c.decodeIfPresent([PlayerHonor].self, forKey: .honors) ?? []
    }
}

extension RosterSlot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        player = try c.decode(Player.self, forKey: .player)
        if let raw = try c.decodeIfPresent(String.self, forKey: .status), let st = RosterStatus(rawValue: raw) {
            status = st
        } else {
            status = .bench
        }
        rotationOrder = try c.decodeIfPresent(Int.self, forKey: .rotationOrder) ?? 1
    }
}

extension Team {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        abbreviation = try c.decodeIfPresent(String.self, forKey: .abbreviation) ?? ""
        division = try c.decodeIfPresent(String.self, forKey: .division) ?? ""
        if let raw = try c.decodeIfPresent(String.self, forKey: .conference), let conf = Conference(rawValue: raw) {
            conference = conf
        } else {
            conference = .unknown
        }
        arena = try c.decodeIfPresent(String.self, forKey: .arena) ?? ""
        colorHex = try c.decodeIfPresent(String.self, forKey: .colorHex) ?? "#E86018"
        roster = try c.decodeIfPresent([RosterSlot].self, forKey: .roster) ?? []
    }
}

extension LeagueSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chemistry = try c.decodeIfPresent(Int.self, forKey: .chemistry) ?? 70
        coachRating = try c.decodeIfPresent(Int.self, forKey: .coachRating) ?? 70
        homeAdvantagePoints = try c.decodeIfPresent(Int.self, forKey: .homeAdvantagePoints) ?? 2
        randomVolatility = try c.decodeIfPresent(Int.self, forKey: .randomVolatility) ?? 12
        lastSeed = try c.decodeIfPresent(Int64.self, forKey: .lastSeed) ?? 1
        developmentMode = try c.decodeIfPresent(String.self, forKey: .developmentMode) ?? "永久"
        autoTradeEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoTradeEnabled) ?? false
    }
}

extension PlayerGameStat {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playerId = try c.decodeIfPresent(UUID.self, forKey: .playerId) ?? UUID()
        playerName = try c.decodeIfPresent(String.self, forKey: .playerName) ?? ""
        teamId = try c.decodeIfPresent(UUID.self, forKey: .teamId) ?? UUID()
        minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 0
        points = try c.decodeIfPresent(Int.self, forKey: .points) ?? 0
        rebounds = try c.decodeIfPresent(Int.self, forKey: .rebounds) ?? 0
        assists = try c.decodeIfPresent(Int.self, forKey: .assists) ?? 0
        steals = try c.decodeIfPresent(Int.self, forKey: .steals) ?? 0
        blocks = try c.decodeIfPresent(Int.self, forKey: .blocks) ?? 0
        fieldGoalsMade = try c.decodeIfPresent(Int.self, forKey: .fieldGoalsMade) ?? 0
        fieldGoalsAttempted = try c.decodeIfPresent(Int.self, forKey: .fieldGoalsAttempted) ?? 0
        threeMade = try c.decodeIfPresent(Int.self, forKey: .threeMade) ?? 0
        threeAttempted = try c.decodeIfPresent(Int.self, forKey: .threeAttempted) ?? 0
        freeThrowsMade = try c.decodeIfPresent(Int.self, forKey: .freeThrowsMade) ?? 0
        freeThrowsAttempted = try c.decodeIfPresent(Int.self, forKey: .freeThrowsAttempted) ?? 0
        fouls = try c.decodeIfPresent(Int.self, forKey: .fouls) ?? 0
    }
}

extension Game {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        homeTeamId = try c.decodeIfPresent(UUID.self, forKey: .homeTeamId) ?? UUID()
        homeTeamName = try c.decodeIfPresent(String.self, forKey: .homeTeamName) ?? ""
        awayTeamId = try c.decodeIfPresent(UUID.self, forKey: .awayTeamId) ?? UUID()
        awayTeamName = try c.decodeIfPresent(String.self, forKey: .awayTeamName) ?? ""
        homeScore = try c.decodeIfPresent(Int.self, forKey: .homeScore) ?? 0
        awayScore = try c.decodeIfPresent(Int.self, forKey: .awayScore) ?? 0
        boxScore = try c.decodeIfPresent([PlayerGameStat].self, forKey: .boxScore) ?? []
    }
}

extension TeamSeasonStat {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        teamId = try c.decodeIfPresent(UUID.self, forKey: .teamId) ?? UUID()
        teamName = try c.decodeIfPresent(String.self, forKey: .teamName) ?? ""
        division = try c.decodeIfPresent(String.self, forKey: .division) ?? ""
        conference = try c.decodeIfPresent(String.self, forKey: .conference) ?? ""
        wins = try c.decodeIfPresent(Int.self, forKey: .wins) ?? 0
        losses = try c.decodeIfPresent(Int.self, forKey: .losses) ?? 0
        pointsFor = try c.decodeIfPresent(Int.self, forKey: .pointsFor) ?? 0
        pointsAgainst = try c.decodeIfPresent(Int.self, forKey: .pointsAgainst) ?? 0
    }
}

extension PlayerSeasonStat {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        playerId = try c.decodeIfPresent(UUID.self, forKey: .playerId) ?? UUID()
        playerName = try c.decodeIfPresent(String.self, forKey: .playerName) ?? ""
        teamId = try c.decodeIfPresent(UUID.self, forKey: .teamId) ?? UUID()
        teamName = try c.decodeIfPresent(String.self, forKey: .teamName) ?? ""
        seasonId = try c.decodeIfPresent(UUID.self, forKey: .seasonId) ?? UUID()
        games = try c.decodeIfPresent(Int.self, forKey: .games) ?? 0
        totalPoints = try c.decodeIfPresent(Int.self, forKey: .totalPoints) ?? 0
        totalRebounds = try c.decodeIfPresent(Int.self, forKey: .totalRebounds) ?? 0
        totalAssists = try c.decodeIfPresent(Int.self, forKey: .totalAssists) ?? 0
        totalSteals = try c.decodeIfPresent(Int.self, forKey: .totalSteals) ?? 0
        totalBlocks = try c.decodeIfPresent(Int.self, forKey: .totalBlocks) ?? 0
        totalMinutes = try c.decodeIfPresent(Int.self, forKey: .totalMinutes) ?? 0
        totalFieldGoalsMade = try c.decodeIfPresent(Int.self, forKey: .totalFieldGoalsMade) ?? 0
        totalFieldGoalsAttempted = try c.decodeIfPresent(Int.self, forKey: .totalFieldGoalsAttempted) ?? 0
        totalThreeMade = try c.decodeIfPresent(Int.self, forKey: .totalThreeMade) ?? 0
        totalThreeAttempted = try c.decodeIfPresent(Int.self, forKey: .totalThreeAttempted) ?? 0
        totalFreeThrowsMade = try c.decodeIfPresent(Int.self, forKey: .totalFreeThrowsMade) ?? 0
        totalFreeThrowsAttempted = try c.decodeIfPresent(Int.self, forKey: .totalFreeThrowsAttempted) ?? 0
        totalFouls = try c.decodeIfPresent(Int.self, forKey: .totalFouls) ?? 0
        position = try c.decodeIfPresent(String.self, forKey: .position) ?? ""
    }
}

extension SeasonSnapshot {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        seasonNumber = try c.decodeIfPresent(Int.self, forKey: .seasonNumber) ?? 1
        seed = try c.decodeIfPresent(Int64.self, forKey: .seed) ?? 1
        settings = try c.decodeIfPresent(LeagueSettings.self, forKey: .settings) ?? LeagueSettings()
        games = try c.decodeIfPresent([Game].self, forKey: .games) ?? []
        teamStats = try c.decodeIfPresent([TeamSeasonStat].self, forKey: .teamStats) ?? []
        playerStats = try c.decodeIfPresent([PlayerSeasonStat].self, forKey: .playerStats) ?? []
        playoffGames = try c.decodeIfPresent([Game].self, forKey: .playoffGames) ?? []
        playoffSeries = try c.decodeIfPresent([PlayoffSeries].self, forKey: .playoffSeries) ?? []
        championTeamId = try c.decodeIfPresent(UUID.self, forKey: .championTeamId)
        championTeamName = try c.decodeIfPresent(String.self, forKey: .championTeamName)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        awards = try c.decodeIfPresent([SeasonAward].self, forKey: .awards) ?? []
        allNBAFirst = try c.decodeIfPresent([AllNBAEntry].self, forKey: .allNBAFirst) ?? []
        allNBASecond = try c.decodeIfPresent([AllNBAEntry].self, forKey: .allNBASecond) ?? []
        allNBAThird = try c.decodeIfPresent([AllNBAEntry].self, forKey: .allNBAThird) ?? []
        seasonLeaders = try c.decodeIfPresent([SeasonLeader].self, forKey: .seasonLeaders) ?? []
        playoffPlayerStats = try c.decodeIfPresent([PlayerSeasonStat].self, forKey: .playoffPlayerStats) ?? []
    }
}

extension League {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        teams = try c.decodeIfPresent([Team].self, forKey: .teams) ?? []
        settings = try c.decodeIfPresent(LeagueSettings.self, forKey: .settings) ?? LeagueSettings()
        seasons = try c.decodeIfPresent([SeasonSnapshot].self, forKey: .seasons) ?? []
        nextSeasonNumber = try c.decodeIfPresent(Int.self, forKey: .nextSeasonNumber) ?? 1
        ongoingSeason = try c.decodeIfPresent(OngoingSeason.self, forKey: .ongoingSeason)
        tradeHistory = try c.decodeIfPresent([TradeRecord].self, forKey: .tradeHistory) ?? []
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}
