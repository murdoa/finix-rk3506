#!/usr/bin/env bash
# Drop-in replacement for setup-etc.pl — eliminates perl (~51 MiB) from the
# system closure. Implements the same /etc/static symlink management logic.
set -euo pipefail

etc="$1"
static="/etc/static"

atomic_symlink() {
    local source="$1" target="$2" tmp="$target.tmp"
    rm -f "$tmp"
    ln -s "$source" "$tmp" && mv "$tmp" "$target"
}

is_static() {
    local path="$1"
    if [ -L "$path" ]; then
        local target
        target="$(readlink "$path")"
        [[ "$target" == /etc/static/* ]]
        return
    fi
    if [ -d "$path" ]; then
        local entry
        for entry in "$path"/*; do
            [ -e "$entry" ] || [ -L "$entry" ] || continue
            is_static "$entry" || return 1
        done
        return 0
    fi
    return 1
}

# Atomically update /etc/static to point at current configuration's etc.
atomic_symlink "$etc" "$static"

# Remove dangling symlinks that point to /etc/static from previous configs.
find /etc -path /etc/nixos -prune -o -type l -print 2>/dev/null | while IFS= read -r link; do
    target="$(readlink "$link" 2>/dev/null)" || continue
    if [[ "$target" == "$static"* ]]; then
        relative="${link#/etc/}"
        if [ ! -L "$static/$relative" ] && [ ! -e "$static/$relative" ]; then
            echo "removing obsolete symlink '$link'..." >&2
            rm -f "$link"
        fi
    fi
done

# Track copied files for cleanup across generations.
old_copied=()
if [ -f /etc/.clean ]; then
    mapfile -t old_copied < /etc/.clean
fi

# Collect list of files we create, for the .clean tracker.
clean_tmp="$(mktemp)"
trap 'rm -f "$clean_tmp"' EXIT

# Build set of created files for later diffing against old_copied.
created_tmp="$(mktemp)"

# For every file in the etc tree, create a corresponding symlink in /etc.
while IFS= read -r entry; do
    fn="${entry#"$etc"/}"
    [ -n "$fn" ] || continue

    target="/etc/$fn"
    echo "$fn" >> "$created_tmp"
    mkdir -p "$(dirname "$target")"

    if [ -L "$entry" ] && [ -d "$target" ] && [ ! -L "$target" ]; then
        if is_static "$target"; then
            rm -rf "$target"
        else
            echo "$target directory contains user files. Symlinking may fail." >&2
        fi
    fi

    if [ -f "$entry.mode" ]; then
        mode="$(cat "$entry.mode")"
        if [ "$mode" = "direct-symlink" ]; then
            src_link="$(readlink "$static/$fn" 2>/dev/null)" || true
            dst_link="$(readlink "$target" 2>/dev/null)" || true
            if [ ! -L "$target" ] || [ "$src_link" != "$dst_link" ]; then
                atomic_symlink "$(readlink "$static/$fn")" "$target"
            fi
        else
            uid="$(cat "$entry.uid")"
            gid="$(cat "$entry.gid")"
            cp "$static/$fn" "$target.tmp"
            # Resolve user/group names to IDs if not numeric
            if [[ ! "$uid" =~ ^\+ ]]; then
                uid="$(id -u "$uid" 2>/dev/null)" || uid=0
            else
                uid="${uid#+}"
            fi
            if [[ ! "$gid" =~ ^\+ ]]; then
                gid="$(getent group "$gid" 2>/dev/null | cut -d: -f3)" || gid=0
            else
                gid="${gid#+}"
            fi
            chown "$uid:$gid" "$target.tmp"
            chmod "$mode" "$target.tmp"
            mv "$target.tmp" "$target" || { echo "could not create target $target" >&2; rm -f "$target.tmp"; }
        fi
        echo "$fn" >> "$clean_tmp"
    elif [ -L "$entry" ]; then
        atomic_symlink "$static/$fn" "$target"
    fi
done < <(find "$etc" -mindepth 1)

# Delete files that were copied in a previous version but not in the current.
for fn in "${old_copied[@]}"; do
    [ -n "$fn" ] || continue
    if ! grep -qxF "$fn" "$created_tmp" 2>/dev/null; then
        echo "removing obsolete file '/etc/$fn'..." >&2
        rm -f "/etc/$fn"
    fi
done

# Rewrite /etc/.clean
sort "$clean_tmp" > /etc/.clean 2>/dev/null || true
rm -f "$created_tmp"

# Create /etc/NIXOS tag
touch /etc/NIXOS
