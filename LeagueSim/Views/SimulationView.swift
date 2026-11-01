import SwiftUI
import Combine

// 单赛季模拟：输种子 -> 跑 82 场常规赛 + 东西部季后赛 -> 快照自动存进当前存档的历史。
// 可复现：同一名单 + 同一种子重跑，结果相同（新快照会追加一条，不覆盖旧快照）。
// 参赛资格：激活名单 >= 5 人的球队；不够 5 人的队列入“未参赛”，不进排名。
// 季后赛：东西部各前 8 名，7 局 4 胜；东西部各不足 8 支时只出常规赛。
// 进行中的赛季：先生成常规赛对战表，逐场打，可随时暂停看排名战绩；
// 自动模拟全部、模拟到该场、模拟该场、自动播放（可暂停）都在这里；
// 季后赛每轮打完停下来，等用户手动确认才打下一轮，总决赛打完自动结算奖项并存快照。
struct SimulationView: View {
    @EnvironmentObject private var store: LeagueStore
    @State private var seedText = "1"
    @State private var autoPlaying = false
    @State private var selectedScheduledId: UUID?
    @State private var showingGameAction = false
    @State private var showingDiscard = false
    @State private var showingStartError = false
    @State private var leaderCategory = "得分"
    @State private var leaderPlayoff = false
    @State private var foldSimStandings = true
    @State private var foldLeaderboard = false
    @State private var foldSchedule = true
    @State private var foldSimPlayoffSeries = true

