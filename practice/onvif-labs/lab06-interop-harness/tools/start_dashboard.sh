#!/bin/bash
export PATH=/home/huanglin/.nix-profile/bin:$PATH
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
cd "$(dirname "$0")/.."
exec /tmp/onvif-venv/bin/python tools/dashboard.py \
  --host 192.168.1.4 \
  --password "$(grep -oP '(?<=ONVIF_AUTH_PASS ")[^"]+' main/onvif_secrets.h)" \
  --listen 19999
