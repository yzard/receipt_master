"""Paper-normalized local logo identity matching. No text recognition or global embedding."""

import base64
import hashlib
import io
from collections import OrderedDict
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageOps

MODEL_ID = "superpoint-lightglue-foreground-v1"


def prepare_image(encoded):
    data = base64.b64decode(encoded, validate=True)
    with Image.open(io.BytesIO(data)) as opened:
        if min(opened.size) < 8 or max(opened.size) > 4096:
            raise ValueError("Invalid logo dimensions")
        image = np.asarray(ImageOps.exif_transpose(opened).convert("L"))
    scale = min(1.0, 1024 / max(image.shape))
    image = cv2.resize(image, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    # Estimate the paper behind dark ink; remove broad illumination and fold shadows.
    size = max(15, int(min(image.shape) * 0.12) | 1)
    background = cv2.morphologyEx(image, cv2.MORPH_CLOSE, np.ones((size, size), np.uint8))
    background = cv2.GaussianBlur(background, (0, 0), 3)
    ink = np.clip(1 - image.astype(np.float32) / np.maximum(background, 32), 0, 1)
    ink[ink < 0.035] = 0
    # Fixed contrast normalization removes ink darkness, not the arrangement of strokes.
    visible = ink[ink > 0]
    if visible.size:
        ink = np.clip(ink / max(float(np.percentile(visible, 90)), 0.08), 0, 1)
    mask = (ink > 0.28).astype(np.uint8)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask)
    keep = np.zeros(count, np.uint8)
    keep[1:] = stats[1:, cv2.CC_STAT_AREA] >= 4
    mask = keep[labels]
    ink[cv2.dilate(mask, np.ones((3, 3), np.uint8)) == 0] = 0
    return (1 - ink).astype(np.float32), mask


def plausible(h, shape_a, shape_b):
    if h is None or not np.isfinite(h).all():
        return False
    ha, wa = shape_a
    hb, wb = shape_b
    corners = np.float32([[[0, 0], [wa, 0], [wa, ha], [0, ha]]])
    mapped = cv2.perspectiveTransform(corners, h)[0]
    area = cv2.contourArea(mapped, oriented=True)
    return bool(np.isfinite(mapped).all() and cv2.isContourConvex(mapped) and 0.15 < area / (hb * wb) < 6)


def geometry(a, b, pa, pb):
    empty = {"score": 0.0, "evidence": 0.0, "inliers": 0, "regions": 0, "coverage": [0.0, 0.0], "matches": len(pa)}
    if len(pa) < 12 or min(a.sum(), b.sum()) < 40:
        return empty
    remaining = np.ones(len(pa), bool)
    verified_a = np.zeros_like(a)
    verified_b = np.zeros_like(b)
    used = 0
    regions = 0
    first = None
    for _ in range(2):
        if remaining.sum() < 12:
            break
        h, inliers = cv2.findHomography(pa[remaining], pb[remaining], cv2.RANSAC, 3.5, maxIters=2000, confidence=0.999)
        if not plausible(h, a.shape, b.shape) or inliers is None or inliers.sum() < 12:
            break
        indices = np.flatnonzero(remaining)[inliers.ravel().astype(bool)]
        qa, qb = pa[indices], pb[indices]
        # Four coincident letter corners cannot establish a logo identity.
        if any(cv2.contourArea(cv2.convexHull(p)) / (m.shape[0] * m.shape[1]) < 0.025 for p, m in [(qa, a), (qb, b)]):
            break
        if first is not None:
            anchors = pa[indices].reshape(1, -1, 2)
            displacement = np.linalg.norm(
                cv2.perspectiveTransform(anchors, h) - cv2.perspectiveTransform(anchors, first), axis=2
            )
            if np.median(displacement) > max(b.shape) * 0.12:
                break
        else:
            first = h
        for source, target, ps, pt, transform, result in [
            (a, b, qa, qb, h, verified_b),
            (b, a, qb, qa, np.linalg.inv(h), verified_a),
        ]:
            support = np.zeros_like(source)
            cv2.fillConvexPoly(support, cv2.convexHull(ps).astype(np.int32), 1)
            support = cv2.dilate(support, np.ones((21, 21), np.uint8))
            warped = cv2.warpPerspective(
                source * support, transform, (target.shape[1], target.shape[0]), flags=cv2.INTER_NEAREST
            )
            near = cv2.distanceTransform(1 - warped, cv2.DIST_L2, 3) < 3.0
            result[:] |= (near & (target > 0)).astype(np.uint8)
        used += len(indices)
        regions += 1
        remaining[indices] = False
    ca = float(verified_a.sum() / max(a.sum(), 1))
    cb = float(verified_b.sum() / max(b.sum(), 1))
    # Both logos must be explained. Background and overall layout never earn points.
    coverage = min(ca, cb)
    # Dozens of repeated letter corners are weak evidence; full support needs 80 inliers.
    evidence = min(1.0, used / 80)
    score = coverage * evidence
    return {
        "score": score,
        "evidence": evidence,
        "inliers": used,
        "regions": regions,
        "coverage": [ca, cb],
        "matches": len(pa),
    }


