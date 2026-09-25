# Context Desk icon

Generated with the built-in Imagegen tool on 2026-09-25. The design uses a charcoal macOS tile, two ivory conversation shapes and a blue unread accent. No third-party logo or source image was supplied.

- `source-v1.png`: original generated artwork with transparency, preserved unchanged.
- `AppIcon.icns`: macOS icon container, including 16, 32, 128, 256 and 512 pt variants at 1×/2×.
- `prompt.txt`: exact generation prompt.

Run `zsh scripts/build-icon.sh` to regenerate the icon container using native macOS `sips` and `iconutil`. The normal `scripts/build-app.sh` embeds it as `Contents/Resources/AppIcon.icns` and sets `CFBundleIconFile`. No runtime dependency or background process is needed.
