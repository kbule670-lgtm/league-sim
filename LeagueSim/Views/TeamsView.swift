import SwiftUI

// 球队列表：按分区，分组显示 30 队；分区为空的队归到“未分组”。
// 点一行进球队详情：改队资料、管名单、看校验提醒。
struct TeamsView: View {
    var league: League
    @EnvironmentObject private var store: LeagueStore

    struct TeamGroup: Identifiable {
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

    // body 只拼三块，每块单独算类型。
    private var tradeSection: some View {
        Section("中途交易（手动）") {
            NavigationLink {
                TradeView()
            } label: {
                Text("交易：球员从一队换到另一队")
            }
            Text("手动控制，不自动交易；球员 ID 不变，已跑完的赛季快照不改写，下一赛季记在新队下。新增球员去球队详情点“加球员”。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var warningsSection: some View {
        if !Validation.leagueWarnings(for: league).isEmpty {
            Section("联盟提醒") {
                ForEach(Validation.leagueWarnings(for: league), id: \.self) { warning in
                    Text(warning).font(.footnote).foregroundStyle(.orange)
                }
            }
        }
    }

    private var teamSections: some View {
        ForEach(grouped, id: \.key) { group in
            TeamGroupSection(group: group)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                QuizStyleHeader(title: "球队")
                List {
                Section {
                    Button("全部填测试名单") { store.fillTestRostersForAllEmptyTeams() }
                }
                tradeSection
                warningsSection
                teamSections
            }
            }
            .navigationBarHidden(true)
        }
    }
}


// 黑底顶栏：标题居中，系统导航栏隐藏；一键退出存档已取消，想回存档列表去“存档”页点“保存并回到存档列表”。
struct QuizStyleHeader: View {
    var title: String
    var body: some View {
        HStack {
            Color.clear.frame(width: 44, height: 44)
            Spacer()
            Text(title).font(.headline).foregroundStyle(.white)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black)
    }
}

// 球队行标签：从 body 里拆出来的独立小视图。
private struct TeamRowLabel: View {
    var team: Team
    var body: some View {
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

private struct TeamGroupSection: View {
    var group: TeamsView.TeamGroup
    var body: some View {
        Section(group.key) {
            ForEach(group.teams) { team in
                NavigationLink {
                    TeamDetailView(teamId: team.id)
                } label: {
                    TeamRowLabel(team: team)
                }
            }
        }
    }
}

struct TeamDetailView: View {
    var teamId: UUID
    @EnvironmentObject private var store: LeagueStore
    @State private var showingAddPlayer = false
    @State private var showingTestFill = false
    @State private var sorting = false

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
                    Section("出手权") {
                        NavigationLink("出手权分配") {
                            ShotShareView(teamId: team.id)
                        }
                        Text("初始按能力值自动分配，不改就是自动；点进去可手动微调。")
                            .font(.footnote).foregroundStyle(.secondary)
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
                    if sorting {
                        Section {
                            Text("长按行右侧的拖动把手上下拖：前 5 名是首发，往上拖进前五就变首发，往下拖就变替补，行上的首发/替补跟着变。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        Section("球员排序（前 5 名首发）") {
                            ForEach(team.activeRoster) { slot in
                                PlayerRow(teamId: team.id, slot: slot)
                            }
                            .onMove { source, destination in
                                store.moveActivePlayer(in: team.id, from: source, to: destination)
                            }
                        }
                        Section("inactive（\(team.inactive.count) 人）") {
                            ForEach(team.inactive) { slot in
                                PlayerRow(teamId: team.id, slot: slot)
                            }
                            .onMove { source, destination in
                                store.movePlayers(in: team.id, from: source, to: destination, status: .inactive)
                            }
                        }
                    } else {
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
                    }
                    Section {
                        Button("按能力自动排首发") { store.autoUpdateLineups(for: team.id) }
                        Text("首发按位置取总评最高的那人，其余按总评排替补；总评越高上场时间越长、球权也越多。赛季结束时全联盟都会自动排一次。")
                            .font(.footnote).foregroundStyle(.secondary)
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
                    Button(sorting ? "完成" : "排序") { sorting.toggle() }
                    Button("加球员") { showingAddPlayer = true }
                }
                .environment(\.editMode, sorting ? .constant(.active) : .constant(.inactive))
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
        TextField("分区（如 大西洋/中部，可空）", text: Binding(
            get: { team.division },
            set: { newValue in var copy = team; copy.division = newValue; store.updateTeam(copy) }
        ))
        Picker("东西部", selection: Binding(
            get: { team.conference },
            set: { newValue in var copy = team; copy.conference = newValue; store.updateTeam(copy) }
        )) {
            ForEach(Conference.allCases) { conference in
                Text(conference.rawValue).tag(conference)
            }
        }
        Text("东西部决定季后赛分组：东部前 8、西部前 8。选“未定”时按分区名推，推不出来就按联赛顺序前后对半分。")
            .font(.footnote).foregroundStyle(.secondary)
        TextField("主场（如 主场馆名，可空）", text: Binding(
            get: { team.arena },
            set: { newValue in var copy = team; copy.arena = newValue; store.updateTeam(copy) }
        ))
        ColorPicker("配色", selection: $color)
            .onAppear { color = team.color() }
            // iOS 16 写法：单参数 onChange（双参数是 iOS 17 才有的，iOS 16 编不过）。
            .onChange(of: color) { newColor in
                if let hex = newColor.toHex() {
                    var copy = team; copy.colorHex = hex; store.updateTeam(copy)
                }
            }
    }
}

// 出手权分配：初始按能力值自动算（总评越高出手越多），拖动可微调；不改就是自动。
// 拖动时只改本地草稿，松手再写进存档，避免每拖一格就存一次盘。
struct ShotShareView: View {
    var teamId: UUID
    @EnvironmentObject private var store: LeagueStore
    @State private var drafts: [UUID: Double] = [:]

    var body: some View {
        if let team = store.currentLeague?.teams.first(where: { $0.id == teamId }) {
            let active = team.activeRoster
            let avg = active.isEmpty ? 70.0 : Double(active.map { Rating.overall(for: $0.player) }.reduce(0, +)) / Double(active.count)
            let weights = active.map { slot in
                drafts[slot.player.id] ?? SimulationEngine.baseShotWeight(for: slot, teamAvgRating: avg)
            }
            let total = weights.reduce(0, +)
            List {
                Section {
                    Text("初始按能力值分配（总评越高出手越多），拖动可微调；不改就是自动。实际出手还受上场时间和手感影响。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("上场球员（按轮换顺序）") {
                    ForEach(Array(active.enumerated()), id: \.element.id) { index, slot in
                        let weight: Double = weights[index]
                        let share: Double = total > 0 ? weight / total : 1.0 / Double(max(1, active.count))
                        let noManual: Bool = slot.shotWeight == nil
                        let noDraft: Bool = drafts[slot.player.id] == nil
                        ShotShareRow(
                            slot: slot,
                            weight: weight,
                            share: share,
                            isAuto: noManual && noDraft,
                            onWeightChange: { drafts[slot.player.id] = $0 },
                            onWeightCommit: { store.setShotWeight(in: teamId, playerId: slot.player.id, weight: drafts[slot.player.id]) },
                            onResetToAuto: {
                                drafts.removeValue(forKey: slot.player.id)
                                store.setShotWeight(in: teamId, playerId: slot.player.id, weight: nil)
                            }
                        )
                    }
                }
                Section {
                    Button("全部恢复自动") {
                        drafts.removeAll()
                        store.resetAllShotWeights(in: teamId)
                    }
                }
            }
            .navigationTitle("出手权分配")
        } else {
            Text("找不到这支球队。").foregroundStyle(.secondary)
        }
    }
}

// 出手权里的一行：单独成 struct，免得整个分配页合成一个大表达式、编译器推类型超时。
private struct ShotShareRow: View {
    var slot: RosterSlot
    var weight: Double
    var share: Double
    var isAuto: Bool
    var onWeightChange: (Double) -> Void
    var onWeightCommit: () -> Void
    var onResetToAuto: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(slot.player.name).font(.headline)
                Text("总评 \(Rating.overall(for: slot.player))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("出手 \(Int((share * 100).rounded()))%")
                    .font(.subheadline).bold()
                if isAuto {
                    Text("自动").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Slider(value: Binding(
                    get: { weight },
                    set: { onWeightChange($0) }
                ), in: 0...500, step: 1, onEditingChanged: { editing in
                    if !editing { onWeightCommit() }
                }, minimumValueLabel: {
                    Text("0").font(.caption2)
                }, maximumValueLabel: {
                    Text("500").font(.caption2)
                }) {
                    Text("出手权")
                }
                Button("自动") { onResetToAuto() }
                    .font(.caption)
                    .buttonStyle(.bordered)
            }
        }
    }
}

private struct PlayerRow: View {
    var teamId: UUID
    var slot: RosterSlot
    @EnvironmentObject private var store: LeagueStore
    @Environment(\.editMode) private var editMode
    @State private var showingEditor = false

    private var isSorting: Bool { editMode?.wrappedValue == .active }

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(slot.player.name).font(.headline)
                Text("\(slot.player.position.name) · #\(slot.player.jerseyNumber) · 总评 \(Rating.overall(for: slot.player))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isSorting {
                Text(slot.status.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            if !isSorting {
                Menu(slot.status.rawValue) {
                    ForEach(RosterStatus.allCases) { status in
                        Button(status.rawValue) {
                            var copy = slot; copy.status = status; store.updatePlayer(in: teamId, slot: copy)
                        }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isSorting { showingEditor = true } }
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
