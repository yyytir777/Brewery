//
//  mainView.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

import SwiftUI

struct MainView: View {
    // 설치된 Cask, Formula 저장
    @StateObject var vm = BreweryViewModel()
    @State private var selected: String? = nil
    @State private var searchText = ""
    @State private var showSearch = false

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm, selected: $selected)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
                .focusable(false)
        } detail: {
            if let name = selected {
                BreweryDetailView(vm: vm, name: name) { dep in
                    selected = dep
                }
                    .id(selected)
                    .frame(minWidth: 500)
            } else if showSearch {
                SearchView(vm: vm, selected: $selected, showSearch: $showSearch)
                    .frame(minWidth: 500, minHeight: 300, alignment: .top)
            } else {
                HomeView(vm: vm)
                    .frame(minWidth: 500, minHeight: 300, alignment: .top)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { selected = nil; showSearch = false }) {
                    Label("Home", systemImage: "house")
                }
                Button(action: { selected = nil; showSearch.toggle()}) {
                    Label("Search", systemImage: "magnifyingglass")
                }
            }
        }
        .onTapGesture {
            Task { @MainActor in
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }
}

#Preview {
    MainView()
}
