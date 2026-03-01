#!/bin/bash
# social-tracker.sh - Track social media engagement for conference promotion
#
# Fetches posts from Bluesky and X (personal + conference accounts),
# then invokes Claude to analyze engagement, update historical metrics,
# and email a report.
#
# Permissions granted:
#   - Read/Write (for data/social-metrics.json persistence)
#   - MCP: agentmail (send engagement report email)
#
# Permissions denied:
#   - Bash (no shell access for Claude)
#   - Edit (use Write for full-file updates)
#
# Usage:
#   ./agents/social-tracker.sh              # Run normally
#   ./agents/social-tracker.sh --dry-run    # Show command without running
#   ./agents/social-tracker.sh --verbose    # Show full output

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../lib/agent-helpers.sh"
source "$SCRIPT_DIR/../lib/x-oauth.sh"

BSKY_API="https://public.api.bsky.app/xrpc"
X_API="https://api.x.com/2"
DATA_DIR="$PROJECT_ROOT/data"
METRICS_FILE="$DATA_DIR/social-metrics.json"
FETCH_FILE="$DATA_DIR/social-fetch-latest.json"

# Ensure data directory exists
mkdir -p "$DATA_DIR"

TODAY=$(date +"%Y-%m-%d")
log_info "Starting social tracker for $TODAY"

# --- Bluesky fetcher (no auth needed) ---
# Log messages go to stderr so they don't pollute the captured JSON
fetch_bluesky() {
  local label="$1"
  local handle="$2"

  log_info "Fetching Bluesky $label profile ($handle)..." >&2
  local profile
  profile=$(curl -sf "$BSKY_API/app.bsky.actor.getProfile?actor=$handle" 2>/dev/null) || {
    log_warn "Failed to fetch Bluesky $label profile" >&2
    profile="{}"
  }

  log_info "Fetching Bluesky $label feed..." >&2
  local feed
  feed=$(curl -sf "$BSKY_API/app.bsky.feed.getAuthorFeed?actor=$handle&limit=50" 2>/dev/null) || {
    log_warn "Failed to fetch Bluesky $label feed" >&2
    feed="{}"
  }

  log_ok "Bluesky $label data fetched" >&2
  printf '{"profile":%s,"feed":%s}' "$profile" "$feed"
}

# --- X/Twitter fetcher (OAuth 1.0a) ---
# Sets all four OAuth credentials for the target account
fetch_x() {
  local label="$1"
  local consumer_key="$2"
  local consumer_secret="$3"
  local token="$4"
  local token_secret="$5"

  # Set credentials for x_api_get
  local orig_ck="${X_CONSUMER_KEY:-}"
  local orig_cs="${X_CONSUMER_SECRET:-}"
  local orig_token="${X_ACCESS_TOKEN:-}"
  local orig_secret="${X_ACCESS_TOKEN_SECRET:-}"
  export X_CONSUMER_KEY="$consumer_key"
  export X_CONSUMER_SECRET="$consumer_secret"
  export X_ACCESS_TOKEN="$token"
  export X_ACCESS_TOKEN_SECRET="$token_secret"

  log_info "Fetching X $label user info..." >&2
  local user
  user=$(x_api_get "$X_API/users/me?user.fields=public_metrics,description,username" 2>/dev/null) || {
    log_warn "Failed to fetch X $label user info" >&2
    user="{}"
  }

  local user_id
  user_id=$(echo "$user" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null) || user_id=""

  local tweets="{}"
  if [ -n "$user_id" ]; then
    log_info "Fetching X $label tweets (user $user_id)..." >&2
    tweets=$(x_api_get "$X_API/users/$user_id/tweets?tweet.fields=created_at,public_metrics,non_public_metrics,organic_metrics,text&max_results=100" 2>/dev/null) || {
      log_warn "Retrying X $label tweets without non_public_metrics..." >&2
      tweets=$(x_api_get "$X_API/users/$user_id/tweets?tweet.fields=created_at,public_metrics,text&max_results=100" 2>/dev/null) || {
        log_warn "Failed to fetch X $label tweets" >&2
        tweets="{}"
      }
    }
    log_ok "X $label data fetched" >&2
  else
    log_warn "Could not extract X $label user ID" >&2
  fi

  # Restore original credentials
  export X_CONSUMER_KEY="$orig_ck"
  export X_CONSUMER_SECRET="$orig_cs"
  export X_ACCESS_TOKEN="$orig_token"
  export X_ACCESS_TOKEN_SECRET="$orig_secret"

  printf '{"user":%s,"tweets":%s}' "$user" "$tweets"
}

# --- Fetch Bluesky data (personal + conference) ---
bsky_personal="{}"
bsky_conference="{}"

if [ -n "${BLUESKY_HANDLE_PERSONAL:-}" ]; then
  bsky_personal=$(fetch_bluesky "personal" "$BLUESKY_HANDLE_PERSONAL")
