#!/usr/bin/env python3
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
"""Tests of test-idp/testidp.py that need no Keycloak: the secret derivation,
the render (secrets in, nothing leaked, the shape hash), the claim shapes, the
login form and the RS256 check. test-idp/local.sh runs the realms on a real
Keycloak. Run by test-idp/testidp_test.sh; the realms come as JSON in
TEST_IDP_REALMS_JSON (a directory), converted from the YAML with yq."""

import base64
import json
import os
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import testidp as t  # noqa: E402

ENV = {"TEST_IDP_SEED": "s" * 40, "TEST_IDP_CLIENT_SEED": "c" * 40}
REALMS = os.environ.get("TEST_IDP_REALMS_JSON", "")


def realm(name):
    with open(os.path.join(REALMS, f"{name}.json")) as f:
        return json.load(f)


class Secrets(unittest.TestCase):
    def test_derive_is_stable_and_maskable(self):
        a = t.derive("x" * 32, "user/google/ada@alpha.test")
        self.assertEqual(a, t.derive("x" * 32, "user/google/ada@alpha.test"))
        self.assertRegex(a, r"^[A-Za-z0-9_-]{43}$")
        self.assertNotEqual(a, t.derive("x" * 32, "user/google/una@personal.test"))
        self.assertNotEqual(a, t.derive("y" * 32, "user/google/ada@alpha.test"))

    def test_known_value(self):
        # HMAC-SHA256(key "k"*32, "fleet-seatrials/test-idp/admin"), base64url: the
        # derivation is a contract with every holder of the seed (the hub too).
        self.assertEqual(t.derive("k" * 32, "admin"), "BRZdOb6WjtJ0lmXRh_CaJx3H2A9of3aH9wjW3W2ySIE")

    def test_short_seed_refused(self):
        with self.assertRaises(t.Failure):
            t.derive("short", "admin")

    def test_seed_per_purpose(self):
        self.assertEqual(t.seed_for("admin"), "TEST_IDP_SEED")
        self.assertEqual(t.seed_for("user/apple/cy@personal.test"), "TEST_IDP_SEED")
        self.assertEqual(t.seed_for("client/apple/tacplus-dev"), "TEST_IDP_CLIENT_SEED")
        self.assertEqual(t.seed_for("pairwise-salt/microsoft"), "TEST_IDP_CLIENT_SEED")
        with self.assertRaises(t.Failure):
            t.seed_for("other")

    def test_unset_seed_names_the_variable_only(self):
        with self.assertRaises(t.Failure) as err:
            t.secret("client/google/tacplus-dev", {"TEST_IDP_SEED": "s" * 40})
        self.assertIn("TEST_IDP_CLIENT_SEED is not set", str(err.exception))


