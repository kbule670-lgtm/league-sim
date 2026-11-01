import Foundation
import SwiftUI

// MARK: - 联赛状态：存档列表 + 当前存档（App 内唯一真相来源）
// 切换流程（写死顺序，不许跳步）：先保存当前存档 -> 再加载目标存档 -> 再记当前存档 ID。
// 删除流程：界面二次确认后才调 deleteArchive；删的是整个存档目录，不可恢复。
// 全离线：本类只读写本地 JSON，不做任何网络操作。
@MainActor
final class LeagueStore: ObservableObject {
    @Published var archives: [ArchiveMeta] = []
    @Published var currentLeague: League?
    @Published var lastSaveOK: Bool = true
    // 进存档状态：正在解码时界面显示“正在进入”，失败时弹具体错误，不再静默没反应。
    @Published var isEnteringArchive = false
    @Published var enterErrorMessage: String? = nil

    var currentArchiveId: UUID? { currentLeague?.id }

    init() {
        refreshArchives()
    }

    func refreshArchives() {
        archives = ArchiveStore.listArchives()
    }

    // MARK: 存档操作（数量不限）
    func createArchive(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let league = League.emptyLeague(name: trimmed.isEmpty ? "新联赛" : trimmed)
        save(league)
        refreshArchives()
    }

    func renameCurrentLeague(to name: String) {
        guard var league = currentLeague else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        league.name = trimmed
        league.updatedAt = Date()
        currentLeague = league
        save(league)
        refreshArchives()
    }

    func deleteArchive(id: UUID) {
        if currentLeague?.id == id { currentLeague = nil }
        _ = ArchiveStore.deleteArchive(id: id)
        refreshArchives()
    }

