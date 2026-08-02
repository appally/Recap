import SwiftUI
import AuthenticationServices
import RecapModels

/// Sign in with Apple + 凭证吊销检查。
struct AppleSignInSection: View {
    var onSignedIn: () -> Void
    var onMessage: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handle(result)
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 48)
            .clipShape(Capsule())

            Text("登录后可绑定订阅。未登录也能用端侧能力与自备密钥；未经同意不会上传会议内容。")
                .font(.recapMeta)
                .foregroundStyle(Color.recapTea.opacity(0.6))
                .lineSpacing(Leading.tight)
        }
    }

    private func handle(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .failure(let error):
            let ns = error as NSError
            if ns.domain == ASAuthorizationError.errorDomain,
               ns.code == ASAuthorizationError.canceled.rawValue {
                onMessage("已取消登录")
            } else {
                onMessage("Apple 登录失败：\(error.localizedDescription)")
            }
        case .success(let auth):
            guard let credential = auth.credential as? ASAuthorizationAppleIDCredential else {
                onMessage("无法读取 Apple 凭证")
                return
            }
            RecapAccountStore.signInWithApple(
                userID: credential.user,
                fullName: credential.fullName,
                email: credential.email
            )
            // 免费档「登录续杯」:把 identityToken 注入凭证提供者,触发一次 issue 上网关验签、升级月度档。
            if AIServiceMode.current == .freeTrial,
               let tokenData = credential.identityToken,
               let jwt = String(data: tokenData, encoding: .utf8) {
                RecapCredentialProvider.shared.setIdentityTokenForElevation(jwt)
                Task { try? await RecapCredentialProvider.shared.ensureFresh(force: true) }
            }
            onSignedIn()
            onMessage("已通过 Apple 登录")
        }
    }
}

public enum AppleCredentialChecker {
    /// 若本地为 Apple 登录且系统侧已吊销/失效，则清掉本机登录态。
    public static func reconcileIfNeeded() async {
        let account = RecapAccountStore.current
        guard account.isSignedIn, account.provider == .apple, let userID = account.userID else {
            return
        }

        let provider = ASAuthorizationAppleIDProvider()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            provider.getCredentialState(forUserID: userID) { state, _ in
                switch state {
                case .revoked, .notFound:
                    Task { @MainActor in
                        RecapAccountStore.signOut()
                    }
                case .authorized, .transferred:
                    break
                @unknown default:
                    break
                }
                continuation.resume()
            }
        }
    }
}
