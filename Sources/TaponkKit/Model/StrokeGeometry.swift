import CoreGraphics

/// Pure polyline arc-length math backing the auto-fade erase animation:
/// `AutofadeController` uses the total length to pick an erase duration that
/// reads as a constant retrace speed regardless of stroke size, and
/// `CanvasView` renders a partially-erased stroke via `trailing` — the eraser
/// retraces the stroke from its first point toward its last, so what stays
/// visible is the trailing fraction of the path.
public enum StrokeGeometry {
    public static func length(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { total, segment in
            total + hypot(segment.1.x - segment.0.x, segment.1.y - segment.0.y)
        }
    }

    /// The leading portion of `points` whose arc length is `fraction` of the
    /// total — measured along the path, not by point count, so the retracting
    /// end moves at a steady speed even where input samples are unevenly
    /// spaced. The final point is interpolated along the segment where the cut
    /// lands, rather than snapped to the nearest sample, so the tip slides
    /// smoothly instead of popping from point to point.
    public static func truncated(_ points: [CGPoint], keepingFraction fraction: CGFloat) -> [CGPoint] {
        guard fraction < 1 else { return points }
        guard fraction > 0, points.count > 1 else { return [] }
        let target = length(of: points) * fraction
        guard target > 0 else { return [] }

        var result = [points[0]]
        var traveled: CGFloat = 0
        for (from, to) in zip(points, points.dropFirst()) {
            let segment = hypot(to.x - from.x, to.y - from.y)
            if traveled + segment >= target {
                guard segment > 0 else { break }
                let t = (target - traveled) / segment
                result.append(CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
                break
            }
            traveled += segment
            result.append(to)
        }
        return result
    }

    /// The trailing counterpart of `truncated`: keeps the *last* `fraction` of
    /// the path's arc length. This is what the erase animation renders — the
    /// eraser consumes the stroke from its first point onward, retracing the
    /// original drawing motion, so the still-visible part is always a suffix
    /// of the path with an interpolated leading tip.
    public static func trailing(_ points: [CGPoint], keepingFraction fraction: CGFloat) -> [CGPoint] {
        truncated(points.reversed(), keepingFraction: fraction).reversed()
    }
}
