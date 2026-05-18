#!/usr/bin/env bash
#
# cloc-history.sh - Track lines of code across every commit in a git repo
#
set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: cloc-history.sh [OPTIONS] [-- CLOC_OPTIONS...]

Track lines of code (via cloc) for every commit in a git repository's history.
Commits are shown in chronological order with deltas between each row.
If the working tree has uncommitted changes, it is included as the final row.

Options:
  -h, --help              Show this help message
  -s, --summarize MODE    Group results: "commit" (default), "day", "week",
                          "month", or "year"
  -n, --max-commits N     Process only the last N commits
  --since REF|DATE        Only process commits after a commit (tag, hash, branch),
                          after a date (e.g. "2024-06-01", "3 months ago"),
                          or a duration ago: Nd (days), Nw (weeks), Nm (months), Nh (hours)
  --all-parents           Follow all parents at merges (default: first-parent only)
  --fill-gaps             When using -s day/week/month/year, emit a row for every
                          period in the range, even if no commits were made

Everything after -- is passed directly to cloc. Use this to filter languages,
exclude directories, etc.

Examples:
  cloc-history.sh
  cloc-history.sh -s day
  cloc-history.sh -s week -n 200
  cloc-history.sh -s week --fill-gaps
  cloc-history.sh --since v1.0 -s month
  cloc-history.sh --since 2024-06-01
  cloc-history.sh --since "3 months ago" -s week
  cloc-history.sh --since 5d
  cloc-history.sh --since 2w -s day
  cloc-history.sh --since 2m -s week
  cloc-history.sh --since 48h
  cloc-history.sh -- --exclude-dir=vendor,node_modules
  cloc-history.sh -- --include-lang=Python,JavaScript
  cloc-history.sh -s month
  cloc-history.sh -s year
  cloc-history.sh -s day -- --exclude-ext=json,yaml
USAGE
    exit 0
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
SUMMARIZE="commit"
MAX_COMMITS=""
FIRST_PARENT="--first-parent"
SINCE_REF=""
FILL_GAPS=0
CLOC_OPTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage ;;
        -s|--summarize)   SUMMARIZE="$2"; shift 2 ;;
        -n|--max-commits) MAX_COMMITS="$2"; shift 2 ;;
        --since)          SINCE_REF="$2"; shift 2 ;;
        --all-parents)    FIRST_PARENT=""; shift ;;
        --fill-gaps)      FILL_GAPS=1; shift ;;
        --)               shift; CLOC_OPTS=("$@"); break ;;
        *)                echo "Error: unknown option: $1" >&2
                          echo "Use -h for help." >&2
                          exit 1 ;;
    esac
done

if [[ ! "$SUMMARIZE" =~ ^(commit|day|week|month|year)$ ]]; then
    echo "Error: --summarize must be 'commit', 'day', 'week', 'month', or 'year' (got '$SUMMARIZE')" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse duration format (Nd, Nw, Nm, Nh only) and convert to a date string for git
# ---------------------------------------------------------------------------
parse_duration() {
    local input=$1
    if [[ "$input" =~ ^([0-9]+)([dwmh])$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"

        case "$unit" in
            h) # hours — include time so git --after is precise
                if date -j -v-${num}H +"%Y-%m-%d %H:%M:%S" &>/dev/null; then
                    date -j -v-${num}H +"%Y-%m-%d %H:%M:%S"
                else
                    date -d "$num hours ago" +"%Y-%m-%d %H:%M:%S"
                fi
                ;;
            d) # days
                if date -j -v-${num}d +"%Y-%m-%d" &>/dev/null; then
                    date -j -v-${num}d +"%Y-%m-%d"
                else
                    date -d "$num days ago" +"%Y-%m-%d"
                fi
                ;;
            w) # weeks
                local days=$((num * 7))
                if date -j -v-${days}d +"%Y-%m-%d" &>/dev/null; then
                    date -j -v-${days}d +"%Y-%m-%d"
                else
                    date -d "$num weeks ago" +"%Y-%m-%d"
                fi
                ;;
            m) # months
                if date -j -v-${num}m +"%Y-%m-%d" &>/dev/null; then
                    date -j -v-${num}m +"%Y-%m-%d"
                else
                    date -d "$num months ago" +"%Y-%m-%d"
                fi
                ;;
        esac
        return 0
    fi
    echo "$input"
    return 1
}

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------
if ! git rev-parse --is-inside-work-tree &>/dev/null; then
    echo "Error: not inside a git repository." >&2
    exit 1
