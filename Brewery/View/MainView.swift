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
    @State private var selected: PackageID? = nil
    @State private var showDiscover = false
    @State private var discoverFocusRequest = 0
    @StateObject private var discoverViewModel = DiscoverViewModel(service: CatalogService.production())

    var body: some View {
        NavigationSplitView {
            SidebarView(vm: vm, selected: $selected, showDiscover: $showDiscover)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 350)
                .focusable(false)
        } detail: {
            if showDiscover {
                DiscoverView(
                    viewModel: discoverViewModel,
                    breweryViewModel: vm,
                    focusRequest: discoverFocusRequest
                ) { packageID in
                    selected = packageID
                    showDiscover = false
                }
                .frame(minWidth: 560, minHeight: 360)
            } else if let packageID = selected {
                BreweryDetailView(vm: vm, packageID: packageID) { dep in
                    selected = .formula(dep)
                }
                    .id(packageID.id)
                    .frame(minWidth: 380)
            } else {
                HomeView(vm: vm)
                    .frame(minWidth: 380, minHeight: 280, alignment: .top)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button(action: { selected = nil; showDiscover = false }) {
                    Label("Home", systemImage: "house")
                }
                Button(action: {
                    selected = nil
                    showDiscover = true
                    discoverFocusRequest += 1
                }) {
                    Label("Discover", systemImage: "magnifyingglass")
                }
            }
        }
        .alert("Homebrew Command Failed", isPresented: Binding(
            get: { vm.lastCommandError != nil },
            set: { isPresented in
                if !isPresented {
                    vm.clearCommandError()
                }
            }
        )) {
            Button("OK") {
                vm.clearCommandError()
            }
        } message: {
            Text(vm.commandErrorMessage)
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
