//! The look: the desktop's own colours, quarry's own type.
//!
//! quarry does not pick colours. tinct generates a Material 3 scheme from the
//! wallpaper and writes it where quickshell reads it; the QML app consumes that
//! file, and so does this window. Two windows of one application that disagree
//! about what "primary" is look like two applications.
//!
//! The file is re-read when it changes, so the board recolours with the
//! wallpaper exactly when quarry does.

use std::path::PathBuf;
use std::time::SystemTime;

use egui::{Color32, CornerRadius, FontData, FontDefinitions, FontFamily, FontId, Margin, Shadow, Stroke, TextStyle};

#[derive(Clone, Copy, Debug)]
pub struct Palette {
    pub dark: bool,
    pub background: Color32,
    pub surface_lowest: Color32,
    pub surface_low: Color32,
    pub surface: Color32,
    pub surface_high: Color32,
    pub surface_highest: Color32,
    pub on_surface: Color32,
    pub on_surface_variant: Color32,
    pub outline: Color32,
    pub outline_variant: Color32,
    pub primary: Color32,
    pub on_primary: Color32,
    pub primary_container: Color32,
    pub on_primary_container: Color32,
    pub error: Color32,
}

fn hex(s: &str) -> Option<Color32> {
    let s = s.trim().trim_start_matches('#');
    if s.len() != 6 {
        return None;
    }
    let v = u32::from_str_radix(s, 16).ok()?;
    Some(Color32::from_rgb((v >> 16) as u8, (v >> 8) as u8, v as u8))
}

impl Palette {
    /// quarry's cold-start map, for a machine that has never run tinct. The
    /// same values as `Scheme.qml`'s fallback, so a fresh install still looks
    /// like one application.
    pub fn fallback() -> Self {
        Palette {
            dark: true,
            background: Color32::from_rgb(0x14, 0x13, 0x13),
            surface_lowest: Color32::from_rgb(0x0f, 0x0e, 0x0e),
            surface_low: Color32::from_rgb(0x1c, 0x1b, 0x1c),
            surface: Color32::from_rgb(0x20, 0x1f, 0x20),
            surface_high: Color32::from_rgb(0x2b, 0x2a, 0x2a),
            surface_highest: Color32::from_rgb(0x36, 0x34, 0x35),
            on_surface: Color32::from_rgb(0xe6, 0xe1, 0xe1),
            on_surface_variant: Color32::from_rgb(0xcb, 0xc5, 0xca),
            outline: Color32::from_rgb(0x94, 0x8f, 0x94),
            outline_variant: Color32::from_rgb(0x49, 0x46, 0x4a),
            primary: Color32::from_rgb(0xcb, 0xc4, 0xcb),
            on_primary: Color32::from_rgb(0x32, 0x2f, 0x34),
            primary_container: Color32::from_rgb(0x2d, 0x2a, 0x2f),
            on_primary_container: Color32::from_rgb(0xe8, 0xe0, 0xe8),
            error: Color32::from_rgb(0xff, 0xb4, 0xab),
        }
    }

    /// `$name: #RRGGBB;` lines, as tinct writes them. Anything missing keeps
    /// the fallback, so a partial file degrades a colour rather than the app.
    pub fn from_scss(text: &str) -> Self {
        let mut p = Palette::fallback();
        for line in text.lines() {
            let Some(rest) = line.trim().strip_prefix('$') else { continue };
            let Some((key, value)) = rest.split_once(':') else { continue };
            let value = value.trim().trim_end_matches(';').trim();
            if key == "darkmode" {
                p.dark = value.eq_ignore_ascii_case("true");
                continue;
            }
            let Some(c) = hex(value) else { continue };
            match key {
                "background" => p.background = c,
                "surfaceContainerLowest" => p.surface_lowest = c,
                "surfaceContainerLow" => p.surface_low = c,
                "surfaceContainer" => p.surface = c,
                "surfaceContainerHigh" => p.surface_high = c,
                "surfaceContainerHighest" => p.surface_highest = c,
                "onSurface" => p.on_surface = c,
                "onSurfaceVariant" => p.on_surface_variant = c,
                "outline" => p.outline = c,
                "outlineVariant" => p.outline_variant = c,
                "primary" => p.primary = c,
                "onPrimary" => p.on_primary = c,
                "primaryContainer" => p.primary_container = c,
                "onPrimaryContainer" => p.on_primary_container = c,
                "error" => p.error = c,
                _ => {}
            }
        }
        p
    }
}

