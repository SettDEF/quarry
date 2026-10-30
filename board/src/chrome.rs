//! The floating interface.
//!
//! Nothing here is a panel that takes space from the board. Every control
//! floats over the canvas in a small surface at an edge, so the pictures run
//! under the chrome to the window's edges, and hiding the interface (`\`)
//! leaves exactly the board. RIA has no persistent chrome at all — a sidebar
//! on TAB, a menu on right-click — which is the right instinct for an app you
//! look THROUGH; this keeps that, and makes what is there discoverable.

use egui::{Align, Align2, Area, Color32, CornerRadius, CursorIcon, FontId, Id, Layout, Order, Pos2, Rect, RichText, Sense, Stroke, StrokeKind, Vec2};
use egui_phosphor::regular as icon;

use crate::model::Record;
use crate::theme::{alpha, mix};
use crate::widgets::{self, caption, hsep, icon_button, kbd, menu_row, pill, surface, tip, vsep, Kind, Row};
use crate::{App, Dialog, Menu, ToastKind};

pub const LIBRARY_WIDTH: f32 = 320.0;
const EDGE: f32 = 12.0;
const BAR_H: f32 = 44.0;
/// Room for the window buttons the compositor floats over the top-right corner
/// (ii-decor "overlay": three 12 px dots, 8 px gaps, 10 px padding, plus a gap),
/// so the right-hand bar sits beside them instead of under them.
const DECOR_PILL: f32 = 84.0;

/// True when a press landed outside every rect given — how a popup knows it
/// has been dismissed.
fn pressed_outside(ctx: &egui::Context, rects: &[Rect]) -> bool {
    ctx.input(|i| {
        i.pointer.any_pressed() && i.pointer.interact_pos().is_some_and(|p| rects.iter().all(|r| !r.contains(p)))
    })
}

impl App {
    pub fn chrome(&mut self, ctx: &egui::Context) {
        if !self.chrome_hidden {
            self.bar_left(ctx);
            self.bar_right(ctx);
            if self.prefs.library {
                self.library_panel(ctx);
            }
            self.zoom_hud(ctx);
            if self.prefs.minimap {
                self.minimap(ctx);
            }
            if !self.selection.is_empty() && !self.grab.is_active() {
                self.selection_bar(ctx);
            }
            self.popups(ctx);
            self.empty_state(ctx);
        }
        self.context_menu(ctx);
        self.carry(ctx);
        self.dialog(ctx);
        self.toasts(ctx);
    }

    // ── top left: library, board switcher ────────────────────────────────

    fn bar_left(&mut self, ctx: &egui::Context) {
        let p = self.theme.p;
        Area::new(Id::new("bar-left")).anchor(Align2::LEFT_TOP, [EDGE, EDGE]).order(Order::Foreground).show(ctx, |ui| {
            surface(&p).show(ui, |ui| {
                ui.set_height(BAR_H - 10.0);
                ui.horizontal_centered(|ui| {
                    let r = icon_button(ui, &p, icon::SIDEBAR_SIMPLE, self.prefs.library);
                    if tip(r, &p, "Library", &["Tab"]).clicked() {
                        self.prefs.library = !self.prefs.library;
                    }
                    vsep(ui, &p);

                    // The board switcher: which board, how full, and a way to
                    // the others — one control where there used to be a strip
                    // of every board's name.
                    let (name, count) = if self.client.is_none() {
                        ("Offline".to_string(), None)
                    } else if self.open.is_empty() {
                        ("No board".to_string(), None)
                    } else {
                        (self.open.clone(), Some(self.pieces.len()))
                    };
                    let font = FontId::proportional(14.0);
                    let name_g = ui.painter().layout_no_wrap(name, font, p.on_surface);
                    let count_g = count.map(|c| ui.painter().layout_no_wrap(c.to_string(), FontId::proportional(12.0), p.on_surface_variant));
                    let width = 26.0 + name_g.size().x.min(260.0) + count_g.as_ref().map(|g| g.size().x + 10.0).unwrap_or(0.0) + 30.0;
                    let (rect, resp) = ui.allocate_exact_size(Vec2::new(width, 32.0), Sense::click());
                    let hover = ui.ctx().animate_bool_with_time(resp.id.with("h"), resp.hovered() || self.switcher_open, 0.1);
                    let painter = ui.painter();
                    painter.rect_filled(rect, CornerRadius::same(9), alpha(p.on_surface, 0.07 * hover));
                    painter.text(rect.left_center() + Vec2::new(14.0, 0.0), Align2::CENTER_CENTER, icon::SQUARES_FOUR, FontId::proportional(16.0), p.primary);
                    let mut x = rect.left() + 28.0;
                    let name_w = name_g.size().x.min(260.0);
                    let clip = Rect::from_min_size(Pos2::new(x, rect.top()), Vec2::new(name_w, rect.height()));
                    painter.with_clip_rect(clip).galley(Pos2::new(x, rect.center().y - name_g.size().y / 2.0), name_g, p.on_surface);
                    x += name_w + 8.0;
                    if let Some(g) = count_g {
                        let pill_r = Rect::from_min_size(Pos2::new(x, rect.center().y - 9.0), Vec2::new(g.size().x + 10.0, 18.0));
                        painter.rect_filled(pill_r, CornerRadius::same(9), alpha(p.on_surface, 0.08));
                        painter.galley(pill_r.center() - g.size() / 2.0, g, p.on_surface_variant);
                    }
                    painter.text(rect.right_center() - Vec2::new(14.0, 0.0), Align2::CENTER_CENTER, icon::CARET_DOWN, FontId::proportional(13.0), p.on_surface_variant);
                    self.anchors.insert("switcher", rect);
                    if resp.on_hover_cursor(CursorIcon::PointingHand).clicked() && self.client.is_some() {
                        self.switcher_open = !self.switcher_open;
                    }
                });
            });
        });
    }

    // ── top right: grid, transparency, help, more ────────────────────────

    fn bar_right(&mut self, ctx: &egui::Context) {
        let p = self.theme.p;
        Area::new(Id::new("bar-right")).anchor(Align2::RIGHT_TOP, [-EDGE - DECOR_PILL, EDGE]).order(Order::Foreground).show(ctx, |ui| {
            surface(&p).show(ui, |ui| {
                ui.set_height(BAR_H - 10.0);
                ui.horizontal_centered(|ui| {
                    let r = icon_button(ui, &p, icon::DOTS_NINE, self.prefs.grid);
                    if tip(r, &p, "Grid", &["G"]).clicked() {
                        self.prefs.grid = !self.prefs.grid;
                    }
                    let faded = self.prefs.ground < 0.999 || self.prefs.picture_opacity < 0.999;
                    let r = icon_button(ui, &p, icon::DROP_HALF, faded || self.fade_open);
                    self.anchors.insert("fade", r.rect);
                    if tip(r, &p, "Ground & transparency", &[]).clicked() {
                        self.fade_open = !self.fade_open;
                    }
                    vsep(ui, &p);
                    let r = icon_button(ui, &p, icon::QUESTION, false);
                    if tip(r, &p, "Shortcuts", &["F1"]).clicked() {
                        self.dialog = Dialog::Help;
                    }
                    let r = icon_button(ui, &p, icon::DOTS_THREE_VERTICAL, self.more_open);
                    self.anchors.insert("more", r.rect);
                    if tip(r, &p, "More", &[]).clicked() {
                        self.more_open = !self.more_open;
                    }
                });
            });
        });
    }

    // ── bottom right: zoom ───────────────────────────────────────────────

    fn zoom_hud(&mut self, ctx: &egui::Context) {
        let p = self.theme.p;
        let now = ctx.input(|i| i.time);
        Area::new(Id::new("zoom")).anchor(Align2::RIGHT_BOTTOM, [-EDGE, -EDGE]).order(Order::Foreground).show(ctx, |ui| {
            surface(&p).show(ui, |ui| {
                ui.horizontal(|ui| {
                    let centre = self.free_area().center();
                    let r = icon_button(ui, &p, icon::MINUS, false);
                    if tip(r, &p, "Zoom out", &["−"]).clicked() {
                        self.zoom_towards(0.8, centre);
                    }
                    let shown = self.zoom_goal.map(|(t, _)| t).unwrap_or(self.zoom);
                    let text = format!("{:.0}%", shown * 100.0);
                    let (rect, resp) = ui.allocate_exact_size(Vec2::new(58.0, 32.0), Sense::click());
                    let hover = ui.ctx().animate_bool_with_time(resp.id.with("h"), resp.hovered() || self.zoom_open, 0.1);
                    ui.painter().rect_filled(rect, CornerRadius::same(9), alpha(p.on_surface, 0.07 * hover));
                    ui.painter().text(rect.center(), Align2::CENTER_CENTER, text, FontId::proportional(13.0), p.on_surface);
                    self.anchors.insert("zoom", rect);
                    if resp.on_hover_cursor(CursorIcon::PointingHand).clicked() {
                        self.zoom_open = !self.zoom_open;
                    }
                    let r = icon_button(ui, &p, icon::PLUS, false);
                    if tip(r, &p, "Zoom in", &["+"]).clicked() {
                        self.zoom_towards(1.25, centre);
                    }
                    vsep(ui, &p);
                    let r = icon_button(ui, &p, icon::CORNERS_OUT, false);
                    if tip(r, &p, "Fit everything", &["F"]).clicked() {
                        self.fit_all(now);
                    }
                    let r = icon_button(ui, &p, icon::MAP_TRIFOLD, self.prefs.minimap);
                    if tip(r, &p, "Overview", &["M"]).clicked() {
                        self.prefs.minimap = !self.prefs.minimap;
                    }
                });
            });
        });
    }