fi

if ! command -v cloc &>/dev/null; then
    echo "Error: 'cloc' is not installed. Install it with: brew install cloc" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Gather commits (oldest first)
# ---------------------------------------------------------------------------
REPO_ROOT=$(git rev-parse --show-toplevel)

WORKTREE_DIRTY=0
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]]; then
    WORKTREE_DIRTY=1
fi

# Resolve --since: parse duration format first, then try as commit ref, fall back to date.
BASELINE_HASH=""
SINCE_DATE=""
GIT_RANGE="HEAD"
if [[ -n "$SINCE_REF" ]]; then
    # Try parsing as duration format (Nd, Nw, Nm, Nh only)
    if parsed_date=$(parse_duration "$SINCE_REF"); then
        SINCE_REF="$parsed_date"
    fi
    
    if START_HASH=$(git rev-parse --verify "$SINCE_REF" 2>/dev/null); then
        # It's a commit ref - use its parent as baseline, include the commit itself
        echo "Showing commits from $(git log -1 --format='%h  %s' "$START_HASH") onwards." >&2

        # Try to get the parent commit for baseline
        if BASELINE_HASH=$(git rev-parse --verify "${START_HASH}^" 2>/dev/null); then
            echo "Baseline: $(git log -1 --format='%h  %s' "$BASELINE_HASH")" >&2
            GIT_RANGE="${BASELINE_HASH}..HEAD"
        else
            # No parent commit (this is the first commit in the repo)
            echo "Warning: No parent commit found (this is the first commit)." >&2
            echo "The first delta will be relative to an empty repository (baseline = 0)." >&2
            BASELINE_HASH=""
            GIT_RANGE="HEAD"
        fi
    else
        # Not a ref — treat as a date expression (git --after handles many formats)
        SINCE_DATE="$SINCE_REF"
        echo "Using commits after '$SINCE_DATE'." >&2
        # Find the last commit at or before the date to use as baseline
        # Don't use FIRST_PARENT here - we want the actual code state before the date
        BASELINE_HASH=$(git log --format='%H' -1 \
            --before="$SINCE_DATE" HEAD 2>/dev/null) || true

        # If no commit found before the date, try the first commit in the filtered range
        if [[ -z "$BASELINE_HASH" ]]; then
            echo "Warning: No commits found before '$SINCE_DATE'." >&2
            echo "The first delta will be relative to an empty repository (baseline = 0)." >&2
        fi
        GIT_RANGE="HEAD"
    fi
fi

git_log_args=(log --format='%H' --reverse)
[[ -n "$FIRST_PARENT" ]] && git_log_args+=("$FIRST_PARENT")
[[ -n "$MAX_COMMITS" ]]  && git_log_args+=("-n" "$MAX_COMMITS")
[[ -n "$SINCE_DATE" ]]   && git_log_args+=("--after=$SINCE_DATE")
git_log_args+=("$GIT_RANGE")

commits=()
while IFS= read -r hash; do
    commits+=("$hash")
done < <(git "${git_log_args[@]}")

