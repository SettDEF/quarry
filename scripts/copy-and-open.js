// ==QuarryScript==
// @name        Copy and open
// @version     1.0
// @description j and k move, o opens, y copies the link — the keybinds 4chan X trained everyone to expect. Works on every screen, which is why it is not named for one.
// @author      quarry
// @match       *
// @grant       keys, clipboard, open, toast
// ==/QuarryScript==

/*
 * A BARE LETTER, AND NOTHING ELSE.
 *
 * quarry only offers scripts un-modified letters while nothing is being typed
 * (see the key handler in shell.qml): Ctrl+F, Escape and the arrows stay the
 * app's, because a script that swallowed those would read as a broken app.
 */
quarry.key("y", function (context) {
    const item = context.item;
    if (!item) {
        quarry.toast("Nothing under the cursor to copy");
        return;
    }
    quarry.copy(item.page_url || item.url);
    quarry.toast("Link copied");
});

quarry.key("o", function (context) {
    if (context.item)
        quarry.open(context.item.page_url || context.item.url);
});
