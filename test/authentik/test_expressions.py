"""Unit tests for the authentik expressions shipped in the WLAN blueprint.

They run the exact expression text build_blueprint.py puts into the
blueprint, wrapped in a function the way authentik evaluates it, against
small fakes of the objects authentik passes in. Standard library only.
"""
import contextlib
import pathlib
import sys
import types
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2] / "authentik"
sys.path.insert(0, str(ROOT))
import build_blueprint  # noqa: E402


def compile_expression(code, params):
    body = "\n".join("    " + line for line in code.splitlines())
    namespace = {}
    exec(f"def _expression({', '.join(params)}):\n{body}\n", namespace)
    return namespace["_expression"]


GENERATE_SRC, SAVE_SRC = build_blueprint.expressions()
generate = compile_expression(GENERATE_SRC, ["user", "http_request"])
save = compile_expression(SAVE_SRC, ["request", "ak_message", "ak_logger"])
md4_ns = {}
exec((ROOT / "src" / "md4.py").read_text(encoding="utf-8"), md4_ns)
md4 = md4_ns["md4"]


def nt_hash(password):
    return md4(password.encode("utf-16-le")).hex().upper()


class FakeUser:
    def __init__(self, pk=1, attributes=None, journal=None):
        self.pk = pk
        self.username = f"user{pk}"
        self.attributes = dict(attributes or {})
        self.saves = []
        self.journal = journal if journal is not None else []

    def save(self, update_fields=None):
        self.saves.append(update_fields)
        self.journal.append("save")


class FakeManager:
    """Records the query: get() only after select_for_update(), inside atomic()."""

    def __init__(self, users, journal, broken=False):
        self.users = users
        self.journal = journal
        self.broken = broken

    def select_for_update(self):
        self.journal.append("select_for_update")
        return self

    def get(self, pk):
        self.journal.append("get")
        if self.broken:
            raise RuntimeError("database is gone")
        return self.users[pk]


def install_fakes(users, broken=False):
    journal = []

    @contextlib.contextmanager
    def atomic():
        journal.append("begin")
        yield
        journal.append("commit")

    for user in users.values():
        user.journal = journal
    db = types.ModuleType("django.db")
    db.transaction = types.SimpleNamespace(atomic=atomic)
    models = types.ModuleType("authentik.core.models")
    models.User = types.SimpleNamespace(objects=FakeManager(users, journal, broken))
    sys.modules.update({
        "django": types.ModuleType("django"),
        "django.db": db,
        "authentik": types.ModuleType("authentik"),
        "authentik.core": types.ModuleType("authentik.core"),
        "authentik.core.models": models,
    })
    return journal


class Logger:
    def info(self, *args, **kwargs):
        pass

    warning = info


class Md4Test(unittest.TestCase):
    def test_rfc1320_vectors(self):
        self.assertEqual(md4(b"").hex(), "31d6cfe0d16ae931b73c59d7e0c089c0")
        self.assertEqual(md4(b"abc").hex(), "a448017aaf21d8525fc10ae87aa6729d")
        self.assertEqual(md4(b"message digest").hex(), "d9130a8164549fe818874806e1c7014b")
        self.assertEqual(
            md4(b"12345678901234567890123456789012345678901234567890123456789012345678901234567890").hex(),
            "e33b4ddc9c38f2199c3e7b164fcc0536",
        )

    def test_nt_hash_of_password(self):
        self.assertEqual(nt_hash("password"), "8846F7EAEE8FB117AD06BDD830B7586C")


class WordlistTest(unittest.TestCase):
    def test_eff_short_list_without_the_hyphenated_entry(self):
        words = build_blueprint.words()
        self.assertEqual(len(words), 1295)
        self.assertEqual(len(set(words)), 1295)
        self.assertNotIn("yo-yo", words)
        self.assertTrue(all(w.isalpha() and w.islower() and 3 <= len(w) <= 5 for w in words))


