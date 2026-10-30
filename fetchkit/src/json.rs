/*
 * Reading JSON by dotted path, including indices, so a manifest can name a
 * field without any code being written for it.
 */

#![allow(dead_code)]


use serde_json::Value;


/// Pluck a nested value with a dotted path: `"data.Page.characters[0].image.large"`.
///
/// This is what makes a declarative `source.toml` possible — the field mapping
/// in the manifest is a set of these paths, so a new JSON source needs no code.
///
/// **17**
pub fn json_pluck<'a>(value: &'a Value, path: &str) -> Option<&'a Value> {
    let mut current = value;
    for raw in path.split('.') {
        let (key, indices) = split_indices(raw);
        if !key.is_empty() {
            current = current.get(key)?;
        }
        for i in indices {
            current = current.get(i)?;
        }
    }
    Some(current)
}

pub(crate) fn split_indices(segment: &str) -> (&str, Vec<usize>) {
    match segment.find('[') {
        None => (segment, Vec::new()),
        Some(at) => {
            let (key, rest) = segment.split_at(at);
            let indices = rest
                .split(['[', ']'])
                .filter(|s| !s.is_empty())
                .filter_map(|s| s.parse().ok())
                .collect();
            (key, indices)
        }
    }
}

/// `json_pluck` as a string, which is what a field mapping almost always wants.
///
/// **18**
pub fn json_str(value: &Value, path: &str) -> String {
    match json_pluck(value, path) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

// ── normalisation ───────────────────────────────────────────────────────────


#[cfg(test)]
mod tests {
    use super::*;
    use crate::fixture;

    #[test]
    fn json_paths_pluck_through_arrays() {
        let value: serde_json::Value =
            serde_json::from_str(&fixture("anilist.json")).expect("json parses");
        let name = json_str(&value, "data.Page.characters[0].name.full");
        let image = json_str(&value, "data.Page.characters[0].image.large");
        assert!(!name.is_empty(), "expected a character name");
        assert!(image.starts_with("https://"), "expected an image url, got {image:?}");
        assert_eq!(json_str(&value, "data.Page.nope[3].missing"), "");
    }
}
