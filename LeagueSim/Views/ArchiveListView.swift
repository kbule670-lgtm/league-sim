import SwiftUI

// 存档列表：App 打开先到这里。
// 当前存档：上次进入过的存档，行尾有“当前”标记；点任何一行就是切换（先存后载）。
// 存档数量不限：新建不设槽位上限；删除要二次确认。
struct ArchiveListView: View {
    @EnvironmentObject private var store: LeagueStore
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var archiveToDelete: ArchiveMeta?
    @State private var archiveToRename: ArchiveMeta?
    @State private var renameText = ""

    private var currentId: UUID? { ArchiveStore.loadCurrentArchiveId() }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("每个存档都是一个完全独立的联赛：30 队、球员、赛季、快照、设置互不串数据。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("全离线：不登录、不联网、不走云同步，飞行模式下也能建档、编辑、模拟、看快照。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("我的存档（\(store.archives.count) 个）") {
                    if store.archives.isEmpty {
                        Text("还没有存档，点右上角“新建”开一个联赛。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.archives, id: \.id) { meta in
                        Button {
                            store.enterArchive(id: meta.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(meta.name).font(.headline)
                                    Text("\(meta.teamCount) 队 · \(meta.seasonCount) 个赛季")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if meta.id == currentId {
                                    Text("当前")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.orange.opacity(0.2))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .swipeActions {
                            Button("改名") {
                                archiveToRename = meta
                                renameText = meta.name
                            }.tint(.blue)
                            Button("删除", role: .destructive) {
                                archiveToDelete = meta
                            }
                        }
                    }
                }
            }
            .navigationTitle("篮球联赛模拟")
            .toolbar {
                Button("新建") { showingCreate = true }
            }
            .alert("新建存档", isPresented: $showingCreate) {
                TextField("联赛名字", text: $newName)
                Button("取消", role: .cancel) { newName = "" }
                Button("创建") {
                    store.createArchive(name: newName)
                    newName = ""
                }
            } message: {
                Text("新存档会生成 30 个空壳队（球队 1 到球队 30），队名和球员都由你在 App 内自己填，不预置任何真实球队球员。")
            }
            .alert("改名", isPresented: Binding(
                get: { archiveToRename != nil },
                set: { if !$0 { archiveToRename = nil } }
            )) {
                TextField("新名字", text: $renameText)
                Button("取消", role: .cancel) { archiveToRename = nil }
                Button("保存") {
                    if let meta = archiveToRename {
                        if store.currentLeague?.id == meta.id {
                            store.renameCurrentLeague(to: renameText)
                        } else if var league = ArchiveStore.loadLeague(id: meta.id) {
                            league.name = renameText
                            league.updatedAt = Date()
                            _ = ArchiveStore.saveLeague(league)
                            store.refreshArchives()
                        }
                    }
                    archiveToRename = nil
                }
            }
            .alert("删除存档？", isPresented: Binding(
                get: { archiveToDelete != nil },
                set: { if !$0 { archiveToDelete = nil } }
            )) {
                Button("取消", role: .cancel) { archiveToDelete = nil }
                Button("删除", role: .destructive) {
                    if let meta = archiveToDelete { store.deleteArchive(id: meta.id) }
                    archiveToDelete = nil
                }
            } message: {
                Text("这个存档的 30 队、球员、赛季快照会全部删除，不可恢复。")
            }
            .onAppear { store.refreshArchives() }
        }
    }
}

// 当前联赛的存档管理 Tab：改名、回列表、删当前存档（二次确认）。
struct ArchiveSettingsView: View {
    @EnvironmentObject private var store: LeagueStore
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var showingDelete = false

    var body: some View {
        NavigationStack {
            List {
                if let league = store.currentLeague {
                    Section("当前存档") {
                        Text(league.name).font(.headline)
                        Text("\(league.teams.count) 队 · \(league.seasons.count) 个赛季")
                            .foregroundStyle(.secondary)
                        Text("存档文件：本地 Documents/LeagueSim/Archives/\(league.id.uuidString)/，不走云端。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button("改名") {
                            renameText = league.name
                            showingRename = true
                        }
                        Button("保存并回到存档列表") {
                            store.backToArchiveList()
                        }
                        Button("删除当前存档", role: .destructive) {
                            showingDelete = true
                        }
                    }
                    Section("离线说明") {
                        Text("本 App 不登录、不联网、不调用任何网络接口。飞行模式下建档、编辑、模拟、看快照全部可用。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("存档")
            .alert("改名", isPresented: $showingRename) {
                TextField("新名字", text: $renameText)
                Button("取消", role: .cancel) {}
                Button("保存") { store.renameCurrentLeague(to: renameText) }
            }
            .alert("删除当前存档？", isPresented: $showingDelete) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    if let id = store.currentLeague?.id { store.deleteArchive(id: id) }
                }
            } message: {
                Text("删除后不可恢复，回到存档列表。")
            }
        }
    }
}
