// Copyright (c) 2026 Jody Scott
// SPDX-License-Identifier: Apache-2.0

// seatrials is the local client of the proof fleet. It authenticates with a
// credential pair (an EC key whose public JWK the fleet's config holds),
// exchanges a signed proof for a kernel-minted token through the gateway, and
// calls the fleet's client-facing services with it.
//
//	seatrials keygen NAME [--tenant /tenants/alpha] [--grant TOKEN]...   # prints the cred_pair to configure
//	seatrials login  [--as NAME]                                          # proof → token (~/.seatrials/NAME.token)
//	seatrials tenant create NAMESPACE [--as root]
//	seatrials tenant cred NAMESPACE CREDNAME [--as root]                  # installs CREDNAME's pair under the tenant
//	seatrials ping MESSAGE [--as NAME]
//	seatrials ask QUESTION [--as NAME] [--context TEXT]...
//
// Every command prints JSON. Keys and tokens live in ~/.seatrials (0600).
package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	sm "github.com/tacplus-dev/fleet-seatrials/client/tacplus/c2sm"
	"github.com/tacplus-dev/fleet-seatrials/client/tacplus/chassis/key"
	"github.com/tacplus-dev/fleet-seatrials/client/tacplus/chassis/token"
	credentials_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/common/credentials"
	entitlements_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/generated/entitlements"
	tenant_config_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/generated/tenant_config"
	doppelganger_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/services/doppelganger"
	kernel_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/services/kernel"
	tenantecho_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/services/tenantecho"
	jwk_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/sys/jwk"
	key_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/sys/key"
	token_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/sys/token"
	tokenrequest_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/sys/tokenrequest"
)

var (
	gateway = envOr("SEATRIALS_GATEWAY", "schematic.146.148.80.132.nip.io:443")
	caFile  = envOr("SEATRIALS_CA", "")
)

func envOr(k, d string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return d
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		printJSON(map[string]string{"error": err.Error()})
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: seatrials keygen|login|tenant|ping|ask ...")
	}
	switch args[0] {
	case "keygen":
		return keygen(args[1:])
	case "login":
		return login(args[1:])
	case "tenant":
		if len(args) < 2 {
			return errors.New("usage: seatrials tenant create|cred ...")
		}
		switch args[1] {
		case "create":
			return tenantCreate(args[2:])
		case "cred":
			return tenantCred(args[2:])
		}
		return fmt.Errorf("unknown tenant command %q", args[1])
	case "ping":
		return ping(args[1:])
	case "ask":
		return ask(args[1:])
	}
	return fmt.Errorf("unknown command %q", args[0])
}

// ---------------------------------------------------------------- credentials

func home() (string, error) {
	h, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(h, ".seatrials")
	return d, os.MkdirAll(d, 0o700)
}

type credFile struct {
	Key     json.RawMessage `json:"key"`  // sys/key.Key as protojson (private)
	Pair    json.RawMessage `json:"pair"` // common/credentials.CredPair as protojson (public)
	PairID  string          `json:"pair_id"`
	Tenant  string          `json:"tenant"`
	Created int64           `json:"created"`
}

func loadCred(name string) (*credFile, *key.ImmutableKey, error) {
	d, err := home()
	if err != nil {
		return nil, nil, err
	}
	data, err := os.ReadFile(filepath.Join(d, name+".cred.json"))
	if err != nil {
		return nil, nil, fmt.Errorf("no credential %q: run seatrials keygen %s (%w)", name, name, err)
	}
	var cf credFile
	if err := json.Unmarshal(data, &cf); err != nil {
		return nil, nil, err
	}
	var k key_pb.Key
	if err := protojson.Unmarshal(cf.Key, &k); err != nil {
		return nil, nil, err
	}
	ik, err := key.NewImmutableKey(&k)
	if err != nil {
		return nil, nil, err
	}
	return &cf, ik, nil
}

type stringList []string

