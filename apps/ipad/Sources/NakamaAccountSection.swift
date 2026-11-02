import SwiftUI
import AuthenticationServices

struct NakamaAccountSection: View {
    @Environment(MangaLibrary.self) private var library
    var body: some View {
        let account = library.backendAuthentication
        Section(L("Backend account")) {
            if let unavailable = account.unavailable {
                Text(unavailable).font(.caption).foregroundStyle(.secondary)
            } else {
                if let user = account.user {
                    LabeledContent(L("Backend account ID"), value: user.id).font(.caption).textSelection(.enabled)
                    LabeledContent(L("Apple ID linked"), value: L(user.apple_id?.isEmpty == false ? "Yes" : "No"))
                    Text(L("Guest sign-in uses a random device credential stored in Keychain. Linking Apple keeps the same backend account."))
                        .font(.caption).foregroundStyle(.secondary)
                    NakamaAppleSignInButton()
                    Button(L("Sign out of backend")) { Task { await account.signOut() } }
                        .disabled(account.working || library.busy || library.downloadingModel)
                } else {
                    NakamaSignInButtons()
                }
                if account.working { ProgressView() }
                if let message = account.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text(L("Your profile, credits and membership are synced with your account."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct NakamaSignInButtons: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(spacing: 12) {
            Button { Task { await library.backendAuthentication.signInDevice() } } label: {
                Label(L("Sign in as guest"), systemImage: "person.crop.circle.fill")
                    .font(.system(size: 20, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                    .background(colorScheme == .dark ? Color.white : Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .disabled(library.backendAuthentication.working)
            .accessibilityIdentifier("nakama-sign-in-device")
            NakamaAppleSignInButton()
        }.padding(.vertical, 8)
    }
}

struct NakamaAppleSignInButton: View {
    @Environment(MangaLibrary.self) private var library
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var phase
    @State private var appleState = ""
    var body: some View {
        let account = library.backendAuthentication
        Group {
            #if targetEnvironment(simulator)
            Text(L("Test Apple sign-in on a physical iPad or iPhone signed into iCloud."))
                .font(.caption).foregroundStyle(.secondary)
            #else
            SignInWithAppleButton(.signIn) { request in
                appleState = UUID().uuidString
                request.requestedScopes = []
                request.state = appleState
                request.nonce = account.challenge?.nonce ?? UUID().uuidString
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                          credential.state == appleState, let data = credential.identityToken,
                          let token = String(data: data, encoding: .utf8), !token.isEmpty else {
                        account.message = L("Apple did not return a valid identity token. Please try again.")
                        return
                    }
                    Task { await account.signInApple(identityToken: token) }
                case .failure(let error):
                    if (error as? ASAuthorizationError)?.code != .canceled {
                        account.message = L("Apple sign-in could not be completed. Check iCloud and try again.")
                    }
                }
            }
            .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
            .frame(height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .disabled(account.working || account.challenge?.usable != true)
            .accessibilityIdentifier("nakama-sign-in-apple")
            if account.challenge?.usable != true && !account.working {
                Button(L("Prepare Apple sign-in")) { Task { await account.prepareAppleSignIn() } }
            }
            #endif
        }
        .task { if account.challenge?.usable != true { await account.prepareAppleSignIn() } }
        .onChange(of: phase) { _, phase in
            if phase == .active && account.challenge?.usable != true {
                Task { await account.prepareAppleSignIn() }
            }
        }
    }
}
