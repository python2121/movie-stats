import MarkdownUI
import SwiftUI

/// Compact MarkdownUI theme tuned for the chat side panel: smaller fonts,
/// tighter spacing, and a readable table style so AI answers (which usually
/// contain markdown tables) render cleanly inside a 280–900pt wide column.
extension Theme {
    @MainActor static let chatTheme: Theme = Theme()
        .text {
            FontSize(13)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(Color.gray.opacity(0.18))
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .relativeLineSpacing(.em(0.18))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.9))
                    }
                    .padding(8)
            }
            .background(Color.gray.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.2))
                }
                .padding(.vertical, 2)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.1))
                }
                .padding(.vertical, 2)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.0))
                }
                .padding(.vertical, 1)
        }
        .table { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(.em(0.92))
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .frame(minHeight: 24, alignment: .leading)
        }
}
