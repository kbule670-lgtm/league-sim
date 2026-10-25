import SwiftUI

// 中途交易（手动控制）：选出队、选球员、选入队、选到队后的状态，确认后球员换队。
// 不自动交易、不自动改球衣号：入队已有相同球衣号时，按钮禁用，先去球员编辑里改号。
// 球员 ID 换队前后不变；已跑完的赛季快照不改写，下一赛季的统计记在新队下。
struct TradeView: View {
    @EnvironmentObject private var store: LeagueStore
    @State private var sourceTeamId: UUID?
    @State private var playerId: UUID?
    @State private var destinationTeamId: UUID?
    @State private var destinationStatus: RosterStatus = .bench
    @State private var resultMessage = ""

    private var league: League? { store.currentLeague }
    private var sourceTeam: Team? {
        league?.teams.first { $0.id == sourceTeamId }
    }
    private var destinationTeam: Team? {
        league?.teams.first { $0.id == destinationTeamId }
    }
    private var selectedSlot: RosterSlot? {
        sourceTeam?.roster.first { $0.player.id == playerId }
    }
    private var hasJerseyConflict: Bool {
        guard let slot = selectedSlot, let dest = destinationTeam else { return false }
        return dest.roster.contains { $0.player.jerseyNumber == slot.player.jerseyNumber }
    }

    var body: some View {
        Form {
            if let league {
                Section("出队") {
                    Picker("出队", selection: Binding(
                        get: { sourceTeamId ?? league.teams.first?.id },
                        set: { sourceTeamId = $0; playerId = nil }
                    )) {
                        ForEach(league.teams) { team in
                            Text(team.name).tag(team.id as UUID?)
                        }
                    }
                }
                Section("球员") {
                    if let source = sourceTeam {
                        Picker("球员", selection: $playerId) {
                            ForEach(source.roster.sorted { $0.rotationOrder < $1.rotationOrder }) { slot in
                                Text("\(slot.player.name) · #\(slot.player.jerseyNumber) · \(slot.status.rawValue)")
                                    .tag(slot.player.id as UUID?)
                            }
                        }
                    } else {
                        Text("先选出队").foregroundStyle(.secondary)
                    }
                }
                Section("入队") {
                    Picker("入队", selection: Binding(
                        get: { destinationTeamId ?? league.teams.first { $0.id != sourceTeamId }?.id },
                        set: { destinationTeamId = $0 }
                    )) {
                        ForEach(league.teams.filter { $0.id != sourceTeamId }) { team in
                            Text(team.name).tag(team.id as UUID?)
                        }
                    }
                    Picker("到队后状态", selection: $destinationStatus) {
                        ForEach(RosterStatus.allCases) { status in
                            Text(status.rawValue).tag(status)
                        }
                    }
                    if hasJerseyConflict, let slot = selectedSlot, let dest = destinationTeam {
                        Text("\(dest.name) 已有 #\(slot.player.jerseyNumber) 球衣，先去改这名球员的球衣号再交易。")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                }
                Section {
                    Button("确认交易") {
                        guard let from = sourceTeamId, let player = playerId,
                              let to = destinationTeamId else { return }
                        if store.tradePlayer(from: from, playerId: player, to: to,
                                             status: destinationStatus) {
                            resultMessage = "交易成功：球员已换队，下一赛季记在新队下，已跑完的赛季快照不变。"
                        } else {
                            resultMessage = "交易失败：请检查出队、球员、入队是否都选了，或入队球衣号是否冲突。"
                        }
                    }
                    .disabled(sourceTeamId == nil || playerId == nil || destinationTeamId == nil
                              || sourceTeamId == destinationTeamId || hasJerseyConflict)
                    if !resultMessage.isEmpty {
                        Text(resultMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("新增球员不用走交易：去球队详情点“加球员”就行，交易是已经在队里的球员换队。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("没有当前存档").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("中途交易")
        .onAppear {
            if sourceTeamId == nil { sourceTeamId = league?.teams.first?.id }
            if destinationTeamId == nil {
                destinationTeamId = league?.teams.first { $0.id != sourceTeamId }?.id
            }
        }
    }
}
