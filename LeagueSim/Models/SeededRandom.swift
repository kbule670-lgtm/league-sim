import Foundation

// MARK: - 确定性随机数：同一名单 + 同一种子 = 同一结果
// 坚决不用系统随机（arc4random / Double.random）：
// 每次模拟都从种子重新开始，赛程顺序、比分、球员数据全部按固定顺序取数，
// 换一台手机、重跑一次，只要名单和种子一样，结果就一样。
struct SeededRandom {
    private var state: UInt64

    init(seed: Int64) {
        // 种子 0 也要能跑：混一个固定常量，避免状态为 0 卡住。
        state = UInt64(bitPattern: seed) &+ 0x9E3779B97F4A7C15
        if state == 0 { state = 0x9E3779B97F4A7C15 }
    }

    mutating func nextUInt64() -> UInt64 {
        // SplitMix64：实现短、周期长、不同种子结果差异明显。
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextDouble() -> Double {
        // [0, 1)
        Double(nextUInt64() >> 11) / Double(1 << 53)
    }

    mutating func nextInt(in range: ClosedRange<Int>) -> Int {
        let span = range.upperBound - range.lowerBound + 1
        guard span > 0 else { return range.lowerBound }
        return range.lowerBound + Int(nextUInt64() % UInt64(span))
    }

    // 近似正态波动：两个均匀数相减，中心在 0，范围约 [-1, 1]，用来做比分波动。
    mutating func nextCentered() -> Double {
        nextDouble() + nextDouble() - 1.0
    }
}
