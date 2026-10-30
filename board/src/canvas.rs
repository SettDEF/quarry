//! The board itself: what is drawn, what is under the pointer, what a gesture
//! does.
//!
//! One interaction surface for the whole canvas, with hit-testing done here
//! rather than by giving every picture its own egui widget. A picture can be
//! rotated, and egui's hit rects are axis-aligned: a turned picture would take
//! clicks in the empty corners of its bounding box and miss none of its own.
//! Deciding ONCE, on press, what the gesture is about — a handle, a picture, a
//! group's header, empty board — is also what stops a drag from turning into
//! a different gesture halfway through.

use egui::emath::Rot2;
use egui::{Align2, Color32, CornerRadius, CursorIcon, FontId, Key, Mesh, Pos2, Rect, Sense, Shape, Stroke, StrokeKind, Vec2};

use crate::model::Piece;
use crate::textures::step_for;
use crate::theme::{alpha, mix};
use crate::{App, Menu, ToastKind, ZOOM_MAX, ZOOM_MIN};

/// A gesture in progress, decided when it started.
#[derive(Clone, PartialEq)]
pub enum Grab {
    None,
    Pan,
    /// Where each selected picture started, the selection's starting bounds,
    /// how far the hand has moved, and the alignment lines currently holding
    /// it. The raw travel is kept separately from the snapped result, so a
    /// snap never sticks: pull further and the picture lets go.
    Move { from: Vec<(String, f32, f32)>, lo: Vec2, hi: Vec2, total: Vec2, guides: Vec<Guide> },
    Marquee { from: Vec2, to: Vec2, additive: bool },
    /// Right-drag on a picture: RIA's scale, which needs no handle to aim at.
    Stretch { from: Vec<(String, f32, f32, f32, f32)>, start: Pos2, ratio_locked: bool },
    /// A corner handle: scale the selection about the opposite corner.
    Corner { from: Vec<(String, f32, f32, f32, f32)>, anchor: Vec2, start: Vec2 },
    /// The knob above the selection, or R held: turn about the centre.
    Turn { from: Vec<(String, f32, f32, f32)>, centre: Vec2, start: f32, by_key: bool },
    MoveGroup { id: i64, members: Vec<String> },
    ResizeGroup { id: i64 },
}

/// An alignment line, in board units.
#[derive(Clone, Copy, PartialEq)]
pub struct Guide {
    pub vertical: bool,
    pub at: f32,
}

impl Grab {
    pub fn is_active(&self) -> bool {
        *self != Grab::None
    }
}

const HANDLE: f32 = 9.0;
const KNOB_GAP: f32 = 26.0;
const HEADER: f32 = 26.0;
const GRIP: f32 = 18.0;

/// A piece's four corners in board space, rotation applied.
pub fn corners(p: &Piece) -> [Vec2; 4] {
    let c = Vec2::new(p.x + p.w / 2.0, p.y + p.h / 2.0);
    let rot = Rot2::from_angle(p.angle.to_radians());
    let (hw, hh) = (p.w / 2.0, p.h / 2.0);
    [
        c + rot * Vec2::new(-hw, -hh),
        c + rot * Vec2::new(hw, -hh),
        c + rot * Vec2::new(hw, hh),
        c + rot * Vec2::new(-hw, hh),
    ]
}

fn contains(p: &Piece, at: Vec2) -> bool {
    let c = Vec2::new(p.x + p.w / 2.0, p.y + p.h / 2.0);
    let local = Rot2::from_angle(-p.angle.to_radians()) * (at - c);
    local.x.abs() <= p.w / 2.0 && local.y.abs() <= p.h / 2.0
}

#[derive(Clone, Copy, PartialEq)]
enum Handle {
    Corner(usize),
    Knob,
}

impl App {
    pub fn canvas_ui(&mut self, ui: &mut egui::Ui) {
        let rect = ui.max_rect();
        self.canvas = rect;
        let response = ui.interact(rect, ui.id().with("board"), Sense::click_and_drag());
        let painter = ui.painter_at(rect);
        let p = self.canvas_palette();

        // The ground. Its opacity is the board's transparency.
        painter.rect_filled(rect, CornerRadius::ZERO, alpha(self.ground_colours().0, self.prefs.ground));
        if self.prefs.grid && !self.clean_frame {
            self.draw_grid(&painter, rect);
        }
        self.view_input(ui, &response);
        self.draw_containers(&painter);
        self.draw_pieces(ui, &painter);
        self.draw_selection(&painter);
        self.pointer(ui, &response);
        if !ui.ctx().wants_keyboard_input() && self.dialog == crate::Dialog::None {
            self.keys(ui);
        }
        if self.clean_frame {
            return;
        }
        if let Grab::Move { guides, .. } = &self.grab {
            for g in guides {
                let line = Stroke::new(1.0, alpha(p.primary, 0.85));
                if g.vertical {
                    let x = self.to_screen(g.at, 0.0).x;
                    painter.line_segment([Pos2::new(x, rect.min.y), Pos2::new(x, rect.max.y)], line);
                } else {
                    let y = self.to_screen(0.0, g.at).y;
                    painter.line_segment([Pos2::new(rect.min.x, y), Pos2::new(rect.max.x, y)], line);
                }
            }
        }
        if let Grab::Marquee { from, to, .. } = &self.grab {
            let r = Rect::from_two_pos(self.to_screen(from.x, from.y), self.to_screen(to.x, to.y));
            painter.rect(r, CornerRadius::same(2), alpha(p.primary, 0.1), Stroke::new(1.0, alpha(p.primary, 0.9)), StrokeKind::Inside);
        }
    }

