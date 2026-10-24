#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# First-time setup of deploy/bootstrap: the fleet's root CA and cluster PKI. Run
# once per trial (crypto.yaml is the fleet's key material and is not committed);
# operator.yaml and services/*.yaml are committed and win over what init writes.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
export SCHEMATIC_OPERATOR_DIR="$here/deploy/bootstrap"
ip=$(gcloud compute addresses describe seatrials-gateway --region us-central1 --format="value(address)")
[ -x "$here/bin/schematic-operator" ] || "$here/deploy/build-operator.sh"
cp "$SCHEMATIC_OPERATOR_DIR/operator.yaml" /tmp/seatrials-operator.yaml
[ -f "$SCHEMATIC_OPERATOR_DIR/crypto.yaml" ] || "$here/bin/schematic-operator" init ca
"$here/bin/schematic-operator" init cluster --fqdn "schematic.$ip.nip.io" --type small --gateways 1 --dev
# init rewrites operator.yaml from its preset; the committed one is the fleet's.
cp /tmp/seatrials-operator.yaml "$SCHEMATIC_OPERATOR_DIR/operator.yaml"
echo "deploy/bootstrap ready: fqdn schematic.$ip.nip.io, CA in crypto.yaml, ca.pem for the client"
