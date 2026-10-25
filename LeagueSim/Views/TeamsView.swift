import SwiftUI

// 球队列表：按分区，分组显示 30 队；分区为空的队归到“未分组”。
// 点一行进球队详情：改队资料、管名单、看校验提醒。
struct TeamsView: View {
    var league: League
    @EnvironmentObject private var store: LeagueStore

    private struct TeamGroup: Identifiable {
        var id: String { key }
        var key: String
        var teams: [Team]
    }

    private var grouped: [TeamGroup] {
        let groups = Dictionary(grouping: league.teams) { team in
            team.division.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未分组" : team.division
        }
        return groups.map { TeamGroup(key: $0.key, teams: $0.value) }.sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("中途交易（手动）") {
                    NavigationLink {
                        TradeView()
                    } label: {
                        Text("交易：球员从一队换到另一队")
                    }
                    Text("手动控制，不自动交易；球员 ID 不变，已跑完的赛季快照不改写，下一赛季记在新队下。新增球员去球队详情点“加球员”。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !Validation.leagueWarnings(for: league).isEmpty {
                    Section("联盟提醒") {
                        ForEach(Validation.leagueWarnings(for: league), id: \.self) { warning in
                            Text(warning).font(.footnote).foregroundStyle(.orange)
                        }
                    }
                }
                ForEach(grouped, id: \.key) { group in
                    Section(group.key) {
                        ForEach(group.teams) { team in
                            NavigationLink {
                                TeamDetailView(teamId: team.id)
                            } label: {
                                HStack {
                                    Circle()
                                        .fill(team.color())
                                        .frame(width: 28, height: 28)
                                        .overlay(Text(team.abbreviation.isEmpty ? "?" : team.abbreviation)
                                            .font(.caption2).foregroundStyle(.white))
                                    VStack(alignment: .leading) {
                                        Text(team.name).font(.headline)
                                        Text("激活 \(team.activeRoster.count) 人 · 首发 \(team.starters.count) 人")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if !Validation.warnings(for: team).isEmpty {
                                        Image(systemName: "exclamationmark.triangle")
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("球队")
            .toolbar {
                Button("全部填测试名单") {
                    store.fillTestRostersForAllEmptyTeams()
                }
            }
        }
    }
}

// 球队详情：队名/缩写/分区/主场/配色可改；名单分首发、替补、inactive 三段；
// 每名球员可上移/下移轮换顺序、改状态、删人；校验提醒列在顶部。
struct TeamDetailView: View {
    var teamId: UUID
    @EnvironmentObject private var store: LeagueStore
    @State private var showingAddPlayer = false
    @State private var showingTestFill = false

    private var team: Team? {
        store.currentLeague?.teams.first { $0.id == teamId }
    }

    var body: some View {
        Group {
            if let team {
                List {
                    Section("球队资料") {
                        TeamEditorFields(team: team)
                    }
                    if !Validation.warnings(for: team).isEmpty {
                        Section("名单校验提醒") {
                            ForEach(Validation.warnings(for: team), id: \.self) { warning in
                                Text(warning).font(.footnote).foregroundStyle(.orange)
                            }
                            Text("提醒不硬拦保存；但模拟只算激活名单 >= 5 人的球队。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Section("首发（\(team.starters.count) / 5）") {
                        ForEach(team.starters) { slot in
                            PlayerRow(teamId: team.id, slot: slot)
                        }
                    }
                    Section("替补（\(team.bench.count) 人）") {
                        ForEach(team.bench) { slot in
                            PlayerRow(teamId: team.id, slot: slot)
                        }
                    }
                    Section("inactive（\(team.inactive.count) 人）") {
                        ForEach(team.inactive) { slot in
                            PlayerRow(teamId: team.id, slot: slot)
                        }
                    }
                    Section {
                        Button("为本队生成虚构测试名单") { showingTestFill = true }
                            .foregroundStyle(.orange)
                        Text("测试名单是虚构占位球员（测试球员 1-13），不是真实球员，点一下会替换本队现有名单。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle(team.name)
                .toolbar {
                    Button("加球员") { showingAddPlayer = true }
                }
                .sheet(isPresented: $showingAddPlayer) {
                    PlayerEditorView(teamId: team.id, slot: nil)
                }
                .alert("生成测试名单？", isPresented: $showingTestFill) {
                    Button("取消", role: .cancel) {}
                    Button("生成并替换", role: .destructive) {
                        store.fillTestRoster(for: team.id)
                    }
                } message: {
                    Text("会替换本队现有全部名单，生成 13 名虚构测试球员（首发 5 + 替补 8）。")
                }
            } else {
                Text("找不到这支球队").foregroundStyle(.secondary)
            }
        }
    }
}

// 球队资料编辑字段：改完即保存到当前存档。
private struct TeamEditorFields: View {
    var team: Team
    @EnvironmentObject private var store: LeagueStore
    @State private var color: Color = .orange

    var body: some View {
        TextField("队名", text: Binding(
            get: { team.name },
            set: { newValue in var copy = team; copy.name = newValue; store.updateTeam(copy) }
        ))
        TextField("缩写（如 ABC，可空）", text: Binding(
            get: { team.abbreviation },
            set: { newValue in var copy = team; copy.abbreviation = newValue; store.updateTeam(copy) }
        ))
        TextField("分区（如 东部/西部，可空）", text: Binding(
            get: { team.division },
            set: { newValue in var copy = team; copy.division = newValue; store.updateTeam(copy) }
        ))
        TextField("主场（如 主场馆名，可空）", text: Binding(
            get: { team.arena },
            set: { newValue in var copy = team; copy.arena = newValue; store.updateTeam(copy) }
        ))
        ColorPicker("配色", selection: $color)
            .onAppear { color = team.color() }
            .onChange(of: color) { _, newColor in
                if let hex = newColor.toHex() {
                    var copy = team; copy.colorHex = hex; store.updateTeam(copy)
                }
            }
    }
}

// 名单行：显示总评（自动或手动）、位置、球衣号；可改状态、调轮换顺序、删人、点进编辑器。
private struct PlayerRow: View {
    var teamId: UUID
    var slot: RosterSlot
    @EnvironmentObject private var store: LeagueStore
    @State private var showingEditor = false

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(slot.player.name).font(.headline)
                Text("\(slot.player.position.rawValue) · #\(slot.player.jerseyNumber) · 总评 \(Rating.overall(for: slot.player))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu(slot.status.rawValue) {
                ForEach(RosterStatus.allCases) { status in
                    Button(status.rawValue) {
                        var copy = slot; copy.status = status; store.updatePlayer(in: teamId, slot: copy)
                    }
                }
            }
            Button { store.movePlayer(in: teamId, playerId: slot.player.id, direction: -1) } label: {
                Image(systemName: "chevron.up")
            }.buttonStyle(.borderless)
            Button { store.movePlayer(in: teamId, playerId: slot.player.id, direction: 1) } label: {
                Image(systemName: "chevron.down")
            }.buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture { showingEditor = true }
        .swipeActions {
            Button("删除", role: .destructive) {
                store.removePlayer(in: teamId, playerId: slot.player.id)
            }
        }
        .sheet(isPresented: $showingEditor) {
            PlayerEditorView(teamId: teamId, slot: slot)
        }
    }
}
