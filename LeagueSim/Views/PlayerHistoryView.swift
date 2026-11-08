import SwiftUI

// 球员各赛季历史数据：从球队里点进一名球员，再点“查看各赛季数据”进来。
// 数据只读已跑完的赛季快照：球员 ID 不变，交易换队后下一赛季记在新队下，
// 旧赛季的队名、数据都不会被改写；所以这里按赛季号倒序列出该球员的每赛季数据。
// 常规赛和季后赛分开统计：顶部切常规赛/季后赛，行和生涯统计都跟着切。
struct PlayerHistoryView: View {
    var playerId: UUID
    var playerName: String
    @EnvironmentObject private var store: LeagueStore
    @State private var scope = "常规赛"
    @State private var foldHonors = true
    @State private var foldCareer = true
    @State private var foldSeasonRows = true

    private var rows: [(seasonNumber: Int, stat: PlayerSeasonStat)] {
        guard let league = store.currentLeague else { return [] }
        return league.seasons
            .sorted { $0.seasonNumber > $1.seasonNumber }
            .compactMap { season in
                let stats = scope == "季后赛" ? season.playoffPlayerStats : season.playerStats
                if let stat = stats.first(where: { $0.playerId == playerId }) {
                    return (season.seasonNumber, stat)
                }
                return nil
            }
    }

