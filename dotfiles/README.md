# dotfiles — Claude-authored, chezmoi-managed

Source tree for the bare-Hyprland desktop on Metis. Managed by
`chezmoi` after the upcoming reinstall. Theme system is **matugen**
(Material You from wallpaper); no Catppuccin anywhere.

## Layout

```
dotfiles/
├── dot_config/             → ~/.config/
│   ├── hypr/               → Hyprland: split-file config
│   ├── waybar/             → status bar
│   ├── swaync/             → notification daemon + panel
│   ├── fuzzel/             → app launcher
│   ├── ghostty/            → terminal
│   ├── yazi/, helix/, imv/, zathura/
│   └── matugen/            → theme generator: config + templates
├── dot_local/bin/          → ~/.local/bin/   (helper scripts)
├── dot_local/share/        → ~/.local/share/ (wallpapers, desktop entries)
├── dot_config/systemd/user/ → user-level systemd units
└── .chezmoiscripts/        → pre-apply hooks (e.g., binding validator)
```

System-level files (greetd config, PAM stacks) live at
`../phase-3-arch-postinstall/system-files/` and are installed by
postinstall.sh, not chezmoi.

## Bootstrap

After fresh install:

```sh
chezmoi init --source=/path/to/arch-setup/dotfiles
chezmoi apply
```

Then `pkill -SIGRTMIN+8 waybar` (and equivalents) once to pick up
the matugen-rendered first palette.
