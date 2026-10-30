// ==QuarryScript==
// @name        4chan: pictures only
// @version     1.0
// @description Drops replies that carry no image, so a thread reads as a gallery.
// @author      quarry
// @match       lens:fourchan
// @grant       rows
// ==/QuarryScript==

/*
 * What quarry is FOR, applied to a thread: the pictures, without the argument
 * around them. The OP is never offered to a script (Main.qml keeps it), so a
 * thread still opens with what it is about.
 */
quarry.on("rows", function (rows, context) {
    if (context.screen !== "thread")
        return rows;
    return rows.filter(post => post.tim !== undefined && post.tim !== null);
});
