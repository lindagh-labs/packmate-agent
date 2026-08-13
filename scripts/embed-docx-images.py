#!/usr/bin/env python3
"""Convert file-linked DOCX images into embedded package parts."""

from __future__ import annotations

import argparse
import os
import re
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path


RELATIONSHIP_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
IMAGE_RELATIONSHIP = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"


def local_target(raw_target: str) -> Path:
    parsed = urllib.parse.urlparse(raw_target)
    if parsed.scheme != "file":
        raise ValueError(f"refusing to embed non-file image target: {raw_target}")
    path = Path(urllib.parse.unquote(parsed.path)).resolve()
    if not path.is_file():
        raise FileNotFoundError(f"linked DOCX image not found: {path}")
    return path


def embed_images(docx: Path) -> int:
    document_name = "word/document.xml"
    relationships_name = "word/_rels/document.xml.rels"

    with zipfile.ZipFile(docx) as archive:
        document_xml = archive.read(document_name)
        relationships_xml = archive.read(relationships_name)

    ET.register_namespace("", RELATIONSHIP_NS)
    relationships = ET.fromstring(relationships_xml)
    linked: list[tuple[str, Path, str]] = []
    used_names: set[str] = set()

    for relationship in relationships:
        if relationship.get("Type") != IMAGE_RELATIONSHIP:
            continue
        if relationship.get("TargetMode") != "External":
            continue
        relationship_id = relationship.attrib["Id"]
        source = local_target(relationship.attrib["Target"])
        name = source.name
        counter = 2
        while name in used_names:
            name = f"{source.stem}-{counter}{source.suffix}"
            counter += 1
        used_names.add(name)
        package_name = f"word/media/{name}"
        relationship.set("Target", f"media/{name}")
        relationship.attrib.pop("TargetMode", None)
        linked.append((relationship_id, source, package_name))

    if not linked:
        return 0

    for relationship_id, _, _ in linked:
        link = f'r:link="{relationship_id}"'.encode()
        embed = f'r:embed="{relationship_id}"'.encode()
        document_xml, replacements = re.subn(re.escape(link), embed, document_xml)
        if replacements != 1:
            raise ValueError(
                f"expected one drawing reference for {relationship_id}, found {replacements}"
            )

    relationships_xml = ET.tostring(
        relationships,
        encoding="utf-8",
        xml_declaration=True,
    )

    handle, temporary_name = tempfile.mkstemp(
        prefix=f".{docx.stem}.", suffix=".docx", dir=docx.parent
    )
    os.close(handle)
    temporary = Path(temporary_name)
    try:
        with zipfile.ZipFile(docx) as source_archive, zipfile.ZipFile(
            temporary, "w"
        ) as destination_archive:
            for info in source_archive.infolist():
                if info.filename == document_name:
                    destination_archive.writestr(info, document_xml)
                elif info.filename == relationships_name:
                    destination_archive.writestr(info, relationships_xml)
                else:
                    destination_archive.writestr(info, source_archive.read(info.filename))
            for _, image, package_name in linked:
                destination_archive.write(
                    image,
                    package_name,
                    compress_type=zipfile.ZIP_DEFLATED,
                )
        os.replace(temporary, docx)
        docx.chmod(0o644)
    finally:
        temporary.unlink(missing_ok=True)
    return len(linked)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("docx", type=Path)
    args = parser.parse_args()
    count = embed_images(args.docx.resolve())
    print(f"EMBEDDED_DOCX_IMAGES {count}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
