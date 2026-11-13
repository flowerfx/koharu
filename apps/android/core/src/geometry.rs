/// Axis-aligned rectangle with a top-left origin. OCR lines use page-normalized
/// coordinates; bubble layout uses bitmap pixels.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const ZERO: Rect = Rect { x: 0.0, y: 0.0, width: 0.0, height: 0.0 };

    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.width / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.height / 2.0
    }
    pub fn area(&self) -> f64 {
        self.width * self.height
    }

    /// Overlapping region, or `None` when the rectangles only touch or are apart
    /// (CoreGraphics returns a null or empty rectangle in both cases).
    pub fn intersection(&self, other: &Rect) -> Option<Rect> {
        let x0 = self.x.max(other.x);
        let y0 = self.y.max(other.y);
        let x1 = self.max_x().min(other.max_x());
        let y1 = self.max_y().min(other.max_y());
        (x1 > x0 && y1 > y0).then(|| Rect::new(x0, y0, x1 - x0, y1 - y0))
    }
    pub fn intersects(&self, other: &Rect) -> bool {
        self.intersection(other).is_some()
    }
    pub fn union(&self, other: &Rect) -> Rect {
        let x0 = self.x.min(other.x);
        let y0 = self.y.min(other.y);
        Rect::new(x0, y0, self.max_x().max(other.max_x()) - x0, self.max_y().max(other.max_y()) - y0)
    }
    pub fn inset(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.width - 2.0 * dx, self.height - 2.0 * dy)
    }
    pub fn offset(&self, dx: f64, dy: f64) -> Rect {
        Rect::new(self.x + dx, self.y + dy, self.width, self.height)
    }
    /// Smallest integer rectangle containing this one.
    pub fn integral(&self) -> Rect {
        let x0 = self.x.floor();
        let y0 = self.y.floor();
        Rect::new(x0, y0, self.max_x().ceil() - x0, self.max_y().ceil() - y0)
    }
    /// Half-open containment, matching `CGRect.contains(_: CGPoint)`.
    pub fn contains_point(&self, x: f64, y: f64) -> bool {
        x >= self.x && x < self.max_x() && y >= self.y && y < self.max_y()
    }
}
