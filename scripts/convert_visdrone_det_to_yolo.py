#!/usr/bin/env python3
"""Convert VisDrone DET annotations to YOLO format.

Expected source layout:

VisDrone2019-DET-train/
  images/
  annotations/
VisDrone2019-DET-val/
  images/
  annotations/

Output layout:

visdrone_yolo/
  VisDrone2019-DET-train/
    images/
    labels/
  VisDrone2019-DET-val/
    images/
    labels/
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


CLASS_MAP = {
    1: 0,  # pedestrian
    2: 1,  # person
    3: 2,  # bicycle
    4: 3,  # car
    5: 4,  # van
    6: 5,  # truck
    7: 6,  # tricycle
    8: 7,  # awning-tricycle
    9: 8,  # bus
    10: 9,  # motor
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument(
        "--copy-images",
        action="store_true",
        help="Copy images into the YOLO output tree instead of symlinking.",
    )
    return parser.parse_args()


def read_image_size(image_path: Path) -> tuple[int, int]:
    try:
        from PIL import Image  # type: ignore
    except ImportError as exc:
        raise SystemExit("Pillow is required: pip install pillow") from exc
    with Image.open(image_path) as image:
        return image.width, image.height


def convert_split(source_root: Path, output_root: Path, split_name: str, copy_images: bool) -> None:
    image_dir = source_root / split_name / "images"
    annotation_dir = source_root / split_name / "annotations"
    out_image_dir = output_root / split_name / "images"
    out_label_dir = output_root / split_name / "labels"
    out_image_dir.mkdir(parents=True, exist_ok=True)
    out_label_dir.mkdir(parents=True, exist_ok=True)

    for image_path in sorted(image_dir.iterdir()):
        if image_path.suffix.lower() not in {".jpg", ".jpeg", ".png"}:
            continue

        width, height = read_image_size(image_path)
        annotation_path = annotation_dir / f"{image_path.stem}.txt"
        output_label_path = out_label_dir / f"{image_path.stem}.txt"

        rows = []
        if annotation_path.exists():
            for raw_line in annotation_path.read_text().splitlines():
                fields = [field.strip() for field in raw_line.split(",")]
                if len(fields) < 8:
                    continue
                x, y, w, h = map(float, fields[:4])
                score = int(fields[4])
                category = int(fields[5])
                if score == 0 or category not in CLASS_MAP:
                    continue

                cx = (x + w / 2.0) / width
                cy = (y + h / 2.0) / height
                nw = w / width
                nh = h / height
                rows.append(f"{CLASS_MAP[category]} {cx:.6f} {cy:.6f} {nw:.6f} {nh:.6f}")

        output_label_path.write_text("\n".join(rows))

        target_image_path = out_image_dir / image_path.name
        if target_image_path.exists():
            target_image_path.unlink()
        if copy_images:
            shutil.copy2(image_path, target_image_path)
        else:
            target_image_path.symlink_to(image_path.resolve())


def main() -> None:
    args = parse_args()
    for split_name in ["VisDrone2019-DET-train", "VisDrone2019-DET-val"]:
        convert_split(
            source_root=args.source_root,
            output_root=args.output_root,
            split_name=split_name,
            copy_images=args.copy_images,
        )
    print("Converted VisDrone DET to YOLO format.")


if __name__ == "__main__":
    main()
