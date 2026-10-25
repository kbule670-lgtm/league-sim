# 篮球联赛模拟（LeagueSim）— P0 本地工程

显示名：篮球联赛模拟 · Bundle ID：com.kabule.leaguesim · iOS 17+ · SwiftUI
本阶段只写本地代码：没有推送 GitHub，没有云端编译，没有出 ipa。

## P0 做到了什么

1. 30 队名单管理
   - 固定 30 队，不增删球队；队名、缩写、分区、主场、配色都可改。
   - 每队名单分首发 5 人、替补、inactive；轮换顺序可上移/下移。
   - 校验提醒（不硬拦）：激活 12-15 人、首发 5 人、球衣号冲突、激活名单缺位置。
   - 联盟提醒：95+ 超 3 人、90+ 超 12 人、联盟平均不在 70-75 时提示。
2. 球员能力编辑器
   - 基本信息 + 位置 PG/SG/SF/PF/C + 年龄 + 身高体重 + 12 项分项 0-99。
   - 总评按位置权重自动算，可手动覆盖；潜力不计入当前总评。
   - 投射 = 三分与中投的均值，代码见 `Rating.swift`；权重和均为 100。
3. 单赛季模拟（可复现）
   - 输入种子，确定性随机数（SplitMix64），同一名单 + 同一种子 = 同一结果。
   - 赛程：单循环，每两队 1 场（P0 不是 82 场）；输出每场比分、球员 box、赛季场均/累计、球队战绩、分区排名。
   - 球队评分 = 前 8 人分钟加权总评×0.65 + 替补深度×0.15 + 化学反应×0.1 + 教练×0.1（化学/教练默认 70 可调）。
   - 预期胜率 = 1 / (1 + exp(-(球队评分 - 联盟平均) / 8))，再叠加随机波动与主场加分。
   - 参赛资格：激活 >= 5 人的球队；不够 5 人的队列入未参赛，不进排名。
4. 赛季快照
   - 跑完自动追加一条冻结快照：比分、战绩、场均、球员名/队名全部存死，之后改名单不污染历史。
   - 历史页可按赛季、球员、球队查看；比赛详情可看双方 box。
5. 本地持久化
   - JSON 存 Documents，不联网。见“多存档”。

## 多存档（P0 必做）

- App 打开先到存档列表，当前存档（上次进入过的）行尾有“当前”标记。
- 每个存档一个独立目录：`Documents/LeagueSim/Archives/<存档ID>/league.json + meta.json`，
  自己的 30 队、球员、赛季、快照、设置、种子，互不串数据；球员 ID 只在同存档内稳定。
- 操作：新建、改名、切换、删除，数量不限。切换 = 先保存当前存档，再加载目标存档。
- 删除要二次确认，删整个存档目录，不可恢复。
- P0 验收方法：建两个存档，各改一队名、跑一赛季，切换后各自的队名与赛季互不影响。

## 全离线（P0 核心场景：没网时打发时间）

- 全离线可玩：建存档、编辑球队球员、模拟赛季、看战绩快照，飞行模式下都要能用。
- 不登录、不联网、不走云同步、不调任何网络接口：代码里没有 URLSession、
  没有网络请求、没有账号体系；联网/云同步一律不进 P0。
- 初始数据：不导 NBA、不导以前的真实历史数据、不预置真实球队球员。
  新存档只有 30 个空壳队（球队 1 到球队 30），队名球员全部由用户在 App 内自己填。
- “生成虚构测试名单”是用户点了按钮后才生成的占位球员（测试球员 1-13），
  不是预置数据，更不是真实球员，目的是不用手动填 30 队就能先验收模拟与快照。

## 明确不做（P1/P2）

奖项、季后赛、排行榜可视化、趋势图、赛季报告、多赛季成长/衰退、退役、
选秀、自由市场、交易、伤病、禁赛、G 联赛、工资帽、云同步、社区分享、
名单 CSV/JSON 导入导出（P0 只有内部 JSON 存档文件，没有导入导出入口）。

## 文件清单

- `project.yml`：XcodeGen 工程定义，Bundle ID com.kabule.leaguesim
- `.github/workflows/build-ipa.yml`：只备好、未执行，供下一步整批上传后云端跑
- `LeagueSim/LeagueSimApp.swift`：入口 + 根 Tab（球队/模拟/历史/存档）
- `LeagueSim/Info.plist`：显示名与场景配置
- `LeagueSim/Models/Models.swift`：位置/能力/球员/球队/联赛/比赛/统计/快照/存档元数据
- `LeagueSim/Models/Rating.swift`：位置权重与总评
- `LeagueSim/Models/SeededRandom.swift`：确定性随机数
- `LeagueSim/Services/ArchiveStore.swift`：多存档本地 JSON 存储
- `LeagueSim/Services/SimulationEngine.swift`：单循环赛季模拟
- `LeagueSim/Services/Validation.swift`：名单与联盟提醒
- `LeagueSim/ViewModels/LeagueStore.swift`：存档切换（先存后载）与联赛操作
- `LeagueSim/Views/ArchiveListView.swift`：存档列表 + 当前联赛存档管理
- `LeagueSim/Views/TeamsView.swift`：球队列表 + 球队详情 + 名单管理
- `LeagueSim/Views/PlayerEditorView.swift`：球员能力编辑器
- `LeagueSim/Views/SimulationView.swift`：模拟 + 历史快照查看
- `LeagueSim/Assets.xcassets/AppIcon.appiconset/`：占位图标（橙底白圈，编译可用，美术未定稿）

## 下一步整批上传云端编译前，还需要用户确认

1. 显示名“篮球联赛模拟”、Bundle ID com.kabule.leaguesim 是否就这么定（改了要重签）。
2. 图标目前是占位橙底白圈，是否先用它出 1.ipa，还是先定一版正式图标再上传。
3. 是否接受 P0 赛程是单循环（每队 29 场）而不是 82 场；要改 82 场的话模拟与快照数据量会大很多，需在上传前定。
4. 上传方式沿用刷题 App：整批一次传到新仓库、云端 Mac 编译一次出未签名 ipa，再用全能签签名——本阶段未推送、未编译。
