//
//  breweryApp.swift
//  brewery
//
//  Created by Wonjae Lim on 12/11/25.
//

import SwiftUI

@main
struct breweryApp: App {
    
    var body: some Scene {
        WindowGroup {
            MainView()
        }
        .defaultSize(width: 900, height: 600)
        .windowResizability(.contentMinSize)
    }
}