    /*
     * THE OVERVIEW.
     *
     * On a board bigger than the window, the question is always "where am I
     * and where is the rest". A map answers it at a glance, and dragging in
     * it is the fastest way across a large board.
     */
    fn minimap(&mut self, ctx: &egui::Context) {
        let p = self.theme.p;
        let view_min = self.view;
        let view_max = self.view + self.canvas.size() / self.zoom;
        let (lo, hi) = match self.bounds(|_| true) {
            Some((lo, hi)) => (lo.min(view_min), hi.max(view_max)),
            None => (view_min, view_max),
        };
        let span = (hi - lo).max(Vec2::splat(1.0));
        let size = Vec2::new(208.0, 136.0);
        Area::new(Id::new("minimap")).anchor(Align2::RIGHT_BOTTOM, [-EDGE, -EDGE - BAR_H - 8.0]).order(Order::Foreground).show(ctx, |ui| {
            surface(&p).show(ui, |ui| {
                let (rect, resp) = ui.allocate_exact_size(size, Sense::click_and_drag());
                let inner = rect.shrink(8.0);
                let scale = (inner.width() / span.x).min(inner.height() / span.y);
                let offset = inner.center() - (lo + span / 2.0) * scale;
                let map = |v: Vec2| Pos2::new(v.x * scale + offset.x, v.y * scale + offset.y);
                let painter = ui.painter_at(rect);
                for b in &self.containers {
                    let r = Rect::from_min_max(map(Vec2::new(b.x, b.y)), map(Vec2::new(b.x + b.w, b.y + b.h)));
                    painter.rect_stroke(r, CornerRadius::same(2), Stroke::new(1.0, alpha(p.on_surface, 0.25)), StrokeKind::Inside);
                }
                let mut order: Vec<&crate::model::Piece> = self.pieces.iter().collect();
                order.sort_by_key(|q| q.z);
                for q in order {
                    let cs = crate::canvas::corners(q);
                    let (a, b) = cs.iter().fold((cs[0], cs[0]), |(a, b), c| (a.min(*c), b.max(*c)));
                    let r = Rect::from_min_max(map(a), map(b));
                    let c = if self.selection.contains(&q.id) { alpha(p.primary, 0.85) } else { alpha(p.on_surface, 0.32) };
                    painter.rect_filled(r, CornerRadius::same(1), c);
                }
                let v = Rect::from_min_max(map(view_min), map(view_max));
                painter.rect(v, CornerRadius::same(3), alpha(p.primary, 0.08), Stroke::new(1.5, p.primary), StrokeKind::Middle);

                if resp.dragged() || resp.clicked() {
                    if let Some(at) = resp.interact_pointer_pos() {
                        let board = (at - offset) / scale;
                        self.flight = None;
                        self.zoom_goal = None;
                        self.view = board - self.canvas.size() / (2.0 * self.zoom);
                    }
                }
                if resp.drag_stopped() || resp.clicked() {
                    self.save_view();
                }
                resp.on_hover_cursor(CursorIcon::Crosshair);
            });
        });
    }

    // ── bottom centre: what to do with the selection ─────────────────────

    fn selection_bar(&mut self, ctx: &egui::Context) {
        let p = self.theme.p;
        let n = self.selection.len();
        let lift = if self.canvas.width() < 1040.0 { BAR_H + 8.0 } else { 0.0 };
        let x_shift = if self.prefs.library && self.canvas.width() > 1100.0 { (LIBRARY_WIDTH + EDGE) / 2.0 } else { 0.0 };
        let all_sharp = self.pieces.iter().filter(|q| self.selection.contains(&q.id)).all(|q| q.sharp);
        Area::new(Id::new("selection-bar"))
            .anchor(Align2::CENTER_BOTTOM, [x_shift, -EDGE - lift])
            .order(Order::Foreground)
            .show(ctx, |ui| {
                surface(&p).show(ui, |ui| {
                    ui.horizontal(|ui| {
                        ui.add_space(8.0);
                        ui.label(RichText::new(if n == 1 { "1 picture".to_string() } else { format!("{n} pictures") }).color(p.on_surface).size(13.0));
                        ui.add_space(4.0);
                        vsep(ui, &p);
                        let r = icon_button(ui, &p, icon::FLIP_HORIZONTAL, false);
                        if tip(r, &p, "Flip horizontally", &["H"]).clicked() {
                            self.edit_selection(|q| q.hflip = !q.hflip);
                        }
                        let r = icon_button(ui, &p, icon::FLIP_VERTICAL, false);
                        if tip(r, &p, "Flip vertically", &["V"]).clicked() {
                            self.edit_selection(|q| q.vflip = !q.vflip);
                        }
                        let r = icon_button(ui, &p, icon::ARROW_CLOCKWISE, false);
                        if tip(r, &p, "Turn 90°", &[]).clicked() {
                            self.edit_selection(|q| q.angle = (q.angle + 90.0).rem_euclid(360.0));
                        }
                        let r = icon_button(ui, &p, icon::ANGLE, false);
                        if tip(r, &p, "Straighten", &[]).clicked() {
                            self.edit_selection(|q| q.angle = 0.0);
                        }
                        vsep(ui, &p);
                        let r = icon_button(ui, &p, icon::STACK, false);
                        if tip(r, &p, "Bring to front", &["]"]).clicked() {
                            self.bring_to_front();
                        }
                        let r = icon_button(ui, &p, icon::SQUARE_HALF, all_sharp);
                        if tip(r, &p, "Hard pixels", &[]).clicked() {
                            let to = !all_sharp;
                            self.edit_selection(move |q| q.sharp = to);
                        }
                        let r = icon_button(ui, &p, icon::BOUNDING_BOX, false);
                        if tip(r, &p, "Group", &["Ctrl", "G"]).clicked() {
                            self.group_selection();
                        }
                        if n > 1 {
                            let r = icon_button(ui, &p, icon::SQUARES_FOUR, false);
                            if tip(r, &p, "Tidy into a grid", &["Ctrl", "Shift", "A"]).clicked() {
                                self.arrange(crate::Arrange::Grid);
                            }
                        }
                        let r = icon_button(ui, &p, icon::COPY, false);
                        if tip(r, &p, "Copy picture", &["Ctrl", "C"]).clicked() {
                            self.copy();
                        }
                        vsep(ui, &p);
                        let r = widgets::icon_button(ui, &p, icon::TRASH, false);
                        if r.hovered() {
                            ui.painter().rect_filled(r.rect, CornerRadius::same(9), alpha(p.error, 0.12));
                            ui.painter().text(r.rect.center(), Align2::CENTER_CENTER, icon::TRASH, FontId::proportional(17.0), p.error);
                        }
                        if tip(r, &p, "Remove from board", &["Del"]).clicked() {
                            self.remove_selection();
                        }
                    });
                });
            });
    }

    // ── the library ──────────────────────────────────────────────────────

