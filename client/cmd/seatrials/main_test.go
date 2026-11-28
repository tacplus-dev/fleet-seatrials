// Copyright (c) 2026 Jody Scott
// SPDX-License-Identifier: Apache-2.0

package main

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	credentials_pb "github.com/tacplus-dev/fleet-seatrials/client/tacplus/types/common/credentials"
)

func ids(pairs []*credentials_pb.CredPair) []string {
	out := []string{}
	for _, p := range pairs {
		out = append(out, p.GetId())
	}
	return out
}

func pairs(ids ...string) []*credentials_pb.CredPair {
	out := []*credentials_pb.CredPair{}
	for _, id := range ids {
		out = append(out, &credentials_pb.CredPair{Id: id})
	}
	return out
}

// tenant cred keeps every other pair, and replaces one of the same id.
func TestWithPairKeepsOthers(t *testing.T) {
	got := ids(withPair(pairs("alpha-1", "ci-alpha-1", "alpha-2"), &credentials_pb.CredPair{Id: "alpha-2"}, ""))
	if want := []string{"alpha-1", "ci-alpha-1", "alpha-2"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// tenant cred --replace drops the earlier pairs of the credential's name, and
// only those: the client-steps job's fresh pair each run leaves one (#77).
func TestWithPairReplacesTheName(t *testing.T) {
	got := ids(withPair(pairs("ci-alpha-1", "alpha-1", "ci-alpha-2", "ci-alphabet-1"), &credentials_pb.CredPair{Id: "ci-alpha-3"}, "ci-alpha"))
	if want := []string{"alpha-1", "ci-alphabet-1", "ci-alpha-3"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// SEATRIALS_HOME is where keys and tokens live when it is set.
func TestHomeFromTheEnvironment(t *testing.T) {
	d := filepath.Join(t.TempDir(), "seatrials")
	t.Setenv("SEATRIALS_HOME", d)
	got, err := home()
	if err != nil || got != d {
		t.Fatalf("home() = %q, %v; want %q", got, err, d)
	}
	if fi, err := os.Stat(d); err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("%s: %v, %v; want a directory 0700", d, fi, err)
	}
}