class LogoMatcher:
    def __init__(self, model_path, cache_size):
        import torch
        from lightglue import LightGlue, SuperPoint

        weights = Path(model_path) / "hub" / "checkpoints"
        for name, digest in {
            "superpoint_v1.pth": "52b6708629640ca883673b5d5c097c4ddad37d8048b33f09c8ca0d69db12c40e",
            "superpoint_lightglue_v0-1_arxiv.pth": "6ff7040d0a497fc6639337946d7538dae07428c18f77a067a0b5a960e7cc551a",
        }.items():
            if hashlib.sha256((weights / name).read_bytes()).hexdigest() != digest:
                raise ValueError("Invalid local logo weights")
        torch.hub.set_dir(str(weights.parent))
        torch.set_num_threads(4)
        cv2.setNumThreads(1)
        self.torch = torch
        self.extractor = SuperPoint(max_num_keypoints=768).eval().cpu()
        self.matcher = (
            LightGlue(features="superpoint", depth_confidence=-1, width_confidence=-1, flash=False).eval().cpu()
        )
        self.cache = OrderedDict()
        self.cache_size = cache_size

    def features(self, encoded):
        key = hashlib.sha256(encoded.encode()).hexdigest()
        if key in self.cache:
            self.cache.move_to_end(key)
            return self.cache[key]
        image, mask = prepare_image(encoded)
        torch = self.torch
        with torch.inference_mode():
            features = self.extractor.extract(torch.from_numpy(image)[None], resize=None)
        points = features['keypoints'][0].numpy()
        foreground = cv2.dilate(mask, np.ones((9, 9), np.uint8))
        valid = (
            foreground[
                np.clip(points[:, 1].astype(int), 0, mask.shape[0] - 1),
                np.clip(points[:, 0].astype(int), 0, mask.shape[1] - 1),
            ]
            > 0
        )
        for name in ['keypoints', 'keypoint_scores', 'descriptors']:
            features[name] = features[name][:, valid]
        self.cache[key] = (features, mask)
        if len(self.cache) > self.cache_size:
            self.cache.popitem(last=False)
        return features, mask

    def compare(self, image, reference):
        fa, ma = self.features(image)
        fb, mb = self.features(reference)
        if min(fa['keypoints'].shape[1], fb['keypoints'].shape[1]) < 12:
            return geometry(ma, mb, np.empty((0, 2), np.float32), np.empty((0, 2), np.float32))
        with self.torch.inference_mode():
            matches = self.matcher({'image0': fa, 'image1': fb})['matches'][0].numpy()
        pa = fa['keypoints'][0].numpy()[matches[:, 0]]
        pb = fb['keypoints'][0].numpy()[matches[:, 1]]
        return geometry(ma, mb, pa, pb)

    def match(self, image, references):
        return {"model": MODEL_ID, "scores": [{"id": r["id"], **self.compare(image, r["image"])} for r in references]}