/// `a` with its alpha replaced. Chrome over a see-through board needs its own
/// opacity, independent of the colour it was given.
pub fn alpha(c: Color32, a: f32) -> Color32 {
    let [r, g, b, _] = c.to_array();
    Color32::from_rgba_unmultiplied(r, g, b, (a.clamp(0.0, 1.0) * 255.0) as u8)
}

/// Linear mix, `t` of the way from `a` to `b`.
pub fn mix(a: Color32, b: Color32, t: f32) -> Color32 {
    let t = t.clamp(0.0, 1.0);
    let l = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    let (a, b) = (a.to_array(), b.to_array());
    Color32::from_rgba_unmultiplied(l(a[0], b[0]), l(a[1], b[1]), l(a[2], b[2]), l(a[3], b[3]))
}

pub struct Theme {
    pub p: Palette,
    path: PathBuf,
    stamp: Option<SystemTime>,
    checked: f64,
}

impl Theme {
    pub fn load() -> Self {
        let home = std::env::var("HOME").unwrap_or_default();
        let path = PathBuf::from(format!(
            "{home}/.local/state/quickshell/user/generated/material_colors.scss"
        ));
        let mut t = Theme { p: Palette::fallback(), path, stamp: None, checked: -10.0 };
        t.reread();
        t
    }

    fn reread(&mut self) -> bool {
        let stamp = std::fs::metadata(&self.path).and_then(|m| m.modified()).ok();
        if stamp == self.stamp {
            return false;
        }
        self.stamp = stamp;
        self.p = match std::fs::read_to_string(&self.path) {
            Ok(text) => Palette::from_scss(&text),
            Err(_) => Palette::fallback(),
        };
        true
    }

    /// A stat every two seconds; the file itself only when it changed.
    pub fn poll(&mut self, ctx: &egui::Context) {
        let now = ctx.input(|i| i.time);
        if now - self.checked < 2.0 {
            return;
        }
        self.checked = now;
        if self.reread() {
            self.apply(ctx);
        }
    }

