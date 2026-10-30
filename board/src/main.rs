//! quarry board — a reference canvas, natively.
//!
//! Was QML under quickshell, and 326 MB for five pictures: 182 MB of that was
//! the runtime before the board drew anything. QML also gave almost no control
//! over the window itself, which for an application whose whole job is to sit
//! beside the thing you are drawing is the wrong set of constraints.
//!
//! Everything hard stays in the daemon: the sources, the catalogue, the
//! thumbnail ladder, the perceptual hashes, the boards schema, and the
//! `board.changed` events that keep this window and quarry in step. This is a
//! canvas and a socket.
//!
//! Layout of the crate:
//!
//!   main.rs      state, board operations, undo, the view
//!   canvas.rs    the board itself: drawing, hit-testing, gestures, keys
//!   chrome.rs    the floating interface: bars, library, menus, dialogs
//!   widgets.rs   the few controls the chrome is built from
//!   theme.rs     the desktop's colours (tinct) and quarry's type
//!   library.rs   catalogue search that does not disturb quarry's own paging
//!   textures.rs  the thumbnail ladder as GPU textures

mod canvas;
mod chrome;
mod client;
mod library;
mod model;
mod previews;
mod textures;
mod theme;
mod widgets;

use std::collections::HashMap;
use std::sync::Arc;

use client::{Client, Events};
use eframe::egui;
use model::{parse_list, BoardSummary, Container, Piece, Record};
use serde_json::json;
use textures::Textures;

/*
 * A HEADLESS SELF-REPORT.
 *
 * Every user-visible defect in this project has been a number, and a number
 * can be asserted. This connects, loads the board and prints what it found,
 * without opening a window.
 */
fn probe() -> i32 {
    let (client, _events) = match Client::connect() {
        Ok(pair) => pair,
        Err(e) => {
            println!("{}", json!({ "connected": false, "error": e }));
            return 1;
        }
    };
    let boards: Vec<BoardSummary> = client
        .call("boards", json!({ "action": "list" }))
        .ok()
        .map(|p| parse_list(p.get("boards")))
        .unwrap_or_default();

    let open = boards.first().map(|b| b.name.clone()).unwrap_or_default();
    let (mut pieces, mut containers): (Vec<Piece>, Vec<Container>) = (Vec::new(), Vec::new());
    if !open.is_empty() {
        if let Ok(p) = client.call("boards", json!({ "action": "items", "name": open })) {
            pieces = parse_list(p.get("items"));
            containers = parse_list(p.get("containers"));
        }
    }

    // Membership by geometry, which is what the canvas draws from — if this
    // disagrees with the stored `container`, the record has drifted.
    let by_geometry = pieces
        .iter()
        .filter(|p| {
            let (cx, cy) = p.centre();
            containers.iter().any(|b| b.contains(cx, cy))
        })
        .count();
    let recorded = pieces.iter().filter(|p| p.container > 0).count();
    let find = client.call("find", json!({ "q": "", "limit": 1 })).is_ok();

    println!(
        "{}",
        json!({
            "connected": true,
            "board": open,
            "boards": boards.len(),
            "pieces": pieces.len(),
            "containers": containers.len(),
            "groupedByGeometry": by_geometry,
            "groupedInRecord": recorded,
            "consistent": by_geometry == recorded,
            "librarySearch": find,
        })
    );
    0
}

fn main() -> eframe::Result<()> {
    if std::env::args().any(|a| a == "--probe") {
        std::process::exit(probe());
    }
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("quarry board")
            .with_app_id("quarry-board")
            .with_inner_size([1280.0, 820.0])
            .with_min_inner_size([520.0, 360.0])
            /*
             * The surface HAS an alpha channel; the app paints it opaque.
             *
             * Transparency cannot be turned on after a window exists, so the
             * channel is asked for up front — but the ground is fully opaque
             * until you lower it. By default the window behaves like any other
             * and the compositor's blur-behind is invisible.
             */
            .with_transparent(true),
        ..Default::default()
    };
    // `quarry-board "Colour study"` opens that board, making it if needed — how
    // quarry's "arrange on a board" hands a board to this window.
    let wanted = std::env::args().skip(1).find(|a| !a.starts_with("--"));
    eframe::run_native("quarry-board", options, Box::new(move |cc| Ok(Box::new(App::new(cc, wanted)))))
}

/// What a context menu was opened on.
#[derive(Clone, PartialEq)]
pub enum Menu {
    None,
    Piece,
    Container(i64),
    Canvas,
}

#[derive(Clone, PartialEq)]
pub enum Dialog {
    None,
    NewBoard(String),
    RenameBoard(String),
    RenameGroup(i64, String),
    DeleteBoard,
    Help,
}

#[derive(Clone, Copy, PartialEq)]
pub enum ToastKind {
    Info,
    Error,
}

pub struct Toast {
    pub text: String,
    pub kind: ToastKind,
    pub born: f64,
    /// A colour to show beside the text — the eyedropper's answer.
    pub swatch: Option<egui::Color32>,
}

/// What a requested screenshot of the window is for.
#[derive(Clone, Copy)]
pub enum Capture {
    /// The board as it is on screen, without the interface, saved as a PNG.
    Export,
    /// The colour under this point, copied as hex.
    Pick(egui::Pos2),
}

#[derive(Clone)]
pub struct Snapshot {
    pieces: Vec<Piece>,
    containers: Vec<Container>,
}

/// A camera move in progress: fit, zoom to 100%, jump from the minimap.
/// Short and eased, so you can see where you went.
#[derive(Clone, Copy)]
pub struct Flight {
    from_view: egui::Vec2,
    from_zoom: f32,
    to_view: egui::Vec2,
    to_zoom: f32,
    start: f64,
}

/// The settings a person expects to find as they left them.
#[derive(Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Prefs {
    pub ground: f32,
    pub picture_opacity: f32,
    pub grid: bool,
    pub minimap: bool,
    pub library: bool,
    pub last_board: String,
    /// The ground's colour: 0 follows the desktop theme, then black, grey, white.
    /// Reference is judged against its surroundings, so the ground is a choice.
    pub tone: u8,
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs { ground: 1.0, picture_opacity: 1.0, grid: true, minimap: false, library: false, last_board: String::new(), tone: 0 }
    }
}