else
  log_warn "BLUESKY_HANDLE_PERSONAL not set, skipping"
fi

if [ -n "${BLUESKY_HANDLE_CONFERENCE:-}" ]; then
  bsky_conference=$(fetch_bluesky "conference" "$BLUESKY_HANDLE_CONFERENCE")
else
  log_warn "BLUESKY_HANDLE_CONFERENCE not set, skipping"
fi

# --- Fetch X/Twitter data (personal + conference) ---
x_personal="{}"
x_conference="{}"

if [ -n "${X_CONSUMER_KEY_PERSONAL:-}" ] && [ -n "${X_CONSUMER_SECRET_PERSONAL:-}" ] && \
   [ -n "${X_ACCESS_TOKEN_PERSONAL:-}" ] && [ -n "${X_ACCESS_TOKEN_SECRET_PERSONAL:-}" ]; then
  x_personal=$(fetch_x "personal" "$X_CONSUMER_KEY_PERSONAL" "$X_CONSUMER_SECRET_PERSONAL" "$X_ACCESS_TOKEN_PERSONAL" "$X_ACCESS_TOKEN_SECRET_PERSONAL")
else
  log_warn "X personal credentials incomplete, skipping"
fi

if [ -n "${X_CONSUMER_KEY_CONFERENCE:-}" ] && [ -n "${X_CONSUMER_SECRET_CONFERENCE:-}" ] && \
   [ -n "${X_ACCESS_TOKEN_CONFERENCE:-}" ] && [ -n "${X_ACCESS_TOKEN_SECRET_CONFERENCE:-}" ]; then
  x_conference=$(fetch_x "conference" "$X_CONSUMER_KEY_CONFERENCE" "$X_CONSUMER_SECRET_CONFERENCE" "$X_ACCESS_TOKEN_CONFERENCE" "$X_ACCESS_TOKEN_SECRET_CONFERENCE")
else
  log_warn "X conference credentials incomplete, skipping"
fi

# --- Load historical metrics ---
historical_metrics="{}"
if [ -f "$METRICS_FILE" ]; then
  historical_metrics=$(cat "$METRICS_FILE")
  log_info "Loaded historical metrics from $METRICS_FILE"
else
  log_info "No historical metrics file found, starting fresh"
fi

# --- Write fetched data to file for Claude to read ---
# Avoids shell quoting issues with large JSON in command-line args
CONFERENCE_NAME="${CONFERENCE_NAME:-Your Conference}"
CONFERENCE_DATE="${CONFERENCE_DATE:-TBD}"

# Write raw data to temp files for Python to read (too large for argv)
RAW_DIR=$(mktemp -d)
trap 'rm -rf "$RAW_DIR"' EXIT
printf '%s\n' "$bsky_personal" > "$RAW_DIR/bsky_p.json"
printf '%s\n' "$bsky_conference" > "$RAW_DIR/bsky_c.json"
printf '%s\n' "$x_personal" > "$RAW_DIR/x_p.json"
printf '%s\n' "$x_conference" > "$RAW_DIR/x_c.json"
printf '%s\n' "$historical_metrics" > "$RAW_DIR/hist.json"

python3 - "$RAW_DIR" "$FETCH_FILE" "$TODAY" "$CONFERENCE_NAME" "$CONFERENCE_DATE" << 'PYEOF'
import json, sys, os
from datetime import datetime, timedelta, timezone

raw_dir, fetch_file, today, conf_name, conf_date = sys.argv[1:6]
cutoff = datetime.now(timezone.utc) - timedelta(days=7)

def read_json(path):
    with open(path) as f:
        return json.load(f)

def parse_dt(s):
    if not s:
        return None
    s = s.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(s)
    except Exception:
        return None

def engagement(p):
    return p.get("likes", 0) + p.get("reposts", 0) + p.get("retweets", 0) + p.get("replies", 0) + p.get("quotes", 0)

def summarize_older(posts):
    if not posts:
        return None
    total_eng = sum(engagement(p) for p in posts)
    avg_eng = round(total_eng / len(posts), 1)
    top = sorted(posts, key=engagement, reverse=True)[:3]
    top_brief = [{"text": p["text"][:80], "likes": p.get("likes",0),
                  "reposts": p.get("reposts", p.get("retweets",0)),
                  "replies": p.get("replies",0)} for p in top]
    return {
        "post_count": len(posts),
        "date_range": {"oldest": posts[-1].get("created_at",""), "newest": posts[0].get("created_at","")},
        "total_engagement": total_eng,
        "avg_engagement_per_post": avg_eng,
        "top_posts": top_brief,
    }

