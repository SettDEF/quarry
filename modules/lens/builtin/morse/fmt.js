.pragma library

/*
 * Small conversions the lens and its skin both need: a chat's icon, a time
 * somebody can read, a size, a file extension. Nothing here talks to anything.
 */

/*
 * INITIALS, NOT THE SAME GLYPH SIXTY TIMES.
 *
 * `chatIcon` answers "group" for every group, so a list of sixty groups was
 * sixty identical circles and the only way to find one was to read every
 * title. Initials with a colour off the id are what every other client draws,
 * and unlike a generic glyph they are information: the same chat looks the
 * same every time you open the list.
 *
 * Letters and digits only — a title that is mostly emoji has no initials, and
 * half a surrogate pair drawn at 15px is worse than the glyph.
 */
function initials(chat) {
    const title = String((chat && chat.title) || "").trim();
    if (title.length === 0)
        return "";
    const words = title.split(/\s+/)
        .map(w => w.replace(/[^\p{L}\p{N}]/gu, ""))
        .filter(w => w.length > 0);
    if (words.length === 0)
        return "";
    const second = words.length > 1 ? Array.from(words[1])[0] : "";
    return (Array.from(words[0])[0] + second).toUpperCase();
}

/*
 * A STABLE HUE FOR AN IDENTITY, 0..1.
 *
 * Not a palette of hex colours: those would be wrong in one of the two themes
 * and would have to be maintained beside the real one. The hue is generated
 * and the lightness comes from the theme, so a chat keeps its colour and the
 * app keeps its own.
 */
function hueOf(key) {
    const text = String(key || "");
    let hash = 0;
    for (let i = 0; i < text.length; i++)
        hash = (hash * 31 + text.charCodeAt(i)) % 360;
    return hash / 360;
}

function chatIcon(chat) {
    if (!chat)
        return "chat";
    switch (String(chat.kind || "")) {
    case "private":
        return "person";
    case "channel":
        return "campaign";
    case "secret":
        return "lock";
    case "group":
    case "supergroup":
        return "group";
    }
    return "chat";
}

function chatKind(chat) {
    if (!chat)
        return "";
    const kind = String(chat.kind || "");
    if (kind === "private")
        return "direct";
    if (kind === "supergroup")
        return "group";
    if (kind === "secret")
        return "secret chat";
    return kind;
}

function folderName(folders, id) {
    for (let i = 0; i < (folders || []).length; i++)
        if (String(folders[i].id) === String(id))
            return String(folders[i].title || "");
    return "";
}

/*
 * TELEGRAM'S FOLDER ICON NAMES, AS MATERIAL SYMBOLS.
 *
 * Telegram picks from a fixed set — "Work", "Cat", "Money", … — and every
 * client draws them in its own idiom. Without this map every folder was the
 * same grey folder glyph, so a row of nine of them told you nothing about
 * which was which. A name this does not know is a name a newer Telegram added:
 * it falls back to the folder rather than to nothing.
 */
function folderIcon(name) {
    const icons = {
        "All": "forum",
        "Unread": "mark_email_unread",
        "Unmuted": "notifications_active",
        "Bots": "smart_toy",
        "Channels": "campaign",
        "Groups": "groups",
        "Private": "person",
        "Custom": "folder_special",
        "Setup": "tune",
        "Cat": "pets",
        "Crown": "workspace_premium",
        "Favorite": "star",
        "Flower": "local_florist",
        "Game": "sports_esports",
        "Home": "home",
        "Love": "favorite",
        "Mask": "theater_comedy",
        "Party": "celebration",
        "Sport": "sports_soccer",
        "Study": "school",
        "Trade": "trending_up",
        "Travel": "flight",
        "Work": "work",
        "Airplane": "flight",
        "Book": "menu_book",
        "Light": "lightbulb",
        "Like": "thumb_up",
        "Money": "payments",
        "Note": "sticky_note_2",
        "Palette": "palette"
    };
    return icons[String(name || "")] || "folder";
}

/// Unix seconds → something a conversation can put beside a message. Formatted
/// by hand: a `.pragma library` has no QML context to ask for a locale.
var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
var DAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