fn prefs_path() -> String {
    format!("{}/.config/quarry/board.json", std::env::var("HOME").unwrap_or_default())
}

#[derive(Clone, Copy, PartialEq)]
pub enum Arrange {
    /// Rows of equal height, wrapped to a landscape block.
    Grid,
    /// One row, left to right.
    Row,
    /// Every picture scaled to the same height, where it stands.
    SameHeight,
}

pub const ZOOM_MIN: f32 = 0.05;
pub const ZOOM_MAX: f32 = 8.0;

pub struct App {
    client: Option<Arc<Client>>,
    events: Option<Events>,
    connect_error: String,

    boards: Vec<BoardSummary>,
    open: String,
    pieces: Vec<Piece>,
    containers: Vec<Container>,
    records: HashMap<String, Record>,

    textures: Textures,
    theme: theme::Theme,
    library: library::Library,
    previews: previews::Previews,

    /// Board-space offset of the viewport's top-left, and the zoom.
    view: egui::Vec2,
    zoom: f32,
    /// Where the canvas is on screen, this frame.
    canvas: egui::Rect,
    /// A wheel zoom still easing towards its target, and the point it holds.
    zoom_goal: Option<(f32, egui::Pos2)>,
    flight: Option<Flight>,

    selection: Vec<String>,
    grab: canvas::Grab,
    hovered: Option<String>,
    /// For double-click-and-drag marquee: when and where empty board was last
    /// clicked.
    last_empty_click: (f64, egui::Pos2),
    /// A board reload that arrived mid-gesture, applied when the hand lifts.
    reload_pending: bool,
    /// A screenshot to request at the end of this frame.
    capture: Option<Capture>,
    /// This frame is being captured: draw the board alone, no handles or hover.
    clean_frame: bool,
    /// The eyedropper is armed; the next click on the board picks a colour.
    picking: bool,
    /// Set by a long press, so the finger lifting is not also a click.
    swallow_click: bool,
    top_z: i64,

    menu: Menu,
    menu_at: egui::Pos2,
    menu_frame: u64,
    dialog: Dialog,
    dialog_focus: bool,
    switcher_open: bool,
    fade_open: bool,
    more_open: bool,
    zoom_open: bool,
    /// Where each popup's button is, so the popup opens under it.
    anchors: HashMap<&'static str, egui::Rect>,
    chrome_hidden: bool,
    /// A picture being dragged out of the library.
    carrying: Option<Record>,

    toasts: Vec<Toast>,
    undo: Vec<Snapshot>,
    redo: Vec<Snapshot>,

    prefs: Prefs,
    saved_prefs: Prefs,
    prefs_changed_at: f64,
    title: String,
    /// This frame's clock, for things that start an animation from deep inside an edit.
    now: f64,
}

impl App {
    fn new(cc: &eframe::CreationContext<'_>, wanted: Option<String>) -> Self {
        theme::install_fonts(&cc.egui_ctx);
        let theme = theme::Theme::load();
        theme.apply(&cc.egui_ctx);

        let (client, events, connect_error) = match Client::connect() {
            Ok((c, ev)) => (Some(Arc::new(c)), Some(ev), String::new()),
            Err(e) => (None, None, e),
        };
        let textures = Textures::new(client.clone());
        let prefs: Prefs = std::fs::read_to_string(prefs_path())
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();

        let mut app = App {
            client,
            events,
            connect_error,
            boards: Vec::new(),
            open: String::new(),
            pieces: Vec::new(),
            containers: Vec::new(),
            records: HashMap::new(),
            textures,
            theme,
            library: library::Library::new(),
            previews: previews::Previews::new(),
            view: egui::Vec2::ZERO,
            zoom: 1.0,
            canvas: egui::Rect::from_min_size(egui::Pos2::ZERO, egui::vec2(1280.0, 820.0)),
            zoom_goal: None,
            flight: None,
            selection: Vec::new(),
            grab: canvas::Grab::None,
            hovered: None,
            last_empty_click: (-10.0, egui::Pos2::ZERO),
            reload_pending: false,
            capture: None,
            clean_frame: false,
            picking: false,
            swallow_click: false,
            top_z: 1,
            menu: Menu::None,
            menu_at: egui::Pos2::ZERO,
            menu_frame: 0,
            dialog: Dialog::None,
            dialog_focus: false,
            switcher_open: false,
            fade_open: false,
            more_open: false,
            zoom_open: false,
            anchors: HashMap::new(),
            chrome_hidden: false,
            carrying: None,
            toasts: Vec::new(),
            undo: Vec::new(),
            redo: Vec::new(),
            saved_prefs: prefs.clone(),
            prefs,
            prefs_changed_at: 0.0,
            title: String::new(),
            now: 0.0,
        };
        app.refresh_boards();
        if let Some(name) = wanted.map(|n| n.trim().to_string()).filter(|n| !n.is_empty()) {
            if app.boards.iter().any(|b| b.name == name) {
                app.open_board(&name);
            } else if app.client.is_some() {
                app.create_board(&name);
            }
        }
        app.demo_state(std::env::var("QUARRY_BOARD_DEMO").unwrap_or_default().as_str());
        app
    }

