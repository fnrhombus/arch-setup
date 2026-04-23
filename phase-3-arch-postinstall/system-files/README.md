# System-level config files (not chezmoi-managed)

These files target paths under `/etc/` and are installed by
`postinstall.sh` during the reinstall (script-implementation pass —
TODO).

## Layout

```
system-files/
├── greetd/
│   ├── config.toml      → /etc/greetd/config.toml
│   ├── regreet.toml     → /etc/greetd/regreet.toml
│   └── (regreet.css comes from matugen at runtime — see below)
└── pam.d/
    └── greetd           → /etc/pam.d/greetd
```

## ReGreet CSS theming

`/etc/greetd/regreet.css` is rendered by **matugen** to
`~/.cache/matugen/regreet.css` at theme-toggle time. Because the
greeter runs as a system user (UID 992 typically) it can't read user
caches directly, so postinstall installs an initial copy at
`/etc/greetd/regreet.css` once. Live theme-following for the greeter
is deferred (would require a polkit rule to allow the user to
`cp ~/.cache/matugen/regreet.css /etc/greetd/`); the greeter is only
seen at cold boot, so the trade-off is acceptable.

To re-theme the greeter manually after a wallpaper change:

```sh
sudo install -m 644 ~/.cache/matugen/regreet.css /etc/greetd/regreet.css
sudo systemctl restart greetd     # next greeter render picks up the new CSS
```

## Wallpaper at the greeter

ReGreet reads `/etc/greetd/wallpaper.jpg` (per the path in regreet.toml).
postinstall copies the same first-boot wallpaper there. Updates to it
are not automatic.
