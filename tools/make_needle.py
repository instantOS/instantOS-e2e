#!/usr/bin/env python3
"""Create an os-autoinst needle from a screenshot.

Usage: make_needle.py <screenshot.png> <tag> [x y w h]...
Multiple [x y w h] rectangles become multiple match areas. Without
rectangles the whole frame is the match area (exact full-screen match).
"""
import json
import shutil
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    shot = Path(sys.argv[1])
    tag = sys.argv[2]
    nums = [int(x) for x in sys.argv[3:]]

    out = Path(__file__).resolve().parents[1] / "casedir" / "needles"
    shutil.copy(shot, out / f"{tag}.png")

    areas = []
    if nums:
        if len(nums) % 4:
            sys.exit("rectangles must be x y w h quadruples")
        for i in range(0, len(nums), 4):
            x, y, w, h = nums[i : i + 4]
            areas.append(
                {"xpos": x, "ypos": y, "width": w, "height": h, "type": "match"}
            )
    else:
        from PIL import Image

        with Image.open(shot) as im:
            areas.append(
                {"xpos": 0, "ypos": 0, "width": im.width, "height": im.height, "type": "match"}
            )

    payload = {"area": areas, "tags": [tag]}
    (out / f"{tag}.json").write_text(json.dumps(payload, indent=4) + "\n")
    print(f"wrote {out / tag}.png/.json with {len(areas)} area(s)")


if __name__ == "__main__":
    main()
