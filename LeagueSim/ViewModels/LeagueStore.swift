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
    func enterArchive(id: UUID) {
        if let current = currentLeague { save(current) }
        guard let league = ArchiveStore.loadLeague(id: id) else { return }
        currentLeague = league
        ArchiveStore.saveCurrentArchiveId(id)
        refreshArchives()
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
}
