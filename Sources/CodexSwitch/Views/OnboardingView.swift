import SwiftUI

/// First-run onboarding presented as a standalone NSWindow on initial launch.
/// Three screens: Welcome -> Add Accounts -> Setup Complete.
struct OnboardingView: View {
    var onAddAccount: () -> Void
    var onComplete: () -> Void

    /// Tracks added account count from the parent AccountManager.
    /// Updated externally whenever the account list changes.
    var accountCount: Int

    @State private var currentPage = 0

    var body: some View {
        VStack(spacing: 0) {
            // Page content
            Group {
                switch currentPage {
                case 0: welcomePage
                case 1: addAccountsPage
                default: setupCompletePage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Page indicator dots
            HStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(index == currentPage ? Color.green : Color.gray.opacity(0.4))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.bottom, 16)
        }
        .frame(width: 400, height: 500)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Screen 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "bolt.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .padding(.bottom, 4)

            Text("Welcome to CodexSwitch")
                .font(.system(size: 22, weight: .bold))

            Text("Seamlessly rotate between multiple ChatGPT Plus accounts in Codex CLI and Codex Desktop. Never hit rate limits again.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Spacer()

            Button(action: { withAnimation { currentPage = 1 } }) {
                Text("Get Started")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 200, height: 36)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Screen 2: Add Accounts

    private var addAccountsPage: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "person.2.fill")
                .font(.system(size: 36))
                .foregroundStyle(.blue)
                .padding(.bottom, 4)

            Text("Add your ChatGPT accounts")
                .font(.system(size: 20, weight: .bold))

            Text("Each Plus account gives you separate rate limits. CodexSwitch automatically switches when one account is exhausted.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)

            // Account count indicator
            VStack(spacing: 8) {
                if accountCount > 0 {
                    HStack(spacing: 6) {
                        ForEach(0..<accountCount, id: \.self) { _ in
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.top, 8)

                    Text("\(accountCount) account\(accountCount == 1 ? "" : "s") added")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    Image(systemName: "person.crop.circle.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                    Text("No accounts added yet")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 60)

            Button(action: onAddAccount) {
                Label("Add Account", systemImage: "plus.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 180, height: 32)
            }
            .buttonStyle(.borderedProminent)
            .tint(.blue)

            if accountCount < 2 {
                Text("Add at least 2 accounts for automatic switching")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Spacer()

            HStack(spacing: 12) {
                Button(action: { withAnimation { currentPage = 0 } }) {
                    Text("Back")
                        .font(.system(size: 13))
                        .frame(width: 80, height: 32)
                }
                .buttonStyle(.bordered)

                Button(action: { withAnimation { currentPage = 2 } }) {
                    Text("Continue")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 120, height: 32)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(accountCount < 2)
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: - Screen 3: Setup Complete

    private var setupCompletePage: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
                .padding(.bottom, 4)

            Text("You're all set!")
                .font(.system(size: 22, weight: .bold))

            VStack(alignment: .leading, spacing: 12) {
                featureRow(
                    icon: "gauge.with.dots.needle.67percent",
                    color: .green,
                    text: "Monitor your rate limits in real-time"
                )
                featureRow(
                    icon: "arrow.triangle.2.circlepath",
                    color: .blue,
                    text: "Switch accounts seamlessly when limits are hit"
                )
                featureRow(
                    icon: "link",
                    color: .orange,
                    text: "Keep Codex CLI and Desktop app in sync"
                )
            }
            .padding(.horizontal, 48)
            .padding(.top, 8)

            // Menu bar hint
            VStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("CodexSwitch runs in your menu bar")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 16)

            Spacer()

            HStack(spacing: 12) {
                Button(action: { withAnimation { currentPage = 1 } }) {
                    Text("Back")
                        .font(.system(size: 13))
                        .frame(width: 80, height: 32)
                }
                .buttonStyle(.bordered)

                Button(action: onComplete) {
                    Text("Done")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 200, height: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
            .padding(.bottom, 24)
        }
    }

    private func featureRow(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
        }
    }
}