    /*
     * DOTS, SO THE CANVAS HAS A SCALE.
     *
     * An infinite plane with nothing on it gives no sense of how far you have
     * panned or zoomed. Dots rather than lines: they give the same scale and
     * stay out from behind the pictures. Two densities, each fading in as it
     * becomes legible and out before it becomes noise.
     */
    fn draw_grid(&self, painter: &egui::Painter, rect: Rect) {
        let base = self.ground_colours().1;
        for (unit, weight, size) in [(40.0f32, 0.07f32, 1.5f32), (200.0, 0.14, 2.0)] {
            let step = unit * self.zoom;
            let fade = ((step - 12.0) / 24.0).clamp(0.0, 1.0);
            if fade <= 0.0 {
                continue;
            }
            if unit < 200.0 && 200.0 * self.zoom < 12.0 {
                continue;
            }
            let color = alpha(base, weight * fade);
            let ox = rect.min.x + (-(self.view.x * self.zoom)).rem_euclid(step);
            let oy = rect.min.y + (-(self.view.y * self.zoom)).rem_euclid(step);
            let mut y = oy;
            while y < rect.max.y {
                let mut x = ox;
                while x < rect.max.x {
                    painter.rect_filled(Rect::from_center_size(Pos2::new(x, y), Vec2::splat(size)), CornerRadius::ZERO, color);
                    x += step;
                }
                y += step;
            }
        }
        // The origin, so "home" is a place and not a guess.
        let o = self.to_screen(0.0, 0.0);
        if rect.contains(o) {
            let s = Stroke::new(1.0, alpha(base, 0.3));
            painter.line_segment([o - Vec2::new(10.0, 0.0), o + Vec2::new(10.0, 0.0)], s);
            painter.line_segment([o - Vec2::new(0.0, 10.0), o + Vec2::new(0.0, 10.0)], s);
        }
    }

    /*
     * A MOUSE WHEEL ZOOMS. A TOUCHPAD PANS. A PINCH ZOOMS.
     *
     * They arrive as the same kind of event; egui carries the discriminator on
     * it — a wheel reports `Line` (it detents), a touchpad `Point`. Ctrl makes
     * anything a zoom, as every map and canvas has taught.
     */
    fn view_input(&mut self, ui: &egui::Ui, response: &egui::Response) {
        if !response.contains_pointer() {
            return;
        }
        // egui ALSO folds ctrl+scroll into `zoom_delta`, so a ctrl+wheel notch
        // is taken here, eased, and the same frame's zoom_delta is ignored —
        // otherwise it would count twice.
        let mut notches = 0.0f32;
        let mut glide = Vec2::ZERO;
        let mut ctrl_wheel = false;
        ui.input(|i| {
            for event in &i.raw.events {
                if let egui::Event::MouseWheel { unit, delta, modifiers } = event {
                    let ctrl = modifiers.ctrl || modifiers.command;
                    match unit {
                        egui::MouseWheelUnit::Line | egui::MouseWheelUnit::Page => {
                            notches += delta.y;
                            ctrl_wheel |= ctrl;
                        }
                        // ctrl + two fingers arrives through zoom_delta.
                        egui::MouseWheelUnit::Point if ctrl => {}
                        egui::MouseWheelUnit::Point => glide -= *delta,
                    }
                }
            }
        });
        let pinch = if ctrl_wheel { 1.0 } else { ui.input(|i| i.zoom_delta()) };
        let touch = ui.input(|i| i.multi_touch()).map(|t| t.translation_delta).unwrap_or(Vec2::ZERO);
        let anchor = ui.input(|i| i.pointer.hover_pos()).unwrap_or(self.canvas.center());

        if notches != 0.0 {
            // 8% a notch, eased: precise enough to aim a framing, and the
            // glide makes a fast spin feel continuous rather than stepped.
            self.zoom_towards(1.08f32.powf(notches.clamp(-10.0, 10.0)), anchor);
        }
        let continuous = pinch;
        if (continuous - 1.0).abs() > 0.0001 {
            // A pinch is already smooth and is the finger's own position: apply
            // it now, and let any wheel glide in flight follow from here.
            self.flight = None;
            if let Some((t, a)) = self.zoom_goal {
                self.zoom_goal = Some(((t * continuous).clamp(ZOOM_MIN, ZOOM_MAX), a));
            }
            self.zoom_about(continuous, anchor);
        }
        let pan = glide + -touch;
        if pan != Vec2::ZERO {
            self.flight = None;
            self.view += pan / self.zoom;
        }
    }

    fn piece_at(&self, at: Vec2) -> Option<usize> {
        let mut best: Option<usize> = None;
        for (i, p) in self.pieces.iter().enumerate() {
            if contains(p, at) && best.is_none_or(|b| self.pieces[b].z <= p.z) {
                best = Some(i);
            }
        }
        best
    }

    /// The selection's bounds on screen, when there is a selection to handle.
    fn selection_screen_bounds(&self) -> Option<Rect> {
        if self.selection.is_empty() {
            return None;
        }
        let chosen = &self.selection;
        let (lo, hi) = self.bounds(|p| chosen.contains(&p.id))?;
        Some(Rect::from_two_pos(self.to_screen(lo.x, lo.y), self.to_screen(hi.x, hi.y)))
    }

    fn handle_at(&self, at: Pos2) -> Option<Handle> {
        let r = self.selection_screen_bounds()?;
        if r.width() < 24.0 && r.height() < 24.0 {
            return None;
        }
        let knob = Pos2::new(r.center().x, r.min.y - KNOB_GAP);
        if at.distance(knob) <= 9.0 {
            return Some(Handle::Knob);
        }
        let cs = [r.left_top(), r.right_top(), r.right_bottom(), r.left_bottom()];
        cs.iter().position(|c| (at - *c).abs().max_elem() <= HANDLE).map(Handle::Corner)
    }

