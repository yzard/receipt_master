"""Controlled synthetic logo perturbations; not independent real photographs."""

import cv2
import numpy as np


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