    private var honors: [PlayerHonor] {
        guard let league = store.currentLeague else { return [] }
        var rosterHonors: [PlayerHonor] = []
        for team in league.teams { for slot in team.roster where slot.player.id == playerId { rosterHonors = slot.player.honors } }
        // 从冻结的赛季快照里把奖项和总冠军补回来，
        // 已有同类型同赛季的去重，不重复。最佳阵容快照里只有名字和队名没有球员 ID，
        // 按名字 + 该赛季该球员的队名对上再补。
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
            let teamName = season.playerStats.first(where: { $0.playerId == playerId })?.teamName
            for (tier, entries) in [("最佳一阵", season.allNBAFirst), ("最佳二阵", season.allNBASecond), ("最佳三阵", season.allNBAThird)] {
                if let entry = entries.first(where: { $0.playerName == playerName && $0.teamName == teamName }) {
                    let key = "\(tier)-\(season.seasonNumber)"
                    if !seen.contains(key) { seen.insert(key); merged.append(PlayerHonor(type: tier, seasonNumber: season.seasonNumber, teamName: entry.teamName, detail: entry.position)) }
                }
            }
        }
        return merged.sorted { $0.seasonNumber > $1.seasonNumber }
    }

    // 同一类荣誉一起统计：按类型分组，每组给次数和赛季列表。
    private var groupedHonors: [(type: String, items: [PlayerHonor])] {
        var order: [String] = []
        var groups: [String: [PlayerHonor]] = [:]
        for h in honors {
            if groups[h.type] == nil { order.append(h.type) }
            groups[h.type, default: []].append(h)
        }
        let preferred = ["总冠军", "MVP", "FMVP", "最佳一阵", "最佳二阵", "最佳三阵"]
        return order.sorted {
            let a = preferred.firstIndex(of: $0) ?? 100
            let b = preferred.firstIndex(of: $1) ?? 100
            return a != b ? a < b : (groups[$0]?.count ?? 0) > (groups[$1]?.count ?? 0)
        }.map { ($0, (groups[$0] ?? []).sorted { $0.seasonNumber > $1.seasonNumber }) }
    }

    // 生涯统计：全部已跑完赛季的单场数据汇总，常规赛和季后赛分开算。
    // 各项都给历史总数：得分、篮板、助攻、抢断、盖帽、上场分钟、投篮/三分/罚球命中与出手。
    private var career: (games: Int, totalPoints: Int, ppg: Double, totalRebounds: Int, totalAssists: Int, totalSteals: Int, totalBlocks: Int, totalMinutes: Int, fgMade: Int, fgAtt: Int, threeMade: Int, threeAtt: Int, ftMade: Int, ftAtt: Int, triple: Int, double: Int, twenty: Int, thirty: Int, forty: Int, fifty: Int, sixty: Int, high: Int, highSeason: Int) {
        guard let league = store.currentLeague else { return (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0) }
        var games = 0; var totalPoints = 0; var high = 0; var highSeason = 0
        var twenty = 0; var thirty = 0; var forty = 0; var fifty = 0; var sixty = 0
        var totalRebounds = 0; var totalAssists = 0; var totalSteals = 0; var totalBlocks = 0; var totalMinutes = 0
        var fgMade = 0; var fgAtt = 0; var threeMade = 0; var threeAtt = 0; var ftMade = 0; var ftAtt = 0
        var allGames: [Game] = []
        for season in league.seasons {
            let seasonGames = scope == "季后赛" ? season.playoffGames : season.games
            allGames.append(contentsOf: seasonGames)
            for game in seasonGames {
                for stat in game.boxScore where stat.playerId == playerId {
                    games += 1; totalPoints += stat.points
                    totalRebounds += stat.rebounds; totalAssists += stat.assists
                    totalSteals += stat.steals; totalBlocks += stat.blocks; totalMinutes += stat.minutes
                    fgMade += stat.fieldGoalsMade; fgAtt += stat.fieldGoalsAttempted
                    threeMade += stat.threeMade; threeAtt += stat.threeAttempted
                    ftMade += stat.freeThrowsMade; ftAtt += stat.freeThrowsAttempted
                    if stat.points > high { high = stat.points; highSeason = season.seasonNumber }
                    if stat.points >= 20 { twenty += 1 }
                    if stat.points >= 30 { thirty += 1 }
                    if stat.points >= 40 { forty += 1 }
                    if stat.points >= 50 { fifty += 1 }
                    if stat.points >= 60 { sixty += 1 }
                }
            }
        }
        let counts = SimulationEngine.milestoneCounts(in: allGames)[playerId] ?? (triple: 0, double: 0)
        return (games, totalPoints, games > 0 ? Double(totalPoints) / Double(games) : 0, totalRebounds, totalAssists, totalSteals, totalBlocks, totalMinutes, fgMade, fgAtt, threeMade, threeAtt, ftMade, ftAtt, counts.triple, counts.double, twenty, thirty, forty, fifty, sixty, high, highSeason)
    }

    var body: some View {
        List {
            Section {
                Picker("常规赛 / 季后赛", selection: $scope) {
                    Text("常规赛").tag("常规赛"); Text("季后赛").tag("季后赛")
                }.pickerStyle(.segmented)
                Text("常规赛和季后赛分开统计：各赛季数据和生涯统计都按上面选的范围算。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button { foldHonors.toggle() } label: {
                    HStack { Text("个人荣誉"); Spacer(); Image(systemName: foldHonors ? "chevron.down" : "chevron.right") }
                }
                if foldHonors {
                    if honors.isEmpty {
                        Text("还没有荣誉：赛季结算后，MVP、得分王、最佳阵容、总冠军、FMVP 会记到这里。")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(groupedHonors.map { "\($0.type) \($0.items.count) 次" }.joined(separator: " · "))
                            .font(.caption)
                        ForEach(groupedHonors, id: \.type) { group in
                            Text("\(group.type) \(group.items.count) 次：\(group.items.map { "第 \($0.seasonNumber) 赛季·\($0.teamName)" }.joined(separator: "、"))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Button { foldCareer.toggle() } label: {
                    HStack { Text("生涯统计（\(scope)）"); Spacer(); Image(systemName: foldCareer ? "chevron.down" : "chevron.right") }
                }
                if foldCareer {
                    let c = career
                    if c.games == 0 {
                        Text("还没有\(scope)比赛数据。").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(String(format: "历史总得分 %d 分 · 场均 %.1f 分 · 总上场 %d 场", c.totalPoints, c.ppg, c.games)).font(.caption)
                        Text("总篮板 \(c.totalRebounds) 个 · 总助攻 \(c.totalAssists) 次 · 总抢断 \(c.totalSteals) 次 · 总盖帽 \(c.totalBlocks) 次 · 总上场 \(c.totalMinutes) 分钟").font(.caption)
                        Text("投篮 \(c.fgMade)/\(c.fgAtt) · 三分 \(c.threeMade)/\(c.threeAtt) · 罚球 \(c.ftMade)/\(c.ftAtt)").font(.caption)
                        Text("三双 \(c.triple) 次 · 两双 \(c.double) 次（三双不计入两双）").font(.caption)
                        Text("单场 20+ \(c.twenty) 次 · 30+ \(c.thirty) 次 · 40+ \(c.forty) 次 · 50+ \(c.fifty) 次 · 60+ \(c.sixty) 次").font(.caption)
                        if c.high > 0 {
                            Text("单场最高得分 \(c.high) 分（第 \(c.highSeason) 赛季）").font(.caption)
                        }
                    }
                }
            }
            if rows.isEmpty {
                Section {
                    Text("还没有 \(playerName) 的\(scope)赛季数据：去“模拟”跑完一赛季，这里就会按赛季列出来。")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button { foldSeasonRows.toggle() } label: {
                        HStack { Text("各赛季数据（\(scope)）"); Spacer(); Image(systemName: foldSeasonRows ? "chevron.down" : "chevron.right") }
                    }
                    if foldSeasonRows {
                        ForEach(rows, id: \.seasonNumber) { row in
                            let stat = row.stat
                            VStack(alignment: .leading) {
                                Text("第 \(row.seasonNumber) 赛季 · \(stat.teamName)")
                                    .font(.headline)
                                Text(String(format: "出场 %d 场 · %.1f 分 · %.1f 板 · %.1f 助 · %.1f 断 · %.1f 帽 · 累计 %d 分",
                                            stat.games, stat.pointsPerGame, stat.reboundsPerGame,
                                            stat.assistsPerGame, stat.stealsPerGame, stat.blocksPerGame, stat.totalPoints))
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
