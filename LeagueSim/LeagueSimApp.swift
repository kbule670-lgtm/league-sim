import SwiftUI

// App 入口：只搭状态，不登录、不联网。
// 全离线：这里没有任何网络、账号、云同步初始化。
@main
struct LeagueSimApp: App {
    @StateObject private var store = LeagueStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
    }
}

// 根视图：App 打开先到存档列表（当前存档一眼看得出，见 ArchiveListView）。
// 选了存档后才进联赛 Tab；回存档列表时会先保存当前存档。
struct ContentView: View {
    @EnvironmentObject private var store: LeagueStore

    var body: some View {
        if let league = store.currentLeague {
            TabView {
                TeamsView(league: league)
                    .tabItem { Label("球队", systemImage: "sportscourt") }
                SimulationView()
                    .tabItem { Label("模拟", systemImage: "play.circle") }
                HistoryView()
                    .tabItem { Label("历史", systemImage: "clock") }
                ArchiveSettingsView()
                    .tabItem { Label("存档", systemImage: "folder") }
            }
            .onAppear { store.refreshArchives() }
        } else {
            ArchiveListView()
        }
    }
}