total=${#commits[@]}
if [[ $total -eq 0 ]]; then
    if [[ $WORKTREE_DIRTY -eq 1 ]]; then
        echo "No commits found, but working tree has uncommitted changes." >&2
    else
        echo "No commits found." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# When summarizing by period, only the last commit per period needs cloc.
# Pre-scan commit dates (cheap) to decide which commits to skip.
# ---------------------------------------------------------------------------
declare -a run_cloc
for i in "${!commits[@]}"; do run_cloc[$i]=1; done

if [[ "$SUMMARIZE" != "commit" ]]; then
    case "$SUMMARIZE" in
        day)   pfmt='%Y-%m-%d' ;;
        week)  pfmt='%G-W%V'   ;;
        month) pfmt='%Y-%m'    ;;
        year)  pfmt='%Y'       ;;
    esac

    # Get the period key for every commit in one batch git-log call
    period_log_args=(log --format='%ad' --date=format:"$pfmt" --reverse)
    [[ -n "$FIRST_PARENT" ]] && period_log_args+=("$FIRST_PARENT")
    [[ -n "$MAX_COMMITS" ]]  && period_log_args+=("-n" "$MAX_COMMITS")
    [[ -n "$SINCE_DATE" ]]   && period_log_args+=("--after=$SINCE_DATE")
    period_log_args+=("$GIT_RANGE")

    periods=()
    while IFS= read -r p; do
        periods+=("$p")
    done < <(git "${period_log_args[@]}")

    # Only keep the last commit in each period (skip earlier ones)
    for i in "${!commits[@]}"; do
        next=$((i + 1))
        if [[ $next -lt $total && "${periods[$i]}" == "${periods[$next]}" ]]; then
            run_cloc[$i]=0
        fi
    done
fi

to_process=0
for v in "${run_cloc[@]}"; do to_process=$((to_process + v)); done

if [[ $total -gt 0 ]]; then
    echo "Processing $to_process of $total commits (grouped by $SUMMARIZE)..." >&2
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Given YYYY-MM-DD, return YYYYMMDD of the Monday starting that ISO week.
week_start_yyyymmdd() {
    local d=$1
    local dow
    # BSD date (macOS) vs GNU date (Linux)
    if dow=$(date -j -f "%Y-%m-%d" "$d" "+%u" 2>/dev/null); then
        date -j -v-$((dow-1))d -f "%Y-%m-%d" "$d" "+%Y%m%d"
    else
        dow=$(date -d "$d" "+%u")
        date -d "$d - $((dow-1)) days" "+%Y%m%d"
    fi
}

format_delta() {
    local d=$1
    if [[ $d -gt 0 ]]; then echo "+${d}"
    else                     echo "${d}"
    fi
}

# Advance a period key by one unit (used by --fill-gaps).
# Key formats: day=YYYY-MM-DD, week=YYYYMMDD, month=YYYY-MM, year=YYYY
next_period() {
    local field=$1 key=$2
    local result
    case "$field" in
        day)
            result=$(date -j -v+1d -f "%Y-%m-%d" "$key" "+%Y-%m-%d" 2>/dev/null) \
                || result=$(date -d "$key + 1 day" "+%Y-%m-%d")
            ;;
        week)
            result=$(date -j -v+7d -f "%Y%m%d" "$key" "+%Y%m%d" 2>/dev/null) \
                || result=$(date -d "${key:0:4}-${key:4:2}-${key:6:2} + 7 days" "+%Y%m%d")
            ;;
        month)
            result=$(date -j -v+1m -f "%Y-%m-01" "${key}-01" "+%Y-%m" 2>/dev/null) \
                || result=$(date -d "${key}-01 + 1 month" "+%Y-%m")
            ;;
        year)
            result=$((key + 1))
            ;;
    esac
    echo "$result"
}

# ---------------------------------------------------------------------------
# Temporary worktree (cleaned up on exit)
# ---------------------------------------------------------------------------
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cloc-history.XXXXXX")