class GenerateTest(unittest.TestCase):
    def setUp(self):
        self.user = FakeUser()
        self.http = types.SimpleNamespace(session={}, method="GET")

    def submit(self):
        return types.SimpleNamespace(session=self.http.session, method="POST")

    def test_six_words_from_the_list(self):
        words = set(build_blueprint.words())
        parts = generate(self.user, self.http).split("-")
        self.assertEqual(len(parts), 6)
        self.assertTrue(set(parts) <= words)

    def test_same_passphrase_until_saved(self):
        first = generate(self.user, self.http)
        self.assertEqual(generate(self.user, self.http), first)

    def test_new_passphrase_after_save_even_if_session_kept(self):
        first = generate(self.user, self.http)
        self.user.attributes["wifi-password-set-at"] = "2026-10-13T00:00:00+00:00"
        self.assertNotEqual(generate(self.user, self.http), first)

    def test_submit_without_pending_value_makes_none(self):
        self.assertEqual(generate(self.user, self.submit()), "")
        self.assertEqual(self.http.session, {})

    def test_submit_after_save_makes_none(self):
        generate(self.user, self.http)
        before = dict(self.http.session)
        self.user.attributes["wifi-password-set-at"] = "2026-10-13T00:00:00+00:00"
        self.assertEqual(generate(self.user, self.submit()), "")
        self.assertEqual(self.http.session, before)

    def test_submit_returns_the_pending_value(self):
        shown = generate(self.user, self.http)
        self.assertEqual(generate(self.user, self.submit()), shown)

    def test_preview_without_request(self):
        self.assertEqual(generate(self.user, None), "")


class SaveTest(unittest.TestCase):
    def setUp(self):
        self.user = FakeUser()
        self.journal = install_fakes({1: self.user})
        self.session = {"wifi_password_pending": {"pw": "acid-acorn-acre-acts-afar-affix", "base": ""}}
        self.messages = []

    def run_save(self, prompt_data, request_user=None):
        request = types.SimpleNamespace(
            context={"prompt_data": prompt_data},
            http_request=types.SimpleNamespace(session=self.session),
            user=request_user or self.user,
        )
        return save(request, self.messages.append, Logger())

    def test_saves_the_hash_of_the_shown_passphrase(self):
        ok = self.run_save({"wifi_password": "acid-acorn-acre-acts-afar-affix", "wifi_ack": True})
        self.assertTrue(ok)
        self.assertEqual(self.user.attributes["wifi-password-nthash"], nt_hash("acid-acorn-acre-acts-afar-affix"))
        self.assertTrue(self.user.attributes["wifi-password-set-at"].endswith("+00:00"))
        self.assertEqual(self.user.saves, [["attributes"]])
        self.assertNotIn("wifi_password_pending", self.session)

    def test_keeps_other_attributes(self):
        self.user.attributes["settings"] = {"locale": "de"}
        self.run_save({"wifi_password": "acid-acorn-acre-acts-afar-affix", "wifi_ack": True})
        self.assertEqual(self.user.attributes["settings"], {"locale": "de"})

    def test_locks_and_saves_the_row_inside_one_transaction(self):
        self.run_save({"wifi_password": "acid-acorn-acre-acts-afar-affix", "wifi_ack": True})
        self.assertEqual(self.journal, ["begin", "select_for_update", "get", "save", "commit"])

    def test_writes_onto_a_fresh_read_not_the_request_user(self):
        # The flow's copy of the user is stale: another change landed meanwhile.
        stale = FakeUser(attributes={"settings": {"locale": "en"}})
        self.user.attributes["settings"] = {"locale": "de"}
        self.assertTrue(self.run_save({"wifi_password": "acid-acorn-acre-acts-afar-affix", "wifi_ack": True},
                                      request_user=stale))
        self.assertEqual(self.user.attributes["settings"], {"locale": "de"})
        self.assertIn("wifi-password-nthash", self.user.attributes)
        self.assertEqual(stale.saves, [])

    def test_refuses_a_value_that_is_not_the_pending_one(self):
        ok = self.run_save({"wifi_password": "attacker-chosen", "wifi_ack": True})
        self.assertFalse(ok)
        self.assertNotIn("wifi-password-nthash", self.user.attributes)
        self.assertTrue(self.messages)

    def test_requires_the_checkbox_to_be_exactly_true(self):
        for ack in (False, "true", "True", 1, None):
            with self.subTest(ack=ack):
                data = {"wifi_password": "acid-acorn-acre-acts-afar-affix"}
                if ack is not None:
                    data["wifi_ack"] = ack
                self.assertFalse(self.run_save(data))
                self.assertNotIn("wifi-password-nthash", self.user.attributes)

    def test_nothing_pending(self):
        self.session.clear()
        self.assertFalse(self.run_save({"wifi_password": "", "wifi_ack": True}))

    def test_database_error_writes_nothing(self):
        self.journal = install_fakes({1: self.user}, broken=True)
        self.assertFalse(self.run_save({"wifi_password": "acid-acorn-acre-acts-afar-affix", "wifi_ack": True}))
        self.assertNotIn("wifi-password-nthash", self.user.attributes)
        self.assertIn("wifi_password_pending", self.session)


class BlueprintTest(unittest.TestCase):
    def test_committed_blueprint_is_current(self):
        self.assertEqual(build_blueprint.OUT.read_text(encoding="utf-8"), build_blueprint.render())


if __name__ == "__main__":
    unittest.main()
