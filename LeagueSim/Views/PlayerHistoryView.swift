import SwiftUI

// 球员各赛季历史数据：从球队里点进一名球员，再点“查看各赛季数据”进来。
// 数据只读已跑完的赛季快照：球员 ID 不变，交易换队后下一赛季记在新队下，
// 旧赛季的队名、数据都不会被改写；所以这里按赛季号倒序列出该球员的每赛季数据。
// 常规赛数据：季后赛不并进场均与投篮累计，季后赛看单场 box。
struct PlayerHistoryView: View {
    var playerId: UUID
    var playerName: String
    @EnvironmentObject private var store: LeagueStore
    @State private var foldHonors = true
    @State private var foldSeasonRows = true

    private var rows: [(seasonNumber: Int, stat: PlayerSeasonStat)] {
        guard let league = store.currentLeague else { return [] }
        return league.seasons
            .sorted { $0.seasonNumber > $1.seasonNumber }
            .compactMap { season in
                if let stat = season.playerStats.first(where: { $0.playerId == playerId }) {
                    return (season.seasonNumber, stat)
                }
                return nil
            }
    }

    private var honors: [PlayerHonor] {
        guard let league = store.currentLeague else { return [] }
        var rosterHonors: [PlayerHonor] = []
        for team in league.teams { for slot in team.roster where slot.player.id == playerId { rosterHonors = slot.player.honors } }
        // 15 版补回已丢荣誉：编辑球员曾把荣誉清零，但赛季快照是冻结的，从快照里把奖项和总冠军补回来，
        // 已有同类型同赛季的去重，不重复。最佳阵容快照里只有名字没有球员 ID，暂不从快照补。
        var seen = Set(rosterHonors.map { "\($0.type)-\($0.seasonNumber)" })
        var merged = rosterHonors
        for season in league.seasons {
            for award in season.awards where award.playerId == playerId {
                let key = "\(award.title)-\(season.seasonNumber)"
                if !seen.contains(key) { seen.insert(key); merged.append(PlayerHonor(type: award.title, seasonNumber: season.seasonNumber, teamName: award.teamName, detail: award.valueText)) }
            }
            if let cid = season.championTeamId, let cname = season.championTeamName,
               season.playerStats.contains(where: { $0.playerId == playerId && $0.teamId == cid }) {
                let key = "总冠军-\(season.seasonNumber)"
                if !seen.contains(key) { seen.insert(key); merged.append(PlayerHonor(type: "总冠军", seasonNumber: season.seasonNumber, teamName: cname, detail: "第 \(season.seasonNumber) 赛季")) }
            }
        }
        return merged.sorted { $0.seasonNumber > $1.seasonNumber }
    }

    var body: some View {
        List {
            Section {
                Button { foldHonors.toggle() } label: {
                    HStack { Text("个人荣誉"); Spacer(); Image(systemName: foldHonors ? "chevron.down" : "chevron.right") }
                }
                if foldHonors {
                let champs = honors.filter { $0.type == "总冠军" }
                let fmvps = honors.filter { $0.type == "FMVP" }
                Text("总冠军 \(champs.count) 次 · FMVP \(fmvps.count) 次")
                if champs.isEmpty && fmvps.isEmpty && honors.isEmpty {
                    Text("还没有荣誉：赛季结算后，MVP、得分王、最佳阵容、总冠军、FMVP 会记到这里。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(champs, id: \.id) { h in Text("总冠军：第 \(h.seasonNumber) 赛季 · \(h.teamName)").font(.caption) }
                ForEach(honors.filter { $0.type != "总冠军" }, id: \.id) { h in
                    Text("\(h.type)：第 \(h.seasonNumber) 赛季 · \(h.teamName) \(h.detail)").font(.caption)
                }
            }
            }
            if rows.isEmpty {
                Section {
                    Text("还没有 \(playerName) 的赛季数据：去“模拟”跑完一赛季，这里就会按赛季列出来。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button { foldSeasonRows.toggle() } label: {
                        HStack { Text("各赛季数据"); Spacer(); Image(systemName: foldSeasonRows ? "chevron.down" : "chevron.right") }
                    }
                    if foldSeasonRows {
                ForEach(rows, id: \.seasonNumber) { row in
                    let stat = row.stat
                    VStack(alignment: .leading) {
                        Text("第 \(row.seasonNumber) 赛季 · \(stat.teamName)")
                            .font(.headline)
                        Text(String(format: "出场 %d 场 · %.1f 分 · %.1f 板 · %.1f 助 · 累计 %d 分",
                                    stat.games, stat.pointsPerGame, stat.reboundsPerGame,
                                    stat.assistsPerGame, stat.totalPoints))
                            .font(.caption).foregroundStyle(.secondary)
                        if stat.totalFieldGoalsAttempted > 0 || stat.totalFreeThrowsAttempted > 0 {
                            Text(String(format: "投篮 %d/%d（%.1f%%）· 三分 %d/%d（%.1f%%）· 罚球 %d/%d（%.1f%%）",
                                        stat.totalFieldGoalsMade, stat.totalFieldGoalsAttempted,
                                        stat.fieldGoalPercentage * 100,
                                        stat.totalThreeMade, stat.totalThreeAttempted,
                                        stat.threePercentage * 100,
                                        stat.totalFreeThrowsMade, stat.totalFreeThrowsAttempted,
                                        stat.freeThrowPercentage * 100))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                    }
                }
            }
        }
        .navigationTitle("\(playerName) 各赛季数据")
    }
}