cleanup() {
    git -C "$REPO_ROOT" worktree remove --force "$WORK_DIR" 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup EXIT

git -C "$REPO_ROOT" worktree add --quiet --detach "$WORK_DIR" HEAD

# ---------------------------------------------------------------------------
# If --since was given, run cloc on that commit to establish the baseline.
# ---------------------------------------------------------------------------
prev_code=0
baseline_code=0
results=()
processed=0

if [[ -n "$BASELINE_HASH" ]]; then
    printf '\r  baseline: cloc on %s...' "$(git log -1 --format='%h' "$BASELINE_HASH")" >&2
    git -C "$WORK_DIR" checkout --quiet --force "$BASELINE_HASH" 2>/dev/null

    baseline=$(
        cd "$WORK_DIR" \
        && cloc --vcs=git --csv ${CLOC_OPTS[@]+"${CLOC_OPTS[@]}"} 2>/dev/null \
        |  awk -F, '$2 == "SUM" { print $5 }'
    ) || true
    baseline=$(echo "$baseline" | tr -d '[:space:]')
    baseline=${baseline:-0}

    prev_code=$baseline
    baseline_code=$baseline
fi

# ---------------------------------------------------------------------------
# Process each commit
# ---------------------------------------------------------------------------

for i in "${!commits[@]}"; do
    commit="${commits[$i]}"

    # Skip commits that aren't the last in their period
    if [[ "${run_cloc[$i]}" -eq 0 ]]; then
        printf '\r  [%d/%d] skipping %s' "$((i + 1))" "$total" \
            "$(git log -1 --format='%h' "$commit")" >&2
        continue
    fi

    ((processed += 1))
    git -C "$WORK_DIR" checkout --quiet --force "$commit" 2>/dev/null

    # Commit metadata
    short=$(git   log -1 --format='%h'  "$commit")
    day=$(git     log -1 --format='%ad' --date=format:'%Y-%m-%d' "$commit")
    week=$(week_start_yyyymmdd "$day")
    month=$(git   log -1 --format='%ad' --date=format:'%Y-%m'    "$commit")
    year=$(git    log -1 --format='%ad' --date=format:'%Y'       "$commit")
    subject=$(git log -1 --format='%s'  "$commit")

    # Count code lines (only git-tracked files)
    code=$(
        cd "$WORK_DIR" \
        && cloc --vcs=git --csv ${CLOC_OPTS[@]+"${CLOC_OPTS[@]}"} 2>/dev/null \
        |  awk -F, '$2 == "SUM" { print $5 }'
    ) || true
    code=$(echo "$code" | tr -d '[:space:]')
    code=${code:-0}

    delta=$((code - prev_code))
    prev_code=$code

    # Pipe-delimited record
    results+=("${short}|${day}|${week}|${month}|${year}|${code}|${delta}|${subject}")

    printf '\r  [%d/%d] %s  %s' "$processed" "$to_process" "$short" "$day" >&2
done

# ---------------------------------------------------------------------------
# If there are uncommitted changes, add the working tree as the final point.
# This captures work-in-progress that hasn't been committed yet.
# ---------------------------------------------------------------------------
if ! git -C "$REPO_ROOT" diff --quiet 2>/dev/null \
   || ! git -C "$REPO_ROOT" diff --cached --quiet 2>/dev/null; then

    printf '\r%-60s\r  cloc on working tree...' '' >&2

    today=$(date '+%Y-%m-%d')
    today_week=$(week_start_yyyymmdd "$today")
    today_month=$(date '+%Y-%m')
    today_year=$(date '+%Y')

    code=$(
        cd "$REPO_ROOT" \
        && cloc --vcs=git --csv ${CLOC_OPTS[@]+"${CLOC_OPTS[@]}"} 2>/dev/null \
        |  awk -F, '$2 == "SUM" { print $5 }'
    ) || true
    code=$(echo "$code" | tr -d '[:space:]')
    code=${code:-0}

    delta=$((code - prev_code))

    results+=("working|${today}|${today_week}|${today_month}|${today_year}|${code}|${delta}|(uncommitted changes)")
fi

printf '\r%-60s\r' '' >&2
echo "Done." >&2
echo "" >&2

# Emit a grouped table. Uses the latest commit in each period for that row's stats.
#   $1 = column header ("Date", "Week", "Month", or "Year")
#   $2 = field name:  "day", "week", "month", or "year"
#   $3 = baseline code count from before the --since cutoff
emit_grouped() {
    local header=$1 field=$2 baseline=$3

    printf '%-12s  %10s  %10s\n' "$header" "Code" "Delta"
    printf '%-12s  %10s  %10s\n' "------------" "----------" "----------"

    local prev_group="" group_code=0 last_before=$baseline
    local num_periods=0 total_delta=0
    local -a deltas=()

    for r in "${results[@]}"; do
        IFS='|' read -r hash day week month year code delta subject <<< "$r"

        local key
        case "$field" in
            day)   key=$day   ;;
            week)  key=$week  ;;
            month) key=$month ;;
            year)  key=$year  ;;
        esac

        if [[ "$key" != "$prev_group" && -n "$prev_group" ]]; then
            local d=$((group_code - last_before))
            printf '%-12s  %10s  %10s\n' "$prev_group" "$group_code" "$(format_delta "$d")"
            total_delta=$((total_delta + d))
            num_periods=$((num_periods + 1))
            deltas+=("$d")
            last_before=$group_code
            # Fill empty periods between prev_group and key
            if [[ "$FILL_GAPS" -eq 1 ]]; then
                local gap
                gap=$(next_period "$field" "$prev_group")
                while [[ "$gap" < "$key" ]]; do
                    printf '%-12s  %10s  %10s\n' "$gap" "$last_before" "0"
                    num_periods=$((num_periods + 1))
                    deltas+=(0)
                    gap=$(next_period "$field" "$gap")
                done
            fi
        fi

        prev_group="$key"
        group_code=$code
    done

    # Emit final group
    if [[ -n "$prev_group" ]]; then
        local d=$((group_code - last_before))
        printf '%-12s  %10s  %10s\n' "$prev_group" "$group_code" "$(format_delta "$d")"
        total_delta=$((total_delta + d))
        num_periods=$((num_periods + 1))
        deltas+=("$d")
    fi

    # Summary footer
    if [[ $num_periods -gt 0 ]]; then
        local avg=$((total_delta / num_periods))

        # Calculate median
        IFS=$'\n' sorted=($(sort -n <<<"${deltas[*]}"))
        local median
        if [[ $((num_periods % 2)) -eq 1 ]]; then
            median=${sorted[$((num_periods / 2))]}
        else
            local mid1=${sorted[$((num_periods / 2 - 1))]}
            local mid2=${sorted[$((num_periods / 2))]}
            median=$(( (mid1 + mid2) / 2 ))
        fi

        printf '%-12s  %10s  %10s\n' "------------" "----------" "----------"
        printf '%-12s  %10s  %10s\n' "total"       "" "$(format_delta "$total_delta")"
        printf '%-12s  %10s  %10s\n' "avg/$field"  "" "$(format_delta "$avg")"
        printf '%-12s  %10s  %10s\n' "median/$field" "" "$(format_delta "$median")"
    fi
}

