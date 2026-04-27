#!/usr/bin/env bash
set -euo pipefail

cp inventory/hosts.yml.example inventory/hosts.yml
cp inventory/group_vars/all.yml.example inventory/group_vars/all.yml
cp inventory/group_vars/firephenix.yml.example inventory/group_vars/firephenix.yml
cp inventory/group_vars/vault.yml.example inventory/group_vars/vault.yml
