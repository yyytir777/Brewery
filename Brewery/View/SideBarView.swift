//
//  sideBarView.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

import SwiftUI

struct SidebarView: View {

    @ObservedObject var vm: BreweryViewModel
    @Binding var selected: PackageID?
    @Binding var showDiscover: Bool

    var body: some View {
        List(selection: $selected) {
            Section {
                Button {
                    selected = nil
                    showDiscover = false
                } label: {
                    Label("Home", systemImage: "house")
                }
                .buttonStyle(.plain)

                Button {
                    selected = nil
                    showDiscover = true
                } label: {
                    Label("Discover", systemImage: "safari")
                }
                .buttonStyle(.plain)
            }
            Section("Casks") {
                ForEach(vm.installedCasks) { cask in
                    HStack {
                        Text(cask.name)
                            .tag(PackageID.cask(cask.name) as PackageID?)
                        Spacer()
                        if vm.isOutdated(.cask(cask.name)) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(cask.cur_version)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
            }

            Section("Formulas") {
                ForEach(vm.installedFormula) { formula in
                    HStack {
                        Text(formula.name)
                            .tag(PackageID.formula(formula.name) as PackageID?)
                        Spacer()
                        if vm.isOutdated(.formula(formula.name)) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(formula.cur_version)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selected) { packageID in
            if packageID != nil {
                showDiscover = false
            }
        }
    }

}

#Preview {
    SidebarView(
        vm: BreweryViewModel(),
        selected: .constant(nil),
        showDiscover: .constant(false)
    )
}
