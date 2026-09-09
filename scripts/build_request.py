"""Emit the chat-completions request body. Prompt comes from argv."""

import json
import sys

prompt = " ".join(sys.argv[1:])
json.dump(
    {
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 512,
        "temperature": 0.7,
    },
    sys.stdout,
)
