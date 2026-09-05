# termux-claude-code

**English** · [简体中文](README.zh-CN.md)

Install [Claude Code](https://claude.com/claude-code) on Termux (Android, aarch64).

```bash
curl -fsSL https://raw.githubusercontent.com/TIMER-err/termux-claude-code/main/install.sh | bash
```

Then open a new shell and run `claude`.

Or clone it and read it first, which is the better habit for anything piped into
a shell:

```bash
git clone https://github.com/TIMER-err/termux-claude-code.git
bash termux-claude-code/install.sh
```

## Why this is needed

Anthropic ships a `linux-arm64` build, but it is a [Bun](https://bun.sh)-packaged
single-file executable linked against **glibc**. Android uses **bionic** libc, so
the binary cannot execute under Termux at all — not a missing dependency you can
`pkg install` your way out of, but a different libc ABI. The npm package is no
escape either: `@anthropic-ai/claude-code` has no dependencies and a
`postinstall` script that fetches that same platform binary.

The usual workaround is a **proot** distro — `proot-distro install ubuntu`, then
install Claude Code inside it against real glibc. It runs, but it is painful to
actually use: **every keystroke takes hundreds of milliseconds to appear.** Typing
a prompt feels like typing over a bad SSH link.

That is worth being precise about, because the obvious explanation is wrong.
`proot` is a ptrace-based userspace chroot, so the assumption is that its syscall
interception taxes everything — but running commands inside the container is
perfectly acceptable. Tool calls, `rg`, `git`, subprocesses: fine. The latency is
specific to the binary's own interactive input path.

The evidence is that installing **this** project inside that same proot container
also fixes it. Same container, same ptrace overhead, responsive typing. So the
container was never really the problem — the packaged binary was.

This script skips both anyway. It does not run the binary and it does not need a
container: it unpacks the JavaScript back out of the executable and runs it on
`bun`. On bare Termux that is an ordinary Android process, your real `$HOME`, and
a 40 MB install instead of a second Linux rootfs to keep updated on a filesystem
apart from your own. And if you are already living inside proot, installing it
there works just as well.

## How it works

1. Download the official `linux-arm64` release and verify its SHA-256 against
   the release manifest.
2. `objcopy` the `.bun` section out of the ELF — this is Bun's standalone
   module-graph blob, terminated by a `\n---- Bun! ----\n` trailer.
3. Parse the module-graph table at the end of that blob and write every entry
   out as a real file (~1800 of them: ESM chunks, skills, docs, native modules).
4. Rewrite Bun's `/$bunfs/root/` virtual-FS paths to real relative paths.
5. Patch the hardcoded `/tmp` paths, which Termux app processes cannot write to.
6. Install a wrapper at `~/.local/bin/claude` that runs `bun cli.js` with the
   right environment.

### The module-graph format

Claude Code around **2.1.2xx** switched to a *code-split* bundle. The `.bun`
section no longer holds one big `cli.js`; it holds ~1800 separate ESM chunks
plus embedded assets, indexed by a table of 52-byte records at the end:

```
struct CompiledModuleGraphFile {   // 52 bytes
    StringPointer name;            // {u32 offset, u32 length}
    StringPointer contents;
    StringPointer sourcemap;
    StringPointer bytecode;
    /* loader / encoding / module_format flags */
};
```

All `StringPointer` offsets are relative to the start of the blob **plus 8**.
The entrypoint is the module named `/$bunfs/root/cli`.

> **Note for anyone porting an older script.** The pre-2.1.2xx approach — find
> the `file:///$bunfs/root/src/entrypoints/cli.js` marker, take the blob after
> it, cut at the first NUL — silently breaks on this format. That marker is now
> just a leftover in a string table ~78 MB away from any code, the length prefix
> reads as garbage, and the fallback NUL scan lands on a ~1 KB helper chunk. The
> result is a `cli.js` that parses fine and **returns immediately** on run.

### Why Bun and not Node

Running the unpacked bundle on Node is *nearly* possible: shim `globalThis.Bun`,
rewrite `import.meta.require` to `createRequire`, map `Bun.zstdDecompress*` onto
`node:zlib`. `claude --version` works. But `--help` dies with
`ERR_REQUIRE_CYCLE_MODULE` — the bundler emits `import.meta.require()` to load
ESM chunks synchronously through circular dependencies, which Bun tolerates and
Node's `require(esm)` does not. Fixing that means statically rewriting 300+ call
sites and hoping the evaluation-order change is benign.

Termux packages `bun` directly (`pkg install bun`), and it runs the bundle
unmodified — no shim, no `npm install`, ~8 MB smaller on disk. So: Bun.

## Requirements

Installed automatically via `pkg` if missing:

`curl` · `ripgrep` · `which` · `python` · `binutils` · `bun` · `ca-certificates`

Roughly 250 MB of free space during install (205 MB download, ~128 MB section,
40 MB final). The installed tree is **40 MB**.

## Options

`bash install.sh [install|uninstall] [options]` — `install` is the default.

| Option | Environment variable | Purpose |
| --- | --- | --- |
| `-r, --release VERSION` | `CLAUDE_RELEASE_VERSION` | Pin a release instead of resolving `latest`. |
| `-b, --binary PATH` | `CLAUDE_LOCAL_BINARY` | Use an already-downloaded binary instead of fetching one. |
| `-f, --force` | `FORCE_INSTALL_CC=1` | Reinstall even when the version marker already matches. |
| `-h, --help` | — | Print the same list and exit. |

To pass options through the curl one-liner, use `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/TIMER-err/termux-claude-code/main/install.sh \
  | bash -s -- --force
```

The 205 MB download is the slowest and most failure-prone step. If it drops
partway, `curl -C -` resumes on retry; or fetch it yourself and pass the path:

```bash
bash install.sh --binary ~/Download/claude
```

## Uninstall

```bash
bash install.sh uninstall
```

Removes `~/.local/bin/claude` and `~/.local/lib/claude-code`. Your auth and
settings in `~/.claude` and the shell rc-file entries are left alone.

## Layout

```
~/.local/bin/claude          wrapper script
~/.local/lib/claude-code/    unpacked module graph (cli.js + ~1800 files)
```

The wrapper sets `TMPDIR`/`CLAUDE_CODE_TMPDIR`/`CLAUDE_TMPDIR` under
`$PREFIX/tmp`, forces `USE_BUILTIN_RIPGREP=0` (the vendored `rg` is not part of
the unpacked graph, so Termux's own is used), disables the auto-updater — it
would replace the install with a binary that cannot run — and points TLS at
`$PREFIX/etc/tls/cert.pem`.

## Caveats

- **Auto-update is off by necessity.** Re-run `install.sh` to upgrade.
- **Unpacking is version-sensitive.** It reads Bun's internal standalone format.
  A Bun upgrade upstream can change the record layout; the script fails loudly
  rather than producing a broken install.
- A few Bun APIs the bundle references (`Bun.serve`, `Bun.Terminal`, `Bun.SQL`)
  come from Anthropic's Bun fork. They are behind optional features and are not
  reached on normal CLI paths.
- Claude Code is proprietary software under
  [Anthropic's Commercial Terms](https://code.claude.com/docs/en/legal-and-compliance).
  This repo contains no Anthropic code — only a script that downloads the
  official release and repacks it locally for a platform it does not target.
