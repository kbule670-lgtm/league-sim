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
    // 切换在后台解码，失败弹具体错误，重复点按直接忽略。
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
                // 一次性迁移：老存档第一次打开时把自动交易翻成开（默认开），之后用户自己关了也不会再被翻回来。
                var migrated = league
                var didMigrate = false
                if !migrated.settings.autoTradeDefaultApplied {
                    migrated.settings.autoTradeEnabled = true
                    migrated.settings.autoTradeDefaultApplied = true
                    if var ongoing = migrated.ongoingSeason {
                        ongoing.settings.autoTradeEnabled = true
                        ongoing.settings.autoTradeDefaultApplied = true
                        migrated.ongoingSeason = ongoing
                    }
                    didMigrate = true
                }
                currentLeague = migrated
                ArchiveStore.saveCurrentArchiveId(id)
                refreshArchives()
                if didMigrate { save(migrated) }
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
            guard !slot.player.isRetired else { return }
            guard !league.teams[toIndex].roster.contains(where: { $0.player.id == playerId }),
                  !league.teams[toIndex].roster.contains(
                    where: { $0.player.jerseyNumber == slot.player.jerseyNumber }) else { return }
            league.teams[fromIndex].roster.remove(at: slotIndex)
            let nextOrder = (league.teams[toIndex].roster.map { $0.rotationOrder }.max() ?? 0) + 1
            var moved = slot
            moved.status = status
            moved.rotationOrder = nextOrder
            league.teams[toIndex].roster.append(moved)
            league.tradeHistory.append(TradeRecord(seasonNumber: league.nextSeasonNumber - 1, fromTeamName: league.teams[fromIndex].name, toTeamName: league.teams[toIndex].name, outPlayerNames: [slot.player.name], inPlayerNames: [], isAuto: false))
            success = true
        }
        return success
    }

    // 排序时首发/替补互移：在整张上场名单里换位，排进前 5 名的就是首发，
    // 第 6 名起是替补；inactive 不动，轮换顺序整队重排。
    func moveActivePlayer(in teamId: UUID, from source: IndexSet, to destination: Int) {
        updateCurrent { league in
            guard let teamIndex = league.teams.firstIndex(where: { $0.id == teamId }) else { return }
            var roster = league.teams[teamIndex].roster
            var active = roster.filter { $0.status.isActive }.sorted { $0.rotationOrder < $1.rotationOrder }
            active.move(fromOffsets: source, toOffset: destination)
            var order = 1
            for (index, slot) in active.enumerated() {
                if let idx = roster.firstIndex(where: { $0.player.id == slot.player.id }) {
                    roster[idx].status = index < 5 ? .starter : .bench
                    roster[idx].rotationOrder = order
                    order += 1
                }
            }
            let inactive = roster.filter { $0.status == .inactive }.sorted { $0.rotationOrder < $1.rotationOrder }
            for slot in inactive {
                if let idx = roster.firstIndex(where: { $0.player.id == slot.player.id }) {
                    roster[idx].rotationOrder = order
                    order += 1
                }
            }
            league.teams[teamIndex].roster = roster
        }
    }

    // 出手权：设某个球员的手动权重（nil = 恢复自动，按总评算）。
    func setShotWeight(in teamId: UUID, playerId: UUID, weight: Double?) {
        updateCurrent { league in
            guard let teamIndex = league.teams.firstIndex(where: { $0.id == teamId }),
                  let slotIndex = league.teams[teamIndex].roster.firstIndex(where: { $0.player.id == playerId }) else { return }
            league.teams[teamIndex].roster[slotIndex].shotWeight = weight
        }
    }

    // 出手权：整队恢复自动。
    func resetAllShotWeights(in teamId: UUID) {
        updateCurrent { league in
            guard let teamIndex = league.teams.firstIndex(where: { $0.id == teamId }) else { return }
            for i in league.teams[teamIndex].roster.indices {
                league.teams[teamIndex].roster[i].shotWeight = nil
            }
        }
    }

    // 拖动排序：把同一组（首发/替补/inactive）里的球员换位，轮换顺序整队重排
    // （首发、替补、inactive 依次编号，总评越高上场时间越长）。
    // 跨组移动不走这里：改首发/替补仍用行里的状态菜单。
    func movePlayers(in teamId: UUID, from source: IndexSet, to destination: Int, status: RosterStatus) {
        updateCurrent { league in
            guard let teamIndex = league.teams.firstIndex(where: { $0.id == teamId }) else { return }
            var roster = league.teams[teamIndex].roster
            var group = roster.filter { $0.status == status }.sorted { $0.rotationOrder < $1.rotationOrder }
            group.move(fromOffsets: source, toOffset: destination)
            var order = 1
            for st in [RosterStatus.starter, .bench, .inactive] {
                let slots = st == status ? group : roster.filter { $0.status == st }.sorted { $0.rotationOrder < $1.rotationOrder }
                for slot in slots {
                    if let idx = roster.firstIndex(where: { $0.player.id == slot.player.id }) {
                        roster[idx].rotationOrder = order
                        order += 1
                    }
                }
            }
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
                let player = Player(name: "测试球员 \(offset + 1)", jerseyNumber: "\(offset + 1)",
                                    position: position, age: 24 + offset % 8,
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
                    let player = Player(name: "测试球员 \(offset + 1)", jerseyNumber: "\(offset + 1)",
                                        position: position, age: 24 + offset % 8,
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

    // 清除历史：清赛季快照、进行中的赛季、交易记录和球员的个人荣誉，球员名单和球队资料保留。
    func clearHistory() {
        updateCurrent { league in
            league.seasons = []
            league.ongoingSeason = nil
            league.tradeHistory = []
            league.nextSeasonNumber = 1
            for ti in league.teams.indices { for si in league.teams[ti].roster.indices {
                league.teams[ti].roster[si].player.honors = []
            } }
        }
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
            guard !outSlots.contains(where: { $0.player.isRetired }) && !inSlots.contains(where: { $0.player.isRetired }) else { return }
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
            league.tradeHistory.append(TradeRecord(seasonNumber: league.nextSeasonNumber - 1, fromTeamName: league.teams[fromIndex].name, toTeamName: league.teams[toIndex].name, outPlayerNames: outSlots.map { $0.player.name }, inPlayerNames: inSlots.map { $0.player.name }, isAuto: false))
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
        let pairs = SimulationEngine.shuffledSchedule(SimulationEngine.regularSeasonSchedule(participants: participants), seed: seed)
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

    private func playRegularScheduled(_ league: inout League, scheduled: ScheduledGame, precomputedRatings: ([UUID: Double], Double)? = nil) {
        guard var ongoing = league.ongoingSeason else { return }
        guard let home = league.teams.first(where: { $0.id == scheduled.homeTeamId }),
              let away = league.teams.first(where: { $0.id == scheduled.awayTeamId }) else { return }
        guard !home.activeRoster.isEmpty && !away.activeRoster.isEmpty else { return }
        let (ratings, avg): ([UUID: Double], Double)
        if let pre = precomputedRatings {
            (ratings, avg) = pre
        } else {
            let participants = league.teams.filter { $0.activeRoster.count >= 5 }
            (ratings, avg) = ratingsForOngoing(league, participants: participants)
        }
        var rng = SeededRandom(seed: ongoing.seed &+ Int64(scheduled.index + 1) * 1000003)
        var rest = ongoing.restCounts
        let game = SimulationEngine.playSingleGame(home: home, away: away, ratings: ratings, leagueAverage: avg, settings: ongoing.settings, isPlayoff: false, restCounts: &rest, rng: &rng)
        ongoing.restCounts = rest
        ongoing.playedGames.append(game)
        if let idx = ongoing.schedule.firstIndex(where: { $0.id == scheduled.id }) { ongoing.schedule[idx].playedGameId = game.id }
        // 体力：打完这场就地更新（上场掉体力、轮休回体力），存进两队名单里。
        let percentiles = SimulationEngine.durabilityPercentiles(teams: league.teams)
        if let homeIdx = league.teams.firstIndex(where: { $0.id == home.id }) {
            SimulationEngine.applyStamina(for: &league.teams[homeIdx], game: game, durabilityPercentile: percentiles, isPlayoff: false, rng: &rng)
        }
        if let awayIdx = league.teams.firstIndex(where: { $0.id == away.id }) {
            SimulationEngine.applyStamina(for: &league.teams[awayIdx], game: game, durabilityPercentile: percentiles, isPlayoff: false, rng: &rng)
        }
        maybeRunMidSeasonTrades(league: &league, ongoing: &ongoing)
        league.ongoingSeason = ongoing
    }

    // 常规赛打完：季后赛进“待确认首轮”，并把首轮 8 组对阵填进对阵图（0-0，未决出）。
    private func finishRegularSeasonIfComplete(_ league: inout League) {
        guard var ongoing = league.ongoingSeason, ongoing.playoffRound == 0,
              ongoing.schedule.allSatisfy({ $0.playedGameId != nil }) else { return }
        ongoing.playoffRound = 1
        setupPlayoffFirstRound(league: league, ongoing: &ongoing)
        league.ongoingSeason = ongoing
    }

    // 按常规赛排名排首轮：东部前 8、西部前 8，1v8、4v5、3v6、2v7。
    private func setupPlayoffFirstRound(league: League, ongoing: inout OngoingSeason) {
        let participants = league.teams.filter { $0.activeRoster.count >= 5 }
        let regularStats = SimulationEngine.aggregateTeamStats(games: ongoing.playedGames, participants: participants)
        let east = SimulationEngine.sortedStandings(participants: participants.filter { SimulationEngine.conference(for: $0, in: participants) == .east }, teamStats: regularStats)
        let west = SimulationEngine.sortedStandings(participants: participants.filter { SimulationEngine.conference(for: $0, in: participants) == .west }, teamStats: regularStats)
        guard east.count >= 8 && west.count >= 8 else { return }
        var series: [PlayoffSeries] = []
        for (standings, conferenceName) in [(east, "东部"), (west, "西部")] {
            let seeds = Array(standings.prefix(8))
            for (hi, li) in [(0, 7), (3, 4), (2, 5), (1, 6)] {
                let higher = seeds[hi]; let lower = seeds[li]
                series.append(PlayoffSeries(id: UUID(), round: "首轮", conference: conferenceName, higherSeed: hi + 1, higherSeedTeamId: higher.id, higherSeedTeamName: higher.name, lowerSeed: li + 1, lowerSeedTeamId: lower.id, lowerSeedTeamName: lower.name, higherWins: 0, lowerWins: 0, winnerTeamId: UUID(), winnerTeamName: "", gameIds: []))
            }
        }
        ongoing.playoffSeries = series
    }

    func simulateRegularGame(scheduledId: UUID) {
        updateCurrent { league in
            guard let ongoing = league.ongoingSeason,
                  let scheduled = ongoing.schedule.first(where: { $0.id == scheduledId && $0.playedGameId == nil }) else { return }
            playRegularScheduled(&league, scheduled: scheduled)
            finishRegularSeasonIfComplete(&league)
        }
    }

    // 单场模拟并返回打完的比赛（虚拟播报用：先模拟出结果，再播这场比赛）。
    func simulateRegularGameReturning(scheduledId: UUID) -> Game? {
        var result: Game? = nil
        updateCurrent { league in
            guard let ongoing = league.ongoingSeason,
                  let scheduled = ongoing.schedule.first(where: { $0.id == scheduledId && $0.playedGameId == nil }) else { return }
            playRegularScheduled(&league, scheduled: scheduled)
            finishRegularSeasonIfComplete(&league)
            if let gameId = league.ongoingSeason?.schedule.first(where: { $0.id == scheduledId })?.playedGameId {
                result = league.ongoingSeason?.playedGames.first { $0.id == gameId }
            }
        }
        return result
    }

    func simulateRegularGamesUpTo(scheduledId: UUID) {
        updateCurrent { league in
            guard let ongoing = league.ongoingSeason,
                  let target = ongoing.schedule.first(where: { $0.id == scheduledId }) else { return }
            let targets = ongoing.schedule.filter { $0.index <= target.index && $0.playedGameId == nil }.sorted { $0.index < $1.index }
            let participants = league.teams.filter { $0.activeRoster.count >= 5 }
            let pre = ratingsForOngoing(league, participants: participants)
            for scheduled in targets { playRegularScheduled(&league, scheduled: scheduled, precomputedRatings: pre) }
            finishRegularSeasonIfComplete(&league)
        }
    }

    func simulateAllRegular() {
        updateCurrent { league in
            guard let ongoing = league.ongoingSeason else { return }
            let targets = ongoing.schedule.filter { $0.playedGameId == nil }.sorted { $0.index < $1.index }
            let participants = league.teams.filter { $0.activeRoster.count >= 5 }
            let pre = ratingsForOngoing(league, participants: participants)
            for scheduled in targets { playRegularScheduled(&league, scheduled: scheduled, precomputedRatings: pre) }
            // 常规赛打完后，季后赛进入“待确认首轮”状态，不自动开打。
            finishRegularSeasonIfComplete(&league)
        }
    }

    func simulateNextRegularGame() {
        updateCurrent { league in
            guard let ongoing = league.ongoingSeason,
                  let next = ongoing.schedule.filter({ $0.playedGameId == nil }).sorted(by: { $0.index < $1.index }).first else { return }
            playRegularScheduled(&league, scheduled: next)
            finishRegularSeasonIfComplete(&league)
        }
    }

    // 季后赛逐轮确认：每轮打完停下来，等用户点下一轮。总决赛打完直接结算赛季。
    // 季后赛逐场 / 逐组 / 逐轮：常规赛打完首轮对阵已填好，点一组对决可以只打一场、打完整组、或打完本轮；
    // 分出胜负自动填进下一轮。确认开始某轮就是“模拟一轮”。
    func simulateOnePlayoffGame(seriesId: UUID) {
        updateCurrent { league in
            guard var ongoing = league.ongoingSeason else { return }
            guard playOnePlayoffGameInLeague(&league, ongoing: &ongoing, seriesId: seriesId) else { return }
            league.ongoingSeason = ongoing
            finishSeasonIfFinalsDecided(&league)
        }
    }

    func simulateOnePlayoffSeries(seriesId: UUID) {
        updateCurrent { league in
            guard var ongoing = league.ongoingSeason else { return }
            var guardCount = 0
            while guardCount < 7 {
                guard let series = ongoing.playoffSeries.first(where: { $0.id == seriesId }), !series.isDecided else { break }
                guard playOnePlayoffGameInLeague(&league, ongoing: &ongoing, seriesId: seriesId) else { break }
                guardCount += 1
            }
            league.ongoingSeason = ongoing
            finishSeasonIfFinalsDecided(&league)
        }
    }

    // 模拟一轮：把当前轮次还没打完的组全部打完（东西部一起），打完进下一轮；总决赛打完自动结算。
    func simulatePlayoffRound() {
        updateCurrent { league in
            guard var ongoing = league.ongoingSeason, ongoing.playoffRound >= 1, ongoing.playoffRound <= 4 else { return }
            // 先补齐缺的对阵（老存档可能只有比分、没有下一轮的对阵）。
            advancePlayoffIfNeeded(league: league, ongoing: &ongoing)
            let roundName = SimulationEngine.playoffRoundName(ongoing.playoffRound)
            for series in ongoing.playoffSeries.filter({ $0.round == roundName && !$0.isDecided }) {
                var guardCount = 0
                while guardCount < 7 {
                    guard let current = ongoing.playoffSeries.first(where: { $0.id == series.id }), !current.isDecided else { break }
                    guard playOnePlayoffGameInLeague(&league, ongoing: &ongoing, seriesId: series.id) else { break }
                    guardCount += 1
                }
            }
            league.ongoingSeason = ongoing
            finishSeasonIfFinalsDecided(&league)
        }
    }

    // 季后赛逐轮确认：每轮打完停下来，等用户点下一轮。总决赛打完直接结算赛季。
    func playNextPlayoffRound() {
        simulatePlayoffRound()
    }

    // 打一场季后赛：找到该组、按主客场打一场、更新比分与体力；决出胜者后尝试排下一轮。返回是否打了一场。
    private func playOnePlayoffGameInLeague(_ league: inout League, ongoing: inout OngoingSeason, seriesId: UUID) -> Bool {
        guard let seriesIndex = ongoing.playoffSeries.firstIndex(where: { $0.id == seriesId }),
              !ongoing.playoffSeries[seriesIndex].isDecided else { return false }
        let series = ongoing.playoffSeries[seriesIndex]
        guard let higher = league.teams.first(where: { $0.id == series.higherSeedTeamId }),
              let lower = league.teams.first(where: { $0.id == series.lowerSeedTeamId }) else { return false }
        let participants = league.teams.filter { $0.activeRoster.count >= 5 }
        let (ratings, avg) = ratingsForOngoing(league, participants: participants)
        var rng = SeededRandom(seed: ongoing.seed &+ Int64(ongoing.playoffGames.count + 1) * 1000003)
        var rest = ongoing.restCounts
        let result = SimulationEngine.playOneSeriesGame(series: series, higher: higher, lower: lower, ratings: ratings, leagueAverage: avg, settings: ongoing.settings, rng: &rng, restCounts: &rest)
        ongoing.restCounts = rest
        ongoing.playoffSeries[seriesIndex] = result.series
        ongoing.playoffGames.append(result.game)
        // 体力：季后赛打一场掉体力，不恢复。
        let percentiles = SimulationEngine.durabilityPercentiles(teams: league.teams)
        if let hi = league.teams.firstIndex(where: { $0.id == higher.id }) {
            SimulationEngine.applyStamina(for: &league.teams[hi], game: result.game, durabilityPercentile: percentiles, isPlayoff: true, rng: &rng)
        }
        if let li = league.teams.firstIndex(where: { $0.id == lower.id }) {
            SimulationEngine.applyStamina(for: &league.teams[li], game: result.game, durabilityPercentile: percentiles, isPlayoff: true, rng: &rng)
        }
        if result.series.isDecided {
            advancePlayoffIfNeeded(league: league, ongoing: &ongoing)
        }
        return true
    }

    // 有一组分出胜负后，看下一轮能不能排出来：两组上家都决出了，就把胜者填进下一轮；轮次随之推进。
    // 首轮没对阵时（老存档）先按排名排首轮。
    private func advancePlayoffIfNeeded(league: League, ongoing: inout OngoingSeason) {
        if ongoing.playoffSeries.filter({ $0.round == "首轮" }).isEmpty {
            setupPlayoffFirstRound(league: league, ongoing: &ongoing)
        }
        let participants = league.teams.filter { $0.activeRoster.count >= 5 }
        let regularStats = SimulationEngine.aggregateTeamStats(games: ongoing.playedGames, participants: participants)
        func standings(for conferenceName: String) -> [Team] {
            SimulationEngine.sortedStandings(participants: participants.filter { SimulationEngine.conference(for: $0, in: participants).rawValue == conferenceName }, teamStats: regularStats)
        }
        func seedOf(_ team: Team, in standings: [Team]) -> Int { (standings.firstIndex(where: { $0.id == team.id }) ?? 0) + 1 }
        func team(for id: UUID) -> Team? { league.teams.first { $0.id == id } }
        // 半决赛：某分区首轮 4 组全决出，排 2 组（上半区 1v8/4v5 胜者，下半区 2v7/3v6 胜者）。
        for conferenceName in ["东部", "西部"] {
            let firstRound = ongoing.playoffSeries.filter { $0.round == "首轮" && $0.conference == conferenceName }
            guard firstRound.count == 4 && firstRound.allSatisfy({ $0.isDecided }) else { continue }
            guard ongoing.playoffSeries.filter({ $0.round == "分区半决赛" && $0.conference == conferenceName }).isEmpty else { continue }
            let slot: [Int: Int] = [1: 0, 4: 1, 3: 2, 2: 3]
            let ordered = firstRound.sorted { (slot[$0.higherSeed] ?? $0.higherSeed) < (slot[$1.higherSeed] ?? $1.higherSeed) }
            let winners = ordered.compactMap { team(for: $0.winnerTeamId) }
            guard winners.count == 4 else { continue }
            let confStandings = standings(for: conferenceName)
            for (a, b) in [(winners[0], winners[1]), (winners[2], winners[3])] {
                let (higher, lower) = seedOf(a, in: confStandings) <= seedOf(b, in: confStandings) ? (a, b) : (b, a)
                ongoing.playoffSeries.append(PlayoffSeries(id: UUID(), round: "分区半决赛", conference: conferenceName, higherSeed: seedOf(higher, in: confStandings), higherSeedTeamId: higher.id, higherSeedTeamName: higher.name, lowerSeed: seedOf(lower, in: confStandings), lowerSeedTeamId: lower.id, lowerSeedTeamName: lower.name, higherWins: 0, lowerWins: 0, winnerTeamId: UUID(), winnerTeamName: "", gameIds: []))
            }
        }
        // 分区决赛：某分区半决赛 2 组全决出，排 1 组。
        for conferenceName in ["东部", "西部"] {
            let semis = ongoing.playoffSeries.filter { $0.round == "分区半决赛" && $0.conference == conferenceName }
            guard semis.count == 2 && semis.allSatisfy({ $0.isDecided }) else { continue }
            guard ongoing.playoffSeries.filter({ $0.round == "分区决赛" && $0.conference == conferenceName }).isEmpty else { continue }
            let winners = semis.compactMap { team(for: $0.winnerTeamId) }
            guard winners.count == 2 else { continue }
            let confStandings = standings(for: conferenceName)
            let (higher, lower) = seedOf(winners[0], in: confStandings) <= seedOf(winners[1], in: confStandings) ? (winners[0], winners[1]) : (winners[1], winners[0])
            ongoing.playoffSeries.append(PlayoffSeries(id: UUID(), round: "分区决赛", conference: conferenceName, higherSeed: seedOf(higher, in: confStandings), higherSeedTeamId: higher.id, higherSeedTeamName: higher.name, lowerSeed: seedOf(lower, in: confStandings), lowerSeedTeamId: lower.id, lowerSeedTeamName: lower.name, higherWins: 0, lowerWins: 0, winnerTeamId: UUID(), winnerTeamName: "", gameIds: []))
        }
        // 总决赛：两分区决赛都决出，排 1 组（常规赛战绩好的当高种子）。
        let eastFinal = ongoing.playoffSeries.first { $0.round == "分区决赛" && $0.conference == "东部" }
        let westFinal = ongoing.playoffSeries.first { $0.round == "分区决赛" && $0.conference == "西部" }
        if let eastFinal, let westFinal, eastFinal.isDecided, westFinal.isDecided,
           ongoing.playoffSeries.filter({ $0.round == "总决赛" }).isEmpty,
           let eastChampion = team(for: eastFinal.winnerTeamId),
           let westChampion = team(for: westFinal.winnerTeamId) {
            let eastWins = regularStats.first(where: { $0.teamId == eastChampion.id })?.wins ?? 0
            let westWins = regularStats.first(where: { $0.teamId == westChampion.id })?.wins ?? 0
            let eastDiff = regularStats.first(where: { $0.teamId == eastChampion.id })?.pointDiff ?? 0
            let westDiff = regularStats.first(where: { $0.teamId == westChampion.id })?.pointDiff ?? 0
            let eastStandings = standings(for: "东部")
            let westStandings = standings(for: "西部")
            let eastIsHigher = eastWins > westWins || (eastWins == westWins && eastDiff >= westDiff)
            let higher = eastIsHigher ? eastChampion : westChampion
            let lower = eastIsHigher ? westChampion : eastChampion
            let higherSeed = eastIsHigher ? seedOf(eastChampion, in: eastStandings) : seedOf(westChampion, in: westStandings)
            let lowerSeed = eastIsHigher ? seedOf(westChampion, in: westStandings) : seedOf(eastChampion, in: eastStandings)
            ongoing.playoffSeries.append(PlayoffSeries(id: UUID(), round: "总决赛", conference: "总决赛", higherSeed: higherSeed, higherSeedTeamId: higher.id, higherSeedTeamName: higher.name, lowerSeed: lowerSeed, lowerSeedTeamId: lower.id, lowerSeedTeamName: lower.name, higherWins: 0, lowerWins: 0, winnerTeamId: UUID(), winnerTeamName: "", gameIds: []))
        }
        // 轮次推进到最早还有没打完的组的那轮；全打完保持 4，等结算。
        for (round, name) in [(1, "首轮"), (2, "分区半决赛"), (3, "分区决赛"), (4, "总决赛")] {
            if ongoing.playoffSeries.contains(where: { $0.round == name && !$0.isDecided }) {
                ongoing.playoffRound = round
                return
            }
        }
        ongoing.playoffRound = 4
    }

    // 总决赛决出胜者就结算本赛季（奖项、快照、新赛季准备）。
    private func finishSeasonIfFinalsDecided(_ league: inout League) {
        guard let ongoing = league.ongoingSeason,
              let finals = ongoing.playoffSeries.first(where: { $0.round == "总决赛" }),
              finals.isDecided else { return }
        finishOngoingSeason(&league)
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
        let championId = ongoing.playoffSeries.last(where: { $0.round == "总决赛" })?.winnerTeamId
        let championName = ongoing.playoffSeries.last(where: { $0.round == "总决赛" })?.winnerTeamName
        let conferenceMap = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, SimulationEngine.conference(for: $0, in: participants).rawValue) })
        let computed = SimulationEngine.computeAwards(regularPlayerStats: regularPlayerStats, regularTeamStats: regularTeamStats, playoffGames: ongoing.playoffGames, finalsGames: finalsGames, snapshotId: snapshotId, positionMap: positionMap, championTeamId: championId, conferenceMap: conferenceMap)
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
        // 最佳阵容记入球员荣誉：一阵/二阵/三阵按名字 + 队名对上当前名单里的人。
        for (tier, entries) in [("最佳一阵", computed.first), ("最佳二阵", computed.second), ("最佳三阵", computed.third)] {
            for entry in entries {
                for ti in league.teams.indices { for si in league.teams[ti].roster.indices where league.teams[ti].roster[si].player.name == entry.playerName && league.teams[ti].name == entry.teamName {
                    let p = league.teams[ti].roster[si].player
                    if !p.honors.contains(where: { $0.type == tier && $0.seasonNumber == ongoing.seasonNumber }) {
                        league.teams[ti].roster[si].player.honors.append(PlayerHonor(type: tier, seasonNumber: ongoing.seasonNumber, teamName: entry.teamName, detail: entry.position))
                    }
                } }
            }
        }
        if let cid = championId, let cname = championName {
            for ti in league.teams.indices where league.teams[ti].id == cid { for si in league.teams[ti].roster.indices {
                league.teams[ti].roster[si].player.honors.append(PlayerHonor(type: "总冠军", seasonNumber: ongoing.seasonNumber, teamName: cname, detail: "第 \(ongoing.seasonNumber) 赛季"))
            } }
        }
        // 赛季结束：年龄 +1，真实模式按潜力和数据成长/下滑，37 岁以上场均 <5 分退役，开启自动交易时跑自动交易。
        applySeasonEndChanges(&league, seasonNumber: ongoing.seasonNumber, seasonStats: regularPlayerStats, seed: ongoing.seed)
        league.ongoingSeason = nil
        league.nextSeasonNumber += 1
        league.updatedAt = Date()
    }

    // 赛季结束处理：年龄 +1；真实模式 23-30 岁上涨、35 岁起下滑；37 岁以上场均 <5 分退役。
    private func applySeasonEndChanges(_ league: inout League, seasonNumber: Int, seasonStats: [PlayerSeasonStat], seed: Int64) {
        let ppgMap = Dictionary(uniqueKeysWithValues: seasonStats.map { ($0.playerId, $0.pointsPerGame) })
        let attributePaths: [WritableKeyPath<Attributes, Int>] = [\.threePoint, \.midRange, \.finishing, \.freeThrow, \.playmaking, \.rebounding, \.perimeterDefense, \.rimProtection, \.athleticism, \.basketballIQ]
        for ti in league.teams.indices {
            for si in league.teams[ti].roster.indices {
                var player = league.teams[ti].roster[si].player
                player.age += 1
                let ppg = ppgMap[player.id] ?? 0
                // 潜力值为 0 的球员不随年龄增长改数值：真实模式的涨/跌都跳过（年龄 +1 和退役照常）。
                if league.settings.developmentMode == "真实" && player.attributes.potential != 0 {
                    if (23...30).contains(player.age) {
                        var gain = player.attributes.potential >= 85 ? 2 : (player.attributes.potential >= 75 ? 1 : 0)
                        if ppg >= 20 { gain += 1 }
                        gain = min(gain, 3)
                        if gain > 0 {
                            // 涨最弱的 4 项（不含潜力），小幅上涨。
                            let weakest = attributePaths.sorted { player.attributes[keyPath: $0] < player.attributes[keyPath: $1] }.prefix(4)
                            for path in weakest { player.attributes[keyPath: path] = min(99, player.attributes[keyPath: path] + gain) }
                            if let manual = player.overallOverride { player.overallOverride = min(99, manual + gain) }
                        }
                    } else if player.age >= 35 {
                        var decline = 1
                        if ppg < 10 { decline += 1 }
                        if player.age >= 38 { decline += 1 }
                        decline = min(decline, 3)
                        let strongest = attributePaths.sorted { player.attributes[keyPath: $0] > player.attributes[keyPath: $1] }.prefix(4)
                        for path in strongest { player.attributes[keyPath: path] = max(0, player.attributes[keyPath: path] - decline) }
                        if let manual = player.overallOverride { player.overallOverride = max(0, manual - decline) }
                    }
                }
                if player.age >= 37 && ppg < 5 {
                    player.isRetired = true
                    league.teams[ti].roster[si].status = .inactive
                }
                league.teams[ti].roster[si].player = player
            }
        }
        // 赛季结束按能力自动排首发和轮换：首发按位置取总评最高，轮换按总评排，球权本来就按总评相对值算。
        autoUpdateLineups(&league)
        // 新赛季体力全员回满 100。
        for ti in league.teams.indices {
            for si in league.teams[ti].roster.indices {
                league.teams[ti].roster[si].stamina = 100
            }
        }
    }

    // 按能力自动排首发：每个位置取总评最高的那人当首发，其余激活球员按总评排替补；
    // 轮换顺序按总评排（总评越高上场时间越长，球权也按总评相对值分）。
    // 某个位置没人时，用剩余总评最高的人顶首发；退役/inactive 的人不动。
    func autoUpdateLineups(for teamId: UUID) {
        updateCurrent { league in
            if let idx = league.teams.firstIndex(where: { $0.id == teamId }) {
                autoUpdateLineupsForTeam(&league.teams[idx])
            }
        }
    }

    private func autoUpdateLineups(_ league: inout League) {
        for ti in league.teams.indices { autoUpdateLineupsForTeam(&league.teams[ti]) }
    }

    private func autoUpdateLineupsForTeam(_ team: inout Team) {
        var active = team.roster.filter { $0.status.isActive && !$0.player.isRetired }
        guard !active.isEmpty else { return }
        active.sort { Rating.overall(for: $0.player) > Rating.overall(for: $1.player) }
        var starterIds: Set<UUID> = []
        for pos in Position.allCases {
            if let best = active.first(where: { $0.player.position == pos && !starterIds.contains($0.player.id) }) {
                starterIds.insert(best.player.id)
            }
        }
        // 位置缺人时按总评补齐 5 名首发。
        for slot in active where starterIds.count < 5 && !starterIds.contains(slot.player.id) {
            starterIds.insert(slot.player.id)
        }
        var order = 1
        for slot in active.sorted(by: { Rating.overall(for: $0.player) > Rating.overall(for: $1.player) }) {
            if let idx = team.roster.firstIndex(where: { $0.player.id == slot.player.id }) {
                team.roster[idx].status = starterIds.contains(slot.player.id) ? .starter : .bench
                team.roster[idx].rotationOrder = order
                order += 1
            }
        }
        for idx in team.roster.indices where !team.roster[idx].status.isActive || team.roster[idx].player.isRetired {
            team.roster[idx].rotationOrder = order
            order += 1
        }
    }

    // 自动交易：赛季结束尝试换队，每队 5 个位置各至少 2 人、单队 95+ 不超过 2 人才成交，最多成交 8 笔。
    // 自动交易（常规赛进行中）：总场次到 300/600/900 时开一个窗口（约每队打了 20/40/60 场），
    // 每队每赛季 1-2 笔；一次互换两边各记 1 笔。交易双方总评差距 <= 8，以补强为目的：
    // 用本队最弱首发，换对方同位置总评高 1-8 的球员；位置人数与 95+ 人数上限不变。
    private func maybeRunMidSeasonTrades(league: inout League, ongoing: inout OngoingSeason) {
        guard ongoing.settings.autoTradeEnabled else { return }
        let windows = [300, 600, 900]
        guard ongoing.tradeWindowsDone < windows.count,
              ongoing.playedGames.count >= windows[ongoing.tradeWindowsDone] else { return }
        ongoing.tradeWindowsDone += 1
        var rng = SeededRandom(seed: ongoing.seed &+ Int64(ongoing.seasonNumber) * 7919 &+ Int64(ongoing.tradeWindowsDone) * 104729)
        func positionOK(teams: [Team]) -> Bool {
            for team in teams {
                let active = team.roster.filter { $0.status.isActive && !$0.player.isRetired }
                for pos in Position.allCases {
                    if active.filter({ $0.player.position == pos }).count < 2 { return false }
                }
                if active.filter({ Rating.overall(for: $0.player) > 95 }).count > 2 { return false }
            }
            return true
        }
        // 随机顺序过一遍还没满 2 笔的队，每队最多谈成 1 笔。
        var order = Array(league.teams.indices)
        for i in stride(from: order.count - 1, through: 1, by: -1) {
            order.swapAt(i, rng.nextInt(in: 0...i))
        }
        for a in order {
            let aKey = league.teams[a].id.uuidString
            guard (ongoing.tradeCounts[aKey] ?? 0) < 2 else { continue }
            let aStarters = league.teams[a].roster.indices.filter { league.teams[a].roster[$0].status == .starter && !league.teams[a].roster[$0].player.isRetired }
            guard let ai = aStarters.min(by: { Rating.overall(for: league.teams[a].roster[$0].player) < Rating.overall(for: league.teams[a].roster[$1].player) }) else { continue }
            let slotA = league.teams[a].roster[ai]
            let ratingA = Rating.overall(for: slotA.player)
            var candidates: [(b: Int, bi: Int, bCount: Int)] = []
            for b in league.teams.indices where b != a {
                let bCount = ongoing.tradeCounts[league.teams[b].id.uuidString] ?? 0
                for bi in league.teams[b].roster.indices {
                    let slotB = league.teams[b].roster[bi]
                    guard slotB.status.isActive, !slotB.player.isRetired,
                          slotB.player.position == slotA.player.position else { continue }
                    let ratingB = Rating.overall(for: slotB.player)
                    guard ratingB > ratingA && ratingB - ratingA <= 8 else { continue }
                    candidates.append((b, bi, bCount))
                }
            }
            let preferred = candidates.filter { $0.bCount < 2 }
            let pool = preferred.isEmpty ? candidates : preferred
            guard !pool.isEmpty else { continue }
            let pick = pool[rng.nextInt(in: 0...(pool.count - 1))]
            var trial = league.teams
            let slotB = trial[pick.b].roster[pick.bi]
            trial[a].roster[ai] = slotB
            trial[pick.b].roster[pick.bi] = slotA
            guard positionOK(teams: [trial[a], trial[pick.b]]) else { continue }
            let nameA = slotA.player.name
            let nameB = slotB.player.name
            let fromName = league.teams[a].name
            let toName = league.teams[pick.b].name
            league.teams = trial
            league.tradeHistory.append(TradeRecord(seasonNumber: ongoing.seasonNumber, fromTeamName: fromName, toTeamName: toName, outPlayerNames: [nameA], inPlayerNames: [nameB], isAuto: true))
            ongoing.tradeCounts[aKey, default: 0] += 1
            ongoing.tradeCounts[league.teams[pick.b].id.uuidString, default: 0] += 1
        }
    }

}