    /*
     * Open the interface in a given state, for a headless render.
     *
     * A window in Xvfb cannot be clicked, and the menus, dialogs and selection
     * handles are exactly what most needs looking at. Comma-separated:
     * select, menu, canvas-menu, group-menu, help, switcher, fade, more, zoom,
     * pick, delete. Ignored unless set; see tools/board-demo.sh.
     */
    fn demo_state(&mut self, states: &str) {
        let mut ids: Vec<(String, f32, f32)> = self.pieces.iter().map(|p| (p.id.clone(), p.x + p.w / 2.0, p.y + p.h / 2.0)).collect();
        ids.sort_by(|a, b| a.2.total_cmp(&b.2).then(a.1.total_cmp(&b.1)));
        for state in states.split(',').map(str::trim) {
            match state {
                "select" => self.selection = ids.iter().take(3).map(|i| i.0.clone()).collect(),
                "menu" => {
                    if let Some((id, x, y)) = ids.get(1).cloned() {
                        self.selection = vec![id];
                        self.menu_at = self.to_screen(x, y);
                        self.menu = Menu::Piece;
                    }
                }
                "canvas-menu" => {
                    self.menu_at = egui::pos2(760.0, 360.0);
                    self.menu = Menu::Canvas;
                }
                "group-menu" => {
                    if let Some(b) = self.containers.first() {
                        self.menu_at = self.to_screen(b.x + 20.0, b.y);
                        self.menu = Menu::Container(b.id);
                    }
                }
                "help" => self.dialog = Dialog::Help,
                "delete" => self.dialog = Dialog::DeleteBoard,
                "new" => {
                    self.dialog = Dialog::NewBoard(String::new());
                    self.dialog_focus = true;
                }
                "switcher" => self.switcher_open = true,
                "fade" => self.fade_open = true,
                "more" => self.more_open = true,
                "zoom" => self.zoom_open = true,
                "pick" => self.picking = true,
                _ => {}
            }
        }
    }

    fn client(&self) -> Option<Arc<Client>> {
        self.client.clone()
    }

    fn reconnect(&mut self) {
        match Client::connect() {
            Ok((c, ev)) => {
                let c = Arc::new(c);
                self.textures = Textures::new(Some(c.clone()));
                self.client = Some(c);
                self.events = Some(ev);
                self.connect_error.clear();
                self.library.invalidate();
                self.refresh_boards();
                self.toast("Connected to quarryd", ToastKind::Info);
            }
            Err(e) => {
                self.connect_error = e;
                self.toast("quarryd is still not answering", ToastKind::Error);
            }
        }
    }

    pub fn toast(&mut self, text: impl Into<String>, kind: ToastKind) {
        self.toasts.push(Toast { text: text.into(), kind, born: -1.0, swatch: None });
        if self.toasts.len() > 4 {
            self.toasts.remove(0);
        }
    }

    pub fn toast_swatch(&mut self, text: impl Into<String>, colour: egui::Color32) {
        self.toasts.push(Toast { text: text.into(), kind: ToastKind::Info, born: -1.0, swatch: Some(colour) });
        if self.toasts.len() > 4 {
            self.toasts.remove(0);
        }
    }

    /*
     * THE WINDOW'S OWN PIXELS, for export and the eyedropper.
     *
     * Both want exactly what is on screen — the picture as scaled, filtered,
     * flipped and faded — and the renderer can hand that back after it paints
     * a frame. Reading the source file instead would pick a colour from a
     * different image than the one you are pointing at.
     */
    fn take_screenshots(&mut self, ctx: &egui::Context) {
        let shots: Vec<(egui::UserData, Arc<egui::ColorImage>)> = ctx.input(|i| {
            i.raw
                .events
                .iter()
                .filter_map(|e| match e {
                    egui::Event::Screenshot { user_data, image, .. } => Some((user_data.clone(), image.clone())),
                    _ => None,
                })
                .collect()
        });
        let ppp = ctx.pixels_per_point();
        for (data, shot) in shots {
            let Some(what) = data.data.as_ref().and_then(|d| (**d).downcast_ref::<Capture>()).copied() else { continue };
            match what {
                Capture::Pick(at) => {
                    let (x, y) = ((at.x * ppp) as usize, (at.y * ppp) as usize);
                    if x >= shot.size[0] || y >= shot.size[1] {
                        continue;
                    }
                    let [r, g, b, _] = shot.pixels[y * shot.size[0] + x].to_srgba_unmultiplied();
                    let hex = format!("#{r:02x}{g:02x}{b:02x}");
                    let copied = std::process::Command::new("wl-copy")
                        .arg(&hex)
                        .stdin(std::process::Stdio::null())
                        .status()
                        .map(|s| s.success())
                        .unwrap_or(false);
                    let text = if copied { format!("Copied {hex}") } else { hex.clone() };
                    self.toast_swatch(text, egui::Color32::from_rgb(r, g, b));
                }
                Capture::Export => {
                    let path = export_path(&self.open);
                    let (w, h) = (shot.size[0] as u32, shot.size[1] as u32);
                    let bytes: Vec<u8> = shot.pixels.iter().flat_map(|c| c.to_srgba_unmultiplied()).collect();
                    if let Some(dir) = std::path::Path::new(&path).parent() {
                        let _ = std::fs::create_dir_all(dir);
                    }
                    match image::save_buffer(&path, &bytes, w, h, image::ColorType::Rgba8) {
                        Ok(()) => self.toast(format!("Saved {}", short_path(&path)), ToastKind::Info),
                        Err(e) => self.toast(format!("Could not save the image: {e}"), ToastKind::Error),
                    }
                }
            }
        }
    }

    pub fn export_view(&mut self) {
        if self.open.is_empty() {
            return;
        }
        self.capture = Some(Capture::Export);
    }

    fn refresh_boards(&mut self) {
        let Some(c) = self.client() else { return };
        if let Ok(p) = c.call("boards", json!({ "action": "list" })) {
            self.boards = parse_list(p.get("boards"));
            let still_there = self.boards.iter().any(|b| b.name == self.open);
            if self.open.is_empty() || !still_there {
                let want = self
                    .boards
                    .iter()
                    .find(|b| b.name == self.prefs.last_board)
                    .or(self.boards.first())
                    .map(|b| b.name.clone());
                match want {
                    Some(name) => self.open_board(&name),
                    None => {
                        self.open.clear();
                        self.pieces.clear();
                        self.containers.clear();
                    }
                }
            }
        }
    }

    fn open_board(&mut self, name: &str) {
        self.open = name.to_string();
        self.prefs.last_board = name.to_string();
        self.selection.clear();
        self.undo.clear();
        self.redo.clear();
        self.flight = None;
        self.zoom_goal = None;
        self.reload();
        if let Some(b) = self.boards.iter().find(|b| b.name == name) {
            self.view = egui::vec2(b.view_x, b.view_y);
            self.zoom = if b.view_z > 0.0 { b.view_z } else { 1.0 };
        }
    }

