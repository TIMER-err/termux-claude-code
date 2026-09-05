# termux-claude-code

**English** · [简体中文](README.zh-CN.md)

Install [Claude Code](https://claude.com/claude-code) on Termux (Android, aarch64).

```bash
curl -fsSL https://raw.githubusercontent.com/TIMER-err/termux-claude-code/main/install.sh | bash
```

Then open a new shell and run `claude`. Or clone the repo and read `install.sh`
first — the better habit for anything piped into a shell.

## Why

Anthropic's `linux-arm64` build is a [Bun](https://bun.sh)-packaged executable
linked against **glibc**. Android uses **bionic**, so it cannot execute under
Termux at all — a different libc ABI, not a missing dependency. The npm package
is no escape; it just downloads that same binary.

The usual workaround, a **proot** distro, does run it, but typing is painful:
every keystroke takes hundreds of milliseconds to appear. That is not proot's
syscall interception — commands and tool calls inside the container are fine,
and installing *this* project in the same container makes the lag go away. The
packaged binary is the problem, not the container.

So this script doesn't run the binary. It unpacks the JavaScript back out of it
and runs that on Termux's native `bun`: an ordinary Android process, your real
`$HOME`, 40 MB. It works inside proot too, if you already live there.

## How it works

1. Download the official `linux-arm64` release, verify SHA-256 against the
   release manifest.
2. `objcopy` the `.bun` section out of the ELF — Bun's standalone module-graph
   blob, ending in a `\n---- Bun! ----\n` trailer.
3. Parse the module-graph table at its end, write every entry out as a real file
   (~1800: ESM chunks, skills, docs, native modules).
4. Rewrite Bun's `/$bunfs/root/` virtual-FS paths to relative ones, and patch the
   hardcoded `/tmp` paths that Termux app processes cannot write to.
5. Install a wrapper at `~/.local/bin/claude` that runs `bun cli.js`.

### The module-graph format

Claude Code around **2.1.2xx** switched to a *code-split* bundle: no single
`cli.js`, but ~1800 ESM chunks plus embedded assets, indexed by 52-byte records
at the end of the section.

```
struct CompiledModuleGraphFile {   // 52 bytes
    StringPointer name;            // {u32 offset, u32 length}
    StringPointer contents;
    StringPointer sourcemap;
    StringPointer bytecode;
    /* loader / encoding / module_format flags */
};
```

Offsets are relative to the blob start **plus 8**; the entrypoint is the module
named `/$bunfs/root/cli`.

Porting an older script? The pre-2.1.2xx trick — seek the
`file:///$bunfs/root/src/entrypoints/cli.js` marker, cut at the first NUL —
now lands on a ~1 KB helper chunk, giving you a `cli.js` that parses fine and
returns immediately on run.

### Why Bun, not Node

Node *nearly* works: shim `globalThis.Bun`, swap `import.meta.require` for
`createRequire`, map `Bun.zstdDecompress*` onto `node:zlib`. But `--help` dies
with `ERR_REQUIRE_CYCLE_MODULE` — the bundle loads ESM chunks synchronously
through circular dependencies, which Bun tolerates and `require(esm)` does not.
Termux packages `bun` (`pkg install bun`), which runs the bundle unmodified.

## Usage

```
install.sh [install|uninstall] [options]
```

Defaults to `install`, and never prompts, so it is safe to pipe.

| Option | Environment variable | Purpose |
| --- | --- | --- |
| `-r, --release VERSION` | `CLAUDE_RELEASE_VERSION` | Pin a release instead of `latest`. |
| `-b, --binary PATH` | `CLAUDE_LOCAL_BINARY` | Use a binary you already downloaded. |
| `-f, --force` | `FORCE_INSTALL_CC=1` | Reinstall even at the same version. |
| `-h, --help` | — | Print the options and exit. |

Re-run `install` to upgrade; it skips the 205 MB download when the installed
version already matches. To pass arguments through the one-liner, use `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/TIMER-err/termux-claude-code/main/install.sh \
  | bash -s -- --force
```

## Uninstall

```bash
bash install.sh uninstall
```

Removes `~/.local/bin/claude` and `~/.local/lib/claude-code/`. Your login and
settings in `~/.claude` survive, as do the marked blocks the installer added to
your shell rc files (`# >>> cc-termux PATH >>>` and
`# >>> claude-code-termux-tmpdir >>>`) — delete those by hand if you want them
gone.

## Notes

- Prerequisites, installed via `pkg` if missing: `curl` · `ripgrep` · `which` ·
  `python` · `binutils` · `bun` · `ca-certificates`. Needs ~250 MB free during
  install; the installed tree is 40 MB.
- The wrapper points `TMPDIR`/`CLAUDE_*TMPDIR` at `$PREFIX/tmp`, sets
  `USE_BUILTIN_RIPGREP=0` (the vendored `rg` isn't in the unpacked graph), points
  TLS at `$PREFIX/etc/tls/cert.pem`, and disables the auto-updater — it would
  replace the install with the binary that cannot run.
- Unpacking reads Bun's internal standalone format, so it is version-sensitive.
  If the record layout changes upstream the script fails loudly rather than
  producing a broken install.
- A few Bun APIs the bundle references (`Bun.serve`, `Bun.Terminal`, `Bun.SQL`)
  come from Anthropic's Bun fork. They sit behind optional features and are not
  reached on normal CLI paths.
- Claude Code is proprietary software under
  [Anthropic's Commercial Terms](https://code.claude.com/docs/en/legal-and-compliance).
  This repo contains no Anthropic code — only a script that downloads the
  official release and repacks it locally for a platform it does not target.
