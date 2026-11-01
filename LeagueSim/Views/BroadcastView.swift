import SwiftUI

// 虚拟播报页：点进一场比赛，比分从 0:0 一步步走到终场。
// 快速跳过也在这个页里：点“快速跳过”直接跳到终场分，不用等播完。
// 内存：events 只在这一页的内存里，退出即丢，不写存档。
// 暂停修法：播放/暂停键永远只切 isPlaying，绝不改 shownCount；
// 从头来只有“重播”一个键，播完后播放键直接禁用，不会再出现
// “点暂停结果从头播、跟重播一个功能”的情况。
// 倍速：0.5x/1x/2x/4x，改倍速就重建计时器，步长 = 0.5 秒 / 倍速。
struct BroadcastView: View {
    var game: Game
    var seasonSeed: Int64

    @State private var events: [BroadcastEvent] = []
    @State private var shownCount = 0
    @State private var isPlaying = false
    @State private var speed: Double = 1.0
    @State private var timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private var currentHome: Int {
        shownCount > 0 ? events[min(shownCount, events.count) - 1].homeScore : 0
    }
    private var currentAway: Int {
        shownCount > 0 ? events[min(shownCount, events.count) - 1].awayScore : 0
    }
    private var currentTime: String {
        if shownCount == 0 {
            return "48:00"
        }
        return events[min(shownCount, events.count) - 1].timeText
    }
    private var isFinished: Bool {
        !events.isEmpty && shownCount >= events.count
    }

    var body: some View {
        List {
            Section {
                Text("\(game.homeTeamName) \(currentHome) : \(currentAway) \(game.awayTeamName)")
                    .font(.title3).bold()
                Text("剩余时间 \(currentTime) · 终场 \(game.homeScore) : \(game.awayScore)")
                    .font(.caption).foregroundStyle(.secondary)
                if isFinished {
                    Text("终场哨响，比分已定。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                HStack {
                    Button(isPlaying ? "暂停" : "播放") {
                        // 只切播放状态，不动 shownCount：暂停就是暂停，绝不从头来。
                        if isPlaying {
                            isPlaying = false
                        } else if !isFinished {
                            isPlaying = true
                        }
                    }
                    .disabled(events.isEmpty || isFinished)
                    Spacer()
                    Button("快速跳过") {
                        shownCount = events.count
                        isPlaying = false
                    }
                    .disabled(events.isEmpty || isFinished)
                    Spacer()
                    Button("重播") {
                        shownCount = 0
                        isPlaying = true
                    }
                    .disabled(events.isEmpty)
                }
                Picker("倍速", selection: $speed) {
                    Text("0.5x").tag(0.5)
                    Text("1x").tag(1.0)
                    Text("2x").tag(2.0)
                    Text("4x").tag(4.0)
                }
                .pickerStyle(.segmented)
                Text("当前 \(speed, specifier: "%.1f")x，每步约 \(0.5 / speed, specifier: "%.3f") 秒；暂停只停住，播完后播放键不可点、只能点重播。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("最近得分") {
                if shownCount == 0 {
                    Text("点播放，从 0:0 开始播。").foregroundStyle(.secondary)
                } else {
                    let recent = events.prefix(shownCount).suffix(10).reversed()
                    ForEach(recent) { event in
                        if event.scorerName.isEmpty {
                            Text("\(event.timeText) · \(event.isHomeScoring ? game.homeTeamName : game.awayTeamName) +\(event.points) · \(event.homeScore) : \(event.awayScore)")
                                .font(.caption)
                        } else {
                            Text("\(event.timeText) · \(event.scorerName) +\(event.points)（\(event.isHomeScoring ? game.homeTeamName : game.awayTeamName)）· \(event.homeScore) : \(event.awayScore)")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("虚拟播报")
        .onAppear {
            events = BroadcastGenerator.events(for: game, seasonSeed: seasonSeed)
            shownCount = 0
            isPlaying = true
        }
        .onDisappear {
            isPlaying = false
        }
        // 单参数 onChange：iOS 16 写法。
        .onChange(of: speed) { _ in
            timer = Timer.publish(every: 0.5 / speed, on: .main, in: .common).autoconnect()
        }
        .onReceive(timer) { _ in
            guard isPlaying, !events.isEmpty, shownCount < events.count else {
                if shownCount >= events.count { isPlaying = false }
                return
            }
            shownCount += 1
        }
    }
}
