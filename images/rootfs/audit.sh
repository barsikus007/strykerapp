#!/bin/bash
set -uo pipefail

TARGET=${1:?usage: audit.sh <image.ext4|tree>}
MNT=""
FOUND=0

cleanup() {
	[ -n "$MNT" ] && umount "$MNT" 2>/dev/null
	[ -n "$MNT" ] && rmdir "$MNT" 2>/dev/null
	return 0
}
trap cleanup EXIT

if [ -d "$TARGET" ]; then
	ROOT=$TARGET
elif [ -f "$TARGET" ]; then
	[ "$(id -u)" = 0 ] || { echo "audit.sh: mounting an image needs root" >&2; exit 2; }
	MNT=$(mktemp -d)
	mount -o loop,ro "$TARGET" "$MNT" || { echo "audit.sh: cannot mount $TARGET" >&2; exit 2; }
	ROOT=$MNT
else
	echo "audit.sh: no such image or tree: $TARGET" >&2
	exit 2
fi

hit() { printf '  FOUND  %s\n' "$*"; FOUND=$((FOUND + 1)); }
ok()  { printf '  ok     %s\n' "$*"; }

MD5MAP=$(mktemp)
cat "$ROOT"/var/lib/dpkg/info/*.md5sums 2>/dev/null > "$MD5MAP" || true
awk '/^Conffiles:/ { c = 1; next }
     /^[^ ]/       { c = 0 }
     c && NF >= 2  { p = $1; sub(/^\//, "", p); print $2, p }' \
	"$ROOT/var/lib/dpkg/status" 2>/dev/null >> "$MD5MAP" || true
trap 'cleanup; rm -f "$MD5MAP"' EXIT

stock() {
	local f=$1 rel want have
	rel=${f#"$ROOT"/}
	want=$(awk -v p="$rel" '$2 == p { print $1; exit }' "$MD5MAP")
	[ -n "$want" ] || return 1
	have=$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)
	[ "$want" = "$have" ]
}
changed_only() {
	local f
	while read -r f; do
		[ -n "$f" ] || continue
		stock "$f" || printf '%s\n' "$f"
	done
}

printf '\n== auditing %s ==\n\n' "$TARGET"

if [ -s "$ROOT/etc/machine-id" ]; then
	hit "/etc/machine-id is not empty: every install would share it"
else
	ok "machine-id empty"
fi

keys=$(ls "$ROOT"/etc/ssh/ssh_host_* 2>/dev/null | wc -l)
if [ "$keys" -gt 0 ]; then
	hit "$keys SSH host key(s) in /etc/ssh: every install would answer with the same key,"
	hit "  which makes the fingerprint the app pins worthless"
else
	ok "no SSH host keys (generated on first boot)"
fi

rootline=$(grep '^root:' "$ROOT/etc/shadow" 2>/dev/null | cut -d: -f2)
case "$rootline" in
	'!'*|'*'|'') ok "root account has no usable password" ;;
	*)           hit "root has a password hash in /etc/shadow, identical in every copy of this image" ;;
esac

sshcfg=$(cat "$ROOT"/etc/ssh/sshd_config "$ROOT"/etc/ssh/sshd_config.d/*.conf 2>/dev/null)
if printf '%s' "$sshcfg" | grep -qiE '^\s*PasswordAuthentication\s+yes'; then
	hit "sshd accepts password authentication"
else
	ok "sshd is key-only"
fi
if printf '%s' "$sshcfg" | grep -qiE '^\s*PermitRootLogin\s+yes'; then
	hit "sshd permits root login with a password"
else
	ok "root login is key-only"
fi

agents=$(grep -rlE '^[^#]*TCP-LISTEN:[0-9]+.*EXEC:' \
	"$ROOT/etc/systemd/system" "$ROOT/usr/local/sbin" "$ROOT/etc/init.d" 2>/dev/null | head -5)
if [ -n "$agents" ]; then
	hit "an unauthenticated shell listener: $(echo "$agents" | tr '\n' ' ')"
else
	ok "no unauthenticated shell listeners"
fi

for f in root/.ssh/authorized_keys root/.ssh/id_rsa root/.ssh/id_ed25519 \
         root/.bash_history root/.gnupg root/.netrc root/.git-credentials; do
	[ -e "$ROOT/$f" ] && hit "/$f exists"
done
hist=$(find "$ROOT" -maxdepth 3 -name '.*history' -size +0 2>/dev/null | head -5)
if [ -n "$hist" ]; then
	hit "non-empty shell history: $(echo "$hist" | tr '\n' ' ')"
else
	ok "no shell history"
fi

leaks=$(grep -rIlE '(^|[^0-9])(10\.[0-9]|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)[0-9]' \
	"$ROOT/etc" 2>/dev/null | changed_only | head -5)
if [ -n "$leaks" ]; then
	hit "private addresses in: $(echo "$leaks" | tr '\n' ' ')"
else
	ok "no private addresses under /etc"
fi

home=$(grep -rIlE '/home/[a-z]|/Users/[a-z]|/root/[a-z]' "$ROOT/etc" "$ROOT/root" \
	"$ROOT/usr/local" 2>/dev/null | changed_only | head -5)
if [ -n "$home" ]; then
	hit "a build machine's path in: $(echo "$home" | tr '\n' ' ')"
else
	ok "no build-host paths"
fi

for f in usr/bin/qemu-aarch64-static usr/sbin/policy-rc.d debootstrap; do
	[ -e "$ROOT/$f" ] && hit "/$f left from the build"
done
[ -e "$ROOT/usr/bin/qemu-aarch64-static" ] || ok "no qemu interpreter left in the tree"

for mods in "$ROOT"/lib/modules/*; do
	[ -d "$mods" ] || continue
	ver=$(cat "$mods/modules.builtin" >/dev/null 2>&1; basename "$mods")
	printf '  ..     module tree present: %s\n' "$ver"
done

lists=$(du -sm "$ROOT/var/lib/apt/lists" 2>/dev/null | cut -f1)
[ "${lists:-0}" -gt 5 ] && hit "apt lists are ${lists} MB (rebuilt by apt-get update in the guest)"
debs=$(ls "$ROOT"/var/cache/apt/archives/*.deb 2>/dev/null | wc -l)
[ "$debs" -gt 0 ] && hit "$debs cached .deb files"

printf '\n  contents: %s used, %s files\n' \
	"$(du -sh "$ROOT" 2>/dev/null | cut -f1)" \
	"$(find "$ROOT" 2>/dev/null | wc -l)"

printf '\n'
if [ "$FOUND" -gt 0 ]; then
	printf '%d finding(s). Fix with scrub.sh and rebuild the image.\n\n' "$FOUND"
	exit 1
fi
printf 'nothing personal found.\n\n'