    fn reload(&mut self) {
        let Some(c) = self.client() else { return };
        let Ok(p) = c.call("boards", json!({ "action": "items", "name": self.open })) else {
            return;
        };
        self.pieces = parse_list(p.get("items"));
        self.containers = parse_list(p.get("containers"));
        self.top_z = self.pieces.iter().map(|p| p.z).max().unwrap_or(0) + 1;
        let present: Vec<String> = self.pieces.iter().map(|p| p.id.clone()).collect();
        self.selection.retain(|s| present.contains(s));

        // A board holds ids the current query does not — that is the point of
        // keeping one — so the records are fetched by id and cached.
        let missing: Vec<String> =
            self.pieces.iter().filter(|p| !self.records.contains_key(&p.id)).map(|p| p.id.clone()).collect();
        for id in missing {
            if let Ok(p) = c.call("item", json!({ "id": id })) {
                if let Some(item) = p.get("item") {
                    if let Ok(rec) = serde_json::from_value::<Record>(item.clone()) {
                        self.records.insert(rec.id.clone(), rec);
                    }
                }
            }
        }
    }

    fn create_board(&mut self, name: &str) {
        let Some(c) = self.client() else { return };
        match c.call("boards", json!({ "action": "create", "name": name })) {
            Ok(_) => {
                self.refresh_boards();
                self.open_board(name);
            }
            Err(e) => self.toast(format!("Could not create the board: {e}"), ToastKind::Error),
        }
    }

    fn rename_board(&mut self, to: &str) {
        let Some(c) = self.client() else { return };
        let from = self.open.clone();
        if from == to {
            return;
        }
        match c.call("boards", json!({ "action": "rename", "name": from, "to": to })) {
            Ok(_) => {
                self.previews.forget(&from);
                self.open = to.to_string();
                self.refresh_boards();
                self.open_board(to);
            }
            Err(e) => self.toast(format!("Could not rename: {e}"), ToastKind::Error),
        }
    }

    fn delete_board(&mut self) {
        let Some(c) = self.client() else { return };
        let name = self.open.clone();
        let _ = c.call("boards", json!({ "action": "delete", "name": name }));
        self.previews.forget(&name);
        self.open.clear();
        self.pieces.clear();
        self.containers.clear();
        self.refresh_boards();
        self.toast(format!("Deleted “{name}” — its pictures are still in quarry"), ToastKind::Info);
    }

    fn commit(&self, piece: &Piece) {
        let Some(c) = self.client() else { return };
        // The whole row: `place` writes every field, so one left out is written
        // as its default — which is how membership used to be silently reset.
        c.send(
            "boards",
            json!({
                "action": "place", "name": self.open, "id": piece.id,
                "x": piece.x, "y": piece.y, "w": piece.w, "h": piece.h,
                "angle": piece.angle, "hflip": piece.hflip, "vflip": piece.vflip,
                "z": piece.z, "sharp": piece.sharp, "container": piece.container,
            }),
        );
    }

    fn commit_selection(&self) {
        for p in self.pieces.iter().filter(|p| self.selection.contains(&p.id)) {
            self.commit(p);
        }
    }

    fn write_container(&self, b: &Container) {
        let Some(c) = self.client() else { return };
        c.send(
            "boards",
            json!({
                "action": "container", "name": self.open, "container": b.id,
                "x": b.x, "y": b.y, "w": b.w, "h": b.h, "label": b.label
            }),
        );
    }

    /// The ground's colour, and the ink that reads on it — grid dots, group
    /// outlines and names.
    pub fn ground_colours(&self) -> (egui::Color32, egui::Color32) {
        let p = &self.theme.p;
        match self.prefs.tone {
            1 => (egui::Color32::from_rgb(8, 8, 9), egui::Color32::from_rgb(235, 235, 235)),
            2 => (egui::Color32::from_rgb(58, 58, 60), egui::Color32::from_rgb(235, 235, 235)),
            3 => (egui::Color32::from_rgb(240, 239, 236), egui::Color32::from_rgb(28, 28, 30)),
            _ => (p.background, p.on_surface),
        }
    }

    /// The palette for drawing ON the board. The desktop's primary is chosen
    /// to read on the desktop's own dark surfaces; on a light ground it would
    /// all but vanish, so selection, handles and guides take a darkened
    /// accent there instead.
    pub fn canvas_palette(&self) -> theme::Palette {
        let mut p = self.theme.p;
        let [r, g, b, _] = self.ground_colours().0.to_array();
        let luminance = (0.2126 * r as f32 + 0.7152 * g as f32 + 0.0722 * b as f32) / 255.0;
        if luminance > 0.55 && self.prefs.ground > 0.5 {
            p.primary = theme::mix(p.primary, egui::Color32::BLACK, 0.62);
            p.on_primary = egui::Color32::from_rgb(245, 245, 245);
        }
        p
    }

    // ── the view ─────────────────────────────────────────────────────────

    pub fn to_screen(&self, x: f32, y: f32) -> egui::Pos2 {
        self.canvas.min + (egui::vec2(x, y) - self.view) * self.zoom
    }

    pub fn to_board(&self, p: egui::Pos2) -> egui::Vec2 {
        (p - self.canvas.min) / self.zoom + self.view
    }

    /// Zoom by `factor`, holding the board point under `anchor` still.
    pub fn zoom_about(&mut self, factor: f32, anchor: egui::Pos2) {
        let before = self.to_board(anchor);
        self.zoom = (self.zoom * factor).clamp(ZOOM_MIN, ZOOM_MAX);
        let after = self.to_board(anchor);
        self.view += before - after;
    }

    /// Ease towards a zoom. Wheel notches arrive as steps; applied raw, a
    /// board jumps between framings. Accumulating into a target and gliding
    /// there keeps every notch counted and none of them visible as a jump.
    pub fn zoom_towards(&mut self, factor: f32, anchor: egui::Pos2) {
        self.flight = None;
        let target = match self.zoom_goal {
            Some((t, _)) => t,
            None => self.zoom,
        };
        self.zoom_goal = Some(((target * factor).clamp(ZOOM_MIN, ZOOM_MAX), anchor));
    }