# ---------------------------------------------------------------------------
# Display results
# ---------------------------------------------------------------------------
case "$SUMMARIZE" in
    commit)
        printf '%-10s  %-12s  %10s  %10s  %s\n' \
            "Hash" "Date" "Code" "Delta" "Subject"
        printf '%-10s  %-12s  %10s  %10s  %s\n' \
            "----------" "------------" "----------" "----------" \
            "------------------------------------------------------------"

        total_delta=0
        deltas=()
        for r in "${results[@]}"; do
            IFS='|' read -r hash day week month year code delta subject <<< "$r"
            printf '%-10s  %-12s  %10s  %10s  %.60s\n' \
                "$hash" "$day" "$code" "$(format_delta "$delta")" "$subject"
            total_delta=$((total_delta + delta))
            deltas+=("$delta")
        done

        num=${#results[@]}
        if [[ $num -gt 0 ]]; then
            avg=$((total_delta / num))

            # Calculate median
            IFS=$'\n' sorted=($(sort -n <<<"${deltas[*]}"))
            median=0
            if [[ $((num % 2)) -eq 1 ]]; then
                median=${sorted[$((num / 2))]}
            else
                mid1=${sorted[$((num / 2 - 1))]}
                mid2=${sorted[$((num / 2))]}
                median=$(( (mid1 + mid2) / 2 ))
            fi

            printf '%-10s  %-12s  %10s  %10s\n' \
                "----------" "------------" "----------" "----------"
            printf '%-10s  %-12s  %10s  %10s\n' \
                "total" "" "" "$(format_delta "$total_delta")"
            printf '%-10s  %-12s  %10s  %10s\n' \
                "avg/commit" "" "" "$(format_delta "$avg")"
            printf '%-10s  %-12s  %10s  %10s\n' \
                "median/commit" "" "" "$(format_delta "$median")"
        fi
        ;;
    day)   emit_grouped "Date"  day   "$baseline_code" ;;
    week)  emit_grouped "week start"  week  "$baseline_code" ;;
    month) emit_grouped "Month" month "$baseline_code" ;;
    year)  emit_grouped "Year"  year  "$baseline_code" ;;
esac