    fn library_panel(&mut self, ctx: &egui::Context) {
        let p = self.theme.p;
        let screen = ctx.screen_rect();
        let top = EDGE + BAR_H + 8.0;
        let height = (screen.height() - top - EDGE).max(160.0);
        let now = ctx.input(|i| i.time);
        let mut place: Option<Record> = None;
        let mut carry: Option<Record> = None;
        let mut close = false;
        let mut want_more = false;

        let shown = Area::new(Id::new("library")).fixed_pos(Pos2::new(EDGE, top)).order(Order::Foreground).show(ctx, |ui| {
            surface(&p).inner_margin(egui::Margin::same(10)).show(ui, |ui| {
                let width = LIBRARY_WIDTH - 20.0;
                ui.set_width(width);
                ui.set_height(height - 20.0);

                ui.horizontal(|ui| {
                    ui.add_space(4.0);
                    ui.label(RichText::new("Library").size(15.0).color(p.on_surface));
                    if self.library.count > 0 {
                        ui.label(RichText::new(group_digits(self.library.count)).size(12.0).color(p.on_surface_variant));
                    }
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        let r = widgets::icon_button_sized(ui, &p, icon::X, false, 28.0);
                        if tip(r, &p, "Close", &["Tab"]).clicked() {
                            close = true;
                        }
                    });
                });
                ui.add_space(4.0);

                let mut leave_similar = false;
                if let Some((_, label)) = self.library.similar.clone() {
                    // In "looks like" mode the search box gives way to what is
                    // being matched, with the way back out beside it.
                    egui::Frame::new()
                        .fill(p.primary_container)
                        .corner_radius(CornerRadius::same(10))
                        .inner_margin(egui::Margin::symmetric(10, 7))
                        .show(ui, |ui| {
                            ui.horizontal(|ui| {
                                ui.label(RichText::new(icon::APPROXIMATE_EQUALS).size(16.0).color(p.on_primary_container));
                                let short: String = label.chars().take(26).collect();
                                let short = if label.chars().count() > 26 { format!("{short}…") } else { short };
                                ui.label(RichText::new(format!("Looks like {short}")).color(p.on_primary_container));
                                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                                    let r = widgets::icon_button_sized(ui, &p, icon::X, false, 22.0);
                                    if tip(r, &p, "Back to search", &[]).clicked() {
                                        leave_similar = true;
                                    }
                                });
                            });
                        });
                    ui.add_space(6.0);
                } else {
                    // The search field: quarry's own query language.
                    let focused = ui.memory(|m| m.has_focus(Id::new("library-search")));
                    egui::Frame::new()
                        .fill(p.surface_high)
                        .stroke(Stroke::new(1.0, if focused { alpha(p.primary, 0.9) } else { alpha(p.outline_variant, 0.5) }))
                        .corner_radius(CornerRadius::same(10))
                        .inner_margin(egui::Margin::symmetric(10, 7))
                        .show(ui, |ui| {
                            ui.horizontal(|ui| {
                                ui.label(RichText::new(icon::MAGNIFYING_GLASS).size(16.0).color(p.on_surface_variant));
                                let edit = egui::TextEdit::singleline(&mut self.library.text)
                                    .id(Id::new("library-search"))
                                    .frame(false)
                                    .hint_text(RichText::new("Search quarry").color(alpha(p.on_surface_variant, 0.6)))
                                    .font(FontId::proportional(14.0))
                                    .desired_width(ui.available_width() - 26.0)
                                    .show(ui);
                                if edit.response.changed() {
                                    self.library.edited(now);
                                }
                                if !self.library.text.is_empty() {
                                    let r = widgets::icon_button_sized(ui, &p, icon::X, false, 22.0);
                                    if r.clicked() {
                                        self.library.text.clear();
                                        self.library.edited(now - 1.0);
                                    }
                                }
                            });
                        });
                    ui.add_space(2.0);
                    ui.horizontal_wrapped(|ui| {
                        ui.spacing_mut().item_spacing.x = 4.0;
                        for chip in ["kind:photo", "sort:new", "used:true"] {
                            let active = self.library.text.split_whitespace().any(|t| t == chip);
                            let g = ui.painter().layout_no_wrap(chip.to_string(), FontId::proportional(11.5), if active { p.on_primary_container } else { p.on_surface_variant });
                            let (r, resp) = ui.allocate_exact_size(g.size() + Vec2::new(14.0, 8.0), Sense::click());
                            let fill = if active { p.primary_container } else if resp.hovered() { alpha(p.on_surface, 0.08) } else { Color32::TRANSPARENT };
                            ui.painter().rect(r, CornerRadius::same(8), fill, Stroke::new(1.0, alpha(p.outline_variant, if active { 0.0 } else { 0.7 })), StrokeKind::Inside);
                            ui.painter().galley(r.center() - g.size() / 2.0, g, p.on_surface_variant);
                            if resp.on_hover_cursor(CursorIcon::PointingHand).clicked() {
                                let mut words: Vec<&str> = self.library.text.split_whitespace().filter(|t| *t != chip).collect();
                                if !active {
                                    words.push(chip);
                                }
                                self.library.text = words.join(" ");
                                self.library.edited(now - 1.0);
                            }
                        }
                    });
                    ui.add_space(6.0);
                }
                if leave_similar {
                    self.library.clear_similar();
                }

                if let Some(err) = &self.library.error {
                    ui.horizontal_wrapped(|ui| {
                        ui.label(RichText::new(icon::WARNING_CIRCLE).color(p.error));
                        ui.label(RichText::new(err).color(p.on_surface_variant).size(12.5));
                    });
                } else if !self.library.loading && self.library.results.is_empty() && self.client.is_some() {
                    ui.add_space(30.0);
                    ui.vertical_centered(|ui| {
                        ui.label(RichText::new(icon::IMAGES).size(30.0).color(alpha(p.on_surface_variant, 0.5)));
                        ui.label(RichText::new(if self.library.similar.is_some() { "Nothing looks like it yet" } else if self.library.text.trim().is_empty() { "The catalogue is empty" } else { "Nothing matches" }).color(p.on_surface_variant));
                    });
                }

                let cols = 3usize;
                let gap = 6.0;
                let tile = ((width - gap * (cols as f32 - 1.0)) / cols as f32).floor();
                let results = self.library.results.clone();
                let on_board: std::collections::HashSet<&str> = self.pieces.iter().map(|q| q.id.as_str()).collect();
                let on_board: std::collections::HashSet<String> = on_board.into_iter().map(String::from).collect();
                let out = egui::ScrollArea::vertical().auto_shrink([false, false]).show(ui, |ui| {
                    ui.spacing_mut().item_spacing = Vec2::splat(gap);
                    for row in results.chunks(cols) {
                        ui.horizontal(|ui| {
                            for rec in row {
                                let (rect, resp) = ui.allocate_exact_size(Vec2::splat(tile), Sense::click_and_drag());
                                if !ui.is_rect_visible(rect) {
                                    continue;
                                }
                                let ppp = ui.ctx().pixels_per_point();
                                let tex = self.textures.get(ui.ctx(), &rec.id, crate::textures::step_for(tile * ppp * 1.4), false);
                                match tex {
                                    Some(t) => {
                                        egui::Image::from_texture(egui::load::SizedTexture::from_handle(&t))
                                            .uv(cover_uv(t.size()))
                                            .corner_radius(CornerRadius::same(8))
                                            .paint_at(ui, rect);
                                    }
                                    None => {
                                        ui.painter().rect_filled(rect, CornerRadius::same(8), alpha(p.on_surface, 0.05));
                                    }
                                }
                                if on_board.contains(&rec.id) {
                                    let c = rect.right_top() + Vec2::new(-12.0, 12.0);
                                    ui.painter().circle_filled(c, 8.0, p.primary);
                                    ui.painter().text(c, Align2::CENTER_CENTER, icon::CHECK, FontId::proportional(11.0), p.on_primary);
                                }
                                if resp.hovered() {
                                    ui.painter().rect_stroke(rect, CornerRadius::same(8), Stroke::new(2.0, p.primary), StrokeKind::Inside);
                                }
                                if resp.drag_started() {
                                    carry = Some(rec.clone());
                                }
                                if resp.clicked() {
                                    place = Some(rec.clone());
                                }
                                let title = if rec.title.is_empty() { rec.id.clone() } else { rec.title.clone() };
                                let dims = if rec.w > 0 { format!("{} × {}", rec.w, rec.h) } else { String::new() };
                                resp.on_hover_cursor(CursorIcon::PointingHand).on_hover_ui(|ui| {
                                    ui.set_max_width(260.0);
                                    ui.label(RichText::new(title).color(p.on_surface));
                                    if !dims.is_empty() {
                                        ui.label(RichText::new(dims).size(11.5).color(p.on_surface_variant));
                                    }
                                    ui.label(RichText::new("Click to add · drag onto the board").size(11.5).color(alpha(p.on_surface_variant, 0.7)));
                                });
                            }
                        });
                    }
                    if self.library.loading {
                        ui.add_space(8.0);
                        ui.vertical_centered(|ui| ui.add(egui::Spinner::new().size(18.0).color(p.primary)));
                    }
                });
                let bottom = out.state.offset.y + out.inner_rect.height();
                if bottom > out.content_size.y - tile * 2.0 {
                    want_more = true;
                }
            });
        });
        self.anchors.insert("library", shown.response.rect);

        if close {
            self.prefs.library = false;
        }
        if want_more {
            self.library.more(self.client.as_ref());
        }
        if let Some(rec) = place {
            let at = self.to_board(self.free_area().center());
            self.place_record(&rec, at);
        }
        if carry.is_some() {
            self.carrying = carry;
        }
    }

    /// A picture on its way from the library to the board.
    fn carry(&mut self, ctx: &egui::Context) {
        let Some(rec) = self.carrying.clone() else { return };
        let p = self.theme.p;
        let (pos, released) = ctx.input(|i| (i.pointer.hover_pos(), i.pointer.any_released()));
        if let Some(at) = pos {
            ctx.set_cursor_icon(CursorIcon::Grabbing);
            let over_panel = self.anchors.get("library").is_some_and(|r| r.contains(at));
            let ratio = if rec.w > 0 { rec.h as f32 / rec.w as f32 } else { 0.75 };
            let w = 150.0;
            Area::new(Id::new("carry")).fixed_pos(at - Vec2::new(w / 2.0, w * ratio / 2.0)).order(Order::Tooltip).interactable(false).show(ctx, |ui| {
                let rect = Rect::from_min_size(ui.max_rect().min, Vec2::new(w, w * ratio));
                ui.allocate_rect(rect, Sense::hover());
                ui.painter().rect_filled(rect.translate(Vec2::new(0.0, 6.0)).expand(2.0), CornerRadius::same(10), Color32::from_black_alpha(60));
                match self.textures.get(ctx, &rec.id, 320, false) {
                    Some(t) => {
                        egui::Image::from_texture(egui::load::SizedTexture::from_handle(&t))
                            .corner_radius(CornerRadius::same(8))
                            .tint(Color32::from_white_alpha(if over_panel { 150 } else { 235 }))
                            .paint_at(ui, rect);
                    }
                    None => {
                        ui.painter().rect_filled(rect, CornerRadius::same(8), alpha(p.surface_highest, 0.9));
                    }
                }
                ui.painter().rect_stroke(rect, CornerRadius::same(8), Stroke::new(2.0, p.primary), StrokeKind::Outside);
            });
            if released {
                self.carrying = None;
                if !over_panel && self.canvas.contains(at) {
                    let board = self.to_board(at);
                    self.place_record(&rec, board);
                }
            }
        } else if released {
            self.carrying = None;
        }
    }

    // ── popups under the bar buttons ─────────────────────────────────────

    fn popups(&mut self, ctx: &egui::Context) {
        let p = self.theme.p;
        let now = ctx.input(|i| i.time);

        if self.switcher_open {
            let anchor = self.anchors.get("switcher").copied().unwrap_or(Rect::NOTHING);
            let boards: Vec<(String, i64)> = self.boards.iter().map(|b| (b.name.clone(), b.items)).collect();
            let mut pick: Option<String> = None;
            let mut new = false;
            let shown = Area::new(Id::new("switcher")).fixed_pos(anchor.left_bottom() + Vec2::new(-6.0, 12.0)).order(Order::Foreground).show(ctx, |ui| {
                surface(&p).show(ui, |ui| {
                    ui.set_width(270.0);
                    caption(ui, &p, "BOARDS");
                    egui::ScrollArea::vertical().max_height(420.0).show(ui, |ui| {
                        for (name, items) in &boards {
                            let active = *name == self.open;
                            // The open board is drawn from what is on screen
                            // now; the others from what the daemon last said.
                            let ids: Vec<String> = if active {
                                let mut mine: Vec<&crate::model::Piece> = self.pieces.iter().collect();
                                mine.sort_by_key(|q| std::cmp::Reverse(q.z));
                                mine.into_iter().take(4).map(|q| q.id.clone()).collect()
                            } else {
                                self.previews.want(self.client.as_ref(), name, *items);
                                self.previews.get(name).to_vec()
                            };
                            let count = if active { self.pieces.len() as i64 } else { *items };

                            let (rect, resp) = ui.allocate_exact_size(Vec2::new(ui.available_width().max(260.0), 52.0), Sense::click());
                            let hovered = resp.hovered();
                            if hovered || active {
                                ui.painter().rect_filled(rect, CornerRadius::same(10), alpha(p.on_surface, if hovered { 0.08 } else { 0.045 }));
                            }
                            let tile = Rect::from_min_size(rect.left_top() + Vec2::new(6.0, 6.0), Vec2::splat(40.0));
                            ui.painter().rect_filled(tile, CornerRadius::same(8), alpha(p.on_surface, 0.06));
                            let cell = 19.0;
                            for (k, id) in ids.iter().enumerate() {
                                let at = Vec2::new((k % 2) as f32, (k / 2) as f32) * (cell + 2.0);
                                let r = Rect::from_min_size(tile.min + at, Vec2::splat(cell));
                                if let Some(t) = self.textures.get(ui.ctx(), id, 160, false) {
                                    egui::Image::from_texture(egui::load::SizedTexture::from_handle(&t))
                                        .uv(cover_uv(t.size()))
                                        .corner_radius(CornerRadius::same(4))
                                        .paint_at(ui, r);
                                }
                            }
                            if ids.is_empty() {
                                ui.painter().text(tile.center(), Align2::CENTER_CENTER, icon::SQUARES_FOUR, FontId::proportional(18.0), alpha(p.on_surface_variant, 0.6));
                            }
                            let text_x = tile.right() + 12.0;
                            let right = rect.right() - if active { 34.0 } else { 10.0 };
                            let name_g = ui.painter().layout_no_wrap(name.clone(), FontId::proportional(13.5), p.on_surface);
                            let clip = Rect::from_min_max(Pos2::new(text_x, rect.top()), Pos2::new(right, rect.bottom()));
                            ui.painter().with_clip_rect(clip).galley(Pos2::new(text_x, rect.center().y - name_g.size().y - 1.0), name_g, p.on_surface);
                            ui.painter().text(
                                Pos2::new(text_x, rect.center().y + 2.0),
                                Align2::LEFT_TOP,
                                if count == 1 { "1 picture".to_string() } else { format!("{count} pictures") },
                                FontId::proportional(11.5),
                                p.on_surface_variant,
                            );
                            if active {
                                ui.painter().text(rect.right_center() - Vec2::new(18.0, 0.0), Align2::CENTER_CENTER, icon::CHECK, FontId::proportional(16.0), p.primary);
                            }
                            if resp.on_hover_cursor(CursorIcon::PointingHand).clicked() {
                                pick = Some(name.clone());
                            }
                        }
                    });
                    hsep(ui, &p);
                    if menu_row(ui, &p, Row::new(icon::PLUS, "New board…").keys("Ctrl N")).clicked() {
                        new = true;
                    }
                });
            });
            if let Some(name) = pick {
                self.open_board(&name);
                self.switcher_open = false;
            }
            if new {
                self.dialog = Dialog::NewBoard(String::new());
                self.dialog_focus = true;
                self.switcher_open = false;
            }
            if pressed_outside(ctx, &[shown.response.rect, anchor]) {
                self.switcher_open = false;
            }
        }

        if self.fade_open {
            let anchor = self.anchors.get("fade").copied().unwrap_or(Rect::NOTHING);
            let shown = Area::new(Id::new("fade")).pivot(Align2::RIGHT_TOP).fixed_pos(anchor.right_bottom() + Vec2::new(46.0, 12.0)).order(Order::Foreground).show(ctx, |ui| {
                surface(&p).inner_margin(egui::Margin::same(12)).show(ui, |ui| {
                    ui.set_width(290.0);
                    ui.label(RichText::new("Ground").size(15.0).color(p.on_surface));
                    ui.add_space(4.0);
                    ui.horizontal(|ui| {
                        let theme_ground = p.background;
                        let tones = [
                            (theme_ground, "Theme"),
                            (Color32::from_rgb(8, 8, 9), "Black"),
                            (Color32::from_rgb(58, 58, 60), "Grey"),
                            (Color32::from_rgb(240, 239, 236), "White"),
                        ];
                        for (k, (colour, name)) in tones.into_iter().enumerate() {
                            let (r, resp) = ui.allocate_exact_size(Vec2::new(62.0, 52.0), Sense::click());
                            let on = self.prefs.tone as usize == k;
                            let dot = Pos2::new(r.center().x, r.top() + 15.0);
                            if on {
                                ui.painter().circle_stroke(dot, 15.0, Stroke::new(2.0, p.primary));
                            } else if resp.hovered() {
                                ui.painter().circle_stroke(dot, 15.0, Stroke::new(1.0, alpha(p.on_surface, 0.4)));
                            }
                            ui.painter().circle(dot, 11.5, colour, Stroke::new(1.0, alpha(p.outline_variant, 0.9)));
                            ui.painter().text(
                                Pos2::new(r.center().x, r.bottom() - 8.0),
                                Align2::CENTER_CENTER,
                                name,
                                FontId::proportional(11.5),
                                if on { p.on_surface } else { p.on_surface_variant },
                            );
                            if resp.on_hover_cursor(CursorIcon::PointingHand).clicked() {
                                self.prefs.tone = k as u8;
                            }
                        }
                    });
                    ui.add_space(10.0);
                    hsep(ui, &p);
                    ui.add_space(4.0);
                    ui.label(RichText::new("Transparency").size(15.0).color(p.on_surface));
                    ui.label(
                        RichText::new("A clear board with solid pictures floats your reference over whatever you are working in.")
                            .size(12.0)
                            .color(p.on_surface_variant),
                    );
                    ui.add_space(8.0);
                    widgets::percent_slider(ui, &p, icon::SQUARE, "Board", &mut self.prefs.ground, 0.0);
                    ui.add_space(4.0);
                    // Never fully invisible: a board of pictures you cannot see
                    // is indistinguishable from an empty one.
                    widgets::percent_slider(ui, &p, icon::IMAGE, "Pictures", &mut self.prefs.picture_opacity, 0.1);
                    // Hyprland blurs whatever shows through a see-through
                    // window, and no client can opt out — only a window rule
                    // can. Say so where the slider is, instead of letting a
                    // blurred desktop look like a bug in the board.
                    if self.prefs.ground < 0.999 && std::env::var_os("HYPRLAND_INSTANCE_SIGNATURE").is_some() {
                        ui.add_space(6.0);
                        ui.horizontal_wrapped(|ui| {
                            ui.label(RichText::new(icon::INFO).size(13.0).color(p.on_surface_variant));
                            ui.label(
                                RichText::new("Hyprland blurs what shows through. Board at 100% (Solid) looks like RIA; for see-through without blur, add a no_blur window rule for quarry-board.")
                                    .size(11.5)
                                    .color(p.on_surface_variant),
                            );
                        });
                    }
                    ui.add_space(8.0);
                    ui.horizontal(|ui| {
                        for (label, g, pic) in [("Solid", 1.0, 1.0), ("Float", 0.0, 1.0), ("Trace", 0.0, 0.45)] {
                            let on = (self.prefs.ground - g).abs() < 0.01 && (self.prefs.picture_opacity - pic).abs() < 0.01;
                            if pill(ui, &p, "", label, if on { Kind::Tonal } else { Kind::Text }).clicked() {
                                self.prefs.ground = g;
                                self.prefs.picture_opacity = pic;
                            }
                        }
                    });
                });
            });
            if pressed_outside(ctx, &[shown.response.rect, anchor]) {
                self.fade_open = false;
            }
        }

        if self.more_open {
            let anchor = self.anchors.get("more").copied().unwrap_or(Rect::NOTHING);
            let has_board = !self.open.is_empty();
            let mut act: Option<&str> = None;
            let shown = Area::new(Id::new("more")).pivot(Align2::RIGHT_TOP).fixed_pos(anchor.right_bottom() + Vec2::new(6.0, 12.0)).order(Order::Foreground).show(ctx, |ui| {
                surface(&p).show(ui, |ui| {
                    ui.set_width(250.0);
                    caption(ui, &p, "BOARD");
                    if menu_row(ui, &p, Row::new(icon::PLUS, "New board…").keys("Ctrl N").enabled(self.client.is_some())).clicked() {
                        act = Some("new");
                    }
                    if menu_row(ui, &p, Row::new(icon::PENCIL_SIMPLE, "Rename board…").keys("F2").enabled(has_board)).clicked() {
                        act = Some("rename");
                    }
                    if menu_row(ui, &p, Row::new(icon::TRASH, "Delete board…").danger().enabled(has_board)).clicked() {
                        act = Some("delete");
                    }
                    hsep(ui, &p);
                    caption(ui, &p, "VIEW");
                    if menu_row(ui, &p, Row::new(icon::SIDEBAR_SIMPLE, "Library").keys("Tab").checked(self.prefs.library)).clicked() {
                        act = Some("library");
                    }
                    if menu_row(ui, &p, Row::new(icon::MAP_TRIFOLD, "Overview").keys("M").checked(self.prefs.minimap)).clicked() {
                        act = Some("minimap");
                    }
                    if menu_row(ui, &p, Row::new(icon::EXPORT, "Export view as PNG").keys("Ctrl E").enabled(has_board)).clicked() {
                        act = Some("export");
                    }
                    if menu_row(ui, &p, Row::new(icon::EYE_SLASH, "Hide interface").keys("\\")).clicked() {
                        act = Some("hide");
                    }
                    hsep(ui, &p);
                    if menu_row(ui, &p, Row::new(icon::ARROW_U_UP_LEFT, "Undo").keys("Ctrl Z").enabled(!self.undo.is_empty())).clicked() {
                        act = Some("undo");
                    }
                    if menu_row(ui, &p, Row::new(icon::ARROW_U_UP_RIGHT, "Redo").keys("Ctrl Shift Z").enabled(!self.redo.is_empty())).clicked() {
                        act = Some("redo");
                    }
                });
            });
            match act {
                Some("new") => {
                    self.dialog = Dialog::NewBoard(String::new());
                    self.dialog_focus = true;
                }
                Some("rename") => {
                    self.dialog = Dialog::RenameBoard(self.open.clone());
                    self.dialog_focus = true;
                }
                Some("delete") => self.dialog = Dialog::DeleteBoard,
                Some("library") => self.prefs.library = !self.prefs.library,
                Some("minimap") => self.prefs.minimap = !self.prefs.minimap,
                Some("hide") => {
                    self.chrome_hidden = true;
                    self.toast("Interface hidden · press \\ to bring it back", ToastKind::Info);
                }
                Some("undo") => self.undo(),
                Some("redo") => self.redo(),
                Some("export") => self.export_view(),
                _ => {}
            }
            if act.is_some() || pressed_outside(ctx, &[shown.response.rect, anchor]) {
                self.more_open = false;
            }
        }

        if self.zoom_open {
            let anchor = self.anchors.get("zoom").copied().unwrap_or(Rect::NOTHING);
            let mut to: Option<f32> = None;
            let mut fit = 0;
            let shown = Area::new(Id::new("zoom-menu")).pivot(Align2::CENTER_BOTTOM).fixed_pos(anchor.center_top() - Vec2::new(0.0, 14.0)).order(Order::Foreground).show(ctx, |ui| {
                surface(&p).show(ui, |ui| {
                    ui.set_width(220.0);
                    for z in [0.25f32, 0.5, 1.0, 2.0, 4.0] {
                        let label = format!("{:.0}%", z * 100.0);
                        let keys = if z == 1.0 { "Ctrl 0" } else { "" };
                        if menu_row(ui, &p, Row::new(icon::MAGNIFYING_GLASS, &label).keys(keys).checked((self.zoom - z).abs() < 0.005)).clicked() {
                            to = Some(z);
                        }
                    }
                    hsep(ui, &p);
                    if menu_row(ui, &p, Row::new(icon::CORNERS_OUT, "Fit everything").keys("F")).clicked() {
                        fit = 1;
                    }
                    if menu_row(ui, &p, Row::new(icon::FRAME_CORNERS, "Fit selection").keys("F").enabled(!self.selection.is_empty())).clicked() {
                        fit = 2;
                    }
                });
            });
            if let Some(z) = to {
                let c = self.free_area().center();
                let board = self.to_board(c);
                let offset = c - self.canvas.min;
                self.fly_to(board - offset / z, z, now);
            }
            match fit {
                1 => self.fit_all(now),
                2 => self.fit_selection(now),
                _ => {}
            }
            if to.is_some() || fit > 0 || pressed_outside(ctx, &[shown.response.rect, anchor]) {
                self.zoom_open = false;
            }
        }
    }

    // ── right-click menus ────────────────────────────────────────────────

    fn context_menu(&mut self, ctx: &egui::Context) {
        if self.menu == Menu::None {
            return;
        }
        let p = self.theme.p;
        let now = ctx.input(|i| i.time);
        let menu = self.menu.clone();
        let mut act: Option<&'static str> = None;
        let n = self.selection.len();
        let all_sharp = self.pieces.iter().filter(|q| self.selection.contains(&q.id)).all(|q| q.sharp);

        let shown = Area::new(Id::new("context-menu")).fixed_pos(self.menu_at).constrain(true).order(Order::Foreground).show(ctx, |ui| {
            surface(&p).show(ui, |ui| {
                ui.set_width(250.0);
                match &menu {
                    Menu::Piece => {
                        let one = if n == 1 { self.selection.first().and_then(|id| self.records.get(id)).cloned() } else { None };
                        match one {
                            // One picture: say which, so "remove" is never a guess.
                            Some(rec) => {
                                ui.add_space(4.0);
                                let title = if rec.title.is_empty() { rec.id.clone() } else { rec.title.clone() };
                                ui.horizontal(|ui| {
                                    ui.add_space(8.0);
                                    ui.set_max_width(234.0);
                                    ui.add(egui::Label::new(RichText::new(title).size(12.5).color(p.on_surface)).truncate());
                                });
                                if rec.w > 0 {
                                    ui.horizontal(|ui| {
                                        ui.add_space(8.0);
                                        ui.label(RichText::new(format!("{} × {} px", rec.w, rec.h)).size(11.5).color(alpha(p.on_surface_variant, 0.8)));
                                    });
                                }
                                hsep(ui, &p);
                            }
                            None => caption(ui, &p, &if n == 1 { "PICTURE".to_string() } else { format!("{n} PICTURES") }),
                        }
                        let rows: [(&str, Row, &'static str); 4] = [
                            ("", Row::new(icon::FLIP_HORIZONTAL, "Flip horizontally").keys("H"), "hflip"),
                            ("", Row::new(icon::FLIP_VERTICAL, "Flip vertically").keys("V"), "vflip"),
                            ("", Row::new(icon::ARROW_CLOCKWISE, "Turn 90°"), "turn"),
                            ("", Row::new(icon::ANGLE, "Straighten"), "straight"),
                        ];
                        for (_, row, id) in rows {
                            if menu_row(ui, &p, row).clicked() {
                                act = Some(id);
                            }
                        }
                        hsep(ui, &p);
                        if menu_row(ui, &p, Row::new(icon::STACK, "Bring to front").keys("]")).clicked() {
                            act = Some("front");
                        }
                        if menu_row(ui, &p, Row::new(icon::STACK_SIMPLE, "Send to back").keys("[")).clicked() {
                            act = Some("back");
                        }
                        if menu_row(ui, &p, Row::new(icon::FRAME_CORNERS, "Zoom to fit").keys("F")).clicked() {
                            act = Some("fit");
                        }
                        if menu_row(ui, &p, Row::new(icon::SQUARE_HALF, "Hard pixels").checked(all_sharp)).clicked() {
                            act = Some("sharp");
                        }
                        hsep(ui, &p);
                        // Only what applies: arranging needs several pictures,
                        // and copy, open and similar need exactly one. A menu
                        // of greyed-out rows is taller than the window.
                        if n > 1 {
                            caption(ui, &p, "ARRANGE");
                            if menu_row(ui, &p, Row::new(icon::SQUARES_FOUR, "Tidy into a grid").keys("Ctrl Shift A")).clicked() {
                                act = Some("tidy");
                            }
                            if menu_row(ui, &p, Row::new(icon::COLUMNS, "Line up in a row")).clicked() {
                                act = Some("row");
                            }
                            if menu_row(ui, &p, Row::new(icon::ARROWS_OUT_LINE_VERTICAL, "Same height")).clicked() {
                                act = Some("height");
                            }
                            hsep(ui, &p);
                        }
                        if menu_row(ui, &p, Row::new(icon::BOUNDING_BOX, "Group").keys("Ctrl G")).clicked() {
                            act = Some("group");
                        }
                        if n == 1 {
                            if menu_row(ui, &p, Row::new(icon::COPY, "Copy picture").keys("Ctrl C")).clicked() {
                                act = Some("copy");
                            }
                            if menu_row(ui, &p, Row::new(icon::ARROW_SQUARE_OUT, "Open original")).clicked() {
                                act = Some("open");
                            }
                            if menu_row(ui, &p, Row::new(icon::APPROXIMATE_EQUALS, "Find similar")).clicked() {
                                act = Some("similar");
                            }
                        }
                        hsep(ui, &p);
                        if menu_row(ui, &p, Row::new(icon::TRASH, "Remove from board").keys("Del").danger()).clicked() {
                            act = Some("remove");
                        }
                    }
                    Menu::Container(id) => {
                        let label = self.containers.iter().find(|b| b.id == *id).map(|b| b.label.clone()).unwrap_or_default();
                        caption(ui, &p, &if label.is_empty() { "GROUP".to_string() } else { label.to_uppercase() });
                        if menu_row(ui, &p, Row::new(icon::PENCIL_SIMPLE, "Rename…")).clicked() {
                            act = Some("g-rename");
                        }
                        if menu_row(ui, &p, Row::new(icon::SELECTION_ALL, "Select pictures inside")).clicked() {
                            act = Some("g-select");
                        }
                        if menu_row(ui, &p, Row::new(icon::FRAME_CORNERS, "Zoom to group")).clicked() {
                            act = Some("g-fit");
                        }
                        hsep(ui, &p);
                        if menu_row(ui, &p, Row::new(icon::BOUNDING_BOX, "Ungroup — pictures stay")).clicked() {
                            act = Some("g-ungroup");
                        }
                    }
                    Menu::Canvas => {
                        caption(ui, &p, "BOARD");
                        if menu_row(ui, &p, Row::new(icon::CLIPBOARD, "Paste picture").keys("Ctrl V").enabled(!self.open.is_empty())).clicked() {
                            act = Some("paste");
                        }
                        if menu_row(ui, &p, Row::new(icon::SIDEBAR_SIMPLE, "Add from library").keys("Tab")).clicked() {
                            act = Some("library");
                        }
                        hsep(ui, &p);
                        if menu_row(ui, &p, Row::new(icon::SELECTION_ALL, "Select all").keys("Ctrl A").enabled(!self.pieces.is_empty())).clicked() {
                            act = Some("all");
                        }
                        if menu_row(ui, &p, Row::new(icon::CORNERS_OUT, "Fit everything").keys("F")).clicked() {
                            act = Some("fit-all");
                        }
                        if menu_row(ui, &p, Row::new(icon::CROSSHAIR, "Go to origin").keys("Space")).clicked() {
                            act = Some("origin");
                        }
                        hsep(ui, &p);
                        if menu_row(ui, &p, Row::new(icon::EYEDROPPER, "Pick a colour").keys("I").enabled(!self.pieces.is_empty())).clicked() {
                            act = Some("pick");
                        }
                        if menu_row(ui, &p, Row::new(icon::EXPORT, "Export view as PNG").keys("Ctrl E").enabled(!self.open.is_empty())).clicked() {
                            act = Some("export");
                        }
                        hsep(ui, &p);
                        if menu_row(ui, &p, Row::new(icon::DOTS_NINE, "Grid").keys("G").checked(self.prefs.grid)).clicked() {
                            act = Some("grid");
                        }
                        if menu_row(ui, &p, Row::new(icon::MAP_TRIFOLD, "Overview").keys("M").checked(self.prefs.minimap)).clicked() {
                            act = Some("minimap");
                        }
                        hsep(ui, &p);
                        if menu_row(ui, &p, Row::new(icon::ARROW_U_UP_LEFT, "Undo").keys("Ctrl Z").enabled(!self.undo.is_empty())).clicked() {
                            act = Some("undo");
                        }
                        if menu_row(ui, &p, Row::new(icon::ARROW_U_UP_RIGHT, "Redo").keys("Ctrl Shift Z").enabled(!self.redo.is_empty())).clicked() {
                            act = Some("redo");
                        }
                    }
                    Menu::None => {}
                }
            });
        });

        match act {
            Some("hflip") => self.edit_selection(|q| q.hflip = !q.hflip),
            Some("vflip") => self.edit_selection(|q| q.vflip = !q.vflip),
            Some("turn") => self.edit_selection(|q| q.angle = (q.angle + 90.0).rem_euclid(360.0)),
            Some("straight") => self.edit_selection(|q| q.angle = 0.0),
            Some("front") => self.bring_to_front(),
            Some("back") => self.send_to_back(),
            Some("fit") => self.fit_selection(now),
            Some("sharp") => {
                let to = !all_sharp;
                self.edit_selection(move |q| q.sharp = to);
            }
            Some("group") => self.group_selection(),
            Some("tidy") => self.arrange(crate::Arrange::Grid),
            Some("row") => self.arrange(crate::Arrange::Row),
            Some("height") => self.arrange(crate::Arrange::SameHeight),
            Some("copy") => self.copy(),
            Some("open") => self.open_original(),
            Some("similar") => {
                if let Some(id) = self.selection.first().cloned() {
                    let label = self
                        .records
                        .get(&id)
                        .map(|r| r.title.clone())
                        .filter(|t| !t.is_empty())
                        .unwrap_or_else(|| "this picture".to_string());
                    self.library.show_similar(&id, &label);
                    self.prefs.library = true;
                }
            }
            Some("remove") => self.remove_selection(),
            Some("paste") => self.paste(),
            Some("library") => self.prefs.library = true,
            Some("all") => self.selection = self.pieces.iter().map(|q| q.id.clone()).collect(),
            Some("fit-all") => self.fit_all(now),
            Some("origin") => {
                let offset = self.free_area().center() - self.canvas.min;
                self.fly_to(-offset / self.zoom, self.zoom, now);
            }
            Some("grid") => self.prefs.grid = !self.prefs.grid,
            Some("pick") => self.picking = true,
            Some("export") => self.export_view(),
            Some("minimap") => self.prefs.minimap = !self.prefs.minimap,
            Some("undo") => self.undo(),
            Some("redo") => self.redo(),
            Some(g) if g.starts_with("g-") => {
                if let Menu::Container(id) = menu {
                    let b = self.containers.iter().find(|b| b.id == id).cloned();
                    match (g, b) {
                        ("g-rename", Some(b)) => {
                            self.dialog = Dialog::RenameGroup(id, b.label.clone());
                            self.dialog_focus = true;
                        }
                        ("g-select", Some(b)) => {
                            self.selection = self
                                .pieces
                                .iter()
                                .filter(|q| {
                                    let (cx, cy) = q.centre();
                                    b.contains(cx, cy)
                                })
                                .map(|q| q.id.clone())
                                .collect();
                        }
                        ("g-fit", Some(b)) => self.frame_rect(Vec2::new(b.x, b.y), Vec2::new(b.x + b.w, b.y + b.h), now),
                        ("g-ungroup", _) => self.ungroup(id),
                        _ => {}
                    }
                }
            }
            _ => {}
        }
        let opened_now = ctx.cumulative_frame_nr() == self.menu_frame;
        if act.is_some() || (!opened_now && pressed_outside(ctx, &[shown.response.rect])) {
            self.menu = Menu::None;
        }
    }

    fn open_original(&mut self) {
        let Some(id) = self.selection.first() else { return };
        let Some(rec) = self.records.get(id) else { return };
        let target = rec.url.clone();
        if target.is_empty() {
            return;
        }
        // Asked for by a click, so opening something is what the person wants;
        // detached, so the board never waits on the viewer.
        let spawned = std::process::Command::new("xdg-open")
            .arg(&target)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
        if spawned.is_err() {
            self.toast("Could not open it — is xdg-open installed?", ToastKind::Error);
        }
    }

    // ── dialogs ──────────────────────────────────────────────────────────

    fn dialog(&mut self, ctx: &egui::Context) {
        if self.dialog == Dialog::None {
            return;
        }
        let p = self.theme.p;
        let mut d = std::mem::replace(&mut self.dialog, Dialog::None);
        let focus = std::mem::take(&mut self.dialog_focus);
        let mut close = false;
        let mut confirm = false;
        let is_help = d == Dialog::Help;

        let frame = egui::Frame::new()
            .fill(p.surface)
            .stroke(Stroke::new(1.0, alpha(p.outline_variant, 0.6)))
            .corner_radius(CornerRadius::same(20))
            .inner_margin(egui::Margin::same(22))
            .shadow(egui::Shadow { offset: [0, 16], blur: 48, spread: 0, color: Color32::from_black_alpha(120) });

        let taken: Vec<String> = self.boards.iter().map(|b| b.name.clone()).collect();
        let open = self.open.clone();
        let count = self.pieces.len();

        let modal = egui::Modal::new(Id::new("dialog")).frame(frame).backdrop_color(Color32::from_black_alpha(100)).show(ctx, |ui| {
            if is_help {
                help_sheet(ui, &p);
                ui.add_space(12.0);
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if pill(ui, &p, "", "Done", Kind::Filled).clicked() {
                        close = true;
                    }
                });
                return;
            }
            ui.set_width(380.0);
            let enter = ui.input(|i| i.key_pressed(egui::Key::Enter));

            if d == Dialog::DeleteBoard {
                dialog_head(ui, &p, icon::TRASH, &format!("Delete “{open}”?"));
                let pictures = if count == 1 { "The picture on it stays".to_string() } else { format!("The {count} pictures on it stay") };
                ui.label(RichText::new(format!("The board and its arrangement go. {pictures} in quarry.")).color(p.on_surface_variant));
                ui.add_space(18.0);
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if pill(ui, &p, "", "Delete", Kind::Danger).clicked() || enter {
                        confirm = true;
                    }
                    if pill(ui, &p, "", "Cancel", Kind::Text).clicked() {
                        close = true;
                    }
                });
                return;
            }

            let (glyph, title, body, hint, action) = match &d {
                Dialog::NewBoard(_) => (icon::SQUARES_FOUR, "New board", "Give it a name you will recognise in the switcher.", "Board name", "Create"),
                Dialog::RenameBoard(_) => (icon::PENCIL_SIMPLE, "Rename board", "quarry keeps the pictures and their arrangement.", "Board name", "Rename"),
                _ => (icon::BOUNDING_BOX, "Name this group", "Optional — a name makes a group findable at a glance.", "e.g. Lighting, Poses, Palette", "Save"),
            };
            dialog_head(ui, &p, glyph, title);
            ui.label(RichText::new(body).color(p.on_surface_variant));
            ui.add_space(14.0);

            let is_group = matches!(d, Dialog::RenameGroup(..));
            let text = match &mut d {
                Dialog::NewBoard(t) | Dialog::RenameBoard(t) | Dialog::RenameGroup(_, t) => t,
                _ => unreachable!(),
            };
            let id = Id::new("dialog-field");
            let focused = ui.memory(|m| m.has_focus(id));
            let edit = egui::Frame::new()
                .fill(p.surface_high)
                .stroke(Stroke::new(if focused { 2.0 } else { 1.0 }, if focused { p.primary } else { alpha(p.outline_variant, 0.8) }))
                .corner_radius(CornerRadius::same(12))
                .inner_margin(egui::Margin::symmetric(12, 10))
                .show(ui, |ui| {
                    ui.add(
                        egui::TextEdit::singleline(text)
                            .id(id)
                            .frame(false)
                            .font(FontId::proportional(15.0))
                            .hint_text(RichText::new(hint).color(alpha(p.on_surface_variant, 0.55)))
                            .desired_width(f32::INFINITY),
                    )
                })
                .inner;
            if focus {
                edit.request_focus();
            }
            let name = text.trim().to_string();
            let clash = !is_group && !name.is_empty() && taken.iter().any(|t| *t == name) && name != open;
            let valid = is_group || (!name.is_empty() && !clash);
            ui.add_space(4.0);
            ui.label(
                RichText::new(if clash { "A board with that name already exists." } else { " " })
                    .size(12.0)
                    .color(p.error),
            );
            ui.add_space(8.0);
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                let r = pill(ui, &p, "", action, if valid { Kind::Filled } else { Kind::Tonal });
                if valid && (r.clicked() || enter) {
                    confirm = true;
                }
                if pill(ui, &p, "", if is_group { "Skip" } else { "Cancel" }, Kind::Text).clicked() {
                    close = true;
                }
            });
        });
        if modal.should_close() {
            close = true;
        }

        if confirm {
            match &d {
                Dialog::NewBoard(t) => self.create_board(t.trim()),
                Dialog::RenameBoard(t) => self.rename_board(t.trim()),
                Dialog::RenameGroup(id, t) => self.rename_group(*id, t.trim()),
                Dialog::DeleteBoard => self.delete_board(),
                _ => {}
            }
        } else if !close {
            self.dialog = d;
        }
    }

    // ── toasts ───────────────────────────────────────────────────────────

    fn toasts(&mut self, ctx: &egui::Context) {
        if self.toasts.is_empty() {
            return;
        }
        let p = self.theme.p;
        let now = ctx.input(|i| i.time);
        for t in self.toasts.iter_mut() {
            if t.born < 0.0 {
                t.born = now;
            }
        }
        let life = |t: &crate::Toast| if t.kind == ToastKind::Error { 5.0 } else { 3.0 };
        self.toasts.retain(|t| now - t.born < life(t));
        let x = if self.prefs.library && !self.chrome_hidden { EDGE + LIBRARY_WIDTH + EDGE } else { EDGE };
        Area::new(Id::new("toasts")).anchor(Align2::LEFT_BOTTOM, [x, -EDGE]).order(Order::Tooltip).interactable(false).show(ctx, |ui| {
            ui.vertical(|ui| {
                ui.spacing_mut().item_spacing.y = 8.0;
                for t in &self.toasts {
                    let age = now - t.born;
                    let fade = ((life(t) - age) / 0.3).clamp(0.0, 1.0) as f32 * ((age / 0.12).clamp(0.0, 1.0) as f32);
                    ui.scope(|ui| {
                        ui.multiply_opacity(fade);
                        // Inverse surface, like a Material snackbar: it has to
                        // read over whatever picture is behind it.
                        egui::Frame::new()
                            .fill(mix(p.on_surface, p.surface, 0.06))
                            .corner_radius(CornerRadius::same(12))
                            .inner_margin(egui::Margin::symmetric(14, 10))
                            .shadow(egui::Shadow { offset: [0, 6], blur: 20, spread: 0, color: Color32::from_black_alpha(70) })
                            .show(ui, |ui| {
                                ui.horizontal(|ui| {
                                    let (glyph, color) = match t.kind {
                                        ToastKind::Info => (icon::INFO, p.surface_high),
                                        ToastKind::Error => (icon::WARNING_CIRCLE, mix(p.error, Color32::BLACK, 0.45)),
                                    };
                                    match t.swatch {
                                        Some(c) => {
                                            let (r, _) = ui.allocate_exact_size(Vec2::splat(18.0), Sense::hover());
                                            ui.painter().rect(r, CornerRadius::same(5), c, Stroke::new(1.0, alpha(p.surface, 0.5)), StrokeKind::Inside);
                                        }
                                        None => {
                                            ui.label(RichText::new(glyph).size(16.0).color(color));
                                        }
                                    }
                                    ui.label(RichText::new(&t.text).color(p.surface).size(13.5));
                                });
                            });
                    });
                }
            });
        });
        ctx.request_repaint_after(std::time::Duration::from_millis(50));
    }

    // ── nothing to show ──────────────────────────────────────────────────

    fn empty_state(&mut self, ctx: &egui::Context) {
        let p = self.theme.p;
        enum Why {
            Offline,
            NoBoards,
            Empty,
        }
        let why = if self.client.is_none() {
            Why::Offline
        } else if self.boards.is_empty() {
            Why::NoBoards
        } else if self.pieces.is_empty() && !self.open.is_empty() {
            Why::Empty
        } else {
            return;
        };
        let offset = if self.prefs.library { (LIBRARY_WIDTH + EDGE) / 2.0 } else { 0.0 };
        let mut act = 0;
        Area::new(Id::new("empty")).anchor(Align2::CENTER_CENTER, [offset, 0.0]).order(Order::Middle).show(ctx, |ui| {
            ui.set_max_width(380.0);
            ui.vertical_centered(|ui| {
                let (glyph, title, body) = match why {
                    Why::Offline => (icon::PLUG, "quarryd isn't running", "The board lives in quarry's catalogue. Start the daemon and reconnect."),
                    Why::NoBoards => (icon::SQUARES_FOUR, "No boards yet", "A board keeps reference arranged side by side, next to the thing you are making."),
                    Why::Empty => (icon::IMAGES, "This board is empty", "Drop pictures or folders here, paste with Ctrl V, or add them from the library."),
                };
                let (r, _) = ui.allocate_exact_size(Vec2::splat(72.0), Sense::hover());
                ui.painter().circle_filled(r.center(), 36.0, alpha(p.primary_container, 0.8));
                ui.painter().text(r.center(), Align2::CENTER_CENTER, glyph, FontId::proportional(32.0), p.on_primary_container);
                ui.add_space(14.0);
                ui.label(RichText::new(title).size(19.0).color(p.on_surface));
                ui.add_space(4.0);
                ui.label(RichText::new(body).size(13.5).color(p.on_surface_variant));
                if let Why::Offline = why {
                    if !self.connect_error.is_empty() {
                        ui.add_space(4.0);
                        ui.label(RichText::new(&self.connect_error).size(11.5).color(alpha(p.on_surface_variant, 0.6)));
                    }
                }
                ui.add_space(16.0);
                ui.horizontal(|ui| {
                    // Centre a row of buttons by measuring it first.
                    let width = match why {
                        Why::Offline => 120.0,
                        Why::NoBoards => 140.0,
                        Why::Empty => 290.0,
                    };
                    ui.add_space(((ui.available_width() - width) / 2.0).max(0.0));
                    match why {
                        Why::Offline => {
                            if pill(ui, &p, icon::ARROW_CLOCKWISE, "Reconnect", Kind::Tonal).clicked() {
                                act = 1;
                            }
                        }
                        Why::NoBoards => {
                            if pill(ui, &p, icon::PLUS, "New board", Kind::Filled).clicked() {
                                act = 2;
                            }
                        }
                        Why::Empty => {
                            if pill(ui, &p, icon::SIDEBAR_SIMPLE, "Open library", Kind::Tonal).clicked() {
                                act = 3;
                            }
                            if pill(ui, &p, icon::CLIPBOARD, "Paste", Kind::Text).clicked() {
                                act = 4;
                            }
                        }
                    }
                });
            });
        });
        match act {
            1 => self.reconnect(),
            2 => {
                self.dialog = Dialog::NewBoard(String::new());
                self.dialog_focus = true;
            }
            3 => self.prefs.library = true,
            4 => self.paste(),
            _ => {}
        }
    }
}

