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
        case 8: return 16
        case 9: return 12
        case 10: return 10
        default: return 8
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

    // 常规赛对战顺序随机打乱：对阵组合不变（每队仍是 82 场），只把比赛顺序用种子随机洗牌，
    // 同一名单 + 同一种子重跑，顺序相同。
    static func shuffledSchedule(_ pairs: [(home: Team, away: Team)], seed: Int64) -> [(home: Team, away: Team)] {
        var result = pairs
        var rng = SeededRandom(seed: seed &+ 987654321)
        if result.count > 1 {
            for index in stride(from: result.count - 1, through: 1, by: -1) {
                let other = rng.nextInt(in: 0...index)
                result.swapAt(index, other)
            }
        }
        return result
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
        let box = boxScore(home: home, homePlaying: home.activeRoster, away: away, awayPlaying: away.activeRoster,
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
                total.totalFieldGoalsMade += stat.fieldGoalsMade
                total.totalFieldGoalsAttempted += stat.fieldGoalsAttempted
                total.totalThreeMade += stat.threeMade
                total.totalThreeAttempted += stat.threeAttempted
                total.totalFreeThrowsMade += stat.freeThrowsMade
                total.totalFreeThrowsAttempted += stat.freeThrowsAttempted
                total.totalFouls += stat.fouls
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

        var playerStatsWithPosition = playerStats
        var posMap: [UUID: String] = [:]
        for team in league.teams { for slot in team.roster { posMap[slot.player.id] = slot.player.position.rawValue } }
        for i in playerStatsWithPosition.indices { playerStatsWithPosition[i].position = posMap[playerStatsWithPosition[i].playerId] ?? "" }
        let snapshot = SeasonSnapshot(id: snapshotId, seasonNumber: league.nextSeasonNumber,
                                      seed: seed, settings: settings, games: games,
                                      teamStats: teamStats, playerStats: playerStatsWithPosition,
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

    // 单场 box：先按出手权分得分，再按篮板/组织能力分篮板助攻，
    // 最后把四舍五入的余差补给本队得分最高的人，保证 box 得分和等于球队比分。
    // 出手权 = 总评^3 × 上场时间：总评越高、上场越久，出手越多。
        // 得分定下来后，再把每人的得分拆成两分/三分/罚球（见 decomposeShooting），
    // 保证 2*两分命中 + 3*三分命中 + 罚球命中 = 该球员得分，一分不差。
    // 出手权基础权重：手动调过就用手动值，没调过按总评相对本队上场阵容平均总评算
    // （总评越高出手越多，和之前自动算的口径一致）；上场时间和手感另外再乘。
    static func baseShotWeight(for slot: RosterSlot, teamAvgRating: Double) -> Double {
        if let manual = slot.shotWeight { return manual }
        let overall = Double(Rating.overall(for: slot.player))
        let relative = max(0.5, min(1.6, overall / max(1.0, teamAvgRating)))
        return pow(relative, 3.0) * 100.0
    }

    static func boxScore(home: Team, homePlaying: [RosterSlot], away: Team, awayPlaying: [RosterSlot], homeScore: Int, awayScore: Int,
                                 rng: inout SeededRandom) -> [PlayerGameStat] {
        var result: [PlayerGameStat] = []
        for (team, teamScore, active) in [(home, homeScore, homePlaying), (away, awayScore, awayPlaying)] {
            guard !active.isEmpty else { continue }
            // 每场手感因子：先按人抽，低分偶尔爆发、高分偶尔打铁，其余在 0.70-1.30 间波动。
            // 手感进出手权权重（不是事后乘得分），这样球队总分仍按权重归一，不会把总分打乱；
            // 同时手感也进投篮命中率（见 decomposeShooting 的 shootingForm），爆发=多得分+命中率高，打铁反之。
            // 上场时间每场微变 +-4 分钟，避免“每场都是固定时间、固定 9/21”这种一眼假的稳定。
            var forms: [Double] = []
            var variedMinutes: [Int] = []
            for slot in active {
                let overall = Double(Rating.overall(for: slot.player))
                let roll = rng.nextDouble()
                var form: Double
                if overall < 80 && roll < 0.08 {
                    form = 1.45
                } else if overall >= 85 && roll < 0.08 {
                    form = 0.60
                } else {
                    form = 0.70 + rng.nextDouble() * 0.60
                }
                forms.append(form)
                let baseMinutes = Int(minutes(for: slot, in: active).rounded())
                variedMinutes.append(max(5, min(40, baseMinutes + rng.nextInt(in: -4...4))))
            }
            // 出手权：按球员总评相对本队上场阵容平均总评算，高越多出手越多、低越少，
            // 不是只看绝对总评：同队里 90 分的比 70 分的多，弱队里的头牌也比强队里的角色球员多。
            let teamAvgRating = active.isEmpty ? 70.0 : Double(active.map { Rating.overall(for: $0.player) }.reduce(0, +)) / Double(active.count)
            let weights = active.enumerated().map { (index, slot) in
                baseShotWeight(for: slot, teamAvgRating: teamAvgRating)
                    * (Double(variedMinutes[index]) / 20.0)
                    * forms[index]
            }
            let weightSum = weights.reduce(0, +)
            var stats: [PlayerGameStat] = []
            var players: [Player] = []
            for (index, slot) in active.enumerated() {
                let player = slot.player
                players.append(player)
                let share = weightSum > 0 ? weights[index] / weightSum : 1.0 / Double(active.count)
                let rawPoints = Double(teamScore) * share * (0.75 + rng.nextDouble() * 0.50)
                let minutes = variedMinutes[index]
                // 篮板：篮板能力 + 位置系数（内线拿得多），助攻：组织能力主导。
                let positionReboundBonus: Double
                switch player.position {
                case .c: positionReboundBonus = 1.4
                case .pf: positionReboundBonus = 1.2
                case .sf: positionReboundBonus = 0.9
                case .sg: positionReboundBonus = 0.7
                case .pg: positionReboundBonus = 0.6
                }
                // 数值按排名拉开差距：不用绝对值线性算，用幂次——85 和 90 同一种数据
                // 要有明显差别，顶级数值和普通数值的差距也更大（篮板/助攻用 1.5 次方，
                // 抢断/盖帽用 2 次方）；抢断/盖帽数值 90 以上再乘 1.5，精英防守者场均断帽明显更多。
                let rebounds = Int((pow(Double(player.attributes.rebounding) / 100.0, 1.5) * 13.0 * positionReboundBonus
                    * (0.5 + rng.nextDouble() * 1.0)).rounded())
                let assists = Int((pow(Double(player.attributes.playmaking) / 100.0, 1.5) * 10.0
                    * (0.5 + rng.nextDouble() * 1.0)).rounded())
                let stealBoost = player.attributes.perimeterDefense >= 90 ? 1.5 : 1.0
                let blockBoost = player.attributes.rimProtection >= 90 ? 1.5 : 1.0
                let steals = Int((pow(Double(player.attributes.perimeterDefense) / 100.0, 2.0) * 3.0
                    * stealBoost * rng.nextDouble()).rounded())
                let blocks = Int((pow(Double(player.attributes.rimProtection) / 100.0, 2.0) * 3.0
                    * blockBoost * rng.nextDouble()).rounded())
                stats.append(PlayerGameStat(playerId: player.id, playerName: player.name,
                                            teamId: team.id, minutes: minutes,
                                            points: Int(rawPoints.rounded()), rebounds: rebounds,
                                            assists: assists, steals: steals, blocks: blocks))
            }
            for foulIndex in stats.indices {
                let foulPlayer = players[foulIndex]
                let foulMinutes = Double(stats[foulIndex].minutes)
                let defense = Double(foulPlayer.attributes.perimeterDefense + foulPlayer.attributes.rimProtection) / 2.0
                let expected = foulMinutes * 0.07 * (0.8 + defense / 200.0) * (0.7 + rng.nextDouble() * 0.6)
                var foulCount = Int(expected.rounded())
                if foulCount < 0 { foulCount = 0 }
                if foulCount > 6 { foulCount = 6 }
                stats[foulIndex].fouls = foulCount
            }
            let diff = teamScore - stats.map { $0.points }.reduce(0, +)
            if let topIndex = stats.indices.max(by: { stats[$0].points < stats[$1].points }) {
                stats[topIndex].points += diff
                if stats[topIndex].points < 0 { stats[topIndex].points = 0 }
            }
            // 得分已定型，再逐人拆投篮：出手/命中、三分、罚球全部从得分反推，
            // 拆完再进 result，保证单场 box 的得分和仍等于球队比分。
            for index in stats.indices {
                let shootingForm = max(0.75, min(1.25, 0.85 + (forms[index] - 1.0) * 0.5))
                let shooting = decomposeShooting(points: stats[index].points,
                                                 player: players[index], shootingForm: shootingForm, rng: &rng)
                stats[index].fieldGoalsMade = shooting.fieldGoalsMade
                stats[index].fieldGoalsAttempted = shooting.fieldGoalsAttempted
                stats[index].threeMade = shooting.threeMade
                stats[index].threeAttempted = shooting.threeAttempted
                stats[index].freeThrowsMade = shooting.freeThrowsMade
                stats[index].freeThrowsAttempted = shooting.freeThrowsAttempted
            }
            result.append(contentsOf: stats)
        }
        return result
    }


    // MARK: - 进行中赛季：轮休、单场、汇总、奖项（供 LeagueStore 逐场调用）
    // 轮休：常规赛每场上 10-11 人，首发一赛季轮休封顶 10 场、其他人封顶 20 场；
    // 封顶的球员必须上场，其余按“首发权重高、已轮休多的人更该上”加权抽；
    // 季后赛上 9 人，不计轮休。
    static func playingRoster(for team: Team, isPlayoff: Bool, restCounts: inout [String: Int], rng: inout SeededRandom) -> [RosterSlot] {
        let active = team.activeRoster
        if isPlayoff { return Array(active.prefix(9)) }
        if active.count <= 11 { return active }
        let playCount = rng.nextDouble() < 0.5 ? 10 : 11
        func cap(for slot: RosterSlot) -> Int { slot.status == .starter ? 10 : 20 }
        var mustPlay: [RosterSlot] = []
        var others: [RosterSlot] = []
        for slot in active {
            let rests = restCounts[slot.player.id.uuidString] ?? 0
            if rests >= cap(for: slot) { mustPlay.append(slot) } else { others.append(slot) }
        }
        var playing = mustPlay
        var remaining = playCount - playing.count
        if remaining < 0 { remaining = 0 }
        // 加权抽：首发权重 4、替补 1.5，再乘 (1 + 已轮休/5)，轮休多的人更优先上场，避免超封顶。
        var pool = others
        while remaining > 0 && !pool.isEmpty {
            let weights = pool.map { slot -> Double in
                let base = slot.status == .starter ? 4.0 : 1.5
                let rests = Double(restCounts[slot.player.id.uuidString] ?? 0)
                return base * (1.0 + rests / 5.0)
            }
            let total = weights.reduce(0, +)
            var roll = rng.nextDouble() * total
            var picked = 0
            for i in weights.indices {
                roll -= weights[i]
                if roll <= 0 { picked = i; break }
                picked = i
            }
            playing.append(pool.remove(at: picked))
            remaining -= 1
        }
        // 没上场的记一次轮休
        let playingIds = Set(playing.map { $0.player.id })
        for slot in active where !playingIds.contains(slot.player.id) {
            restCounts[slot.player.id.uuidString, default: 0] += 1
        }
        return playing.sorted { $0.rotationOrder < $1.rotationOrder }
    }

    static func playSingleGame(home: Team, away: Team, ratings: [UUID: Double], leagueAverage: Double, settings: LeagueSettings, isPlayoff: Bool, restCounts: inout [String: Int], rng: inout SeededRandom) -> Game {
        let homeRating = ratings[home.id] ?? 0
        let awayRating = ratings[away.id] ?? 0
        let homeWinProb = 1.0 / (1.0 + exp(-(homeRating - leagueAverage) / 8.0))
        let awayWinProb = 1.0 / (1.0 + exp(-(awayRating - leagueAverage) / 8.0))
        let edge = (homeWinProb - awayWinProb) * 0.5
        let roll = rng.nextDouble()
        let homeWins = roll < (0.5 + edge)
        var homeScore = score(for: homeRating, isHome: true, settings: settings, leagueAverage: leagueAverage, rng: &rng)
        var awayScore = score(for: awayRating, isHome: false, settings: settings, leagueAverage: leagueAverage, rng: &rng)
        if homeWins && homeScore <= awayScore { homeScore = awayScore + rng.nextInt(in: 1...8) }
        if !homeWins && awayScore <= homeScore { awayScore = homeScore + rng.nextInt(in: 1...8) }
        let homePlaying = playingRoster(for: home, isPlayoff: isPlayoff, restCounts: &restCounts, rng: &rng)
        let awayPlaying = playingRoster(for: away, isPlayoff: isPlayoff, restCounts: &restCounts, rng: &rng)
        let box = boxScore(home: home, homePlaying: homePlaying, away: away, awayPlaying: awayPlaying, homeScore: homeScore, awayScore: awayScore, rng: &rng)
        return Game(id: UUID(), homeTeamId: home.id, homeTeamName: home.name, awayTeamId: away.id, awayTeamName: away.name, homeScore: homeScore, awayScore: awayScore, boxScore: box)
    }

    static func playSeriesWithPlaying(higher: Team, higherSeed: Int, lower: Team, lowerSeed: Int, round: String, conferenceName: String, ratings: [UUID: Double], leagueAverage: Double, settings: LeagueSettings, rng: inout SeededRandom, restCounts: inout [String: Int]) -> (series: PlayoffSeries, games: [Game], winner: Team) {
        var higherWins = 0
        var lowerWins = 0
        var games: [Game] = []
        var gameIndex = 0
        while higherWins < 4 && lowerWins < 4 && gameIndex < 7 {
            let higherIsHome = gameIndex == 0 || gameIndex == 1 || gameIndex == 4 || gameIndex == 6
            let home = higherIsHome ? higher : lower
            let away = higherIsHome ? lower : higher
            let game = playSingleGame(home: home, away: away, ratings: ratings, leagueAverage: leagueAverage, settings: settings, isPlayoff: true, restCounts: &restCounts, rng: &rng)
            games.append(game)
            if game.homeScore > game.awayScore {
                if higherIsHome { higherWins += 1 } else { lowerWins += 1 }
            } else {
                if higherIsHome { lowerWins += 1 } else { higherWins += 1 }
            }
            gameIndex += 1
        }
        let winner = higherWins == 4 ? higher : lower
        let series = PlayoffSeries(id: UUID(), round: round, conference: conferenceName, higherSeed: higherSeed, higherSeedTeamId: higher.id, higherSeedTeamName: higher.name, lowerSeed: lowerSeed, lowerSeedTeamId: lower.id, lowerSeedTeamName: lower.name, higherWins: higherWins, lowerWins: lowerWins, winnerTeamId: winner.id, winnerTeamName: winner.name, gameIds: games.map { $0.id })
        return (series, games, winner)
    }

    static func aggregateTeamStats(games: [Game], participants: [Team]) -> [TeamSeasonStat] {
        var wins: [UUID: Int] = [:]; var losses: [UUID: Int] = [:]; var pf: [UUID: Int] = [:]; var pa: [UUID: Int] = [:]
        for game in games {
            let homeWins = game.homeScore > game.awayScore
            wins[game.homeTeamId, default: 0] += homeWins ? 1 : 0
            losses[game.homeTeamId, default: 0] += homeWins ? 0 : 1
            wins[game.awayTeamId, default: 0] += homeWins ? 0 : 1
            losses[game.awayTeamId, default: 0] += homeWins ? 1 : 0
            pf[game.homeTeamId, default: 0] += game.homeScore; pa[game.homeTeamId, default: 0] += game.awayScore
            pf[game.awayTeamId, default: 0] += game.awayScore; pa[game.awayTeamId, default: 0] += game.homeScore
        }
        return participants.map { team in
            TeamSeasonStat(teamId: team.id, teamName: team.name, division: team.division, conference: conference(for: team, in: participants).rawValue, wins: wins[team.id] ?? 0, losses: losses[team.id] ?? 0, pointsFor: pf[team.id] ?? 0, pointsAgainst: pa[team.id] ?? 0)
        }
    }

    static func aggregatePlayerStats(games: [Game], seasonId: UUID, positionMap: [UUID: String] = [:]) -> [PlayerSeasonStat] {
        let milestones = milestoneCounts(in: games)
        var totals: [UUID: PlayerSeasonStat] = [:]
        var teamNameMap: [UUID: String] = [:]; var teamIdMap: [UUID: UUID] = [:]; var nameMap: [UUID: String] = [:]
        for game in games {
            for stat in game.boxScore {
                nameMap[stat.playerId] = stat.playerName
                teamIdMap[stat.playerId] = stat.teamId
                teamNameMap[stat.playerId] = stat.teamId == game.homeTeamId ? game.homeTeamName : game.awayTeamName
                var total = totals[stat.playerId] ?? PlayerSeasonStat(playerId: stat.playerId, playerName: stat.playerName, teamId: stat.teamId, teamName: "", seasonId: seasonId, games: 0, totalPoints: 0, totalRebounds: 0, totalAssists: 0, totalSteals: 0, totalBlocks: 0, totalMinutes: 0)
                total.games += 1; total.totalPoints += stat.points; total.totalRebounds += stat.rebounds; total.totalAssists += stat.assists; total.totalSteals += stat.steals; total.totalBlocks += stat.blocks; total.totalMinutes += stat.minutes
                total.totalFieldGoalsMade += stat.fieldGoalsMade; total.totalFieldGoalsAttempted += stat.fieldGoalsAttempted; total.totalThreeMade += stat.threeMade; total.totalThreeAttempted += stat.threeAttempted; total.totalFreeThrowsMade += stat.freeThrowsMade; total.totalFreeThrowsAttempted += stat.freeThrowsAttempted; total.totalFouls += stat.fouls
                totals[stat.playerId] = total
            }
        }
        return totals.values.map { stat -> PlayerSeasonStat in
            var copy = stat; copy.seasonId = seasonId; copy.teamName = teamNameMap[stat.playerId] ?? ""; copy.teamId = teamIdMap[stat.playerId] ?? stat.teamId; copy.playerName = nameMap[stat.playerId] ?? stat.playerName; copy.position = positionMap[stat.playerId] ?? ""; copy.tripleDoubles = milestones[stat.playerId]?.triple ?? 0; copy.doubleDoubles = milestones[stat.playerId]?.double ?? 0; return copy
        }.sorted { $0.pointsPerGame > $1.pointsPerGame }
    }

    static func sortedStandings(participants: [Team], teamStats: [TeamSeasonStat]) -> [Team] {
        let statMap = Dictionary(uniqueKeysWithValues: teamStats.map { ($0.teamId, $0) })
        let order = Dictionary(uniqueKeysWithValues: participants.enumerated().map { ($1.id, $0) })
        return participants.sorted {
            let l = statMap[$0.id]; let r = statMap[$1.id]
            if (l?.wins ?? 0) != (r?.wins ?? 0) { return (l?.wins ?? 0) > (r?.wins ?? 0) }
            if (l?.pointDiff ?? 0) != (r?.pointDiff ?? 0) { return (l?.pointDiff ?? 0) > (r?.pointDiff ?? 0) }
            if (l?.pointsFor ?? 0) != (r?.pointsFor ?? 0) { return (l?.pointsFor ?? 0) > (r?.pointsFor ?? 0) }
            return (order[$0.id] ?? 0) < (order[$1.id] ?? 0)
        }
    }

    static func playoffRoundName(_ round: Int) -> String {
        switch round { case 1: return "首轮"; case 2: return "分区半决赛"; case 3: return "分区决赛"; case 4: return "总决赛"; default: return "季后赛" }
    }

    // 三双/两双统计（NBA 判定）：得分、篮板、助攻、抢断、盖帽五项里 >=10 的项数，
    // >=3 项是三双，恰好 2 项是两双，三双不计入两双。
    static func milestoneCounts(in games: [Game]) -> [UUID: (triple: Int, double: Int)] {
        var counts: [UUID: (triple: Int, double: Int)] = [:]
        for game in games {
            for stat in game.boxScore {
                let categories = [stat.points, stat.rebounds, stat.assists, stat.steals, stat.blocks].filter { $0 >= 10 }.count
                if categories >= 3 {
                    counts[stat.playerId, default: (0, 0)].triple += 1
                } else if categories == 2 {
                    counts[stat.playerId, default: (0, 0)].double += 1
                }
            }
        }
        return counts
    }

    // 历史单场得分最高：返回 (球员名, 队名, 得分, 赛季号, 对手)，按得分降序。
    static func topScoringGames(in seasons: [SeasonSnapshot], limit: Int) -> [(playerName: String, teamName: String, points: Int, seasonNumber: Int, opponent: String)] {
        var rows: [(playerName: String, teamName: String, points: Int, seasonNumber: Int, opponent: String)] = []
        for season in seasons {
            for game in season.games + season.playoffGames {
                for stat in game.boxScore {
                    let opponent = stat.teamId == game.homeTeamId ? game.awayTeamName : game.homeTeamName
                    rows.append((stat.playerName, stat.teamId == game.homeTeamId ? game.homeTeamName : game.awayTeamName, stat.points, season.seasonNumber, opponent))
                }
            }
        }
        return Array(rows.sorted { $0.points > $1.points }.prefix(limit))
    }

    // 奖项：得分王/篮板王/助攻王/抢断王/盖帽王按场均最高（出场至少一半，凑不够就全算）；
    // DPOY 按抢断+盖帽综合；MVP 按场均分+板+助×1.5+抢断×2+盖帽×2+球队胜场×0.15；
    // 最佳阵容按每个位置场均分排前三；FMVP 按冠军队总决赛场均分最高（败方再高也不给）。
    static func computeAwards(regularPlayerStats: [PlayerSeasonStat], regularTeamStats: [TeamSeasonStat], playoffGames: [Game], finalsGames: [Game], snapshotId: UUID, positionMap: [UUID: String], championTeamId: UUID? = nil, conferenceMap: [UUID: String] = [:]) -> (awards: [SeasonAward], first: [AllNBAEntry], second: [AllNBAEntry], third: [AllNBAEntry], leaders: [SeasonLeader], playoffPlayerStats: [PlayerSeasonStat], fmvpPlayerId: UUID?) {
        let maxGames = regularPlayerStats.map { $0.games }.max() ?? 0
        let threshold = max(1, maxGames / 2)
        let eligible = regularPlayerStats.filter { $0.games >= threshold }
        let pool = eligible.isEmpty ? regularPlayerStats : eligible
        func leader(_ key: (PlayerSeasonStat) -> Double) -> PlayerSeasonStat? { pool.max(by: { key($0) < key($1) }) }
        func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
        var awards: [SeasonAward] = []
        var leaders: [SeasonLeader] = []
        if let s = leader({ $0.pointsPerGame }) { awards.append(SeasonAward(title: "得分王", playerId: s.playerId, playerName: s.playerName, teamName: s.teamName, valueText: "场均 \(fmt(s.pointsPerGame)) 分")); leaders.append(SeasonLeader(category: "得分王", playerName: s.playerName, teamName: s.teamName, perGame: s.pointsPerGame, valueText: "场均 \(fmt(s.pointsPerGame)) 分")) }
        if let s = leader({ $0.reboundsPerGame }) { awards.append(SeasonAward(title: "篮板王", playerId: s.playerId, playerName: s.playerName, teamName: s.teamName, valueText: "场均 \(fmt(s.reboundsPerGame)) 板")); leaders.append(SeasonLeader(category: "篮板王", playerName: s.playerName, teamName: s.teamName, perGame: s.reboundsPerGame, valueText: "场均 \(fmt(s.reboundsPerGame)) 板")) }
        if let s = leader({ $0.assistsPerGame }) { awards.append(SeasonAward(title: "助攻王", playerId: s.playerId, playerName: s.playerName, teamName: s.teamName, valueText: "场均 \(fmt(s.assistsPerGame)) 助")); leaders.append(SeasonLeader(category: "助攻王", playerName: s.playerName, teamName: s.teamName, perGame: s.assistsPerGame, valueText: "场均 \(fmt(s.assistsPerGame)) 助")) }
        if let s = leader({ $0.stealsPerGame }) { leaders.append(SeasonLeader(category: "抢断王", playerName: s.playerName, teamName: s.teamName, perGame: s.stealsPerGame, valueText: "场均 \(fmt(s.stealsPerGame)) 断")) }
        if let s = leader({ $0.blocksPerGame }) { leaders.append(SeasonLeader(category: "盖帽王", playerName: s.playerName, teamName: s.teamName, perGame: s.blocksPerGame, valueText: "场均 \(fmt(s.blocksPerGame)) 帽")) }
        let winsMap = Dictionary(uniqueKeysWithValues: regularTeamStats.map { ($0.teamId, $0.wins) })
        if let mvp = pool.max(by: { ($0.pointsPerGame + $0.reboundsPerGame + $0.assistsPerGame * 1.5 + $0.stealsPerGame * 2 + $0.blocksPerGame * 2 + Double(winsMap[$0.teamId] ?? 0) * 0.15) < ($1.pointsPerGame + $1.reboundsPerGame + $1.assistsPerGame * 1.5 + $1.stealsPerGame * 2 + $1.blocksPerGame * 2 + Double(winsMap[$1.teamId] ?? 0) * 0.15) }) {
            awards.insert(SeasonAward(title: "MVP", playerId: mvp.playerId, playerName: mvp.playerName, teamName: mvp.teamName, valueText: "场均 \(fmt(mvp.pointsPerGame)) 分 \(fmt(mvp.reboundsPerGame)) 板 \(fmt(mvp.assistsPerGame)) 助"), at: 0)
        }
        if let dpoy = pool.max(by: { ($0.stealsPerGame + $0.blocksPerGame) < ($1.stealsPerGame + $1.blocksPerGame) }) {
            awards.append(SeasonAward(title: "DPOY", playerId: dpoy.playerId, playerName: dpoy.playerName, teamName: dpoy.teamName, valueText: "场均 \(fmt(dpoy.stealsPerGame)) 断 \(fmt(dpoy.blocksPerGame)) 帽"))
        }
        // 最佳阵容分东西部两组：每个分区、每个位置按场均分取前三，分别进一/二/三阵。
        // conferenceMap 为空（老调用）时退回整联盟一组，东西部字段留空。
        var first: [AllNBAEntry] = []; var second: [AllNBAEntry] = []; var third: [AllNBAEntry] = []
        let positions = ["PG", "SG", "SF", "PF", "C"]
        let positionNames = ["PG": "控卫", "SG": "分卫", "SF": "小前", "PF": "大前", "C": "中锋"]
        let conferences = conferenceMap.isEmpty ? [""] : ["东部", "西部"]
        for conf in conferences {
            for pos in positions {
                let group = pool.filter {
                    let p = $0.position.isEmpty ? (positionMap[$0.playerId] ?? "PG") : $0.position
                    let c = conferenceMap[$0.teamId] ?? ""
                    return p == pos && (conf.isEmpty || c == conf)
                }.sorted { $0.pointsPerGame > $1.pointsPerGame }
                if group.indices.contains(0) { first.append(AllNBAEntry(playerName: group[0].playerName, teamName: group[0].teamName, position: positionNames[pos] ?? pos, conference: conf)) }
                if group.indices.contains(1) { second.append(AllNBAEntry(playerName: group[1].playerName, teamName: group[1].teamName, position: positionNames[pos] ?? pos, conference: conf)) }
                if group.indices.contains(2) { third.append(AllNBAEntry(playerName: group[2].playerName, teamName: group[2].teamName, position: positionNames[pos] ?? pos, conference: conf)) }
            }
        }
        let playoffPlayerStats = aggregatePlayerStats(games: playoffGames, seasonId: snapshotId, positionMap: positionMap)
        var fmvpId: UUID? = nil
        if !finalsGames.isEmpty {
            let finalsStats = aggregatePlayerStats(games: finalsGames, seasonId: snapshotId, positionMap: positionMap)
            // FMVP 只在冠军队里比总决赛场均分，冠军未知时不发 FMVP。
            let finalsPool = championTeamId != nil ? finalsStats.filter { $0.teamId == championTeamId } : []
            if let fmvp = finalsPool.max(by: { $0.pointsPerGame < $1.pointsPerGame }) {
                fmvpId = fmvp.playerId
                awards.append(SeasonAward(title: "FMVP", playerId: fmvp.playerId, playerName: fmvp.playerName, teamName: fmvp.teamName, valueText: "总决赛场均 \(fmt(fmvp.pointsPerGame)) 分"))
            }
        }
        return (awards, first, second, third, leaders, playoffPlayerStats, fmvpId)
    }

    // 把一名球员的单场得分拆成投篮：两分命中、三分命中、罚球命中。
    // 思路：先按三分能力定三分命中数，再按罚球能力定罚球命中数（并调成奇偶，
    // 让剩下的分一定能被两分整除），最后剩下全是两分；出手数按命中率反推，
    // 并保证总出手 >= 总命中、三分出手 >= 三分命中、罚球出手 >= 罚球命中、
    // 总出手 - 三分出手 >= 两分命中（即两分出手够分两分命中）。
    // 0 分球员也可能有出手（投丢了），命中全是 0。
    private static func decomposeShooting(points: Int, player: Player, shootingForm: Double = 1.0,
                                          rng: inout SeededRandom)
    -> (fieldGoalsMade: Int, fieldGoalsAttempted: Int, threeMade: Int,
        threeAttempted: Int, freeThrowsMade: Int, freeThrowsAttempted: Int) {
        let attrs = player.attributes
        func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
            min(high, max(low, value))
        }
        if points == 0 {
            let fieldGoalsAttempted = rng.nextInt(in: 0...3)
            // 三分数值 40 以下不出手三分。
            let threeAttempted = attrs.threePoint < 40 ? 0 : min(fieldGoalsAttempted, rng.nextInt(in: 0...2))
            // 0 出手不能只有 1 个罚球（1 罚只能是 2+1/3+1 的加罚，得先有投篮命中）：0 出手时罚球为 0。
            let freeThrowsAttempted = fieldGoalsAttempted == 0 ? 0 : rng.nextInt(in: 0...1) * 2
            return (0, fieldGoalsAttempted, 0, threeAttempted, 0, freeThrowsAttempted)
        }
        // 出手倾向：内线三分占比减半，外线三分占比提高，综合正常。
        let tendencyThreeMultiplier: Double
        switch player.tendency {
        case .inside: tendencyThreeMultiplier = 0.45
        case .outside: tendencyThreeMultiplier = 1.7
        case .balanced: tendencyThreeMultiplier = 1.0
        }
        // 三分数值 40 以下不出手三分：三分占比直接归零。
        let threeShare = attrs.threePoint < 40 ? 0 : clamp((0.15 + Double(attrs.threePoint - 50) * 0.004) * tendencyThreeMultiplier, 0.05, 0.65)
        // 三分命中率：评分越高越高，99 分约 53%，90 分约 48%，80 分约 44%，70 分约 40%。
        let threePercentage = clamp(0.40 + Double(attrs.threePoint - 70) * 0.0045
            + (rng.nextDouble() - 0.5) * 0.10, 0.28, 0.58)
        let freeThrowPercentage = clamp(0.74 + Double(attrs.freeThrow - 70) * 0.003, 0.65, 0.94)
        let shootingAverage = Double(attrs.threePoint + attrs.midRange + attrs.finishing) / 3.0
        // 总命中率：评分越高越高，99 分约 58%（再乘手感、封顶 65%），70 分约 48%，
        // 目标是前 30 大于 43%、前十约 50%、前三约 60%（只统计场均出手 >= 4 次的球员）。
        let fieldGoalPercentage = clamp((0.48 + (shootingAverage - 70.0) * 0.0035) * shootingForm, 0.30, 0.65)
        var threeMade = Int((Double(points) * threeShare / 3.0).rounded())
        threeMade = min(max(threeMade, 0), points / 3)
        if rng.nextDouble() < 0.3 && threeMade > 0 { threeMade -= 1 }
        else if rng.nextDouble() < 0.3 && threeMade < points / 3 { threeMade += 1 }
        let remainingAfterThree = points - threeMade * 3
        var freeThrowsMade = Int((Double(remainingAfterThree)
            * (0.12 + Double(attrs.freeThrow - 70) * 0.001)).rounded())
        freeThrowsMade = min(max(freeThrowsMade, 0), remainingAfterThree)
        if (remainingAfterThree - freeThrowsMade) % 2 != 0 {
            if freeThrowsMade < remainingAfterThree { freeThrowsMade += 1 } else { freeThrowsMade -= 1 }
        }
        let twoMade = (remainingAfterThree - freeThrowsMade) / 2
        let fieldGoalsMade = twoMade + threeMade
        let threeAttempted: Int
        if attrs.threePoint < 40 {
            threeAttempted = 0
        } else if threeMade == 0 {
            threeAttempted = min(rng.nextInt(in: 0...2), fieldGoalsMade)
        } else {
            threeAttempted = max(threeMade, Int((Double(threeMade) / threePercentage).rounded()))
        }
        var freeThrowsAttempted: Int
        if freeThrowsMade == 0 {
            // 没罚进就只有 0 罚或 2 罚，不能只有 1 罚（1 罚必须是加罚，得先罚进一个）。
            freeThrowsAttempted = rng.nextInt(in: 0...1) * 2
        } else {
            freeThrowsAttempted = max(freeThrowsMade, Int((Double(freeThrowsMade) / freeThrowPercentage).rounded()))
        }
        var fieldGoalsAttempted = fieldGoalsMade
        if fieldGoalsMade > 0 {
            fieldGoalsAttempted = max(fieldGoalsAttempted,
                                     Int((Double(fieldGoalsMade) / fieldGoalPercentage).rounded()))
        }
        fieldGoalsAttempted = max(fieldGoalsAttempted, threeAttempted + twoMade)
        // 罚球兜底：只有 1 个罚球时必须是 2+1/3+1 的加罚，得有投篮命中；否则改成 2 罚（罚中数不变，总分不变）。
        if freeThrowsAttempted == 1 && fieldGoalsMade == 0 {
            freeThrowsAttempted = 2
        }
        return (fieldGoalsMade, fieldGoalsAttempted, threeMade, threeAttempted,
                freeThrowsMade, freeThrowsAttempted)
    }
}
