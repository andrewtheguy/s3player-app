//
//  ContentView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var auth: AuthViewModel

    var body: some View {
        NavigationStack {
            StationsView(auth: auth)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Sign Out") {
                            auth.logout()
                        }
                    }
                }
        }
    }
}

#Preview {
    ContentView(auth: AuthViewModel())
}