    pub fn fly_to(&mut self, view: egui::Vec2, zoom: f32, now: f64) {
        self.zoom_goal = None;
        self.flight = Some(Flight { from_view: self.view, from_zoom: self.zoom, to_view: view, to_zoom: zoom, start: now });
    }

    /// Frame a board-space rectangle, with a margin, over the part of the
    /// window the chrome does not cover.
    pub fn frame_rect(&mut self, min: egui::Vec2, max: egui::Vec2, now: f64) {
        let span = egui::vec2((max.x - min.x).max(1.0), (max.y - min.y).max(1.0));
        let room = self.free_area();
        let zoom = ((room.width() / span.x).min(room.height() / span.y) * 0.9).clamp(ZOOM_MIN, ZOOM_MAX);
        let centre = min + span / 2.0;
        let offset = room.center() - self.canvas.min;
        let view = centre - offset / zoom;
        self.fly_to(view, zoom, now);
    }

    /// The canvas minus the library panel, so "fit" centres in what you see.
    pub fn free_area(&self) -> egui::Rect {
        let mut r = self.canvas.shrink(24.0);
        if self.prefs.library && !self.chrome_hidden {
            r.min.x += chrome::LIBRARY_WIDTH + 12.0;
        }
        r.min.y += 48.0;
        r
    }

    pub fn fit_all(&mut self, now: f64) {
        if let Some((min, max)) = self.bounds(|_| true) {
            self.frame_rect(min, max, now);
        }
    }

    pub fn fit_selection(&mut self, now: f64) {
        let chosen = self.selection.clone();
        if let Some((min, max)) = self.bounds(|p| chosen.contains(&p.id)) {
            self.frame_rect(min, max, now);
        }
    }

    /// Board-space bounds of the pieces that pass `keep`, rotation included.
    pub fn bounds(&self, keep: impl Fn(&Piece) -> bool) -> Option<(egui::Vec2, egui::Vec2)> {
        let mut out: Option<(egui::Vec2, egui::Vec2)> = None;
        for p in self.pieces.iter().filter(|p| keep(p)) {
            for c in canvas::corners(p) {
                out = Some(match out {
                    None => (c, c),
                    Some((lo, hi)) => (lo.min(c), hi.max(c)),
                });
            }
        }
        out
    }

    fn advance_view(&mut self, ctx: &egui::Context) {
        let (now, dt) = ctx.input(|i| (i.time, i.stable_dt.min(0.05)));
        if let Some(f) = self.flight {
            let t = ((now - f.start) / 0.32).clamp(0.0, 1.0) as f32;
            let e = 1.0 - (1.0 - t).powi(3);
            // Zoom in log space, so a flight from 10% to 400% does not spend
            // its whole duration apparently not moving.
            let z = (f.from_zoom.ln() + (f.to_zoom.ln() - f.from_zoom.ln()) * e).exp();
            self.zoom = z;
            self.view = f.from_view + (f.to_view - f.from_view) * e;
            if t >= 1.0 {
                self.flight = None;
                self.save_view();
            } else {
                ctx.request_repaint();
            }
        }
        if let Some((target, anchor)) = self.zoom_goal {
            let gap = (target / self.zoom).ln();
            if gap.abs() < 0.0015 {
                self.zoom_about(target / self.zoom, anchor);
                self.zoom_goal = None;
                self.save_view();
            } else {
                let k = 1.0 - (-dt * 20.0).exp();
                self.zoom_about((gap * k).exp(), anchor);
                ctx.request_repaint();
            }
        }
    }

    pub fn save_view(&self) {
        let Some(c) = self.client() else { return };
        if self.open.is_empty() {
            return;
        }
        c.send("boards", json!({ "action": "view", "name": self.open, "x": self.view.x, "y": self.view.y, "z": self.zoom }));
    }

    // ── undo ─────────────────────────────────────────────────────────────

    /// Remember the board as it is, before something changes it.
    pub fn checkpoint(&mut self) {
        self.undo.push(Snapshot { pieces: self.pieces.clone(), containers: self.containers.clone() });
        if self.undo.len() > 100 {
            self.undo.remove(0);
        }
        self.redo.clear();
    }

    pub fn undo(&mut self) {
        if let Some(s) = self.undo.pop() {
            let now = Snapshot { pieces: self.pieces.clone(), containers: self.containers.clone() };
            self.redo.push(now);
            self.restore(s);
        }
    }

    pub fn redo(&mut self) {
        if let Some(s) = self.redo.pop() {
            let now = Snapshot { pieces: self.pieces.clone(), containers: self.containers.clone() };
            self.undo.push(now);
            self.restore(s);
        }
    }

    /// Make the daemon match a snapshot by writing only what differs.
    fn restore(&mut self, s: Snapshot) {
        let Some(c) = self.client() else { return };
        for p in &s.pieces {
            if self.pieces.iter().find(|q| q.id == p.id) != Some(p) {
                self.commit(p);
            }
        }
        for p in &self.pieces {
            if !s.pieces.iter().any(|q| q.id == p.id) {
                c.send("boards", json!({ "action": "remove", "name": self.open, "id": p.id }));
            }
        }
        let mut recreated = false;
        for b in &s.containers {
            match self.containers.iter().find(|q| q.id == b.id) {
                Some(q) if q == b => {}
                Some(_) => self.write_container(b),
                None => {
                    // Ungrouped since: a container comes back as a new one,
                    // because the id it had is gone.
                    let _ = c.call(
                        "boards",
                        json!({ "action": "container", "name": self.open, "container": 0,
                                "x": b.x, "y": b.y, "w": b.w, "h": b.h, "label": b.label }),
                    );
                    recreated = true;
                }
            }
        }
        for b in &self.containers {
            if !s.containers.iter().any(|q| q.id == b.id) {
                let _ = c.call("boards", json!({ "action": "uncontain", "name": self.open, "container": b.id }));
            }
        }
        self.pieces = s.pieces;
        self.containers = s.containers;
        if recreated {
            self.reload();
            self.reconcile_membership();
        }
        let present: Vec<String> = self.pieces.iter().map(|p| p.id.clone()).collect();
        self.selection.retain(|id| present.contains(id));
    }

