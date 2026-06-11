# Vaultty

`Vaultty` is a macOS block terminal for Automic Vault workflows.

The app owns command input and renders command output as blocks. It uses a
persistent shell process, private OSC lifecycle markers, and a bundled
`vaultty-env` helper that reads Automic Vault dotenv keys directly from Keychain.
It does not call `av dotenv export`.

![Vaultty screenshot](assets/screenshot.webp)

## Features

- The macOS Tahoe appearance you have been waiting for
- Warp style blocks
- Fig autocompletions
- Automically loads Automic Vault encrytped `.env` secrets without approval

> [!IMPORTANT]
>
> Yes this means an agent with Computer Use could use Vaultty to exfilitrate
> secrets. But Computer Use also means that the agent could approve in Automic
> Vault too. If you are not using the AV iPhone app, or tranfering approvals
> to another machine then Vaultty is convenient and as-secure.

## Build

```sh
scripts/build-app.sh --release
```

The build script signs the app with the Developer ID identity associated with
`TEAM_COMMON_NAME` in `~/src/automic-vault/.env`.

## Versioning

`Cargo.toml` is the source of truth. Bump `package.version` to release a new
app version. `scripts/build-app.sh` stamps that into
`CFBundleShortVersionString`, sets `CFBundleVersion` from the git commit count,
and `scripts/publish.sh` publishes GitHub release tag `vX.Y.Z` from the built app
bundle.

## Ghostty Integration

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
