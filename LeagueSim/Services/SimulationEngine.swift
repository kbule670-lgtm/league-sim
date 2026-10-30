import Foundation

// MARK: - 赛季模拟引擎（纯函数：输入联赛 + 种子，输出快照，不改原联赛）
// 常规赛：每队 82 场。30 队且东西部各 15 支时按 NBA 式场次分配：
// 跨区每对打 2 场（30 场），同区 12 个对手各打 4 场、另外 2 个同区对手只打 2 场
// （58 + 24 = 82）；参赛队不足 30 支或东西部分布不是 15/15 时，
// 用轮换法排满 82 场（每轮每队打 1 场，重复轮次、主客场轮换），同样每队恰好 82 场。
// 这不是真实 NBA 日历（没有日期、背靠背）：赛制规则按官方来的是场次、
// 东西部分组、前 8 名、7 局 4 胜对阵与主客场顺序。
// 季后赛：东西部各前 8 名，首轮 1-8、4-5、3-6、2-7，对阵固定不重排，
// 半决赛是首轮胜者 1-8 组对 4-5 组、2-7 组对 3-6 组；分区决赛、总决赛
// 全部 7 局 4 胜，主客场按 2-2-1-1-1（高种子主场打第 1、2、5、7 场）。
// 总决赛主场归常规赛战绩更好的一方（胜场、净胜分、再按东部先）。
// 东西部各不足 8 支时不打季后赛，只出常规赛，并在界面说明原因。
// 参赛资格：只有激活名单 >= 5 人的球队参赛；不够 5 人的队列入 skippedTeams，
// 不进排名，这样联赛没填完也能先跑一部分，不用等 30 队全部填满。
// 同一名单 + 同一种子：赛程按球队在联赛里的顺序生成，随机数只从种子取，
// 常规赛打完随机流接着打季后赛，所以重跑结果完全相同；改了任何一名
// 球员的能力或轮换，结果就可能变。
// 球员场均榜只算常规赛：季后赛 box 只存在 playoffGames 里单场看，
// 不并进 playerStats，否则场均会被季后赛拉偏；球队战绩同样只算常规赛。
enum SimulationEngine {
    struct Result {
        var snapshot: SeasonSnapshot
        var skippedTeams: [Team]
    }

    // 球队评分 = 前 8 人分钟加权总评 x0.65 + 替补深度 x0.15 + 化学反应 x0.1 + 教练 x0.1
    // 分钟权重：按轮换顺序递减，首发拿得多，替补拿得少。
    static func minutes(for slot: RosterSlot, in active: [RosterSlot]) -> Double {
        guard let index = active.firstIndex(where: { $0.player.id == slot.player.id }) else { return 0 }
        switch index {
        case 0: return 34
        case 1: return 32
        case 2: return 30
        case 3: return 28
        case 4: return 26
        case 5: return 22
        case 6: return 20
        case 7: return 18
        default: return 14
        }
    }

    static func teamRating(for team: Team, settings: LeagueSettings) -> Double {
        let active = team.activeRoster
        guard !active.isEmpty else { return 0 }
        let top8 = Array(active.prefix(8))
        let topMinutes = top8.map { minutes(for: $0, in: active) }
        let topTotal = zip(top8, topMinutes).map { Double(Rating.overall(for: $0.player)) * $1 }.reduce(0, +)
        let topSum = topMinutes.reduce(0, +)
        let topWeighted = topSum > 0 ? topTotal / topSum : 0
        let rest = Array(active.dropFirst(8))
        let benchDepth: Double
        if rest.isEmpty {
            benchDepth = topWeighted
        } else {
            benchDepth = Double(rest.map { Rating.overall(for: $0.player) }.reduce(0, +)) / Double(rest.count)
        }
        return topWeighted * 0.65 + benchDepth * 0.15
            + Double(settings.chemistry) * 0.1 + Double(settings.coachRating) * 0.1
    }

