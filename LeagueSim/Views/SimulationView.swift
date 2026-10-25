import SwiftUI

// 单赛季模拟：输种子 -> 跑单循环 -> 快照自动存进当前存档的历史。
// 可复现：同一名单 + 同一种子重跑，结果相同（新快照会追加一条，不覆盖旧快照）。
// 参赛资格：激活名单 >= 5 人的球队；不够 5 人的队列入“未参赛”，不进排名。
struct SimulationView: View {
    @EnvironmentObject private var store: LeagueStore
    @State private var seedText = "1"
    @State private var lastSnapshot: SeasonSnapshot?
    @State private var lastSkipped: [Team] = []
    @State private var showingResult = false

    private var league: League? { store.currentLeague }

    var body: some View {
        NavigationStack {
            Form {
                if let league {
                    Section("本赛季设置（存在当前存档里）") {
                        Stepper("化学反应：\(league.settings.chemistry)",
                                value: bindingSettings(\.chemistry), in: 0...99)
                        Stepper("教练评分：\(league.settings.coachRating)",
                                value: bindingSettings(\.coachRating), in: 0...99)
                        Stepper("主场加分：\(league.settings.homeAdvantagePoints)",
                                value: bindingSettings(\.homeAdvantagePoints), in: 0...10)
                        Stepper("随机波动：\(league.settings.randomVolatility)",
                                value: bindingSettings(\.randomVolatility), in: 0...30)
                        TextField("随机种子（整数）", text: $seedText).keyboardType(.numbersAndPunctuation)
                        Text("同一名单 + 同一种子 = 同一结果；改名单或改种子，结果就变。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("参赛情况") {
                        let participants = league.teams.filter { $0.activeRoster.count >= 5 }
                        let skipped = league.teams.filter { $0.activeRoster.count < 5 }
                        Text("可参赛球队：\(participants.count) 支（激活 >= 5 人）")
                        Text("未参赛球队：\(skipped.count) 支（激活 < 5 人，不进排名）")
                            .foregroundStyle(.secondary)
                        Text("赛程：单循环，每两队打 1 场，每队 \(max(0, participants.count - 1)) 场（P0 不是 82 场）。")
                            .font(.footnote).foregroundStyle(.secondary)
                        if !skipped.isEmpty {
                            Text("未参赛：" + skipped.map { $0.name }.joined(separator: "、"))
                                .font(.footnote).foregroundStyle(.orange)
                        }
                    }
                    Section {
                        Button("跑一赛季") {
                            let seed = Int64(seedText) ?? league.settings.lastSeed
                            let result = store.runSeason(seed: seed)
                            lastSnapshot = result.snapshot
                            lastSkipped = result.skipped
                            showingResult = true
                        }
                        .disabled(league.teams.filter { $0.activeRoster.count >= 5 }.count < 2)
                        Button("为所有空队填虚构测试名单") {
                            store.fillTestRostersForAllEmptyTeams()
                        }
                        Text("测试名单是虚构球员，不是真实球员；只填目前名单为空的队。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let snapshot = lastSnapshot {
                        Section("刚跑完：第 \(snapshot.seasonNumber) 赛季（种子 \(snapshot.seed)）") {
                            Text("比赛 \(snapshot.games.count) 场 · 参赛队 \(snapshot.teamStats.count) 支")
                            if !lastSkipped.isEmpty {
                                Text("未参赛：" + lastSkipped.map { $0.name }.joined(separator: "、"))
                                    .font(.footnote).foregroundStyle(.orange)
                            }
                            Button("去历史里看完整战绩") { showingResult = false }
                        }
                    }
                }
            }
            .navigationTitle("模拟")
            .onAppear {
                if let league { seedText = "\(league.settings.lastSeed)" }
            }
        }
    }

    private func bindingSettings(_ keyPath: WritableKeyPath<LeagueSettings, Int>) -> Binding<Int> {
        Binding(
            get: { store.currentLeague?.settings[keyPath: keyPath] ?? 70 },
            set: { newValue in
                store.updateCurrent { league in league.settings[keyPath: keyPath] = newValue }
            }
        )
    }
}

// 历史：赛季快照列表 -> 战绩（按胜场、净胜分排）-> 分区排名 -> 球员场均榜 -> 每场比赛比分与 box。
// 快照是冻结的：之后改球队球员名、能力，都不会改写这里。
struct HistoryView: View {
    @EnvironmentObject private var store: LeagueStore
    @State private var selectedSeasonId: UUID?
    @State private var searchText = ""

    private var seasons: [SeasonSnapshot] {
        store.currentLeague?.seasons.sorted { $0.seasonNumber > $1.seasonNumber } ?? []
    }

    private var selected: SeasonSnapshot? {
        seasons.first { $0.id == selectedSeasonId } ?? seasons.first
    }

    var body: some View {
        NavigationStack {
            List {
                if seasons.isEmpty {
                    Section {
                        Text("还没有跑完的赛季。去“模拟”跑一赛季，结束会自动存一条快照到这里。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section("赛季") {
                        Picker("赛季", selection: Binding(
                            get: { selected?.id ?? seasons.first?.id },
                            set: { selectedSeasonId = $0 }
                        )) {
                            ForEach(seasons) { season in
                                Text("第 \(season.seasonNumber) 赛季（种子 \(season.seed)）").tag(season.id as UUID?)
                            }
                        }
                    }
                    if let season = selected {
                        Section("球队战绩（胜场、净胜分排序）") {
                            ForEach(season.teamStats) { stat in
                                HStack {
                                    Text(stat.teamName)
                                    Spacer()
                                    Text("\(stat.wins) 胜 \(stat.losses) 负 · 净胜 \(stat.pointDiff)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section("分区排名") {
                            let divisions = Dictionary(grouping: season.teamStats) {
                                $0.division.isEmpty ? "未分组" : $0.division
                            }
                            ForEach(divisions.keys.sorted(), id: \.self) { division in
                                Text(division).font(.headline)
                                ForEach(divisions[division] ?? []) { stat in
                                    Text("\(stat.teamName)：\(stat.wins) 胜 \(stat.losses) 负")
                                        .font(.caption)
                                }
                            }
                        }
                        Section("球员场均榜（按场均得分）") {
                            TextField("搜球员或球队", text: $searchText)
                            let filtered = season.playerStats.filter { stat in
                                searchText.isEmpty
                                    || stat.playerName.localizedCaseInsensitiveContains(searchText)
                                    || stat.teamName.localizedCaseInsensitiveContains(searchText)
                            }
                            ForEach(filtered.prefix(50)) { stat in
                                VStack(alignment: .leading) {
                                    Text("\(stat.playerName)（\(stat.teamName)）")
                                    Text(String(format: "%.1f 分 · %.1f 板 · %.1f 助 · 出场 %d 场",
                                                stat.pointsPerGame, stat.reboundsPerGame,
                                                stat.assistsPerGame, stat.games))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Section("每场比赛（点进去看 box，里面有虚拟播报）") {
                            ForEach(season.games) { game in
                                NavigationLink {
                                    GameDetailView(game: game, seasonSeed: season.seed)
                                } label: {
                                    Text("\(game.homeTeamName) \(game.homeScore) : \(game.awayScore) \(game.awayTeamName)")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史快照")
        }
    }
}

private struct GameDetailView: View {
    var game: Game
    var seasonSeed: Int64

    var body: some View {
        List {
            Section("怎么看这场比赛") {
                NavigationLink {
                    BroadcastView(game: game, seasonSeed: seasonSeed)
                } label: {
                    Text("虚拟播报：从 0:0 一步步播到终场")
                }
                Text("不想等就进播报页点“快速跳过”，直接看终场分；播报只在看的时候现算，不存进存档，不占内存。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("\(game.homeTeamName) \(game.homeScore) : \(game.awayScore) \(game.awayTeamName)") {
                ForEach(game.boxScore.filter { $0.teamId == game.homeTeamId }, id: \.playerId) { stat in
                    boxRow(stat)
                }
            }
            Section("客队") {
                ForEach(game.boxScore.filter { $0.teamId == game.awayTeamId }, id: \.playerId) { stat in
                    boxRow(stat)
                }
            }
        }
        .navigationTitle("比赛详情")
    }

    private func boxRow(_ stat: PlayerGameStat) -> some View {
        VStack(alignment: .leading) {
            Text(stat.playerName)
            Text("\(stat.minutes) 分钟 · \(stat.points) 分 · \(stat.rebounds) 板 · \(stat.assists) 助 · \(stat.steals) 断 · \(stat.blocks) 帽")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