    // ── edits ────────────────────────────────────────────────────────────

    /// Apply an edit to every selected piece and write them all back.
    pub fn edit_selection(&mut self, f: impl Fn(&mut Piece)) {
        if self.selection.is_empty() {
            return;
        }
        self.checkpoint();
        let chosen = self.selection.clone();
        for p in self.pieces.iter_mut().filter(|p| chosen.contains(&p.id)) {
            f(p);
        }
        self.commit_selection();
    }

    pub fn remove_selection(&mut self) {
        if self.selection.is_empty() {
            return;
        }
        let Some(c) = self.client() else { return };
        self.checkpoint();
        let n = self.selection.len();
        for id in self.selection.clone() {
            c.send("boards", json!({ "action": "remove", "name": self.open, "id": id }));
        }
        let chosen = std::mem::take(&mut self.selection);
        self.pieces.retain(|p| !chosen.contains(&p.id));
        self.toast(
            format!("Took {} off the board · Ctrl Z to undo", if n == 1 { "a picture".into() } else { format!("{n} pictures") }),
            ToastKind::Info,
        );
    }

    pub fn bring_to_front(&mut self) {
        let chosen = self.selection.clone();
        let mut order: Vec<usize> = (0..self.pieces.len()).filter(|i| chosen.contains(&self.pieces[*i].id)).collect();
        order.sort_by_key(|i| self.pieces[*i].z);
        self.checkpoint();
        for i in order {
            self.top_z += 1;
            self.pieces[i].z = self.top_z;
        }
        self.commit_selection();
    }

    pub fn send_to_back(&mut self) {
        let chosen = self.selection.clone();
        let low = self.pieces.iter().map(|p| p.z).min().unwrap_or(0);
        let mut order: Vec<usize> = (0..self.pieces.len()).filter(|i| chosen.contains(&self.pieces[*i].id)).collect();
        order.sort_by_key(|i| std::cmp::Reverse(self.pieces[*i].z));
        self.checkpoint();
        let mut z = low;
        for i in order {
            z -= 1;
            self.pieces[i].z = z;
        }
        self.commit_selection();
    }

    /*
     * TIDY.
     *
     * Gathering reference is fast and messy; a board you come back to is
     * rows you can scan. Pictures are taken in reading order — bands from top
     * to bottom, left to right within a band — so tidying keeps roughly the
     * order you had, and set to the MEDIAN height, so one huge or tiny picture
     * does not decide the size of all the others. Tidy means straight: turned
     * pictures are straightened, because a row of tilted rectangles does not
     * pack.
     */
    pub fn arrange(&mut self, how: Arrange) {
        let chosen = self.selection.clone();
        if chosen.len() < 2 && how != Arrange::SameHeight {
            return;
        }
        let Some((lo, _)) = self.bounds(|p| chosen.contains(&p.id)) else { return };
        self.checkpoint();

        let mut idx: Vec<usize> = (0..self.pieces.len()).filter(|i| chosen.contains(&self.pieces[*i].id)).collect();
        let mut heights: Vec<f32> = idx.iter().map(|i| self.pieces[*i].h).collect();
        heights.sort_by(|a, b| a.total_cmp(b));
        let h = heights[heights.len() / 2].max(20.0);
        let band = h * 0.5;
        idx.sort_by(|a, b| {
            let (pa, pb) = (&self.pieces[*a], &self.pieces[*b]);
            (pa.y / band).floor().total_cmp(&(pb.y / band).floor()).then(pa.x.total_cmp(&pb.x))
        });

        let gap = 24.0;
        match how {
            Arrange::SameHeight => {
                for i in &idx {
                    let p = &mut self.pieces[*i];
                    let (cx, cy) = p.centre();
                    p.w = h * p.w / p.h.max(1.0);
                    p.h = h;
                    p.x = cx - p.w / 2.0;
                    p.y = cy - p.h / 2.0;
                }
            }
            Arrange::Row | Arrange::Grid => {
                let widths: Vec<f32> = idx.iter().map(|i| h * self.pieces[*i].w / self.pieces[*i].h.max(1.0)).collect();
                let total: f32 = widths.iter().sum::<f32>() + gap * (widths.len() as f32 - 1.0);
                // For a block about 16:10: with r rows, width = total / r and
                // height = r (h + gap), so width = sqrt(1.6 · total · (h + gap)).
                let limit = match how {
                    Arrange::Row => f32::INFINITY,
                    _ => (1.6 * total * (h + gap)).sqrt().max(widths.iter().cloned().fold(0.0, f32::max)),
                };
                let (mut x, mut y) = (lo.x, lo.y);
                for (k, i) in idx.iter().enumerate() {
                    let w = widths[k];
                    if x > lo.x && x + w - lo.x > limit {
                        x = lo.x;
                        y += h + gap;
                    }
                    let p = &mut self.pieces[*i];
                    p.w = w;
                    p.h = h;
                    p.x = x;
                    p.y = y;
                    p.angle = 0.0;
                    x += w + gap;
                }
            }
        }
        self.reconcile_membership();
        self.commit_selection();
    }

    /*
     * Wrap the selection in a container.
     *
     * "These belong together" is one gesture on things you have already
     * gathered, rather than a box drawn empty and then filled.
     */
    pub fn group_selection(&mut self) {
        if self.selection.is_empty() {
            return;
        }
        let Some(c) = self.client() else { return };
        let chosen = self.selection.clone();
        let Some((min, max)) = self.bounds(|p| chosen.contains(&p.id)) else { return };
        self.checkpoint();
        let (pad, head) = (28.0, 28.0);
        let made = c.call(
            "boards",
            json!({
                "action": "container", "name": self.open, "container": 0,
                "x": min.x - pad, "y": min.y - head,
                "w": (max.x - min.x) + pad * 2.0, "h": (max.y - min.y) + head + pad,
                "label": ""
            }),
        );
        if let Ok(p) = made {
            if let Some(id) = p.get("container").and_then(|v| v.as_i64()) {
                for p in self.pieces.iter_mut().filter(|p| chosen.contains(&p.id)) {
                    p.container = id;
                }
                self.commit_selection();
                self.reload();
                self.dialog = Dialog::RenameGroup(id, String::new());
                self.dialog_focus = true;
                return;
            }
        }
        self.reload();
    }