    fn header_at(&self, at: Pos2) -> Option<i64> {
        self.containers.iter().rev().find_map(|b| {
            let min = self.to_screen(b.x, b.y);
            let max = self.to_screen(b.x + b.w, b.y + b.h);
            // The name sits ABOVE the outline, so pictures filling a group
            // can never cover the handle that moves it.
            let header = Rect::from_min_max(Pos2::new(min.x, min.y - HEADER), Pos2::new(max.x, min.y + 6.0));
            header.contains(at).then_some(b.id)
        })
    }

    fn grip_at(&self, at: Pos2) -> Option<i64> {
        self.containers.iter().rev().find_map(|b| {
            let max = self.to_screen(b.x + b.w, b.y + b.h);
            Rect::from_min_max(max - Vec2::splat(GRIP), max).contains(at).then_some(b.id)
        })
    }

    fn selected_geometry(&self) -> Vec<(String, f32, f32, f32, f32)> {
        self.pieces
            .iter()
            .filter(|p| self.selection.contains(&p.id))
            .map(|p| (p.id.clone(), p.x, p.y, p.w, p.h))
            .collect()
    }

    fn raise(&mut self, id: &str) {
        let top = self.pieces.iter().map(|p| p.z).max().unwrap_or(0);
        if let Some(p) = self.pieces.iter().find(|p| p.id == id) {
            if p.z == top && self.pieces.iter().filter(|q| q.z == top).count() == 1 {
                return;
            }
        }
        self.top_z = self.top_z.max(top) + 1;
        let z = self.top_z;
        if let Some(p) = self.pieces.iter_mut().find(|p| p.id == id) {
            p.z = z;
        }
        if let Some(p) = self.pieces.iter().find(|p| p.id == id) {
            self.commit(p);
        }
    }

