import SwiftUI

// 虚拟播报页：点进一场比赛，比分从 0:0 一步步走到终场。
// 快速跳过也在这个页里：点“快速跳过”直接跳到终场分，不用等播完。
// 内存：events 只在这一页的内存里，退出即丢，不写存档。
// 暂停修法（9 版，修“暂停后跳回开头又卡住”）：
// 以前用 Timer.publish 存进 @State，换倍速就换一个新计时器，旧计时器没取消干净，
// 暂停时计时器和 isPlaying 容易脱节：按钮还显示“暂停”，比分却卡住不动，
// 再点也恢复不了；而且 onAppear 每次都把 shownCount 清零重播。
// 现在改成任务循环：isPlaying 或倍速一变，旧任务就取消、新任务按新倍速重起；
// 暂停就是取消任务，比分停在原地，按钮变回“播放”；再点播放从原地继续，绝不从头；
// 只有“重播”才清零；重进页面时如果 events 已有，就不再清零。
// 倍速：0.5x/1x/2x/4x，步长 = 0.5 秒 / 倍速。
struct BroadcastView: View {
    var game: Game
    var seasonSeed: Int64

    @State private var events: [BroadcastEvent] = []
    @State private var shownCount = 0
    @State private var isPlaying = false
    @State private var speed: Double = 1.0

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
                } else if !isPlaying && shownCount > 0 {
                    Text("已暂停，停在当前比分，点“播放”从这里继续，不会从头来。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                HStack {
                    Button(isPlaying ? "暂停" : "播放") {
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
            if events.isEmpty {
                events = BroadcastGenerator.events(for: game, seasonSeed: seasonSeed)
                shownCount = 0
                isPlaying = true
            }
        }
        .onDisappear {
            isPlaying = false
        }
        // 每步一个任务：id 里带上 shownCount，播一步就换一个新任务接着播；
        // 暂停会取消当前任务，播放/换倍速/重播都会按当前 shownCount 重起，不会卡在旧计时器上。
        .task(id: "\(isPlaying)-\(speed)-\(shownCount)") {
            guard isPlaying, shownCount < events.count else { return }
            let interval = 0.5 / speed
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
            if shownCount < events.count {
                shownCount += 1
                if shownCount >= events.count { isPlaying = false }
            }
        }
    }
}
