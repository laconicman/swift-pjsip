# Local patches applied to PJSIP before building

`build.sh` applies **every `*.patch` sitting directly in this directory** to the extracted
pjproject tree, in sorted order, before `config_site` is written — see `apply_patches()` in
`../build.sh`. A patch that will not apply is a **hard build failure**, deliberately: the failure
mode this directory exists to prevent is a rebuild silently dropping a fix upstream has not taken.

- Idempotent — a reverse dry-run that succeeds means the hunk is already present, so re-running a
  phase over an already-patched tree is a no-op.
- Every applied patch is recorded with its SHA-256 in `.build-pjsip/meta/patches.txt`, and
  `build.sh notes` reproduces that list in the release notes.
- `--patches <dir>` (or `PATCHES_DIR=`) points the step elsewhere — at `historical/`, or at an
  empty directory to build **unpatched upstream**, which is how you check retirement criterion 1
  below.
- `historical/` is **not** applied. It holds patches kept for provenance only.

## `iphone17-darwin-dev-stride.patch`

Applies to **pjproject master** (verified against `288de6142`, 2026-08-19 — the commit the current
artifact is pinned to). Touches one file, `pjmedia/src/pjmedia-videodev/darwin_dev.m`.

Fixes two stride bugs in the capture callback, both instances of Apple QA1829 ("always query
per-plane bytes-per-row; never derive one plane's stride from another, and never assume
`bytesPerRow == width * bpp`"):

1. **Chroma plane walked with the luma stride.** The clipped NV12→I420 path advanced with
   `p += (stride - vid_size.w)` where `stride` is `CVPixelBufferGetBytesPerRowOfPlane(img, 0)`
   while `p` walks plane 1. Now reads plane 1's own stride.
2. **Packed/BGRA copied as one flat block.** `pj_memcpy(capture_buf, base, frame_size)` ignored
   `CVPixelBufferGetBytesPerRow` entirely, so a padded row was read across its own boundary. Now
   copies row by row, bounded by `min(src_stride, dst_stride)` and
   `min(CVPixelBufferGetHeight, frame_size / bytes_per_row)`.

Symptom when absent: horizontal repetition / banding on the iPhone 17 front camera, whose stride is
much larger than `width × bpp`.

### What the forward-port changed relative to the 2.16 original

The original (now `historical/2.16-iphone17-darwin-dev-stride.patch`, recovered 2026-08-19 by
diffing `buildPJwVideoPatch/pjproject-2.16p.zip` against a clean 2.16 export) also carried a
`USE_HORIZON_LEVEL` half — gravity-relative capture via `AVCaptureDeviceRotationCoordinator`.
**That half is dropped**, because master now does the same job properly and with more care:
`cam_portrait_angle` is calibrated from the coordinator plus physical device orientation and cached
for the stream's lifetime (`darwin_dev.m:139`, `:1343-1429`, from
[#5017](https://github.com/pjsip/pjproject/pull/5017) / [#5046](https://github.com/pjsip/pjproject/pull/5046)).
Re-adding our cruder version would regress it.

One change goes **beyond** the original, from a DeepWiki review of the forward-port
([consult](https://deepwiki.com/search/in-pjmediasrcpjmedia-videodevd_782fdd60-f991-4f31-96e5-9b484cf75135?mode=deep)):
`need_clip` is computed from the **luma** stride only, and the `!need_clip` chroma path does a flat
strideless copy. Fixing only the clipped branch leaves the bug alive whenever the luma plane is
unpadded but the chroma plane is not — CoreVideo pads planes independently, which is the whole
reason `CVPixelBufferGetBytesPerRowOfPlane` takes a plane index. The patch therefore adds
`need_clip_uv`, derived from the chroma stride, and gates the chroma branch on it. When the strides
agree the behaviour is byte-identical to before.

The same review confirmed the packed row loop cannot overrun either buffer: `capture_buf` is
allocated exactly `frame_size` (`darwin_dev.m:956`) with `frame_size = bytes_per_row * size.h`
(`:825-826`, `:865-866`), so `dst_rows` is exactly `size.h` and the destination offset is bounded by
`frame_size`. Residual (pre-existing, not a regression): when `dst_stride > src_stride` the trailing
bytes of each destination row keep stale data.

### Upstream status — the bug is reported, closed, and still live

Reported by us as **[pjproject#4817](https://github.com/pjsip/pjproject/issues/4817)** ("[pjmedia]
Incorrect video from front camera iPhone 17", 2026-02-24 — the same day the 2.16 archive was built).
The report root-causes both copy paths, cites QA1829, and attaches a working `darwin_dev.m`.

**Closed `COMPLETED` 2026-02-27** with one comment: *"Check #4751"*. That closure does not cover the
stride bug:

| Claim | Verified 2026-08-19 against `288de6142` |
|---|---|
| #4751 fixes the stride bug | **No.** `30838cf58` changes 36 lines of `darwin_dev.m`, none touching `stride` or `BytesPerRow`. It is a capture-angle fix |
| `master` has the stride fix | **No.** `p += (stride - stream->vid_size.w)` at :669 and `pj_memcpy(…, frame_size)` at :682, both still present |
| `2.17` has it | **No.** Tagged 2026-04-22, before all of it |

The likely explanation is benign: #4817 described **two** symptoms — a ~90° rotation *and* banding —
and the rotation half was genuinely fixed. The stride half went with the closed issue.

**So any rebuild from an unpatched upstream source reintroduces the banding.**

### Upstream action, when someone has time

Better than filing fresh: **comment on the existing #4817**, noting that #4751 addressed orientation
rather than stride and that master still carries both offending lines. The analysis and patch are
already in that thread; this forward-port and the `need_clip_uv` finding are what is new. Out of
scope for the rebuild task — see `../../../swift-pjsua/Upstream/README.md` for how this workspace
files things.

### Retirement criteria

This directory is temporary by design. Delete the patch, this section, and §-1 of
`TASK-code-swift-pjsip-rebuild.md` when **both** hold:

1. The PJSIP version being built contains stride-aware copies — grep `darwin_dev.m` for
   `GetBytesPerRowOfPlane(img, 1)` and a row-by-row packed copy; the naive
   `pj_memcpy(…, frame_size)` must be gone. (Build with `--patches /dev/null`-style empty dir to
   confirm the tree no longer needs us.)
2. **A video call from an iPhone 17 front camera has been checked on a real device** and the remote
   picture is clean. No automated test in this workspace can see this — it is the one regression
   that needs an eye.
