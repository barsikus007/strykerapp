#!/bin/bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib/common.sh"

need_root

mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/artifacts.tsv"

started=$(date -u +%s)

if [ "${CHROOT_ONLY:-0}" = 1 ]; then
	say "1/4  the VM kernel -- skipped (CHROOT_ONLY=1)"
	say "2/4  the UML kernel -- skipped (CHROOT_ONLY=1)"
	say "3/4  the Debian system"
	CHROOT_ONLY=1 bash "$HERE/rootfs/build.sh"
	say "4/4  the out-of-tree driver packages -- skipped (CHROOT_ONLY=1)"

	say "auditing what is about to be published"
	bash "$HERE/rootfs/audit.sh" "$WORK_DIR/rootfs/tree"

	elapsed=$(( $(date -u +%s) - started ))
	say "done in $((elapsed / 60))m $((elapsed % 60))s"
	column -t -s'	' "$OUT_DIR/artifacts.tsv" 2>/dev/null || cat "$OUT_DIR/artifacts.tsv"
	printf '\n%s\n' "next: images/publish.sh <base-url>   (writes the manifest block)"
	exit 0
fi

say "1/4  the VM kernel"
bash "$HERE/kernel/build-vm.sh"

if [ "${SKIP_UML:-0}" = 1 ]; then
	say "2/4  the UML kernel -- skipped (SKIP_UML=1)"
else
	say "2/4  the UML kernel"
	if ! bash "$HERE/kernel/build-uml.sh"; then
		warn "the UML kernel did not build. The VM engine's artifacts are"
		warn "unaffected; set SKIP_UML=1 to stop trying, or read the error above."
	fi
fi

say "3/4  the Debian system"
bash "$HERE/rootfs/build.sh"

say "4/4  the out-of-tree driver packages"
if ! bash "$HERE/drivers/add-driver.sh" all; then
	warn "some drivers did not build -- see above. These are optional packages,"
	warn "not part of any image, so the rest of the release is still complete."
fi

say "auditing what is about to be published"
bash "$HERE/rootfs/audit.sh" "$OUT_DIR/vm/rootfs.img"

elapsed=$(( $(date -u +%s) - started ))
say "done in $((elapsed / 60))m $((elapsed % 60))s"
column -t -s'	' "$OUT_DIR/artifacts.tsv" 2>/dev/null || cat "$OUT_DIR/artifacts.tsv"
printf '\n%s\n' "next: images/publish.sh <base-url>   (writes the manifest block)"