    pub fn apply(&self, ctx: &egui::Context) {
        let p = &self.p;
        let mut style = (*ctx.style()).clone();
        let mut v = if p.dark { egui::Visuals::dark() } else { egui::Visuals::light() };

        v.panel_fill = p.surface_low;
        v.window_fill = p.surface;
        v.extreme_bg_color = p.surface_lowest;
        v.faint_bg_color = p.surface_low;
        v.code_bg_color = p.surface_high;
        v.window_stroke = Stroke::new(1.0, alpha(p.outline_variant, 0.7));
        v.window_corner_radius = CornerRadius::same(16);
        v.menu_corner_radius = CornerRadius::same(12);
        v.window_shadow = Shadow { offset: [0, 10], blur: 32, spread: 0, color: Color32::from_black_alpha(110) };
        v.popup_shadow = Shadow { offset: [0, 6], blur: 20, spread: 0, color: Color32::from_black_alpha(90) };
        v.selection.bg_fill = alpha(p.primary, 0.35);
        v.selection.stroke = Stroke::new(1.0, p.primary);
        v.hyperlink_color = p.primary;
        v.warn_fg_color = p.error;
        v.error_fg_color = p.error;
        v.text_cursor.stroke = Stroke::new(2.0, p.primary);
        v.slider_trailing_fill = true;
        v.handle_shape = egui::style::HandleShape::Circle;
        v.striped = false;

        let radius = CornerRadius::same(9);
        let w = &mut v.widgets;
        w.noninteractive.bg_fill = p.surface;
        w.noninteractive.weak_bg_fill = p.surface;
        w.noninteractive.bg_stroke = Stroke::new(1.0, alpha(p.outline_variant, 0.6));
        w.noninteractive.fg_stroke = Stroke::new(1.0, p.on_surface_variant);
        w.noninteractive.corner_radius = radius;

        w.inactive.bg_fill = p.surface_highest;
        w.inactive.weak_bg_fill = p.surface_high;
        w.inactive.bg_stroke = Stroke::NONE;
        w.inactive.fg_stroke = Stroke::new(1.0, p.on_surface);
        w.inactive.corner_radius = radius;
        w.inactive.expansion = 0.0;

        w.hovered.bg_fill = mix(p.surface_highest, p.on_surface, 0.12);
        w.hovered.weak_bg_fill = p.surface_highest;
        w.hovered.bg_stroke = Stroke::NONE;
        w.hovered.fg_stroke = Stroke::new(1.5, p.on_surface);
        w.hovered.corner_radius = radius;
        w.hovered.expansion = 0.0;

        w.active.bg_fill = p.primary;
        w.active.weak_bg_fill = p.primary_container;
        w.active.bg_stroke = Stroke::NONE;
        w.active.fg_stroke = Stroke::new(1.5, p.on_primary_container);
        w.active.corner_radius = radius;
        w.active.expansion = 0.0;

        w.open.bg_fill = p.surface_highest;
        w.open.weak_bg_fill = p.surface_highest;
        w.open.bg_stroke = Stroke::NONE;
        w.open.fg_stroke = Stroke::new(1.0, p.on_surface);
        w.open.corner_radius = radius;

        style.visuals = v;
        style.spacing.item_spacing = egui::vec2(6.0, 6.0);
        style.spacing.button_padding = egui::vec2(10.0, 6.0);
        style.spacing.interact_size.y = 30.0;
        style.spacing.menu_margin = Margin::same(6);
        style.spacing.window_margin = Margin::same(16);
        style.spacing.slider_width = 180.0;
        style.spacing.slider_rail_height = 6.0;
        style.spacing.icon_width = 16.0;
        style.animation_time = 0.14;
        style.text_styles = [
            (TextStyle::Small, FontId::new(11.5, FontFamily::Proportional)),
            (TextStyle::Body, FontId::new(13.5, FontFamily::Proportional)),
            (TextStyle::Button, FontId::new(13.5, FontFamily::Proportional)),
            (TextStyle::Heading, FontId::new(17.0, FontFamily::Proportional)),
            (TextStyle::Monospace, FontId::new(12.0, FontFamily::Monospace)),
        ]
        .into();
        ctx.set_style(style);
    }
}

/*
 * quarry's typeface, found the way the desktop finds it.
 *
 * `fc-match` answers with whatever fontconfig would actually render for the
 * name, so an install without Google Sans Flex quietly gets Rubik and then
 * egui's own font — never a missing-glyph box. Icons are Phosphor, compiled
 * in, appended as a fallback so they render inside ordinary text.
 */
pub fn install_fonts(ctx: &egui::Context) {
    let mut fonts = FontDefinitions::default();

    for family in ["Google Sans Flex", "Rubik"] {
        let Ok(out) = std::process::Command::new("fc-match")
            .args(["-f", "%{family}\n%{file}", family])
            .output()
        else {
            break;
        };
        let text = String::from_utf8_lossy(&out.stdout).to_string();
        let mut lines = text.lines();
        let (Some(found), Some(file)) = (lines.next(), lines.next()) else { continue };
        if !found.contains(family) {
            continue;
        }
        let Ok(bytes) = std::fs::read(file) else { continue };
        fonts.font_data.insert("ui".into(), FontData::from_owned(bytes).into());
        fonts
            .families
            .entry(FontFamily::Proportional)
            .or_default()
            .insert(0, "ui".into());
        break;
    }

    egui_phosphor::add_to_fonts(&mut fonts, egui_phosphor::Variant::Regular);
    ctx.set_fonts(fonts);
}
