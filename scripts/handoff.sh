#!/usr/bin/env bash
# The handoff from Terraform to Ansible: write each stack's current outputs to JSON files
# that Ansible's variables read (ansible/inventories/group_vars/aws.yml).
#
#   scripts/handoff.sh ap-southeast-2
#
# Each file comes straight from the stack that owns the values. Run it again before any
# playbook that follows a Terraform change, so Ansible never works from old outputs.
set -euo pipefail
region=${1:?usage: handoff.sh <region>}
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/ansible/.tfout"
"$root/scripts/tf.sh" output 20-eks      "$region" > "$root/ansible/.tfout/$region.json"
"$root/scripts/tf.sh" output 15-database "$region" > "$root/ansible/.tfout/$region-database.json"
echo "Wrote ansible/.tfout/$region.json and $region-database.json" >&2