    fn pointer(&mut self, ui: &egui::Ui, response: &egui::Response) {
        let ctx = ui.ctx().clone();
        let (now, shift, pos, press) = ctx.input(|i| (i.time, i.modifiers.shift, i.pointer.hover_pos(), i.pointer.press_origin()));

        /*
         * THE EYEDROPPER owns the pointer while it is armed.
         *
         * One click picks, then it disarms: a picker that stays on turns the
         * next ordinary click on a picture into a colour nobody wanted.
         * Panning stays possible with the middle button and the wheel.
         */
        if self.picking {
            if response.contains_pointer() {
                ctx.set_cursor_icon(CursorIcon::Crosshair);
            }
            if response.clicked() {
                if let Some(at) = pos {
                    self.capture = Some(crate::Capture::Pick(at));
                }
                self.picking = false;
            }
            if response.secondary_clicked() {
                self.picking = false;
            }
            if response.drag_started_by(egui::PointerButton::Middle) {
                self.grab = Grab::Pan;
            }
            if response.dragged() && self.grab == Grab::Pan {
                self.view -= response.drag_delta() / self.zoom;
            }
            if response.drag_stopped() {
                self.grab = Grab::None;
                self.save_view();
            }
            return;
        }

        // What is under the pointer, for hover and cursor.
        self.hovered = None;
        if response.contains_pointer() && !self.grab.is_active() {
            if let Some(at) = pos {
                match self.handle_at(at) {
                    Some(Handle::Corner(i)) => ctx.set_cursor_icon(if i % 2 == 0 { CursorIcon::ResizeNwSe } else { CursorIcon::ResizeNeSw }),
                    Some(Handle::Knob) => ctx.set_cursor_icon(CursorIcon::Grab),
                    None => {
                        if let Some(i) = self.piece_at(self.to_board(at)) {
                            self.hovered = Some(self.pieces[i].id.clone());
                        } else if self.grip_at(at).is_some() {
                            ctx.set_cursor_icon(CursorIcon::ResizeNwSe);
                        } else if self.header_at(at).is_some() {
                            ctx.set_cursor_icon(CursorIcon::Grab);
                        }
                    }
                }
            }
        }

        // ── starting a gesture ───────────────────────────────────────────
        if response.drag_started_by(egui::PointerButton::Primary) {
            let origin = press.or(pos).unwrap_or(self.canvas.center());
            let at = self.to_board(origin);
            self.flight = None;
            if let Some(h) = self.handle_at(origin) {
                self.checkpoint();
                let chosen = self.selection.clone();
                let (lo, hi) = self.bounds(|p| chosen.contains(&p.id)).unwrap_or((at, at));
                self.grab = match h {
                    Handle::Corner(i) => {
                        let cs = [lo, Vec2::new(hi.x, lo.y), hi, Vec2::new(lo.x, hi.y)];
                        Grab::Corner { from: self.selected_geometry(), anchor: cs[(i + 2) % 4], start: cs[i] }
                    }
                    Handle::Knob => {
                        let centre = (lo + hi) / 2.0;
                        let v = at - centre;
                        Grab::Turn {
                            from: self
                                .pieces
                                .iter()
                                .filter(|p| chosen.contains(&p.id))
                                .map(|p| (p.id.clone(), p.angle, p.x + p.w / 2.0, p.y + p.h / 2.0))
                                .collect(),
                            centre,
                            start: v.y.atan2(v.x),
                            by_key: false,
                        }
                    }
                };
            } else if let Some(id) = self.grip_at(origin) {
                self.checkpoint();
                self.grab = Grab::ResizeGroup { id };
            } else if let Some(i) = self.piece_at(at) {
                let id = self.pieces[i].id.clone();
                if !self.selection.contains(&id) {
                    if shift {
                        self.selection.push(id.clone());
                    } else {
                        self.selection = vec![id.clone()];
                    }
                }
                self.checkpoint();
                self.raise(&id);
                let chosen = self.selection.clone();
                let (lo, hi) = self.bounds(|p| chosen.contains(&p.id)).unwrap_or((at, at));
                self.grab = Grab::Move {
                    from: self.pieces.iter().filter(|p| chosen.contains(&p.id)).map(|p| (p.id.clone(), p.x, p.y)).collect(),
                    lo,
                    hi,
                    total: Vec2::ZERO,
                    guides: Vec::new(),
                };
            } else if let Some(id) = self.header_at(origin) {
                self.checkpoint();
                let members = self
                    .containers
                    .iter()
                    .find(|b| b.id == id)
                    .map(|b| {
                        self.pieces
                            .iter()
                            .filter(|p| {
                                let (cx, cy) = p.centre();
                                b.contains(cx, cy)
                            })
                            .map(|p| p.id.clone())
                            .collect()
                    })
                    .unwrap_or_default();
                self.grab = Grab::MoveGroup { id, members };
            } else {
                // Shift-drag, or double-click-and-drag, draws a marquee; a plain
                // drag pans, because on an infinite canvas that is the gesture
                // a hand — or a finger — makes first.
                let (t, p0) = self.last_empty_click;
                let second_press = now - t < 0.45 && p0.distance(origin) < 16.0;
                self.grab = if shift || second_press {
                    Grab::Marquee { from: at, to: at, additive: shift }
                } else {
                    Grab::Pan
                };
            }
        }
        if response.drag_started_by(egui::PointerButton::Secondary) {
            let origin = press.or(pos).unwrap_or(self.canvas.center());
            if let Some(i) = self.piece_at(self.to_board(origin)) {
                let id = self.pieces[i].id.clone();
                if !self.selection.contains(&id) {
                    self.selection = vec![id];
                }
                self.checkpoint();
                self.grab = Grab::Stretch { from: self.selected_geometry(), start: origin, ratio_locked: shift };
            } else {
                self.grab = Grab::Pan;
            }
        }
        if response.drag_started_by(egui::PointerButton::Middle) {
            self.grab = Grab::Pan;
        }

        // ── during ───────────────────────────────────────────────────────
        if response.dragged() {
            let delta = response.drag_delta() / self.zoom;
            let here = pos.map(|p| self.to_board(p));
            match self.grab.clone() {
                Grab::Pan => {
                    self.view -= delta;
                    ctx.set_cursor_icon(CursorIcon::Grabbing);
                }
                Grab::Move { from, lo, hi, total, .. } => {
                    let total = total + delta;
                    // Alt moves freely, for the times a near-alignment is the
                    // point.
                    let free = ctx.input(|i| i.modifiers.alt);
                    let (snap, guides) = if free { (Vec2::ZERO, Vec::new()) } else { self.snap(lo + total, hi + total, &from) };
                    let offset = total + snap;
                    for (id, x0, y0) in &from {
                        if let Some(t) = self.pieces.iter_mut().find(|t| &t.id == id) {
                            t.x = x0 + offset.x;
                            t.y = y0 + offset.y;
                        }
                    }
                    self.grab = Grab::Move { from, lo, hi, total, guides };
                    ctx.set_cursor_icon(CursorIcon::Grabbing);
                }
                Grab::Marquee { from, additive, .. } => {
                    if let Some(h) = here {
                        self.grab = Grab::Marquee { from, to: h, additive };
                    }
                }
                Grab::Stretch { from, start, ratio_locked } => {
                    if let Some(at) = pos {
                        let fw = (1.0 + (at.x - start.x) / 220.0).max(0.05);
                        let fh = (1.0 + (at.y - start.y) / 220.0).max(0.05);
                        let (fw, fh) = if ratio_locked { (fh, fh) } else { (fw, fh) };
                        for (id, x0, y0, w0, h0) in &from {
                            if let Some(t) = self.pieces.iter_mut().find(|t| &t.id == id) {
                                let (cx, cy) = (x0 + w0 / 2.0, y0 + h0 / 2.0);
                                t.w = (w0 * fw).max(24.0);
                                t.h = (h0 * fh).max(18.0);
                                t.x = cx - t.w / 2.0;
                                t.y = cy - t.h / 2.0;
                            }
                        }
                    }
                }
                Grab::Corner { from, anchor, start } => {
                    if let Some(h) = here {
                        // Proportional, always: a corner handle that could
                        // distort reference is a handle nobody dares use.
                        let d0 = start - anchor;
                        let d1 = h - anchor;
                        let f = ((d1.x * d0.x + d1.y * d0.y) / d0.length_sq().max(1.0)).max(0.02);
                        for (id, x0, y0, w0, h0) in &from {
                            if let Some(t) = self.pieces.iter_mut().find(|t| &t.id == id) {
                                t.w = (w0 * f).max(12.0);
                                t.h = (h0 * f).max(9.0);
                                t.x = anchor.x + (x0 - anchor.x) * f;
                                t.y = anchor.y + (y0 - anchor.y) * f;
                            }
                        }
                        ctx.set_cursor_icon(CursorIcon::ResizeNwSe);
                    }
                }
                Grab::Turn { from, centre, start, by_key: false } => {
                    if let Some(h) = here {
                        let v = h - centre;
                        let mut by = (v.y.atan2(v.x) - start).to_degrees();
                        if shift {
                            by = (by / 15.0).round() * 15.0;
                        }
                        self.turn(&from, centre, by);
                        ctx.set_cursor_icon(CursorIcon::Grabbing);
                    }
                }
                Grab::MoveGroup { id, members } => {
                    if let Some(b) = self.containers.iter_mut().find(|b| b.id == id) {
                        b.x += delta.x;
                        b.y += delta.y;
                    }
                    for p in self.pieces.iter_mut().filter(|p| members.contains(&p.id)) {
                        p.x += delta.x;
                        p.y += delta.y;
                    }
                    ctx.set_cursor_icon(CursorIcon::Grabbing);
                }
                Grab::ResizeGroup { id } => {
                    if let Some(b) = self.containers.iter_mut().find(|b| b.id == id) {
                        b.w = (b.w + delta.x).max(160.0);
                        b.h = (b.h + delta.y).max(120.0);
                    }
                    ctx.set_cursor_icon(CursorIcon::ResizeNwSe);
                }
                _ => {}
            }
        }

        // R held: turn with the pointer's horizontal travel.
        if let Grab::Turn { from, centre, start, by_key: true } = self.grab.clone() {
            if let Some(at) = pos {
                let mut by = (at.x - start) / 3.0;
                if shift {
                    by = (by / 15.0).round() * 15.0;
                }
                self.turn(&from, centre, by);
            }
            let done = ctx.input(|i| !i.key_down(Key::R) || i.pointer.any_pressed());
            if done {
                self.grab = Grab::None;
                self.commit_selection();
            }
        }

        // ── ending ───────────────────────────────────────────────────────
        if response.drag_stopped() {
            match std::mem::replace(&mut self.grab, Grab::None) {
                Grab::Pan => self.save_view(),
                Grab::Move { .. } | Grab::Stretch { .. } | Grab::Corner { .. } | Grab::Turn { .. } => {
                    self.settle_membership_of_selection();
                    self.commit_selection();
                }
                Grab::Marquee { from, to, additive } => {
                    let (lo, hi) = (from.min(to), from.max(to));
                    // Overlap, not containment: a marquee that only takes what
                    // it entirely surrounds cannot select anything larger than
                    // the window.
                    let hit: Vec<String> = self
                        .pieces
                        .iter()
                        .filter(|p| {
                            let cs = corners(p);
                            let (plo, phi) = cs.iter().fold((cs[0], cs[0]), |(a, b), c| (a.min(*c), b.max(*c)));
                            plo.x < hi.x && phi.x > lo.x && plo.y < hi.y && phi.y > lo.y
                        })
                        .map(|p| p.id.clone())
                        .collect();
                    if additive {
                        for id in hit {
                            if !self.selection.contains(&id) {
                                self.selection.push(id);
                            }
                        }
                    } else {
                        self.selection = hit;
                    }
                }
                Grab::MoveGroup { id, members } => {
                    if let Some(b) = self.containers.iter().find(|b| b.id == id).cloned() {
                        self.write_container(&b);
                    }
                    for p in self.pieces.iter().filter(|p| members.contains(&p.id)) {
                        self.commit(p);
                    }
                }
                Grab::ResizeGroup { id } => {
                    if let Some(b) = self.containers.iter().find(|b| b.id == id).cloned() {
                        self.write_container(&b);
                    }
                    // Resizing an outline over a picture is how you gather things.
                    self.reconcile_membership();
                }
                Grab::None => {}
            }
        }

        /*
         * A LONG PRESS IS A RIGHT-CLICK, for a finger.
         *
         * A touchscreen has no second button, and without this every menu on
         * the board was out of reach. Only for touches: a mouse held still is
         * someone thinking, not asking for a menu.
         */
        let long_press = ctx.input(|i| {
            i.any_touches()
                && i.pointer.primary_down()
                && !i.pointer.is_decidedly_dragging()
                && i.pointer.press_start_time().is_some_and(|t| i.time - t > 0.55)
        });
        if long_press && self.menu == Menu::None && !self.grab.is_active() {
            if let Some(at) = pos {
                self.open_menu_at(at, ctx.cumulative_frame_nr());
                // The finger lifting would otherwise count as a click and
                // close the menu it just opened.
                self.swallow_click = true;
            }
        }
        if ctx.input(|i| i.any_touches() && i.pointer.primary_down() && !i.pointer.is_decidedly_dragging()) {
            ctx.request_repaint_after(std::time::Duration::from_millis(100));
        }

        // ── clicks ───────────────────────────────────────────────────────
        if response.clicked() && std::mem::take(&mut self.swallow_click) {
            // the release of a long press
        } else if response.clicked() {
            if let Some(at) = pos {
                match self.piece_at(self.to_board(at)) {
                    Some(i) => {
                        let id = self.pieces[i].id.clone();
                        if shift {
                            match self.selection.iter().position(|s| *s == id) {
                                Some(k) => {
                                    self.selection.remove(k);
                                }
                                None => self.selection.push(id.clone()),
                            }
                        } else {
                            self.selection = vec![id.clone()];
                        }
                        self.raise(&id);
                    }
                    None => {
                        if !shift && self.header_at(at).is_none() {
                            self.selection.clear();
                        }
                        self.last_empty_click = (now, at);
                    }
                }
            }
            self.menu = Menu::None;
        }
        if response.double_clicked() {
            if let Some(at) = pos {
                match self.piece_at(self.to_board(at)) {
                    // Double-click FILLS THE VIEW with it: look closely, then
                    // come back out.
                    Some(i) => {
                        self.selection = vec![self.pieces[i].id.clone()];
                        self.fit_selection(now);
                    }
                    None => {
                        if self.header_at(at).is_none() {
                            self.fit_all(now);
                        }
                    }
                }
            }
        }
        if response.secondary_clicked() {
            if let Some(at) = pos {
                self.open_menu_at(at, ctx.cumulative_frame_nr());
            }
        }
        if ctx.input(|i| i.pointer.any_released()) && !response.clicked() {
            self.swallow_click = false;
        }
    }

