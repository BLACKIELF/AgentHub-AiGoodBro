"""Fail before packaging when an actual MSI input cannot round-trip in CP936.

Resource contents are payload bytes, not database strings. Tauri 2.6.2 emits
File/@Source without Name, so the original basename must be representable.
"""
import argparse
import html
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET


def check_text(value, label):
    try:
        if "\0" in value or value.encode("cp936", "strict").decode("cp936", "strict") != value:
            raise ValueError("non-roundtrip")
    except (UnicodeError, ValueError) as error:
        raise ValueError("MSI CP936 string rejected: " + label) from error


def check_inputs(root, source_only=False):
    root = Path(root).resolve(strict=True)
    tauri = root / "windows/apps/codexu-tauri/src-tauri"
    config = json.loads((tauri / "tauri.conf.json").read_text())
    windows = config["bundle"]["windows"]
    wix = windows["wix"]
    if wix["language"] != {"en-US": {"localePath": "installer/encoding-en-US.wxl"}} or wix["template"] != "installer/wix-main.wxs":
        raise ValueError("MSI localization/template needs a new encoding audit")
    # These optional inputs would need their own complete string enumeration.
    if any(config["bundle"].get(key) for key in ("fileAssociations", "externalBin", "licenseFile")) or any(
        wix.get(key) for key in ("fragmentPaths", "componentRefs", "componentGroupRefs", "featureRefs", "featureGroupRefs", "mergeRefs")
    ) or config.get("plugins", {}).get("deep-link"):
        raise ValueError("MSI extra string source needs an encoding audit")
    template = (tauri / wix["template"]).read_text()
    product = re.search(r"<Product\b[^>]+>", template).group(0)
    if 'Codepage="936"' not in product or 'SummaryCodepage="!(loc.TauriCodepage)"' not in template:
        raise ValueError("MSI database/summary codepage contract changed")
    check_text(html.unescape(template), "template")
    check_text((tauri / "Cargo.toml").read_text(), "Cargo package metadata")
    locale = ET.fromstring((tauri / "installer/encoding-en-US.wxl").read_bytes())
    if locale.attrib.get("Codepage") != "936" or locale.attrib.get("Culture") != "en-us" or len(locale):
        raise ValueError("MSI localization override must only select database CP936")
    # Only fields consumed by the pinned MSI renderer; copyright is PE metadata.
    values = [config["productName"], config["version"], config["identifier"],
              config["bundle"]["publisher"], wix["upgradeCode"], "codexu-tauri.exe"]
    values += [config["bundle"].get(key, "") or "" for key in ("longDescription", "homepage")]
    for value in values:
        check_text(value, "product field")
    # Product name and publisher also appear in the separate summary stream.
    for value in (config["productName"], config["bundle"]["publisher"]):
        if value.encode("cp1252", "strict").decode("cp1252") != value:
            raise ValueError("MSI summary field cannot round-trip in CP1252")
    policy = json.loads((tauri / "installer/SOURCE.json").read_text())["encoding_contract"]
    if (policy["databaseCodepage"], policy["summaryCodepage"], policy["languageId"]) != (936, 1252, 1033):
        raise ValueError("MSI encoding audit contract changed")
    for item in policy["localizationSources"]:
        if not item["allValuesAscii"] or item["nonAsciiCodepoints"]:
            raise ValueError("Pinned en-US localization needs a new encoding audit")
    resources = json.loads((tauri / "tauri.windows.conf.json").read_text())["bundle"]["resources"]
    count = 0
    skipped = []
    non_latin = []
    for source, target in resources.items():
        relative = Path(target)
        if relative.is_absolute() or ".." in relative.parts or not source.endswith("/") or not target.endswith("/"):
            raise ValueError("MSI resource mapping is not a relative directory mapping")
        directory = (tauri / source).resolve()
        if not directory.is_relative_to(root):
            raise ValueError("MSI resource source escaped repository")
        if not directory.exists() and source_only and source.startswith("resources/"):
            skipped.append(target)
            continue
        if not directory.is_dir():
            raise ValueError("MSI resource directory missing: " + target)
        for path in sorted(directory.rglob("*")):
            if path.is_symlink():
                raise ValueError("MSI resource link is not allowed")
            rel = relative / path.relative_to(directory)
            check_text(rel.as_posix(), "resource target")
            check_text(path.name, "resource Source basename")
            if path.is_file():
                count += 1
                try:
                    rel.as_posix().encode("cp1252")
                except UnicodeEncodeError:
                    non_latin.append(rel.as_posix())
    return {"databaseCodepage": 936, "summaryCodepage": 1252, "languageId": 1033,
            "resourceFiles": count, "nonCp1252Resources": non_latin,
            "sourceOnly": source_only, "unpreparedResourceDirectories": skipped}


def check_generated(directory):
    results = []
    for name in ("main.wxs", "locale.wxl"):
        path = Path(directory) / name
        root = ET.fromstring(path.read_bytes())
        values = [v for el in root.iter() for v in list(el.attrib.values()) + ([el.text] if el.text else [])]
        for value in values:
            check_text(value, "generated " + name)
        if name == "main.wxs":
            product = next(el for el in root.iter() if el.tag.endswith("}Product"))
            if product.attrib.get("Codepage") != "936":
                raise ValueError("Generated MSI database codepage mismatch")
        else:
            strings = {el.attrib.get("Id"): el.text for el in root}
            if root.attrib.get("Codepage") != "936" or strings.get("TauriLanguage") != "1033" or strings.get("TauriCodepage") != "1252":
                raise ValueError("Generated MSI summary/language mismatch")
        results.append({"file": name, "valuesChecked": len(values)})
    return results


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--source-only", action="store_true")
    parser.add_argument("--generated", type=Path)
    args = parser.parse_args()
    result = check_inputs(args.root, args.source_only)
    if args.generated:
        result["generated"] = check_generated(args.generated)
    print(json.dumps(result, ensure_ascii=True))
    print("PASS: MSI CP936 input roundtrip; en-US and summary CP1252 preserved")