function when(seconds) {
    if (!seconds)
        return "";
    const then = new Date(seconds * 1000);
    const now = new Date();
    const pad = n => (n < 10 ? "0" : "") + n;
    const time = `${pad(then.getHours())}:${pad(then.getMinutes())}`;
    if (then.toDateString() === now.toDateString())
        return time;
    const days = Math.floor((now.getTime() - then.getTime()) / 86400000);
    if (days < 7)
        return `${DAYS[then.getDay()]} ${time}`;
    const year = then.getFullYear() === now.getFullYear() ? "" : ` ${then.getFullYear()}`;
    return `${then.getDate()} ${MONTHS[then.getMonth()]}${year}`;
}

/*
 * WHICH DAY A RUN OF MESSAGES BELONGS TO.
 *
 * `when` deliberately says as little as it can get away with — a bare "14:03"
 * inside today, "Tue 14:03" inside a week — which leaves a month of scrollback
 * with no day boundary anywhere in it: the only way to tell Tuesday from March
 * was the shape of the string beside each bubble.
 */
function day(seconds) {
    if (!seconds)
        return "";
    const then = new Date(seconds * 1000);
    const now = new Date();
    if (then.toDateString() === now.toDateString())
        return "Today";
    const yesterday = new Date(now.getTime() - 86400000);
    if (then.toDateString() === yesterday.toDateString())
        return "Yesterday";
    const year = then.getFullYear() === now.getFullYear() ? "" : ` ${then.getFullYear()}`;
    return `${DAYS[then.getDay()]} ${then.getDate()} ${MONTHS[then.getMonth()]}${year}`;
}

function size(bytes) {
    const n = Number(bytes) || 0;
    if (n <= 0)
        return "";
    const units = ["B", "kB", "MB", "GB"];
    let value = n;
    let unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
        value /= 1024;
        unit++;
    }
    return unit === 0 ? `${n} B` : `${value.toFixed(value >= 100 ? 0 : 1)} ${units[unit]}`;
}

function duration(seconds) {
    const n = Math.round(Number(seconds) || 0);
    if (n <= 0)
        return "";
    const m = Math.floor(n / 60);
    const s = n % 60;
    return `${m}:${s < 10 ? "0" : ""}${s}`;
}

function mediaIcon(media) {
    if (!media)
        return "description";
    switch (String(media.kind || "")) {
    case "photo":
        return "image";
    case "video":
        return "movie";
    case "videoNote":
        return "videocam";
    case "animation":
        return "gif";
    case "sticker":
        return "emoji_emotions";
    case "voice":
        return "mic";
    }
    return "description";
}

/// What a message is, when it has no words of its own.
function mediaLabel(media) {
    if (!media)
        return "";
    const kind = String(media.kind || "file");
    const name = media.name && media.name.length > 0 ? String(media.name) : "";
    if (name.length > 0)
        return name;
    switch (kind) {
    case "photo":
        return "Photo";
    case "video":
        return "Video";
    case "animation":
        return "GIF";
    case "sticker":
        return "Sticker";
    case "voice":
        return "Voice message";
    case "videoNote":
        return "Video message";
    }
    return "File";
}

function isDrawable(media) {
    if (!media)
        return false;
    const kind = String(media.kind || "");
    // A sticker comes in three formats and only one of them is a picture: the
    // other two are a VP9 clip and a gzipped Lottie, and handing either to an
    // Image draws a broken frame.
    if (kind === "sticker")
        return String(media.format || "static") === "static";
    return kind === "photo" || kind === "video" || kind === "animation" || kind === "videoNote";
}

function isMoving(media) {
    if (!media)
        return false;
    const kind = String(media.kind || "");
    return kind === "video" || kind === "animation" || kind === "videoNote";
}

/// The extension to keep a copy under: the file's own, else one from its mime.
function extensionOf(path, mime) {
    const tail = String(path || "").split("/").pop();
    const dot = tail.lastIndexOf(".");
    if (dot > 0 && tail.length - dot <= 6)
        return tail.slice(dot).toLowerCase();
    const type = String(mime || "");
    if (type === "image/png")
        return ".png";
    if (type === "image/jpeg")
        return ".jpg";
    if (type === "image/webp")
        return ".webp";
    if (type === "image/gif")
        return ".gif";
    if (type === "video/mp4")
        return ".mp4";
    if (type === "video/webm")
        return ".webm";
    return ".bin";
}

/// A path or URL that is a clip, whatever `kind` the message claimed — a clip
/// sent as a document is still not something an Image can draw.
function isVideoPath(path) {
    return /\.(mp4|webm|mkv|mov|m4v|avi|ogv)(\?|$)/i.test(String(path || ""));
}