    private var league: League? { store.currentLeague }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                QuizStyleHeader(title: "模拟", onExit: { store.backToArchiveList() })
                Form {
                if let league {
                    Section("本赛季设置（存在当前存档里）") {
                        Stepper("化学反应：\(league.settings.chemistry)", value: bindingSettings(\.chemistry), in: 0...99)
                        Stepper("教练评分：\(league.settings.coachRating)", value: bindingSettings(\.coachRating), in: 0...99)
                        Stepper("主场加分：\(league.settings.homeAdvantagePoints)", value: bindingSettings(\.homeAdvantagePoints), in: 0...10)
                        Stepper("随机波动：\(league.settings.randomVolatility)", value: bindingSettings(\.randomVolatility), in: 0...30)
                        TextField("随机种子（整数）", text: $seedText).keyboardType(.numbersAndPunctuation)
                        Text("同一名单 + 同一种子 + 同一打法顺序 = 同一结果；中途改名单、改种子，后面的比赛就变。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let ongoing = league.ongoingSeason {
                        ongoingSection(league: league, ongoing: ongoing)
                    } else {
                        Section("开始新赛季") {
                            let participants = league.teams.filter { $0.activeRoster.count >= 5 }
                            Text("可参赛球队：\(participants.count) 支（激活 >= 5 人）")
                            Text("点开始会先生成常规赛对战表（每队 82 场），存在存档里，之后逐场打，不会一次跑完。")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("生成常规赛对战表并开始赛季") {
                                let seed = Int64(seedText) ?? league.settings.lastSeed
                                if !store.startOngoingSeason(seed: seed) { showingStartError = true }
                            }
                            .disabled(participants.count < 2)
                            Button("为所有空队填虚构测试名单") { store.fillTestRostersForAllEmptyTeams() }
                        }
                    }
                }
            }

            .onAppear { if let league { seedText = "\(league.settings.lastSeed)" } }
            .onDisappear { autoPlaying = false }
            .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
                if autoPlaying { store.simulateNextRegularGame() }
            }
            .alert("开始不了", isPresented: $showingStartError) {
                Button("知道了") {}
            } message: { Text("可参赛球队不足 2 支（激活 >= 5 人），先把名单填满再开始。") }
            .alert("放弃进行中的赛季？", isPresented: $showingDiscard) {
                Button("取消", role: .cancel) {}
                Button("放弃", role: .destructive) { store.discardOngoingSeason() }
            } message: { Text("对战表和已打的比赛都会丢掉，已跑完的赛季快照不受影响。") }
            .alert("这场怎么打", isPresented: $showingGameAction) {
                Button("模拟到该场") { if let id = selectedScheduledId { store.simulateRegularGamesUpTo(scheduledId: id) } }
                Button("只模拟该场") { if let id = selectedScheduledId { store.simulateRegularGame(scheduledId: id) } }
                Button("取消", role: .cancel) {}
            } message: { Text("“模拟到该场”是把这场之前的未打场次连这场一起打完；“只模拟该场”是只打这一场，之前的场次留着以后打，排名按已打场次算。") }
            }
            .navigationBarHidden(true)
        }
    }

    private func ongoingSection(league: League, ongoing: OngoingSeason) -> some View {
        Group {
            let played = ongoing.schedule.filter { $0.playedGameId != nil }.count
            let total = ongoing.schedule.count
            let participants = league.teams.filter { $0.activeRoster.count >= 5 }
            let teamStats = SimulationEngine.aggregateTeamStats(games: ongoing.playedGames, participants: participants)
            let standings = SimulationEngine.sortedStandings(participants: participants, teamStats: teamStats)
            Section("进行中：第 \(ongoing.seasonNumber) 赛季（种子 \(ongoing.seed)）") {
                Text("常规赛已打 \(played) / \(total) 场，随时可以停下来看排名，点继续就能接着打。")
                if ongoing.playoffRound == 0 {
                    Text("常规赛进行中")
                } else if ongoing.playoffRound <= 4 {
                    Text("常规赛已打完，季后赛：\(SimulationEngine.playoffRoundName(ongoing.playoffRound))待确认")
                }
                if ongoing.playoffRound == 0 {
                    Button(autoPlaying ? "暂停自动播放" : "自动播放（每 0.3 秒打一场，可随时暂停）") { autoPlaying.toggle() }
                    Button("模拟下一场") { store.simulateNextRegularGame() }
                    Button("自动模拟全部常规赛") { autoPlaying = false; store.simulateAllRegular() }
                    Button("放弃进行中的赛季", role: .destructive) { showingDiscard = true }
                } else if ongoing.playoffRound <= 4 {
                    let eastCount = participants.filter { SimulationEngine.conference(for: $0, in: participants) == .east }.count
                    Text("季后赛参赛：东部前 8、西部前 8；东西部各不足 8 支时不打季后赛。当前东西部参赛队：\(eastCount) / \(participants.count - eastCount) 支。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("确认开始\(SimulationEngine.playoffRoundName(ongoing.playoffRound))") { store.playNextPlayoffRound() }
                    if ongoing.playoffRound < 4 {
                        Text("打完这轮会停下来，等你确认才打下一轮。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("总决赛打完自动结算本赛季奖项并存快照。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Button { foldSimStandings.toggle() } label: {
                    HStack { Text("排名（常规赛，按已打场次算）"); Spacer(); Image(systemName: foldSimStandings ? "chevron.down" : "chevron.right") }
                }
                if foldSimStandings {
                ForEach(["东部", "西部"], id: \.self) { conf in
                    Text(conf).font(.headline)
                    let confTeams = standings.filter { SimulationEngine.conference(for: $0, in: participants).rawValue == conf }
                    ForEach(Array(confTeams.enumerated()), id: \.element.id) { idx, team in
                        let stat = teamStats.first { $0.teamId == team.id }
                        Text("\(idx + 1). \(team.name)：\(stat?.wins ?? 0) 胜 \(stat?.losses ?? 0) 负 · 净胜 \(stat?.pointDiff ?? 0)")
                            .font(.caption)
                    }
                }
            }
            }
            Section {
                Button { foldLeaderboard.toggle() } label: {
                    HStack { Text("联盟数据榜前 30（实时更新）"); Spacer(); Image(systemName: foldLeaderboard ? "chevron.down" : "chevron.right") }
                }
                if foldLeaderboard {
                Picker("类别", selection: $leaderCategory) {
                    ForEach(["得分", "篮板", "助攻", "抢断", "盖帽", "投篮命中率", "三分命中率", "罚球命中率"], id: \.self) { Text($0) }
                }
                Picker("常规赛 / 季后赛", selection: $leaderPlayoff) {
                    Text("常规赛").tag(false); Text("季后赛").tag(true)
                }.pickerStyle(.segmented)
                let gamesForBoard = leaderPlayoff ? ongoing.playoffGames : ongoing.playedGames
                let boardStats = SimulationEngine.aggregatePlayerStats(games: gamesForBoard, seasonId: ongoing.id)
                let sortedBoard = sortedLeaderboard(boardStats, category: leaderCategory)
                ForEach(Array(sortedBoard.prefix(30).enumerated()), id: \.element.playerId) { idx, stat in
                    Text("\(idx + 1). \(stat.playerName)（\(stat.teamName)）：\(leaderboardValue(stat, category: leaderCategory))")
                        .font(.caption)
                }
                if sortedBoard.isEmpty { Text("还没打比赛，榜是空的。").font(.caption).foregroundStyle(.secondary) }
            }
            }
            if ongoing.playoffRound >= 1 {
                Section {
                Button { foldSimPlayoffSeries.toggle() } label: {
                    HStack { Text("季后赛系列赛"); Spacer(); Image(systemName: foldSimPlayoffSeries ? "chevron.down" : "chevron.right") }
                }
                if foldSimPlayoffSeries {
                    if ongoing.playoffSeries.isEmpty { Text("还没打季后赛。").font(.caption).foregroundStyle(.secondary) }
                    ForEach(ongoing.playoffSeries) { series in
                        Text("\(series.conference)\(series.round)：\(series.higherSeed) 号 \(series.higherSeedTeamName) \(series.higherWins):\(series.lowerWins) \(series.lowerSeed) 号 \(series.lowerSeedTeamName)")
                            .font(.caption)
                    }
                }
            }
            }
            if ongoing.playoffRound == 0 {
                Section {
                Button { foldSchedule.toggle() } label: {
                    HStack { Text("常规赛对战表（点未打的场选怎么打，已打的点进看 box）"); Spacer(); Image(systemName: foldSchedule ? "chevron.down" : "chevron.right") }
                }
                if foldSchedule {
                    ForEach(ongoing.schedule) { scheduled in
                        let home = league.teams.first { $0.id == scheduled.homeTeamId }
                        let away = league.teams.first { $0.id == scheduled.awayTeamId }
                        if let gameId = scheduled.playedGameId, let game = ongoing.playedGames.first(where: { $0.id == gameId }) {
                            NavigationLink {
                                GameDetailView(game: game, seasonSeed: ongoing.seed)
                            } label: {
                                Text("\(game.homeTeamName) \(game.homeScore) : \(game.awayScore) \(game.awayTeamName)（已打）")
                                    .font(.caption)
                            }
                        } else {
                            Button {
                                selectedScheduledId = scheduled.id; showingGameAction = true
                            } label: {
                                Text("\(home?.name ?? "") vs \(away?.name ?? "")（未打）")
                                    .font(.caption)
                            }
                        }
                    }
                }
            }
            }
        }
    }

    private func sortedLeaderboard(_ stats: [PlayerSeasonStat], category: String) -> [PlayerSeasonStat] {
        switch category {
        case "得分": return stats.sorted { $0.pointsPerGame > $1.pointsPerGame }
        case "篮板": return stats.sorted { $0.reboundsPerGame > $1.reboundsPerGame }
        case "助攻": return stats.sorted { $0.assistsPerGame > $1.assistsPerGame }
        case "抢断": return stats.sorted { $0.stealsPerGame > $1.stealsPerGame }
        case "盖帽": return stats.sorted { $0.blocksPerGame > $1.blocksPerGame }
        case "投篮命中率": return stats.filter { $0.totalFieldGoalsAttempted >= 10 }.sorted { $0.fieldGoalPercentage > $1.fieldGoalPercentage }
        case "三分命中率": return stats.filter { $0.totalThreeAttempted >= 10 }.sorted { $0.threePercentage > $1.threePercentage }
        case "罚球命中率": return stats.filter { $0.totalFreeThrowsAttempted >= 10 }.sorted { $0.freeThrowPercentage > $1.freeThrowPercentage }
        default: return stats
        }
    }

    private func leaderboardValue(_ stat: PlayerSeasonStat, category: String) -> String {
        switch category {
        case "得分": return String(format: "场均 %.1f 分", stat.pointsPerGame)
        case "篮板": return String(format: "场均 %.1f 板", stat.reboundsPerGame)
        case "助攻": return String(format: "场均 %.1f 助", stat.assistsPerGame)
        case "抢断": return String(format: "场均 %.1f 断", stat.stealsPerGame)
        case "盖帽": return String(format: "场均 %.1f 帽", stat.blocksPerGame)
        case "投篮命中率": return String(format: "%.1f%%", stat.fieldGoalPercentage * 100)
        case "三分命中率": return String(format: "%.1f%%", stat.threePercentage * 100)
        case "罚球命中率": return String(format: "%.1f%%", stat.freeThrowPercentage * 100)
        default: return ""
        }
    }

    private func bindingSettings(_ keyPath: WritableKeyPath<LeagueSettings, Int>) -> Binding<Int> {
        Binding(get: { store.currentLeague?.settings[keyPath: keyPath] ?? 70 }, set: { newValue in store.updateCurrent { league in league.settings[keyPath: keyPath] = newValue } })
    }
}

// 历史：赛季快照列表 -> 战绩（按胜场、净胜分排）-> 分区排名 -> 球员场均榜 -> 每场比赛比分与 box。
// 快照是冻结的：之后改球队球员名、能力，都不会改写这里。
struct HistoryView: View {
    @EnvironmentObject private var store: LeagueStore
    @State private var selectedSeasonId: UUID?
    @State private var searchText = ""
    @State private var foldStandings = true
    @State private var foldPlayerBoard = false
    @State private var foldRegularGames = false
    @State private var foldPlayoffGames = false
    @State private var foldEastWest = false
    @State private var foldHistoryPlayoffs = true
    @State private var foldAwards = true
    @State private var foldDivisions = false
    @State private var foldSeasonAwardsOverview = true
    @State private var foldHistoryLeaderboard = false
    @State private var historyLeaderCategory = "得分"

    private var seasons: [SeasonSnapshot] {
        store.currentLeague?.seasons.sorted { $0.seasonNumber > $1.seasonNumber } ?? []
    }

    private var selected: SeasonSnapshot? {
        seasons.first { $0.id == selectedSeasonId } ?? seasons.first
    }

    // 跨赛季累计：同一球员各赛季统计相加，队名取最近一个赛季的。
    private func historyAggregatedStats(seasons: [SeasonSnapshot]) -> [PlayerSeasonStat] {
        var totals: [UUID: PlayerSeasonStat] = [:]
        for season in seasons.sorted(by: { $0.seasonNumber < $1.seasonNumber }) {
            for stat in season.playerStats {
                var total = totals[stat.playerId] ?? PlayerSeasonStat(playerId: stat.playerId, playerName: stat.playerName, teamId: stat.teamId, teamName: stat.teamName, seasonId: season.id, games: 0, totalPoints: 0, totalRebounds: 0, totalAssists: 0, totalSteals: 0, totalBlocks: 0, totalMinutes: 0)
                total.games += stat.games; total.totalPoints += stat.totalPoints; total.totalRebounds += stat.totalRebounds; total.totalAssists += stat.totalAssists; total.totalSteals += stat.totalSteals; total.totalBlocks += stat.totalBlocks; total.totalMinutes += stat.totalMinutes
                total.totalFieldGoalsMade += stat.totalFieldGoalsMade; total.totalFieldGoalsAttempted += stat.totalFieldGoalsAttempted; total.totalThreeMade += stat.totalThreeMade; total.totalThreeAttempted += stat.totalThreeAttempted; total.totalFreeThrowsMade += stat.totalFreeThrowsMade; total.totalFreeThrowsAttempted += stat.totalFreeThrowsAttempted; total.totalFouls += stat.totalFouls
                total.teamName = stat.teamName; total.teamId = stat.teamId; total.playerName = stat.playerName
                totals[stat.playerId] = total
            }
        }
        return Array(totals.values)
    }

    private func historyRankedStats(stats: [PlayerSeasonStat], category: String) -> [PlayerSeasonStat] {
        switch category {
        case "得分": return stats.filter { $0.games >= 82 }.sorted { $0.pointsPerGame > $1.pointsPerGame }
        case "篮板": return stats.filter { $0.games >= 82 }.sorted { $0.reboundsPerGame > $1.reboundsPerGame }
        case "助攻": return stats.filter { $0.games >= 82 }.sorted { $0.assistsPerGame > $1.assistsPerGame }
        case "抢断": return stats.filter { $0.games >= 82 }.sorted { $0.stealsPerGame > $1.stealsPerGame }
        case "盖帽": return stats.filter { $0.games >= 82 }.sorted { $0.blocksPerGame > $1.blocksPerGame }
        case "投篮": return stats.filter { $0.totalFieldGoalsAttempted >= 300 }.sorted { $0.fieldGoalPercentage > $1.fieldGoalPercentage }
        case "三分": return stats.filter { $0.totalThreeAttempted >= 300 }.sorted { $0.threePercentage > $1.threePercentage }
        case "罚球": return stats.filter { $0.totalFreeThrowsAttempted >= 300 }.sorted { $0.freeThrowPercentage > $1.freeThrowPercentage }
        default: return []
        }
    }

    private func historyLeaderValueText(stat: PlayerSeasonStat, category: String) -> String {
        switch category {
        case "得分": return String(format: "场均 %.1f 分 · 出场 %d 场", stat.pointsPerGame, stat.games)
        case "篮板": return String(format: "场均 %.1f 板 · 出场 %d 场", stat.reboundsPerGame, stat.games)
        case "助攻": return String(format: "场均 %.1f 助 · 出场 %d 场", stat.assistsPerGame, stat.games)
        case "抢断": return String(format: "场均 %.1f 断 · 出场 %d 场", stat.stealsPerGame, stat.games)
        case "盖帽": return String(format: "场均 %.1f 帽 · 出场 %d 场", stat.blocksPerGame, stat.games)
        case "投篮": return String(format: "%.1f%% · %d/%d", stat.fieldGoalPercentage * 100, stat.totalFieldGoalsMade, stat.totalFieldGoalsAttempted)
        case "三分": return String(format: "%.1f%% · %d/%d", stat.threePercentage * 100, stat.totalThreeMade, stat.totalThreeAttempted)
        case "罚球": return String(format: "%.1f%% · %d/%d", stat.freeThrowPercentage * 100, stat.totalFreeThrowsMade, stat.totalFreeThrowsAttempted)
        default: return ""
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                QuizStyleHeader(title: "历史快照", onExit: { store.backToArchiveList() })
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
                    // 15 版新增：历年奖项一览 + 历史数据榜前 30，不用一个赛季一个赛季翻。
                    Section {
                        Button { foldSeasonAwardsOverview.toggle() } label: {
                            HStack { Text("历年奖项一览（每个赛季 MVP、得分王等）"); Spacer(); Image(systemName: foldSeasonAwardsOverview ? "chevron.down" : "chevron.right") }
                        }
                        if foldSeasonAwardsOverview {
                            if seasons.isEmpty {
                                Text("还没有跑完的赛季。").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(seasons) { season in
                                let mvp = season.awards.first { $0.title == "MVP" }
                                let fmvp = season.awards.first { $0.title == "FMVP" }
                                let score = season.awards.first { $0.title == "得分王" }
                                let rebound = season.awards.first { $0.title == "篮板王" }
                                let assist = season.awards.first { $0.title == "助攻王" }
                                let steal = season.seasonLeaders.first { $0.category == "抢断王" }
                                let block = season.seasonLeaders.first { $0.category == "盖帽王" }
                                VStack(alignment: .leading) {
                                    Text("第 \(season.seasonNumber) 赛季").font(.headline)
                                    Text("MVP：\(mvp?.playerName ?? "—")（\(mvp?.teamName ?? "—")）· FMVP：\(fmvp?.playerName ?? "—") · 总冠军：\(season.championTeamName ?? "—")").font(.caption).foregroundStyle(.secondary)
                                    Text("得分王：\(score?.playerName ?? "—") · 篮板王：\(rebound?.playerName ?? "—") · 助攻王：\(assist?.playerName ?? "—") · 抢断王：\(steal?.playerName ?? "—") · 盖帽王：\(block?.playerName ?? "—")").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Section {
                        Button { foldHistoryLeaderboard.toggle() } label: {
                            HStack { Text("历史数据榜前 30（跨赛季累计）"); Spacer(); Image(systemName: foldHistoryLeaderboard ? "chevron.down" : "chevron.right") }
                        }
                        if foldHistoryLeaderboard {
                            Picker("数据", selection: $historyLeaderCategory) {
                                ForEach(["得分", "篮板", "助攻", "抢断", "盖帽", "投篮", "三分", "罚球"], id: \.self) { Text($0) }
                            }
                            .pickerStyle(.segmented)
                            let aggregated = historyAggregatedStats(seasons: seasons)
                            let ranked = historyRankedStats(stats: aggregated, category: historyLeaderCategory)
                            if ranked.isEmpty {
                                Text("还没有跨赛季数据：跑完一赛季后这里才有。").font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(Array(ranked.prefix(30).enumerated()), id: \.element.playerId) { index, stat in
                                HStack {
                                    Text("\(index + 1). \(stat.playerName)（\(stat.teamName)）")
                                    Spacer()
                                    Text(historyLeaderValueText(stat: stat, category: historyLeaderCategory)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Text("计分榜按场均排（累计出场至少 82 场）；命中率榜按命中率排（累计出手至少 300 次），老快照投篮为 0 的不进命中率榜。").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let season = selected {
                        Section {
                Button { foldStandings.toggle() } label: {
                    HStack { Text("球队战绩（常规赛胜场、净胜分排序）"); Spacer(); Image(systemName: foldStandings ? "chevron.down" : "chevron.right") }
                }
                if foldStandings {
                            ForEach(season.teamStats.sorted { ($0.wins, $0.pointDiff, $0.pointsFor) > ($1.wins, $1.pointDiff, $1.pointsFor) }) { stat in
                                HStack {
                                    Text(stat.teamName)
                                    Spacer()
                                    Text("\(stat.wins) 胜 \(stat.losses) 负 · 净胜 \(stat.pointDiff)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
            }
                        if season.teamStats.contains(where: { !$0.conference.isEmpty }) {
                            Section {
                Button { foldEastWest.toggle() } label: {
                    HStack { Text("东西部排名（常规赛）"); Spacer(); Image(systemName: foldEastWest ? "chevron.down" : "chevron.right") }
                }
                if foldEastWest {
                                ForEach(["东部", "西部"], id: \.self) { conference in
                                    Text(conference).font(.headline)
                                    ForEach(season.teamStats.filter { $0.conference == conference }.sorted { ($0.wins, $0.pointDiff, $0.pointsFor) > ($1.wins, $1.pointDiff, $1.pointsFor) }) { stat in
                                        Text("\(stat.teamName)：\(stat.wins) 胜 \(stat.losses) 负")
                                            .font(.caption)
                                    }
                                }
                            }
            }
                        }
                        if let champion = season.championTeamName {
                            Section {
                Button { foldHistoryPlayoffs.toggle() } label: {
                    HStack { Text("季后赛（点进一轮看各场比赛）"); Spacer(); Image(systemName: foldHistoryPlayoffs ? "chevron.down" : "chevron.right") }
                }
                if foldHistoryPlayoffs {
                                Text("总冠军：\(champion)")
                                ForEach(season.playoffSeries) { series in
                                    NavigationLink {
                                        PlayoffSeriesDetailView(series: series, season: season)
                                    } label: {
                                        Text("\(series.conference)\(series.round)：\(series.higherSeed) 号种子 \(series.higherSeedTeamName) \(series.higherWins):\(series.lowerWins) \(series.lowerSeed) 号种子 \(series.lowerSeedTeamName)")
                                            .font(.caption)
                                    }
                                }
                                if season.playoffSeries.isEmpty {
                                    Text("季后赛数据为空").font(.caption).foregroundStyle(.secondary)
                                }
                            }
            }
                        } else {
                            Section("季后赛") {
                                Text("本赛季没有季后赛（老快照，或东西部各不足 8 支参赛队，只出了常规赛）。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !season.awards.isEmpty || !season.seasonLeaders.isEmpty {
                            Section {
                Button { foldAwards.toggle() } label: {
                    HStack { Text("赛季总结（奖项与历史之王）"); Spacer(); Image(systemName: foldAwards ? "chevron.down" : "chevron.right") }
                }
                if foldAwards {
                                if let champion = season.championTeamName { Text("总冠军：\(champion)") }
                                ForEach(season.awards) { award in
                                    Text("\(award.title)：\(award.playerName)（\(award.teamName)） \(award.valueText)")
                                        .font(.caption)
                                }
                                if !season.allNBAFirst.isEmpty {
                                    Text("最佳一阵：\(season.allNBAFirst.map { "\($0.position) \($0.playerName)" }.joined(separator: "、"))").font(.caption)
                                }
                                if !season.allNBASecond.isEmpty {
                                    Text("最佳二阵：\(season.allNBASecond.map { "\($0.position) \($0.playerName)" }.joined(separator: "、"))").font(.caption)
                                }
                                if !season.allNBAThird.isEmpty {
                                    Text("最佳三阵：\(season.allNBAThird.map { "\($0.position) \($0.playerName)" }.joined(separator: "、"))").font(.caption)
                                }
                                ForEach(season.seasonLeaders, id: \.category) { leader in
                                    Text("\(leader.category)：\(leader.playerName)（\(leader.teamName)） \(leader.valueText)")
                                        .font(.caption)
                                }
                                if season.awards.isEmpty && season.seasonLeaders.isEmpty {
                                    Text("老快照没有奖项数据，新赛季结算后这里才有。").font(.caption).foregroundStyle(.secondary)
                                }
                            }
            }
                        }
                        Section {
                Button { foldDivisions.toggle() } label: {
                    HStack { Text("分区排名"); Spacer(); Image(systemName: foldDivisions ? "chevron.down" : "chevron.right") }
                }
                if foldDivisions {
                            let divisions = Dictionary(grouping: season.teamStats) {
                                $0.division.isEmpty ? "未分组" : $0.division
                            }
                            ForEach(divisions.keys.sorted(), id: \.self) { division in
                                Text(division).font(.headline)
                                ForEach((divisions[division] ?? []).sorted { ($0.wins, $0.pointDiff, $0.pointsFor) > ($1.wins, $1.pointDiff, $1.pointsFor) }) { stat in
                                    Text("\(stat.teamName)：\(stat.wins) 胜 \(stat.losses) 负")
                                        .font(.caption)
                                }
                            }
                        }
            }
                        Section {
                Button { foldPlayerBoard.toggle() } label: {
                    HStack { Text("球员场均榜（按场均得分）"); Spacer(); Image(systemName: foldPlayerBoard ? "chevron.down" : "chevron.right") }
                }
                if foldPlayerBoard {
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
                        Section {
                Button { foldRegularGames.toggle() } label: {
                    HStack { Text("常规赛每场比赛（点进去看 box，里面有虚拟播报）"); Spacer(); Image(systemName: foldRegularGames ? "chevron.down" : "chevron.right") }
                }
                if foldRegularGames {
                            ForEach(season.games) { game in
                                NavigationLink {
                                    GameDetailView(game: game, seasonSeed: season.seed)
                                } label: {
                                    Text("\(game.homeTeamName) \(game.homeScore) : \(game.awayScore) \(game.awayTeamName)")
                                }
                            }
                        }
            }
                        if !season.playoffGames.isEmpty {
                            Section {
                Button { foldPlayoffGames.toggle() } label: {
                    HStack { Text("季后赛每场比赛（点进去看 box，里面有虚拟播报）"); Spacer(); Image(systemName: foldPlayoffGames ? "chevron.down" : "chevron.right") }
                }
                if foldPlayoffGames {
                                ForEach(season.playoffGames) { game in
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
                }
            }
            }
            .navigationBarHidden(true)
        }
    }
}

// 季后赛系列赛详情：点进一轮，先看这轮的各场比赛比分，再点进单场看 box 与播报。
// 以前系列赛那行只是纯文字点不动，各场比赛又混在 105 场的长列表里难找，
// 现在按系列赛分组，gameIds 的顺序就是比赛顺序。
private struct PlayoffSeriesDetailView: View {
    var series: PlayoffSeries
    var season: SeasonSnapshot

    private var games: [Game] {
        series.gameIds.compactMap { id in
            season.playoffGames.first { $0.id == id }
        }
    }

    var body: some View {
        List {
            Section("\(series.conference)\(series.round)") {
                Text("\(series.higherSeed) 号种子 \(series.higherSeedTeamName) \(series.higherWins):\(series.lowerWins) \(series.lowerSeed) 号种子 \(series.lowerSeedTeamName)")
                Text("胜者：\(series.winnerTeamName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("各场比赛（点进去看 box，里面有虚拟播报）") {
                if games.isEmpty {
                    Text("本轮没有单场数据").foregroundStyle(.secondary)
                } else {
                    ForEach(games) { game in
                        NavigationLink {
                            GameDetailView(game: game, seasonSeed: season.seed)
                        } label: {
                            Text("\(game.homeTeamName) \(game.homeScore) : \(game.awayScore) \(game.awayTeamName)")
                        }
                    }
                }
            }
        }
        .navigationTitle("\(series.conference)\(series.round)")
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
            Text("\(stat.minutes) 分钟 · \(stat.points) 分 · \(stat.rebounds) 板 · \(stat.assists) 助 · \(stat.steals) 断 · \(stat.blocks) 帽 · \(stat.fouls) 犯\(stat.fouledOut ? "（犯满离场）" : "")")
                .font(.caption).foregroundStyle(.secondary)
            if stat.fieldGoalsAttempted > 0 || stat.freeThrowsAttempted > 0 {
                Text("投篮 \(stat.fieldGoalsMade)/\(stat.fieldGoalsAttempted) · 三分 \(stat.threeMade)/\(stat.threeAttempted) · 罚球 \(stat.freeThrowsMade)/\(stat.freeThrowsAttempted)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
