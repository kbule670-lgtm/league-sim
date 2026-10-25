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
                    TextField("姓名", text: $name)
                    TextField("球衣号", text: $jerseyText).keyboardType(.numberPad)
                    Picker("位置", selection: $position) {
                        ForEach(Position.allCases) { item in
                            Text(item.name).tag(item)
                        }
                    }
                    TextField("年龄", text: $ageText).keyboardType(.numberPad)
                    TextField("身高（厘米）", text: $heightText).keyboardType(.numberPad)
                    TextField("体重（公斤）", text: $weightText).keyboardType(.numberPad)
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
        let player = Player(id: slot?.player.id ?? UUID(),
                            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                            jerseyNumber: Int(jerseyText) ?? 0, position: position,
                            age: Int(ageText) ?? 25, heightCm: Int(heightText) ?? 195,
                            weightKg: Int(weightText) ?? 90, attributes: attrs.clamped(),
                            overallOverride: useManualOverall ? manualOverall : nil)
        if let slot {
            store.updatePlayer(in: teamId, slot: RosterSlot(player: player, status: status,
                                                             rotationOrder: slot.rotationOrder))
        } else {
            store.addPlayer(to: teamId, player: player, status: status)
        }
    }
}

// 0-99 滑杆 + 数字：滑杆步进 1，数字一眼看得出。
private struct AttributeSlider: View {
    var label: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(label)
                Spacer()
                Text("\(value)").monospacedDigit()
            }
            Slider(value: Binding(
                get: { Double(value) },
                set: { value = Int($0) }
            ), in: 0...99, step: 1)
        }
    }
}
