//! What is on a board, as this app sees it.
//!
//! Mirrors the daemon's rows rather than inventing a second model: the
//! geometry is authoritative in SQLite and this is a working copy of it, held
//! while you drag so the daemon is written once on release instead of on every
//! frame.

use serde::Deserialize;
use serde_json::Value;

/// One picture, placed. Board units — the view carries the zoom, so a board
/// laid out on a 4K screen opens correctly on a laptop.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Piece {
    pub id: String,
    #[serde(default)]
    pub x: f32,
    #[serde(default)]
    pub y: f32,
    #[serde(default)]
    pub w: f32,
    #[serde(default)]
    pub h: f32,
    #[serde(default)]
    pub angle: f32,
    #[serde(default)]
    pub hflip: bool,
    #[serde(default)]
    pub vflip: bool,
    #[serde(default)]
    pub z: i64,
    #[serde(default)]
    pub sharp: bool,
    #[serde(default)]
    pub container: i64,
}

impl Piece {
    pub fn centre(&self) -> (f32, f32) {
        (self.x + self.w / 2.0, self.y + self.h / 2.0)
    }
}

/// A labelled outline. Pictures belong to it by where they ARE, not by a mode
/// you enter — see `members_of`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Container {
    pub id: i64,
    #[serde(default)]
    pub x: f32,
    #[serde(default)]
    pub y: f32,
    #[serde(default = "default_w")]
    pub w: f32,
    #[serde(default = "default_h")]
    pub h: f32,
    #[serde(default)]
    pub label: String,
}

fn default_w() -> f32 {
    600.0
}
fn default_h() -> f32 {
    400.0
}

impl Container {
    pub fn contains(&self, x: f32, y: f32) -> bool {
        x >= self.x && x <= self.x + self.w && y >= self.y && y <= self.y + self.h
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct BoardSummary {
    pub name: String,
    #[serde(default)]
    pub items: i64,
    #[serde(rename = "viewX", default)]
    pub view_x: f32,
    #[serde(rename = "viewY", default)]
    pub view_y: f32,
    #[serde(rename = "viewZ", default = "one")]
    pub view_z: f32,
}

fn one() -> f32 {
    1.0
}

/// A catalogue row — only the parts a canvas needs.
#[derive(Debug, Clone, Deserialize)]
pub struct Record {
    pub id: String,
    #[serde(default)]
    pub url: String,
    #[serde(default)]
    pub thumb: String,
    #[serde(default)]
    pub w: u32,
    #[serde(default)]
    pub h: u32,
    #[serde(default)]
    pub title: String,
}

pub fn parse_list<T: for<'de> Deserialize<'de>>(value: Option<&Value>) -> Vec<T> {
    value
        .and_then(|v| v.as_array())
        .map(|rows| {
            rows.iter()
                .filter_map(|r| serde_json::from_value(r.clone()).ok())
                .collect()
        })
        .unwrap_or_default()
}
