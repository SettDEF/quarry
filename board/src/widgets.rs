//! The handful of controls the board is built from.
//!
//! egui's stock widgets are made to be adequate everywhere. A reference board
//! is chrome floating over pictures, which asks for fewer, quieter controls:
//! icon buttons that are only a glyph until you hover them, menus whose rows
//! carry their shortcut, and one floating surface style shared by every
//! panel, so the window reads as a single designed thing.

use egui::{Align2, Color32, CornerRadius, CursorIcon, FontId, Margin, Response, Sense, Shadow, Stroke, StrokeKind, Ui};

use crate::theme::{alpha, mix, Palette};

/// The floating surface every panel, bar and menu sits on.
///
/// Opaque rather than glassy: the board behind it is usually pictures, and
/// text over a picture showing through is text you cannot read.
pub fn surface(p: &Palette) -> egui::Frame {
    egui::Frame::new()
        .fill(p.surface)
        .stroke(Stroke::new(1.0, alpha(p.outline_variant, 0.55)))
        .corner_radius(CornerRadius::same(14))
        .inner_margin(Margin::same(5))
        .shadow(Shadow { offset: [0, 8], blur: 28, spread: 0, color: Color32::from_black_alpha(80) })
}

/// A glyph that becomes a button when you reach for it.
pub fn icon_button(ui: &mut Ui, p: &Palette, icon: &str, active: bool) -> Response {
    icon_button_sized(ui, p, icon, active, 32.0)
}

pub fn icon_button_sized(ui: &mut Ui, p: &Palette, icon: &str, active: bool, side: f32) -> Response {
    let (rect, resp) = ui.allocate_exact_size(egui::vec2(side, side), Sense::click());
    if ui.is_rect_visible(rect) {
        let hover = ui.ctx().animate_bool_with_time(resp.id.with("hover"), resp.hovered(), 0.1);
        let pressed = resp.is_pointer_button_down_on();
        let fill = if active {
            mix(p.primary_container, p.on_primary_container, 0.06 * hover)
        } else {
            alpha(p.on_surface, 0.07 * hover + if pressed { 0.06 } else { 0.0 })
        };
        let painter = ui.painter();
        painter.rect_filled(rect, CornerRadius::same((side * 0.3) as u8), fill);
        let color = if active {
            p.on_primary_container
        } else {
            mix(p.on_surface_variant, p.on_surface, hover)
        };
        painter.text(rect.center(), Align2::CENTER_CENTER, icon, FontId::proportional(side * 0.53), color);
    }
    resp.on_hover_cursor(CursorIcon::PointingHand)
}

/// A tooltip that names the action AND its key: learning shortcuts happens
/// by seeing them where the mouse already is.
pub fn tip(resp: Response, p: &Palette, label: &str, keys: &[&str]) -> Response {
    let p = *p;
    let label = label.to_string();
    let keys: Vec<String> = keys.iter().map(|k| k.to_string()).collect();
    resp.on_hover_ui(move |ui| {
        ui.horizontal(|ui| {
            ui.label(egui::RichText::new(&label).color(p.on_surface));
            for k in &keys {
                kbd(ui, &p, k);
            }
        });
    })
}

/// A key, drawn as a key.
pub fn kbd(ui: &mut Ui, p: &Palette, text: &str) {
    let galley = ui.painter().layout_no_wrap(
        text.to_string(),
        FontId::proportional(11.0),
        p.on_surface_variant,
    );
    let size = egui::vec2((galley.size().x + 10.0).max(20.0), 19.0);
    let (rect, _) = ui.allocate_exact_size(size, Sense::hover());
    let painter = ui.painter();
    painter.rect(
        rect,
        CornerRadius::same(5),
        alpha(p.on_surface, 0.05),
        Stroke::new(1.0, alpha(p.outline_variant, 0.9)),
        StrokeKind::Inside,
    );
    painter.galley(rect.center() - galley.size() / 2.0, galley, p.on_surface_variant);
}

pub fn vsep(ui: &mut Ui, p: &Palette) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(9.0, 20.0), Sense::hover());
    ui.painter().line_segment(
        [rect.center_top(), rect.center_bottom()],
        Stroke::new(1.0, alpha(p.outline_variant, 0.8)),
    );
}

pub fn hsep(ui: &mut Ui, p: &Palette) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 9.0), Sense::hover());
    ui.painter().line_segment(
        [rect.left_center() + egui::vec2(6.0, 0.0), rect.right_center() - egui::vec2(6.0, 0.0)],
        Stroke::new(1.0, alpha(p.outline_variant, 0.7)),
    );
}

/// Small, quiet heading for a group of menu rows or settings.
pub fn caption(ui: &mut Ui, p: &Palette, text: &str) {
    ui.add_space(2.0);
    ui.horizontal(|ui| {
        ui.add_space(8.0);
        ui.label(egui::RichText::new(text).size(11.0).color(alpha(p.on_surface_variant, 0.75)));
    });
}

pub struct Row<'a> {
    pub icon: &'a str,
    pub label: &'a str,
    pub keys: &'a str,
    pub danger: bool,
    pub checked: Option<bool>,
    pub enabled: bool,
}

