//
//  PackagePreviewView.swift
//  Brewery
//
//  Created by Wonjae Lim on 3/27/26.
//

import SwiftUI

struct PackagePreviewView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject var vm: BreweryViewModel
    let name: String
    let isCask: Bool
    
    @State private var formula: BreweryFormula? = nil
    @State private var cask: BreweryCask? = nil
    @State private var isLoading: Bool = true
    
    var desc: String? { formula?.desc ?? cask?.desc }
    var homepage: String { formula?.homepage ?? cask?.homepage ?? "" }
    var version: String { formula?.latest_version ?? cask?.latest_version ?? "unknown" }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isLoading {
                HStack {
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                }
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text(name)
                        .font(.title2.bold())
                    
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.title2)
                    }
                    .buttonStyle(.plain)
                }
                
                if let desc {
                    Text(desc)
                        .foregroundStyle(.secondary)
                }
                
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Info")
                        .font(.headline)
                    GroupBox {
                        VStack(spacing: 0) {
                            infoRow(key: "Version", value: version)
                            Divider()
                            infoLinkRow(key: "Homepage", url: homepage)
                        }
                    }
                }
                
                Divider()
                
                HStack {
                    Spacer()
                    Button("Install") {
                        Task {
                            if isCask { await vm.installCask(name: name) }
                            else { await vm.installFormula(name: name) }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.installingPackages.contains(name))
                }
                
            }
        }
        .padding(24)
        .frame(width: 600)
        .task {
            let info = await vm.fetchPackageInfo(name: name, isCask: isCask)
            formula = info.formula
            cask = info.cask
            isLoading = false
        }
    }
}

#Preview {
    PackagePreviewView(vm: BreweryViewModel(), name: "git", isCask: false)
}
