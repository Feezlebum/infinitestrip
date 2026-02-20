#!/bin/bash
# Infinite Strip — image generation script
# Usage:
#   ./generate.sh seed              → generate Day 001 from scratch
#   ./generate.sh next              → generate next day using last published image
#   ./generate.sh batch 7           → generate N days sequentially from last published
#
# Images saved to: /home/clawd/clawd/infinitestrip/strip/day-NNN.png
# Manifest updated: /home/clawd/clawd/infinitestrip/manifest.json
# GitHub: auto-committed and pushed after each successful generation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STRIP_DIR="/home/clawd/clawd/infinitestrip/strip"
MANIFEST="/home/clawd/clawd/infinitestrip/manifest.json"
REPO_DIR="/tmp/infinitestrip-repo"
SHARE_DIR="/tmp/share"

source ~/.bashrc 2>/dev/null || true
API_KEY="${GEMINI_API_KEY:-}"
if [[ -z "$API_KEY" ]]; then
  API_KEY=$(grep 'GEMINI_API_KEY' ~/.bashrc | head -1 | sed 's/.*=//' | tr -d '"' | tr -d "'")
fi

MODEL="gemini-3-pro-image-preview"
API_URL="https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"

SEED_PROMPT='You are the creator of Infinite Strip — an everlasting comic book published one page per day with no human authorship and no predetermined ending. This is Page 1.

Generate the very first page: 4 panels arranged in a 2x2 grid. Art style: vibrant, bold, cinematic — classic X-Men and 90s Marvel energy. Rich saturated colours, dramatic lighting, expressive characters, dynamic poses, bold ink outlines. Full of life, not grimdark.

You have total creative freedom over the world, the characters, and the opening situation. Invent something worth returning to every day.

Include dialogue bubbles and panel text where the story calls for it. All text must be clearly legible, correctly spelled, and placed so it does not obscure key artwork. Prioritise readability — if in doubt, use less text rather than more.

End on a moment that makes tomorrow feel necessary.

Output: a single high-resolution image showing 4 comic panels in a 2x2 layout.'

CONTINUE_PROMPT='You are the sole author and artist of Infinite Strip — an everlasting comic published daily with no human intervention and no predetermined ending. You have total creative authority.

Here is yesterday'\''s page.

Generate the next page: 4 panels in a 2x2 grid.

Two rules only: preserve the established art style, colour palette, and character designs from the reference image — and pick up directly from where the story left off. Everything else is yours. Time can jump. Characters can change. The world can fracture. Dreams, flashbacks, new characters, genre shifts, moments of pure silence — nothing is off limits. Safe storytelling is the only failure condition. The greatest comic authors do not telegraph what'\''s coming. Neither should you.

For any text, dialogue, or captions: ensure all text is clearly legible, correctly spelled, and positioned so it does not obscure key artwork. Use less text rather than risk illegibility.

End on something that makes tomorrow feel necessary.

Output: a single high-resolution image showing 4 comic panels in a 2x2 layout, exactly matching the established style.'

mkdir -p "$STRIP_DIR" "$SHARE_DIR"

# ── Get current day count from manifest ──
get_last_day() {
  python3 -c "
import json
try:
    d = json.load(open('$MANIFEST'))
    strips = d.get('strips', [])
    print(strips[-1]['day'] if strips else 0)
except:
    print(0)
"
}

# ── Format day number ──
pad_day() {
  printf '%03d' "$1"
}

# ── Format date ──
today_date() {
  date -u +%Y-%m-%d
}

# ── Update manifest ──
update_manifest() {
  local day="$1"
  local date_str="$2"
  local file="strip/day-$(pad_day $day).png"
  python3 -c "
import json
try:
    d = json.load(open('$MANIFEST'))
except:
    d = {'total': 0, 'strips': []}
entry = {'day': $day, 'date': '$date_str', 'label': 'Day $(pad_day $day)', 'file': '$file'}
d['strips'].append(entry)
d['total'] = len(d['strips'])
json.dump(d, open('$MANIFEST','w'), indent=2)
print('Manifest updated: day $day')
"
}

