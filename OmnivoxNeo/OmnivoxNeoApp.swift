//
//  OmnivoxNeoApp.swift
//  OmnivoxNeo
//
//  Created by Thomas on 2026-09-03.
//

import SwiftUI

@main
struct OmnivoxNeoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 720, height: 860)
        #endif
    }
}
