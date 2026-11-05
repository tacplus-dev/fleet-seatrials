#!/usr/bin/env bash
# Copyright (c) 2026 Jody Scott
# SPDX-License-Identifier: Apache-2.0
#
# kubectl diff's external diff program (KUBECTL_EXTERNAL_DIFF, set by
# deploy/diff.sh): kubectl writes each object of the render, as it is live and
# as it would be after the apply, into two directories, one file per object
# named <group>.<version>.<Kind>.<namespace>.<name>, and calls this with both.
#
#   deploy/diff-names.sh LIVE MERGED
#
# It prints how each object that differs does (added, removed, changed) and its
# name, never its content: the render carries the fleet's Secrets, its service
# configs and the gateway's certificate key, and the job log is not a place
# for them.
#
# Exit status as kubectl expects of a diff program: 0 no difference, 1 some.
set -euo pipefail
live=$1 merged=$2
changed=0
for name in $( (ls -A "$live"; ls -A "$merged") | sort -u); do
  if [ -f "$live/$name" ] && [ -f "$merged/$name" ] && cmp -s "$live/$name" "$merged/$name"; then
    continue
  fi
  changed=1
  if [ ! -f "$live/$name" ]; then how=added; elif [ ! -f "$merged/$name" ]; then how=removed; else how=changed; fi
  echo "$how: $name"
done
exit "$changed"
