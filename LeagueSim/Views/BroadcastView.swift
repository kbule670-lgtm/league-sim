import SwiftUI

// 虚拟播报页：点进一场比赛，比分从 0:0 一步步走到终场。
// 快速跳过也在这个页里：点“快速跳过”直接跳到终场分，不用等播完。
// 内存：events 只在播放器里，退出页面不写存档。
//
// 暂停/重制根因（10 版，修 9 版没修掉的）：
// 9 版以前播放状态（events、shownCount、isPlaying）都存在页面自己的 @State 里，
// 页面一被系统重建（父页面一刷新、导航栈一动），@State 就被清空，onAppear 又
// 把 shownCount 清零、isPlaying 置 true，于是播到一半就跳回 0:2、按钮还一直是
// “暂停”——点暂停根本没生效，不是计时器换没换的问题。
// 现在播放状态搬到页面外的 BroadcastPlayer，按比赛 id 缓存：页面重建多少次，
// 播放器还是同一个，shownCount 和暂停状态都不会丢；onAppear 只在第一次进
// 来时自动播，之后重进、重建都不自动重播、不自动续播；离开页面也不强制
// 暂停（避免重建时误触发 onDisappear 把播放停掉），要停只能点“暂停”，
// 要从头只能点“重播”。
// 倍速：0.5x/1x/2x/4x，任务每步都按当前倍速算步长，换倍速不用重建任务、不清零。
@MainActor
final class BroadcastPlayer: ObservableObject {
    private static var cache: [UUID: BroadcastPlayer] = [:]

    static func shared(game: Game, seasonSeed: Int64) -> BroadcastPlayer {
        if let existing = cache[game.id] { return existing }
        let player = BroadcastPlayer(game: game, seasonSeed: seasonSeed)
        cache[game.id] = player
        return player
    }

    let game: Game
    @Published var events: [BroadcastEvent]
    @Published var shownCount = 0
    @Published var isPlaying = false
    @Published var speed: Double = 1.0
    private(set) var hasStarted = false
    private var task: Task<Void, Never>?

    private init(game: Game, seasonSeed: Int64) {
        self.game = game
        self.events = BroadcastGenerator.events(for: game, seasonSeed: seasonSeed)
    }

    var isFinished: Bool { !events.isEmpty && shownCount >= events.count }

    func startIfNeeded() {
        if !hasStarted {
            hasStarted = true
            play()
        }
    }

    func play() {
        guard shownCount < events.count else { isPlaying = false; return }
        isPlaying = true
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                let interval = 0.5 / speed
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                guard isPlaying else { return }
                if shownCount < events.count {
                    shownCount += 1
                    if shownCount >= events.count { isPlaying = false; return }
                } else {
                    isPlaying = false
                    return
                }
            }
        }
    }

    func pause() {
        isPlaying = false
        task?.cancel()
        task = nil
    }

    func replay() {
        pause()
        shownCount = 0
        hasStarted = true
        play()
    }

    func skip() {
        pause()
        shownCount = events.count
    }
}

struct BroadcastView: View {
    var game: Game
    var seasonSeed: Int64

    @ObservedObject private var player: BroadcastPlayer

    init(game: Game, seasonSeed: Int64) {
        self.game = game
        self.seasonSeed = seasonSeed
        _player = ObservedObject(wrappedValue: BroadcastPlayer.shared(game: game, seasonSeed: seasonSeed))
    }

    private var currentHome: Int {
        player.shownCount > 0 ? player.events[min(player.shownCount, player.events.count) - 1].homeScore : 0
    }
    private var currentAway: Int {
        player.shownCount > 0 ? player.events[min(player.shownCount, player.events.count) - 1].awayScore : 0
    }
    private var currentTime: String {
        if player.shownCount == 0 {
            return "48:00"
        }
        return player.events[min(player.shownCount, player.events.count) - 1].timeText
    }

    var body: some View {
        List {
            Section {
                Text("\(game.homeTeamName) \(currentHome) : \(currentAway) \(game.awayTeamName)")
                    .font(.title3).bold()
                Text("剩余时间 \(currentTime) · 终场 \(game.homeScore) : \(game.awayScore)")
                    .font(.caption).foregroundStyle(.secondary)
                if player.isFinished {
                    Text("终场哨响，比分已定。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !player.isPlaying && player.shownCount > 0 {
                    Text("已暂停，停在当前比分，点“播放”从这里继续，不会从头来。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Section {
                HStack {
                    Button(player.isPlaying ? "暂停" : "播放") {
                        if player.isPlaying {
                            player.pause()
                        } else if !player.isFinished {
                            player.play()
                        }
                    }
                    .disabled(player.events.isEmpty || player.isFinished)
                    Spacer()
                    Button("快速跳过") {
                        player.skip()
                    }
                    .disabled(player.events.isEmpty || player.isFinished)
                    Spacer()
                    Button("重播") {
                        player.replay()
                    }
                    .disabled(player.events.isEmpty)
                }
                Picker("倍速", selection: $player.speed) {
                    Text("0.5x").tag(0.5)
                    Text("1x").tag(1.0)
                    Text("2x").tag(2.0)
                    Text("4x").tag(4.0)
                }
                .pickerStyle(.segmented)
                Text("当前 \(player.speed, specifier: "%.1f")x，每步约 \(0.5 / player.speed, specifier: "%.3f") 秒；暂停只停住，播完后播放键不可点、只能点重播。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("最近得分") {
                if player.shownCount == 0 {
                    Text("点播放，从 0:0 开始播。").foregroundStyle(.secondary)
                } else {
                    let recent = player.events.prefix(player.shownCount).suffix(10).reversed()
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
            player.startIfNeeded()
        }
    }
}
