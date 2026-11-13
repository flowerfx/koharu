// Port of apps/ipad/Sources/BubbleLayout.swift.
//
// Finds the speech bubble around each OCR box so a translation can use the
// bubble's interior instead of the box. Japanese text is usually a narrow
// vertical column; fitting horizontal text into that column makes it tiny.

use std::collections::HashSet;

use crate::geometry::Rect;

const BRIGHTNESS: u8 = 190;
const COVERAGE: f64 = 0.98;

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct BubbleGroup {
    /// Indices into the input boxes, in input (reading) order.
    pub members: Vec<u32>,
    /// Where the text goes, in pixel coordinates.
    pub rect: Rect,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum LayoutError {
    #[error("gray buffer has {actual} bytes, expected {expected}")]
    BufferSize { expected: u64, actual: u64 },
}

/// `gray` is a row-major 8-bit luminance image. Boxes are in the same pixel
/// space. Boxes reached by one flood fill share a bubble and form one group.
#[uniffi::export]
pub fn bubble_groups(gray: Vec<u8>, width: u32, height: u32, boxes: Vec<Rect>) -> Result<Vec<BubbleGroup>, LayoutError> {
    let (width, height) = (width as usize, height as usize);
    if gray.len() != width * height {
        return Err(LayoutError::BufferSize { expected: (width * height) as u64, actual: gray.len() as u64 });
    }
    let image = Rect::new(0.0, 0.0, width as f64, height as f64);
    let cells: Vec<Option<Rect>> = boxes.iter().map(|b| b.intersection(&image).map(|r| r.integral())).collect();
    let mut groups = Vec::new();
    let mut grouped = HashSet::new();
    for (index, cell) in cells.iter().enumerate() {
        if grouped.contains(&index) {
            continue;
        }
        let bubble = cell
            .filter(|b| b.width >= 1.0 && b.height >= 1.0)
            .and_then(|b| fill(&gray, width, height, &b, &cells));
        let Some(bubble) = bubble else {
            groups.push(BubbleGroup { members: vec![index as u32], rect: boxes[index] });
            grouped.insert(index);
            continue;
        };
        let members: Vec<usize> = (0..cells.len())
            .filter(|i| !grouped.contains(i) && cells[*i].is_some_and(|c| bubble.contains(&c)))
            .collect();
        grouped.extend(members.iter().copied());
        let union = members.iter().fold(boxes[index], |acc, i| acc.union(&boxes[*i]));
        // Keep the original box when the bubble interior is not larger.
        let rect = if bubble.interior.area() > union.area() { bubble.interior } else { union };
        let members = if members.is_empty() { vec![index] } else { members };
        groups.push(BubbleGroup { members: members.into_iter().map(|i| i as u32).collect(), rect });
    }
    groups.sort_by_key(|g| g.members[0]);
    Ok(groups)
}

struct Bubble {
    mask: Vec<bool>,
    /// Search window in image pixels.
    area: Rect,
    interior: Rect,
}

impl Bubble {
    fn contains(&self, cell: &Rect) -> bool {
        if !self.area.contains_point(cell.mid_x(), cell.mid_y()) {
            return false;
        }
        let x = (cell.mid_x() - self.area.x) as usize;
        let y = (cell.mid_y() - self.area.y) as usize;
        self.mask[y * self.area.width as usize + x]
    }
}

/// Flood fills bright pixels (and every OCR box, whose text will be erased)
/// from `cell`. A fill that reaches the search window edge is open art or page
/// background, not a closed bubble. Spiky "flash" bubbles have narrow white
/// gaps between their spikes, so a leak is retried with the bright area
/// eroded, which closes gaps a few pixels wide.
fn fill(gray: &[u8], width: usize, height: usize, cell: &Rect, cells: &[Option<Rect>]) -> Option<Bubble> {
    let margin = (2.0 * cell.width.max(cell.height)).max(0.12 * width.min(height) as f64);
    let area = cell
        .inset(-margin, -margin)
        .intersection(&Rect::new(0.0, 0.0, width as f64, height as f64))?
        .integral();
    let (w, h, ox, oy) = (area.width as usize, area.height as usize, area.x as usize, area.y as usize);
    if w <= 2 || h <= 2 {
        return None;
    }
    let mut bright = vec![false; w * h];
    for y in 0..h {
        for x in 0..w {
            bright[y * w + x] = gray[(y + oy) * width + x + ox] >= BRIGHTNESS;
        }
    }
    let gap = (width.min(height) / 300).max(2);
    for radius in [0, gap, 2 * gap] {
        let mut open = if radius == 0 { bright.clone() } else { erode(&bright, w, h, radius) };
        for other in cells.iter().flatten() {
            let Some(r) = other.intersection(&area) else { continue };
            for y in (r.y as usize - oy)..(r.max_y() as usize - oy) {
                for x in (r.x as usize - ox)..(r.max_x() as usize - ox) {
                    open[y * w + x] = true;
                }
            }
        }
        let seed = cell.intersection(&area)?.offset(-area.x, -area.y);
        if let Some(mask) = flood(&open, w, h, &seed) {
            return Some(bubble(mask, area));
        }
    }
    None
}

fn flood(open: &[bool], w: usize, h: usize, seed: &Rect) -> Option<Vec<bool>> {
    let mut mask = vec![false; w * h];
    let mut stack = Vec::new();
    for y in seed.y as usize..seed.max_y() as usize {
        for x in seed.x as usize..seed.max_x() as usize {
            mask[y * w + x] = true;
            stack.push(y * w + x);
        }
    }
    while let Some(p) = stack.pop() {
        let (x, y) = (p % w, p / w);
        if x == 0 || y == 0 || x == w - 1 || y == h - 1 {
            return None;
        }
        for q in [p - 1, p + 1, p - w, p + w] {
            if open[q] && !mask[q] {
                mask[q] = true;
                stack.push(q);
            }
        }
    }
    Some(mask)
}

/// A pixel stays open only if its whole (2r+1)² neighbourhood is bright.
fn erode(value: &[bool], w: usize, h: usize, r: usize) -> Vec<bool> {
    let pass = |input: &[bool], horizontal: bool| -> Vec<bool> {
        let mut output = vec![false; w * h];
        let (lines, length) = if horizontal { (h, w) } else { (w, h) };
        let (mut left, mut right) = (vec![0i64; length], vec![0i64; length]);
        let len = length as i64;
        for line in 0..lines {
            let index = |i: usize| if horizontal { line * w + i } else { i * w + line };
            // Distance to the nearest dark pixel on each side along the line.
            let mut last = -len;
            for i in 0..length {
                if !input[index(i)] {
                    last = i as i64;
                }
                left[i] = i as i64 - last;
            }
            last = 2 * len;
            for i in (0..length).rev() {
                if !input[index(i)] {
                    last = i as i64;
                }
                right[i] = last - i as i64;
            }
            for i in 0..length {
                output[index(i)] = left[i] > r as i64 && right[i] > r as i64;
            }
        }
        output
    };
    pass(&pass(value, true), false)
}

fn bubble(mask: Vec<bool>, area: Rect) -> Bubble {
    let (w, h) = (area.width as usize, area.height as usize);
    // Dark marks enclosed by the bubble (missed furigana, punctuation, stray
    // strokes) count as interior: only what the window edge reaches is outside.
    let mut outside = vec![false; w * h];
    let mut stack = Vec::with_capacity(2 * (w + h));
    for x in 0..w {
        stack.push(x);
        stack.push((h - 1) * w + x);
    }
    for y in 0..h {
        stack.push(y * w);
        stack.push(y * w + w - 1);
    }
    while let Some(p) = stack.pop() {
        if mask[p] || outside[p] {
            continue;
        }
        outside[p] = true;
        let (x, y) = (p % w, p / w);
        if x > 0 {
            stack.push(p - 1);
        }
        if x < w - 1 {
            stack.push(p + 1);
        }
        if y > 0 {
            stack.push(p - w);
        }
        if y < h - 1 {
            stack.push(p + w);
        }
    }
    let solid: Vec<bool> = outside.iter().map(|o| !o).collect();
    let interior = interior(&solid, w, h).offset(area.x, area.y);
    Bubble { mask, area, interior }
}

/// The largest rectangle with the bubble's bounding-box aspect, centred on the
/// bubble's centroid, that lies (almost) entirely inside the bubble.
fn interior(mask: &[bool], w: usize, h: usize) -> Rect {
    let stride = w + 1;
    let mut sum = vec![0i64; stride * (h + 1)];
    let (mut min_x, mut min_y, mut max_x, mut max_y) = (w, h, 0, 0);
    let (mut cx, mut cy, mut count) = (0usize, 0usize, 0usize);
    for y in 0..h {
        let mut row = 0i64;
        for x in 0..w {
            if mask[y * w + x] {
                row += 1;
                count += 1;
                cx += x;
                cy += y;
                min_x = min_x.min(x);
                min_y = min_y.min(y);
                max_x = max_x.max(x);
                max_y = max_y.max(y);
            }
            sum[(y + 1) * stride + x + 1] = sum[y * stride + x + 1] + row;
        }
    }
    if count == 0 {
        return Rect::ZERO;
    }
    let centre = (cx as f64 / count as f64 + 0.5, cy as f64 / count as f64 + 0.5);
    let full = ((max_x - min_x + 1) as f64, (max_y - min_y + 1) as f64);
    let rect = |scale: f64| {
        Rect::new(
            centre.0 - full.0 * scale / 2.0,
            centre.1 - full.1 * scale / 2.0,
            full.0 * scale,
            full.1 * scale,
        )
        .integral()
    };
    let fits = |r: Rect| {
        if r.x < 0.0 || r.y < 0.0 || r.max_x() > w as f64 || r.max_y() > h as f64 || r.width < 1.0 || r.height < 1.0 {
            return false;
        }
        let (x0, y0, x1, y1) = (r.x as usize, r.y as usize, r.max_x() as usize, r.max_y() as usize);
        let inside = sum[y1 * stride + x1] - sum[y0 * stride + x1] - sum[y1 * stride + x0] + sum[y0 * stride + x0];
        inside as f64 >= COVERAGE * ((x1 - x0) * (y1 - y0)) as f64
    };
    let (mut lo, mut hi) = (0.0, 1.0);
    for _ in 0..12 {
        let mid = (lo + hi) / 2.0;
        if fits(rect(mid)) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    // Leave a little breathing room from the bubble outline.
    let best = rect(lo);
    best.inset(best.width * 0.05, best.height * 0.05)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn closed_bubble_groups_both_boxes_and_grows_rect() {
        // Black page with a white 100x100 bubble holding two small text boxes.
        let (w, h) = (300usize, 300usize);
        let mut gray = vec![0u8; w * h];
        for y in 100..200 {
            for x in 100..200 {
                gray[y * w + x] = 255;
            }
        }
        let boxes = vec![Rect::new(140.0, 120.0, 8.0, 40.0), Rect::new(152.0, 120.0, 8.0, 40.0)];
        let groups = bubble_groups(gray, w as u32, h as u32, boxes).unwrap();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].members, vec![0, 1]);
        assert!(groups[0].rect.width > 60.0 && groups[0].rect.height > 60.0);
    }

    #[test]
    fn open_background_keeps_box() {
        let gray = vec![255u8; 200 * 200];
        let boxes = vec![Rect::new(50.0, 50.0, 10.0, 30.0)];
        let groups = bubble_groups(gray, 200, 200, boxes.clone()).unwrap();
        assert_eq!(groups, vec![BubbleGroup { members: vec![0], rect: boxes[0] }]);
    }
}