    // MARK: - 东西部判定（界面和引擎共用同一口径）
    // 顺序：先看球队自己选的东西部；再看分区名（大西洋/中部/东南 -> 东部，
    // 西北/太平洋/西南 -> 西部，分区栏里直接写东部/西部也认）；
    // 都推不出来时按联赛顺序前后对半分，30 队正好 15/15。
    static func conference(for team: Team, in participants: [Team]) -> Conference {
        if team.conference == .east { return .east }
        if team.conference == .west { return .west }
        let division = team.division.lowercased()
        if division.contains("atlantic") || division.contains("central") || division.contains("southeast")
            || division.contains("东部") || division.contains("大西洋") || division.contains("中部")
            || division.contains("东南") {
            return .east
        }
        if division.contains("northwest") || division.contains("pacific") || division.contains("southwest")
            || division.contains("西部") || division.contains("西北") || division.contains("太平洋")
            || division.contains("西南") {
            return .west
        }
        guard let index = participants.firstIndex(where: { $0.id == team.id }) else { return .east }
        return index < participants.count / 2 ? .east : .west
    }

    // MARK: - 常规赛赛程（返回主客队对，每队恰好 82 场）
    static func regularSeasonSchedule(participants: [Team]) -> [(home: Team, away: Team)] {
        guard participants.count >= 2 else { return [] }
        let east = participants.filter { conference(for: $0, in: participants) == .east }
        let west = participants.filter { conference(for: $0, in: participants) == .west }
        if participants.count == 30 && east.count == 15 && west.count == 15 {
            return nbaStyleSchedule(participants: participants, east: east, west: west)
        }
        return circleSchedule(participants: participants)
    }

    // 30 队 15/15：跨区 2 场 + 同区 12 对手 4 场 + 同区 2 对手 2 场 = 82。
    // 同区“只打 2 场”的 2 个对手取环形邻居：把同区 15 队排成一圈，
    // 每队的前后邻居就是那 2 个（邻居关系对称，不会出现 A 多打 B、B 不多打 A）。
    private static func nbaStyleSchedule(participants: [Team], east: [Team], west: [Team]) -> [(home: Team, away: Team)] {
        var schedule: [(home: Team, away: Team)] = []
        func addPair(_ first: Team, _ second: Team, games: Int) {
            for gameIndex in 0..<games {
                if gameIndex % 2 == 0 {
                    schedule.append((home: first, away: second))
                } else {
                    schedule.append((home: second, away: first))
                }
            }
        }
        // 基础：每对球队各打 2 场（主客场各 1 场），共 58 场/队。
        for i in participants.indices {
            for j in (i + 1)..<participants.count {
                addPair(participants[i], participants[j], games: 2)
            }
        }
        // 补强：同区内除环形邻居外的 12 个对手各再打 2 场，共 24 场/队。
        for group in [east, west] {
            for k in group.indices {
                let team = group[k]
                let previous = group[(k + group.count - 1) % group.count]
                let next = group[(k + 1) % group.count]
                for opponent in group where opponent.id != team.id
                    && opponent.id != previous.id && opponent.id != next.id {
                    // 只从序号小的一方加，避免同一对加两次。
                    if let teamIndex = group.firstIndex(where: { $0.id == team.id }),
                       let opponentIndex = group.firstIndex(where: { $0.id == opponent.id }),
                       teamIndex < opponentIndex {
                        addPair(team, opponent, games: 2)
                    }
                }
            }
        }
        return schedule
    }

