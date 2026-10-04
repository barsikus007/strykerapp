#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/common.sh"

BASE=${1:?usage: publish.sh <base-url>
  e.g. https://github.com/zalexdev/strykerapp/releases/download}
BASE=${BASE%/}
PUB=$OUT_DIR/publish
CHROOT_TAG=${CHROOT_TAG:-chroot-main}
ROOTLESS_TAG=${ROOTLESS_TAG:-rootless-main}
REPO=${REPO:-$IMAGES_DIR/..}
MANIFEST=${MANIFEST:-$REPO/stryker_manifest.json}
SUITE=${SUITE:-trixie}

[ -f "$OUT_DIR/artifacts.tsv" ] || die "nothing built yet -- run images/build-all.sh"

# Which core block this build is for, taken from the app rather than guessed.
# The app picks debian_v2 when its own versionCode clears that block's
# min_version_code and falls back to debian, so a release has to write the block
# the current build will actually read -- otherwise the manifest and the app
# disagree and the sha256 the app verifies against is the wrong one.
VERSION_CODE=${VERSION_CODE:-$(sed -n \
	's/.*versionCode[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' \
	"$REPO/app/build.gradle" 2>/dev/null | head -1)}
[ -n "$VERSION_CODE" ] || die "cannot read versionCode from $REPO/app/build.gradle;
  set VERSION_CODE explicitly"
if [ -z "${CHROOT_KEY+x}" ]; then
	if grep -q '"debian_v2"' "$MANIFEST" 2>/dev/null; then
		CHROOT_KEY=debian_v2
	else
		CHROOT_KEY=debian
	fi
fi
CHROOT_MIN_VC=${CHROOT_MIN_VC:-$VERSION_CODE}
CHROOT_VERSION=${CHROOT_VERSION:-chroot-debian-$SUITE}

rm -rf "$PUB"
mkdir -p "$PUB/$CHROOT_TAG" "$PUB/$ROOTLESS_TAG" "$PUB/drivers"

place() {
	local src=$1 dst=$2
	[ -f "$src" ] || return 1
	cp -f "$src" "$dst"
	printf '%s\n' "$dst"
}

say "collecting"
place "$OUT_DIR/chroot64-debian.tar.gz" "$PUB/$CHROOT_TAG/chroot64-debian.tar.gz" >/dev/null \
	|| warn "no chroot tarball"
place "$OUT_DIR/vm/Image"        "$PUB/$ROOTLESS_TAG/Image"       >/dev/null || warn "no VM kernel"
place "$OUT_DIR/vm/initrd.img"   "$PUB/$ROOTLESS_TAG/initrd.img"  >/dev/null || warn "no initrd"
place "$OUT_DIR/vm/rootfs.imgz"  "$PUB/$ROOTLESS_TAG/rootfs.imgz" >/dev/null || warn "no VM rootfs"
place "$OUT_DIR/uml/linux-uml"   "$PUB/$ROOTLESS_TAG/linux-uml"   >/dev/null || true
place "$OUT_DIR/uml/stub_exe"    "$PUB/$ROOTLESS_TAG/stub_exe"    >/dev/null || true
for f in qemu-system-aarch64 libslirp.so; do
	[ -f "$OUT_DIR/prebuilt/$f" ] && place "$OUT_DIR/prebuilt/$f" "$PUB/$ROOTLESS_TAG/$f" >/dev/null
done
cp -f "$OUT_DIR"/drivers/*.deb "$OUT_DIR"/drivers/Packages.gz "$PUB/drivers/" 2>/dev/null || true

{
	printf 'images        %s\n' "$(git -C "$IMAGES_DIR" rev-parse HEAD 2>/dev/null || echo 'not a git checkout')"
	printf 'kernel        %s\n' "$(cat "$OUT_DIR/vm/kernel.release" 2>/dev/null || echo '-')"
	printf 'kernel source %s\n' "$(cat "$OUT_DIR/vm/kernel.source" 2>/dev/null || echo '-')"
	printf 'suite         %s\n' "${SUITE:-trixie}"
	printf 'built         %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	printf 'reproduce     images/build-all.sh\n'
	printf '\n'
	printf 'Uncompressed checksums, for the artifacts that ship compressed --\n'
	printf 'the gzip wrapper is only reproducible with the same compressor\n'
	printf 'settings, the content underneath it always is:\n'
	for f in "$OUT_DIR/vm/rootfs.img"; do
		[ -f "$f" ] && printf '  %s  %s\n' "$(sha256_of "$f")" "$(basename "$f")"
	done
} > "$PUB/BUILDINFO.txt"
cp -f "$OUT_DIR/vm/Image.config" "$PUB/$ROOTLESS_TAG/Image.config" 2>/dev/null || true

say "checksums"
asset() {
	local file=$1 url=$2 indent=$3
	[ -f "$file" ] || return 1
	printf '%s"url": "%s",\n'    "$indent" "$url"
	printf '%s"sha256": "%s",\n' "$indent" "$(sha256_of "$file")"
	printf '%s"size": %s\n'      "$indent" "$(stat -c%s "$file")"
}

MF=$PUB/manifest-fragment.json

[ -f "$PUB/$CHROOT_TAG/chroot64-debian.tar.gz" ] || die \
	"no chroot tarball in $PUB/$CHROOT_TAG -- refusing to write a fragment
  with a half-populated core block"

{
	printf '{\n'
	printf '  "core": {\n'
	printf '    "%s": {\n' "$CHROOT_KEY"
	printf '      "min_version_code": %s,\n' "$CHROOT_MIN_VC"
	printf '      "version": "%s",\n' "$CHROOT_VERSION"
	printf '      "note": "Debian %s arm64. Same tree as the rootless VM image; drivers are built into the guest kernel, SSH is the transport.",\n' "$SUITE"
	printf '      "chroot64": {\n'
	asset "$PUB/$CHROOT_TAG/chroot64-debian.tar.gz" \
	      "$BASE/$CHROOT_TAG/chroot64-debian.tar.gz" '        '
	printf '      }\n'
	printf '    }\n'
	printf '  },\n'
	printf '  "rootless": {\n'
	printf '    "version": "%s",\n' "$ROOTLESS_TAG"
	for pair in "kernel:Image" "initrd:initrd.img" "rootfs:rootfs.imgz" \
	            "uml_kernel:linux-uml" "uml_stub:stub_exe"; do
		key=${pair%%:*}; name=${pair##*:}
		[ -f "$PUB/$ROOTLESS_TAG/$name" ] || continue
		printf '    "%s": {\n' "$key"
		asset "$PUB/$ROOTLESS_TAG/$name" "$BASE/$ROOTLESS_TAG/$name" '      '
		printf '    },\n'
	done
	printf '    "kernel_release": "%s"\n' "$(cat "$OUT_DIR/vm/kernel.release" 2>/dev/null || echo '')"
	printf '  }\n'
	printf '}\n'
} > "$MF"

if command -v python3 >/dev/null 2>&1; then
	python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$MF" \
		&& info "manifest fragment parses as JSON" \
		|| die "the fragment this wrote is not valid JSON: $MF"
fi

if [ "${APPLY:-0}" = 1 ]; then
	say "writing the core block into $MANIFEST"
	python3 "$IMAGES_DIR/lib/update-manifest.py" "$MANIFEST" \
		--core "$CHROOT_KEY" --fragment "$MF" ${DRY_RUN:+--dry-run}
fi

printf '\n'
find "$PUB" -type f -printf '%-52p %10s\n' | sort | sed 's/^/   /'
printf '\n%s\n' "manifest block: core.$CHROOT_KEY (min_version_code $CHROOT_MIN_VC)"
printf '%s\n' "Upload out/publish/<tag>/* to the matching release tag."
printf '%s\n' "APPLY=1 does the manifest write for you -- that is what CI uses, and it"
printf '%s\n' "is also the only way to get the sha256 right. Keep the legacy"
printf '%s\n' "core.chroot64/chroot32 keys as they are: builds below version 6 read"
printf '%s\n' "those directly and cannot be changed."
