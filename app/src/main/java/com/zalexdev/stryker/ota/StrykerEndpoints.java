package com.zalexdev.stryker.ota;

public final class StrykerEndpoints {

    public static final String REPO = com.zalexdev.stryker.BuildConfig.REPO;

    public static final String GITHUB_REPO = "https://github.com/" + REPO;

    public static final String MANIFEST_URL =
            "https://raw.githubusercontent.com/" + REPO + "/main/stryker_manifest.json";

    // Where a chroot published for this exact build lives. The Chroot workflow
    // names its release tag chroot-<versionCode>, so this cannot drift away
    // from what was actually built the way a hardcoded tag did: this constant
    // used to say chroot-main, so a 6.5 client whose manifest fetch failed
    // pulled the versionCode-600 tree and called it current.
    private static final String CHROOT_BASE = GITHUB_REPO + "/releases/download/chroot-";
    public static final String FALLBACK_CHROOT_64 =
            CHROOT_BASE + com.zalexdev.stryker.BuildConfig.VERSION_CODE
                    + "/chroot64-debian.tar.gz";

    // Deliberately a floating tag, unlike the chroot above. Nothing publishes a
    // per-version rootless release, so pinning these to a versionCode would
    // point at a tag that does not exist; rootless-main always resolves.
    private static final String ROOTLESS_BASE =
            GITHUB_REPO + "/releases/download/rootless-main/";
    public static final String FALLBACK_ROOTLESS_QEMU     = ROOTLESS_BASE + "qemu-system-aarch64";
    public static final String FALLBACK_ROOTLESS_KERNEL   = ROOTLESS_BASE + "Image";
    public static final String FALLBACK_ROOTLESS_LIBSLIRP = ROOTLESS_BASE + "libslirp.so";
    public static final String FALLBACK_ROOTLESS_INITRD   = ROOTLESS_BASE + "initrd.img";
    public static final String FALLBACK_ROOTLESS_ROOTFS   = ROOTLESS_BASE + "rootfs.imgz";

    public static final String PREFS = "stryker_ota";

    private StrykerEndpoints() {
    }
}
