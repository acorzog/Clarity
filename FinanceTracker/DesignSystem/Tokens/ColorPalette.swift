import Foundation

/// The one Clarity color-picker palette — see `CLARITY_DESIGN_SYSTEM.md` §17 ("Color Picker
/// Consolidation") and §29.
///
/// Before this token, `WalletEditorView` and `NewSharedEventView` each hardcoded their own hex
/// array for their respective account/event color pickers. They had already drifted: both used
/// the same 10 base hues, but `WalletEditorView` additionally included lime (`#84CC16`) and gray
/// (`#6B7280`), and the two lists were ordered differently. This is the superset of both,
/// canonicalized to `WalletEditorView`'s (more complete) ordering.
///
/// Shared explicitly uses this same array — per the design system's explicit rule, Shared's
/// visual distinctness comes from content/iconography, never a parallel color system.
enum ClarityColorPalette {
    static let hexValues: [String] = [
        "#F59E0B", "#F97316", "#EF4444", "#EC4899", "#8B5CF6",
        "#6366F1", "#3B82F6", "#0EA5E9", "#14B8A6", "#10B981",
        "#84CC16", "#6B7280"
    ]
}
