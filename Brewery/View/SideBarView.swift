//
//  sideBarView.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

import SwiftUI

struct SidebarView: View {

    @ObservedObject var vm: BreweryViewModel
    @Binding var selected: String?

    var body: some View {
        List(selection: $selected) {
            Section("Casks") {
                ForEach(vm.installedCasks) { cask in
                    HStack {
                        Text(cask.name)
                            .tag(cask.name as String?)
                        Spacer()
                        if cask.outdated {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(cask.cur_version)
                    }
                }
            }

            Section("Formulas") {
                ForEach(vm.installedFormula) { formula in
                    HStack {
                        Text(formula.name)
                            .tag(formula.name as String?)
                        Spacer()
                        if formula.outdated {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.orange)
                        }
                        Text(formula.cur_version)
                    }
                    
                }
            }
        }
        .listStyle(.sidebar)
    }

}

#Preview {
    SidebarView(
        vm: BreweryViewModel(),
        selected: .constant(nil)
    )
}
