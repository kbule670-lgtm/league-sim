import Foundation

// MARK: - 虚拟播报：点进一场比赛，现算比分进程，终场分必须等于已存终场分
// 内存约束（朋友原话“内存别太大”）：
// - 播报只在看的那一场比赛现算，算出来只放内存里的一个小数组（约 60 条得分事件）；
// - 不写入存档 JSON、不进赛季快照、不给所有比赛都预存逐条数据；
// - 退出播报页，数组就随视图销毁，不留持久化数据。
// 可复现：同一赛季种子 + 同一场比赛（队名 + 终场分），算出来的进程永远相同，
// 这样重播不会出现“这次终场分变了”的情况。
// 得分球员：事件不再只写“主队/客队得分”，而是按 box 里每人的实际得分拆成
// 1/2/3 分的小块，打乱顺序后逐条播；每人的小块加起来正好等于他的 box 得分，
// 全场小块加起来正好等于终场分，所以最近得分能写出“谁得了这分”。
struct BroadcastEvent: Identifiable {
    var id: Int
    var homeScore: Int
    var awayScore: Int
    var isHomeScoring: Bool
    var points: Int
    var scorerName: String
    // 剩余时间（秒）：开场 48:00 = 2880，终场 0:00。
    var timeRemainingSeconds: Int

    var timeText: String {
        let minutes = timeRemainingSeconds / 60
        let seconds = timeRemainingSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

enum BroadcastGenerator {
    static func events(for game: Game, seasonSeed: Int64) -> [BroadcastEvent] {
        // 从赛季种子 + 队名 + 终场分派生播报种子：稳定、可复现，与赛季模拟的随机源分开。
        var seed = seasonSeed
        for scalar in (game.homeTeamName + game.awayTeamName).unicodeScalars {
            seed = seed &* 31 &+ Int64(scalar.value)
        }
        seed = seed &+ Int64(game.homeScore) * 131 &+ Int64(game.awayScore) * 17
        var rng = SeededRandom(seed: seed)

        // 每人的得分拆成 1/2/3 分小块：三分能力高的球员拆出 3 分块的概率稍高，
        // 但小块总和一定等于他的 box 得分，不会凭空多分或少分。
        struct Chunk {
            var isHome: Bool
            var scorerName: String
            var points: Int
        }
        var chunks: [Chunk] = []
        for stat in game.boxScore {
            var remaining = stat.points
            while remaining > 0 {
                let chunk: Int
                if remaining >= 3 && rng.nextDouble() < 0.35 {
                    chunk = 3
                } else if remaining >= 2 {
                    chunk = 2
                } else {
                    chunk = 1
                }
                chunks.append(Chunk(isHome: stat.teamId == game.homeTeamId,
                                    scorerName: stat.playerName, points: chunk))
                remaining -= chunk
            }
        }
        // 老快照或 box 为空的比赛没有球员得分可拆：退回只按队名播，不写得分球员。
        if chunks.isEmpty {
            return teamOnlyEvents(for: game, rng: &rng)
        }
        // 打乱小块顺序：Fisher-Yates，同一种子打乱结果相同。
        for index in stride(from: chunks.count - 1, through: 1, by: -1) {
            let other = rng.nextInt(in: 0...index)
            chunks.swapAt(index, other)
        }
        var events: [BroadcastEvent] = []
        var home = 0
        var away = 0
        var timeRemaining = 48 * 60
        for (index, chunk) in chunks.enumerated() {
            if chunk.isHome { home += chunk.points } else { away += chunk.points }
            // 时间往前走：每条事件消耗 15-75 秒，但要给后面每条至少留 5 秒，
            // 最后一条强制 0:00，保证终场对齐，中间不会提前归零。
            if index == chunks.count - 1 {
                timeRemaining = 0
            } else {
                let remainingEvents = chunks.count - index - 1
                let maxConsumption = max(5, timeRemaining - remainingEvents * 5)
                let consumption = min(rng.nextInt(in: 15...75), maxConsumption)
                timeRemaining = max(0, timeRemaining - consumption)
            }
            events.append(BroadcastEvent(id: index, homeScore: home, awayScore: away,
                                         isHomeScoring: chunk.isHome, points: chunk.points,
                                         scorerName: chunk.scorerName,
                                         timeRemainingSeconds: timeRemaining))
        }
        return events
    }

    // 兜底：没有 box 可拆时，只按队名和终场分播，逻辑与旧版一致。
    private static func teamOnlyEvents(for game: Game, rng: inout SeededRandom) -> [BroadcastEvent] {
        var remainingHome = game.homeScore
        var remainingAway = game.awayScore
        guard remainingHome + remainingAway > 0 else { return [] }
        var events: [BroadcastEvent] = []
        var home = 0
        var away = 0
        var timeRemaining = 48 * 60
        var index = 0
        while remainingHome > 0 || remainingAway > 0 {
            let isHome: Bool
            if remainingHome == 0 {
                isHome = false
            } else if remainingAway == 0 {
                isHome = true
            } else {
                isHome = rng.nextDouble() < Double(remainingHome) / Double(remainingHome + remainingAway)
            }
            let remaining = isHome ? remainingHome : remainingAway
            let points: Int
            if remaining == 1 {
                points = 1
            } else if remaining == 2 {
                points = rng.nextDouble() < 0.7 ? 2 : 1
            } else {
                let roll = rng.nextDouble()
                if roll < 0.55 {
                    points = 2
                } else if roll < 0.85 {
                    points = 3
                } else {
                    points = 1
                }
            }
            if isHome {
                home += points
                remainingHome -= points
            } else {
                away += points
                remainingAway -= points
            }
            if remainingHome == 0 && remainingAway == 0 {
                timeRemaining = 0
            } else {
                timeRemaining = max(0, timeRemaining - rng.nextInt(in: 15...75))
            }
            events.append(BroadcastEvent(id: index, homeScore: home, awayScore: away,
                                         isHomeScoring: isHome, points: points, scorerName: "",
                                         timeRemainingSeconds: timeRemaining))
            index += 1
            if index > 1000 { break }
        }
        return events
    }
}
