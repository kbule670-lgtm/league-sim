import SwiftUI

// 中途交易（手动控制，多选）：转出和转入都可一次选好几个人，一次成交。
// 球衣冲突按换完之后算：互换球衣号本身不算冲突，只有换完后同队内重复才算失败；
// 球员 ID 换队前后不变；已跑完的赛季快照不改写，下一赛季的统计记在新队下。
struct TradeView: View {
    @EnvironmentObject private var store: LeagueStore
    @State private var sourceTeamId: UUID?
    @State private var destinationTeamId: UUID?
    @State private var outIds: Set<UUID> = []
    @State private var inIds: Set<UUID> = []
    @State private var resultMessage = ""

    private var league: League? { store.currentLeague }
    private var sourceTeam: Team? { league?.teams.first { $0.id == sourceTeamId } }
    private var destinationTeam: Team? { league?.teams.first { $0.id == destinationTeamId } }

    var body: some View {
        Form {
            if let league {
                Section("出队") {
                    Picker("出队", selection: Binding(get: { sourceTeamId ?? league.teams.first?.id }, set: { sourceTeamId = $0; outIds = [] })) {
                        ForEach(league.teams) { team in Text(team.name).tag(team.id as UUID?) }
                    }
                }
                Section("转出（可多选，点一下选中、再点取消）") {
                    if let source = sourceTeam {
                        ForEach(source.roster.sorted { $0.rotationOrder < $1.rotationOrder }) { slot in
                            Button {
                                if outIds.contains(slot.player.id) { outIds.remove(slot.player.id) } else { outIds.insert(slot.player.id) }
                            } label: {
                                HStack { Text((outIds.contains(slot.player.id) ? "✓ " : "") + "\(slot.player.name) · #\(slot.player.jerseyNumber) · \(slot.player.position.name)"); Spacer() }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Section("入队") {
                    Picker("入队", selection: Binding(get: { destinationTeamId ?? league.teams.first { $0.id != sourceTeamId }?.id }, set: { destinationTeamId = $0; inIds = [] })) {
                        ForEach(league.teams.filter { $0.id != sourceTeamId }) { team in Text(team.name).tag(team.id as UUID?) }
                    }
                }
                Section("转入（可多选，点一下选中、再点取消；不选就是单向转出）") {
                    if let dest = destinationTeam {
                        ForEach(dest.roster.sorted { $0.rotationOrder < $1.rotationOrder }) { slot in
                            Button {
                                if inIds.contains(slot.player.id) { inIds.remove(slot.player.id) } else { inIds.insert(slot.player.id) }
                            } label: {
                                HStack { Text((inIds.contains(slot.player.id) ? "✓ " : "") + "\(slot.player.name) · #\(slot.player.jerseyNumber) · \(slot.player.position.name)"); Spacer() }
                            }.buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Button("确认交易") {
                        guard let from = sourceTeamId, let to = destinationTeamId, !outIds.isEmpty else { return }
                        if store.tradePlayersMulti(from: from, outPlayerIds: Array(outIds), to: to, inPlayerIds: Array(inIds)) {
                            resultMessage = "交易成功：已换队，下一赛季记在新队下，已跑完的赛季快照不变。"
                            outIds = []; inIds = []
                        } else {
                            resultMessage = "交易失败：换完后同队内球衣号重复，或选的人不在队里，先改球衣号再试。"
                        }
                    }
                    .disabled(sourceTeamId == nil || destinationTeamId == nil || sourceTeamId == destinationTeamId || outIds.isEmpty)
                    if !resultMessage.isEmpty { Text(resultMessage).font(.footnote).foregroundStyle(.secondary) }
                    Text("转出至少选 1 人，转入可以不选（单向转出）；互换时球衣号互换不算冲突。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("没有当前存档").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("中途交易")
        .onAppear {
            if sourceTeamId == nil { sourceTeamId = league?.teams.first?.id }
            if destinationTeamId == nil { destinationTeamId = league?.teams.first { $0.id != sourceTeamId }?.id }
        }
    }
}
