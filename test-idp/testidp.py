#!/usr/bin/env python3
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
"""The test IdP's tooling (#27): its secrets, its realms and its sign-in checks.

Python's standard library only (the deploy pipeline's image has python3, and
nothing is installed). No command prints a secret: those that make one write
it to a new file the caller names, mode 0600, and print only that file's name
(#55); a password or a token is never in an argument, a log line or an error
message.

  testidp.py secret PURPOSE FILE      the secret derived for PURPOSE (see derive), into FILE
  testidp.py new-seed FILE            a fresh seed, into FILE
  testidp.py render REALM.json FILE   the realm with its client secrets, pairwise
                                      salt and user passwords filled in, as Keycloak
                                      imports it on every start (test-idp/apply.sh), into FILE
  testidp.py claims ISSUER_URL REALM.json USERNAME
                                      signs USERNAME in with the realm's claims-check client
                                      (authorization code + PKCE) and checks its ID token's shape
  testidp.py tacplus HOST ISSUER_URL REALM.json USERNAME
                                      signs USERNAME in at https://HOST through oauth (Authorize,
                                      the realm's login page, MintCallbackTokens) and checks the
                                      kernel session names the realm and the user's sub
  testidp.py remove ADMIN_URL REALM.json USERNAME
                                      deletes the user at the IdP
  testidp.py refused ISSUER_URL REALM.json USERNAME
                                      succeeds only if the realm refuses USERNAME's sign-in

Seeds come from the environment, never from an argument: TEST_IDP_SEED (user
passwords, the admin password) and TEST_IDP_CLIENT_SEED (the tacplus-dev
clients' secrets, the pairwise salts).
"""

import base64
import hashlib
import hmac
import html.parser
import http.cookiejar
import json
import os
import re
import secrets as pysecrets
import sys
import urllib.error
import urllib.parse
import urllib.request

# The id_token claim check's client and its redirect: same host as tacplus.dev's
# client, so a pairwise sub is the same for both.
CHECK_CLIENT = "claims-check"
CHECK_REDIRECT = "https://seatrials.tacplus.dev/test-idp/claims"
TACPLUS_CLIENT = "tacplus-dev"
# oauth.yaml's provider for each realm.
PROVIDER_NAMES = {"google": "Test Google", "microsoft": "Test Microsoft", "apple": "Test Apple"}
ADMIN_USER = "admin"
# The tid of Microsoft personal accounts (consumers), as Entra issues it.
MSA_TID = "9188040d-6c67-4c5b-b112-36a304b66dad"


class Failure(Exception):
    """A check that failed; its message names what, never a secret."""


# ---- secrets ---------------------------------------------------------------

def seed_for(purpose):
    """The seed variable a purpose is derived from."""
    if purpose.startswith(("client/", "pairwise-salt/")):
        return "TEST_IDP_CLIENT_SEED"
    if purpose == "admin" or purpose.startswith("user/"):
        return "TEST_IDP_SEED"
    raise Failure(f"no seed for purpose [{purpose}]")


def derive(seed, purpose):
    """A test secret: HMAC-SHA256(seed, purpose), base64url without padding
    (43 characters of A-Z a-z 0-9 _ -, so GitLab can mask it).

    Purposes: admin; user/<realm>/<username>; client/<realm>/tacplus-dev;
    pairwise-salt/<realm>."""
    if len(seed) < 32:
        raise Failure("the seed is shorter than 32 characters")
    mac = hmac.new(seed.encode(), ("fleet-seatrials/test-idp/" + purpose).encode(), hashlib.sha256)
    return base64.urlsafe_b64encode(mac.digest()).rstrip(b"=").decode()


def secret(purpose, env=None):
    env = os.environ if env is None else env
    name = seed_for(purpose)
    seed = env.get(name, "")
    if not seed:
        raise Failure(f"{name} is not set")
    return derive(seed, purpose)


def new_seed():
    """A fresh seed, for the pipeline to store when none is set."""
    return pysecrets.token_urlsafe(48)