    /// The menu for whatever is under `at`: a picture, a group, or the board.
    fn open_menu_at(&mut self, at: Pos2, frame: u64) {
        self.menu_at = at;
        self.menu_frame = frame;
        if let Some(i) = self.piece_at(self.to_board(at)) {
            let id = self.pieces[i].id.clone();
            if !self.selection.contains(&id) {
                self.selection = vec![id];
            }
            self.menu = Menu::Piece;
        } else if let Some(id) = self.header_at(at) {
            self.menu = Menu::Container(id);
        } else {
            self.menu = Menu::Canvas;
        }
    }

    /*
     * SNAP TO WHAT IS ALREADY THERE.
     *
     * A reference board is mostly rows and columns of pictures, and lining one
     * up by eye at 30% zoom is a job for a tool. The moving selection's edges
     * and centre are pulled onto the nearest edge or centre of any other
     * picture or group within six SCREEN pixels — constant under zoom, so it
     * never grabs from across the board when zoomed out.
     */
    fn snap(&self, lo: Vec2, hi: Vec2, moving: &[(String, f32, f32)]) -> (Vec2, Vec<Guide>) {
        let reach = 6.0 / self.zoom;
        let (mut xs, mut ys): (Vec<f32>, Vec<f32>) = (Vec::new(), Vec::new());
        let view = Rect::from_min_max(self.to_board(self.canvas.min).to_pos2(), self.to_board(self.canvas.max).to_pos2());
        for p in &self.pieces {
            if moving.iter().any(|m| m.0 == p.id) {
                continue;
            }
            let cs = corners(p);
            let (a, b) = cs.iter().fold((cs[0], cs[0]), |(a, b), c| (a.min(*c), b.max(*c)));
            // Only what can be seen: a line to something off screen is a
            // snap nobody can understand.
            if !view.intersects(Rect::from_min_max(a.to_pos2(), b.to_pos2())) {
                continue;
            }
            xs.extend([a.x, (a.x + b.x) / 2.0, b.x]);
            ys.extend([a.y, (a.y + b.y) / 2.0, b.y]);
        }
        for b in &self.containers {
            xs.extend([b.x, b.x + b.w]);
            ys.extend([b.y, b.y + b.h]);
        }
        let nearest = |ours: [f32; 3], theirs: &[f32]| -> Option<(f32, f32)> {
            let mut best: Option<(f32, f32)> = None;
            for o in ours {
                for t in theirs {
                    let d = *t - o;
                    if d.abs() <= reach && best.is_none_or(|b| d.abs() < b.0.abs()) {
                        best = Some((d, *t));
                    }
                }
            }
            best
        };
        let mut snap = Vec2::ZERO;
        let mut guides = Vec::new();
        if let Some((d, at)) = nearest([lo.x, (lo.x + hi.x) / 2.0, hi.x], &xs) {
            snap.x = d;
            guides.push(Guide { vertical: true, at });
        }
        if let Some((d, at)) = nearest([lo.y, (lo.y + hi.y) / 2.0, hi.y], &ys) {
            snap.y = d;
            guides.push(Guide { vertical: false, at });
        }
        (snap, guides)
    }