    // 通用轮换法：一轮循环赛每队打 n-1 场；排满 q 轮再补 r 轮，q*(n-1)+r = 82。
    // 奇数队时每轮有一队轮空（补一个虚拟队），一轮仍是每队 n-1 场。
    private static func circleSchedule(participants: [Team]) -> [(home: Team, away: Team)] {
        let count = participants.count
        guard count >= 2 else { return [] }
        var teams: [Team?] = participants.map { Optional($0) }
        if count % 2 == 1 { teams.append(nil) }
        let roundsCount = teams.count - 1
        var rounds: [[(home: Team, away: Team)]] = []
        var rotating = teams
        for _ in 0..<roundsCount {
            var round: [(home: Team, away: Team)] = []
            for i in 0..<(rotating.count / 2) {
                let first = rotating[i]
                let second = rotating[rotating.count - 1 - i]
                if let home = first, let away = second {
                    round.append((home: home, away: away))
                } else if let home = second, let away = first {
                    round.append((home: home, away: away))
                }
            }
            rounds.append(round)
            // 固定第一队不动，其余顺时针转一位，下一轮配对就全变了。
            if rotating.count > 2 {
                let last = rotating.removeLast()
                rotating.insert(last, at: 1)
            }
        }
        let gamesPerCycle = count - 1
        let fullCycles = 82 / gamesPerCycle
        let remainderRounds = 82 % gamesPerCycle
        var schedule: [(home: Team, away: Team)] = []
        for cycle in 0..<fullCycles {
            for round in rounds {
                for pair in round {
                    schedule.append(cycle % 2 == 0 ? pair : (home: pair.away, away: pair.home))
                }
            }
        }
        if remainderRounds > 0 {
            if count % 2 == 1 {
                // 奇数队补轮：直接取前 r 轮会有人轮空、场次凑不齐 82。
                // 此时余数一定是偶数：每取一个偏移量，环上每队恰好多打 2 场
                // （一次作主队、一次作客队），r/2 个偏移量正好补满 r 场/队。
                for offset in 1...(remainderRounds / 2) {
                    for i in participants.indices {
                        let home = participants[i]
                        let away = participants[(i + offset) % count]
                        schedule.append(offset % 2 == 1 ? (home: home, away: away) : (home: away, away: home))
                    }
                }
            } else {
                for round in rounds.prefix(remainderRounds) {
                    for pair in round {
                        schedule.append(fullCycles % 2 == 0 ? pair : (home: pair.away, away: pair.home))
                    }
                }
            }
        }
        return schedule
    }

    // MARK: - 单场比赛（常规赛和季后赛共用，保证同一逻辑）
    private static func playGame(home: Team, away: Team, ratings: [UUID: Double],
                                 leagueAverage: Double, settings: LeagueSettings,
                                 rng: inout SeededRandom) -> Game {
        let homeRating = ratings[home.id] ?? 0
        let awayRating = ratings[away.id] ?? 0
        // 预期胜率 = 1 / (1 + exp(-(球队评分 - 联盟平均) / 8))，主场队先算，
        // 再用两队评分差微调：主场优势体现在比分上，胜负仍由随机数决定。
        let homeWinProb = 1.0 / (1.0 + exp(-(homeRating - leagueAverage) / 8.0))
        let awayWinProb = 1.0 / (1.0 + exp(-(awayRating - leagueAverage) / 8.0))
        let edge = (homeWinProb - awayWinProb) * 0.5
        let roll = rng.nextDouble()
        let homeWins = roll < (0.5 + edge)
        // 比分：基准 105 分，评分高于联盟平均加分，低于减分，再叠加随机波动与主场加分。
        var homeScore = score(for: homeRating, isHome: true, settings: settings,
                              leagueAverage: leagueAverage, rng: &rng)
        var awayScore = score(for: awayRating, isHome: false, settings: settings,
                              leagueAverage: leagueAverage, rng: &rng)
        if homeWins && homeScore <= awayScore { homeScore = awayScore + rng.nextInt(in: 1...8) }
        if !homeWins && awayScore <= homeScore { awayScore = homeScore + rng.nextInt(in: 1...8) }
        let box = boxScore(home: home, away: away,
                           homeScore: homeScore, awayScore: awayScore, rng: &rng)
        return Game(id: UUID(), homeTeamId: home.id, homeTeamName: home.name,
                    awayTeamId: away.id, awayTeamName: away.name,
                    homeScore: homeScore, awayScore: awayScore, boxScore: box)
    }

