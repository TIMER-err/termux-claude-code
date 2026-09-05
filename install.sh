#!/bin/bash
# Install Claude Code on Termux (Android, aarch64).
#
# The official linux-arm64 release is a Bun-packaged binary linked against
# glibc, so it cannot execute under Android's bionic libc. This script unpacks
# the Bun module graph out of the binary's .bun section into plain files and
# runs them with Termux's own `bun`.
set -euo pipefail

section() { printf '\n=== %s ===\n' "$1"; }
step()    { printf '[%s] %s\n' "$1" "$2"; }
err()     { printf 'Error: %s\n' "$1" >&2; }

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
USER_BIN="$HOME/.local/bin"
USER_LIB="$HOME/.local/lib"

CLAUDE_PKG_DIR="$USER_LIB/claude-code"
CLAUDE_CLI="$CLAUDE_PKG_DIR/cli.js"
CLAUDE_VERSION_MARKER="$CLAUDE_PKG_DIR/.installed-version"

CURL=(curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors -C -)

usage() {
    cat <<'USAGE'
Install Claude Code on Termux (Android, aarch64).

Usage:
  install.sh [action] [options]

Actions:
  install                Install or update Claude Code (default)
  uninstall              Remove the wrapper and the unpacked module graph

Options:
  -r, --release VERSION  Pin a release instead of resolving "latest"
  -b, --binary PATH      Use an already-downloaded linux-arm64 binary
  -f, --force            Reinstall even if the installed version matches
  -h, --help             Show this help and exit

Environment variables (equivalent to the options above):
  CLAUDE_RELEASE_VERSION   same as --release
  CLAUDE_LOCAL_BINARY      same as --binary
  FORCE_INSTALL_CC=1       same as --force

Examples:
  bash install.sh
  bash install.sh --release 2.1.25
  bash install.sh --binary ~/Download/claude
  bash install.sh uninstall
USAGE
}

need_value() {
    [ "$2" -ge 2 ] || { err "$1 requires a value"; exit 1; }
}

action=install
while [ $# -gt 0 ]; do
    case "$1" in
        install)   action=install ;;
        uninstall) action=uninstall ;;
        -r|--release|--version)
            need_value "$1" $#; CLAUDE_RELEASE_VERSION="$2"; shift ;;
        --release=*|--version=*) CLAUDE_RELEASE_VERSION="${1#*=}" ;;
        -b|--binary)
            need_value "$1" $#; CLAUDE_LOCAL_BINARY="$2"; shift ;;
        --binary=*) CLAUDE_LOCAL_BINARY="${1#*=}" ;;
        -f|--force) FORCE_INSTALL_CC=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) err "Unknown argument: $1"; usage >&2; exit 1 ;;
    esac
    shift
done

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PATH_MARKER_BEGIN="# >>> cc-termux PATH >>>"
PATH_MARKER_END="# <<< cc-termux PATH <<<"
TMPDIR_MARKER_BEGIN="# >>> claude-code-termux-tmpdir >>>"
TMPDIR_MARKER_END="# <<< claude-code-termux-tmpdir <<<"

