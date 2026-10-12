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

**No patch is applied today.** `0.3.0` is the first artifact built from unmodified upstream source:
the one patch the `0.2.x` artifacts carried was merged upstream, and is retired below.

## Retired: `iphone17-darwin-dev-stride.patch`

Kept for provenance as `historical/2.17-iphone17-darwin-dev-stride.patch` (the forward-port to
master `288de6142`, applied to `0.2.0` and `0.2.1`) and `historical/2.16-iphone17-darwin-dev-stride.patch`
(the original, applied to the `0.1.x` 2.16 artifacts). Both touch one file,
`pjmedia/src/pjmedia-videodev/darwin_dev.m`.

**What it fixed.** Two stride bugs in the capture callback, both instances of Apple QA1829 ("always
query per-plane bytes-per-row; never derive one plane's stride from another, and never assume
`bytesPerRow == width * bpp`"):

1. **Chroma plane walked with the luma stride.** The clipped NV12→I420 path advanced plane 1 by
   `CVPixelBufferGetBytesPerRowOfPlane(img, 0)`.
2. **Packed/BGRA copied as one flat block.** `pj_memcpy(capture_buf, base, frame_size)` ignored
   `CVPixelBufferGetBytesPerRow`, so a padded row was read across its own boundary.

Symptom when absent: horizontal repetition / banding on the iPhone 17 front camera, whose stride is
much larger than `width × bpp`.

**How it left.** Reported as [pjproject#4817](https://github.com/pjsip/pjproject/issues/4817),
which was closed after a fix for the rotation half of that report; the stride half was then fixed
upstream by [pjproject#5249](https://github.com/pjsip/pjproject/pull/5249) (`b3ca8d109`, merged
2026-09-10). That fix supersedes the patch rather than restating it:

- the chroma plane uses its own stride, and the unclipped chroma path is gated on it
  (`need_clip_uv`) — the gap a review of the forward-port had found in the original;
- the packed copy goes row by row, with the destination pitch taken from the delivered buffer's own
  width rather than from the stream's negotiated `bytes_per_row`, which follows the negotiated
  orientation and disagrees with the buffer for a portrait-negotiated stream;
- rows the source cannot fill are zeroed instead of showing the previous frame.

Because the upstream code differs, the patch no longer applies to master, and `build.sh` would stop
on it — which is the behaviour this directory is built around.

### Retirement criteria

1. **Met.** The PJSIP source being built contains stride-aware copies: `darwin_dev.m` reads
   `CVPixelBufferGetBytesPerRowOfPlane(img, 1)` for the chroma plane and copies packed formats row by
   row; `p += (stride - stream->vid_size.w)` and the flat `pj_memcpy(…, frame_size)` are gone
   (verified against `bd69054a6`).
2. **Open.** A video call from an iPhone 17 front camera, checked on a real device, with a clean
   remote picture. No automated test can see this regression; it needs an eye. Record the result
   here when it is done.
