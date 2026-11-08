import SwiftUI

// 虚拟播报页：点进一场比赛，比分从 0:0 一步步播到终场；点“快速跳过”直接跳到终场分。
// 播放器按比赛 id 缓存、只改状态不重建进度，退出页面不写存档；页面底部有一行诊断（播放器 id、已播步数、状态、代次）。
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
    @Published var lastAction = "进页"
    private(set) var hasStarted = false
    private var task: Task<Void, Never>?

    private init(game: Game, seasonSeed: Int64) {
        self.game = game
        self.events = BroadcastGenerator.events(for: game, seasonSeed: seasonSeed)
    }

    var isFinished: Bool { !events.isEmpty && shownCount >= events.count }
    var debugLine: String {
        "诊断：播放器 \(String(game.id.uuidString.suffix(4))) · 已播 \(shownCount)/\(events.count) · \(isPlaying ? "播放中" : "已暂停/未播") · 任务代次 \(taskGeneration) · 上次：\(lastAction)"
    }

    func startIfNeeded() {
        if !hasStarted {
            hasStarted = true
            lastAction = "首次自动播"
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
        lastAction = "播放"
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
        lastAction = "暂停"
        print("[播报] 暂停点击 shown=\(shownCount) generation=\(taskGeneration)")
        isPlaying = false
        taskGeneration += 1
        task?.cancel()
        task = nil
    }

    func replay() {
        lastAction = "重播"
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
        lastAction = "快速跳过"
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

    @State private var showingReplayConfirm = false
    @State private var foldFullRecord = false
    @State private var foldLiveStats = true

    // 实时得分：已播事件里该球员得了多少分（按名字 + 主客队对）。
    private func livePoints(for stat: PlayerGameStat) -> Int {
        player.events.prefix(player.shownCount).filter {
            $0.scorerName == stat.playerName && $0.isHomeScoring == (stat.teamId == game.homeTeamId)
        }.map { $0.points }.reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(game.homeTeamName) \(currentHome) : \(currentAway) \(game.awayTeamName)")
                    .font(.title3).bold()
                // 播报结束前不露终场比分：只显示剩余时间，播完才给出总结果。
                if player.isFinished {
                    Text("剩余时间 \(currentTime) · 终场 \(game.homeScore) : \(game.awayScore)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("剩余时间 \(currentTime)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if player.isFinished {
                    Text("终场哨响，比分已定。")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !player.isPlaying && player.shownCount > 0 {
                    Text("已暂停，停在当前比分，点“播放”从这里继续，不会从头来。")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(player.debugLine)
                    .font(.caption2).foregroundStyle(.secondary)
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
                        showingReplayConfirm = true
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
                Text("当前 \(player.speed, specifier: "%.1f")x，每步约 \(0.5 / player.speed, specifier: "%.3f") 秒；暂停只停住，播完后播放键不可点、只能点重播；重播要点确认才清零。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Button { foldLiveStats.toggle() } label: {
                        HStack { Text("实时球员数据（上场情况 + 得分）"); Spacer(); Image(systemName: foldLiveStats ? "chevron.down" : "chevron.right") }
                    }
                    if foldLiveStats {
                        Text("上场情况看出场分钟：分钟 > 0 就是上过场；实时得分随播报进度涨，全场数据播完才显示。")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach([game.homeTeamId, game.awayTeamId], id: \.self) { teamId in
                            Text(teamId == game.homeTeamId ? game.homeTeamName : game.awayTeamName).font(.headline)
                            ForEach(game.boxScore.filter { $0.teamId == teamId }, id: \.playerId) { stat in
                                if player.isFinished {
                                    Text("\(stat.playerName)：实时 \(livePoints(for: stat)) 分 · 全场 \(stat.points) 分 \(stat.rebounds) 板 \(stat.assists) 助 · 出场 \(stat.minutes) 分钟")
                                        .font(.caption)
                                } else {
                                    Text("\(stat.playerName)：实时 \(livePoints(for: stat)) 分 · 出场 \(stat.minutes) 分钟")
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    Divider()
                    Text("最近得分").font(.headline)
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
                    Divider()
                    Button { foldFullRecord.toggle() } label: {
                        HStack { Text("全场得分记录（\(player.shownCount)/\(player.events.count) 条）"); Spacer(); Image(systemName: foldFullRecord ? "chevron.down" : "chevron.right") }
                    }
                    if foldFullRecord {
                        if player.shownCount == 0 {
                            Text("还没开始播。").foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(player.events.prefix(player.shownCount))) { event in
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
                .padding()
            }
        }
        .navigationTitle("虚拟播报")
        .onAppear {
            player.startIfNeeded()
        }
        .alert("确认重播？", isPresented: $showingReplayConfirm) {
            Button("取消", role: .cancel) {}
            Button("确认重播", role: .destructive) { player.replay() }
        } message: {
            Text("重播会把比分清零、从 0:0 重新播。暂停和换倍速不会清零。")
        }
    }
}