impl<'a> Row<'a> {
    pub fn new(icon: &'a str, label: &'a str) -> Self {
        Row { icon, label, keys: "", danger: false, checked: None, enabled: true }
    }
    pub fn keys(mut self, k: &'a str) -> Self {
        self.keys = k;
        self
    }
    pub fn danger(mut self) -> Self {
        self.danger = true;
        self
    }
    pub fn checked(mut self, on: bool) -> Self {
        self.checked = Some(on);
        self
    }
    pub fn enabled(mut self, on: bool) -> Self {
        self.enabled = on;
        self
    }
}

/// One row of a menu: icon, label, and the shortcut set flush right.
pub fn menu_row(ui: &mut Ui, p: &Palette, row: Row) -> Response {
    let width = ui.available_width().max(220.0);
    let sense = if row.enabled { Sense::click() } else { Sense::hover() };
    let (rect, resp) = ui.allocate_exact_size(egui::vec2(width, 30.0), sense);
    if ui.is_rect_visible(rect) {
        let hover = row.enabled && resp.hovered();
        let painter = ui.painter();
        if hover {
            let tint = if row.danger { p.error } else { p.on_surface };
            painter.rect_filled(rect, CornerRadius::same(8), alpha(tint, 0.09));
        }
        let base = if row.danger { p.error } else { p.on_surface };
        let fg = if row.enabled { base } else { alpha(base, 0.38) };
        let dim = if row.enabled { alpha(p.on_surface_variant, 0.85) } else { alpha(p.on_surface_variant, 0.3) };
        painter.text(
            rect.left_center() + egui::vec2(18.0, 0.0),
            Align2::CENTER_CENTER,
            row.icon,
            FontId::proportional(16.0),
            if row.danger { fg } else { dim },
        );
        painter.text(
            rect.left_center() + egui::vec2(36.0, 0.0),
            Align2::LEFT_CENTER,
            row.label,
            FontId::proportional(13.5),
            fg,
        );
        let mut right = rect.right() - 10.0;
        if let Some(on) = row.checked {
            if on {
                painter.text(
                    egui::pos2(right - 6.0, rect.center().y),
                    Align2::CENTER_CENTER,
                    egui_phosphor::regular::CHECK,
                    FontId::proportional(15.0),
                    p.primary,
                );
            }
            right -= 22.0;
        }
        if !row.keys.is_empty() {
            painter.text(
                egui::pos2(right, rect.center().y),
                Align2::RIGHT_CENTER,
                row.keys,
                FontId::proportional(12.0),
                alpha(p.on_surface_variant, 0.6),
            );
        }
    }
    if row.enabled {
        resp.on_hover_cursor(CursorIcon::PointingHand)
    } else {
        resp
    }
}

#[derive(Clone, Copy, PartialEq)]
pub enum Kind {
    Filled,
    Tonal,
    Text,
    Danger,
}

/// A pill button with words on it, for dialogs and empty states.
pub fn pill(ui: &mut Ui, p: &Palette, icon: &str, label: &str, kind: Kind) -> Response {
    let font = FontId::proportional(13.5);
    let text = if icon.is_empty() { label.to_string() } else { format!("{icon}  {label}") };
    let fg = match kind {
        Kind::Filled => p.on_primary,
        Kind::Tonal => p.on_primary_container,
        Kind::Text => p.primary,
        Kind::Danger => p.surface_lowest,
    };
    let galley = ui.painter().layout_no_wrap(text, font, fg);
    let size = egui::vec2(galley.size().x + 32.0, 36.0);
    let (rect, resp) = ui.allocate_exact_size(size, Sense::click());
    if ui.is_rect_visible(rect) {
        let hover = ui.ctx().animate_bool_with_time(resp.id.with("hover"), resp.hovered(), 0.1);
        let bg = match kind {
            Kind::Filled => mix(p.primary, p.on_primary, 0.08 * hover),
            Kind::Tonal => mix(p.primary_container, p.on_primary_container, 0.08 * hover),
            Kind::Text => alpha(p.primary, 0.1 * hover),
            Kind::Danger => mix(p.error, p.surface_lowest, 0.08 * hover),
        };
        let painter = ui.painter();
        painter.rect_filled(rect, CornerRadius::same(18), bg);
        painter.galley(rect.center() - galley.size() / 2.0, galley, fg);
    }
    resp.on_hover_cursor(CursorIcon::PointingHand)
}

/// A labelled slider with its value as a percentage, which is how people
/// talk about opacity.
pub fn percent_slider(ui: &mut Ui, p: &Palette, icon: &str, label: &str, value: &mut f32, min: f32) -> Response {
    ui.horizontal(|ui| {
        ui.add_space(4.0);
        ui.label(egui::RichText::new(icon).size(15.0).color(p.on_surface_variant));
        ui.label(egui::RichText::new(label).color(p.on_surface));
        ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
            ui.add_space(6.0);
            ui.label(
                egui::RichText::new(format!("{:.0}%", *value * 100.0))
                    .color(p.on_surface_variant)
                    .size(12.0),
            );
        });
    });
    ui.horizontal(|ui| {
        ui.add_space(6.0);
        ui.spacing_mut().slider_width = ui.available_width() - 8.0;
        ui.add(egui::Slider::new(value, min..=1.0).show_value(false))
    })
    .inner
}