    fn turn(&mut self, from: &[(String, f32, f32, f32)], centre: Vec2, by: f32) {
        let rot = Rot2::from_angle(by.to_radians());
        let single = from.len() == 1;
        for (id, a0, cx, cy) in from {
            if let Some(t) = self.pieces.iter_mut().find(|t| &t.id == id) {
                t.angle = (a0 + by).rem_euclid(360.0);
                // Several pictures turn as ONE thing, about their shared
                // centre; one picture just turns in place.
                let c = if single { Vec2::new(*cx, *cy) } else { centre + rot * (Vec2::new(*cx, *cy) - centre) };
                t.x = c.x - t.w / 2.0;
                t.y = c.y - t.h / 2.0;
            }
        }
    }

    /// Membership follows where a picture ENDED UP: dropped inside an
    /// outline it belongs, dragged out it does not.
    fn settle_membership_of_selection(&mut self) {
        let boxes = self.containers.clone();
        let chosen = self.selection.clone();
        for p in self.pieces.iter_mut().filter(|p| chosen.contains(&p.id)) {
            let (cx, cy) = p.centre();
            p.container = boxes.iter().filter(|b| b.contains(cx, cy)).map(|b| b.id).last().unwrap_or(0);
        }
    }

    /*
     * A container is an OUTLINE and a name.
     *
     * Filled, it competes with the pictures it exists to group. The outline
     * brightens under the pointer so its header reads as the handle it is.
     */
    fn draw_containers(&self, painter: &egui::Painter) {
        let p = self.canvas_palette();
        let pointer = painter.ctx().input(|i| i.pointer.hover_pos());
        for b in &self.containers {
            let min = self.to_screen(b.x, b.y);
            let max = self.to_screen(b.x + b.w, b.y + b.h);
            let r = Rect::from_min_max(min, max);
            if !self.canvas.intersects(r.expand(4.0)) {
                continue;
            }
            let hot = pointer.is_some_and(|at| self.header_at(at) == Some(b.id) || self.grip_at(at) == Some(b.id))
                || matches!(&self.grab, Grab::MoveGroup { id, .. } | Grab::ResizeGroup { id } if *id == b.id);
            let ink = self.ground_colours().1;
            let line = if hot { alpha(p.primary, 0.9) } else { alpha(ink, 0.22) };
            let ground = self.prefs.ground.max(0.35);
            painter.rect_stroke(r, CornerRadius::same(10), Stroke::new(if hot { 1.5 } else { 1.0 }, alpha(line, ground)), StrokeKind::Inside);

            let members = self
                .pieces
                .iter()
                .filter(|q| {
                    let (cx, cy) = q.centre();
                    b.contains(cx, cy)
                })
                .count();
            let label = if b.label.is_empty() { "Untitled group" } else { &b.label };
            let name = painter.layout_no_wrap(label.to_string(), FontId::proportional(13.0), alpha(ink, 0.85 * ground));
            let name_w = name.size().x;
            let top = min + Vec2::new(4.0, -HEADER / 2.0 - name.size().y / 2.0 - 2.0);
            if r.width() > 60.0 {
                painter.galley(top, name, p.on_surface);
                painter.text(
                    top + Vec2::new(name_w + 8.0, 1.5),
                    Align2::LEFT_TOP,
                    if members == 0 { "empty".to_string() } else { members.to_string() },
                    FontId::proportional(11.5),
                    alpha(ink, 0.55 * ground),
                );
            }
            // The grip: two short diagonals in the corner, the mark every
            // resizable thing has taught.
            let g = alpha(if hot { p.primary } else { ink }, 0.5 * ground);
            for k in [5.0, 10.0] {
                painter.line_segment([max - Vec2::new(k, 3.0), max - Vec2::new(3.0, k)], Stroke::new(1.2, g));
            }
        }
    }