@unittest.skipUnless(REALMS, "TEST_IDP_REALMS_JSON is not set")
class Realms(unittest.TestCase):
    def test_files_hold_no_secret(self):
        for name in ("google", "microsoft", "apple"):
            text = json.dumps(realm(name))
            for key in ('"secret"', '"credentials"', '"pairwiseSubAlgorithmSalt"', '"password"'):
                self.assertNotIn(key, text, f"{name}.yaml holds {key}")

    def test_each_realm_has_both_clients_and_its_name(self):
        for name in ("google", "microsoft", "apple"):
            r = realm(name)
            self.assertEqual(r["realm"], name)
            clients = {c["clientId"]: c for c in r["clients"]}
            self.assertEqual(set(clients), {t.TACPLUS_CLIENT, t.CHECK_CLIENT})
            self.assertFalse(clients[t.TACPLUS_CLIENT]["publicClient"])
            self.assertTrue(clients[t.CHECK_CLIENT]["publicClient"])
            self.assertEqual(clients[t.CHECK_CLIENT]["attributes"]["pkce.code.challenge.method"], "S256")
            self.assertEqual(clients[t.CHECK_CLIENT]["redirectUris"], [t.CHECK_REDIRECT])
            ids = [u["id"] for u in r["users"]]
            self.assertEqual(len(ids), len(set(ids)), f"{name}: a user id twice")

    def test_render_fills_secrets_from_the_seeds(self):
        r = t.render(realm("microsoft"), ENV)
        client = next(c for c in r["clients"] if c["clientId"] == t.TACPLUS_CLIENT)
        self.assertEqual(client["secret"], t.derive(ENV["TEST_IDP_CLIENT_SEED"], "client/microsoft/tacplus-dev"))
        check = next(c for c in r["clients"] if c["clientId"] == t.CHECK_CLIENT)
        self.assertNotIn("secret", check)
        salts = {m["config"]["pairwiseSubAlgorithmSalt"] for c in r["clients"] for m in c.get("protocolMappers", [])}
        self.assertEqual(salts, {t.derive(ENV["TEST_IDP_CLIENT_SEED"], "pairwise-salt/microsoft")})
        for u in r["users"]:
            self.assertEqual(u["credentials"][0]["value"],
                             t.derive(ENV["TEST_IDP_SEED"], f"user/microsoft/{u['username']}"))
            self.assertFalse(u["credentials"][0]["temporary"])

    def test_render_leaves_the_input_alone(self):
        r = realm("google")
        t.render(r, ENV)
        self.assertNotIn("credentials", json.dumps(r))

    def test_shape_hash_ignores_users_only(self):
        r = realm("google")
        h = t.render(r, ENV)["attributes"][t.SHAPE_ATTRIBUTE]
        r["users"][0]["firstName"] = "Changed"
        self.assertEqual(t.render(r, ENV)["attributes"][t.SHAPE_ATTRIBUTE], h)
        r["accessTokenLifespan"] = 301
        self.assertNotEqual(t.render(r, ENV)["attributes"][t.SHAPE_ATTRIBUTE], h)
        other = dict(ENV, TEST_IDP_CLIENT_SEED="d" * 40)
        self.assertNotEqual(t.render(realm("google"), other)["attributes"][t.SHAPE_ATTRIBUTE], h)

    def test_readme_lists_every_user(self):
        with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "README.md")) as f:
            readme = f.read()
        for name in ("google", "microsoft", "apple"):
            self.assertIn(f"/realms/{name}", readme)
            for u in realm(name)["users"]:
                self.assertIn(f"`{u['username']}`", readme, f"README.md does not list {name}/{u['username']}")

    def test_the_cases(self):
        users = {(n, u["username"]): u for n in ("google", "microsoft", "apple") for u in realm(n)["users"]}
        # One person on two providers.
        self.assertIn(("google", "ada@alpha.test"), users)
        self.assertIn(("microsoft", "ada@alpha.test"), users)
        # An unverified email; an account without email; a relay email.
        self.assertFalse(users[("google", "una@personal.test")]["emailVerified"])
        self.assertNotIn("email", users[("microsoft", "nomail@beta.test")])
        self.assertTrue(users[("apple", "rae@personal.test")]["email"].endswith("@privaterelay.appleid.test"))
        # The removed user.
        self.assertIn(("google", "gone@personal.test"), users)


def google_claims(**over):
    c = {"sub": "104857600000000000001", "email": "ada@alpha.test", "email_verified": True, "hd": "alpha.test",
         "name": "Ada Alpha", "picture": "https://idp.test.tacplus.dev/avatars/ada.png"}
    c.update(over)
    return {k: v for k, v in c.items() if v is not None}


GOOGLE_ADA = {"id": "104857600000000000001", "username": "ada@alpha.test", "email": "ada@alpha.test",
              "emailVerified": True, "firstName": "Ada", "lastName": "Alpha",
              "attributes": {"hd": ["alpha.test"], "picture": ["https://idp.test.tacplus.dev/avatars/ada.png"]}}
MS_NOMAIL = {"id": "ce049696-240a-54f2-8e5d-9dea9849f27b", "username": "nomail@beta.test",
             "attributes": {"tid": ["793d49df-e344-5cca-9783-2304f0ae94dc"],
                            "oid": ["ce049696-240a-54f2-8e5d-9dea9849f27b"], "upn": ["nomail@beta.test"]}}
APPLE_RAE = {"id": "x", "username": "rae@personal.test", "email": "k7q2xw9mzp@privaterelay.appleid.test",
             "attributes": {"apple_sub": ["001666.e0b16139f6b1d1d084c8a63e4d8e99bf.4026"],
                            "is_private_email": ["true"], "real_user_status": ["1"]}}


