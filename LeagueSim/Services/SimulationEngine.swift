import Foundation

// MARK: - 赛季模拟引擎（纯函数：输入联赛 + 种子，输出快照，不改原联赛）
// P0 赛程：单循环，每两队打 1 场，每队 29 场（不是 82 场，界面和 README 都写明）。
// 只有激活名单 >= 5 人的球队参赛；不够 5 人的队会列入 skippedTeams，不进排名，
// 这样联赛没填完也能先跑一部分，不用等 30 队全部填满。
// 同一名单 + 同一种子：赛程按球队在联赛里的顺序生成，随机数只从种子取，
// 所以重跑结果完全相同；改了任何一名球员的能力或轮换，结果就可能变。
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

    static func simulate(league: League, seed: Int64) -> Result {
        let settings = league.settings
        var rng = SeededRandom(seed: seed)
        let participants = league.teams.filter { $0.activeRoster.count >= 5 }
        let skipped = league.teams.filter { $0.activeRoster.count < 5 }
        let ratings = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, teamRating(for: $0, settings: settings)) })
        let leagueAverage = participants.isEmpty ? 0 : ratings.values.reduce(0, +) / Double(participants.count)

        // 赛程：按联赛顺序两两配对，主客场按配对顺序轮换（第一队主场），全部确定性。
        var games: [Game] = []
        var teamWins: [UUID: Int] = [:]
        var teamLosses: [UUID: Int] = [:]
        var teamPointsFor: [UUID: Int] = [:]
        var teamPointsAgainst: [UUID: Int] = [:]
        var playerTotals: [UUID: PlayerSeasonStat] = [:]
        var playerTeamName: [UUID: String] = [:]
        var playerTeamId: [UUID: UUID] = [:]
        var playerName: [UUID: String] = [:]

        for i in participants.indices {
            for j in (i + 1)..<participants.count {
                let home = participants[i]
                let away = participants[j]
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
                games.append(Game(id: UUID(), homeTeamId: home.id, homeTeamName: home.name,
                                  awayTeamId: away.id, awayTeamName: away.name,
                                  homeScore: homeScore, awayScore: awayScore, boxScore: box))
                teamWins[home.id, default: 0] += homeWins ? 1 : 0
                teamLosses[home.id, default: 0] += homeWins ? 0 : 1
                teamWins[away.id, default: 0] += homeWins ? 0 : 1
                teamLosses[away.id, default: 0] += homeWins ? 1 : 0
                teamPointsFor[home.id, default: 0] += homeScore
                teamPointsAgainst[home.id, default: 0] += awayScore
                teamPointsFor[away.id, default: 0] += awayScore
                teamPointsAgainst[away.id, default: 0] += homeScore
                for stat in box {
                    playerName[stat.playerId] = stat.playerName
                    playerTeamId[stat.playerId] = stat.teamId
                    playerTeamName[stat.playerId] = stat.teamId == home.id ? home.name : away.name
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
        }

        let snapshotId = UUID()
        let teamStats = participants.map { team in
            TeamSeasonStat(teamId: team.id, teamName: team.name, division: team.division,
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

        let snapshot = SeasonSnapshot(id: snapshotId, seasonNumber: league.nextSeasonNumber,
                                      seed: seed, settings: settings, games: games,
                                      teamStats: teamStats, playerStats: playerStats, createdAt: Date())
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