func (s *stringList) String() string     { return fmt.Sprint(*s) }
func (s *stringList) Set(v string) error { *s = append(*s, v); return nil }

// keygen makes a credential pair: the private key stays in ~/.seatrials, the
// public half is printed as the cred_pair the fleet config (operator.yaml
// root_cred_pairs, or a tenant's kernel.cred_pairs) must carry.
func keygen(args []string) error {
	fs := flag.NewFlagSet("keygen", flag.ContinueOnError)
	tenant := fs.String("tenant", "/", `owning tenant namespace: "/" for the root pair, or /tenants/<name>`)
	var grants stringList
	fs.Var(&grants, "grant", "entitlement grant token (repeatable); default KERNEL_ANY for root, TENANTECHO_ANY+DOPPELGANGER_ANY otherwise")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: seatrials keygen NAME [--tenant NS] [--grant TOKEN]...")
	}
	name := fs.Arg(0)
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	kp, err := key.NewKey(priv)
	if err != nil {
		return err
	}
	idb := make([]byte, 8)
	if _, err := rand.Read(idb); err != nil {
		return err
	}
	pairID := name + "-" + hex.EncodeToString(idb)
	kp.Id = pairID // the key is known by the pair id it backs; the proof's kid is the same
	if len(grants) == 0 {
		if *tenant == "/" {
			grants = []string{"KERNEL_ANY"}
		} else {
			grants = []string{"TENANTECHO_ANY", "DOPPELGANGER_ANY"}
		}
	}
	now := time.Now().Unix()
	pair := &credentials_pb.CredPair{
		Id:         pairID,
		TenantName: *tenant,
		PublicKey: &jwk_pb.Jwk{
			Kty:     key_pb.KeyType_KEY_TYPE_EC,
			Alg:     "ES256",
			Kid:     pairID,
			Use:     jwk_pb.JwkUseType_JWK_USE_TYPE_SIG,
			Crv:     "P-256",
			X:       base64.RawURLEncoding.EncodeToString(priv.X.FillBytes(make([]byte, 32))),
			Y:       base64.RawURLEncoding.EncodeToString(priv.Y.FillBytes(make([]byte, 32))),
			Created: now,
		},
		Entitlements: &entitlements_pb.TokenEntitlements{Grants: grants},
		Namespaces:   []string{"*"},
		Description:  "seatrials client " + name,
	}
	keyJSON, err := protojson.Marshal(kp)
	if err != nil {
		return err
	}
	pairJSON, err := protojson.MarshalOptions{UseProtoNames: true}.Marshal(pair)
	if err != nil {
		return err
	}
	d, err := home()
	if err != nil {
		return err
	}
	cf := credFile{Key: keyJSON, Pair: pairJSON, PairID: pairID, Tenant: *tenant, Created: now}
	data, _ := json.MarshalIndent(cf, "", "  ")
	if err := os.WriteFile(filepath.Join(d, name+".cred.json"), data, 0o600); err != nil {
		return err
	}
	// The public half, as the config wants it.
	var pairMap map[string]any
	_ = json.Unmarshal(pairJSON, &pairMap)
	printJSON(map[string]any{"credential": name, "file": filepath.Join(d, name+".cred.json"), "cred_pair": pairMap})
	return nil
}

// ---------------------------------------------------------------- transport

func dial() (*grpc.ClientConn, error) {
	pool, err := x509.SystemCertPool()
	if err != nil || pool == nil {
		pool = x509.NewCertPool()
	}
	if caFile != "" {
		pem, err := os.ReadFile(caFile)
		if err != nil {
			return nil, fmt.Errorf("reading CA %s: %w", caFile, err)
		}
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("no certificates in %s", caFile)
		}
	}
	host := gateway
	if i := strings.LastIndex(host, ":"); i > 0 {
		host = host[:i]
	}
	return grpc.NewClient(gateway, grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{RootCAs: pool, ServerName: host, MinVersion: tls.VersionTLS13})))
}