    fn draw_pieces(&mut self, ui: &egui::Ui, painter: &egui::Painter) {
        let p = self.canvas_palette();
        let mut order: Vec<usize> = (0..self.pieces.len()).collect();
        order.sort_by_key(|i| self.pieces[*i].z);
        let ppp = ui.ctx().pixels_per_point();
        let tint = Color32::from_white_alpha((self.prefs.picture_opacity.clamp(0.1, 1.0) * 255.0) as u8);

        for i in order {
            let piece = self.pieces[i].clone();
            let quad: Vec<Pos2> = corners(&piece).iter().map(|c| self.to_screen(c.x, c.y)).collect();
            let aabb = Rect::from_points(&quad);
            if !self.canvas.intersects(aabb) {
                continue; // off screen: no texture, no work
            }
            let drawn = piece.w.max(piece.h) * self.zoom * ppp;
            let step = step_for(drawn);
            match self.textures.get(ui.ctx(), &piece.id, step, piece.sharp) {
                Some(tex) => {
                    let (mut u0, mut u1, mut v0, mut v1) = (0.0, 1.0, 0.0, 1.0);
                    if piece.hflip {
                        std::mem::swap(&mut u0, &mut u1);
                    }
                    if piece.vflip {
                        std::mem::swap(&mut v0, &mut v1);
                    }
                    let uvs = [Pos2::new(u0, v0), Pos2::new(u1, v0), Pos2::new(u1, v1), Pos2::new(u0, v1)];
                    let mut mesh = Mesh::with_texture(tex.id());
                    for k in 0..4 {
                        mesh.vertices.push(egui::epaint::Vertex { pos: quad[k], uv: uvs[k], color: tint });
                    }
                    mesh.add_triangle(0, 1, 2);
                    mesh.add_triangle(0, 2, 3);
                    painter.add(Shape::mesh(mesh));
                }
                // A frame, not a hole, and not a colour guess: the board knows
                // where a picture goes before it knows what it looks like.
                None => {
                    painter.add(Shape::convex_polygon(quad.clone(), alpha(p.on_surface, 0.05), Stroke::new(1.0, alpha(p.on_surface, 0.08))));
                }
            }

            let selected = self.selection.contains(&piece.id) && !self.clean_frame;
            if selected {
                painter.add(Shape::closed_line(quad.clone(), Stroke::new(2.0, p.primary)));
            } else if self.hovered.as_deref() == Some(piece.id.as_str()) && !self.grab.is_active() {
                painter.add(Shape::closed_line(quad, Stroke::new(1.5, alpha(p.primary, 0.55))));
            }
        }
    }

    /// Handles on the selection's bounds: four corners that scale, one knob
    /// that turns. Constant size on screen, so they can be hit at any zoom.
    fn draw_selection(&self, painter: &egui::Painter) {
        if matches!(self.grab, Grab::Pan | Grab::Marquee { .. } | Grab::MoveGroup { .. }) || self.chrome_hidden || self.clean_frame {
            return;
        }
        let Some(r) = self.selection_screen_bounds() else { return };
        if r.width() < 24.0 && r.height() < 24.0 {
            return;
        }
        let p = self.canvas_palette();
        if self.selection.len() > 1 {
            painter.add(Shape::dashed_line(
                &[r.left_top(), r.right_top(), r.right_bottom(), r.left_bottom(), r.left_top()],
                Stroke::new(1.0, alpha(p.primary, 0.7)),
                5.0,
                4.0,
            ));
        }
        let knob = Pos2::new(r.center().x, r.min.y - KNOB_GAP);
        painter.line_segment([Pos2::new(r.center().x, r.min.y), knob], Stroke::new(1.0, alpha(p.primary, 0.7)));
        painter.circle(knob, 5.5, p.surface_lowest, Stroke::new(1.5, p.primary));
        for c in [r.left_top(), r.right_top(), r.right_bottom(), r.left_bottom()] {
            let h = Rect::from_center_size(c, Vec2::splat(HANDLE));
            painter.rect(h, CornerRadius::same(2), mix(p.surface_lowest, p.on_surface, 0.95), Stroke::new(1.5, p.primary), StrokeKind::Middle);
        }
        // Size readout while scaling, the one number you are aiming for.
        if let Grab::Corner { .. } | Grab::Stretch { .. } = self.grab {
            if let Some(piece) = self.pieces.iter().find(|q| self.selection.first() == Some(&q.id)) {
                let text = format!("{:.0} × {:.0}", piece.w, piece.h);
                let at = Pos2::new(r.center().x, r.max.y + 18.0);
                let g = painter.layout_no_wrap(text, FontId::proportional(12.0), p.on_primary);
                let bg = Rect::from_center_size(at, g.size() + Vec2::new(14.0, 6.0));
                painter.rect_filled(bg, CornerRadius::same(8), p.primary);
                painter.galley(bg.center() - g.size() / 2.0, g, p.on_primary);
            }
        }
        if let Grab::Turn { .. } = self.grab {
            if let Some(piece) = self.pieces.iter().find(|q| self.selection.first() == Some(&q.id)) {
                let text = format!("{:.0}°", piece.angle);
                let g = painter.layout_no_wrap(text, FontId::proportional(12.0), p.on_primary);
                let bg = Rect::from_center_size(knob - Vec2::new(0.0, 20.0), g.size() + Vec2::new(14.0, 6.0));
                painter.rect_filled(bg, CornerRadius::same(8), p.primary);
                painter.galley(bg.center() - g.size() / 2.0, g, p.on_primary);
            }
        }
    }

