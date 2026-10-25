import Foundation

// MARK: - 总评：按位置权重算，潜力不计入
// 投射 = 三分与中投的均值（代码里写清楚，不用“投射”当独立分项存）。
// 每组权重和都是 100，算出来直接就是 0-99 的总评。
enum Rating {
    // 权重字段：投射 shooting 是三分/中投均值对应的权重。
    struct Weights {
        var playmaking: Double
        var shooting: Double
        var finishing: Double
        var freeThrow: Double
        var rebounding: Double
        var perimeterDefense: Double
        var rimProtection: Double
        var athleticism: Double
        var basketballIQ: Double
        var durability: Double
    }

    static func weights(for position: Position) -> Weights {
        switch position {
        case .pg:
            // 组织25 / 投射20 / 运动15 / 智商15 / 外防10 / 终结10 / 耐久5
            return Weights(playmaking: 25, shooting: 20, finishing: 10, freeThrow: 0,
                           rebounding: 0, perimeterDefense: 10, rimProtection: 0,
                           athleticism: 15, basketballIQ: 15, durability: 5)
        case .sg:
            // 投射30 / 终结15 / 运动15 / 外防15 / 组织10 / 智商10 / 耐久5
            return Weights(playmaking: 10, shooting: 30, finishing: 15, freeThrow: 0,
                           rebounding: 0, perimeterDefense: 15, rimProtection: 0,
                           athleticism: 15, basketballIQ: 10, durability: 5)
        case .sf:
            // 投射20 / 终结15 / 外防15 / 运动15 / 篮板10 / 组织10 / 智商10 / 耐久5
            return Weights(playmaking: 10, shooting: 20, finishing: 15, freeThrow: 0,
                           rebounding: 10, perimeterDefense: 15, rimProtection: 0,
                           athleticism: 15, basketballIQ: 10, durability: 5)
        case .pf:
            // 篮板20 / 护框15 / 终结15 / 外防10 / 运动10 / 投射10 / 智商10 / 耐久10
            return Weights(playmaking: 0, shooting: 10, finishing: 15, freeThrow: 0,
                           rebounding: 20, perimeterDefense: 10, rimProtection: 15,
                           athleticism: 10, basketballIQ: 10, durability: 10)
        case .c:
            // 护框25 / 篮板20 / 终结20 / 运动10 / 智商10 / 罚球5 / 耐久10
            return Weights(playmaking: 0, shooting: 0, finishing: 20, freeThrow: 5,
                           rebounding: 20, perimeterDefense: 0, rimProtection: 25,
                           athleticism: 10, basketballIQ: 10, durability: 10)
        }
    }

    // 自动总评：分项加权平均。potential 故意不在这里出现。
    static func automaticOverall(for player: Player) -> Int {
        let a = player.attributes.clamped()
        let w = weights(for: player.position)
        let shooting = Double(a.threePoint + a.midRange) / 2.0
        let total = w.playmaking * Double(a.playmaking)
            + w.shooting * shooting
            + w.finishing * Double(a.finishing)
            + w.freeThrow * Double(a.freeThrow)
            + w.rebounding * Double(a.rebounding)
            + w.perimeterDefense * Double(a.perimeterDefense)
            + w.rimProtection * Double(a.rimProtection)
            + w.athleticism * Double(a.athleticism)
            + w.basketballIQ * Double(a.basketballIQ)
            + w.durability * Double(a.durability)
        return min(99, max(0, Int(total / 100.0)))
    }

    // 界面显示的总评：手动覆盖优先，否则自动算。
    static func overall(for player: Player) -> Int {
        if let manual = player.overallOverride { return min(99, max(0, manual)) }
        return automaticOverall(for: player)
    }
}