func tokenPath(name string) (string, error) {
	d, err := home()
	if err != nil {
		return "", err
	}
	return filepath.Join(d, name+".token"), nil
}

func savedToken(name string) func() (string, error) {
	return func() (string, error) {
		p, err := tokenPath(name)
		if err != nil {
			return "", err
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return "", fmt.Errorf("not logged in as %q: run seatrials login --as %s (%w)", name, name, err)
		}
		return strings.TrimSpace(string(b)), nil
	}
}

func manager(name string) (*sm.ServiceManager, func(), error) {
	conn, err := dial()
	if err != nil {
		return nil, nil, err
	}
	return sm.New(conn, savedToken(name)), func() { conn.Close() }, nil
}

// ---------------------------------------------------------------- login

// login signs a short-lived proof with the credential's key (kid = the pair id,
// audience kernel, a fresh jti) and exchanges it for a kernel-minted token
// through the gateway (kernel.Mint/MintClientToken carries its own proof, so no
// bearer is needed for that one call).
func login(args []string) error {
	fs := flag.NewFlagSet("login", flag.ContinueOnError)
	as := fs.String("as", "root", "credential name")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cf, ik, err := loadCred(*as)
	if err != nil {
		return err
	}
	now := time.Now().Unix()
	jti := make([]byte, 16)
	if _, err := rand.Read(jti); err != nil {
		return err
	}
	proof := token.NewImmutableToken(&token_pb.Token{})
	proof.SetKid(cf.PairID).SetIssuer("seatrials").SetSubject(cf.PairID).SetAudience("kernel").
		SetIssuedAt(now).SetExpiration(now + 30).SetJTI(hex.EncodeToString(jti))
	if err := proof.Sign(ik); err != nil {
		return fmt.Errorf("signing proof: %w", err)
	}
	conn, err := dial()
	if err != nil {
		return err
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// MintClientToken is self-authenticating: the generated client would attach a
	// bearer we do not have yet, so it is called on the raw stub.
	resp, err := kernel_pb.NewMintClient(conn).MintClientToken(ctx, &tokenrequest_pb.MintClientTokenRequest{InputToken: proof.GetBase64()})
	if err != nil {
		return fmt.Errorf("MintClientToken: %w", err)
	}
	tok := resp.GetAccessToken().GetBase64()
	if tok == "" {
		return errors.New("MintClientToken returned no access token")
	}
	p, err := tokenPath(*as)
	if err != nil {
		return err
	}
	if err := os.WriteFile(p, []byte(tok+"\n"), 0o600); err != nil {
		return err
	}
	parsed, _ := token.ParseToken(tok)
	out := map[string]any{"credential": *as, "token_file": p, "token_received": true}
	if parsed != nil {
		out["subject"] = parsed.GetSubject()
		out["namespace"] = parsed.GetNamespace()
		out["audience"] = parsed.GetAudience()
	}
	printJSON(out)
	return nil
}

// ---------------------------------------------------------------- tenants

func tenantCreate(args []string) error {
	fs := flag.NewFlagSet("tenant create", flag.ContinueOnError)
	as := fs.String("as", "root", "credential name (a root pair)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: seatrials tenant create /tenants/NAME [--as root]")
	}
	m, done, err := manager(*as)
	if err != nil {
		return err
	}
	defer done()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	t, err := m.Grpc().Clients().Services().TenantAdminClient().CreateTenant(ctx, &kernel_pb.CreateTenantRequest{TenantNamespace: fs.Arg(0)})
	if err != nil {
		return err
	}
	return printProto(t)
}