    /*
     * THE KEYS.
     *
     * Largely RIA's, which are what an artist's hands already know — and never
     * while a text field has the keyboard, or typing a search for "hv" would
     * flip the selection twice.
     */
    fn keys(&mut self, ui: &egui::Ui) {
        let ctx = ui.ctx().clone();
        let (shift, ctrl, now) = ctx.input(|i| (i.modifiers.shift, i.modifiers.command || i.modifiers.ctrl, i.time));
        let pressed = |k: Key| ctx.input(|i| i.key_pressed(k));
        let centre = self.free_area().center();

        if ctrl {
            if pressed(Key::Z) {
                if shift { self.redo() } else { self.undo() }
            }
            if pressed(Key::Y) {
                self.redo();
            }
            if pressed(Key::A) {
                if shift {
                    self.arrange(crate::Arrange::Grid);
                } else {
                    self.selection = self.pieces.iter().map(|p| p.id.clone()).collect();
                }
            }
            if pressed(Key::G) {
                self.group_selection();
            }
            if pressed(Key::V) {
                self.paste();
            }
            if pressed(Key::C) {
                self.copy();
            }
            if pressed(Key::E) {
                self.export_view();
            }
            if pressed(Key::N) {
                self.dialog = crate::Dialog::NewBoard(String::new());
                self.dialog_focus = true;
            }
            if pressed(Key::Num0) {
                self.zoom_towards(1.0 / self.zoom, centre);
            }
            return;
        }

        if pressed(Key::F) {
            if self.selection.is_empty() { self.fit_all(now) } else { self.fit_selection(now) }
        }
        if pressed(Key::I) {
            self.picking = !self.picking;
            if self.picking {
                self.toast("Click anything on the board to copy its colour", ToastKind::Info);
            }
        }
        if pressed(Key::Escape) && self.picking {
            self.picking = false;
        } else if pressed(Key::Escape) {
            if self.menu != Menu::None || self.switcher_open || self.fade_open || self.more_open || self.zoom_open {
                self.menu = Menu::None;
                self.switcher_open = false;
                self.fade_open = false;
                self.more_open = false;
                self.zoom_open = false;
            } else if let Grab::Turn { by_key: true, .. } = self.grab {
                self.grab = Grab::None;
                self.undo();
            } else {
                self.selection.clear();
            }
        }
        if pressed(Key::Delete) || pressed(Key::Backspace) {
            self.remove_selection();
        }
        if pressed(Key::H) {
            self.edit_selection(|p| p.hflip = !p.hflip);
        }
        if pressed(Key::V) {
            self.edit_selection(|p| p.vflip = !p.vflip);
        }
        if pressed(Key::R) && !self.selection.is_empty() {
            // Held: turn with the pointer. Tapped: nothing moves until the
            // pointer does, so a tap is a no-op rather than a surprise.
            if let Some(at) = ctx.input(|i| i.pointer.hover_pos()) {
                self.checkpoint();
                let chosen = self.selection.clone();
                let (lo, hi) = self.bounds(|p| chosen.contains(&p.id)).unwrap_or_default();
                self.grab = Grab::Turn {
                    from: self
                        .pieces
                        .iter()
                        .filter(|p| chosen.contains(&p.id))
                        .map(|p| (p.id.clone(), p.angle, p.x + p.w / 2.0, p.y + p.h / 2.0))
                        .collect(),
                    centre: (lo + hi) / 2.0,
                    start: at.x,
                    by_key: true,
                };
            }
        }
        if pressed(Key::CloseBracket) {
            self.bring_to_front();
        }
        if pressed(Key::OpenBracket) {
            self.send_to_back();
        }
        if pressed(Key::Plus) || pressed(Key::Equals) {
            self.zoom_towards(1.25, centre);
        }
        if pressed(Key::Minus) {
            self.zoom_towards(0.8, centre);
        }
        if pressed(Key::Space) {
            let zoom = self.zoom;
            let offset = self.free_area().center() - self.canvas.min;
            self.fly_to(-offset / zoom, zoom, now);
        }
        if pressed(Key::Tab) {
            self.prefs.library = !self.prefs.library;
        }
        if pressed(Key::G) {
            self.prefs.grid = !self.prefs.grid;
        }
        if pressed(Key::M) {
            self.prefs.minimap = !self.prefs.minimap;
        }
        if pressed(Key::Backslash) {
            self.chrome_hidden = !self.chrome_hidden;
            if self.chrome_hidden {
                self.toast("Interface hidden · press \\ to bring it back", ToastKind::Info);
            }
        }
        if pressed(Key::F1) || pressed(Key::Questionmark) || (shift && pressed(Key::Slash)) {
            self.dialog = crate::Dialog::Help;
        }
        if pressed(Key::F2) && !self.open.is_empty() {
            self.dialog = crate::Dialog::RenameBoard(self.open.clone());
            self.dialog_focus = true;
        }

        // Arrows nudge the selection; with nothing selected they pan.
        let mut nudge = Vec2::ZERO;
        let step = if shift { 10.0 } else { 1.0 };
        for (k, v) in [(Key::ArrowLeft, Vec2::new(-1.0, 0.0)), (Key::ArrowRight, Vec2::new(1.0, 0.0)), (Key::ArrowUp, Vec2::new(0.0, -1.0)), (Key::ArrowDown, Vec2::new(0.0, 1.0))] {
            if pressed(k) {
                nudge += v;
            }
        }
        if nudge != Vec2::ZERO {
            if self.selection.is_empty() {
                self.view += nudge * 60.0 / self.zoom;
            } else {
                self.edit_selection(|p| {
                    p.x += nudge.x * step;
                    p.y += nudge.y * step;
                });
            }
        }
    }
}
