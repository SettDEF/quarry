import qs.modules.lens

/*
 * DEPRECATED — an extension is a LENS now (modules/lens/Lens.qml).
 *
 * Kept as the same type under the old name so the packs already on disk load
 * unchanged: `Extension { menuItems: […] }` still means what it meant. A lens
 * adds the screen, the sources it claims and its skins; a pack that only
 * contributes menu rows or an in-context mock needs none of that and is a
 * perfectly good lens with no skin at all.
 */
Lens {}
