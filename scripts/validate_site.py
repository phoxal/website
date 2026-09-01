#!/usr/bin/env python3

from __future__ import annotations

from html.parser import HTMLParser
from pathlib import Path
from struct import unpack
from urllib.parse import unquote, urlparse
import re
import sys
import xml.etree.ElementTree as ElementTree


ROOT = Path(__file__).resolve().parents[1]
SITE_ORIGIN = "https://phoxal.com"
PRODUCT_DEFINITION = (
    "Phoxal is an open-source robotics framework for turning robot experience into "
    "observable, repeatable, and deliberately evaluated improvements."
)
EXPECTED_LIFECYCLE = [
    "Author",
    "Validate",
    "Simulate",
    "Execute",
    "Observe",
    "Create",
    "Evaluate",
    "Promote",
]
URL_PATTERN = re.compile(r"url\(\s*(['\"]?)([^)'\"]+)\1\s*\)")


class SiteParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.ids: list[str] = []
        self.references: list[tuple[str, str]] = []
        self.fragment_links: list[str] = []
        self.meta: dict[str, str] = {}
        self.stylesheets: list[str] = []
        self.h1_count = 0
        self.script_count = 0
        self.lifecycle_count = 0
        self.lifecycle_stages: list[str] = []
        self.title_parts: list[str] = []
        self._in_lifecycle = False
        self._in_lifecycle_heading = False
        self._in_title = False
        self._heading_parts: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = {name: value or "" for name, value in attrs}
        if values.get("id"):
            self.ids.append(values["id"])

        for attribute in ("href", "src", "poster"):
            if values.get(attribute):
                reference = values[attribute]
                self.references.append((f"{tag}[{attribute}]", reference))
                if attribute == "href" and reference.startswith("#"):
                    self.fragment_links.append(reference[1:])

        if tag == "link" and "stylesheet" in values.get("rel", "").split():
            self.stylesheets.append(values.get("href", ""))

        if tag == "meta":
            key = values.get("name") or values.get("property")
            if key:
                self.meta[key] = values.get("content", "")

        if tag == "h1":
            self.h1_count += 1
        elif tag == "script":
            self.script_count += 1
        elif tag == "title":
            self._in_title = True

        classes = values.get("class", "").split()
        if tag == "ol" and "lifecycle" in classes:
            self.lifecycle_count += 1
            self._in_lifecycle = True
        elif tag == "h3" and self._in_lifecycle:
            self._in_lifecycle_heading = True
            self._heading_parts = []

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title_parts.append(data)
        if self._in_lifecycle_heading:
            self._heading_parts.append(data)

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self._in_title = False
        elif tag == "h3" and self._in_lifecycle_heading:
            heading = " ".join("".join(self._heading_parts).split())
            self.lifecycle_stages.append(heading)
            self._in_lifecycle_heading = False
        elif tag == "ol" and self._in_lifecycle:
            self._in_lifecycle = False


def local_path(reference: str) -> Path | None:
    parsed = urlparse(reference)
    if parsed.scheme in {"http", "https"}:
        if f"{parsed.scheme}://{parsed.netloc}" != SITE_ORIGIN:
            return None
        site_path = unquote(parsed.path)
    elif parsed.scheme or reference.startswith(("#", "mailto:")):
        return None
    else:
        site_path = unquote(parsed.path)

    if site_path in {"", "/"}:
        candidate = ROOT / "index.html"
    else:
        candidate = ROOT / site_path.lstrip("/")

    resolved = candidate.resolve()
    try:
        resolved.relative_to(ROOT.resolve())
    except ValueError as error:
        raise ValueError(f"local path escapes the repository: {reference}") from error
    return resolved


def valid_external_reference(reference: str) -> bool:
    parsed = urlparse(reference)
    if parsed.scheme in {"http", "https"}:
        return bool(parsed.netloc and " " not in reference)
    if parsed.scheme == "mailto":
        address = parsed.path
        return address.count("@") == 1 and " " not in address
    return not parsed.scheme


def png_dimensions(path: Path) -> tuple[int, int]:
    header = path.read_bytes()[:24]
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"{path.relative_to(ROOT)} is not a valid PNG")
    return unpack(">II", header[16:24])