    // MARK: - 季后赛系列赛（7 局 4 胜，主客场 2-2-1-1-1）
    private static func playSeries(higher: Team, higherSeed: Int, lower: Team, lowerSeed: Int,
                                   round: String, conferenceName: String,
                                   ratings: [UUID: Double], leagueAverage: Double,
                                   settings: LeagueSettings, rng: inout SeededRandom)
    -> (series: PlayoffSeries, games: [Game], winner: Team) {
        var higherWins = 0
        var lowerWins = 0
        var games: [Game] = []
        var gameIndex = 0
        while higherWins < 4 && lowerWins < 4 && gameIndex < 7 {
            // 第 1、2、5、7 场高种子主场，第 3、4、6 场低种子主场。
            let higherIsHome = gameIndex == 0 || gameIndex == 1 || gameIndex == 4 || gameIndex == 6
            let home = higherIsHome ? higher : lower
            let away = higherIsHome ? lower : higher
            let game = playGame(home: home, away: away, ratings: ratings,
                                leagueAverage: leagueAverage, settings: settings, rng: &rng)
            games.append(game)
            if game.homeScore > game.awayScore {
                if higherIsHome { higherWins += 1 } else { lowerWins += 1 }
            } else {
                if higherIsHome { lowerWins += 1 } else { higherWins += 1 }
            }
            gameIndex += 1
        }
        let winner = higherWins == 4 ? higher : lower
        let series = PlayoffSeries(id: UUID(), round: round, conference: conferenceName,
                                   higherSeed: higherSeed, higherSeedTeamId: higher.id,
                                   higherSeedTeamName: higher.name, lowerSeed: lowerSeed,
                                   lowerSeedTeamId: lower.id, lowerSeedTeamName: lower.name,
                                   higherWins: higherWins, lowerWins: lowerWins,
                                   winnerTeamId: winner.id, winnerTeamName: winner.name,
                                   gameIds: games.map { $0.id })
        return (series, games, winner)
    }

