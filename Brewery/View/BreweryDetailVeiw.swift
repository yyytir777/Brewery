//
//  brewDetailVeiw.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

import SwiftUI

struct BreweryDetailView: View {
    // BreweryViewModel 안에 있는 @Published 객체의 변경을 감지
    @ObservedObject var vm: BreweryViewModel

    let packageID: PackageID
    let onNavigate: (String) -> Void

    @State private var showMoreInfo = false
    @State private var brewInfoText = ""
    @State private var showUninstallConfirm = false
    @State private var zapOnUninstall = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let error = vm.outdatedError {
                    InventoryErrorBanner(message: vm.hasLoadedOutdated ? "Showing the last successful update check.\n\(error)" : error) {
                        Task { await vm.loadInstalled() }
                    }
                }
                if let formula = vm.formula(for: packageID) {
                    detailFormulaSection(formula: formula)
                } else if let cask = vm.cask(for: packageID) {
                    detailCaskSection(cask: cask)
                } else {
                    Text("This package is no longer installed. Choose another package from Installed or search in Search.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(packageID.name)
        .accessibilityIdentifier("detail.\(packageID.id)")
        .task(id: packageID.id) {
            brewInfoText = await vm.fetchInfo(name: packageID.name, isCask: packageID.kind == .cask)
        }
    }

    private func detailFormulaSection(formula: BreweryFormula) -> some View {
        VStack(alignment: .leading, spacing: 20) {

            // 헤더
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(formula.cur_version)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                    if vm.isOutdated(formula.packageID) {
                        Text("-> \(formula.latest_version)")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        
                        if vm.isOperating(formula.packageID) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Update") {
                                Task { await vm.updateBrew(name: formula.packageID.name, isCask: false) }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("detail.update")
                            .controlSize(.small)
                        }
                    } else {
                        Text(LocalizedStringKey(vm.hasLoadedOutdated && vm.outdatedError == nil ? "Latest" : "Update status unknown"))
                            .font(.subheadline)
                            .foregroundStyle(vm.hasLoadedOutdated && vm.outdatedError == nil ? .green : .secondary)
                    }
                }
                if let desc = formula.desc {
                    Text(desc)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            // 정보
            VStack(alignment: .leading, spacing: 8) {
                Text("Info")
                    .font(.headline)
                GroupBox {
                    VStack(spacing: 0) {
                        infoRow(key: "Full name", value: formula.full_name)
                        Divider()
                        infoLinkRow(key: "Homepage", url: formula.homepage)
                        Divider()
                        infoRow(key: "License", value: formula.license ?? "unknown")
                        if let date = formula.installed_date {
                            Divider()
                            infoRow(key: "Installation Date", value: Date(timeIntervalSince1970: date).formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                }
            }
            

            // 의존성
            if !formula.dependencies.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dependencies")
                        .font(.headline)
                    DependencyGraphView(
                        root: formula,
                        loader: { name in
                            try await vm.resolveFormulaForDependencyGraph(name: name)
                        },
                        onNavigate: onNavigate
                    )
                    .id(formula.packageID.id)
                }
            }
                
            HStack {
                Button(action: { showMoreInfo.toggle() }) {
                    HStack {
                        Text("More info")
                        Image(systemName: showMoreInfo ? "chevron.up" : "chevron.down")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("Uninstall", role: .destructive) {
                    zapOnUninstall = false
                    showUninstallConfirm = true
                }
                .tint(.red)
                .accessibilityIdentifier("detail.uninstall")
                .disabled(vm.isOperating(formula.packageID) || vm.isHomebrewAvailable == false)
            }

            if showMoreInfo {
                ScrollView {
                    Text(brewInfoText.isEmpty ? "Loading..." : brewInfoText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .textSelection(.enabled)
            }

        }
        .confirmationDialog("Uninstall \(formula.name)?", isPresented: $showUninstallConfirm, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) {
                Task { await vm.uninstallFormula(name: formula.packageID.name) }
            }
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private func detailCaskSection(cask: BreweryCask) -> some View {
        VStack(alignment: .leading, spacing: 20) {

            // 헤더
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(cask.cur_version)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .textSelection(.enabled)
                    if vm.isOutdated(cask.packageID) {
                        Text("-> \(cask.latest_version)")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        
                        if vm.isOperating(cask.packageID) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Update") {
                                Task { await vm.updateBrew(name: cask.packageID.name, isCask: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("detail.update")
                            .controlSize(.small)
                        }
                    } else {
                        Text(LocalizedStringKey(vm.hasLoadedOutdated && vm.outdatedError == nil ? "Latest" : "Update status unknown"))
                            .font(.subheadline)
                            .foregroundStyle(vm.hasLoadedOutdated && vm.outdatedError == nil ? .green : .secondary)
                            .textSelection(.enabled)
                    }
                }
                if let desc = cask.desc {
                    Text(desc)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            // 정보
            VStack(alignment: .leading, spacing: 8) {
                Text("Info")
                    .font(.headline)
                GroupBox {
                    VStack(spacing: 0) {
                        if let date = cask.installed_time {
                            infoRow(key: "Installation Date", value: Date(timeIntervalSince1970: date).formatted(date: .abbreviated, time: .omitted))
                        }
                        
                        Divider()
                        infoLinkRow(key: "Homepage", url: cask.homepage)
                        Divider()
                        infoRow(key: "Auto updates", value: cask.auto_updates == true ? "Yes" : "No")
                    }
                }
            }
            
            HStack {
                Button(action: { showMoreInfo.toggle() }) {
                    HStack {
                        Text("More info")
                        Image(systemName: showMoreInfo ? "chevron.up" : "chevron.down")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                
                Spacer()
                
                Menu {
                    Button("Uninstall", role: .destructive) {
                        zapOnUninstall = false
                        showUninstallConfirm = true
                    }

                    Button("Uninstall and Delete Data", role: .destructive) {
                        zapOnUninstall = true
                        showUninstallConfirm = true
                    }
                    .accessibilityIdentifier("detail.uninstallAndDeleteData")
                } label: {
                    Text("Uninstall")
                }
                .tint(.red)
                .accessibilityIdentifier("detail.uninstall")
                .disabled(vm.isOperating(cask.packageID) || vm.isHomebrewAvailable == false)
                
            }

            if showMoreInfo {
                ScrollView {
                    Text(brewInfoText.isEmpty ? "Loading..." : brewInfoText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
                .textSelection(.enabled)
            }
        }
        .confirmationDialog(
            zapOnUninstall ? "Uninstall \(cask.name) and delete data?" : "Uninstall \(cask.name)?",
            isPresented: $showUninstallConfirm,
            titleVisibility: .visible
        ) {
            Button(zapOnUninstall ? "Uninstall and Delete Data" : "Uninstall", role: .destructive) {
                Task {
                    if zapOnUninstall {
                        await vm.uninstallCaskWithZap(name: cask.packageID.name)
                    } else {
                        await vm.uninstallCask(name: cask.packageID.name)
                    }
                }
            }
        } message: {
            Text(zapOnUninstall ? "This also deletes associated settings and data, including files that may be shared with other apps. This cannot be undone." : "This action cannot be undone.")
        }
    }
}

#Preview {
    BreweryDetailView(vm: BreweryViewModel(), packageID: .formula("curl"), onNavigate: { _ in })
}
