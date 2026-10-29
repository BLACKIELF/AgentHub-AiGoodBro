//! Mac EdgeDock geometry translated to top-origin physical desktop coordinates.
use super::model::Side;
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}
impl Rect {
    pub fn right(self) -> f64 {
        self.x + self.width
    }
    pub fn bottom(self) -> f64 {
        self.y + self.height
    }
    pub fn contains(self, x: f64, y: f64) -> bool {
        x >= self.x && x <= self.right() && y >= self.y && y <= self.bottom()
    }
    pub fn distance_squared(self, x: f64, y: f64) -> f64 {
        (x - x.clamp(self.x, self.right())).powi(2) + (y - y.clamp(self.y, self.bottom())).powi(2)
    }
    pub fn expanded(self, x: f64, y: f64) -> Self {
        Self {
            x: self.x - x,
            y: self.y - y,
            width: self.width + 2. * x,
            height: self.height + 2. * y,
        }
    }
}
pub fn fitting_scale(requested: f64, natural_height: f64, available_height: f64) -> f64 {
    if requested <= 1. || natural_height <= 0. || natural_height * requested <= available_height {
        return requested;
    }
    if natural_height > available_height {
        return 1.;
    }
    (available_height / natural_height * 100.).floor().max(100.) / 100.
}
pub fn rail(work: Rect, side: Side, offset: f64, height: f64, scale: f64, dpi: f64) -> Rect {
    let inset = (8. * dpi).min((work.height - 1.).max(0.) / 2.);
    let height = height.min((work.height - 2. * inset).max(1.));
    let travel = (work.height - height - 2. * inset).max(0.);
    let width = (64. * scale * dpi).min(work.width.max(1.));
    Rect {
        x: if side == Side::Right {
            work.right() - width
        } else {
            work.x
        },
        y: work.y + inset + travel * offset.clamp(0., 1.),
        width,
        height,
    }
}
pub fn peek(rail: Rect, work: Rect, side: Side, scale: f64, dpi: f64) -> Rect {
    let width = ((10. * scale).round().max(10.) * dpi).min(work.width.max(1.));
    let height = ((88. * scale).round() * dpi).min(work.height.max(1.));
    Rect {
        x: if side == Side::Right {
            work.right() - width
        } else {
            work.x
        },
        y: (rail.y + rail.height / 2. - height / 2.)
            .clamp(work.y, (work.bottom() - height).max(work.y)),
        width,
        height,
    }
}
pub fn card(
    rail: Rect,
    center_y: f64,
    height: f64,
    work: Rect,
    side: Side,
    scale: f64,
    dpi: f64,
) -> Rect {
    let inset = (8. * dpi).min((work.height - 1.).max(0.) / 2.);
    let horizontal_inset = (8. * dpi).min((work.width - 1.).max(0.) / 2.);
    let height = height.min((work.height - 2. * inset).max(1.));
    let width = (292. * scale * dpi).min((work.width - 2. * horizontal_inset).max(1.));
    let x = if side == Side::Right {
        rail.x - (4. * scale * dpi + width)
    } else {
        rail.right() + 4. * scale * dpi
    };
    Rect {
        x: x.clamp(
            work.x + horizontal_inset,
            (work.right() - width - horizontal_inset).max(work.x + horizontal_inset),
        ),
        y: (center_y - height / 2.).clamp(
            work.y + inset,
            (work.bottom() - height - inset).max(work.y + inset),
        ),
        width,
        height,
    }
}
pub fn popover(work: Rect, anchor: (f64, f64), collapsed: bool, dpi: f64) -> Rect {
    let width = (420. * dpi).min(work.width);
    let height = (if collapsed { 64. } else { 640. } * dpi).min(work.height);
    Rect {
        x: (anchor.0 - width / 2.).clamp(work.x, (work.right() - width).max(work.x)),
        y: (anchor.1 - height - 8. * dpi).clamp(work.y, (work.bottom() - height).max(work.y)),
        width,
        height,
    }
}
pub fn placement_after_drag(rail: Rect, work: Rect, dpi: f64) -> (Side, f64) {
    let side = if rail.x + rail.width / 2. < work.x + work.width / 2. {
        Side::Left
    } else {
        Side::Right
    };
    let travel = (work.height - rail.height - 16. * dpi).max(0.);
    let offset = if travel > 0. {
        ((rail.y - work.y - 8. * dpi) / travel).clamp(0., 1.)
    } else {
        0.3
    };
    (side, offset)
}
pub fn corridor_contains(x: f64, y: f64, rail: Rect, card: Rect, dpi: f64) -> bool {
    let (start, end) = if card.x < rail.x {
        (card.right(), rail.x)
    } else {
        (rail.right(), card.x)
    };
    x >= start.min(end) - 6. * dpi
        && x <= start.max(end) + 6. * dpi
        && y >= card.y
        && y <= card.bottom()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn mac_widths_margins_and_offset_are_dpi_consistent() {
        let work = Rect {
            x: -1920.,
            y: 40.,
            width: 1920.,
            height: 1040.,
        };
        let r = rail(work, Side::Left, 1., 400., 1., 1.);
        assert_eq!(r.x, -1920.);
        assert_eq!(r.bottom(), 1072.);
        let c = card(r, 500., 300., work, Side::Left, 1., 1.);
        assert_eq!(c.x, r.right() + 4.);
        assert_eq!(c.width, 292.);
        let p = peek(r, work, Side::Left, 1., 1.);
        assert_eq!(p.width, 10.);
        assert_eq!(p.height, 88.);
    }
    #[test]
    fn taskbar_work_area_and_tiny_monitors_clamp_popover() {
        let work = Rect {
            x: 100.,
            y: 200.,
            width: 300.,
            height: 400.,
        };
        let p = popover(work, (10000., -10000.), false, 2.);
        assert_eq!(p, work);
        assert_eq!(fitting_scale(1.25, 800., 900.), 1.12);
    }
    #[test]
    fn native_drag_changes_only_side_and_bounded_offset() {
        let work = Rect {
            x: 0.,
            y: 0.,
            width: 1920.,
            height: 1000.,
        };
        let r = Rect {
            x: 10000.,
            y: -10000.,
            width: 64.,
            height: 500.,
        };
        assert_eq!(placement_after_drag(r, work, 1.), (Side::Right, 0.));
    }
    #[test]
    fn mixed_dpi_negative_displays_and_tiny_work_areas_keep_surfaces_inside() {
        for dpi in [1., 1.25, 1.5, 2.] {
            for (width, height) in [(1920., 1040.), (800., 600.), (120., 100.), (4., 4.)] {
                let work = Rect {
                    x: -2000.,
                    y: -100.,
                    width,
                    height,
                };
                for side in [Side::Left, Side::Right] {
                    for offset in [0., 0.3, 1.] {
                        let rail = rail(work, side, offset, 1408. * dpi, 1.25, dpi);
                        let peek = peek(rail, work, side, 1.25, dpi);
                        let card = card(rail, rail.y + 90., 550. * dpi, work, side, 1.25, dpi);
                        for rect in [rail, peek, card, popover(work, (-5000., 5000.), false, dpi)] {
                            assert!(rect.x >= work.x && rect.y >= work.y);
                            assert!(rect.right() <= work.right() + 0.000001);
                            assert!(rect.bottom() <= work.bottom() + 0.000001);
                            assert!(rect.width > 0. && rect.height > 0.);
                        }
                    }
                }
            }
        }
    }
    #[test]
    fn hover_corridor_and_nearest_display_use_actual_physical_coordinates() {
        let rail = Rect {
            x: 1800.,
            y: 200.,
            width: 96.,
            height: 600.,
        };
        let card = Rect {
            x: 1356.,
            y: 300.,
            width: 438.,
            height: 660.,
        };
        assert!(corridor_contains(1797., 400., rail, card, 1.5));
        assert!(!corridor_contains(1700., 400., rail, card, 1.5));
        assert!(!corridor_contains(1797., 100., rail, card, 1.5));
        assert_eq!(rail.distance_squared(1800., 200.), 0.);
        assert_eq!(rail.distance_squared(1790., 200.), 100.);
    }
}
