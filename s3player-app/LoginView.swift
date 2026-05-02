//
//  LoginView.swift
//  s3player-app
//
//  Created by it3 on 5/1/26.
//

import SwiftUI

struct LoginView: View {
    @ObservedObject var auth: AuthViewModel
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case host
        case password
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    fields
                    if let errorMessage = auth.errorMessage {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    signInButton
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(24)
            }
            .navigationTitle("Sign In")
            .background(groupedBackground)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("S3 Player")
                .font(.largeTitle.bold())

            Text("Enter your host and site password to continue.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Host")
                    .font(.headline)
                TextField("Server host", text: $auth.hostText)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .host)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .padding(14)
                    .background(secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.headline)
                SecureField("Site password", text: $auth.passwordText)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .padding(14)
                    .background(secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var signInButton: some View {
        Button(action: submit) {
            Label(auth.isLoggingIn ? "Signing In" : "Sign In", systemImage: "arrow.right.circle.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(auth.isLoggingIn)
    }

    private func submit() {
        focusedField = nil
        Task { await auth.login() }
    }

    private var groupedBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(.systemGroupedBackground)
        #endif
    }

    private var secondaryGroupedBackground: Color {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(.secondarySystemGroupedBackground)
        #endif
    }
}

#Preview {
    LoginView(auth: AuthViewModel())
}
