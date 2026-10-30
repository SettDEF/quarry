/*
 * Turning titles into filenames.
 */

#![allow(dead_code)]




pub(crate) fn slugify_uncapped(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut dash = false;
    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            dash = false;
        } else if !out.is_empty() && !dash {
            out.push('-');
            dash = true;
        }
    }
    while out.ends_with('-') {
        out.pop();
    }
    out
}

pub fn slugify(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut dash = false;
    for ch in text.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
            dash = false;
        } else if !out.is_empty() && !dash {
            out.push('-');
            dash = true;
        }
    }
    /*
     * CAPPED, BECAUSE A SLUG BECOMES A FILENAME.
     *
     * Titles are whatever the uploader typed, and some of them are a
     * paragraph: one export landed a 226-character name, which is inside the
     * 255-byte limit only by luck. Past it the write fails with
     * ENAMETOOLONG — reported as "export failed", with nothing pointing at the
     * length. Cut at a word boundary so what survives is still readable.
     */
    const MAX: usize = 80;
    if out.len() > MAX {
        let cut = out[..MAX].rfind('-').unwrap_or(MAX);
        out.truncate(cut.max(1));
    }

    while out.ends_with('-') {
        out.pop();
    }
    if out.is_empty() {
        "untitled".into()
    } else {
        out
    }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slugs_are_filesystem_safe() {
        assert_eq!(slugify("Black & White — Spider/Man!"), "black-white-spider-man");
        assert_eq!(slugify("  padded  "), "padded");
        assert_eq!(slugify("***"), "untitled");
        assert!(!slugify("a/b").contains('/'));
    }

    /// A slug becomes a filename, and a filename has a limit.
    #[test]
    fn a_paragraph_of_a_title_still_makes_a_filename() {
        let rambling = "In space no one can hear you moan for empire check out my \
                        patreon if you want to support me and have a look at all the \
                        WIPs and other stuff https://www.patreon.com/c/chapaevv";
        let slug = slugify(rambling);

        assert!(slug.len() <= 80, "{} chars: {slug}", slug.len());
        // Cut at a word boundary, so it still reads as the thing it names.
        assert!(!slug.ends_with('-'));
        assert!(slug.starts_with("in-space-no-one-can-hear-you"));

        // Room for what the export template adds around it: the size, the
        // extension, a de-duplicating " (2)", and the directory.
        assert!(slug.len() + "-3840x2160.png (2)".len() < 255);
    }

    #[test]
    fn short_titles_are_untouched() {
        assert_eq!(slugify("Sunset Over Kyoto"), "sunset-over-kyoto");
    }
}
