"""Build a chat-completions request carrying an inline image."""

import argparse
import base64
import json
import mimetypes
import pathlib
import sys

ap = argparse.ArgumentParser()
ap.add_argument("image")
ap.add_argument("--prompt", default="What text is written in this image?")
ap.add_argument("--max-tokens", type=int, default=128)
a = ap.parse_args()

path = pathlib.Path(a.image)
if not path.is_file():
    sys.exit(f"no such image: {path}")

mime = mimetypes.guess_type(path.name)[0] or "image/png"
b64 = base64.b64encode(path.read_bytes()).decode()

json.dump(
    {
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": a.prompt},
                # Inline data URI; no file access needed server-side.
                {"type": "image_url",
                 "image_url": {"url": f"data:{mime};base64,{b64}"}},
            ],
        }],
        "max_tokens": a.max_tokens,
        "temperature": 0,
    },
    sys.stdout,
)
