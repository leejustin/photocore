import SwiftUI

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let sections: [(String, [(String, String)])] = [
        ("Flow", [
            ("⌘O", "Open a folder"),
            ("⌘1", "Check"),
            ("⌘2", "Style"),
            ("⌘3", "Save"),
            ("⌘4", "Album"),
            ("⌘D", "Adjust one photo"),
            ("?", "This overlay"),
            ("⌃⌘S", "Sidebar")
        ]),
        ("Album", [
            ("Space", "Loupe"),
            ("G / Esc", "Grid"),
            ("← →", "Previous / next"),
            ("↑ ↓", "Similar frames"),
            ("P / X / U", "Favorite / hide / clear"),
            ("1–5", "Stars"),
            ("6–9", "Color"),
            ("S", "Survey similar"),
            ("E", "Eyes"),
            ("\\", "Original")
        ]),
        ("Check", [
            ("Return", "Keep suggestion"),
            ("← →", "Choose a frame"),
            ("P", "Keep focused"),
            ("X", "Drop / skip"),
            ("E", "Eyes")
        ])
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keys")
                    .font(StudioType.display)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(StudioQuietButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 18)

            Rectangle().fill(StudioChrome.hairline).frame(height: 1)

            ScrollView {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(sections, id: \.0) { title, items in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(title.uppercased())
                                .font(StudioType.caption)
                                .tracking(1.1)
                                .foregroundStyle(StudioChrome.tertiary)
                            ForEach(items, id: \.1) { key, action in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(key)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(StudioChrome.text)
                                        .frame(width: 72, alignment: .leading)
                                    Text(action)
                                        .font(StudioType.ui)
                                        .foregroundStyle(StudioChrome.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(28)
            }
        }
        .frame(width: 640, height: 420)
        .background(StudioChrome.panel)
        .preferredColorScheme(.dark)
    }
}