    static func simulate(league: League, seed: Int64) -> Result {
        let settings = league.settings
        var rng = SeededRandom(seed: seed)
        let participants = league.teams.filter { $0.activeRoster.count >= 5 }
        let skipped = league.teams.filter { $0.activeRoster.count < 5 }
        let ratings = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, teamRating(for: $0, settings: settings)) })
        let leagueAverage = participants.isEmpty ? 0 : ratings.values.reduce(0, +) / Double(participants.count)
        let orderIndex = Dictionary(uniqueKeysWithValues: participants.enumerated().map { ($1.id, $0) })

        // 常规赛：按赛程打满 82 场/队，只算常规赛胜负与球员累计。
        var games: [Game] = []
        var teamWins: [UUID: Int] = [:]
        var teamLosses: [UUID: Int] = [:]
        var teamPointsFor: [UUID: Int] = [:]
        var teamPointsAgainst: [UUID: Int] = [:]
        var playerTotals: [UUID: PlayerSeasonStat] = [:]
        var playerTeamName: [UUID: String] = [:]
        var playerTeamId: [UUID: UUID] = [:]
        var playerName: [UUID: String] = [:]

        for pair in regularSeasonSchedule(participants: participants) {
            let game = playGame(home: pair.home, away: pair.away, ratings: ratings,
                                leagueAverage: leagueAverage, settings: settings, rng: &rng)
            games.append(game)
            let homeWins = game.homeScore > game.awayScore
            teamWins[game.homeTeamId, default: 0] += homeWins ? 1 : 0
            teamLosses[game.homeTeamId, default: 0] += homeWins ? 0 : 1
            teamWins[game.awayTeamId, default: 0] += homeWins ? 0 : 1
            teamLosses[game.awayTeamId, default: 0] += homeWins ? 1 : 0
            teamPointsFor[game.homeTeamId, default: 0] += game.homeScore
            teamPointsAgainst[game.homeTeamId, default: 0] += game.awayScore
            teamPointsFor[game.awayTeamId, default: 0] += game.awayScore
            teamPointsAgainst[game.awayTeamId, default: 0] += game.homeScore
            for stat in game.boxScore {
                playerName[stat.playerId] = stat.playerName
                playerTeamId[stat.playerId] = stat.teamId
                playerTeamName[stat.playerId] = stat.teamId == game.homeTeamId ? game.homeTeamName : game.awayTeamName
                var total = playerTotals[stat.playerId] ?? PlayerSeasonStat(
                    playerId: stat.playerId, playerName: stat.playerName,
                    teamId: stat.teamId, teamName: "",
                    seasonId: UUID(), games: 0, totalPoints: 0, totalRebounds: 0,
                    totalAssists: 0, totalSteals: 0, totalBlocks: 0, totalMinutes: 0)
                total.games += 1
                total.totalPoints += stat.points
                total.totalRebounds += stat.rebounds
                total.totalAssists += stat.assists
                total.totalSteals += stat.steals
                total.totalBlocks += stat.blocks
                total.totalMinutes += stat.minutes
                playerTotals[stat.playerId] = total
            }
        }

        let snapshotId = UUID()
        // 常规赛排名：胜场、净胜分、总得分，最后一项按联赛顺序，保证平局也不乱序。
        func sortedStandings(_ teams: [Team]) -> [Team] {
            teams.sorted {
                let leftWins = teamWins[$0.id] ?? 0
                let rightWins = teamWins[$1.id] ?? 0
                if leftWins != rightWins { return leftWins > rightWins }
                let leftDiff = (teamPointsFor[$0.id] ?? 0) - (teamPointsAgainst[$0.id] ?? 0)
                let rightDiff = (teamPointsFor[$1.id] ?? 0) - (teamPointsAgainst[$1.id] ?? 0)
                if leftDiff != rightDiff { return leftDiff > rightDiff }
                let leftFor = teamPointsFor[$0.id] ?? 0
                let rightFor = teamPointsFor[$1.id] ?? 0
                if leftFor != rightFor { return leftFor > rightFor }
                return (orderIndex[$0.id] ?? 0) < (orderIndex[$1.id] ?? 0)
            }
        }
        let teamStats = participants.map { team in
            TeamSeasonStat(teamId: team.id, teamName: team.name, division: team.division,
                           conference: conference(for: team, in: participants).rawValue,
                           wins: teamWins[team.id] ?? 0, losses: teamLosses[team.id] ?? 0,
                           pointsFor: teamPointsFor[team.id] ?? 0, pointsAgainst: teamPointsAgainst[team.id] ?? 0)
        }.sorted { ($0.wins, $0.pointDiff) > ($1.wins, $1.pointDiff) }
        let playerStats = playerTotals.values.map { stat -> PlayerSeasonStat in
            var copy = stat
            copy.seasonId = snapshotId
            copy.teamName = playerTeamName[stat.playerId] ?? ""
            copy.teamId = playerTeamId[stat.playerId] ?? stat.teamId
            copy.playerName = playerName[stat.playerId] ?? stat.playerName
            return copy
        }.sorted { $0.pointsPerGame > $1.pointsPerGame }

        // 季后赛：东西部各前 8 名；不足 8 支时直接不打，只留常规赛。
        var playoffGames: [Game] = []
        var playoffSeries: [PlayoffSeries] = []
        var championTeamId: UUID? = nil
        var championTeamName: String? = nil
        let eastStandings = sortedStandings(participants.filter { conference(for: $0, in: participants) == .east })
        let westStandings = sortedStandings(participants.filter { conference(for: $0, in: participants) == .west })
        if eastStandings.count >= 8 && westStandings.count >= 8 {
            func conferencePlayoffs(standings: [Team], conferenceName: String) -> Team {
                let seeds = Array(standings.prefix(8))
                func seedOf(_ team: Team) -> Int {
                    (seeds.firstIndex(where: { $0.id == team.id }) ?? 0) + 1
                }
                // 首轮对阵固定：1-8、4-5、3-6、2-7；半决赛 1-8 组对 4-5 组、2-7 组对 3-6 组。
                let firstRoundPairs = [(0, 7), (3, 4), (2, 5), (1, 6)]
                var roundWinners: [Team] = []
                for (higherIndex, lowerIndex) in firstRoundPairs {
                    let higher = seeds[higherIndex]
                    let lower = seeds[lowerIndex]
                    let result = playSeries(higher: higher, higherSeed: higherIndex + 1,
                                            lower: lower, lowerSeed: lowerIndex + 1,
                                            round: "首轮", conferenceName: conferenceName,
                                            ratings: ratings, leagueAverage: leagueAverage,
                                            settings: settings, rng: &rng)
                    playoffSeries.append(result.series)
                    playoffGames.append(contentsOf: result.games)
                    roundWinners.append(result.winner)
                }
                // 半决赛：首轮第 1 组胜者对第 2 组胜者，第 3 组胜者对第 4 组胜者；
                // 高种子 = 原常规赛种子号更小的一方。
                var semifinalWinners: [Team] = []
                for pair in [(0, 1), (2, 3)] {
                    let first = roundWinners[pair.0]
                    let second = roundWinners[pair.1]
                    let (higher, lower) = seedOf(first) <= seedOf(second) ? (first, second) : (second, first)
                    let result = playSeries(higher: higher, higherSeed: seedOf(higher),
                                            lower: lower, lowerSeed: seedOf(lower),
                                            round: "分区半决赛", conferenceName: conferenceName,
                                            ratings: ratings, leagueAverage: leagueAverage,
                                            settings: settings, rng: &rng)
                    playoffSeries.append(result.series)
                    playoffGames.append(contentsOf: result.games)
                    semifinalWinners.append(result.winner)
                }
                let first = semifinalWinners[0]
                let second = semifinalWinners[1]
                let (higher, lower) = seedOf(first) <= seedOf(second) ? (first, second) : (second, first)
                let finalResult = playSeries(higher: higher, higherSeed: seedOf(higher),
                                             lower: lower, lowerSeed: seedOf(lower),
                                             round: "分区决赛", conferenceName: conferenceName,
                                             ratings: ratings, leagueAverage: leagueAverage,
                                             settings: settings, rng: &rng)
                playoffSeries.append(finalResult.series)
                playoffGames.append(contentsOf: finalResult.games)
                return finalResult.winner
            }
            let eastChampion = conferencePlayoffs(standings: eastStandings, conferenceName: "东部")
            let westChampion = conferencePlayoffs(standings: westStandings, conferenceName: "西部")
            // 总决赛：常规赛战绩更好的一方拿主场（胜场、净胜分，东部先作最后平局）。
            let eastWins = teamWins[eastChampion.id] ?? 0
            let westWins = teamWins[westChampion.id] ?? 0
            let eastDiff = (teamPointsFor[eastChampion.id] ?? 0) - (teamPointsAgainst[eastChampion.id] ?? 0)
            let westDiff = (teamPointsFor[westChampion.id] ?? 0) - (teamPointsAgainst[westChampion.id] ?? 0)
            let eastIsHigher = eastWins > westWins || (eastWins == westWins && eastDiff >= westDiff)
            let finalsHigher = eastIsHigher ? eastChampion : westChampion
            let finalsLower = eastIsHigher ? westChampion : eastChampion
            let finalsHigherSeed = eastIsHigher
                ? (eastStandings.firstIndex(where: { $0.id == eastChampion.id }) ?? 0) + 1
                : (westStandings.firstIndex(where: { $0.id == westChampion.id }) ?? 0) + 1
            let finalsLowerSeed = eastIsHigher
                ? (westStandings.firstIndex(where: { $0.id == westChampion.id }) ?? 0) + 1
                : (eastStandings.firstIndex(where: { $0.id == eastChampion.id }) ?? 0) + 1
            let finals = playSeries(higher: finalsHigher, higherSeed: finalsHigherSeed,
                                    lower: finalsLower, lowerSeed: finalsLowerSeed,
                                    round: "总决赛", conferenceName: "总决赛",
                                    ratings: ratings, leagueAverage: leagueAverage,
                                    settings: settings, rng: &rng)
            playoffSeries.append(finals.series)
            playoffGames.append(contentsOf: finals.games)
            championTeamId = finals.winner.id
            championTeamName = finals.winner.name
        }

        let snapshot = SeasonSnapshot(id: snapshotId, seasonNumber: league.nextSeasonNumber,
                                      seed: seed, settings: settings, games: games,
                                      teamStats: teamStats, playerStats: playerStats,
                                      playoffGames: playoffGames, playoffSeries: playoffSeries,
                                      championTeamId: championTeamId, championTeamName: championTeamName,
                                      createdAt: Date())
        return Result(snapshot: snapshot, skippedTeams: skipped)
    }

    // 单场比分：基准 105 分，评分高于联盟平均加分，低于减分，再叠加随机波动与主场加分。
    private static func score(for rating: Double, isHome: Bool, settings: LeagueSettings,
                              leagueAverage: Double, rng: inout SeededRandom) -> Int {
        var points = 105.0 + (rating - leagueAverage) * 1.2
        if isHome { points += Double(settings.homeAdvantagePoints) }
        points += rng.nextCentered() * Double(settings.randomVolatility)
        return max(70, Int(points.rounded()))
    }

    // 单场 box：先按总评算使用率分得分，再按篮板/组织能力分篮板助攻，
    // 最后把四舍五入的余差补给本队得分最高的人，保证 box 得分和等于球队比分。
    private static func boxScore(home: Team, away: Team, homeScore: Int, awayScore: Int,
                                 rng: inout SeededRandom) -> [PlayerGameStat] {
        var result: [PlayerGameStat] = []
        for (team, teamScore) in [(home, homeScore), (away, awayScore)] {
            let active = team.activeRoster
            guard !active.isEmpty else { continue }
            let weights = active.map { pow(Double(Rating.overall(for: $0.player)), 1.5) }
            let weightSum = weights.reduce(0, +)
            var stats: [PlayerGameStat] = []
            for (index, slot) in active.enumerated() {
                let player = slot.player
                let share = weightSum > 0 ? weights[index] / weightSum : 1.0 / Double(active.count)
                let rawPoints = Double(teamScore) * share * (0.85 + rng.nextDouble() * 0.3)
                let minutes = Int(minutes(for: slot, in: active).rounded())
                // 篮板：篮板能力 + 位置系数（内线拿得多），助攻：组织能力主导。
                let positionReboundBonus: Double
                switch player.position {
                case .c: positionReboundBonus = 1.4
                case .pf: positionReboundBonus = 1.2
                case .sf: positionReboundBonus = 0.9
                case .sg: positionReboundBonus = 0.7
                case .pg: positionReboundBonus = 0.6
                }
                let rebounds = Int(((Double(player.attributes.rebounding) / 100.0) * 12.0 * positionReboundBonus
                    * (0.7 + rng.nextDouble() * 0.6)).rounded())
                let assists = Int(((Double(player.attributes.playmaking) / 100.0) * 9.0
                    * (0.7 + rng.nextDouble() * 0.6)).rounded())
                let steals = Int(((Double(player.attributes.perimeterDefense) / 100.0) * 2.0
                    * rng.nextDouble()).rounded())
                let blocks = Int(((Double(player.attributes.rimProtection) / 100.0) * 2.0
                    * rng.nextDouble()).rounded())
                stats.append(PlayerGameStat(playerId: player.id, playerName: player.name,
                                            teamId: team.id, minutes: minutes,
                                            points: Int(rawPoints.rounded()), rebounds: rebounds,
                                            assists: assists, steals: steals, blocks: blocks))
            }
            let diff = teamScore - stats.map { $0.points }.reduce(0, +)
            if let topIndex = stats.indices.max(by: { stats[$0].points < stats[$1].points }) {
                stats[topIndex].points += diff
                if stats[topIndex].points < 0 { stats[topIndex].points = 0 }
            }
            result.append(contentsOf: stats)
        }
        return result
    }
}
