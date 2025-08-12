#!/usr/bin/env bash
set -euo pipefail

# === Config ===
RPC="http://127.0.0.1:8546"              # rpcdaemon endpoint
DATADIR="/home/ilya/erigon-data"         # live Erigon datadir
STAGE_BASE="/home/ilya/srv/snaps/stage"  # rsync copy destination
OUT_BASE="/home/ilya/srv/snaps/out"      # chunks + manifest destination
CHUNK="1G"
ZSTD_THREADS="${ZSTD_THREADS:-8}"
CLIENT_NAME="erigon"
CLIENT_VER="3.x"
CLIENT_FLAGS="--prune.mode=archive --db.writemap=true --http=false"
CHAIN="mainnet"                          # consider "eth-mainnet" for consistency
FORK="${FORK:-safe}"                     # safe|finalized|latest
DICT=""                                  # optional zstd dictionary path

# === Compute layout_id (compatibility fingerprint) ===
PRUNE_MODE="archive"   # keep in sync with your actual prune mode
KV="mdbx"
ANCIENTS="default"
MAJOR="3"
compat="name=erigon;major=$MAJOR;prune=$PRUNE_MODE;kv=$KV;ancients=$ANCIENTS"
LAYOUT_ID=$(printf "%s" "$compat" | sha256sum | awk '{print $1}')

ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now="$(ts_utc)"

echo "[1/8] Probing RPC (finalized/safe/latest)"
get_block() {
  local tag="$1"
  curl -sf "$RPC" -H 'content-type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$tag\",false],\"id\":1}" \
  | jq -r '.result'
}
blk_finalized="$(get_block finalized)"
blk_safe="$(get_block safe)"
blk_latest="$(get_block latest)"

blk_sel="$(jq -n --argjson f "$blk_finalized" --argjson s "$blk_safe" --argjson l "$blk_latest" --arg fork "$FORK" \
          '{"finalized":$f,"safe":$s,"latest":$l}[$fork]')"

