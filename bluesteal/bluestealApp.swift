//
//  bluestealApp.swift
//  bluesteal
//
//  Created by James Westgate on 18/05/2026.
//

import SwiftUI

@main
struct bluestealApp: App {
    @State private var scanner = CableScanner()
    @State private var store = AdvertStore(logger: JSONLLogger())

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(scanner)
                .environment(store)
        }
    }
}
