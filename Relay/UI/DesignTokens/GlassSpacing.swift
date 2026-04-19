import CoreGraphics

/// Spacing tokens for Glass. Powers-of-4 scale; keeps rhythm predictable.
/// Use these anywhere a hardcoded padding / spacing / frame constant would
/// appear. Varied spacing (not identical everywhere) is a design goal —
/// tight groupings + generous separations make composition feel intentional.
///
/// **Usage rules** — see `Relay/DESIGN.md`. Short grammar:
/// `xs (4)` icon↔label, label↔subtitle within a single row.
/// `s (8)` two related items in a cluster.
/// `m (12)` default inter-element gap; default row vertical.
/// `l (16)` section interior, card interior.
/// `xl (24)` between groups on an empty / hero screen.
/// `xxl (32)` hero-level breathing room only.
///
/// Any `.padding(12)` / `.padding(16)` etc. in feature code is a drift bug —
/// swap for `GlassSpacing.m` / `.l`. Numbers off-scale (e.g. pill's 3pt
/// vertical) need a comment explaining the optical reason.
public enum GlassSpacing {
 /// 4pt — hairline spacing inside dense clusters (e.g., icon + label).
 public static let xs: CGFloat = 4
 /// 8pt — small gap between related items.
 public static let s: CGFloat = 8
 /// 12pt — default inter-element gap.
 public static let m: CGFloat = 12
 /// 16pt — section padding, card interior padding.
 public static let l: CGFloat = 16
 /// 24pt — major separation between groups.
 public static let xl: CGFloat = 24
 /// 32pt — hero / empty-state breathing room.
 public static let xxl: CGFloat = 32
}
