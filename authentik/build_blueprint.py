#!/usr/bin/env python3
"""Render authentik/blueprints/wlan-passwort.yaml from authentik/src/.

    python3 authentik/build_blueprint.py          write the blueprint
    python3 authentik/build_blueprint.py --check  exit 1 if it is out of date
"""
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent
SRC = ROOT / "src"
OUT = ROOT / "blueprints" / "wlan-passwort.yaml"
# The expressions sit in YAML block scalars under "attrs:"; eight spaces nests
# them below their key.
INDENT = " " * 8


def _read(name):
    return (SRC / name).read_text(encoding="utf-8")


def words():
    out = []
    for line in _read("eff_short_wordlist_1.txt").splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        word = line.split()[-1]
        # The hyphen separates the words of a passphrase, so yo-yo is out.
        if word.isalpha() and word.islower():
            out.append(word)
    return out


def expressions():
    generate = "WORDS = " + repr(tuple(words())) + "\n" + _read("wifi_password_generate.expr")
    save = _read("md4.py") + "\n" + _read("wifi_password_save.expr")
    return generate, save


def _block(code):
    return "\n".join(INDENT + line if line.strip() else "" for line in code.rstrip("\n").splitlines())


def render():
    generate, save = expressions()
    template = _read("wlan-passwort.yaml.in")
    return template.replace("@GENERATE@", _block(generate)).replace("@SAVE@", _block(save))


def main(argv):
    text = render()
    if argv[1:] == ["--check"]:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != text:
            print(f"{OUT} is out of date; run: python3 authentik/build_blueprint.py", file=sys.stderr)
            return 1
        return 0
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