hex_h="$(jq -r '.number' <<<"$blk_sel")"
H=$((16#${hex_h#0x}))  # numeric height
snap_name="erigon-${H}-$(date -u +%Y%m%dT%H%M%SZ)"
STAGE_DIR="${STAGE_BASE}/${snap_name}"
OUT_DIR="${OUT_BASE}/${snap_name}"
mkdir -p "$STAGE_DIR" "$OUT_DIR/chaindata"

echo "[2/8] First rsync (node running) → $STAGE_DIR"
rsync -aHAX --numeric-ids --delete \
  --exclude='logs/**' \
  --exclude='tmp/**' \
  --exclude='cache/**' \
  --exclude='temp/**' \
  --exclude='etl-temp/**' \
  --exclude='**/mdbx.lck' \
  --info=progress2 \
  "$DATADIR/." "$STAGE_DIR/" \
  || { ec=$?; if [ $ec -ne 24 ]; then echo "[rsync] failed with code $ec"; exit $ec; else echo "[rsync] some files vanished (code 24) — OK"; fi; }

echo "[3/8] Send SIGTERM to Erigon and wait for clean shutdown. Press Enter when done."
read -r _

echo "[4/8] Second rsync (delta, minutes) → $STAGE_DIR"
rsync -aHAX --numeric-ids --delete \
  --exclude='logs/**' \
  --exclude='tmp/**' \
  --exclude='cache/**' \
  --exclude='temp/**' \
  --exclude='etl-temp/**' \
  --exclude='**/mdbx.lck' \
  --info=progress2 \
  "$DATADIR/." "$STAGE_DIR/"

echo "[5/8] You can start Erigon back now. Press Enter after it starts."
read -r _

echo "[6/8] Packing (tar|zstd|split → 1 GiB) from $STAGE_DIR to $OUT_DIR/chaindata"
cd "$STAGE_DIR"
ionice -c2 -n7 nice -n19 bash -c '
  TAR="tar --numeric-owner --owner=0 --group=0 --xattrs --acls -cf - ."
  if [[ -n "'"$DICT"'" ]]; then
    eval "$TAR" | zstd -T'"$ZSTD_THREADS"' --long=31 -19 --no-check --stdout --dict="'"$DICT"'" \
      | split -b '"$CHUNK"' - "'"$OUT_DIR"'/chaindata/part_"
  else
    eval "$TAR" | zstd -T'"$ZSTD_THREADS"' --long=31 -19 --no-check --stdout \
      | split -b '"$CHUNK"' - "'"$OUT_DIR"'/chaindata/part_"
  fi
'
a=1; for f in "$OUT_DIR"/chaindata/part_*; do mv "$f" "$(printf "%s/chaindata/%04d.zst" "$OUT_DIR" "$a")"; a=$((a+1)); done

echo "[7/8] Indexing parts (size + sha256)"
parts_json="$(bash -c '
  DIR="'"$OUT_DIR"'/chaindata"
  first=1; echo -n "["
  for f in $(ls -1 "$DIR"/*.zst | sort); do
    sz=$(stat -c%s "$f"); sh=$(sha256sum "$f" | awk "{print \$1}"); bn=$(basename "$f")
    [[ $first -eq 0 ]] && echo -n ","
    printf "{\"path\":\"chaindata/%s\",\"size\":%s,\"sha256\":\"%s\",\"url\":\"\"}" "$bn" "$sz" "$sh"
    first=0
  done
  echo -n "]"
')"

dict_field=""
if [[ -n "$DICT" ]]; then dict_field="sha256:$(sha256sum "$DICT" | awk '{print $1}')"; fi

echo "[8/8] Building manifest.json"
jq -n \
  --arg schema "snapsmith/v1" \
  --arg chain  "$CHAIN" \
  --arg name   "$CLIENT_NAME" \
  --arg ver    "$CLIENT_VER" \
  --arg flags  "$CLIENT_FLAGS" \
  --arg layout "erigon-full" \
  --arg algo   "zstd" \
  --arg chunksize "1GiB" \
  --arg dict   "$dict_field" \
  --arg time   "$now" \
  --arg layout_id "$LAYOUT_ID" \
  --argjson height "$H" \
  --argjson sel "$blk_sel" \
  --argjson parts "$parts_json" '
{
  schema:$schema,
  chain:$chain,
  client:{
    name:$name,
    version:$ver,
    flags:($flags|split(" ")),
    layout_id:$layout_id
  },
  height: $height,
  timestamp: $time,
  roots:{
    stateRoot:    $sel.stateRoot,
    blockHash:    $sel.hash,
    txRoot:       $sel.transactionsRoot,
    receiptsRoot: $sel.receiptsRoot
  },
  artifact:{
    layout:$layout,
    compress:{algo:$algo, dict:($dict//""), chunkSize:$chunksize},
    parts:$parts
  },
  checks:{}
}' > "$OUT_DIR/manifest.json"

man_sha="$(jq -c 'del(.signatures)' "$OUT_DIR/manifest.json" | sha256sum | awk '{print $1}')"
jq --arg ms "$man_sha" '.checks.manifestSha256=$ms' "$OUT_DIR/manifest.json" > "$OUT_DIR/.m" && mv "$OUT_DIR/.m" "$OUT_DIR/manifest.json"

# Placeholder: real Ed25519 signing will be added via snapsmith CLI
jq '.signatures=[{"alg":"ed25519","pub":"","sig":""}]' "$OUT_DIR/manifest.json" > "$OUT_DIR/manifest.signed.json"

echo
echo "✅ Done:"
echo "  OUT:       $OUT_DIR"
echo "  PARTS:     $OUT_DIR/chaindata"
echo "  MANIFEST:  $OUT_DIR/manifest.signed.json (without real signature yet)"