def write_new(path, what, text):
    """Writes text to a new file at path, mode 0600, and prints only its name.
    Never to stdout, a terminal or a file already there: O_EXCL refuses every
    path that exists (/dev/stdout, /dev/tty), so the mode is always 0600; "-",
    which means stdout to the caller, is refused before it becomes a file."""
    if path == "-":
        raise Failure(f"{what}: - is stdout: it is written nowhere else")
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError as err:
        raise Failure(f"{what}: {path} is not a new file ({err.strerror}): it is written nowhere else") from None
    with os.fdopen(fd, "w") as f:
        os.fchmod(fd, 0o600)
        f.write(text)
    print(f"{what}: written to {path}")


# ---- realms ----------------------------------------------------------------

def render(realm, env=None):
    """The realm as Keycloak imports it: each tacplus-dev client gets its
    secret, each pairwise sub mapper its salt, each user a password."""
    realm = json.loads(json.dumps(realm))
    name = realm["realm"]
    for client in realm.get("clients", []):
        if client["clientId"] == TACPLUS_CLIENT:
            client["secret"] = secret(f"client/{name}/{TACPLUS_CLIENT}", env)
        for mapper in client.get("protocolMappers", []):
            if mapper.get("protocolMapper") == "oidc-sha256-pairwise-sub-mapper":
                mapper.setdefault("config", {})["pairwiseSubAlgorithmSalt"] = secret(f"pairwise-salt/{name}", env)
    for user in realm.get("users", []):
        user["credentials"] = [{"type": "password", "temporary": False,
                                "value": secret(f"user/{name}/{user['username']}", env)}]
    return realm


def find_user(realm, username):
    for user in realm.get("users", []):
        if user["username"] == username:
            return user
    raise Failure(f"realm {realm['realm']} has no user {username}")


# ---- HTTP ------------------------------------------------------------------

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Http:
    """A small browser: a cookie jar, redirects followed only when asked."""

    def __init__(self):
        jar = http.cookiejar.CookieJar()
        self.follow = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        self.stay = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect)

    def request(self, method, url, data=None, headers=None, follow=True, form=False, token=None):
        body = None
        headers = dict(headers or {})
        if data is not None:
            if form:
                body = urllib.parse.urlencode(data).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                body = json.dumps(data).encode()
                headers["Content-Type"] = "application/json"
        if token:
            headers["Authorization"] = "Bearer " + token
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with (self.follow if follow else self.stay).open(req, timeout=30) as resp:
                return resp.status, dict(resp.headers), resp.read().decode()
        except urllib.error.HTTPError as err:
            return err.code, dict(err.headers), err.read().decode(errors="replace")
        except urllib.error.URLError as err:
            raise Failure(f"{method} {strip_query(url)}: {err.reason}") from None

    def json(self, method, url, data=None, form=False, token=None, want=(200,)):
        status, _, body = self.request(method, url, data, form=form, token=token)
        if status not in want:
            raise Failure(f"{method} {strip_query(url)}: HTTP {status}")
        return json.loads(body) if body.strip() else None


def strip_query(url):
    return url.split("?", 1)[0]


class LoginForm(html.parser.HTMLParser):
    """The action of Keycloak's login form (form id kc-form-login), and any
    error message on the page."""

    def __init__(self):
        super().__init__()
        self.action = None
        self.error = None
        self._in_error = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form" and a.get("id") == "kc-form-login":
            self.action = a.get("action")
        if "kc-feedback-text" in (a.get("class") or "") or a.get("id") == "input-error":
            self._in_error = True

    def handle_data(self, data):
        if self._in_error and data.strip():
            self.error = (self.error or "") + data.strip()
            self._in_error = False


def login_form(page):
    form = LoginForm()
    form.feed(page)
    return form


def sign_in_at_idp(browser, authorize_url, username, password, redirect_prefix):
    """Follows authorize_url to the realm's login page, submits the user's
    password and answers the query of the redirect back to redirect_prefix
    (code and state), without loading it."""
    status, _, page = browser.request("GET", authorize_url)
    if status != 200:
        raise Failure(f"the realm's authorize page answered HTTP {status}")
    form = login_form(page)
    if not form.action:
        raise Failure("the realm's authorize page holds no login form")
    status, headers, page = browser.request(
        "POST", form.action, {"username": username, "password": password, "credentialId": ""},
        form=True, follow=False)
    location = headers.get("Location") or headers.get("location") or ""
    if status not in (302, 303) or not location.startswith(redirect_prefix):
        why = login_form(page).error if status == 200 else None
        raise Failure(f"{username}: the realm did not sign in (HTTP {status}"
                      + (f": {why}" if why else "") + ")")
    query = urllib.parse.parse_qs(urllib.parse.urlsplit(location).query)
    if "error" in query:
        raise Failure(f"{username}: the realm answered error {query['error'][0]}")
    return {k: v[0] for k, v in query.items()}