    /// Remove a container. Its pictures STAY.
    pub fn ungroup(&mut self, id: i64) {
        let Some(c) = self.client() else { return };
        self.checkpoint();
        let _ = c.call("boards", json!({ "action": "uncontain", "name": self.open, "container": id }));
        self.reload();
    }

    pub fn rename_group(&mut self, id: i64, label: &str) {
        if let Some(b) = self.containers.iter_mut().find(|b| b.id == id) {
            b.label = label.to_string();
        }
        if let Some(b) = self.containers.iter().find(|b| b.id == id).cloned() {
            self.write_container(&b);
        }
    }

    /*
     * The record follows the geometry, wherever geometry settled.
     *
     * Membership is decided by where a picture IS — its centre inside an
     * outline — and the stored column is a cache of that.
     */
    pub fn reconcile_membership(&mut self) {
        let boxes = self.containers.clone();
        let mut changed = Vec::new();
        for p in self.pieces.iter_mut() {
            let (cx, cy) = p.centre();
            let into = boxes.iter().filter(|b| b.contains(cx, cy)).map(|b| b.id).last().unwrap_or(0);
            if into != p.container {
                p.container = into;
                changed.push(p.clone());
            }
        }
        for p in &changed {
            self.commit(p);
        }
    }

    /// Put a catalogue record on the board, centred on a board point.
    pub fn place_record(&mut self, rec: &Record, at: egui::Vec2) {
        let Some(c) = self.client() else { return };
        if self.open.is_empty() {
            self.toast("Create a board first", ToastKind::Error);
            return;
        }
        if self.pieces.iter().any(|p| p.id == rec.id) {
            // One of each picture per board: bring the existing one into view
            // rather than silently doing nothing.
            self.selection = vec![rec.id.clone()];
            self.fit_selection(self.now);
            self.toast("Already on this board", ToastKind::Info);
            return;
        }
        self.checkpoint();
        let ratio = if rec.w > 0 && rec.h > 0 { rec.h as f32 / rec.w as f32 } else { 0.75 };
        // A comfortable size on SCREEN, whatever the zoom: dropped at 10% a
        // 460-unit picture is a speck.
        let w = (360.0 / self.zoom).clamp(80.0, 4000.0);
        let h = w * ratio;
        self.top_z += 1;
        let piece = Piece {
            id: rec.id.clone(),
            x: at.x - w / 2.0,
            y: at.y - h / 2.0,
            w,
            h,
            angle: 0.0,
            hflip: false,
            vflip: false,
            z: self.top_z,
            sharp: false,
            container: 0,
        };
        let _ = c.call(
            "boards",
            json!({
                "action": "place", "name": self.open, "id": piece.id,
                "x": piece.x, "y": piece.y, "w": piece.w, "h": piece.h, "z": piece.z
            }),
        );
        self.records.insert(rec.id.clone(), rec.clone());
        self.pieces.push(piece);
        self.selection = vec![rec.id.clone()];
        self.reconcile_membership();
    }

    fn adopt_and_place(&mut self, path: &str, at: egui::Vec2) -> bool {
        let Some(c) = self.client() else { return false };
        let Ok(p) = c.call("adopt", json!({ "path": path })) else {
            self.toast(format!("quarry could not read {}", short_path(path)), ToastKind::Error);
            return false;
        };
        let Some(item) = p.get("item") else { return false };
        let Ok(rec) = serde_json::from_value::<Record>(item.clone()) else { return false };
        self.place_record(&rec, at);
        true
    }

    // ── files and the clipboard ──────────────────────────────────────────

    /*
     * DROP FILES ONTO THE BOARD.
     *
     * Through the catalogue rather than around it: `adopt` turns a local file
     * into an ordinary row, so it gets a thumbnail and a perceptual hash and
     * can be searched for afterwards. Several at once fan out from the drop
     * point instead of landing in one stack.
     */
    fn handle_drops(&mut self, ctx: &egui::Context) {
        let (dropped, at) = ctx.input(|i| {
            (
                i.raw.dropped_files.iter().filter_map(|f| f.path.clone()).collect::<Vec<_>>(),
                i.pointer.hover_pos(),
            )
        });
        if dropped.is_empty() {
            return;
        }
        if self.open.is_empty() {
            self.toast("Create a board first", ToastKind::Error);
            return;
        }
        let base = self.to_board(at.unwrap_or(self.free_area().center()));
        let files = expand_dropped(dropped);
        let step = 380.0 / self.zoom;
        let cols = (files.len() as f32).sqrt().ceil().max(1.0) as usize;
        let mut added = 0;
        for (n, path) in files.iter().enumerate() {
            let (col, row) = ((n % cols) as f32, (n / cols) as f32);
            let at = base + egui::vec2((col - (cols as f32 - 1.0) / 2.0) * step, row * step * 0.8);
            if self.adopt_and_place(&path.to_string_lossy(), at) {
                added += 1;
            }
        }
        if added > 1 {
            let ids: Vec<String> = self.pieces.iter().rev().take(added).map(|p| p.id.clone()).collect();
            self.selection = ids;
            self.toast(format!("Added {added} pictures"), ToastKind::Info);
        }
    }