class Shapes(unittest.TestCase):
    def test_google(self):
        self.assertEqual(t.check_shape("google", GOOGLE_ADA, google_claims()), [])
        self.assertTrue(t.check_shape("google", GOOGLE_ADA, google_claims(email_verified="true")))
        self.assertTrue(t.check_shape("google", GOOGLE_ADA, google_claims(hd=None)))
        self.assertTrue(t.check_shape("google", GOOGLE_ADA, google_claims(tid="x")))

    def test_microsoft(self):
        good = {"ver": "2.0", "tid": "793d49df-e344-5cca-9783-2304f0ae94dc",
                "oid": "ce049696-240a-54f2-8e5d-9dea9849f27b", "sub": "27a2e3cf-ab32-3ff3-9331-b1146c11c700",
                "preferred_username": "nomail@beta.test"}
        self.assertEqual(t.check_shape("microsoft", MS_NOMAIL, good), [])
        self.assertTrue(t.check_shape("microsoft", MS_NOMAIL, dict(good, email="nomail@beta.test")))
        self.assertTrue(t.check_shape("microsoft", MS_NOMAIL, dict(good, sub=good["oid"])), "sub not pairwise")
        self.assertTrue(t.check_shape("microsoft", MS_NOMAIL, dict(good, email_verified=True)))
        self.assertTrue(t.check_shape("microsoft", MS_NOMAIL, dict(good, xms_edov=True)))

    def test_apple(self):
        good = {"sub": "001666.e0b16139f6b1d1d084c8a63e4d8e99bf.4026", "email": APPLE_RAE["email"],
                "email_verified": True, "is_private_email": True, "real_user_status": 1}
        self.assertEqual(t.check_shape("apple", APPLE_RAE, good), [])
        self.assertTrue(t.check_shape("apple", APPLE_RAE, dict(good, is_private_email="true")))
        self.assertTrue(t.check_shape("apple", APPLE_RAE, dict(good, is_private_email=False)))
        self.assertTrue(t.check_shape("apple", APPLE_RAE, dict(good, name="Rae Relay")))
        self.assertTrue(t.check_shape("apple", APPLE_RAE, dict(good, real_user_status="1")))

    def test_unknown_realm(self):
        self.assertTrue(t.check_shape("okta", GOOGLE_ADA, {}))


class LoginPage(unittest.TestCase):
    def test_form_action_and_error(self):
        page = ('<html><form id="kc-form-login" action="https://idp/realms/google/login-actions/authenticate?x=1&amp;y=2">'
                '<span id="input-error" class="pf-m-error">Invalid username or password.</span></form></html>')
        form = t.login_form(page)
        self.assertEqual(form.action, "https://idp/realms/google/login-actions/authenticate?x=1&y=2")
        self.assertEqual(form.error, "Invalid username or password.")

    def test_no_form(self):
        self.assertIsNone(t.login_form("<html><p>We are sorry...</p></html>").action)


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


class Jwt(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.mkdtemp()
        key = os.path.join(cls.dir, "key.pem")
        subprocess.run(["openssl", "genrsa", "-out", key, "2048"], check=True, capture_output=True)
        text = subprocess.run(["openssl", "rsa", "-in", key, "-noout", "-modulus"], check=True,
                              capture_output=True, text=True).stdout
        n = int(text.strip().split("=", 1)[1], 16)
        cls.key = key
        cls.jwks = {"keys": [{"kty": "RSA", "kid": "k1", "n": b64(n.to_bytes(256, "big")), "e": "AQAB"}]}

    def sign(self, claims, kid="k1", alg="RS256"):
        head = b64(json.dumps({"alg": alg, "kid": kid}).encode())
        body = b64(json.dumps(claims).encode())
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", self.key], input=f"{head}.{body}".encode(),
                             check=True, capture_output=True).stdout
        return f"{head}.{body}.{b64(sig)}"

    def test_verifies(self):
        self.assertEqual(t.verify_jwt(self.sign({"sub": "a"}), self.jwks), {"sub": "a"})

    def test_tampered(self):
        head, _, sig = self.sign({"sub": "a"}).split(".")
        with self.assertRaises(t.Failure):
            t.verify_jwt(f"{head}.{b64(json.dumps({'sub': 'b'}).encode())}.{sig}", self.jwks)

    def test_unknown_kid_and_alg(self):
        with self.assertRaises(t.Failure):
            t.verify_jwt(self.sign({"sub": "a"}, kid="k2"), self.jwks)
        with self.assertRaises(t.Failure):
            t.verify_jwt(self.sign({"sub": "a"}, alg="none"), self.jwks)


class Strings(unittest.TestCase):
    def test_find_strings(self):
        found = dict(t.find_strings({"a": {"b": ["x", {"c": "y"}]}, "n": 1}))
        self.assertEqual(found, {"a.b[0]": "x", "a.b[1].c": "y"})


if __name__ == "__main__":
    unittest.main()
