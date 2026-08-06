#!/usr/bin/env bash
# Contract for the MinIO companion image.
#
# Safebucket fatals at boot if its bucket does not exist, and the browser
# uploads/downloads files directly against this service with presigned URLs,
# which means CORS preflights must succeed. Both are baked into the image, so
# both are asserted here before anything is published.
#
# Usage: ./test/minio_test.sh [image-tag]
set -uo pipefail

IMG="${1:-safebucket-railway-minio:test}"
NAME="minio-contract-test-$$"
PORT=19000
PW="test-secret-$$"
FAILED=0

pass() { printf '  ok    %s\n' "$1"; }
fail() {
  printf '  FAIL  %s\n' "$1"
  printf '        expected: %s\n' "$2"
  printf '        actual:   %s\n' "$3"
  FAILED=1
}

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "minio_test: $IMG"

docker run -d --name "$NAME" \
  -e MINIO_ROOT_USER=safebucket \
  -e MINIO_ROOT_PASSWORD="$PW" \
  -e SAFEBUCKET_S3_BUCKET=safebucket \
  -e PORT=$PORT \
  -p "$PORT:$PORT" "$IMG" >/dev/null 2>&1

# 1. Starts a server with no arguments supplied by the platform.
health=""
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/minio/health/live" 2>/dev/null)
  if [[ "$code" == "200" ]]; then health=ok; break; fi
  sleep 1
done
if [[ "$health" == "ok" ]]; then
  pass "serves on \$PORT with no start command"
else
  fail "serves on \$PORT with no start command" "health endpoint returning 200" \
       "$(docker logs "$NAME" 2>&1 | tail -5)"
fi

# 2. The bucket Safebucket expects must already exist, or the app fatals at
#    boot on a storage service that otherwise looks healthy.
# The bucket is created after the server answers its health check, so this has
# to poll rather than check once. docker exec does not inherit the entrypoint's
# environment either, so the mc config directory has to be passed again.
buckets=""
for _ in $(seq 1 20); do
  buckets=$(docker exec -e MC_CONFIG_DIR=/tmp/.mc "$NAME" mc ls local 2>&1)
  [[ "$buckets" == *safebucket* ]] && break
  sleep 1
done
if [[ "$buckets" == *safebucket* ]]; then
  pass "creates the safebucket bucket on first boot"
else
  fail "creates the safebucket bucket on first boot" "a bucket named safebucket" "$buckets"
fi

# 3. Safebucket's storage client uses path-style S3 addressing, so the bucket
#    has to be reachable at /<bucket> rather than as a host prefix.
code=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PORT/safebucket/" 2>/dev/null)
if [[ "$code" == "403" || "$code" == "200" ]]; then
  pass "answers path-style requests for the bucket (HTTP $code)"
else
  fail "answers path-style requests for the bucket" "403 or 200" "HTTP $code"
fi

# 4. The web UI PUTs presigned uploads straight to this service from the
#    browser, so the CORS preflight for a cross-origin PUT must be allowed.
cors=$(curl -s -o /dev/null -D - -X OPTIONS \
  -H "Origin: https://app.example.com" \
  -H "Access-Control-Request-Method: PUT" \
  "http://127.0.0.1:$PORT/safebucket/some-object" 2>/dev/null)
if echo "$cors" | grep -qi "access-control-allow-origin"; then
  pass "allows cross-origin preflight for presigned uploads"
else
  fail "allows cross-origin preflight for presigned uploads" \
       "an Access-Control-Allow-Origin response header" \
       "$(echo "$cors" | head -3 | tr '\n' ' ')"
fi

echo
if [[ $FAILED -eq 0 ]]; then
  echo "minio_test: PASS"
else
  echo "minio_test: FAIL"
fi
exit $FAILED
