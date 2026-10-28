#!/usr/bin/env python3
"""Render the WLAN password blueprints from authentik/src/.

One blueprint per word list: authentik/blueprints/wlan-passwort.yaml (English)
and authentik/blueprints/wlan-passwort.de.yaml (German). Import one of them.

    python3 authentik/build_blueprint.py          write the blueprints
    python3 authentik/build_blueprint.py --check  exit 1 if one is out of date
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "src"
WORDLISTS = {"en": "eff_short_wordlist_1.txt", "de": "wortliste_de.txt"}
OUTPUTS = {
    "en": ROOT / "blueprints" / "wlan-passwort.yaml",
    "de": ROOT / "blueprints" / "wlan-passwort.de.yaml",
}
OUT = OUTPUTS["en"]
# Plain ASCII only: str.isalpha() would let umlauts through, and the hyphen
# separates the words of a passphrase, so yo-yo is out.
WORD = re.compile(r"[a-z]{3,6}")
# The expressions sit in YAML block scalars under "attrs:"; eight spaces nests
# them below their key.
INDENT = " " * 8


def _read(name):
    return (SRC / name).read_text(encoding="utf-8")


def words(lang="en"):
    out = []
    for line in _read(WORDLISTS[lang]).splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        word = line.split()[-1]
        if WORD.fullmatch(word):
            out.append(word)
    return out


def expressions(lang="en"):
    generate = "WORDS = " + repr(tuple(words(lang))) + "\n" + _read("wifi_password_generate.expr")
    save = _read("md4.py") + "\n" + _read("wifi_password_save.expr")
    return generate, save


def _block(code):
    return "\n".join(INDENT + line if line.strip() else "" for line in code.rstrip("\n").splitlines())


def render(lang="en"):
    generate, save = expressions(lang)
    template = _read("wlan-passwort.yaml.in")
    return template.replace("@GENERATE@", _block(generate)).replace("@SAVE@", _block(save))


def main(argv):
    check = argv[1:] == ["--check"]
    stale = 0
    for lang, out in OUTPUTS.items():
        text = render(lang)
        if check:
            if not out.exists() or out.read_text(encoding="utf-8") != text:
                print(f"{out} is out of date; run: python3 authentik/build_blueprint.py", file=sys.stderr)
                stale = 1
            continue
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {out}")
    return stale


if __name__ == "__main__":
    sys.exit(main(sys.argv))
