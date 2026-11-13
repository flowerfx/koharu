// Port of `PagePipeline.recognize` region ordering/merging in apps/ipad.

use crate::geometry::Rect;

/// One recognized OCR line in page-normalized coordinates (0...1, top-left origin).
#[derive(Debug, Clone, uniffi::Record)]
pub struct OcrLine {
    pub rect: Rect,
    pub text: String,
    pub vertical: bool,
}

/// A text region that is translated as one segment.
#[derive(Debug, Clone, uniffi::Record)]
pub struct TextSegment {
    pub id: u32,
    pub source: String,
    pub rect: Rect,
}

fn reads_before(a: &OcrLine, b: &OcrLine) -> bool {
    // Manga reads top to bottom, then right to left within a row.
    if (a.rect.y - b.rect.y).abs() > 0.04 {
        a.rect.y < b.rect.y
    } else {
        a.rect.max_x() > b.rect.max_x()
    }
}

/// Orders lines in reading order and joins nearby lines/columns that share an
/// orientation, so each speech bubble becomes one translation segment.
#[uniffi::export]
pub fn merge_lines(lines: Vec<OcrLine>) -> Vec<TextSegment> {
    let mut regions: Vec<OcrLine> = Vec::with_capacity(lines.len());
    // The row-tolerance comparator is not a total order, which `sort_by` may
    // reject; a stable insertion keeps the iPad ordering without that contract.
    for line in lines.into_iter().filter(|l| !l.text.trim().is_empty()) {
        let at = regions.iter().position(|r| reads_before(&line, r)).unwrap_or(regions.len());
        regions.insert(at, line);
    }

    let mut merged: Vec<OcrLine> = Vec::new();
    while !regions.is_empty() {
        let mut region = regions.remove(0);
        let mut changed = true;
        while changed {
            changed = false;
            for index in 0..regions.len() {
                let next = &regions[index];
                let vertical = region.vertical;
                if vertical != next.vertical {
                    continue;
                }
                let (a, b) = (&region.rect, &next.rect);
                let along = if vertical {
                    a.max_y().min(b.max_y()) - a.y.max(b.y)
                } else {
                    a.max_x().min(b.max_x()) - a.x.max(b.x)
                };
                let length = if vertical { a.height.min(b.height) } else { a.width.min(b.width) };
                let gap = if vertical {
                    a.x.max(b.x) - a.max_x().min(b.max_x())
                } else {
                    a.y.max(b.y) - a.max_y().min(b.max_y())
                };
                let thickness = if vertical { a.width.min(b.width) } else { a.height.min(b.height) };
                if !a.intersects(b) && along > length * 0.6 && gap >= 0.0 && gap < thickness * 0.8 {
                    let next = regions.remove(index);
                    region.text = if vertical && next.rect.max_x() > region.rect.max_x() {
                        next.text + &region.text
                    } else {
                        region.text + if vertical { "" } else { " " } + &next.text
                    };
                    region.rect = region.rect.union(&next.rect);
                    changed = true;
                    break;
                }
            }
        }
        merged.push(region);
    }

    merged
        .into_iter()
        .enumerate()
        .map(|(id, line)| TextSegment { id: id as u32, source: line.text, rect: line.rect })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(x: f64, y: f64, w: f64, h: f64, text: &str, vertical: bool) -> OcrLine {
        OcrLine { rect: Rect::new(x, y, w, h), text: text.into(), vertical }
    }

    #[test]
    fn joins_adjacent_vertical_columns_right_to_left() {
        let segments = merge_lines(vec![
            line(0.50, 0.10, 0.02, 0.20, "左", true),
            line(0.53, 0.10, 0.02, 0.20, "右", true),
            line(0.10, 0.80, 0.30, 0.02, "far", false),
        ]);
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].source, "右左");
        assert_eq!(segments[1].source, "far");
    }
}
