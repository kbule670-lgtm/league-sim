import Foundation

// MARK: - 虚拟播报：点进一场比赛，现算比分进程，终场分必须等于已存终场分
// 内存约束（朋友原话“内存别太大”）：
// - 播报只在看的那一场比赛现算，算出来只放内存里的一个小数组（约 100 条得分事件）；
// - 不写入存档 JSON、不进赛季快照、不给所有比赛都预存逐条数据；
// - 退出播报页，数组就随视图销毁，不留持久化数据。
// 可复现：同一赛季种子 + 同一场比赛（队名 + 终场分），算出来的进程永远相同，
// 这样重播不会出现“这次终场分变了”的情况。
struct BroadcastEvent: Identifiable {
    var id: Int
    var homeScore: Int
    var awayScore: Int
    var isHomeScoring: Bool
    var points: Int
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
        var remainingHome = game.homeScore
        var remainingAway = game.awayScore
        guard remainingHome + remainingAway > 0 else { return [] }

        // 从赛季种子 + 队名 + 终场分派生播报种子：稳定、可复现，与赛季模拟的随机源分开。
        var seed = seasonSeed
        for scalar in (game.homeTeamName + game.awayTeamName).unicodeScalars {
            seed = seed &* 31 &+ Int64(scalar.value)
        }
        seed = seed &+ Int64(game.homeScore) * 131 &+ Int64(game.awayScore) * 17
        var rng = SeededRandom(seed: seed)

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
            // 时间往前走：每条得分事件消耗 15-75 秒；最后一条强制 0:00，保证终场对齐。
            if remainingHome == 0 && remainingAway == 0 {
                timeRemaining = 0
            } else {
                timeRemaining = max(0, timeRemaining - rng.nextInt(in: 15...75))
            }
            events.append(BroadcastEvent(id: index, homeScore: home, awayScore: away,
                                         isHomeScoring: isHome, points: points,
                                         timeRemainingSeconds: timeRemaining))
            index += 1
            // 安全上限：终场分再大也不会无限循环。
            if index > 1000 { break }
        }
        return events
    }
}