check_prereqs() {
    step "0/4" "Checking prerequisites..."
    local missing=()
    command -v curl    >/dev/null 2>&1 || missing+=(curl)
    command -v rg      >/dev/null 2>&1 || missing+=(ripgrep)
    command -v which   >/dev/null 2>&1 || missing+=(which)
    command -v python3 >/dev/null 2>&1 || missing+=(python)
    command -v objcopy >/dev/null 2>&1 || missing+=(binutils)
    command -v bun     >/dev/null 2>&1 || missing+=(bun)
    [ -f "$PREFIX/etc/tls/cert.pem" ] || missing+=(ca-certificates)

    if [ ${#missing[@]} -gt 0 ]; then
        echo "    Installing: ${missing[*]}"
        pkg install -y "${missing[@]}" >/dev/null 2>&1 || {
            err "failed to install prerequisites. Run manually:"
            echo "  pkg install ${missing[*]}" >&2
            exit 1
        }
    else
        echo "    All prerequisites present."
    fi
}

install_claude() {
    section "Claude Code"

    step "claude 1/4" "Resolving Claude Code version..."
    VERSION="${CLAUDE_RELEASE_VERSION:-latest}"
    if [ "$VERSION" = "latest" ]; then
        VERSION=$("${CURL[@]}" "https://downloads.claude.ai/claude-code-releases/latest")
    fi
    [ -n "$VERSION" ] || { err "Could not resolve latest Claude Code version"; exit 1; }
    echo "    Version: $VERSION"

    MANIFEST_URL="https://downloads.claude.ai/claude-code-releases/$VERSION/manifest.json"
    BIN_URL="https://downloads.claude.ai/claude-code-releases/$VERSION/linux-arm64/claude"
    CHECKSUM=$("${CURL[@]}" "$MANIFEST_URL" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['platforms']['linux-arm64']['checksum'])")
    [ -n "$CHECKSUM" ] || { err "Could not resolve checksum from manifest"; exit 1; }

    INSTALL_TAG="$VERSION|$CHECKSUM"
    if [ "${FORCE_INSTALL_CC:-0}" != "1" ] \
        && [ -f "$CLAUDE_VERSION_MARKER" ] \
        && [ "$(cat "$CLAUDE_VERSION_MARKER")" = "$INSTALL_TAG" ] \
        && [ -f "$CLAUDE_CLI" ]; then
        step "claude 2/4" "Already up to date, skipping."
    else
        step "claude 2/4" "Downloading bun-packaged linux-arm64 binary (~205 MB)..."
        if [ -n "${CLAUDE_LOCAL_BINARY:-}" ]; then
            echo "    Using local binary: $CLAUDE_LOCAL_BINARY"
            cp "$CLAUDE_LOCAL_BINARY" "$TMP_DIR/claude-bin"
        else
            "${CURL[@]}" "$BIN_URL" -o "$TMP_DIR/claude-bin"
        fi
        echo "$CHECKSUM  $TMP_DIR/claude-bin" | sha256sum -c - >/dev/null
        echo "    checksum OK: $CHECKSUM"

        step "claude 3/4" "Unpacking the Bun module graph..."
        objcopy -O binary --only-section=.bun "$TMP_DIR/claude-bin" "$TMP_DIR/bun.section"
        rm -f "$TMP_DIR/claude-bin"
        rm -rf "$CLAUDE_PKG_DIR"
        rm -f "$USER_BIN/claude"
        mkdir -p "$CLAUDE_PKG_DIR"
        python3 - "$TMP_DIR/bun.section" "$CLAUDE_PKG_DIR" <<'EXTRACT'
import os, re, struct, sys

section_path, out_dir = sys.argv[1], sys.argv[2]
data = open(section_path, 'rb').read()

# Claude Code >= ~2.1.2xx ships a *code-split* Bun standalone bundle: the .bun
# section holds ~1800 separate ESM chunks plus embedded assets, indexed by a
# module-graph table at the very end. Naive single-file extraction (find the
# cli.js marker, take the blob after it, cut at the first NUL) lands on a ~1 KB
# helper chunk, producing a cli.js that runs and returns immediately.
trailer = data.rfind(b'\n---- Bun! ----\n')
if trailer < 0:
    sys.exit('bun standalone trailer not found; unsupported build')

BASE = 8     # StringPointer offsets are relative to the blob start + 8
STRIDE = 52  # sizeof(CompiledModuleGraphFile)
ROOT = '/$bunfs/root/'


def u32(o):
    return struct.unpack('<I', data[o:o + 4])[0]


def name_at(p):
    """Return the module name if a valid graph record starts at p."""
    if p < 0 or p + STRIDE > len(data):
        return None
    off, ln = u32(p), u32(p + 4)
    if not (5 <= ln <= 200):
        return None
    s = data[off + BASE:off + BASE + ln]
    if not s.startswith(ROOT.encode()) or b'\0' in s:
        return None
    return s.decode()


anchor = None
for probe in range(trailer - STRIDE, trailer - 400000, -1):
    if name_at(probe) and name_at(probe + STRIDE) and name_at(probe + 2 * STRIDE):
        anchor = probe
        break
if anchor is None:
    sys.exit('module graph table not found')

start = anchor
while name_at(start - STRIDE):
    start -= STRIDE
end = anchor
while name_at(end + STRIDE):
    end += STRIDE
end += STRIDE

mods = []
for p in range(start, end, STRIDE):
    nm = name_at(p)[len(ROOT):]
    off, ln = u32(p + 8), u32(p + 12)
    mods.append((nm, data[off + BASE:off + BASE + ln]))
print(f'    module graph: {len(mods)} entries')

if not any(n == 'cli' for n, _ in mods):
    sys.exit('entrypoint "cli" missing from module graph')

ZSTD = b'\x28\xb5\x2f\xfd'
pat_tmp = re.compile(r'["\']/tmp/claude["\']')
pat_priv = re.compile(r'["\']/private/tmp/claude["\']')
pat_bridge = re.compile(r'`/tmp/claude-mcp-browser-bridge-\$\{([A-Za-z_$][\w$]*)\(\)\}`')
n_tmp = n_priv = n_bridge = n_js = 0

for nm, content in mods:
    out_name = 'cli.js' if nm == 'cli' else nm
    fp = os.path.join(out_dir, out_name)
    os.makedirs(os.path.dirname(fp), exist_ok=True)

    # Vendored asset bundles (mermaid.min.js etc.) are zstd blobs, not source.
    if content[:4] != ZSTD and (nm == 'cli' or nm.endswith(('.js', '.mjs'))):
        src = content.decode('utf-8')
        # /$bunfs/root/ is a virtual FS that only exists inside the packaged
        # binary. Rewrite to paths relative to each module's own directory:
        # import specifiers resolve directly, and the embedded-asset loader
        # joins its argument against import.meta.dirname, so both work.
        rel = './' if '/' not in out_name else '../' * out_name.count('/')
        src = src.replace(ROOT + 'cli"', rel + 'cli.js"').replace(ROOT, rel)

        # Termux app processes cannot write to /tmp; make the hardcoded paths
        # respect the CLAUDE_*TMPDIR env vars that the wrapper sets.
        n_tmp += len(pat_tmp.findall(src))
        n_priv += len(pat_priv.findall(src))
        src = pat_tmp.sub('(process.env.CLAUDE_TMPDIR||"/tmp/claude")', src)
        src = pat_priv.sub('(process.env.CLAUDE_TMPDIR||"/private/tmp/claude")', src)

        hit = pat_bridge.findall(src)
        if hit:
            n_bridge += len(hit)
            src = pat_bridge.sub(
                '`${process.env.CLAUDE_CODE_TMPDIR||process.env.TMPDIR||"/tmp"}'
                '/claude-mcp-browser-bridge-${' + hit[0] + '()}`', src)

        content = src.encode('utf-8')
        n_js += 1

    with open(fp, 'wb') as f:
        f.write(content)

print(f'    wrote {len(mods)} files ({n_js} js)')
print(f'    patched: sandbox tmp allowlist ({n_tmp + n_priv} occurrences)')
print(f'    patched: browser bridge tmpdir ({n_bridge} occurrences)')
if not n_tmp and not n_priv:
    print('    note: tmp allowlist target not found (likely refactored upstream)')
EXTRACT

        # Bun resolves node builtins and every bundled dep itself, so there is
        # nothing to npm install here.
        cat > "$CLAUDE_PKG_DIR/package.json" <<'PKG'
{
  "name": "claude-code-termux-runtime",
  "version": "0.0.0",
  "private": true,
  "type": "module"
}
PKG
    fi

    step "claude 4/4" "Writing wrapper..."
    mkdir -p "$USER_BIN"
    cat > "$USER_BIN/claude" <<WRAPPER
#!/usr/bin/env bash
# USE_BUILTIN_RIPGREP=0: the bundled rg vendor path isn't shipped with the
# unpacked module graph, so defer to the Termux pkg \`rg\` on PATH.
# CLAUDE_*TMPDIR: cli.js is patched to honor these; Termux has no writable
# /tmp in app context, so anchor them under \$PREFIX/tmp.
TMPDIR="\${TMPDIR:-$PREFIX/tmp}"
CLAUDE_CODE_TMPDIR="\${CLAUDE_CODE_TMPDIR:-\$TMPDIR}"
CLAUDE_TMPDIR="\${CLAUDE_TMPDIR:-\$TMPDIR/claude}"
mkdir -p "\$CLAUDE_TMPDIR"
CA_BUNDLE="\${SSL_CERT_FILE:-$PREFIX/etc/tls/cert.pem}"
exec env USE_BUILTIN_RIPGREP=0 DISABLE_AUTOUPDATER=1 DISABLE_INSTALLATION_CHECKS=1 \\
    TMPDIR="\$TMPDIR" CLAUDE_CODE_TMPDIR="\$CLAUDE_CODE_TMPDIR" CLAUDE_TMPDIR="\$CLAUDE_TMPDIR" \\
    SSL_CERT_FILE="\$CA_BUNDLE" NODE_EXTRA_CA_CERTS="\$CA_BUNDLE" \\
    bun "$CLAUDE_CLI" "\$@"
WRAPPER
    chmod +x "$USER_BIN/claude"

    echo "$INSTALL_TAG" > "$CLAUDE_VERSION_MARKER"
}

add_block_to_rc() {
    local rc="$1" block="$2" marker="$3"
    if [ -f "$rc" ] && grep -qF "$marker" "$rc"; then
        echo "    $rc: already configured"
        return
    fi
    mkdir -p "$(dirname "$rc")"
    printf '\n%s\n' "$block" >> "$rc"
    echo "    $rc: added"
}

setup_tmpdir_env() {
    section "Claude tmpdir"

    local zshenv_block sh_block fish_block
    zshenv_block="$TMPDIR_MARKER_BEGIN
# On Termux/Android, /tmp is not writable by app processes.
# ~/.zshenv is used because Claude Code launches non-interactive zsh shells.
if [ -n \"\${PREFIX:-}\" ] && [ -d \"\$PREFIX/tmp\" ]; then
    export TMPDIR=\"\${TMPDIR:-\$PREFIX/tmp}\"
    export CLAUDE_CODE_TMPDIR=\"\${CLAUDE_CODE_TMPDIR:-\$TMPDIR}\"
    export CLAUDE_TMPDIR=\"\${CLAUDE_TMPDIR:-\$TMPDIR/claude}\"
fi
$TMPDIR_MARKER_END"

    sh_block="$TMPDIR_MARKER_BEGIN
# Keep interactive shells aligned with the Termux TMPDIR workaround.
if [ -n \"\${PREFIX:-}\" ] && [ -d \"\$PREFIX/tmp\" ]; then
    export TMPDIR=\"\${TMPDIR:-\$PREFIX/tmp}\"
    export CLAUDE_CODE_TMPDIR=\"\${CLAUDE_CODE_TMPDIR:-\$TMPDIR}\"
    export CLAUDE_TMPDIR=\"\${CLAUDE_TMPDIR:-\$TMPDIR/claude}\"
fi
$TMPDIR_MARKER_END"

    fish_block="$TMPDIR_MARKER_BEGIN
# Keep Fish shells aligned with the Termux TMPDIR workaround.
if set -q PREFIX; and test -d \"\$PREFIX/tmp\"
    if test -z \"\$TMPDIR\"
        set -gx TMPDIR \"\$PREFIX/tmp\"
    end
    if test -z \"\$CLAUDE_CODE_TMPDIR\"
        set -gx CLAUDE_CODE_TMPDIR \"\$TMPDIR\"
    end
    if test -z \"\$CLAUDE_TMPDIR\"
        set -gx CLAUDE_TMPDIR \"\$TMPDIR/claude\"
    end
end
$TMPDIR_MARKER_END"

    add_block_to_rc "$HOME/.zshenv" "$zshenv_block" "$TMPDIR_MARKER_BEGIN"
    add_block_to_rc "$HOME/.zshrc" "$sh_block" "$TMPDIR_MARKER_BEGIN"
    add_block_to_rc "$HOME/.bashrc" "$sh_block" "$TMPDIR_MARKER_BEGIN"
    add_block_to_rc "$HOME/.config/fish/config.fish" "$fish_block" "$TMPDIR_MARKER_BEGIN"
}

setup_shell_path() {
    section "Shell PATH"
    case ":${PATH:-}:" in
        *":$USER_BIN:"*) echo "    current session PATH already includes $USER_BIN" ;;
        *) echo "    current session PATH will include $USER_BIN after reloading your shell" ;;
    esac

    local sh_block fish_block
    sh_block="$PATH_MARKER_BEGIN
case \":\$PATH:\" in
    *\":\$HOME/.local/bin:\"*) ;;
    *) export PATH=\"\$HOME/.local/bin:\$PATH\" ;;
esac
$PATH_MARKER_END"

    fish_block="$PATH_MARKER_BEGIN
if not contains \"\$HOME/.local/bin\" \$PATH
    set -gx PATH \"\$HOME/.local/bin\" \$PATH
end
$PATH_MARKER_END"

    add_block_to_rc "$HOME/.bashrc" "$sh_block" "$PATH_MARKER_BEGIN"
    add_block_to_rc "$HOME/.zshrc" "$sh_block" "$PATH_MARKER_BEGIN"
    add_block_to_rc "$HOME/.config/fish/config.fish" "$fish_block" "$PATH_MARKER_BEGIN"
}

if [ "$action" = "uninstall" ]; then
    section "Uninstall Claude Code"
    for p in "$USER_BIN/claude" "$CLAUDE_PKG_DIR"; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        rm -rf "$p"
        echo "    removed $p"
    done
    printf '\nDone. ~/.claude and rc-file entries left intact.\n'
    exit 0
fi

check_prereqs
install_claude
setup_tmpdir_env
setup_shell_path

printf '\nDone.\n'
case ":${PATH:-}:" in
    *":$USER_BIN:"*) ;;
    *)
        case "$(basename "${SHELL:-}")" in
            bash) echo "  (Open a new shell or: source ~/.bashrc)" ;;
            zsh)  echo "  (Open a new shell or: source ~/.zshrc)" ;;
            fish) echo "  (Open a new shell or: source ~/.config/fish/config.fish)" ;;
            *)    echo "  (Open a new shell to pick up the updated PATH)" ;;
        esac
        ;;
esac
echo "  Run: claude"
