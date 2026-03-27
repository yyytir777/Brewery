//
//  SearchView.swift
//  Brewery
//
//  Created by Wonjae Lim on 3/27/26.
//

import SwiftUI

struct SearchView: View {
    @ObservedObject var vm: BreweryViewModel
    @Binding var selected: String?
    @Binding var showSearch: Bool
    @State private var query = ""
    @State private var hasSearched = false
    
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search packages...", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTextFieldFocused)
                    .onSubmit {
                        runSearch()
                    }
                Button("Search") {
                    runSearch()
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || vm.isSearching)
            }
            .padding()
            
            Divider()
            
            if vm.isSearching {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !hasSearched {
                Text("Search for a formla or cask")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.searchResults.isEmpty {
                Text("No results for \"\(query)\"")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.searchResults) { result in
                    SearchResultRow(vm: vm, result: result) {
                        selected = result.name
                        showSearch = false
                    }
                }
            }
        }
        .onAppear { isTextFieldFocused = true }
    }
    
    private func runSearch() {
        hasSearched = true
        Task { await vm.search(query: query) }
    }
}

struct SearchResultRow: View {
    @ObservedObject var vm: BreweryViewModel
    let result: SearchResult
    let onNavigate: () -> Void
    
    @State private var showPreview = false
    
    var isInstalled: Bool {
        result.isCask ? vm.getCask(for: result.name) != nil : vm.getFormula(for: result.name) != nil
    }
    
    var isInstalling: Bool {
        vm.installingPackages.contains(result.name)
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .fontWeight(.medium)
                Text(result.isCask ? "Cask" : "Formula")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            if isInstalling {
                ProgressView().scaleEffect(0.7)
            } else if isInstalled {
                Button("View") {
                    onNavigate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(width: 60)
            } else {
                Button("View") {
                    showPreview = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(width: 60)
                .popover(isPresented: $showPreview) {
                    PackagePreviewView(vm: vm, name: result.name, isCask: result.isCask)
                }
                
                Button("Install") {
                    Task {
                        if result.isCask { await vm.installCask(name: result.name) }
                        else { await vm.installFormula(name: result.name) }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: 60)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    SearchView(vm: BreweryViewModel(), selected: .constant(nil), showSearch: .constant(true))
}
