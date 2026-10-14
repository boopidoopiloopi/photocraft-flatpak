#!/usr/bin/env bash
#
# craft-apps installer
#
#   bash -c "$(curl -sSL https://raw.githubusercontent.com/USER/REPO/main/install.sh)"
#
# Builds a local flatpak repo from GitHub release bundles of the ArtCraft
# apps, installs the selected apps from it (user install), and hooks
# `flatpak update` in bash + fish so the repo refreshes from GitHub first.
# Re-running the installer on the same directory lets you add/remove apps.

set -eo pipefail

GITHUB_ORG="storytold"
REMOTE_NAME="craft-apps"
DEFAULT_DIR="$PWD/craft-apps"

CAT_NAMES=(photocraft vectorcraft filmcraft lightcraft effectcraft cadcraft)
CAT_LABELS=(
    "PhotoCraft  (image editing / Photoshop alternative)"
    "VectorCraft (vector illustration)"
    "FilmCraft   (video editing / Premiere alternative)"
    "LightCraft  (photo library & raw development)"
    "EffectCraft (motion graphics & VFX)"
    "CADCraft    (CAD & drafting / AutoCAD alternative)"
)

if [[ -t 1 ]]; then
    C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'; C_R=$'\033[1;31m'; C_0=$'\033[0m'
else
    C_G=""; C_Y=""; C_R=""; C_0=""
fi
info() { printf '%s==>%s %s\n' "$C_G" "$C_0" "$*"; }
warn() { printf '%s==> %s%s\n' "$C_Y" "$C_0" "$*"; }
die()  { printf '%s==> ERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; exit 1; }

ask() { # ask PROMPT VARNAME — prints the prompt itself so it always shows
    local __in=""
    if [[ -w /dev/tty ]]; then
        printf '%s' "$1" > /dev/tty
        read -r __in < /dev/tty || __in=""
    else
        printf '%s' "$1" >&2
        read -r __in || __in=""
    fi
    printf -v "$2" '%s' "$__in"
}

in_list() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [[ "$x" == "$needle" ]] && return 0; done
    return 1
}

# --------------------------------------------------------------- deps ------
ensure_deps() {
    local -a missing=()
    local c
    for c in flatpak curl jq ostree; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [[ ${#missing[@]} -eq 0 ]] && return

    info "Installing missing tools: ${missing[*]}"
    local -a sudocmd=()
    if [[ $EUID -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 \
            || die "Need root or sudo to install: ${missing[*]}"
        sudocmd=(sudo)
    fi
    if command -v pacman >/dev/null 2>&1; then
        "${sudocmd[@]}" pacman -S --needed --noconfirm "${missing[@]}"
    elif command -v apt-get >/dev/null 2>&1; then
        "${sudocmd[@]}" apt-get update -y
        "${sudocmd[@]}" apt-get install -y "${mсонissing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        "${sudocmd[@]}" dnf install -y "${missing[@]}"
    elif command -v zypper >/dev/null 2>&1; then
        "${sudocmd[@]}" zypper --non-interactive install "${missing[@]}"
    else
        die "Unknown package manager — install manually: ${missing[*]}"
    fi
}

# ----------------------------------------------------------- selection -----
# yay-style: "1 2 3", "1-3", "^4"; commas optional; empty input = all
parse_selection() { # $1=input  $2=count  -> SELECTED=(1-based indices)
    local input="$1" n="$2"
    local -a tokens
    local token t lo hi i have_incl=0 is_excl
    local -A incl=() excl=()
    SELECTED=()
    read -ra tokens <<< "${input//,/ }"

    for token in "${tokens[@]}"; do
        [[ -z "$token" ]] && continue
        t="$token"
        is_excl=0
        if [[ "$t" == ^* ]]; then is_excl=1; t="${t:1}"; fi
        if [[ ! "$t" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
            die "Invalid selection: '$token'  (use e.g. 1 2 3, 1-3 or ^4)"
        fi
        if [[ "$t" == *-* ]]; then
            lo="${t%-*}"; hi="${t#*-}"
            if (( lo > hi )); then i=$lo; lo=$hi; hi=$i; fi
        else
            lo=$t; hi=$t
        fi
        if (( lo < 1 || hi > n )); then
            die "Out of range: '$token'  (pick 1-$n)"
        fi
        for ((i = lo; i <= hi; i++)); do
            if (( is_excl )); then excl[$i]=1; else incl[$i]=1; have_incl=1; fi
        done
    done
    if (( ! have_incl )); then
        for ((i = 1; i <= n; i++)); do incl[$i]=1; done
    fi
    for ((i = 1; i <= n; i++)); do
        if [[ -n "${incl[$i]:-}" && -z "${excl[$i]:-}" ]]; then
            SELECTED+=("$i")
        fi
    done
    [[ ${#SELECTED[@]} -eq 0 ]] && die "Nothing selected."
}

# -------------------------------------------------------------- repo -------
repo_appids_for() { # app slug -> app IDs of that app in the local repo
    ostree --repo=repo refs 2>/dev/null \
        | awk -F/ -v a="$1" '$1 == "app" && $2 ~ ("\\." a "$") {print $2}' \
        | sort -u || true
}
repo_refs_for() { # app slug -> full ostree refs of that app
    ostree --repo=repo refs 2>/dev/null \
        | awk -F/ -v a="$1" '$1 == "app" && $2 ~ ("\\." a "$")' || true
}

# ---------------------------------------------------------------- main -----
ensure_deps

echo
echo "  ─── craft-apps installer ───"
echo "  Local flatpak repo for the ArtCraft apps (github.com/$GITHUB_ORG)"
echo
ask "Install directory [$DEFAULT_DIR]: " DIR_IN
DIR="${DIR_IN:-$DEFAULT_DIR}"
DIR="${DIR/#\~/$HOME}"
DIR="${DIR%/}"
mkdir -p "$DIR"
DIR="$(cd "$DIR" && pwd)"
cd "$DIR"

NEW_INSTALL=1
if [[ -f apps.list || -d repo ]]; then NEW_INSTALL=0; fi

CURRENT=()
if [[ -f apps.list ]]; then
    mapfile -t CURRENT < <(grep -v '^[[:space:]]*$' apps.list 2>/dev/null || true)
fi

echo
if [[ $NEW_INSTALL -eq 1 ]]; then
    info "Which apps should this repo track?"
    echo "    (e.g. '1 2 3', '1-3' or '^4' — press Enter for all)"
else
    info "Existing craft-apps repo found. Current apps are marked [x]."
    echo "    Choose what to KEEP (e.g. '1 3', '^2' — press Enter to keep current)."
fi
echo
for i in "${!CAT_NAMES[@]}"; do
    mark="[ ]"
    if in_list "${CAT_NAMES[$i]}" "${CURRENT[@]}"; then mark="[x]"; fi
    printf '   %s %d) %s\n' "$mark" "$((i + 1))" "${CAT_LABELS[$i]}"
done
echo
ask "Apps (eg: 1 2 3, 1-3 or ^4): " SEL_IN

if [[ -z "${SEL_IN// /}" && $NEW_INSTALL -eq 0 && ${#CURRENT[@]} -gt 0 ]]; then
    SELECTED=()
    for i in "${!CAT_NAMES[@]}"; do
        if in_list "${CAT_NAMES[$i]}" "${CURRENT[@]}"; then SELECTED+=("$((i + 1))"); fi
    done
else
    parse_selection "$SEL_IN" "${#CAT_NAMES[@]}"
fi

DESIRED=()
for i in "${SELECTED[@]}"; do
    DESIRED+=("${CAT_NAMES[$((i - 1))]}")
done

ADD=(); REMOVE=()
for app in "${DESIRED[@]}"; do
    in_list "$app" "${CURRENT[@]}" || ADD+=("$app")
done
if [[ $NEW_INSTALL -eq 0 ]]; then
    for app in "${CURRENT[@]}"; do
        in_list "$app" "${DESIRED[@]}" || REMOVE+=("$app")
    done
fi

echo
info "Plan for $DIR"
echo "    repo tracks : ${DESIRED[*]}"
[[ ${#ADD[@]} -gt 0 ]]    && echo "    add+install : ${ADD[*]}"
[[ ${#REMOVE[@]} -gt 0 ]] && echo "    remove      : ${REMOVE[*]}"
[[ $NEW_INSTALL -eq 1 ]]  && echo "    runtime     : org.freedesktop.Platform (from Flathub if missing)"
echo
ask "Proceed? [Y/n] " YN
[[ "$YN" =~ ^[Nn] ]] && die "Aborted."

printf '%s\n' "${DESIRED[@]}" > apps.list

# ---------------------------------------------------------------- files ----
info "writing refresh-craft-apps.sh"
cat > refresh-craft-apps.sh <<'REFRESH_EOF'
#!/usr/bin/env bash
# Refresh the local craft-apps flatpak repo from the latest GitHub releases
# of the apps listed in apps.list (one app name per line).
#
# Called automatically by the `flatpak` shell wrapper on `flatpak update`;
# you can also run it by hand. Best-effort: a failed download skips that app.
set -eo pipefail
cd "$(dirname "$0")"

REPO=repo

case "$(uname -m)" in
    x86_64)  ARCH=x86_64  ;;
    aarch64) ARCH=aarch64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

mapfile -t APPS < <(grep -v '^[[:space:]]*$' apps.list 2>/dev/null || true)
if [[ ${#APPS[@]} -eq 0 ]]; then
    echo "apps.list is empty - nothing to do."
    exit 0
fi

mkdir -p downloads
if [[ ! -d "$REPO/objects" ]]; then
    ostree --repo="$REPO" init --mode=archive-z2
fi

for app in "${APPS[@]}"; do
    echo "== $app: looking up latest release"
    url="$(curl -fsSL "https://api.github.com/repos/storytold/$app/releases/latest" \
        | jq -r --arg arch "$ARCH" \
            '.assets[]
             | select(.name | endswith("linux-\($arch).flatpak"))
             | .browser_download_url' \
        | head -n1)" || true
    if [[ -z "${url:-}" ]]; then
        echo "!! $app: no linux-$ARCH .flatpak asset found (or rate-limited) - skipping" >&2
        continue
    fi

    file="downloads/$(basename "$url")"
    if [[ -f "$file" ]]; then
        echo "== $app: already have $(basename "$url")"
    else
        echo "== $app: downloading $(basename "$url")"
        if ! curl -fL --progress-bar -o "$file.part" "$url"; then
            echo "!! $app: download failed - skipping" >&2
            rm -f "$file.part"
            continue
        fi
        mv "$file.part" "$file"
        echo "== $app: importing into repo"
        flatpak build-import-bundle "$REPO" "$file"
    fi
done

echo "== refreshing repo metadata"
flatpak build-update-repo "$REPO"
REFRESH_EOF
chmod +x refresh-craft-apps.sh

info "writing flatpak-wrapper.sh"
cat > flatpak-wrapper.sh <<'WRAPPER_EOF'
# >>> craft-apps flatpak wrapper >>>
# Wraps `flatpak` so `flatpak update` first refreshes the local craft-apps
# repo (see refresh-craft-apps.sh in the same directory).
_craft_app_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
flatpak() {
    if [[ "${1:-}" == update || "${1:-}" == upgrade ]] \
       && [[ -x "$_craft_app_dir/refresh-craft-apps.sh" ]]; then
        "$_craft_app_dir/refresh-craft-apps.sh" || return
    fi
    command flatpak "$@"
}
# <<< craft-apps flatpak wrapper <<<
WRAPPER_EOF

# -------------------------------------------------------------- removals ---
if [[ ${#REMOVE[@]} -gt 0 ]]; then
    echo
    ask "Also uninstall removed apps from this system? [y/N] " uninst
    for app in "${REMOVE[@]}"; do
        while IFS= read -r appid; do
            if [[ "$uninst" =~ ^[Yy] ]] && flatpak --user info "$appid" >/dev/null 2>&1; then
                info "uninstalling $appid"
                flatpak uninstall --user -y "$appid" || warn "could not uninstall $appid"
            fi
        done < <(repo_appids_for "$app")
        while IFS= read -r ref; do
            ostree --repo=repo refs --delete "$ref"
        done < <(repo_refs_for "$app")
        rm -f downloads/"$app"-*.flatpak downloads/"$app"-*.part
    done
    info "pruning repo"
    ostree --repo=repo prune
    flatpak build-update-repo repo
fi

# ------------------------------------------------- fetch & install news ----
if [[ ${#ADD[@]} -gt 0 ]]; then
    echo
    ./refresh-craft-apps.sh
fi

info "making sure Flathub is available (for the freedesktop runtime)"
flatpak --user remote-add --if-not-exists flathub \
    https://dl.flathub.org/repo/flathub.flatpakrepo

info "registering local repo as remote '$REMOTE_NAME'"
flatpak --user remote-delete "$REMOTE_NAME" 2>/dev/null || true
flatpak --user remote-add --no-gpg-verify "$REMOTE_NAME" "file://$DIR/repo"

if [[ ${#ADD[@]} -gt 0 ]]; then
    for app in "${ADD[@]}"; do
        found=0
        while IFS= read -r appid; do
            found=1
            if flatpak --user info "$appid" >/dev/null 2>&1; then
                info "$appid is already installed"
            else
                info "installing $appid"
                flatpak install --user -y "$REMOTE_NAME" "$appid"
            fi
        done < <(repo_appids_for "$app")
        [[ $found -eq 0 ]] && warn "$app: no release yet — retried on every 'flatpak update'"
    done
fi

# ----------------------------------------------------------- shell hooks ---
BASHRC="$HOME/.bashrc"
touch "$BASHRC"
sed -i '/^# >>> craft-apps flatpak wrapper >>>$/,/^# <<< craft-apps flatpak wrapper <<<$/{d}' "$BASHRC"
{
    echo
    echo '# >>> craft-apps flatpak wrapper >>>'
    echo "if [ -f \"$DIR/flatpak-wrapper.sh\" ]; then . \"$DIR/flatpak-wrapper.sh\"; fi"
    echo '# <<< craft-apps flatpak wrapper <<<'
} >> "$BASHRC"
info "bash wrapper hooked into $BASHRC"

if command -v fish >/dev/null 2>&1 || [[ -d "$HOME/.config/fish" ]]; then
    FISH_FILE="$HOME/.config/fish/functions/flatpak.fish"
    mkdir -p "$(dirname "$FISH_FILE")"
    if [[ -f "$FISH_FILE" ]] && ! grep -q 'craft-apps flatpak wrapper' "$FISH_FILE"; then
        cp "$FISH_FILE" "$FISH_FILE.bak"
        warn "existing $FISH_FILE backed up to $FISH_FILE.bak"
    fi
    cat > "$FISH_FILE" <<FISH_EOF
# >>> craft-apps flatpak wrapper >>>
function flatpak --wraps=flatpak --description 'flatpak wrapper: refresh craft-apps repo before update'
    if set -q argv[1]; and contains -- "\$argv[1]" update upgrade
        "$DIR/refresh-craft-apps.sh"; or return \$status
    end
    command flatpak \$argv
end
# <<< craft-apps flatpak wrapper <<<
FISH_EOF
    info "fish wrapper written to $FISH_FILE"
else
    warn "fish not found — bash wrapper only"
fi

# ------------------------------------------------------------- summary -----
echo
info "Done!"
echo "    directory : $DIR"
echo "    apps      : ${DESIRED[*]}"
flatpak --user remote-ls --app "$REMOTE_NAME" 2>/dev/null | sed 's/^/    /' || true
echo
echo "  From now on, just run:  flatpak update"
echo "  (the shell wrapper refreshes this repo from GitHub first)"
echo "  Re-run this installer to add or remove apps."
echo "  Open a new terminal so the wrapper is loaded."
