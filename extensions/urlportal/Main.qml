import qs.modules.widgets

/*
 * LINKS GO WHERE THE REST OF THE DESKTOP SENDS THEM.
 *
 * urlportal is a router: videos to mpv, image hosts to a viewer, pages to
 * zash's web view. quarry handed links to xdg-open, which knows none of that,
 * so a link from a chat opened somewhere different from the same link
 * anywhere else on this machine.
 *
 * The script is looked for on PATH first, then at ~/.scripts/urlportal —
 * quickshell does not always inherit the login shell's PATH. Exit 127 when
 * neither is there makes Sys.open fall back to xdg-open.
 */
Extension {
    openers: [
        {
            "id": "urlportal",
            "label": "urlportal",
            "matches": url => /^https?:\/\//i.test(url),
            "command": ["sh", "-c", 'p=$(command -v urlportal 2>/dev/null || echo "$HOME/.scripts/urlportal"); [ -x "$p" ] || exit 127; exec "$p" "$1"', "urlportal", "%u"]
        }
    ]
}