def main() -> int:
    errors: list[str] = []
    parser = SiteParser()
    parser.feed((ROOT / "index.html").read_text(encoding="utf-8"))

    duplicate_ids = sorted({item_id for item_id in parser.ids if parser.ids.count(item_id) > 1})
    if duplicate_ids:
        errors.append(f"duplicate IDs: {', '.join(duplicate_ids)}")

    missing_fragments = sorted(set(parser.fragment_links) - set(parser.ids))
    if missing_fragments:
        errors.append(f"unresolved fragments: {', '.join(missing_fragments)}")

    if parser.h1_count != 1:
        errors.append(f"expected exactly one H1, found {parser.h1_count}")
    if parser.script_count != 0:
        errors.append(f"expected zero script elements, found {parser.script_count}")
    if parser.lifecycle_count != 1:
        errors.append(f"expected one lifecycle list, found {parser.lifecycle_count}")
    if parser.lifecycle_stages != EXPECTED_LIFECYCLE:
        errors.append(
            "unexpected lifecycle order: "
            + " -> ".join(parser.lifecycle_stages)
        )

    title = " ".join("".join(parser.title_parts).split())
    if title != "Phoxal | Robots that improve without giving up control":
        errors.append(f"unexpected document title: {title}")

    for key in ("description", "og:description", "twitter:description"):
        if parser.meta.get(key) != PRODUCT_DEFINITION:
            errors.append(f"{key} does not use the canonical product definition")

    for key in ("og:title", "twitter:title", "og:image:alt", "twitter:image:alt"):
        if "giving up control" not in parser.meta.get(key, ""):
            errors.append(f"{key} does not use the central phrase")

    if parser.meta.get("og:image:type") != "image/png":
        errors.append("og:image:type must be image/png")

    if any(urlparse(stylesheet).query for stylesheet in parser.stylesheets):
        errors.append("stylesheet references must not use manual cache hashes")

    css_text = (ROOT / "styles.css").read_text(encoding="utf-8")
    css_references = [("styles.css", match[1]) for match in URL_PATTERN.findall(css_text)]
    image_references = [
        (f"meta[{key}]", parser.meta[key])
        for key in ("og:image", "twitter:image")
        if parser.meta.get(key)
    ]

    for source, reference in parser.references + css_references + image_references:
        if not valid_external_reference(reference):
            errors.append(f"malformed URL in {source}: {reference}")
            continue
        try:
            path = local_path(reference)
        except ValueError as error:
            errors.append(str(error))
            continue
        if path is not None and not path.is_file():
            errors.append(f"missing local file from {source}: {path.relative_to(ROOT)}")

    if not (ROOT / "assets/inter-OFL.txt").is_file():
        errors.append("the self-hosted Inter font must retain its OFL license")

    expected_images = {
        ROOT / "assets/phoxal-social-card.png": (1200, 630),
        ROOT / "assets/apple-touch-icon.png": (180, 180),
        ROOT / "assets/favicon.png": (64, 64),
    }
    for path, expected_dimensions in expected_images.items():
        if not path.is_file():
            errors.append(f"missing required image: {path.relative_to(ROOT)}")
            continue
        try:
            actual_dimensions = png_dimensions(path)
        except ValueError as error:
            errors.append(str(error))
            continue
        if actual_dimensions != expected_dimensions:
            errors.append(
                f"{path.relative_to(ROOT)} is {actual_dimensions}, expected {expected_dimensions}"
            )

    robots = (ROOT / "robots.txt").read_text(encoding="utf-8")
    for required_line in (
        "User-agent: *",
        "Allow: /",
        "Sitemap: https://phoxal.com/sitemap.xml",
    ):
        if required_line not in robots.splitlines():
            errors.append(f"robots.txt is missing: {required_line}")

    sitemap_root = ElementTree.parse(ROOT / "sitemap.xml").getroot()
    sitemap_locations = sitemap_root.findall(
        "{http://www.sitemaps.org/schemas/sitemap/0.9}url/"
        "{http://www.sitemaps.org/schemas/sitemap/0.9}loc"
    )
    if [location.text for location in sitemap_locations] != ["https://phoxal.com/"]:
        errors.append("sitemap.xml must contain only the canonical homepage URL")

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1

    print(
        "Validated one H1, eight lifecycle stages, internal fragments, local assets, "
        "metadata, icons, robots.txt, sitemap.xml, and zero scripts."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
