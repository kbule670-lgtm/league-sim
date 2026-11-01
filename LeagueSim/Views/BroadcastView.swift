import SwiftUI

// 虚拟播报页：点进一场比赛，比分从 0:0 一步步播到终场。
// 快速跳过也在这个页里：点“快速跳过”直接跳到终场分，不用等播完。
// 内存：events 只在播放器里，退出页面不写存档。
//
// 11 版（按 GPT 方案收口，10 版的思路 + 补上 GPT 强调的两点）：
// 1. 单一播放器、单一任务：events、shownCount、isPlaying、speed 全在 BroadcastPlayer
//    里，页面只观察、不自己维护进度；不用 Timer，不用 .task(id:) 反复重建任务。
// 2. 播放器实例唯一：按比赛 id 静态缓存，同一场比赛永远复用同一个播放器，
//    页面重建、导航栈刷新、重新进页都不能重新创建进度。
// 3. 任务代次校验（10 版缺的）：play/pause/replay/skip 都会让 taskGeneration +1，
//    任务循环每步都校验 generation == taskGeneration、!Task.isCancelled、isPlaying，
//    三项缺一就立刻退出，旧任务失效后绝对不能再改 shownCount。
// 4. 暂停：isPlaying = false、代次 +1、取消任务，保留 shownCount 和 events，
//    UI 立即变“播放”并显示“已暂停”。
// 5. 继续：从当前 shownCount 继续，不重新生成事件、不清零；启动前如果已在播就不重起任务。
// 6. 重播：只有主动点“重播”才清零；其他任何操作都不能把 shownCount 设为 0。
// 7. 倍速：只改 speed，任务下一次循环按 0.5 / speed 算间隔，不销毁播放器、不重建事件、不重置进度。
// 8. 生命周期：onAppear 只获取已有播放器、只在第一次自动播；onDisappear 不清零、不强制暂停，
//    离开再进入保留原来的播放状态（要停只能点暂停）。
// 9. 诊断：页面底部有一行小字诊断（播放器 id 后 4 位、已播步数/总数、播放状态、任务代次），
//    再出问题截图这一行就能判断是播放器被重建、还是旧任务在改进度；同时打 print 日志。
@MainActor
final class BroadcastPlayer: ObservableObject {
    private static var cache: [UUID: BroadcastPlayer] = [:]

    static func shared(game: Game, seasonSeed: Int64) -> BroadcastPlayer {
        if let existing = cache[game.id] {
            print("[播报] 缓存命中 game=\(game.id) shown=\(existing.shownCount) playing=\(existing.isPlaying)")
            return existing
        }
        let player = BroadcastPlayer(game: game, seasonSeed: seasonSeed)
        cache[game.id] = player
        print("[播报] 新建播放器 game=\(game.id) events=\(player.events.count)")
        return player
    }

    let game: Game
    @Published var events: [BroadcastEvent]
    @Published var shownCount = 0
    @Published var isPlaying = false
    @Published var speed: Double = 1.0
    @Published private(set) var taskGeneration = 0
    private(set) var hasStarted = false
    private var task: Task<Void, Never>?

    private init(game: Game, seasonSeed: Int64) {
        self.game = game
        self.events = BroadcastGenerator.events(for: game, seasonSeed: seasonSeed)
    }

    var isFinished: Bool { !events.isEmpty && shownCount >= events.count }
    var debugLine: String {
        "诊断：播放器 \(String(game.id.uuidString.suffix(4))) · 已播 \(shownCount)/\(events.count) · \(isPlaying ? "播放中" : "已暂停/未播") · 任务代次 \(taskGeneration)"
    }

    func startIfNeeded() {
        if !hasStarted {
            hasStarted = true
            print("[播报] 首次进页自动播 game=\(game.id)")
            play()
        } else {
            print("[播报] 已有播放器，不自动重播 game=\(game.id) shown=\(shownCount) playing=\(isPlaying)")
        }
    }

    func play() {
        guard shownCount < events.count else { isPlaying = false; return }
        if isPlaying, task != nil {
            print("[播报] 已在播，不重起任务 game=\(game.id) shown=\(shownCount)")
            return
        }
        isPlaying = true
        task?.cancel()
        taskGeneration += 1
        let generation = taskGeneration
        print("[播报] 播放点击/启动 generation=\(generation) shown=\(shownCount)")
        task = Task {
            while !Task.isCancelled {
                let interval = 0.5 / speed
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { print("[播报] 任务取消退出 generation=\(generation)"); return }
                guard generation == taskGeneration else { print("[播报] 旧任务代次失效退出 generation=\(generation) current=\(taskGeneration)"); return }
                guard isPlaying else { print("[播报] 已暂停退出 generation=\(generation)"); return }
                if shownCount < events.count {
                    shownCount += 1
                    print("[播报] 推进 generation=\(generation) shown=\(shownCount)")
                    if shownCount >= events.count { isPlaying = false; return }
                } else {
                    isPlaying = false
                    return
                }
            }
        }
    }

    func pause() {
        print("[播报] 暂停点击 shown=\(shownCount) generation=\(taskGeneration)")
        isPlaying = false
        taskGeneration += 1
        task?.cancel()
        task = nil
    }

    func replay() {
        print("[播报] 重播点击（唯一允许清零的操作）旧 shown=\(shownCount)")
        isPlaying = false
        taskGeneration += 1
        task?.cancel()
        task = nil
        shownCount = 0
        hasStarted = true
        play()
    }

    func skip() {
        print("[播报] 快速跳过 shown=\(shownCount)")
        isPlaying = false
        taskGeneration += 1
        task?.cancel()
        task = nil
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
                Text(player.debugLine)
                    .font(.caption2).foregroundStyle(.secondary)
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
