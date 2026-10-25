import Foundation

// MARK: - 名单校验（只提醒，不硬拦；模拟资格另见 SimulationEngine）
// 12-15 人激活：少了/多了都提示；球衣号冲突、位置缺人也提示。
// 防通胀提醒：95+ 全联盟不超过 3 人、90+ 不超过 12 人、联盟平均建议 70-75，
// 超了只提醒，不禁止保存——用户自己说了算。
enum Validation {
    static func warnings(for team: Team) -> [String] {
        var list: [String] = []
        let active = team.activeRoster
        if active.count < 12 {
            list.append("激活名单只有 \(active.count) 人，建议 12-15 人")
        } else if active.count > 15 {
            list.append("激活名单有 \(active.count) 人，超过 15 人上限")
        }
        if team.starters.count != 5 {
            list.append("首发是 \(team.starters.count) 人，应为 5 人")
        }
        var seenNumbers: [Int: String] = [:]
        for slot in team.roster {
            if let other = seenNumbers[slot.player.jerseyNumber] {
                list.append("球衣号 \(slot.player.jerseyNumber) 冲突：\(other) 与 \(slot.player.name)")
            } else {
                seenNumbers[slot.player.jerseyNumber] = slot.player.name
            }
        }
        let positions = Set(active.map { $0.player.position })
        for position in Position.allCases where !positions.contains(position) {
            list.append("激活名单缺少 \(position.rawValue) 位置球员")
        }
        return list
    }

    static func leagueWarnings(for league: League) -> [String] {
        var list: [String] = []
        let players = league.teams.flatMap { $0.roster.map { $0.player } }
        let over95 = players.filter { Rating.overall(for: $0) >= 95 }.count
        let over90 = players.filter { Rating.overall(for: $0) >= 90 }.count
        if over95 > 3 { list.append("95+ 球员有 \(over95) 人，建议全联盟不超过 3 人") }
        if over90 > 12 { list.append("90+ 球员有 \(over90) 人，建议全联盟不超过 12 人") }
        if !players.isEmpty {
            let average = Double(players.map { Rating.overall(for: $0) }.reduce(0, +)) / Double(players.count)
            if average < 70 || average > 75 {
                list.append(String(format: "联盟平均总评 %.1f，建议控制在 70-75", average))
            }
        }
        return list
    }
}