    // MARK: 切换（先存后载）
    // 修复“1、2、3 全点了都进不去”：以前在主线程同步解码，文件大时会卡住、
    // 解码失败时又静默 return，界面看起来就是点了没反应。现在改成：
    // 后台解码（主线程不卡，能看到“正在进入”）、失败弹具体错误、重复点按直接忽略。
    func enterArchive(id: UUID) {
        guard !isEnteringArchive else { return }
        if let current = currentLeague { save(current) }
        isEnteringArchive = true
        enterErrorMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                ArchiveStore.loadLeagueResult(id: id)
            }.value
            isEnteringArchive = false
            switch result {
            case .success(let league):
                currentLeague = league
                ArchiveStore.saveCurrentArchiveId(id)
                refreshArchives()
            case .failure(let error):
                // 系统解码错误原文是英文，用户看不懂，翻译成中文再弹。
                if let decodingError = error as? DecodingError {
                    switch decodingError {
                    case .keyNotFound(let key, _):
                        enterErrorMessage = "进不去：存档里缺少字段 \(key.stringValue)，请把这条提示发给开发者"
                    case .valueNotFound(_, let context):
                        enterErrorMessage = "进不去：字段值缺失 \(context.codingPath.last?.stringValue ?? "")"
                    case .typeMismatch(_, let context):
                        enterErrorMessage = "进不去：字段类型不对 \(context.codingPath.last?.stringValue ?? "")"
                    case .dataCorrupted(let context):
                        enterErrorMessage = "进不去：存档数据损坏 \(context.debugDescription)"
                    @unknown default:
                        enterErrorMessage = "进不去：存档读不出来"
                    }
                } else {
                    enterErrorMessage = "进不去：\(error.localizedDescription)"
                }
            }
        }
    }

    func backToArchiveList() {
        if let current = currentLeague { save(current) }
        currentLeague = nil
        refreshArchives()
    }

    // MARK: 当前联赛修改后保存
    func save(_ league: League? = nil) {
        guard var value = league ?? currentLeague else { return }
        value.updatedAt = Date()
        if league == nil { currentLeague = value }
        lastSaveOK = ArchiveStore.saveLeague(value)
        refreshArchives()
    }

    func updateCurrent(_ transform: (inout League) -> Void) {
        guard var league = currentLeague else { return }
        transform(&league)
        league.updatedAt = Date()
        currentLeague = league
        save(league)
    }

    // MARK: 球队 / 球员操作（都在当前存档内）
    func updateTeam(_ team: Team) {
        updateCurrent { league in
            if let index = league.teams.firstIndex(where: { $0.id == team.id }) {
                league.teams[index] = team
            }
        }
    }

    func addPlayer(to teamId: UUID, player: Player, status: RosterStatus) {
        updateCurrent { league in
            guard let teamIndex = league.teams.firstIndex(where: { $0.id == teamId }) else { return }
            let nextOrder = (league.teams[teamIndex].roster.map { $0.rotationOrder }.max() ?? 0) + 1
            league.teams[teamIndex].roster.append(
                RosterSlot(player: player, status: status, rotationOrder: nextOrder))
        }
    }

    func updatePlayer(in teamId: UUID, slot: RosterSlot) {
        updateCurrent { league in
            guard let teamIndex = league.teams.firstIndex(where: { $0.id == teamId }),
                  let slotIndex = league.teams[teamIndex].roster.firstIndex(
                    where: { $0.player.id == slot.player.id }) else { return }
            league.teams[teamIndex].roster[slotIndex] = slot
        }
    }

    func removePlayer(in teamId: UUID, playerId: UUID) {
        updateCurrent { league in
            guard let teamIndex = league.teams.firstIndex(where: { $0.id == teamId }) else { return }
            league.teams[teamIndex].roster.removeAll { $0.player.id == playerId }
        }
    }

    // 中途交易（手动控制，App 不自动交易）：
    // 把一名球员从一队移到另一队，球员 ID 不变、能力不改；
    // 已跑完的赛季快照是冻结深拷贝，不会因为这次换队被改写，
    // 下一赛季跑出来的统计会记在新队名下，这就是换队历史的来源。
    // 球衣号冲突时直接失败、不自动改号，让使用者先去改球衣号再交易。
    func tradePlayer(from fromTeamId: UUID, playerId: UUID, to toTeamId: UUID,
                     status: RosterStatus) -> Bool {
        guard fromTeamId != toTeamId else { return false }
        var success = false
        updateCurrent { league in
            guard let fromIndex = league.teams.firstIndex(where: { $0.id == fromTeamId }),
                  let toIndex = league.teams.firstIndex(where: { $0.id == toTeamId }),
                  let slotIndex = league.teams[fromIndex].roster.firstIndex(
                    where: { $0.player.id == playerId }) else { return }
            let slot = league.teams[fromIndex].roster[slotIndex]
            guard !league.teams[toIndex].roster.contains(where: { $0.player.id == playerId }),
                  !league.teams[toIndex].roster.contains(
                    where: { $0.player.jerseyNumber == slot.player.jerseyNumber }) else { return }
            league.teams[fromIndex].roster.remove(at: slotIndex)
            let nextOrder = (league.teams[toIndex].roster.map { $0.rotationOrder }.max() ?? 0) + 1
            var moved = slot
            moved.status = status
            moved.rotationOrder = nextOrder
            league.teams[toIndex].roster.append(moved)
            success = true
        }
        return success
    }

    func movePlayer(in teamId: UUID, playerId: UUID, direction: Int) {
        updateCurrent { league in
            guard let teamIndex = league.teams.firstIndex(where: { $0.id == teamId }) else { return }
            var roster = league.teams[teamIndex].roster.sorted { $0.rotationOrder < $1.rotationOrder }
            guard let index = roster.firstIndex(where: { $0.player.id == playerId }) else { return }
            let target = index + direction
            guard target >= 0 && target < roster.count else { return }
            roster.swapAt(index, target)
            for i in roster.indices { roster[i].rotationOrder = i + 1 }
            league.teams[teamIndex].roster = roster
        }
    }

    // 虚构测试名单：只在用户点了按钮后才生成，不是预置数据，更不是真实球员。
    // 每队 13 人（首发 5 + 替补 8），名字是“测试球员 1”这类占位名，能力按序号在 65-88 之间错开，
    // 目的只是让用户不用手动填 30 队就能先跑一赛季验收模拟与快照。
    func fillTestRoster(for teamId: UUID) {
        updateCurrent { league in
            guard let teamIndex = league.teams.firstIndex(where: { $0.id == teamId }) else { return }
            let positions: [Position] = [.pg, .sg, .sf, .pf, .c, .pg, .sg, .sf, .pf, .c, .sg, .sf, .pf]
            var slots: [RosterSlot] = []
            for (offset, position) in positions.enumerated() {
                let base = 65 + (offset * 2) % 24
                var attrs = Attributes()
                attrs.threePoint = min(99, base + 3)
                attrs.midRange = min(99, base + 2)
                attrs.finishing = min(99, base + 1)
                attrs.freeThrow = min(99, base)
                attrs.playmaking = min(99, base + (position == .pg ? 10 : 0))
                attrs.rebounding = min(99, base + (position == .c || position == .pf ? 10 : 0))
                attrs.perimeterDefense = min(99, base)
                attrs.rimProtection = min(99, base + (position == .c ? 10 : 0))
                attrs.athleticism = min(99, base + 2)
                attrs.basketballIQ = min(99, base + 1)
                attrs.durability = min(99, base + 5)
                attrs.potential = min(99, base + 8)
                let player = Player(name: "测试球员 \(offset + 1)", jerseyNumber: offset + 1,
                                    position: position, age: 24 + offset % 8,
                                    heightCm: 190 + offset % 20, weightKg: 85 + offset % 20,
                                    attributes: attrs)
                slots.append(RosterSlot(player: player,
                                        status: offset < 5 ? .starter : .bench,
                                        rotationOrder: offset + 1))
            }
            league.teams[teamIndex].roster = slots
        }
    }

    func fillTestRostersForAllEmptyTeams() {
        updateCurrent { league in
            for teamIndex in league.teams.indices where league.teams[teamIndex].roster.isEmpty {
                let positions: [Position] = [.pg, .sg, .sf, .pf, .c, .pg, .sg, .sf, .pf, .c, .sg, .sf, .pf]
                var slots: [RosterSlot] = []
                for (offset, position) in positions.enumerated() {
                    let base = 65 + (offset * 2) % 24
                    var attrs = Attributes()
                    attrs.threePoint = min(99, base + 3)
                    attrs.midRange = min(99, base + 2)
                    attrs.finishing = min(99, base + 1)
                    attrs.freeThrow = min(99, base)
                    attrs.playmaking = min(99, base + (position == .pg ? 10 : 0))
                    attrs.rebounding = min(99, base + (position == .c || position == .pf ? 10 : 0))
                    attrs.perimeterDefense = min(99, base)
                    attrs.rimProtection = min(99, base + (position == .c ? 10 : 0))
                    attrs.athleticism = min(99, base + 2)
                    attrs.basketballIQ = min(99, base + 1)
                    attrs.durability = min(99, base + 5)
                    attrs.potential = min(99, base + 8)
                    let player = Player(name: "测试球员 \(offset + 1)", jerseyNumber: offset + 1,
                                        position: position, age: 24 + offset % 8,
                                        heightCm: 190 + offset % 20, weightKg: 85 + offset % 20,
                                        attributes: attrs)
                    slots.append(RosterSlot(player: player,
                                            status: offset < 5 ? .starter : .bench,
                                            rotationOrder: offset + 1))
                }
                league.teams[teamIndex].roster = slots
            }
        }
    }

    // 跑赛季：快照追加后，赛季号 +1；快照本身是深拷贝，之后改名单不污染它。
    func runSeason(seed: Int64) -> (snapshot: SeasonSnapshot, skipped: [Team]) {
        guard var league = currentLeague else {
            fatalError("没有当前存档时不应调 runSeason，界面已禁用该按钮")
        }
        var settings = league.settings
        settings.lastSeed = seed
        league.settings = settings
        let result = SimulationEngine.simulate(league: league, seed: seed)
        league.seasons.append(result.snapshot)
        league.nextSeasonNumber += 1
        league.updatedAt = Date()
        currentLeague = league
        save(league)
        return (result.snapshot, result.skippedTeams)
    }

    // MARK: - 存档复制
    func copyArchive(id: UUID) {
        guard var league = ArchiveStore.loadLeague(id: id) else { return }
        league.id = UUID()
        league.name = league.name + " 副本"
        league.ongoingSeason = nil
        let now = Date()
        league.createdAt = now
        league.updatedAt = now
        _ = ArchiveStore.saveLeague(league)
        refreshArchives()
    }

    // MARK: - 多选交易（转出、转入都可多选，互换后球衣不冲突才成交）
    func tradePlayersMulti(from fromTeamId: UUID, outPlayerIds: [UUID], to toTeamId: UUID, inPlayerIds: [UUID]) -> Bool {
        guard fromTeamId != toTeamId else { return false }
        var success = false
        updateCurrent { league in
            guard let fromIndex = league.teams.firstIndex(where: { $0.id == fromTeamId }),
                  let toIndex = league.teams.firstIndex(where: { $0.id == toTeamId }) else { return }
            let outSlots = league.teams[fromIndex].roster.filter { outPlayerIds.contains($0.player.id) }
            let inSlots = league.teams[toIndex].roster.filter { inPlayerIds.contains($0.player.id) }
            guard outSlots.count == outPlayerIds.count, inSlots.count == inPlayerIds.count else { return }
            // 互换后校验：去掉换出的人、加上换入的人，队内不能有重复球衣号或重复球员。
            func check(teamRoster: [RosterSlot], removeIds: [UUID], addSlots: [RosterSlot]) -> Bool {
                let remaining = teamRoster.filter { !removeIds.contains($0.player.id) }
                let combined = remaining + addSlots
                let jerseys = combined.map { $0.player.jerseyNumber }
                let ids = combined.map { $0.player.id }
                return Set(jerseys).count == jerseys.count && Set(ids).count == ids.count
            }
            guard check(teamRoster: league.teams[fromIndex].roster, removeIds: outPlayerIds, addSlots: inSlots) else { return }
            guard check(teamRoster: league.teams[toIndex].roster, removeIds: inPlayerIds, addSlots: outSlots) else { return }
            league.teams[fromIndex].roster.removeAll { outPlayerIds.contains($0.player.id) }
            league.teams[toIndex].roster.removeAll { inPlayerIds.contains($0.player.id) }
            let fromNext = (league.teams[fromIndex].roster.map { $0.rotationOrder }.max() ?? 0) + 1
            let toNext = (league.teams[toIndex].roster.map { $0.rotationOrder }.max() ?? 0) + 1
            for (i, var slot) in inSlots.enumerated() { slot.rotationOrder = fromNext + i; league.teams[fromIndex].roster.append(slot) }
            for (i, var slot) in outSlots.enumerated() { slot.rotationOrder = toNext + i; league.teams[toIndex].roster.append(slot) }
            success = true
        }
        return success
    }

    // MARK: - 进行中的赛季
    private func ratingsForOngoing(_ league: League, participants: [Team]) -> ([UUID: Double], Double) {
        let ratings = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, SimulationEngine.teamRating(for: $0, settings: league.ongoingSeason?.settings ?? league.settings)) })
        let avg = participants.isEmpty ? 0 : ratings.values.reduce(0, +) / Double(participants.count)
        return (ratings, avg)
    }

    func startOngoingSeason(seed: Int64) -> Bool {
        guard var league = currentLeague, league.ongoingSeason == nil else { return false }
        let participants = league.teams.filter { $0.activeRoster.count >= 5 }
        guard participants.count >= 2 else { return false }
        var settings = league.settings
        settings.lastSeed = seed
        league.settings = settings
        let pairs = SimulationEngine.regularSeasonSchedule(participants: participants)
        let schedule = pairs.enumerated().map { ScheduledGame(id: UUID(), index: $0.offset, homeTeamId: $0.element.home.id, awayTeamId: $0.element.away.id, playedGameId: nil) }
        league.ongoingSeason = OngoingSeason(id: UUID(), seasonNumber: league.nextSeasonNumber, seed: seed, settings: settings, schedule: schedule, playedGames: [], playoffGames: [], playoffSeries: [], playoffRound: 0, restCounts: [:])
        league.updatedAt = Date()
        currentLeague = league
        save(league)
        return true
    }

    func discardOngoingSeason() {
        updateCurrent { league in league.ongoingSeason = nil }
    }

    private func playRegularScheduled(_ league: inout League, scheduled: ScheduledGame) {
        guard var ongoing = league.ongoingSeason else { return }
        guard let home = league.teams.first(where: { $0.id == scheduled.homeTeamId }),
              let away = league.teams.first(where: { $0.id == scheduled.awayTeamId }) else { return }
        guard !home.activeRoster.isEmpty && !away.activeRoster.isEmpty else { return }
        let participants = league.teams.filter { $0.activeRoster.count >= 5 }
        let (ratings, avg) = ratingsForOngoing(league, participants: participants)
        var rng = SeededRandom(seed: ongoing.seed &+ Int64(scheduled.index + 1) * 1000003)
        var rest = ongoing.restCounts
        let game = SimulationEngine.playSingleGame(home: home, away: away, ratings: ratings, leagueAverage: avg, settings: ongoing.settings, isPlayoff: false, restCounts: &rest, rng: &rng)
        ongoing.restCounts = rest
        ongoing.playedGames.append(game)
        if let idx = ongoing.schedule.firstIndex(where: { $0.id == scheduled.id }) { ongoing.schedule[idx].playedGameId = game.id }
        league.ongoingSeason = ongoing
    }

    func simulateRegularGame(scheduledId: UUID) {
        updateCurrent { league in
            guard let ongoing = league.ongoingSeason,
                  let scheduled = ongoing.schedule.first(where: { $0.id == scheduledId && $0.playedGameId == nil }) else { return }
            playRegularScheduled(&league, scheduled: scheduled)
        }
    }

    func simulateRegularGamesUpTo(scheduledId: UUID) {
        updateCurrent { league in
            guard let ongoing = league.ongoingSeason,
                  let target = ongoing.schedule.first(where: { $0.id == scheduledId }) else { return }
            let targets = ongoing.schedule.filter { $0.index <= target.index && $0.playedGameId == nil }.sorted { $0.index < $1.index }
            for scheduled in targets { playRegularScheduled(&league, scheduled: scheduled) }
        }
    }

    func simulateAllRegular() {
        updateCurrent { league in
            guard let ongoing = league.ongoingSeason else { return }
            let targets = ongoing.schedule.filter { $0.playedGameId == nil }.sorted { $0.index < $1.index }
            for scheduled in targets { playRegularScheduled(&league, scheduled: scheduled) }
            // 常规赛打完后，季后赛进入“待确认首轮”状态，不自动开打。
            if let updated = league.ongoingSeason, updated.schedule.allSatisfy({ $0.playedGameId != nil }) {
                var copy = updated; copy.playoffRound = 1; league.ongoingSeason = copy
            }
        }
    }

    func simulateNextRegularGame() {
        updateCurrent { league in
            guard let ongoing = league.ongoingSeason,
                  let next = ongoing.schedule.filter({ $0.playedGameId == nil }).sorted(by: { $0.index < $1.index }).first else { return }
            playRegularScheduled(&league, scheduled: next)
            if let updated = league.ongoingSeason, updated.schedule.allSatisfy({ $0.playedGameId != nil }) {
                var copy = updated; copy.playoffRound = 1; league.ongoingSeason = copy
            }
        }
    }

    // 季后赛逐轮确认：每轮打完停下来，等用户点下一轮。总决赛打完直接结算赛季。
    func playNextPlayoffRound() {
        updateCurrent { league in
            guard var ongoing = league.ongoingSeason, ongoing.playoffRound >= 1, ongoing.playoffRound <= 4 else { return }
            let participants = league.teams.filter { $0.activeRoster.count >= 5 }
            let regularStats = SimulationEngine.aggregateTeamStats(games: ongoing.playedGames, participants: participants)
            let eastStandings = SimulationEngine.sortedStandings(participants: participants.filter { SimulationEngine.conference(for: $0, in: participants) == .east }, teamStats: regularStats)
            let westStandings = SimulationEngine.sortedStandings(participants: participants.filter { SimulationEngine.conference(for: $0, in: participants) == .west }, teamStats: regularStats)
            guard eastStandings.count >= 8 && westStandings.count >= 8 else { return }
            let (ratings, avg) = ratingsForOngoing(league, participants: participants)
            var rng = SeededRandom(seed: ongoing.seed &+ Int64(ongoing.playoffRound + 100) * 1000003)
            var rest = ongoing.restCounts
            let round = ongoing.playoffRound
            let roundName = SimulationEngine.playoffRoundName(round)
            func seedOf(_ team: Team, in standings: [Team]) -> Int { (standings.firstIndex(where: { $0.id == team.id }) ?? 0) + 1 }
            func playConference(standings: [Team], conferenceName: String) -> (series: [PlayoffSeries], games: [Game], winner: Team) {
                var seriesOut: [PlayoffSeries] = []; var gamesOut: [Game] = []
                let seeds = Array(standings.prefix(8))
                if round == 1 {
                    var winners: [Team] = []
                    for (hi, li) in [(0, 7), (3, 4), (2, 5), (1, 6)] {
                        let result = SimulationEngine.playSeriesWithPlaying(higher: seeds[hi], higherSeed: hi + 1, lower: seeds[li], lowerSeed: li + 1, round: roundName, conferenceName: conferenceName, ratings: ratings, leagueAverage: avg, settings: ongoing.settings, rng: &rng, restCounts: &rest)
                        seriesOut.append(result.series); gamesOut.append(contentsOf: result.games); winners.append(result.winner)
                    }
                    return (seriesOut, gamesOut, winners.first ?? seeds[0])
                } else if round == 2 {
                    let firstRound = ongoing.playoffSeries.filter { $0.round == "首轮" && $0.conference == conferenceName }
                    guard firstRound.count == 4 else { return (seriesOut, gamesOut, seeds[0]) }
                    let winners = firstRound.compactMap { series in standings.first(where: { $0.id == series.winnerTeamId }) }
                    guard winners.count == 4 else { return (seriesOut, gamesOut, seeds[0]) }
                    var semiWinners: [Team] = []
                    for (a, b) in [(0, 1), (2, 3)] {
                        let first = winners[a]; let second = winners[b]
                        let (higher, lower) = seedOf(first, in: standings) <= seedOf(second, in: standings) ? (first, second) : (second, first)
                        let result = SimulationEngine.playSeriesWithPlaying(higher: higher, higherSeed: seedOf(higher, in: standings), lower: lower, lowerSeed: seedOf(lower, in: standings), round: roundName, conferenceName: conferenceName, ratings: ratings, leagueAverage: avg, settings: ongoing.settings, rng: &rng, restCounts: &rest)
                        seriesOut.append(result.series); gamesOut.append(contentsOf: result.games); semiWinners.append(result.winner)
                    }
                    return (seriesOut, gamesOut, semiWinners.first ?? seeds[0])
                } else if round == 3 {
                    let semis = ongoing.playoffSeries.filter { $0.round == "分区半决赛" && $0.conference == conferenceName }
                    guard semis.count == 2 else { return (seriesOut, gamesOut, seeds[0]) }
                    let winners = semis.compactMap { series in standings.first(where: { $0.id == series.winnerTeamId }) }
                    guard winners.count == 2 else { return (seriesOut, gamesOut, seeds[0]) }
                    let (higher, lower) = seedOf(winners[0], in: standings) <= seedOf(winners[1], in: standings) ? (winners[0], winners[1]) : (winners[1], winners[0])
                    let result = SimulationEngine.playSeriesWithPlaying(higher: higher, higherSeed: seedOf(higher, in: standings), lower: lower, lowerSeed: seedOf(lower, in: standings), round: roundName, conferenceName: conferenceName, ratings: ratings, leagueAverage: avg, settings: ongoing.settings, rng: &rng, restCounts: &rest)
                    seriesOut.append(result.series); gamesOut.append(contentsOf: result.games)
                    return result.winner
                }
                return (seriesOut, gamesOut, seeds[0])
            }
            if round < 4 {
                let eastResult = playConference(standings: eastStandings, conferenceName: "东部")
                ongoing.playoffSeries.append(contentsOf: eastResult.series); ongoing.playoffGames.append(contentsOf: eastResult.games)
                let westResult = playConference(standings: westStandings, conferenceName: "西部")
                ongoing.playoffSeries.append(contentsOf: westResult.series); ongoing.playoffGames.append(contentsOf: westResult.games)
                ongoing.restCounts = rest
                ongoing.playoffRound = round + 1
                league.ongoingSeason = ongoing
            } else {
                // 总决赛
                let eastFinals = ongoing.playoffSeries.filter { $0.round == "分区决赛" && $0.conference == "东部" }.last
                let westFinals = ongoing.playoffSeries.filter { $0.round == "分区决赛" && $0.conference == "西部" }.last
                guard let eastId = eastFinals?.winnerTeamId, let westId = westFinals?.winnerTeamId,
                      let eastChampion = league.teams.first(where: { $0.id == eastId }),
                      let westChampion = league.teams.first(where: { $0.id == westId }) else { return }
                let eastWins = regularStats.first(where: { $0.teamId == eastId })?.wins ?? 0
                let westWins = regularStats.first(where: { $0.teamId == westId })?.wins ?? 0
                let eastDiff = regularStats.first(where: { $0.teamId == eastId })?.pointDiff ?? 0
                let westDiff = regularStats.first(where: { $0.teamId == westId })?.pointDiff ?? 0
                let eastIsHigher = eastWins > westWins || (eastWins == westWins && eastDiff >= westDiff)
                let higher = eastIsHigher ? eastChampion : westChampion
                let lower = eastIsHigher ? westChampion : eastChampion
                let higherSeed = eastIsHigher ? seedOf(eastChampion, in: eastStandings) : seedOf(westChampion, in: westStandings)
                let lowerSeed = eastIsHigher ? seedOf(westChampion, in: westStandings) : seedOf(eastChampion, in: eastStandings)
                let finals = SimulationEngine.playSeriesWithPlaying(higher: higher, higherSeed: higherSeed, lower: lower, lowerSeed: lowerSeed, round: roundName, conferenceName: "总决赛", ratings: ratings, leagueAverage: avg, settings: ongoing.settings, rng: &rng, restCounts: &rest)
                ongoing.playoffSeries.append(finals.series); ongoing.playoffGames.append(contentsOf: finals.games); ongoing.restCounts = rest
                league.ongoingSeason = ongoing
                finishOngoingSeason(&league)
            }
        }
    }

    private func finishOngoingSeason(_ league: inout League) {
        guard let ongoing = league.ongoingSeason else { return }
        let participants = league.teams.filter { $0.activeRoster.count >= 5 }
        let snapshotId = UUID()
        let regularTeamStats = SimulationEngine.aggregateTeamStats(games: ongoing.playedGames, participants: participants)
        var positionMap: [UUID: String] = [:]
        for team in league.teams { for slot in team.roster { positionMap[slot.player.id] = slot.player.position.rawValue } }
        let regularPlayerStats = SimulationEngine.aggregatePlayerStats(games: ongoing.playedGames, seasonId: snapshotId, positionMap: positionMap)
        let finalsGames = ongoing.playoffGames.filter { game in
            guard let series = ongoing.playoffSeries.last(where: { $0.round == "总决赛" }) else { return false }
            return series.gameIds.contains(game.id)
        }
        let computed = SimulationEngine.computeAwards(regularPlayerStats: regularPlayerStats, regularTeamStats: regularTeamStats, playoffGames: ongoing.playoffGames, finalsGames: finalsGames, snapshotId: snapshotId, positionMap: positionMap)
        let championId = ongoing.playoffSeries.last(where: { $0.round == "总决赛" })?.winnerTeamId
        let championName = ongoing.playoffSeries.last(where: { $0.round == "总决赛" })?.winnerTeamName
        let snapshot = SeasonSnapshot(id: snapshotId, seasonNumber: ongoing.seasonNumber, seed: ongoing.seed, settings: ongoing.settings, games: ongoing.playedGames, teamStats: regularTeamStats, playerStats: regularPlayerStats, playoffGames: ongoing.playoffGames, playoffSeries: ongoing.playoffSeries, championTeamId: championId, championTeamName: championName, createdAt: Date())
        var snap = snapshot
        snap.awards = computed.awards; snap.allNBAFirst = computed.first; snap.allNBASecond = computed.second; snap.allNBAThird = computed.third; snap.seasonLeaders = computed.leaders; snap.playoffPlayerStats = computed.playoffPlayerStats
        league.seasons.append(snap)
        // 荣誉记入当前名单：奖项得主、FMVP、冠军队全员。
        for award in computed.awards {
            guard let pid = award.playerId else { continue }
            for ti in league.teams.indices { for si in league.teams[ti].roster.indices where league.teams[ti].roster[si].player.id == pid {
                league.teams[ti].roster[si].player.honors.append(PlayerHonor(type: award.title, seasonNumber: ongoing.seasonNumber, teamName: award.teamName, detail: award.valueText))
            } }
        }
        if let cid = championId, let cname = championName {
            for ti in league.teams.indices where league.teams[ti].id == cid { for si in league.teams[ti].roster.indices {
                league.teams[ti].roster[si].player.honors.append(PlayerHonor(type: "总冠军", seasonNumber: ongoing.seasonNumber, teamName: cname, detail: "第 \(ongoing.seasonNumber) 赛季"))
            } }
        }
        league.ongoingSeason = nil
        league.nextSeasonNumber += 1
        league.updatedAt = Date()
    }

}
