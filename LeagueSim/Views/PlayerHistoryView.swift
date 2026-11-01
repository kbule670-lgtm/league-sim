import SwiftUI

// 球员各赛季历史数据：从球队里点进一名球员，再点“查看各赛季数据”进来。
// 数据只读已跑完的赛季快照：球员 ID 不变，交易换队后下一赛季记在新队下，
// 旧赛季的队名、数据都不会被改写；所以这里按赛季号倒序列出该球员的每赛季数据。
// 常规赛数据：季后赛不并进场均与投篮累计，季后赛看单场 box。
struct PlayerHistoryView: View {
    var playerId: UUID
    var playerName: String
    @EnvironmentObject private var store: LeagueStore

    private var rows: [(seasonNumber: Int, stat: PlayerSeasonStat)] {
        guard let league = store.currentLeague else { return [] }
        return league.seasons
            .sorted { $0.seasonNumber > $1.seasonNumber }
            .compactMap { season in
                if let stat = season.playerStats.first(where: { $0.playerId == playerId }) {
                    return (season.seasonNumber, stat)
                }
                return nil
            }
    }

    var body: some View {
        List {
            if rows.isEmpty {
                Section {
                    Text("还没有 \(playerName) 的赛季数据：去“模拟”跑完一赛季，这里就会按赛季列出来。")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(rows, id: \.seasonNumber) { row in
                    let stat = row.stat
                    VStack(alignment: .leading) {
                        Text("第 \(row.seasonNumber) 赛季 · \(stat.teamName)")
                            .font(.headline)
                        Text(String(format: "出场 %d 场 · %.1f 分 · %.1f 板 · %.1f 助 · 累计 %d 分",
                                    stat.games, stat.pointsPerGame, stat.reboundsPerGame,
                                    stat.assistsPerGame, stat.totalPoints))
                            .font(.caption).foregroundStyle(.secondary)
                        if stat.totalFieldGoalsAttempted > 0 || stat.totalFreeThrowsAttempted > 0 {
                            Text(String(format: "投篮 %d中%d（%.1f%%）· 三分 %d中%d（%.1f%%）· 罚球 %d中%d（%.1f%%）",
                                        stat.totalFieldGoalsMade, stat.totalFieldGoalsAttempted,
                                        stat.fieldGoalPercentage * 100,
                                        stat.totalThreeMade, stat.totalThreeAttempted,
                                        stat.threePercentage * 100,
                                        stat.totalFreeThrowsMade, stat.totalFreeThrowsAttempted,
                                        stat.freeThrowPercentage * 100))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("\(playerName) 各赛季数据")
    }
}
