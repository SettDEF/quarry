import qs.modules.common
import qs.modules.widgets
import qs.services
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts

/*
 * The query bar.
 *
 * One bar answers "a wallpaper for my ultrawide" and "a square avatar of a cat",
 * which only works if it is a language rather than a search box:
 *
 *     anime kind:wallpaper ratio>=2.3 w>=3440 -nsfw sort:new
 *
 * The daemon parses it (see PROTOCOL.md), so the grammar has exactly one
 * implementation. Completion asks the daemon too — the values come from the
 * catalogue, so `source:` suggests the sources that actually have rows.
 */
Item {
    id: root

    property alias text: field.text
    readonly property int suggestionCount: suggestions.count
    /// What the dropdown is actually doing, for the IPC check — it has shipped
    /// twice as a shape with the right contents and the wrong geometry.
    readonly property real popupHeight: popup.visible ? popup.height : 0
    /// Where the dropdown actually is, against where the field actually is —
    /// the one comparison that would have caught it drawing 900px away.
    readonly property string popupPlacement: {
        if (!root.overlay)
            return "no overlay";
        const f = field.mapToItem(root.overlay, 0, 0);
        return `field x=${Math.round(f.x)} w=${Math.round(field.width)} · popup x=${Math.round(popup.x)} w=${Math.round(popup.width)}`;
    }

    /*
     * BOTH implicit sizes, and the width is the one that matters.
     *
     * This declared only a height. In a RowLayout that competes with another
     * `fillWidth` item, an item whose implicit width is zero can be handed
     * zero — and it was: the field rendered 0px wide, which does not look like
     * a broken layout, it looks like there is no search box at all. The two
     * icons that live at its edges collapsed on top of each other at the far
     * right of the bar, with the field's own border as a hairline between
     * them, and the middle of the window was empty.
     *
     * A minimum as well, so no arrangement can squeeze it back to nothing.
     */
    implicitHeight: field.implicitHeight
    implicitWidth: 420
    Layout.minimumWidth: 260

    // Completion applies to the token under the cursor, which for typing is the
    // last one. Splitting on space is enough: quoted phrases are not completed.
    readonly property string activeToken: {
        const parts = field.text.split(/\s+/);
        return parts.length ? parts[parts.length - 1] : "";
    }

    function _replaceActiveToken(replacement) {
        const parts = field.text.split(/\s+/);
        parts[parts.length - 1] = replacement;
        field.text = parts.join(" ") + " ";
        popup.visible = false;
    }

    function _apply() {
        Catalog.query = field.text;
    }

    /*
     * Running a search on purpose, as opposed to the debounce running one
     * because you paused.
     *
     * Only this records history. `_apply` fires 160ms after every keystroke,
     * so remembering there would fill the list with `s`, `su`, `sun`, `suns`
     * — every prefix on the way to the search, which is precisely the noise
     * a history is supposed to be free of.
     */
    function _submit() {
        debounce.stop();
        root._apply();
        // Enter means "search now", not "after the pause".
        Catalog.searchNow();
        root._remember(field.text);
        popup.visible = false;
    }

    /*
     * WHAT YOU SEARCHED FOR BEFORE.
     *
     * Shown when the bar is focused and empty, which is otherwise the one
     * moment a search box has nothing to offer. Only queries that were actually
     * RUN are kept — not everything typed on the way to one — because a history
     * of half-typed prefixes is noise wearing the clothes of a suggestion.
     */
    function _remember(text) {
        const trimmed = (text || "").trim();
        if (trimmed.length < 2)
            return;
        const kept = (Prefs.recentQueries || []).filter(q => q !== trimmed);
        kept.unshift(trimmed);
        // Ten is already more than anybody scans; the list shows fewer.
        Prefs.recentQueries = kept.slice(0, 10);
    }

    /*
     * ONE ROW OF THE DROPDOWN.
     *
     * `text` is what goes in the field. `typed` is the part you already wrote,
     * which is dimmed rather than emphasised — Baymard's rule, and it is right:
     * you know what you typed, so the useful signal is what is being ADDED.
     * Emphasising the match instead makes every row look the same at the front.
     */
    function _row(text, typed, recent) {
        const colon = text.indexOf(":");
        const key = colon > 0 && !recent ? text.slice(0, colon + 1) : "";
        return {
            "text": text,
            "key": key,
            "value": text.slice(key.length),
            // How much of this row the user has already committed to.
            "typedLength": typed && text.startsWith(typed) ? typed.length : 0,
            "recent": !!recent,
            "count": root._countFor(key, text.slice(key.length))
        };
    }

    /// Fill the list with what you searched for before. Returns whether there
    /// was anything to show.
    function _showRecents() {
        const recents = (Prefs.recentQueries || []).slice(0, 6);
        suggestions.model = recents.map(q => root._row(q, "", true));
        suggestions.currentIndex = 0;
        return recents.length > 0 && field.activeFocus;
    }

    /*
     * Taking a row: a completion goes into the token, a past search replaces
     * the whole query — they are different acts and the row says which it is.
     */
    function _commit(row) {
        if (!row)
            return;
        if (row.recent) {
            field.text = row.text;
            root._submit();
            return;
        }
        root._replaceActiveToken(row.text);
    }

    /*
     * PREVIEWING WITH THE ARROW KEYS.
     *
     * Moving the selection copies that row into the field. It is the rule that
     * makes an autocomplete feel like typing rather than like picking from a
     * menu: you arrow to `source:danbooru`, it is in the bar, and you carry on
     * typing ` w>=3440` from there instead of committing and starting again.
     *
     * `_beforePreview` is what you actually wrote, so Escape can give it back.
     */
    property string _beforePreview: ""

    function _preview(index) {
        if (index < 0 || index >= suggestions.count)
            return;
        const row = suggestions.model[index];
        if (!row || row.recent)
            return;
        const parts = root._beforePreview.split(/\s+/);
        parts[parts.length - 1] = row.text;
        // Assigned without going through `_apply`: previewing is not searching,
        // and running a query per arrow key would be a crawl per keystroke.
        previewing = true;
        field.text = parts.join(" ");
        previewing = false;
    }

    /*
     * Anything that moves the field moves the list under it.
     *
     * The window resizing, the header relaying out, the clear button appearing
     * and changing the field's width — each of them leaves the popup where it
     * was, because its position was computed rather than bound.
     */
    onWidthChanged: popup.reposition()
    onHeightChanged: popup.reposition()
    // The header lays out after this is first positioned, so the field slides
    // sideways under a dropdown that stayed where the field used to be.
    onXChanged: popup.reposition()
    onYChanged: popup.reposition()

    Timer {
        // Cheap insurance: a reparent or a font change moves the field without
        // any of the signals above firing.
        running: popup.visible
        interval: 250
        repeat: true
        onTriggered: popup.reposition()
    }

    Connections {
        target: root.overlay
        function onWidthChanged() { popup.reposition() }
        function onHeightChanged() { popup.reposition() }
    }

    /*
     * THE BAR SHOWS THE QUERY, WHOEVER WROTE IT.
     *
     * The rail and the filter panel write tokens straight into the query, and
     * the bar never heard about it: pick Avatars and the field still said
     * nothing, then type a word and the debounce wrote the field back over the
     * query — dropping the filter you had just picked, silently. Written as a
     * preview, so it neither re-runs the search nor opens completions.
     */
    Connections {
        target: Catalog
        function onQueryChanged() {
            if (field.text.trim() === Catalog.query.trim())
                return;
            root.previewing = true;
            field.text = Catalog.query.length > 0 ? Catalog.query + " " : "";
            root.previewing = false;
        }
    }

    /// Set while the field is being written by the preview rather than by a
    /// person, so the completion timer does not chase its own tail.
    property bool previewing: false

    /// How many rows are behind a completion, where the catalogue knows.
    ///
    /// Supporting information, and styled as such: it turns "source:danbooru"
    /// from a string you might be about to guess wrong into a choice with a
    /// size attached.
    function _countFor(key, value) {
        const facets = key === "source:" ? Catalog.facetSources
            : key === "kind:" ? Catalog.facetKinds
            : key === "family:" ? Catalog.facetFamilies
            : null;
        if (!facets)
            return 0;
        const hit = facets.find(f => f.id === value);
        return hit ? hit.items : 0;
    }



    MaterialTextField {
        id: field
        anchors.fill: parent
        // The bar has its own clear button, placed with the filter controls.
        // The field's built-in one sits at its right edge — on top of them.
        showClear: false
        // Room for the buttons that live inside the bar, and the "/" hint.
        trailingSpace: root.text.length > 0 ? 86 : 78
        // A pill at rest, squarer once you are typing in it: the shape says
        // which of the two states it is in without a colour change.
        fieldRadius: field.activeFocus ? Appearance.rounding.normal : Appearance.rounding.full
        Behavior on fieldRadius {
            NumberAnimation {
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Easing.OutCubic
            }
        }
        // Square where the completions join, round when they are not there.
        bottomRadius: popup.visible ? 0 : field.fieldRadius
        Behavior on bottomRadius {
            NumberAnimation {
                duration: Appearance.animDur(110)
            }
        }
        implicitHeight: 48
        /*
         * AN INVITATION, NOT A SPECIFICATION.
         *
         * This read `search, or kind:wallpaper ratio>=2.3 -nsfw` — which is
         * the grammar, correctly, and is also the first thing anybody sees.
         * Three operators and a negation before you have typed anything says
         * "you need to learn this". One real example says the same thing and
         * can be copied; the rest of the language is a keystroke away in the
         * completions, and spelled out in the filter panel next door.
         */
        // The count is the sources that actually have rows, not the ones that
        // exist — "search 21 sources" is only true of a catalogue that has
        // been crawled, and a number that is a promise rather than a fact is
        // worse than no number.
        placeholder: Catalog.facetSources.length > 0
            ? `Search ${Catalog.facetSources.length} sources — try “4k wallpaper” or kind:avatar`
            : "Search — try “4k wallpaper” or kind:avatar"
        leadingIcon: "search"

        // Typing runs the query on a short delay, and asks for completions for
        // the token being typed.
        onTextChanged: {
            if (root.previewing)
                return;   // the arrow keys wrote this, not a person
            root._beforePreview = field.text;
            debounce.restart();
            complete.restart();
        }

        // Focusing an empty bar is the one moment a search box has nothing to
        // offer, and the moment it most obviously could.
        onActiveFocusChanged: {
            if (field.activeFocus && field.text.length === 0)
                popup.visible = root._showRecents();
            else if (!field.activeFocus)
                popup.visible = false;
        }

        onAccepted: root._submit()
    }

    /*
     * Filtering lives in the search, not beside it.
     *
     * A filter panel and a query bar are the same act — narrowing — and having
     * them as separate controls in a row of icons made that invisible. Inside
     * the bar it reads as what it is: the other way of saying the same thing.
     */
    /*
     * Emptying it took holding backspace.
     *
     * With filters now written INTO the query — picking a source types
     * `source:wikimedia` — the bar accumulates, and "start again" became a
     * common thing to want and a tedious thing to do. It appears only when
     * there is something to clear, so the resting bar still has one button.
     */
    IconButton {
        anchors.right: filterButton.left
        anchors.rightMargin: 2
        anchors.verticalCenter: parent.verticalCenter
        size: 38
        icon: "close"
        tooltip: "Clear the search"
        visible: root.text.length > 0
        onClicked: {
            field.text = "";
            root._apply();
            popup.visible = false;
            field.forceFieldFocus();
        }
    }

    // The shortcut, where a shortcut belongs: on the thing it focuses.
    Rectangle {
        anchors.right: filterButton.left
        anchors.rightMargin: 6
        anchors.verticalCenter: parent.verticalCenter
        visible: root.text.length === 0 && !field.activeFocus
        implicitWidth: 22
        implicitHeight: 20
        radius: Appearance.rounding.verysmall
        color: ColorUtils.transparentize(Appearance.colors.colLayer2, 0.35)

        StyledText {
            anchors.centerIn: parent
            text: "/"
            font.pixelSize: Appearance.font.pixelSize.smallest
            font.family: Appearance.font.family.monospace
            color: Appearance.colors.colSubtext
        }
    }

    IconButton {
        id: filterButton
        // Clear of the pill's curve: a 38px circle at the very edge has its
        // glyph cut by the field's own rounded corner.
        anchors.right: parent.right
        anchors.rightMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        size: 38
        // A funnel, not sliders: "tune" reads as settings at 20px.
        icon: root.filterOpen ? "filter_alt" : "filter_list"
        iconSize: 20
        fill: root.filterOpen ? 1 : 0
        tooltip: Shell.filterPanel && Shell.filterPanel.activeCount > 0
            ? `${Shell.filterPanel.activeCount} filter${Shell.filterPanel.activeCount === 1 ? "" : "s"} on — click to change them`
            : "Filters"
        toggled: root.filterOpen
        onClicked: root.filterToggled()

        // On the icon, ringed in the field's colour so the two never merge.
        Rectangle {
            visible: !!Shell.filterPanel && Shell.filterPanel.activeCount > 0
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.rightMargin: -1
            anchors.topMargin: 1
            implicitWidth: Math.max(16, badge.implicitWidth + 8)
            implicitHeight: 16
            radius: height / 2
            color: Appearance.colors.colPrimary
            border.width: 2
            border.color: Appearance.colors.colSurfaceContainerHigh

            StyledText {
                id: badge
                // Filled to the pill and aligned both ways: centring a text
                // item leaves the digit sitting high, because its item is as
                // tall as the font's line, not as tall as the digit.
                anchors.fill: parent
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: Shell.filterPanel ? `${Shell.filterPanel.activeCount}` : ""
                font.pixelSize: Appearance.font.pixelSize.smallest
                font.weight: Font.DemiBold
                color: Appearance.colors.colOnPrimary
            }
        }
    }

    // How many filters are on, beside the funnel rather than on it: a badge in
    // the corner of a 38px button either covers the glyph or hangs outside the
    // field's rounded edge.
    property bool filterOpen: false

    signal filterToggled

    Timer {
        id: debounce
        interval: 160
        onTriggered: root._apply()
    }

    /*
     * WHICH ANSWER IS STILL THE ANSWER.
     *
     * Completion requests go out per keystroke and come back whenever they come
     * back — nothing promises they arrive in order, and the protocol says so
     * out loud. A slow reply for "so" landing after a fast one for "source:d"
     * would replace the right list with a stale one, and it would look like the
     * dropdown lagging a character behind rather than like a bug.
     */
    property int _completionEpoch: 0

    Timer {
        id: complete
        interval: 90
        onTriggered: {
            const token = root.activeToken;
            if (token.length === 0 || !Client.connected) {
                popup.visible = root._showRecents();
                return;
            }
            const epoch = ++root._completionEpoch;
            Client.call("complete", {
                "prefix": token
            }, function (err, payload) {
                if (epoch !== root._completionEpoch)
                    return;   // a newer keystroke has already been answered
                if (err || !payload) {
                    popup.visible = false;
                    return;
                }
                /*
                 * Nothing to suggest once the token is complete.
                 *
                 * A single suggestion identical to what is already typed is not
                 * a completion, it is a mirror — and it sat over the gallery
                 * for as long as the cursor stayed put.
                 */
                // Eight, not everything: past about ten rows people stop
                // reading suggestions and start ignoring them.
                const useful = payload.suggestions.filter(s => s !== token).slice(0, 8);
                suggestions.model = useful.map(s => root._row(s, token, false));
                popup.visible = useful.length > 0 && field.text.length > 0;
                // Nothing is chosen until you choose it. With row 0 lit, Enter
                // ran a suggestion you had only been offered — so typing a word
                // and pressing Enter searched for a different one.
                suggestions.currentIndex = -1;
            });
        }
    }

    // Tab completes, arrows move, Escape dismisses — and Escape only clears the
    // query when there is no popup to close first, so one key does not do two
    // things at once.
    Keys.onPressed: event => {
        if (!popup.visible)
            return;
        if (event.key === Qt.Key_Down) {
            // Wrapping, both ways: at the end of six rows the next press
            // should go back to the top, not stop dead.
            suggestions.currentIndex = (suggestions.currentIndex + 1 + suggestions.count) % suggestions.count;
            root._preview(suggestions.currentIndex);
            event.accepted = true;
        } else if (event.key === Qt.Key_Up) {
            suggestions.currentIndex =
                (suggestions.currentIndex - 1 + suggestions.count) % suggestions.count;
            root._preview(suggestions.currentIndex);
            event.accepted = true;
        } else if (event.key === Qt.Key_Tab) {
            // Tab completes the first suggestion even when none is selected —
            // that is what Tab means in a completion list.
            root._commit(suggestions.model[Math.max(0, suggestions.currentIndex)]);
            event.accepted = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (suggestions.currentIndex >= 0) {
                root._commit(suggestions.model[suggestions.currentIndex]);
                event.accepted = true;
            } else {
                // Nothing picked: run exactly what is typed, and get the list
                // out of the way.
                popup.visible = false;
            }
        } else if (event.key === Qt.Key_Escape) {
            // Give back what was typed before the arrow keys started editing
            // it. Without this, dismissing the list leaves you with a
            // suggestion you were only looking at.
            if (root._beforePreview.length > 0 && field.text !== root._beforePreview)
                field.text = root._beforePreview;

            /*
             * ESCAPE WITH NOTHING OPEN MEANS "LET ME OUT OF THIS BOX".
             *
             * Escape closed the suggestion list and stopped there, so the field
             * kept focus for ever — until you happened to click the wall. Every
             * bare-letter key belongs to the scripts while the window has focus
             * and to the text field while it does not, which meant that after
             * ANY search, `a` typed an "a" instead of starting autoscroll, the
             * digits typed digits instead of setting its speed, and every other
             * script keybind did the same. It read as "autoscroll doesn't work"
             * and it was really "the search box never let go".
             *
             * One press closes the list, a second gives the keys back — so
             * dismissing a suggestion still does only that.
             */
            if (!popup.visible)
                root.releaseField();

            popup.visible = false;
            event.accepted = true;
        }
    }

    /*
     * THE SHADOW HAS TO LIVE WHERE THE POPUP LIVES.
     *
     * `anchors.fill: popup` is only legal between siblings, and the popup is
     * reparented into the overlay while this stayed behind in the query bar —
     * so the anchor was refused ("Cannot anchor to an item that isn't a parent
     * or sibling") and the shadow drew at 0x0, invisible, on every launch.
     *
     * Same parent, and geometry copied rather than anchored: `popup.x` and the
     * rest are ordinary properties that notify when `reposition()` assigns
     * them, so this follows it without an anchor.
     */
    RectangularShadow {
        parent: popup.parent
        x: popup.x
        y: popup.y
        width: popup.width
        height: popup.height
        radius: popup.radius
        blur: 20
        spread: 1
        offset: Qt.vector2d(0, 4)
        color: Qt.rgba(0, 0, 0, 0.4)
        visible: popup.visible
        z: popup.z - 1
    }

    /*
     * THE COMPLETIONS, AND WHY THEY LIVE SOMEWHERE ELSE.
     *
     * This used to be a child of the query bar with `z: 100` on it, which
     * cannot work for two separate reasons and failed for both. `z` orders an
     * item among its OWN siblings, and the gallery is a sibling of the entire
     * header — so the pictures painted straight over it. And the header clips,
     * so the part that did draw was cut off at the header's edge: what reached
     * the screen was a 12-pixel sliver of a dropdown, which reads as a broken
     * decoration rather than as a list of suggestions.
     *
     * So it is reparented into an overlay above everything (`overlay`, handed
     * in by the shell — the same item the menus pop into) and positioned by
     * mapping the field's corner into it. Nothing else can be over it, and
     * nothing can clip it.
     */
    property Item overlay: null

    Rectangle {
        id: popup

        parent: root.overlay || root
        // Mapped rather than anchored: anchors do not cross a reparent.
        /*
         * POSITIONED BY HAND, BECAUSE `mapToItem` IS NOT A BINDING.
         *
         * This was `x: field.mapToItem(overlay, 0, field.height).x`, which
         * looks like a binding and is not one: `mapToItem` reads geometry, it
         * does not depend on it, so Qt evaluates it once — while the RowLayout
         * is still laying out and the field is at x≈0 — and never again. The
         * result was a dropdown pinned to the far left of the window under the
         * heading, while the search bar it belongs to sat 900px away on the
         * right. Not a styling problem: it was drawing where the field used to
         * be.
         *
         * So it is recomputed whenever anything that could move it changes.
         * Assignment rather than binding, deliberately — a binding here would
         * be the same lie in a different shape.
         */
        function reposition() {
            if (!root.overlay) {
                popup.x = 0;
                popup.y = field.height;
                popup.width = field.width;
                return;
            }
            const corner = field.mapToItem(root.overlay, 0, field.height);
            popup.x = corner.x;
            popup.y = corner.y;
            // The width has to follow too: it is the bottom half of the field,
            // and a field that resized while the list was closed would open a
            // list of the wrong length.
            popup.width = field.width;
        }

        /*
         * IT IS THE BOTTOM OF THE SEARCH BAR, NOT A PANEL UNDER IT.
         *
         * Exactly the field's width and hard against its bottom edge, with the
         * join squared off at both ends and the same surface colour — so the
         * two read as one control that grew, which is what a completions list
         * is. A narrower box floating six pixels below looked like a menu that
         * happened to appear near the search.
         */
        // Width, x and y all come from `reposition` — a binding on `width`
        // alongside assigned x/y would half-follow the field, which is worse
        // than not following it at all.

        // The row heights, plus the padding — and NOTHING when there is
        // nothing to show, which is the state the 12px sliver was.
        /*
         * IT EXPANDS; IT DOES NOT SCROLL.
         *
         * A scrollbar inside an autocomplete is a list that has given up on
         * being scannable — and the model is already capped at eight, which is
         * under the point where people stop reading suggestions and start
         * ignoring them. So the height is simply the rows, plus the header when
         * there is one.
         */
        readonly property int headerHeight: suggestions.showingRecents ? 24 : 0
        height: suggestions.count > 0 ? suggestions.count * 36 + 14 + headerHeight : 0
        visible: false
        // Square at the join, rounded where it ends — the shell's card radius.
        radius: Appearance.rounding.normal
        // Continuous with the field: square where they meet, so the two read
        // as one control rather than a card parked under another.
        topLeftRadius: 0
        topRightRadius: 0
        color: field.color
        // The same accent the focused field wears, so the outline runs around
        // both halves rather than drawing a box around one of them.
        border.width: field.border.width
        border.color: field.border.color
        z: 1000

        // Depth is what says "above the pictures". A one-pixel border does not.
        RectangularShadow {
            anchors.fill: parent
            radius: parent.radius
            // Enough to lift it off the pictures, not so much that it reads as
            // a menu that happens to be near the search.
            blur: 18
            spread: 0
            offset: Qt.vector2d(0, 3)
            color: Qt.rgba(0, 0, 0, 0.3)
            z: -1
        }

        /*
         * "Recent" is a scope label, and scope labels are styled apart.
         *
         * Without it a list of past searches is indistinguishable from a list
         * of completions — same rows, same shape, entirely different meaning:
         * one narrows what you are typing, the other replaces it.
         */
        StyledText {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.leftMargin: 17
            anchors.topMargin: 8
            visible: suggestions.showingRecents
            text: "Recent"
            font.pixelSize: Appearance.font.pixelSize.smallest
            font.weight: Font.DemiBold
            color: Appearance.colors.colSubtext
        }

        ListView {
            id: suggestions
            anchors.fill: parent
            anchors.topMargin: 7 + popup.headerHeight
            anchors.leftMargin: 7
            anchors.rightMargin: 7
            anchors.bottomMargin: 7
            clip: true
            model: []
            keyNavigationWraps: true
            interactive: false

            /// Whether this list is history rather than completions.
            readonly property bool showingRecents:
                count > 0 && !!model[0] && model[0].recent === true

            delegate: Rectangle {
                required property var modelData
                required property int index

                width: suggestions.width
                height: 36
                radius: Appearance.rounding.small

                /*
                 * ONE highlight, shared by the pointer and the keyboard.
                 *
                 * The row lit up only for `currentIndex`, which the arrow keys
                 * moved and the mouse did not — so hovering a suggestion said
                 * nothing, and clicking one that was not the lit row acted on
                 * something the popup had never acknowledged. Hover MOVES the
                 * focus instead of drawing a second, competing highlight, so
                 * Enter and a click always commit the same row.
                 */
                readonly property bool focused: index === suggestions.currentIndex
                // Zero-alpha hover tint, not `transparent`: fading to rgba(0,0,0,0)
                // pulls the colour through black on the way out.
                color: sugTap.pressed ? Appearance.colors.colLayer4Active : focused ? Appearance.colors.colLayer4Hover : ColorUtils.transparentize(Appearance.colors.colLayer4Hover, 1)

                Behavior on color {
                    animation: Appearance.animation.stateChange.colorAnimation.createObject(this)
                }

                HoverHandler {
                    cursorShape: Qt.PointingHandCursor
                    onHoveredChanged: if (hovered)
                        suggestions.currentIndex = index
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    spacing: 8

                    MaterialSymbol {
                        /*
                         * What KIND of thing this is, so a column of twenty
                         * words is not twenty identical rows — and so a past
                         * search never looks like a filter you can apply.
                         */
                        text: {
                            if (modelData.recent)
                                return "history";
                            switch (modelData.key) {
                            case "kind:":
                                return "category";
                            case "source:":
                                return "cloud";
                            case "family:":
                                return "shapes";
                            case "tag:":
                            case "tags:":
                                return "sell";
                            case "in:":
                            case "collection:":
                                return "bookmark";
                            case "sort:":
                                return "sort";
                            default:
                                return modelData.key.length > 0 ? "tune" : "search";
                            }
                        }
                        iconSize: 17
                        color: Appearance.colors.colSubtext
                    }

                    StyledText {
                        /*
                         * THE PART YOU HAVE NOT TYPED IS THE PART THAT MATTERS.
                         *
                         * The instinct is to highlight the match — and it is
                         * wrong, measurably: you already know what you typed,
                         * so bolding it makes every row identical at the front
                         * and hides the one thing that distinguishes them. The
                         * typed prefix is dimmed and the rest is not, so a
                         * column of `source:` completions reads as danbooru,
                         * derpibooru, deviantart rather than as three
                         * source-somethings.
                         */
                        Layout.fillWidth: true
                        textFormat: Text.StyledText
                        text: {
                            const dim = Appearance.colors.colSubtext;
                            const typed = modelData.typedLength;
                            const full = modelData.text;
                            if (typed > 0)
                                return `<font color="${dim}">${full.slice(0, typed)}</font>${full.slice(typed)}`;
                            // A completion with no shared prefix still has a
                            // key, and the key is context rather than answer.
                            return modelData.key.length > 0
                                ? `<font color="${dim}">${modelData.key}</font>${modelData.value}`
                                : full;
                        }
                        font.pixelSize: Appearance.font.pixelSize.small
                        color: Appearance.colors.colOnLayer4
                        elide: Text.ElideRight
                    }

                    /*
                     * How much is behind it.
                     *
                     * Supporting information, styled as such — monospace and
                     * dim, so it lines up down the column and never competes
                     * with the thing it describes. It is the difference
                     * between guessing at a source name and choosing one.
                     */
                    StyledText {
                        visible: modelData.count > 0
                        // 40,855 reads; 40855 is a string of digits.
                        text: Number(modelData.count).toLocaleString(Qt.locale("en_US"), "f", 0)
                        font.family: Appearance.font.family.numbers
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }

                    // Which one Enter will take.
                    StyledText {
                        visible: parent.parent.focused
                        text: "⏎"
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }
                }

                TapHandler {
                    id: sugTap
                    // Grab on press. This floats over the gallery, so an
                    // ungrabbed tap on a suggestion also landed on whatever
                    // tile was underneath.
                    gesturePolicy: TapHandler.ReleaseWithinBounds
                    onTapped: root._commit(modelData)
                }
            }
        }
    }

    /// Put the cursor in the bar AND select what is there.
    ///
    /// Selecting matters more than it looks: `/` is pressed to start a new
    /// search, and landing the cursor at the end of the last one means the
    /// first thing you type is appended to a query you meant to replace.
    /// Hand the keyboard back to the window, so script keys work again.
    function releaseField() {
        field.focus = false;
        if (Shell.content)
            Shell.content.forceActiveFocus();

    }

    function focusField() {
        field.focusAndSelect();
    }
}