def extract_bluesky(raw):
    if raw == {} or raw.get("profile") == {}:
        return None
    profile = raw.get("profile", {})
    feed_items = raw.get("feed", {}).get("feed", [])
    recent, older = [], []
    for item in feed_items:
        post = item.get("post", {})
        reason = item.get("reason", {})
        is_repost = reason.get("$type") == "app.bsky.feed.defs#reasonRepost"
        p = {
            "uri": post.get("uri", ""),
            "text": post.get("record", {}).get("text", ""),
            "created_at": post.get("record", {}).get("createdAt", ""),
            "likes": post.get("likeCount", 0),
            "reposts": post.get("repostCount", 0),
            "replies": post.get("replyCount", 0),
            "quotes": post.get("quoteCount", 0),
            "is_repost": is_repost,
            "original_author": post.get("author", {}).get("handle", "") if is_repost else None,
        }
        dt = parse_dt(p["created_at"])
        if dt and dt >= cutoff:
            recent.append(p)
        else:
            older.append(p)
    result = {
        "handle": profile.get("handle", ""),
        "display_name": profile.get("displayName", ""),
        "followers": profile.get("followersCount", 0),
        "following": profile.get("followsCount", 0),
        "posts_count": profile.get("postsCount", 0),
        "recent_posts": recent,
    }
    summary = summarize_older(older)
    if summary:
        result["older_posts_summary"] = summary
    return result

def extract_x(raw):
    if raw == {} or raw.get("user") == {}:
        return None
    user_data = raw.get("user", {}).get("data", {})
    if not user_data:
        return None
    pub = user_data.get("public_metrics", {})
    tweet_items = raw.get("tweets", {}).get("data", [])
    recent, older = [], []
    for t in tweet_items:
        pm = t.get("public_metrics", {})
        npm = t.get("non_public_metrics", {})
        tweet = {
            "id": t.get("id", ""),
            "text": t.get("text", ""),
            "created_at": t.get("created_at", ""),
            "impressions": pm.get("impression_count", 0),
            "likes": pm.get("like_count", 0),
            "retweets": pm.get("retweet_count", 0),
            "replies": pm.get("reply_count", 0),
            "quotes": pm.get("quote_count", 0),
            "bookmarks": pm.get("bookmark_count", 0),
        }
        if npm:
            tweet["engagements"] = npm.get("engagements", 0)
            tweet["profile_clicks"] = npm.get("user_profile_clicks", 0)
        dt = parse_dt(tweet["created_at"])
        if dt and dt >= cutoff:
            recent.append(tweet)
        else:
            older.append(tweet)
    result = {
        "username": user_data.get("username", ""),
        "name": user_data.get("name", ""),
        "description": user_data.get("description", ""),
        "followers": pub.get("followers_count", 0),
        "following": pub.get("following_count", 0),
        "tweet_count": pub.get("tweet_count", 0),
        "recent_tweets": recent,
    }
    summary = summarize_older(older)
    if summary:
        result["older_tweets_summary"] = summary
    return result

bsky_p = extract_bluesky(read_json(os.path.join(raw_dir, "bsky_p.json")))
bsky_c = extract_bluesky(read_json(os.path.join(raw_dir, "bsky_c.json")))
x_p = extract_x(read_json(os.path.join(raw_dir, "x_p.json")))
x_c = extract_x(read_json(os.path.join(raw_dir, "x_c.json")))
hist = read_json(os.path.join(raw_dir, "hist.json"))

data = {"date": today, "conference": {"name": conf_name, "date": conf_date}}
if bsky_p: data["bluesky_personal"] = bsky_p
if bsky_c: data["bluesky_conference"] = bsky_c
if x_p: data["x_personal"] = x_p
if x_c: data["x_conference"] = x_c
if hist != {}: data["historical_metrics"] = hist

with open(fetch_file, "w") as f:
    json.dump(data, f, indent=2)
size = len(json.dumps(data))
print(f"Fetch file: {size:,} chars", file=sys.stderr)
PYEOF

log_ok "Fetched data written to $FETCH_FILE"

# --- Run Claude agent ---
run_agent \
  --allowed-tools \
    "Read" \
    "Write" \
    "mcp__agentmail__send_message" \
    "mcp__agentmail__create_inbox" \
    "mcp__agentmail__list_inboxes" \
  --disallowed-tools \
    "Bash" \
    "Edit" \
  --mcp-config "$SCRIPT_DIR/../mcp-configs/email-only.json" \
  --append-system-prompt-file "$SCRIPT_DIR/../prompts/social-tracker.md" \
  --max-turns 12 \
  --max-budget 1.50 \
  --model sonnet \
  --output-format text \
  "$@" \
  --prompt "Today is $TODAY.
Conference: $CONFERENCE_NAME (date: $CONFERENCE_DATE)
User email: ${EMAIL_TO}
Metrics file path: $METRICS_FILE
Fetched data file: $FETCH_FILE

Read the fetched data file to get all social media data, then analyze engagement across all accounts, update the metrics file, and send me the report email."

log_ok "Social tracker complete"
