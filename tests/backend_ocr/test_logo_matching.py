import base64
import io
import sys
import unittest
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).parents[2] / 'src/backend_ocr'))
from logo_matching import geometry, prepare_image


def encoded(image):
    out = io.BytesIO()
    Image.fromarray(image).save(out, format='PNG')
    return base64.b64encode(out.getvalue()).decode()


class LogoGeometryTest(unittest.TestCase):
    def test_paper_and_broad_shadow_do_not_supply_foreground_evidence(self):
        paper = np.tile(np.linspace(150, 245, 300).astype(np.uint8), (160, 1))
        normalized, mask = prepare_image(encoded(paper))
        self.assertLess(mask.mean(), 0.01)
        empty = np.empty((0, 2), np.float32)
        self.assertEqual(geometry(mask, mask, empty, empty)['score'], 0)

    def test_matching_one_small_corner_cannot_identify_the_logo(self):
        mask = np.zeros((200, 400), np.uint8)
        cv2.putText(mask, 'MARKET', (10, 130), cv2.FONT_HERSHEY_SIMPLEX, 2, 1, 4)
        points = np.float32([[20 + i % 4, 100 + i // 4] for i in range(20)])
        self.assertEqual(geometry(mask, mask, points, points)['score'], 0)

    def test_foreground_shape_differs_despite_matching_layout(self):
        a = np.zeros((180, 400), np.uint8)
        b = a.copy()
        cv2.putText(a, 'SKY FOODS', (10, 90), cv2.FONT_HERSHEY_SIMPLEX, 1.3, 1, 3)
        cv2.putText(b, 'HUALIAN', (10, 90), cv2.FONT_HERSHEY_SIMPLEX, 1.3, 1, 3)
        # Even an invented full-image alignment cannot earn background similarity.
        points = np.float32([[x, y] for x in range(10, 390, 30) for y in [10, 90, 170]])
        self.assertLess(geometry(a, b, points, points)['score'], 0.55)

    def test_invalid_image_fails_instead_of_returning_a_match(self):
        for data in ['not base64', encoded(np.zeros((2, 2), np.uint8))]:
            with self.assertRaises(ValueError):
                prepare_image(data)