    /*
     * Pasting writes the clipboard to a real file first: everything
     * downstream works on paths, and a picture that existed only inside this
     * process would vanish when the board reopened.
     */
    pub fn paste(&mut self) {
        let dir = format!("{}/.cache/quarry/pasted", std::env::var("HOME").unwrap_or_default());
        let _ = std::fs::create_dir_all(&dir);
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or(0);
        let path = format!("{dir}/paste-{stamp}.png");
        let out = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!("wl-paste --type image/png > {}", shell_quote(&path)))
            .status();
        let ok = matches!(out, Ok(s) if s.success()) && std::fs::metadata(&path).map(|m| m.len() > 0).unwrap_or(false);
        if ok {
            let at = self.to_board(self.free_area().center());
            if self.adopt_and_place(&path, at) {
                self.toast("Pasted", ToastKind::Info);
            }
        } else {
            let _ = std::fs::remove_file(&path);
            self.toast("There is no picture on the clipboard", ToastKind::Error);
        }
    }

    /// Copy the selected picture out, into whatever you are drawing in.
    pub fn copy(&mut self) {
        let Some(id) = self.selection.first().cloned() else { return };
        let Some(rec) = self.records.get(&id) else { return };
        let path = rec.url.strip_prefix("file://").unwrap_or(&rec.url).to_string();
        if path.starts_with("http") {
            self.toast("That picture is not on disk yet", ToastKind::Error);
            return;
        }
        let ok = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!("wl-copy < {}", shell_quote(&path)))
            .status()
            .map(|s| s.success())
            .unwrap_or(false);
        if ok {
            self.toast("Copied to the clipboard", ToastKind::Info);
        } else {
            self.toast("Could not copy — is wl-clipboard installed?", ToastKind::Error);
        }
    }

    fn save_prefs(&mut self, now: f64) {
        if self.prefs == self.saved_prefs {
            self.prefs_changed_at = now;
            return;
        }
        // A slider drag changes the value every frame; write once it rests.
        if now - self.prefs_changed_at < 0.8 {
            return;
        }
        let path = prefs_path();
        if let Some(dir) = std::path::Path::new(&path).parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(text) = serde_json::to_string_pretty(&self.prefs) {
            let _ = std::fs::write(&path, text);
        }
        self.saved_prefs = self.prefs.clone();
    }
}

impl eframe::App for App {
    /// Cleared to nothing; the canvas paints the ground itself, at whatever
    /// opacity the board is set to.
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        [0.0, 0.0, 0.0, 0.0]
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let now = ctx.input(|i| i.time);
        self.now = now;
        self.theme.poll(ctx);
        self.textures.pump(ctx);

        // The other application changed a board. Same socket, same daemon.
        let mut changed = false;
        let mut disconnected = false;
        if let Some(ev) = self.events.as_ref() {
            loop {
                match ev.try_recv() {
                    Ok((name, _)) => changed |= name == "board.changed",
                    Err(std::sync::mpsc::TryRecvError::Empty) => break,
                    Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                        disconnected = true;
                        break;
                    }
                }
            }
        }
        if disconnected {
            self.events = None;
            self.client = None;
            self.connect_error = "quarryd closed the connection".into();
        }
        if changed {
            if self.grab.is_active() {
                self.reload_pending = true;
            } else {
                let at = self.boards.iter().map(|b| (b.name.clone(), b.items)).collect::<Vec<_>>();
                self.refresh_boards();
                if at != self.boards.iter().map(|b| (b.name.clone(), b.items)).collect::<Vec<_>>() {
                    self.library.invalidate();
                }
                self.reload();
            }
        }
        if self.reload_pending && !self.grab.is_active() {
            self.reload_pending = false;
            self.refresh_boards();
            self.reload();
        }
        if self.previews.pump() {
            ctx.request_repaint();
        }
        if self.library.pump(self.client.as_ref(), now) || self.library.loading {
            ctx.request_repaint_after(std::time::Duration::from_millis(60));
        }
        if self.prefs.library && self.library.text.is_empty() && self.library.results.is_empty() {
            ctx.request_repaint_after(std::time::Duration::from_millis(250));
        }

        let title = if self.open.is_empty() { "quarry board".to_string() } else { format!("{} — quarry board", self.open) };
        if title != self.title {
            ctx.send_viewport_cmd(egui::ViewportCommand::Title(title.clone()));
            self.title = title;
        }

        self.take_screenshots(ctx);
        self.advance_view(ctx);
        self.handle_drops(ctx);

        self.clean_frame = matches!(self.capture, Some(Capture::Export));
        if self.clean_frame {
            self.hovered = None;
        }
        egui::CentralPanel::default().frame(egui::Frame::NONE).show(ctx, |ui| {
            self.canvas_ui(ui);
        });

        if !self.clean_frame {
            self.chrome(ctx);
        }
        if let Some(what) = self.capture.take() {
            ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::UserData::new(what)));
            ctx.request_repaint();
        }
        self.save_prefs(now);
    }
}

/// Directories dropped on the board contribute the pictures directly inside
/// them — not recursively: dropping a home folder should not try to adopt a
/// hundred thousand files.
fn expand_dropped(paths: Vec<std::path::PathBuf>) -> Vec<std::path::PathBuf> {
    let pictures = ["png", "jpg", "jpeg", "webp", "gif", "bmp", "avif"];
    let mut out = Vec::new();
    for p in paths {
        if p.is_dir() {
            let mut inside: Vec<_> = std::fs::read_dir(&p)
                .map(|rd| {
                    rd.filter_map(|e| e.ok().map(|e| e.path()))
                        .filter(|f| {
                            f.extension()
                                .and_then(|e| e.to_str())
                                .is_some_and(|e| pictures.contains(&e.to_ascii_lowercase().as_str()))
                        })
                        .collect()
                })
                .unwrap_or_default();
            inside.sort();
            out.extend(inside.into_iter().take(200));
        } else {
            out.push(p);
        }
    }
    out
}

/// `~/Pictures/quarry boards/<board> <unix time>.png`, where the desktop's
/// pictures folder is whatever xdg-user-dirs says it is.
fn export_path(board: &str) -> String {
    let home = std::env::var("HOME").unwrap_or_default();
    let pictures = std::process::Command::new("xdg-user-dir")
        .arg("PICTURES")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
        .filter(|p| !p.is_empty() && *p != home)
        .unwrap_or_else(|| format!("{home}/Pictures"));
    let safe: String = board.chars().map(|c| if c.is_alphanumeric() || c == ' ' || c == '-' || c == '_' { c } else { '_' }).collect();
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    format!("{pictures}/quarry boards/{} {stamp}.png", safe.trim())
}

fn short_path(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| path.to_string())
}

/// Single-quote a path for `sh -c`.
///
/// Not decoration: RIA interpolates untrusted paths and URLs straight into
/// `system()` calls, which is a command injection in a reference viewer. A
/// filename with a quote in it is a perfectly ordinary thing to have.
fn shell_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}