// tenantCred installs a credential pair (made by keygen --tenant NS) under the
// tenant: the pair's owner decides the namespace its tokens carry.
func tenantCred(args []string) error {
	fs := flag.NewFlagSet("tenant cred", flag.ContinueOnError)
	as := fs.String("as", "root", "credential name (a root pair)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 2 {
		return errors.New("usage: seatrials tenant cred /tenants/NAME CREDNAME [--as root]")
	}
	ns, credName := fs.Arg(0), fs.Arg(1)
	cf, _, err := loadCred(credName)
	if err != nil {
		return err
	}
	var pair credentials_pb.CredPair
	if err := protojson.Unmarshal(cf.Pair, &pair); err != nil {
		return err
	}
	if pair.GetTenantName() != ns {
		return fmt.Errorf("credential %q was made for tenant %q, not %q", credName, pair.GetTenantName(), ns)
	}
	m, done, err := manager(*as)
	if err != nil {
		return err
	}
	defer done()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	admin := m.Grpc().Clients().Services().TenantAdminClient()
	cfg, err := admin.GetTenantConfig(ctx, &kernel_pb.GetTenantConfigRequest{TenantNamespace: ns})
	if err != nil {
		return fmt.Errorf("GetTenantConfig: %w", err)
	}
	if cfg.Kernel == nil {
		cfg.Kernel = &credentials_pb.KernelTenantConfig{}
	}
	kept := cfg.Kernel.CredPairs[:0]
	for _, cp := range cfg.Kernel.CredPairs {
		if cp.GetId() != pair.GetId() {
			kept = append(kept, cp)
		}
	}
	cfg.Kernel.CredPairs = append(kept, &pair)
	out, err := admin.UpdateTenantConfig(ctx, &kernel_pb.SetTenantConfigRequest{TenantNamespace: ns, Config: cfg})
	if err != nil {
		return fmt.Errorf("UpdateTenantConfig: %w", err)
	}
	_ = out
	printJSON(map[string]any{"tenant": ns, "cred_pair": pair.GetId(), "cred_pairs": len(cfg.Kernel.CredPairs)})
	return nil
}

var _ *tenant_config_pb.TenantConfig // the type GetTenantConfig returns; kept named for readers

// ---------------------------------------------------------------- the proofs

func ping(args []string) error {
	fs := flag.NewFlagSet("ping", flag.ContinueOnError)
	as := fs.String("as", "root", "credential name")
	if err := fs.Parse(args); err != nil {
		return err
	}
	msg := strings.Join(fs.Args(), " ")
	if msg == "" {
		msg = "ping"
	}
	m, done, err := manager(*as)
	if err != nil {
		return err
	}
	defer done()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	resp, err := m.Grpc().Clients().Services().TenantEchoClient().Ping(ctx, &tenantecho_pb.PingRequest{Message: msg})
	if err != nil {
		return err
	}
	return printProto(resp)
}

func ask(args []string) error {
	fs := flag.NewFlagSet("ask", flag.ContinueOnError)
	as := fs.String("as", "root", "credential name")
	var ctxs stringList
	fs.Var(&ctxs, "context", "session context (repeatable)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	q := strings.Join(fs.Args(), " ")
	if q == "" {
		return errors.New("usage: seatrials ask QUESTION [--as NAME] [--context TEXT]...")
	}
	m, done, err := manager(*as)
	if err != nil {
		return err
	}
	defer done()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	c := m.Grpc().Clients().Services().DoppelgangerClient()
	sess, err := c.CreateSession(ctx, &doppelganger_pb.CreateSessionRequest{Context: ctxs})
	if err != nil {
		return err
	}
	resp, err := c.GenerateAnswer(ctx, &doppelganger_pb.GenerateAnswerRequest{SessionId: sess.GetSessionId(), Question: q})
	if err != nil {
		return err
	}
	return printProto(resp)
}

// ---------------------------------------------------------------- output

func printProto(m proto.Message) error {
	b, err := protojson.MarshalOptions{UseProtoNames: true, EmitUnpopulated: true}.Marshal(m)
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}

func printJSON(v any) {
	b, _ := json.MarshalIndent(v, "", "  ")
	fmt.Println(string(b))
}