/// Crop a texture to a centred square: a grid of letterboxed thumbnails reads
/// as a grid of holes.
fn cover_uv(size: [usize; 2]) -> Rect {
    let ratio = size[0] as f32 / size[1].max(1) as f32;
    if ratio > 1.0 {
        let inset = (1.0 - 1.0 / ratio) / 2.0;
        Rect::from_min_max(Pos2::new(inset, 0.0), Pos2::new(1.0 - inset, 1.0))
    } else {
        let inset = (1.0 - ratio) / 2.0;
        Rect::from_min_max(Pos2::new(0.0, inset), Pos2::new(1.0, 1.0 - inset))
    }
}

fn group_digits(n: usize) -> String {
    let s = n.to_string();
    let mut out = String::new();
    for (i, c) in s.chars().enumerate() {
        if i > 0 && (s.len() - i) % 3 == 0 {
            out.push(',');
        }
        out.push(c);
    }
    out
}

fn dialog_head(ui: &mut egui::Ui, p: &crate::theme::Palette, glyph: &str, title: &str) {
    ui.horizontal(|ui| {
        let (r, _) = ui.allocate_exact_size(Vec2::splat(36.0), Sense::hover());
        ui.painter().circle_filled(r.center(), 18.0, p.primary_container);
        ui.painter().text(r.center(), Align2::CENTER_CENTER, glyph, FontId::proportional(18.0), p.on_primary_container);
        ui.add_space(4.0);
        ui.label(RichText::new(title).size(19.0).color(p.on_surface));
    });
    ui.add_space(8.0);
}

