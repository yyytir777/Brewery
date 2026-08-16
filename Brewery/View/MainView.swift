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
    @State private var selected: String? = "__home"
    @State private var discoverFocusRequest = 0
    @StateObject private var discoverViewModel = DiscoverViewModel(service: CatalogService.production())

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm, selected: $selected)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
                .focusable(false)
        } detail: {
            if selected == "__discover" {
                DiscoverView(viewModel: discoverViewModel, breweryViewModel: vm, focusRequest: discoverFocusRequest) { id in selected = id.name }
                    .frame(minWidth: 560, minHeight: 360)
            } else if let name = selected, name != "__home" {
                BreweryDetailView(vm: vm, name: name) { dep in
                    selected = dep
                }
                    .id(selected)
                    .frame(minWidth: 380)
            } else {
                HomeView(vm: vm)
                    .frame(minWidth: 380, minHeight: 280, alignment: .top)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { selected = "__home" }) {
                    Label("Home", systemImage: "house")
                }
                Button(action: { selected = "__discover"; discoverFocusRequest += 1 }) {
                    Label("Discover", systemImage: "magnifyingglass")
                }
            }
        }
        .onTapGesture {
            Task { @MainActor in
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .alert("Homebrew Command Failed", isPresented: Binding(
            get: { vm.lastCommandError != nil },
            set: { if !$0 { vm.lastCommandError = nil } }
        )) {
            Button("OK") { vm.lastCommandError = nil }
        } message: {
            Text(vm.commandErrorMessage)
        }
    }
}

#Preview {
    MainView()
}
