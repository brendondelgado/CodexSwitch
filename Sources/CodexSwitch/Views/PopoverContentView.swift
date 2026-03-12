import SwiftUI

struct PopoverContentView: View {
    @Bindable var manager: AccountManager
    var onImportAccount: () -> Void
    var onForceSwap: (UUID) -> Void
    var onOpenSettings: () -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("CodexSwitch")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if let active = manager.activeAccount {
                    Text(active.email)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button(action: onOpenSettings) {
                    Image(systemName: "gear")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(manager.sortedAccounts) { account in
                    AccountCardView(account: account) {
                        onForceSwap(account.id)
                    }
                }
            }
            .padding(10)

            Divider()

            HStack {
                if let lastSwap = manager.swapHistory.last {
                    let ago = RelativeDateTimeFormatter()
                    Text("Last swap: \(ago.localizedString(for: lastSwap.timestamp, relativeTo: Date()))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No swaps yet")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button(action: onImportAccount) {
                    Label("Import Account", systemImage: "plus.circle")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 500)
    }
}
