import SwiftUI

// 虚拟播报页：点进一场比赛，比分从 0:0 一步步走到终场。
// 快速跳过也在这个页里：点“快速跳过”直接跳到终场分，不用等播完。
// 内存：events 只在这一页的内存里，退出即丢，不写存档。
struct BroadcastView: View {
    var game: Game
    var seasonSeed: Int64

    @State private var events: [BroadcastEvent] = []
    @State private var shownCount = 0
    @State private var isPlaying = false
    private let timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

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
                        if isFinished {
                            shownCount = 0
                            isPlaying = true
                        } else {
                            isPlaying.toggle()
                        }
                    }
                    .disabled(events.isEmpty)
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
                Text("每步约 0.5 秒自动往前走；不想等就点快速跳过，直接看终场。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("最近得分") {
                if shownCount == 0 {
                    Text("点播放，从 0:0 开始播。").foregroundStyle(.secondary)
                } else {
                    let recent = events.prefix(shownCount).suffix(10).reversed()
                    ForEach(recent) { event in
                        Text("\(event.timeText) · \(event.isHomeScoring ? game.homeTeamName : game.awayTeamName) +\(event.points) · \(event.homeScore) : \(event.awayScore)")
                            .font(.caption)
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
        .onReceive(timer) { _ in
            guard isPlaying, !events.isEmpty, shownCount < events.count else {
                if shownCount >= events.count { isPlaying = false }
                return
            }
            shownCount += 1
        }
    }
}
