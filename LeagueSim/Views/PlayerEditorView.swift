import SwiftUI

// 球员能力编辑器：基本信息 + 位置 + 12 项分项（0-99 滑杆）。
// 总评实时显示：默认按位置权重自动算；打开“手动总评”后用手动值，潜力始终不计入。
struct PlayerEditorView: View {
    var teamId: UUID
    var slot: RosterSlot?
    @EnvironmentObject private var store: LeagueStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var jerseyText = ""
    @State private var position: Position = .pg
    @State private var ageText = "25"
    @State private var heightText = "195"
    @State private var weightText = "90"
    @State private var status: RosterStatus = .bench
    @State private var attrs = Attributes()
    @State private var useManualOverall = false
    @State private var manualOverall = 70

    private var previewPlayer: Player {
        Player(name: name.isEmpty ? "未命名" : name,
               jerseyNumber: Int(jerseyText) ?? 0, position: position,
               age: Int(ageText) ?? 25, heightCm: Int(heightText) ?? 195,
               weightKg: Int(weightText) ?? 90, attributes: attrs,
               overallOverride: useManualOverall ? manualOverall : nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    // 标签必须写死在左边：原来只靠 TextField 的占位标签，
                    // 填上数字后标签就没了，25/195/90 是啥根本看不出来。
                    HStack {
                        Text("姓名")
                        TextField("", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("球衣号")
                        TextField("", text: $jerseyText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("位置", selection: $position) {
                        ForEach(Position.allCases) { item in
                            Text(item.name).tag(item)
                        }
                    }
                    HStack {
                        Text("年龄（岁）")
                        TextField("", text: $ageText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("身高（厘米）")
                        TextField("", text: $heightText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("体重（公斤）")
                        TextField("", text: $weightText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("名单状态", selection: $status) {
                        ForEach(RosterStatus.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                }
                Section("总评") {
                    HStack {
                        Text("自动总评（按位置权重）")
                        Spacer()
                        Text("\(Rating.automaticOverall(for: previewPlayer))").bold()
                    }
                    Toggle("手动覆盖总评", isOn: $useManualOverall)
                    if useManualOverall {
                        AttributeSlider(label: "手动总评", value: $manualOverall)
                    }
                    Text("当前显示总评：\(Rating.overall(for: previewPlayer))（潜力不计入当前总评）")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let slot {
                    Section("各赛季历史数据") {
                        NavigationLink {
                            PlayerHistoryView(playerId: slot.player.id, playerName: slot.player.name)
                        } label: {
                            Text("查看 \(slot.player.name) 各赛季数据")
                        }
                        Text("按赛季列：球队、场次、场均分板助、投篮三分罚球命中率；数据来自已跑完的赛季快照，之后改名改队不改写历史。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section("分项能力（0-99）") {
                    AttributeSlider(label: "三分", value: binding(\.threePoint))
                    AttributeSlider(label: "中投", value: binding(\.midRange))
                    Text("投射 = 三分与中投的均值，参与总评加权，不单独存一项。")
                        .font(.footnote).foregroundStyle(.secondary)
                    AttributeSlider(label: "内线终结", value: binding(\.finishing))
                    AttributeSlider(label: "罚球", value: binding(\.freeThrow))
                    AttributeSlider(label: "组织", value: binding(\.playmaking))
                    AttributeSlider(label: "篮板", value: binding(\.rebounding))
                    AttributeSlider(label: "外线防守", value: binding(\.perimeterDefense))
                    AttributeSlider(label: "护框", value: binding(\.rimProtection))
                    AttributeSlider(label: "运动能力", value: binding(\.athleticism))
                    AttributeSlider(label: "篮球智商", value: binding(\.basketballIQ))
                    AttributeSlider(label: "耐久", value: binding(\.durability))
                    AttributeSlider(label: "潜力（不计入当前总评）", value: binding(\.potential))
                }
            }
            .navigationTitle(slot == nil ? "加球员" : "编辑球员")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save(); dismiss() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func binding(_ keyPath: WritableKeyPath<Attributes, Int>) -> Binding<Int> {
        Binding(
            get: { attrs[keyPath: keyPath] },
            set: { attrs[keyPath: keyPath] = min(99, max(0, $0)) }
        )
    }

    private func load() {
        guard let slot else { return }
        let player = slot.player
        name = player.name
        jerseyText = "\(player.jerseyNumber)"
        position = player.position
        ageText = "\(player.age)"
        heightText = "\(player.heightCm)"
        weightText = "\(player.weightKg)"
        status = slot.status
        attrs = player.attributes
        if let manual = player.overallOverride {
            useManualOverall = true
            manualOverall = manual
        }
    }

    private func save() {
        // 15 版修编辑丢荣誉：新建 Player 时把原荣誉带上，否则改一次能力/球衣就把前几赛季荣誉全清空。
        let player = Player(id: slot?.player.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            jerseyNumber: Int(jerseyText) ?? 0, position: position,
                            age: Int(ageText) ?? 25, heightCm: Int(heightText) ?? 195,
                            weightKg: Int(weightText) ?? 90, attributes: attrs.clamped(),
                            overallOverride: useManualOverall ? manualOverall : nil,
                            honors: slot?.player.honors ?? [])
        if let slot {
            store.updatePlayer(in: teamId, slot: RosterSlot(player: player, status: status,
                                                             rotationOrder: slot.rotationOrder))
        } else {
            store.addPlayer(to: teamId, player: player, status: status)
        }
    }
}

// 0-99 键盘输入，不用滑块：用户反馈拖滑块改数太费劲，直接敲数字。
// 文本框用本地 text 状态 + 焦点守门：正在输入时不把 value 写回 text，
// 这样清空重输不会被立刻弹回 0；失焦后才按 value 同步一次，输入始终钳制 0-99。
private struct AttributeSlider: View {
    var label: String
    @Binding var value: Int
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            TextField("", text: $text)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .frame(width: 80)
        }
        .onAppear { text = "\(value)" }
        // 单参数 onChange：iOS 16 写法，双参数是 iOS 17 才有的。
        .onChange(of: text) { _ in
            value = min(99, max(0, Int(text) ?? 0))
        }
        .onChange(of: value) { _ in
            if !focused { text = "\(value)" }
        }
    }
}
