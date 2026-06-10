# Vaultty

`Vaultty` is a macOS block terminal for Automic Vault workflows.

The app owns command input and renders command output as blocks. It uses a
persistent shell process, private OSC lifecycle markers, and a bundled
`vaultty-env` helper that reads Automic Vault dotenv keys directly from Keychain.
It does not call `av dotenv export`.

Build:

```sh
scripts/build-app.sh --release
```

The build script signs the app with the Developer ID identity associated with
`TEAM_COMMON_NAME` in `~/src/automic-vault/.env`.

Ghostty integration:

```sh
scripts/build-libghostty-vt.sh
scripts/build-app.sh --release --with-ghostty-vt
```

`libghostty-vt` is pinned to Ghostty `v1.3.1`, whose `build.zig.zon` requires
Zig `0.15.2`. `scripts/fetch-zig-0.15.2.sh` downloads the official arm64 macOS
Zig tarball and verifies its SHA-256 checksum. If Zig `0.15.2` cannot link
against the installed macOS SDK, the Ghostty build fails loudly and logs to
`target/logs/libghostty-vt-build.log` instead of silently shipping a terminal
that only pretends to use Ghostty.