# ---- JWT -------------------------------------------------------------------

def b64url(data):
    return base64.urlsafe_b64decode(data + "=" * (-len(data) % 4))


SHA256_DIGEST_INFO = bytes.fromhex("3031300d060960864801650304020105000420")


# ---- Ed25519 (RFC 8032), verification only ---------------------------------
ED_P = 2**255 - 19
ED_L = 2**252 + 27742317777372353535851937790883648493
ED_D = -121665 * pow(121666, ED_P - 2, ED_P) % ED_P
ED_I = pow(2, (ED_P - 1) // 4, ED_P)


def ed_add(a, b):
    """The sum of two points in extended coordinates (X, Y, Z, T)."""
    A, B = (a[1] - a[0]) * (b[1] - b[0]) % ED_P, (a[1] + a[0]) * (b[1] + b[0]) % ED_P
    C, D = 2 * a[3] * b[3] * ED_D % ED_P, 2 * a[2] * b[2] % ED_P
    E, F, G, H = B - A, D - C, D + C, B + A
    return (E * F % ED_P, G * H % ED_P, F * G % ED_P, E * H % ED_P)


def ed_mul(n, point):
    out = (0, 1, 1, 0)
    while n:
        if n & 1:
            out = ed_add(out, point)
        point = ed_add(point, point)
        n >>= 1
    return out


def ed_point(data):
    """The point 32 bytes encode, or None when they encode none."""
    if len(data) != 32:
        return None
    y = int.from_bytes(data, "little")
    sign, y = y >> 255, y & ((1 << 255) - 1)
    if y >= ED_P:
        return None
    x2 = (y * y - 1) * pow(ED_D * y * y + 1, ED_P - 2, ED_P) % ED_P
    x = pow(x2, (ED_P + 3) // 8, ED_P)
    if (x * x - x2) % ED_P:
        x = x * ED_I % ED_P
    if (x * x - x2) % ED_P or (x == 0 and sign):
        return None
    if x & 1 != sign:
        x = ED_P - x
    return (x, y, 1, x * y % ED_P)


ED_B = ed_point((4 * pow(5, ED_P - 2, ED_P) % ED_P).to_bytes(32, "little"))


def ed25519_verifies(public, message, signature):
    """Whether signature is public's Ed25519 signature of message."""
    A, R = ed_point(public), ed_point(signature[:32]) if len(signature) == 64 else None
    if A is None or R is None:
        return False
    s = int.from_bytes(signature[32:], "little")
    if s >= ED_L:
        return False
    h = int.from_bytes(hashlib.sha512(signature[:32] + public + message).digest(), "little") % ED_L
    left, right = ed_mul(s, ED_B), ed_add(R, ed_mul(h, A))
    return (left[0] * right[2] - right[0] * left[2]) % ED_P == 0 and (left[1] * right[2] - right[1] * left[2]) % ED_P == 0


def verify_jwt(token, jwks):
    """The claims of a JWT whose signature verifies with a key of jwks: RS256, as
    the realms sign their ID tokens, or EdDSA (Ed25519), as kernel signs its
    sessions."""
    try:
        header_b64, payload_b64, sig_b64 = token.split(".")
        header = json.loads(b64url(header_b64))
    except ValueError:
        raise Failure("the token is not a JWT") from None
    alg, kid = header.get("alg"), header.get("kid")
    signed = f"{header_b64}.{payload_b64}".encode()
    if alg == "EdDSA":
        keys = [k for k in jwks.get("keys", [])
                if k.get("kid") == kid and k.get("kty") == "OKP" and k.get("crv") == "Ed25519"]
        if not keys:
            raise Failure(f"no Ed25519 key {kid} in the JWKS")
        if not ed25519_verifies(b64url(keys[0]["x"]), signed, b64url(sig_b64)):
            raise Failure("the token's signature does not verify")
        return json.loads(b64url(payload_b64))
    if alg != "RS256":
        raise Failure(f"the token is signed {alg}, neither RS256 nor EdDSA")
    keys = [k for k in jwks.get("keys", []) if k.get("kid") == kid and k.get("kty") == "RSA"]
    if not keys:
        raise Failure(f"no RSA key {kid} in the JWKS")
    n = int.from_bytes(b64url(keys[0]["n"]), "big")
    e = int.from_bytes(b64url(keys[0]["e"]), "big")
    k = (n.bit_length() + 7) // 8
    em = pow(int.from_bytes(b64url(sig_b64), "big"), e, n).to_bytes(k, "big")
    digest = hashlib.sha256(signed).digest()
    want = b"\x00\x01" + b"\xff" * (k - 3 - len(SHA256_DIGEST_INFO) - len(digest)) + b"\x00" + SHA256_DIGEST_INFO + digest
    if not hmac.compare_digest(em, want):
        raise Failure("the token's signature does not verify")
    return json.loads(b64url(payload_b64))


# ---- shapes ----------------------------------------------------------------

GUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
APPLE_SUB = re.compile(r"^[0-9]{6}\.[0-9a-f]{32}\.[0-9]{4}$")


def attr(user, name):
    values = user.get("attributes", {}).get(name) or []
    return values[0] if values else None


def check_shape(realm_name, user, claims):
    """The problems with an ID token's claims, as the realm's provider would
    shape them for this user; empty when it has that shape."""
    problems = []

    def want(cond, what):
        if not cond:
            problems.append(what)

    def is_bool(name):
        return isinstance(claims.get(name), bool)

    email = user.get("email")
    if realm_name == "google":
        want(claims.get("sub") == user["id"] and user["id"].isdigit(), "sub is the account's decimal id")
        want(claims.get("email") == email, "email is the account's")
        want(is_bool("email_verified") and claims["email_verified"] == user.get("emailVerified", False),
             "email_verified is a boolean, the account's")
        want(claims.get("hd") == attr(user, "hd"), "hd is the Workspace domain, absent for a consumer account")
        want(claims.get("name") == f"{user.get('firstName', '')} {user.get('lastName', '')}".strip(), "name")
        want(claims.get("picture") == attr(user, "picture"), "picture")
        want("tid" not in claims and "is_private_email" not in claims, "no other provider's claims")
    elif realm_name == "microsoft":
        want(claims.get("ver") == "2.0", "ver is 2.0")
        want(GUID.match(claims.get("tid") or "") is not None and claims.get("tid") == attr(user, "tid"),
             "tid is the directory's GUID")
        want(GUID.match(claims.get("oid") or "") is not None and claims.get("oid") == attr(user, "oid"),
             "oid is the account's object GUID")
        want(isinstance(claims.get("sub"), str) and claims["sub"] not in (user["id"], attr(user, "oid")),
             "sub is pairwise, neither the oid nor the account id")
        want(claims.get("preferred_username") == attr(user, "upn"), "preferred_username is the UPN")
        if email:
            want(claims.get("email") == email, "email is the account's")
        else:
            want("email" not in claims, "email is absent: the account has none")
        edov = attr(user, "xms_edov")
        if edov is None:
            want("xms_edov" not in claims, "xms_edov is absent")
        else:
            want(is_bool("xms_edov") and claims["xms_edov"] == (edov == "true"), "xms_edov is a boolean")
        want("email_verified" not in claims, "no email_verified: Microsoft sends none")
        want("hd" not in claims and "is_private_email" not in claims, "no other provider's claims")
    elif realm_name == "apple":
        want(APPLE_SUB.match(claims.get("sub") or "") is not None and claims.get("sub") == attr(user, "apple_sub"),
             "sub is the Apple team-scoped id (000000.<32 hex>.0000)")
        want(claims.get("email") == email, "email is the account's, or its relay address")
        want(is_bool("email_verified") and claims["email_verified"] is True, "email_verified is true")
        relay = (email or "").endswith("@privaterelay.appleid.test")
        want(is_bool("is_private_email") and claims["is_private_email"] == relay,
             "is_private_email is true exactly for a relay address")
        want(isinstance(claims.get("real_user_status"), int)
             and claims["real_user_status"] == int(attr(user, "real_user_status") or -1),
             "real_user_status is the account's integer (0, 1, 2)")
        want(not any(k in claims for k in ("name", "given_name", "family_name", "picture")),
             "no name in the ID token: Apple sends it once, outside the token")
        want("tid" not in claims and "hd" not in claims, "no other provider's claims")
    else:
        problems.append(f"no shape for realm {realm_name}")
    return problems


# ---- the commands -----------------------------------------------------------

def admin_token(browser, admin_url):
    tok = browser.json("POST", f"{admin_url}/realms/master/protocol/openid-connect/token",
                       {"grant_type": "password", "client_id": "admin-cli", "username": ADMIN_USER,
                        "password": secret("admin")}, form=True)
    return tok["access_token"]


def remove(admin_url, realm, username):
    browser = Http()
    token = admin_token(browser, admin_url)
    name = realm["realm"]
    found = browser.json("GET", f"{admin_url}/admin/realms/{name}/users?exact=true&username="
                         + urllib.parse.quote(username), token=token)
    for u in found:
        browser.json("DELETE", f"{admin_url}/admin/realms/{name}/users/{u['id']}", token=token, want=(204,))
    print(f"{name}: {username} removed at the IdP" if found else f"{name}: {username} was not there")


def pkce():
    verifier = pysecrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    return verifier, challenge


def realm_endpoints(browser, issuer):
    disc = browser.json("GET", f"{issuer}/.well-known/openid-configuration")
    if disc.get("issuer") != issuer:
        raise Failure(f"discovery names issuer [{disc.get('issuer')}], not {issuer}")
    return disc, browser.json("GET", disc["jwks_uri"])


def id_token_claims(issuer, realm, username):
    """Signs username in with the claims-check client; the verified ID token's claims."""
    browser = Http()
    disc, jwks = realm_endpoints(browser, issuer)
    verifier, challenge = pkce()
    state, nonce = pysecrets.token_urlsafe(16), pysecrets.token_urlsafe(16)
    scope = "openid email name" if realm["realm"] == "apple" else "openid email profile"
    url = disc["authorization_endpoint"] + "?" + urllib.parse.urlencode({
        "client_id": CHECK_CLIENT, "response_type": "code", "redirect_uri": CHECK_REDIRECT, "scope": scope,
        "state": state, "nonce": nonce, "code_challenge": challenge, "code_challenge_method": "S256"})
    got = sign_in_at_idp(browser, url, username, secret(f"user/{realm['realm']}/{username}"), CHECK_REDIRECT)
    if got.get("state") != state:
        raise Failure("the realm returned another state")
    tok = browser.json("POST", disc["token_endpoint"], {
        "grant_type": "authorization_code", "client_id": CHECK_CLIENT, "code": got["code"],
        "redirect_uri": CHECK_REDIRECT, "code_verifier": verifier}, form=True)
    claims = verify_jwt(tok["id_token"], jwks)
    if claims.get("iss") != issuer or claims.get("aud") not in (CHECK_CLIENT, [CHECK_CLIENT]) \
            or claims.get("nonce") != nonce:
        raise Failure("the ID token's iss, aud or nonce is not the request's")
    return claims


def claims_check(issuer, realm, username):
    user = find_user(realm, username)
    claims = id_token_claims(issuer, realm, username)
    problems = check_shape(realm["realm"], user, claims)
    shown = {k: claims[k] for k in sorted(claims) if k not in ("exp", "iat", "auth_time", "jti", "nonce", "sid", "at_hash")}
    if problems:
        raise Failure(f"{realm['realm']}/{username}: not the provider's shape: " + "; ".join(problems)
                      + f" (claims {json.dumps(shown, sort_keys=True)})")
    print(f"ok   claims {realm['realm']}/{username}: {json.dumps(shown, sort_keys=True)}")
    return claims


def refused(issuer, realm, username):
    try:
        id_token_claims(issuer, realm, username)
    except Failure as err:
        print(f"ok   refused {realm['realm']}/{username}: {err}")
        return
    raise Failure(f"{realm['realm']}/{username}: the realm still signs the user in")


def find_strings(value, path=""):
    """Every (path, string) in a JSON value."""
    if isinstance(value, dict):
        for k, v in value.items():
            yield from find_strings(v, f"{path}.{k}" if path else k)
    elif isinstance(value, list):
        for i, v in enumerate(value):
            yield from find_strings(v, f"{path}[{i}]")
    elif isinstance(value, str):
        yield path, value


def tacplus_check(host, issuer, realm, username):
    """The full sign-in at tacplus.dev, as a browser does it: the realm's
    provider from ListProviders, Authorize, the realm's login page, the
    redirect back to https://HOST/ (not loaded), MintCallbackTokens. The kernel
    session's access token must verify with the host's JWKS and name the realm
    as the issuer and the user's sub, as the realm's own ID token has it."""
    base = f"https://{host}"
    name = PROVIDER_NAMES[realm["realm"]]
    expect = claims_check(issuer, realm, username)
    browser = Http()
    listed = browser.json("POST", f"{base}/oauth/Auth/ListProviders", {})
    index = next((p.get("providerIndex", p.get("provider_index", 0)) for p in listed.get("providers", [])
                  if p.get("name") == name), None)
    if index is None:
        raise Failure(f"{host} lists no provider {name} (its client secret is not in place?)")
    auth = browser.json("POST", f"{base}/oauth/Auth/Authorize", {"provider_index": index, "callback_url": base + "/"})
    redirect = auth.get("redirectUrl") or auth.get("redirect_url") or ""
    if not redirect.startswith(issuer + "/"):
        raise Failure(f"{name}'s Authorize does not send to {issuer}")
    if f"client_id={TACPLUS_CLIENT}" not in redirect:
        raise Failure(f"{name}'s Authorize does not name client_id {TACPLUS_CLIENT}")
    got = sign_in_at_idp(browser, redirect, username, secret(f"user/{realm['realm']}/{username}"), base + "/")
    minted = browser.json("POST", f"{base}/oauth/Auth/MintCallbackTokens", {"code": got["code"], "state": got["state"]})
    access = minted.get("accessToken") or minted.get("access_token")
    if not access or not (minted.get("refreshToken") or minted.get("refresh_token")):
        raise Failure(f"{name}/{username}: MintCallbackTokens returned no kernel session")
    _, host_jwks = realm_endpoints(browser, base)
    session = verify_jwt(access, host_jwks)
    strings = dict(find_strings(session))
    named = sorted(p for p, v in strings.items() if v == issuer)
    subbed = sorted(p for p, v in strings.items() if v == expect["sub"] or v.endswith("|" + expect["sub"]))
    if not named or not subbed:
        raise Failure(f"{name}/{username}: the kernel session does not name "
                      + ("the realm as issuer" if not named else "the user's sub")
                      + f" (its claims: {', '.join(sorted(session))})")
    print(f"ok   tacplus {host} {name}/{username}: kernel session, issuer at {', '.join(named)}, "
          f"sub at {', '.join(subbed)}")


def load(path):
    with open(path) as f:
        return json.load(f)


def main(argv):
    cmd, args = (argv[1], argv[2:]) if len(argv) > 1 else ("", [])
    try:
        if cmd == "secret" and len(args) == 2:
            write_new(args[1], f"secret {args[0]}", secret(args[0]))
        elif cmd == "new-seed" and len(args) == 1:
            write_new(args[0], "new seed", new_seed())
        elif cmd == "render" and len(args) == 2:
            write_new(args[1], f"realm {args[0]}", json.dumps(render(load(args[0]))))
        elif cmd == "claims" and len(args) == 3:
            claims_check(args[0].rstrip("/"), load(args[1]), args[2])
        elif cmd == "tacplus" and len(args) == 4:
            tacplus_check(args[0], args[1].rstrip("/"), load(args[2]), args[3])
        elif cmd == "remove" and len(args) == 3:
            remove(args[0].rstrip("/"), load(args[1]), args[2])
        elif cmd == "refused" and len(args) == 3:
            refused(args[0].rstrip("/"), load(args[1]), args[2])
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except Failure as err:
        print(f"FAIL {err}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
