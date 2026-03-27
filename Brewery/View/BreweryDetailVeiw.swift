//
//  brewDetailVeiw.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

import SwiftUI
import AppKit

struct BreweryDetailView: View {
    // BreweryViewModel 안에 있는 @Published 객체의 변경을 감지
    @ObservedObject var vm: BreweryViewModel

    let name: String
    let onNavigate: (String) -> Void

    @State private var showMoreInfo = false
    @State private var brewInfoText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let formula = vm.getFormula(for: name) {
                    detailFormulaSection(formula: formula)
                } else if let cask = vm.getCask(for: name) {
                    detailCaskSection(cask: cask)
                } else {
                    Text("Information not found.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
        .frame(maxWidth: .infinity)
        .navigationTitle(name)
        .onAppear {
            Task { brewInfoText = await vm.fetchInfo(name: name) }
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
                    if formula.outdated {
                        Text("→ \(formula.latest_version)")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        
                        if vm.updatingPackageNames.contains(formula.name) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("update") {
                                Task { await vm.updateBrew(name: formula.name, isCask: false) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    } else { // 최신버전일 때
                        Text("latest")
                            .font(.subheadline)
                            .foregroundStyle(.green)
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
                    GroupBox {
                        FlowLayout(spacing: 6) {
                            ForEach(formula.dependencies, id: \.self) { dep in
                                Button(dep) {
                                    onNavigate(dep)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .onHover { hovering in
                                    hovering ? NSCursor.pointingHand.push() : NSCursor.pop()
                                }
                            }
                        }
                        .padding(4)
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
                
                Button("uninstall", role: .destructive, action: { Task { await vm.uninstallFormula(name: formula.name) } })
                    .tint(.red)
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
                    if cask.outdated {
                        Text("→ \(cask.latest_version)")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                        
                        if vm.updatingPackageNames.contains(cask.name) {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("update") {
                                Task { await vm.updateBrew(name: cask.name, isCask: true) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    } else {
                        Text("latest")
                            .font(.subheadline)
                            .foregroundStyle(.green)
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
                        infoRow(key: "auto updates", value: cask.auto_updates == true ? "O" : "X")
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
                    Button("uninstall", role: .destructive) {
                        Task { await vm.uninstallCask(name: cask.name) }
                    }
                    
                    Button("uninstall + delete data", role: .destructive) {
                        Task { await vm.uninstallCaskWithZap(name: cask.name) }
                    }
                } label: {
                    Text("uninstall")
                        .foregroundStyle(.red)
                }
                
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
    }
}

// 태그처럼 가로로 흘러내리는 레이아웃
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX && x > bounds.minX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#Preview {
    BreweryDetailView(vm: BreweryViewModel(), name: "curl", onNavigate: { _ in })
}
