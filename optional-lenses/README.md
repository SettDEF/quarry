# Lenses that are not shipped

These are complete, working lenses. They are here rather than in
`modules/lens/builtin/` because they are adult, and a default install should not
carry an adult lens at all — not disabled, not hidden behind a switch, not
present.

`modules/lens/builtin/` is compiled into the package and scanned at startup.
This directory is not installed by `PKGBUILD` and nothing looks in it.

## Installing one

    cp -r optional-lenses/pornhub ~/.local/share/quarry/lenses/

`services/Lenses.qml` scans `~/.local/share/quarry/lenses/` after the built-ins,
and a user lens overrides a built-in of the same id — so this needs no rebuild
and survives upgrades.

## They still obey the switch

Installing one does not make it appear. `lens.json` declares `"adult": true`, and
`Lenses.isEnabled` returns false for an adult lens while adult content is off in
settings — the stored "enabled" is kept but not honoured, so turning the switch
back on restores what you had rather than making you set it up again.

## Why not just leave them in and disabled

Because "shipped but disabled" is a promise made of intent, and this one was
already broken once: `adult` had been in every lens manifest since the first one
and nothing read it. The pornhub lens was listed, enablable and openable with
adult content switched off. Not shipping it is the version of that promise that
cannot come apart.
