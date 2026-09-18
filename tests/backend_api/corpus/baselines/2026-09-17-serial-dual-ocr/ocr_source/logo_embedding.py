"""CPU image embeddings; immutable weights ship in the OCR image."""
import base64
import io

MODEL_ID = 'dinov2-small-ed25f3a-cls-letterbox-v1'


class LogoEncoder:
    def __init__(self, path):
        import torch
        from transformers import AutoImageProcessor, AutoModel
        torch.set_num_threads(4)
        self.torch = torch
        self.processor = AutoImageProcessor.from_pretrained(path, local_files_only=True)
        self.model = AutoModel.from_pretrained(path, local_files_only=True).eval().to('cpu')

    def encode(self, encoded):
        from PIL import Image, ImageOps
        picture = Image.open(io.BytesIO(base64.b64decode(encoded, validate=True)))
        picture = ImageOps.exif_transpose(picture).convert('RGB')
        if min(picture.size) < 8 or max(picture.size) > 4096:
            raise ValueError('Invalid logo dimensions')
        # Preserve the complete wordmark; default center-crop would cut long logos.
        picture = ImageOps.pad(picture, (224, 224), color='white')
        inputs = self.processor(images=picture, return_tensors='pt', do_center_crop=False)
        with self.torch.inference_mode():
            vector = self.model(**inputs).last_hidden_state[:, 0, :]
            vector = self.torch.nn.functional.normalize(vector, dim=-1)[0]
        return {'model': MODEL_ID, 'embedding': vector.tolist()}