/// Every gesture and key, where people look for them.
fn help_sheet(ui: &mut egui::Ui, p: &crate::theme::Palette) {
    ui.set_width(640.0);
    dialog_head(ui, p, icon::KEYBOARD, "Keyboard & mouse");
    let sections: [(&str, &[(&str, &[&str])]); 3] = [
        (
            "BOARD",
            &[
                ("Pan", &["Drag", "Two fingers"]),
                ("Zoom", &["Wheel", "Pinch"]),
                ("Fit everything", &["F", "Double-click"]),
                ("Zoom to 100%", &["Ctrl", "0"]),
                ("Go to origin", &["Space"]),
                ("Select an area", &["Shift Drag"]),
                ("…or", &["Double-click", "Drag"]),
                ("Select all", &["Ctrl", "A"]),
                ("Menu, by touch", &["Long press"]),
                ("Undo · redo", &["Ctrl Z", "Ctrl Shift Z"]),
            ],
        ),
        (
            "PICTURES",
            &[
                ("Scale", &["Corners", "Right-drag"]),
                ("Keep proportions", &["Shift Right-drag"]),
                ("Turn", &["Knob", "Hold R"]),
                ("Snap to 15°", &["Shift"]),
                ("Flip", &["H", "V"]),
                ("Front · back", &["]", "["]),
                ("Nudge", &["Arrows", "Shift ×10"]),
                ("Group", &["Ctrl", "G"]),
                ("Tidy into a grid", &["Ctrl Shift A"]),
                ("Move without snapping", &["Alt"]),
                ("Remove", &["Del"]),
            ],
        ),
        (
            "WINDOW",
            &[
                ("Library", &["Tab"]),
                ("Grid", &["G"]),
                ("Overview", &["M"]),
                ("Hide interface", &["\\"]),
                ("Paste a picture", &["Ctrl", "V"]),
                ("Copy a picture", &["Ctrl", "C"]),
                ("New board", &["Ctrl", "N"]),
                ("Rename board", &["F2"]),
                ("Pick a colour", &["I"]),
                ("Export view as PNG", &["Ctrl", "E"]),
                ("This sheet", &["F1"]),
            ],
        ),
    ];
    ui.columns(3, |cols| {
        for (col, (title, rows)) in cols.iter_mut().zip(sections.iter()) {
            caption(col, p, title);
            for (label, keys) in rows.iter() {
                col.horizontal(|ui| {
                    ui.set_min_height(26.0);
                    ui.add_space(8.0);
                    ui.label(RichText::new(*label).size(12.5).color(p.on_surface));
                    ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                        for k in keys.iter().rev() {
                            kbd(ui, p, k);
                        }
                    });
                });
            }
        }
    });
}
