"""Pinned-model regression: reviewed logo crops, separate from real-photo holdouts.

Executed inside the OCR image build, entirely offline. Synthetic variants are regression
coverage, not evidence of accuracy on independent photographs or real paper folds.
"""

import argparse
import base64
import io
import json
import sys
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parents[2] / 'src/backend_ocr'))
from logo_matching import LogoMatcher


def encoded(image):
    out = io.BytesIO()
    Image.fromarray(image).save(out, format='PNG')
    return base64.b64encode(out.getvalue()).decode()


def variants(image):
    height, width = image.shape[:2]
    image = cv2.resize(image, (int(width * min(1, 1024 / width)), int(height * min(1, 1024 / width))))
    height, width = image.shape[:2]
    transform = cv2.getPerspectiveTransform(
        np.float32([[0, 0], [width, 0], [width, height], [0, height]]),
        np.float32([[width * 0.15, height * 0.05], [width * 0.80, 0], [width * 0.97, height * 0.93], [0, height]]),
    )
    y, x = np.mgrid[:height, :width].astype(np.float32)
    crease = width * 0.52
    fold = cv2.remap(
        image,
        x,
        y - np.maximum(x - crease, 0) * 0.13,
        cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(255, 255, 255),
    )
    fold = (fold * (1 - 0.28 * np.exp(-(((x - crease) / 12) ** 2)))[:, :, None]).astype('uint8')
    return {
        'rotate': cv2.warpAffine(
            image,
            cv2.getRotationMatrix2D((width / 2, height / 2), 12, 0.82),
            (width, height),
            borderValue=(255, 255, 255),
        ),
        'perspective': cv2.warpPerspective(image, transform, (width, height), borderValue=(255, 255, 255)),
        'simulated_fold': fold,
        'faint': (image * 0.36 + 160).clip(0, 255).astype('uint8'),
    }


def evaluate(root, weights):
    model = LogoMatcher(weights, 128)
    samples = json.loads((root / 'manifest.json').read_text())['samples']
    images = {s['id']: base64.b64encode((root / s['image']).read_bytes()).decode() for s in samples}
    results = []
    for a in samples:
        for b in samples:
            if a['name'] == b['name']:
                continue
            result = model.compare(images[a['id']], images[b['id']])
            results.append({'kind': 'different_store', 'a': a['id'], 'b': b['id'], **result})
            assert result['score'] < 0.20, (a['name'], b['name'], result)
        original = np.asarray(Image.open(root / a['image']).convert('RGB'))
        for name, image in variants(original).items():
            result = model.compare(encoded(image), images[a['id']])
            results.append({'kind': name, 'a': a['id'], **result})
            assert result['score'] >= 0.55 and result['evidence'] >= 0.75, (a['name'], name, result)
    print(json.dumps({'cases': len(results), 'results': results}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--samples', type=Path, required=True)
    parser.add_argument('--weights', required=True)
    args = parser.parse_args()
    evaluate(args.samples, args.weights)
