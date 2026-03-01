#!/bin/bash
# x-oauth.sh - OAuth 1.0a signing helper for X (Twitter) API v2
#
# Provides: x_api_get <url>
# Requires: X_CONSUMER_KEY, X_CONSUMER_SECRET, X_ACCESS_TOKEN, X_ACCESS_TOKEN_SECRET
# Dependencies: openssl, python3, curl

# Percent-encode a string per RFC 3986
_pct_encode() {
  python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}

# Generate OAuth 1.0a signed GET request
x_api_get() {
  local url="$1"

  # Validate credentials are set
  for var in X_CONSUMER_KEY X_CONSUMER_SECRET X_ACCESS_TOKEN X_ACCESS_TOKEN_SECRET; do
    if [ -z "${!var:-}" ]; then
      echo "Error: $var is not set" >&2
      return 1
    fi
  done

  # OAuth parameters
  local oauth_nonce
  oauth_nonce=$(openssl rand -hex 16)
  local oauth_timestamp
  oauth_timestamp=$(date +%s)

  # Split URL into base and query string
  local base_url="${url%%\?*}"
  local query_string=""
  if [[ "$url" == *"?"* ]]; then
    query_string="${url#*\?}"
  fi

  # Collect all parameters (OAuth + query string)
  local -a params=()
  params+=("oauth_consumer_key=$(_pct_encode "$X_CONSUMER_KEY")")
  params+=("oauth_nonce=$(_pct_encode "$oauth_nonce")")
  params+=("oauth_signature_method=$(_pct_encode "HMAC-SHA1")")
  params+=("oauth_timestamp=$(_pct_encode "$oauth_timestamp")")
  params+=("oauth_token=$(_pct_encode "$X_ACCESS_TOKEN")")
  params+=("oauth_version=$(_pct_encode "1.0")")

  # Parse query string parameters (percent-encode keys and values per RFC 5849)
  if [ -n "$query_string" ]; then
    IFS='&' read -ra qparams <<< "$query_string"
    for qp in "${qparams[@]}"; do
      local qkey="${qp%%=*}"
      local qval="${qp#*=}"
      params+=("$(_pct_encode "$qkey")=$(_pct_encode "$qval")")
    done
  fi

  # Sort parameters lexicographically
  local sorted_params
  sorted_params=$(printf '%s\n' "${params[@]}" | sort)

  # Build parameter string
  local param_string=""
  while IFS= read -r param; do
    if [ -n "$param_string" ]; then
      param_string+="&$param"
    else
      param_string="$param"
    fi
  done <<< "$sorted_params"

  # Build signature base string
  local sig_base_string="GET&$(_pct_encode "$base_url")&$(_pct_encode "$param_string")"

  # Build signing key
  local signing_key="$(_pct_encode "$X_CONSUMER_SECRET")&$(_pct_encode "$X_ACCESS_TOKEN_SECRET")"

  # Generate HMAC-SHA1 signature
  local oauth_signature
  oauth_signature=$(printf '%s' "$sig_base_string" | openssl dgst -sha1 -hmac "$signing_key" -binary | base64)

  # Build Authorization header
  local auth_header="OAuth "
  auth_header+="oauth_consumer_key=\"$(_pct_encode "$X_CONSUMER_KEY")\", "
  auth_header+="oauth_nonce=\"$(_pct_encode "$oauth_nonce")\", "
  auth_header+="oauth_signature=\"$(_pct_encode "$oauth_signature")\", "
  auth_header+="oauth_signature_method=\"HMAC-SHA1\", "
  auth_header+="oauth_timestamp=\"$oauth_timestamp\", "
  auth_header+="oauth_token=\"$(_pct_encode "$X_ACCESS_TOKEN")\", "
  auth_header+="oauth_version=\"1.0\""

  curl -sf -H "Authorization: $auth_header" "$url"
}