# ── Call Gemini API ──
call_api_text_only() {
  local prompt="$1"
  local output="$2"
  local max_retries=8
  local wait=20

  for i in $(seq 1 $max_retries); do
    echo "  → API call attempt $i/$max_retries..."
    local response
    response=$(curl -s --max-time 150 -X POST "$API_URL?key=${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"contents\":[{\"parts\":[{\"text\":$(echo "$prompt"|python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}]}],\"generationConfig\":{\"responseModalities\":[\"image\",\"text\"]}}")

    if [[ -z "$response" ]]; then
      echo "  ✗ Empty response — waiting ${wait}s..."
      sleep $wait; wait=$((wait + 10)); continue
    fi

    local result
    result=$(echo "$response" | python3 -c "
import json,sys,base64
data=json.loads(sys.stdin.read())
for part in data.get('candidates',[{}])[0].get('content',{}).get('parts',[]):
    if 'inlineData' in part:
        with open('$output','wb') as f:
            f.write(base64.b64decode(part['inlineData']['data']))
        print('OK')
        exit()
err=data.get('error',{})
print('ERR:',err.get('code','?'),'|',err.get('message','?')[:80])
" 2>&1)

    if [[ "$result" == "OK" ]]; then
      echo "  ✓ Image saved: $output"
      return 0
    else
      echo "  ✗ $result — waiting ${wait}s..."
      sleep $wait; wait=$((wait + 10))
    fi
  done

  echo "ERROR: Failed after $max_retries attempts"
  return 1
}

# ── Call API with image reference ──
call_api_with_image() {
  local prompt="$1"
  local ref_image="$2"
  local output="$3"
  local max_retries=8
  local wait=20
  local payload_file="/tmp/is_payload_$$.json"

  # Write prompt + build payload file (avoids "argument list too long")
  printf '%s' "$prompt" > /tmp/is_prompt_$$.txt
  python3 -c "
import json, base64
prompt = open('/tmp/is_prompt_$$.txt').read()
img_b64 = base64.b64encode(open('$ref_image','rb').read()).decode()
payload = {
    'contents': [{'parts': [
        {'text': prompt},
        {'inlineData': {'mimeType': 'image/png', 'data': img_b64}}
    ]}],
    'generationConfig': {'responseModalities': ['image', 'text']}
}
json.dump(payload, open('$payload_file','w'))
"

  for i in $(seq 1 $max_retries); do
    echo "  → API call attempt $i/$max_retries (with image ref)..."
    local response_file="/tmp/is_response_$$.json"
    curl -s --max-time 150 -X POST "$API_URL?key=${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "@$payload_file" \
      -o "$response_file"

    if [[ ! -s "$response_file" ]]; then
      echo "  ✗ Empty response — waiting ${wait}s..."
      sleep $wait; wait=$((wait + 10)); continue
    fi

    local result
    result=$(python3 -c "
import json,sys,base64
data=json.load(open('$response_file'))
for part in data.get('candidates',[{}])[0].get('content',{}).get('parts',[]):
    if 'inlineData' in part:
        with open('$output','wb') as f:
            f.write(base64.b64decode(part['inlineData']['data']))
        print('OK')
        exit()
err=data.get('error',{})
print('ERR:',err.get('code','?'),'|',err.get('message','?')[:80])
" 2>&1)

    if [[ "$result" == "OK" ]]; then
      echo "  ✓ Image saved: $output"
      rm -f "$payload_file" "$response_file" "/tmp/is_prompt_$$.txt"
      return 0
    else
      echo "  ✗ $result — waiting ${wait}s..."
      sleep $wait; wait=$((wait + 10))
    fi
  done

  rm -f "$payload_file" "$response_file" "/tmp/is_prompt_$$.txt"
  echo "ERROR: Failed after $max_retries attempts"
  return 1
}

# ── Commit and push ──
commit_and_push() {
  local day="$1"
  local padded=$(pad_day $day)

  # Sync repo
  cd "$REPO_DIR"
  git pull --rebase origin master 2>/dev/null || true
  cp "$STRIP_DIR/day-${padded}.png" "$REPO_DIR/strip/day-${padded}.png"
  cp "$MANIFEST" "$REPO_DIR/manifest.json"
  git add .
  git commit -m "Day ${padded} — $(date -u +%Y-%m-%d)" 2>/dev/null || echo "Nothing to commit"
  git push origin master
  echo "  ✓ Pushed to GitHub: day-${padded}.png"

  # Copy to share
  cp "$STRIP_DIR/day-${padded}.png" "$SHARE_DIR/day-${padded}.png"
}

# ── MAIN ──
MODE="${1:-next}"
COUNT="${2:-1}"

case "$MODE" in

  seed)
    echo "=== Generating Day 001 (seed) ==="
    OUT="$STRIP_DIR/day-001.png"
    call_api_text_only "$SEED_PROMPT" "$OUT"
    update_manifest 1 "$(today_date)"
    commit_and_push 1
    echo "=== Day 001 complete ==="
    ;;

  next)
    LAST=$(get_last_day)
    NEXT=$((LAST + 1))
    PADDED_LAST=$(pad_day $LAST)
    PADDED_NEXT=$(pad_day $NEXT)
    REF="$STRIP_DIR/day-${PADDED_LAST}.png"
    OUT="$STRIP_DIR/day-${PADDED_NEXT}.png"
    echo "=== Generating Day $NEXT (continuing from Day $LAST) ==="
    if [[ ! -f "$REF" ]]; then echo "ERROR: reference image not found: $REF"; exit 1; fi
    call_api_with_image "$CONTINUE_PROMPT" "$REF" "$OUT"
    update_manifest $NEXT "$(today_date)"
    commit_and_push $NEXT
    echo "=== Day $NEXT complete ==="
    ;;

  batch)
    echo "=== Generating batch of $COUNT days ==="
    for i in $(seq 1 $COUNT); do
      LAST=$(get_last_day)
      NEXT=$((LAST + 1))
      PADDED_LAST=$(pad_day $LAST)
      PADDED_NEXT=$(pad_day $NEXT)
      REF="$STRIP_DIR/day-${PADDED_LAST}.png"
      OUT="$STRIP_DIR/day-${PADDED_NEXT}.png"
      echo "--- [$i/$COUNT] Day $NEXT ---"
      if [[ ! -f "$REF" ]]; then echo "ERROR: ref not found: $REF"; exit 1; fi
      call_api_with_image "$CONTINUE_PROMPT" "$REF" "$OUT"
      update_manifest $NEXT "$(date -u -d "+$((i-1)) days" +%Y-%m-%d 2>/dev/null || date -u -v+$((i-1))d +%Y-%m-%d)"
      commit_and_push $NEXT
      echo "  ✓ Day $NEXT done"
      sleep 5
    done
    echo "=== Batch complete: $COUNT days generated ==="
    ;;

  *)
    echo "Usage: $0 [seed|next|batch N]"
    exit 1
    ;;
esac
