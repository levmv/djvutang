#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

npm ci --no-audit --no-fund
npx playwright install --with-deps chromium webkit
