//
//  HomeView.swift
//  brewery
//
//  Created by Wonjae Lim on 12/12/25.
//

import SwiftUI

struct HomeView: View {
    
    @ObservedObject var vm: BreweryViewModel
    
    var outdatedCount: Int {
        let formulae = vm.installedFormula.filter { $0.outdated }.count
        let casks = vm.installedCasks.filter { $0.outdated }.count
        return formulae + casks
    }
    
    var body: some View {
        
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                Text("Brewery")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                HStack {
                    Text(vm.brewVersion)
                    Text("·")
                    Text(vm.brewSize)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            
            HStack(spacing: 20) {
                StatCard(title: "Installed", value: "\(vm.installedFormula.count + vm.installedCasks.count)", isLoading: vm.isLoading)
                
                VStack(spacing: 16) {
                    HalfStatCard(title: "Cask", value: "\(vm.installedCasks.count)", isLoading: vm.isLoading)
                        
                    HalfStatCard(title: "Formula", value: "\(vm.installedFormula.count)", isLoading: vm.isLoading)
                }
            }
            
            HStack(spacing: 20) {
                StatCard(title: "Outdated", value:
                            "\(outdatedCount)", isLoading: vm.isLoading)
                
                VStack(spacing: 16) {
                    Button(action: { Task { await vm.brewSelfUpdate() } }) {
                        Label(vm.isRunningUpdate ? "Updating..." : vm.isLatestAfterUpdate == true ? "Latest Version" : "Brew Update", systemImage: vm.isRunningUpdate ? "arrow.triangle.2.circlepath" : vm.isLatestAfterUpdate == true ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                            .frame(width: 140)
                            .foregroundStyle(vm.isLatestAfterUpdate == true && !vm.isRunningUpdate ?
                               .green : .primary)
                    }
                    .disabled(vm.isRunningUpdate)
                    .controlSize(.large)

                    Button(action: { Task { await vm.brewCleanUp() } }) {
                        Label(vm.isRunningCleanup ? "Cleaing..." : "Brew Cleanup", systemImage: "trash")
                            .frame(width: 140)

                    }
                    .controlSize(.large)
                }
                .frame(width: 160, height: 116)
            }
        }
        .padding()
    }
}

struct StatCard: View {
    let title: String
    let value: String
    let isLoading: Bool
    
    
    var body: some View {
        VStack(spacing: 4) {
            if isLoading {
               ProgressView()
                    .frame(height: 40)
            } else {
                Text(value)
                    .font(.system(size: 36, weight: .bold, design: .rounded))
            }
            
            Text(title)
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
        .frame(width: 160, height: 116)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct HalfStatCard: View {
    let title: String
    let value: String
    let isLoading: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            if isLoading {
               ProgressView()
                    .scaleEffect(0.5)
                    .frame(height: 20)
            } else {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(width: 160, height: 50)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))

    }
}


#Preview {
    HomeView(vm: BreweryViewModel())
}
