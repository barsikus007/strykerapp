package com.zalexdev.stryker.ota;

public final class StrykerEndpoints {

    public static final String REPO = com.zalexdev.stryker.BuildConfig.REPO;

    public static final String GITHUB_REPO = "https://github.com/" + REPO;

    public static final String MANIFEST_URL =
            "https://raw.githubusercontent.com/" + REPO + "/main/stryker_manifest.json";

    // Use the chroot pinned in the build's manifest if the remote fetch fails.
    // Keep the repository configurable so forks use their own release assets.
    public static final String FALLBACK_CHROOT_64 =
            GITHUB_REPO + com.zalexdev.stryker.BuildConfig.CHROOT_DOWNLOAD_PATH;

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
