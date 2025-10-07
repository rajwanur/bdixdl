#!/bin/sh

# bdixdl - POSIX-compliant H5AI media downloader
# Downloads media files from h5ai HTTP directory listings with advanced features

VERSION="1.2.1" # Fixed repeated downloads bug with queue progress tracking
SCRIPT_NAME="bdixdl"

# --- Default Configuration ---
DEFAULT_DESTINATION="/mnt/main_pool/data/downloads/test"
DEFAULT_MAX_DEPTH=5
DEFAULT_THREADS=3
DEFAULT_CONFIG_FILE="$HOME/.config/bdixdl.conf"

# File extensions to download
MEDIA_EXTENSIONS="mp4 mkv avi wmv mov flv webm m4v"
POSTER_EXTENSIONS="jpg jpeg png gif bmp"
SUBTITLE_EXTENSIONS="srt sub ass vtt"

# --- Global Variables ---
BASE_URL=""
SEARCH_KEYWORDS=""
DOWNLOAD_DESTINATION="$DEFAULT_DESTINATION"
MAX_SEARCH_DEPTH="$DEFAULT_MAX_DEPTH"
MAX_THREADS="$DEFAULT_THREADS"
DRY_RUN=0
QUIET=0
DEBUG=0
RESUME=0               # Individual file resume (partial downloads)
SESSION_RESUME=0        # Session resume (complete session state)
FORCE_OVERWRITE=0
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
# Use a more portable temporary directory location
TEMP_DIR="${TMPDIR:-/tmp}/${SCRIPT_NAME}_$$"
MATCHING_FOLDERS=""
TOTAL_FILES=0
DOWNLOADED_FILES=0
SKIPPED_FILES=0

# New variables for enhanced tracking
MEDIA_FILES_COUNT=0
POSTER_FILES_COUNT=0
SUBTITLE_FILES_COUNT=0
MEDIA_TOTAL_SIZE=0
POSTER_TOTAL_SIZE=0
SUBTITLE_TOTAL_SIZE=0
MEDIA_SKIPPED_COUNT=0
POSTER_SKIPPED_COUNT=0
SUBTITLE_SKIPPED_COUNT=0
DOWNLOAD_QUEUE_FILE="$TEMP_DIR/download_queue_$$.txt"
CURRENT_FILE_NUMBER=0
TOTAL_FILES_TO_DOWNLOAD=0
START_TIME=0
DOWNLOADED_BYTES=0
SHOW_PROGRESS=1  # 1=show detailed progress, 0=simple progress

# Session tracking variables for resume functionality
SESSION_CONTEXT=""         # Track current session context (matches from find_matching_folders)
RESUME_CONTEXT_SAVED=0     # Track if we've saved the session context for resuming

# Enhanced signal handling variables
INTERRUPTED=0              # Flag to track if user interrupted
CLEANUP_IN_PROGRESS=0      # Flag to prevent multiple cleanups
CURRENT_DOWNLOAD_URL=""    # Track current download for interruption
CURRENT_DOWNLOAD_FILE=""   # Track current file for interruption
CURRENT_BASE_URL=""        # Track current directory for interruption
CURRENT_FOLDER_NAME=""     # Track current folder for interruption
INTERRUPT_REASON=""        # Track reason for interruption (SIGINT, SIGTERM, EXIT)
STATE_FILE="./${SCRIPT_NAME}_state_$$"  # Session-specific state file
RESUME_STATE_FILE="./${SCRIPT_NAME}_resume_state"  # Fixed resume state file

# File filtering options
MIN_FILE_SIZE=0          # Minimum file size in bytes (0 = no minimum)
MAX_FILE_SIZE=0          # Maximum file size in bytes (0 = no maximum)
EXCLUDE_EXTENSIONS=""    # Comma-separated list of extensions to exclude
EXCLUDE_KEYWORDS=""      # Comma-separated list of keywords to exclude from filenames
EXCLUDE_REGEX=""         # Regular expression pattern to exclude from filenames

# --- Utility Functions ---

log() {
    [ "$QUIET" -eq 0 ] && printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"
}

debug() {
    [ "$DEBUG" -eq 1 ] && [ "$QUIET" -eq 0 ] && printf "[DEBUG] %s\n" "$*"
}

error() {
    printf "[ERROR] %s\n" "$*" >&2
}

die() {
    error "$*"
    cleanup
    exit 1
}

# Signal handler for user interruption (Ctrl+C)
handle_interrupt() {
    if [ "$INTERRUPTED" -eq 0 ]; then
        INTERRUPTED=1
        INTERRUPT_REASON="SIGINT"
        echo ""
        printf "\033[1;33m*** Interruption detected (Ctrl+C) ***\033[0m\n"
        printf "\033[1;33mGracefully stopping downloads and saving progress...\033[0m\n"

        # Set global interruption flag
        export INTERRUPTED=1
    fi
}

# Signal handler for termination signal
handle_terminate() {
    if [ "$INTERRUPTED" -eq 0 ]; then
        INTERRUPTED=1
        INTERRUPT_REASON="SIGTERM"
        echo ""
        printf "\033[1;33m*** Termination signal received ***\033[0m\n"
        printf "\033[1;33mGracefully stopping downloads and saving progress...\033[0m\n"

        # Set global interruption flag
        export INTERRUPTED=1
    fi
}

# Save current state for resumption
save_interrupt_state() {
    if [ -z "$STATE_FILE" ]; then
        return
    fi

    # Save to both the session-specific and fixed resume state files
    cat > "$STATE_FILE" << EOF
# bdixdl interruption state - $(date)
INTERRUPT_REASON=$INTERRUPT_REASON
INTERRUPT_TIME=$(date +%s)
TOTAL_FILES=$TOTAL_FILES
DOWNLOADED_FILES=$DOWNLOADED_FILES
SKIPPED_FILES=$SKIPPED_FILES
CURRENT_DOWNLOAD_URL="$CURRENT_DOWNLOAD_URL"
CURRENT_DOWNLOAD_FILE="$CURRENT_DOWNLOAD_FILE"
MEDIA_FILES_COUNT=$MEDIA_FILES_COUNT
POSTER_FILES_COUNT=$POSTER_FILES_COUNT
SUBTITLE_FILES_COUNT=$SUBTITLE_FILES_COUNT
START_TIME=$START_TIME
DOWNLOADED_BYTES=$DOWNLOADED_BYTES
TOTAL_FILES_TO_DOWNLOAD=$TOTAL_FILES_TO_DOWNLOAD
CURRENT_FILE_NUMBER=$CURRENT_FILE_NUMBER
DOWNLOAD_QUEUE_FILE="$DOWNLOAD_QUEUE_FILE"
EOF

    # Save current directory context if we're in the middle of processing
    if [ -n "$CURRENT_BASE_URL" ]; then
        echo "CURRENT_BASE_URL=\"$CURRENT_BASE_URL\"" >> "$STATE_FILE"
    fi
    if [ -n "$CURRENT_FOLDER_NAME" ]; then
        echo "CURRENT_FOLDER_NAME=\"$CURRENT_FOLDER_NAME\"" >> "$STATE_FILE"
    fi

    # Also save the original BASE_URL and SEARCH_KEYWORDS for resume validation
    if [ -n "$BASE_URL" ]; then
        echo "BASE_URL=\"$BASE_URL\"" >> "$STATE_FILE"
    fi
    if [ -n "$SEARCH_KEYWORDS" ]; then
        echo "SEARCH_KEYWORDS=\"$SEARCH_KEYWORDS\"" >> "$STATE_FILE"
    fi

    # Save session context if we have processed folders
    if [ -f "$TEMP_DIR/matches" ] && [ "$RESUME_CONTEXT_SAVED" -eq 0 ]; then
        # Save the folder matches that were selected for download
        echo "SESSION_CONTEXT_SAVED=1" >> "$STATE_FILE"

        # Save the first match as the resume context (or create a combined context)
        if [ -s "$TEMP_DIR/matches" ]; then
            first_match=$(head -n 1 "$TEMP_DIR/matches")
            resume_url=$(echo "$first_match" | cut -d'|' -f1)
            resume_name=$(echo "$first_match" | cut -d'|' -f3)

            if [ -n "$resume_url" ] && [ -n "$resume_name" ]; then
                echo "CURRENT_BASE_URL=\"$resume_url\"" >> "$STATE_FILE"
                echo "CURRENT_FOLDER_NAME=\"$resume_name\"" >> "$STATE_FILE"
                debug "Saved resume context: URL=$resume_url, NAME=$resume_name"
            fi
        fi
    fi

    # Also copy to the fixed resume state file for easier resuming
    cp "$STATE_FILE" "$RESUME_STATE_FILE"
}

# Show interruption summary
show_interrupt_summary() {
    if [ "$INTERRUPTED" -eq 0 ]; then
        return
    fi

    echo ""
    printf "\033[1;31m=== Download Session Interrupted ===\033[0m\n"
    printf "\033[1mReason:\033[0m $INTERRUPT_REASON\n"
    # Use TOTAL_FILES_TO_DOWNLOAD if available, otherwise fall back to TOTAL_FILES
    local total_files=$TOTAL_FILES
    [ "$TOTAL_FILES_TO_DOWNLOAD" -gt 0 ] && total_files=$TOTAL_FILES_TO_DOWNLOAD

    printf "\033[1mFiles processed:\033[0m $DOWNLOADED_FILES/$total_files\n"

    # Use the correct skipped files counter
    local skipped_files=$SKIPPED_FILES
    local total_skipped=$((MEDIA_SKIPPED_COUNT + POSTER_SKIPPED_COUNT + SUBTITLE_SKIPPED_COUNT))
    [ "$total_skipped" -gt 0 ] && skipped_files=$total_skipped

    printf "\033[1mFiles skipped:\033[0m $skipped_files\n"

    if [ "$DOWNLOADED_FILES" -gt 0 ]; then
        local elapsed=$(( $(date +%s) - START_TIME ))
        if [ "$elapsed" -gt 0 ]; then
            local rate=$(( DOWNLOADED_BYTES / elapsed ))
            printf "\033[1mData downloaded:\033[0m $(format_bytes $DOWNLOADED_BYTES)\n"
            printf "\033[1mAverage speed:\033[0m $(format_bytes $rate)/s\n"
        fi
    fi

    if [ -n "$CURRENT_DOWNLOAD_FILE" ]; then
        # Use quotes and ensure the full filename is displayed
        printf "\033[1mCurrent download was:\033[0m %s\n" "$CURRENT_DOWNLOAD_FILE"
        printf "\033[1mThis file can be resumed with --resume flag\033[0m\n"
    fi

    echo ""
    printf "\033[1;32mTo resume this session, run:\033[0m\n"
    printf "  \033[1m$SCRIPT_NAME --resume [other-options]\033[0m\n"
    echo ""
    printf "\033[1mState saved to:\033[0m $RESUME_STATE_FILE\n"
    printf "\033[1m(Also saved as:\033[0m $STATE_FILE\033[1m)\033[0m\n"
}

# Check if we should continue processing (not interrupted)
should_continue() {
    [ "$INTERRUPTED" -eq 0 ] && return 0
    return 1
}

# Load saved session state for resumption
load_session_state() {
    # Check both the fixed resume state file and the session-specific one
    if [ ! -f "$RESUME_STATE_FILE" ] && [ ! -f "$STATE_FILE" ]; then
        error "No saved session state found. Cannot resume."
        error "Expected state file: $RESUME_STATE_FILE or $STATE_FILE"
        exit 1
    fi

    # Use the fixed resume state file if available, otherwise try the session-specific one
    local state_file="$RESUME_STATE_FILE"
    if [ ! -f "$RESUME_STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
        state_file="$STATE_FILE"
    fi

    log "Loading saved session state from: $state_file"

    # Source the state file (safe approach with eval)
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        case "$key" in
            \#*|'') continue ;;
        esac

        # Remove surrounding quotes if present
        if [ "${value#\"}" != "$value" ]; then
            value="${value#\"}"
            value="${value%\"}"
        fi

        # Restore variables
        case "$key" in
            INTERRUPT_REASON) INTERRUPT_REASON="$value" ;;
            INTERRUPT_TIME) INTERRUPT_TIME="$value" ;;
            TOTAL_FILES) TOTAL_FILES="$value" ;;
            DOWNLOADED_FILES) DOWNLOADED_FILES="$value" ;;
            SKIPPED_FILES) SKIPPED_FILES="$value" ;;
            CURRENT_DOWNLOAD_URL) CURRENT_DOWNLOAD_URL="$value" ;;
            CURRENT_DOWNLOAD_FILE) CURRENT_DOWNLOAD_FILE="$value" ;;
            MEDIA_FILES_COUNT) MEDIA_FILES_COUNT="$value" ;;
            POSTER_FILES_COUNT) POSTER_FILES_COUNT="$value" ;;
            SUBTITLE_FILES_COUNT) SUBTITLE_FILES_COUNT="$value" ;;
            START_TIME) START_TIME="$value" ;;
            DOWNLOADED_BYTES) DOWNLOADED_BYTES="$value" ;;
            CURRENT_BASE_URL) CURRENT_BASE_URL="$value" ;;
            CURRENT_FOLDER_NAME) CURRENT_FOLDER_NAME="$value" ;;
            BASE_URL) BASE_URL="$value" ;;
            SEARCH_KEYWORDS) SEARCH_KEYWORDS="$value" ;;
            TOTAL_FILES_TO_DOWNLOAD) TOTAL_FILES_TO_DOWNLOAD="$value" ;;
            CURRENT_FILE_NUMBER) CURRENT_FILE_NUMBER="$value" ;;
            DOWNLOAD_QUEUE_FILE) DOWNLOAD_QUEUE_FILE="$value" ;;
            SESSION_CONTEXT_SAVED) RESUME_CONTEXT_SAVED=1 ;;
        esac
    done < "$state_file"

    log "Session state loaded successfully"
    log "Previous session interrupted: $INTERRUPT_REASON"
    log "Previously downloaded: $DOWNLOADED_FILES files"
    log "Previously downloaded data: $(format_bytes $DOWNLOADED_BYTES)"

    # Clear the state file after loading
    rm -f "$STATE_FILE"
}

# Check if we're in resume mode and there's a state file
check_resume_mode() {
    if [ "$RESUME" -eq 1 ] && [ -n "$STATE_FILE" ] && [ -f "$STATE_FILE" ]; then
        return 0
    fi
    return 1
}

cleanup() {
    # Prevent multiple cleanups running simultaneously
    if [ "$CLEANUP_IN_PROGRESS" -eq 1 ]; then
        return
    fi
    CLEANUP_IN_PROGRESS=1

    # Save current state if interrupted
    if [ "$INTERRUPTED" -eq 1 ]; then
        save_interrupt_state
        show_interrupt_summary
    fi

    # Clean up temporary directory
    if [ -d "$TEMP_DIR" ]; then
        if [ "$INTERRUPTED" -eq 1 ]; then
            # Preserve download queue and matches for resume
            debug "Preserving download queue for resume: $DOWNLOAD_QUEUE_FILE"
            debug "Preserving matches for resume: $TEMP_DIR/matches"
        else
            # Clean up everything on normal exit
            rm -rf "$TEMP_DIR"
        fi
    fi

    # Clean up state files on normal exit
    if [ "$INTERRUPTED" -eq 0 ]; then
        [ -f "$STATE_FILE" ] && rm -f "$STATE_FILE"
        [ -f "$RESUME_STATE_FILE" ] && rm -f "$RESUME_STATE_FILE"
    fi

    # Kill background jobs if any
    jobs -p 2>/dev/null | while read -r pid; do
        kill "$pid" 2>/dev/null || true
    done
}

show_help() {
    cat << EOF
$SCRIPT_NAME v$VERSION - Download media from h5ai HTTP directory listings

USAGE:
    $SCRIPT_NAME [OPTIONS] BASE_URL KEYWORDS...

ARGUMENTS:
    BASE_URL     Base URL of h5ai server (e.g., https://ftp.isp.net/media/)
    KEYWORDS     Space-separated keywords to search for in folder names

OPTIONS:
    -d, --destination DIR    Download destination (default: $DEFAULT_DESTINATION)
    -D, --depth NUM         Maximum search depth (default: $DEFAULT_MAX_DEPTH)
    -t, --threads NUM       Concurrent download threads (default: $DEFAULT_THREADS)
    -n, --dry-run          Show what would be downloaded without downloading
    -r, --resume           Resume interrupted downloads (automatically detects partial files and continues from where left off)
    -f, --force-overwrite  Force overwrite existing files (skip if same size by default)
    --min-size SIZE        Exclude files smaller than SIZE (e.g., 100M, 2G, 500K)
    --max-size SIZE        Exclude files larger than SIZE (e.g., 10G, 500M, 1T)
    --exclude-ext EXTS     Exclude files with these extensions (comma-separated, e.g., avi,wmv,flv)
    --exclude-keywords WORDS Exclude files containing these keywords in filename (comma-separated)
    --exclude-regex PATTERN Exclude files matching this regex pattern
    -q, --quiet            Suppress non-error output
    --debug                Show debug information (verbose logging)
    -c, --config FILE      Use custom config file (default: $DEFAULT_CONFIG_FILE)
    -h, --help             Show this help message
    -v, --version          Show version information

CONFIG FILE:
    The config file uses KEY=VALUE format. Example:

    DOWNLOAD_DESTINATION=/mnt/main_pool/data/downloads/test
    MAX_SEARCH_DEPTH=5
    MAX_THREADS=3
    RESUME=1
    QUIET=0
    SHOW_PROGRESS=1
    DEBUG=0

EXAMPLES:
    $SCRIPT_NAME https://ftp.yourserever.net/media/ "movie 2023"
    $SCRIPT_NAME -n -t 5 https://yourserever.com/files/ "documentary nature"
    $SCRIPT_NAME --dry-run --depth 3 http://192.168.1.1/media/ "series season"

    # Filter examples:
    $SCRIPT_NAME --max-size 2G https://server.com/media/ "movies"  # Exclude files larger than 2GB
    $SCRIPT_NAME --min-size 100M --exclude-ext avi,wmv https://server.com/media/ "videos"
    $SCRIPT_NAME --exclude-keywords "sample,trailer,bonus" https://server.com/media/ "movies"
    $SCRIPT_NAME --exclude-regex ".*[Ss]ample.*|.*[Tt]railer.*" https://server.com/media/ "videos"

SUPPORTED FILE TYPES:
    Media: $MEDIA_EXTENSIONS
    Images: $POSTER_EXTENSIONS
    Subtitles: $SUBTITLE_EXTENSIONS
EOF
}

show_version() {
    printf "%s version %s\n" "$SCRIPT_NAME" "$VERSION"
}

# Check if required commands are available
check_dependencies() {
    missing=""
    for cmd in curl wget grep sed mkdir rm; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing="$missing $cmd"
        fi
    done

    if [ -n "$missing" ]; then
        die "Missing required commands:$missing"
    fi
}

# Load configuration from file
load_config() {
    [ ! -f "$CONFIG_FILE" ] && return 0

    # Read config file safely
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        case "$key" in
            ''|'#'*) continue ;;
        esac

        # Remove leading/trailing whitespace
        key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        case "$key" in
            DOWNLOAD_DESTINATION) DOWNLOAD_DESTINATION="$value" ;;
            MAX_SEARCH_DEPTH) MAX_SEARCH_DEPTH="$value" ;;
            MAX_THREADS) MAX_THREADS="$value" ;;
            RESUME) RESUME="$value" ;;
            QUIET) QUIET="$value" ;;
            DEBUG) DEBUG="$value" ;;
            SHOW_PROGRESS) SHOW_PROGRESS="$value" ;;
            MIN_FILE_SIZE) MIN_FILE_SIZE="$value" ;;
            MAX_FILE_SIZE) MAX_FILE_SIZE="$value" ;;
            EXCLUDE_EXTENSIONS) EXCLUDE_EXTENSIONS="$value" ;;
            EXCLUDE_KEYWORDS) EXCLUDE_KEYWORDS="$value" ;;
            EXCLUDE_REGEX) EXCLUDE_REGEX="$value" ;;
        esac
    done < "$CONFIG_FILE"
}

# Simple URL decoder for common percent-encoding
url_decode() {
    printf '%s' "$1" | sed 's/+/ /g; s/%20/ /g; s/%21/!/g; s/%22/"/g; s/%23/#/g; s/%24/$/g; s/%25/%/g; s/%26/\&/g; s/%27/'"'"'/g; s/%28/(/g; s/%29/)/g; s/%2A/*/g; s/%2B/+/g; s/%2C/,/g; s/%2D/-/g; s/%2E/./g; s/%2F/\//g; s/%5B/[/g; s/%5D/]/g; s/%C2%BD/½/g'
}

# Format bytes to human-readable format
format_bytes() {
    bytes="$1"
    if [ "$bytes" -lt 1024 ]; then
        printf "%d B" "$bytes"
    elif [ "$bytes" -lt 1048576 ]; then
        printf "%.1f KB" "$(echo "$bytes 1024" | awk '{printf $1/$2}')"
    elif [ "$bytes" -lt 1073741824 ]; then
        printf "%.1f MB" "$(echo "$bytes 1048576" | awk '{printf $1/$2}')"
    else
        printf "%.1f GB" "$(echo "$bytes 1073741824" | awk '{printf $1/$2}')"
    fi
}

# Parse size string (e.g., "100M", "2G", "500K") to bytes
parse_size() {
    size_str="$1"

    # Remove whitespace and convert to lowercase
    size_str=$(echo "$size_str" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

    # Extract number and unit
    number=$(echo "$size_str" | sed 's/[^0-9.]//g')
    unit=$(echo "$size_str" | sed 's/[0-9.]//g')

    # Default to bytes if no unit
    case "$unit" in
        ""|b)
            multiplier=1
            ;;
        k|kb)
            multiplier=1024
            ;;
        m|mb)
            multiplier=1048576
            ;;
        g|gb)
            multiplier=1073741824
            ;;
        t|tb)
            multiplier=1099511627776
            ;;
        *)
            debug "parse_size: Unknown unit '$unit', treating as bytes"
            multiplier=1
            ;;
    esac

    # Calculate bytes
    bytes=$(echo "$number $multiplier" | awk '{printf "%.0f", $1 * $2}')
    printf '%s\n' "$bytes"
}

# Check if file should be excluded based on filters
should_exclude_file() {
    filename="$1"
    file_size="$2"

    # Skip filtering if no filters are set
    if [ "$MIN_FILE_SIZE" -eq 0 ] && [ "$MAX_FILE_SIZE" -eq 0 ] && \
       [ -z "$EXCLUDE_EXTENSIONS" ] && [ -z "$EXCLUDE_KEYWORDS" ] && [ -z "$EXCLUDE_REGEX" ]; then
        return 1  # Don't exclude
    fi

    # Size-based filtering
    if [ "$MIN_FILE_SIZE" -gt 0 ] && [ "$file_size" -gt 0 ] && [ "$file_size" -lt "$MIN_FILE_SIZE" ]; then
        debug "    FILTER: File too small ($(format_bytes "$file_size") < $(format_bytes "$MIN_FILE_SIZE"))"
        return 0  # Exclude
    fi

    if [ "$MAX_FILE_SIZE" -gt 0 ] && [ "$file_size" -gt 0 ] && [ "$file_size" -gt "$MAX_FILE_SIZE" ]; then
        debug "    FILTER: File too large ($(format_bytes "$file_size") > $(format_bytes "$MAX_FILE_SIZE"))"
        return 0  # Exclude
    fi

    # Extension-based filtering
    if [ -n "$EXCLUDE_EXTENSIONS" ]; then
        # Extract extension and convert to lowercase
        case "$filename" in
            *.*)
                ext=$(printf '%s' "$filename" | sed 's/.*\.//' | tr '[:upper:]' '[:lower:]')
                ;;
            *)
                ext=""
                ;;
        esac

        old_ifs="$IFS"
        IFS=','
        for exclude_ext in $EXCLUDE_EXTENSIONS; do
            exclude_ext=$(printf '%s' "$exclude_ext" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            if [ "$ext" = "$exclude_ext" ]; then
                IFS="$old_ifs"
                debug "    FILTER: Extension excluded ($ext)"
                return 0  # Exclude
            fi
        done
        IFS="$old_ifs"
    fi

    # Keyword-based filtering
    if [ -n "$EXCLUDE_KEYWORDS" ]; then
        filename_lower=$(printf '%s' "$filename" | tr '[:upper:]' '[:lower:]')

        old_ifs="$IFS"
        IFS=','
        for keyword in $EXCLUDE_KEYWORDS; do
            keyword=$(printf '%s' "$keyword" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
            case "$filename_lower" in
                *"$keyword"*)
                    IFS="$old_ifs"
                    debug "    FILTER: Keyword excluded ($keyword)"
                    return 0  # Exclude
                    ;;
            esac
        done
        IFS="$old_ifs"
    fi

    # Regex-based filtering
    if [ -n "$EXCLUDE_REGEX" ]; then
        if echo "$filename" | grep -q -E "$EXCLUDE_REGEX"; then
            debug "    FILTER: Regex pattern matched ($EXCLUDE_REGEX)"
            return 0  # Exclude
        fi
    fi

    # Passes all filters
    return 1  # Don't exclude
}

# Get file type category
get_file_type() {
    filename="$1"

    # Check if filename has an extension
    case "$filename" in
        *.*) ;;
        *) printf "unknown" && return ;;
    esac

    # Extract extension and convert to lowercase
    ext=$(printf '%s' "$filename" | sed 's/.*\.//' | tr '[:upper:]' '[:lower:]')

    # Check media extensions
    for media_ext in $MEDIA_EXTENSIONS; do
        if [ "$ext" = "$media_ext" ]; then
            printf "media"
            return
        fi
    done

    # Check poster extensions
    for poster_ext in $POSTER_EXTENSIONS; do
        if [ "$ext" = "$poster_ext" ]; then
            printf "poster"
            return
        fi
    done

    # Check subtitle extensions
    for subtitle_ext in $SUBTITLE_EXTENSIONS; do
        if [ "$ext" = "$subtitle_ext" ]; then
            printf "subtitle"
            return
        fi
    done

    printf "unknown"
}

# Get href paths from HTML, excluding navigation links
get_href_paths() {
    url="$1"
    # log "  Fetching URL: $url"

    # Fix URL protocol if needed
    url=$(echo "$url" | sed 's|^http:/\([^/]\)|http://\1|')

    # Fetch the HTML content and save to a temporary file for debugging
    html_content="$TEMP_DIR/html_content_$$.html"
    mkdir -p "$TEMP_DIR" 2>/dev/null
    curl -s -L --max-redirs 3 --connect-timeout 10 --max-time 30 "$url" 2>/dev/null > "$html_content"

    # Check if we got any content
    if [ ! -s "$html_content" ]; then
        log "  ERROR: No content received from URL"
        return 1
    fi

    # Debug output
    content_size=$(wc -c < "$html_content")
    debug "  Received HTML content: $content_size bytes"

    # Try to find all links (both files and directories)
    # Use a more general approach to find all href attributes
    cat "$html_content" | \
    tr -d '\n' | \
    grep -o '<a[^>]*href="[^"]*"[^>]*>' | \
    grep -o 'href="[^"]*"' | \
    sed 's/href="//;s/"//' | \
    grep -v '^[.]\{1,2\}/' | \
    grep -v '^#' | \
    grep -v '^[?]' | \
    grep -v '\[[0-9:]\+\]' | \
    grep -v '_h5ai' | \
    sort -u > "$TEMP_DIR/links_$$.txt"

    # Debug output
    link_count=$(wc -l < "$TEMP_DIR/links_$$.txt")
    debug "  Found $link_count total links"

    # Output the results
    cat "$TEMP_DIR/links_$$.txt"

    # Clean up temporary files
    rm -f "$html_content" "$TEMP_DIR/links_$$.txt"
}

# Check if string contains any of the keywords (case-insensitive)
matches_keywords() {
    text="$1"
    text_lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')

    # Convert SEARCH_KEYWORDS to individual words and check each
    old_ifs="$IFS"
    IFS=' '
    for keyword in $SEARCH_KEYWORDS; do
        keyword_lower=$(printf '%s' "$keyword" | tr '[:upper:]' '[:lower:]')
        case "$text_lower" in
            *"$keyword_lower"*)
                IFS="$old_ifs"
                return 0
                ;;
        esac
    done
    IFS="$old_ifs"
    return 1
}

# Check if file extension is supported
is_supported_extension() {
    filename="$1"

    # Check if filename has an extension
    case "$filename" in
        *.*) ;;
        *) return 1 ;;
    esac

    # Extract extension and convert to lowercase
    ext=$(printf '%s' "$filename" | sed 's/.*\.//' | tr '[:upper:]' '[:lower:]')

    # Debug output
    debug "      Extension check: '%s' -> '%s'" "$filename" "$ext"

    all_extensions="$MEDIA_EXTENSIONS $POSTER_EXTENSIONS $SUBTITLE_EXTENSIONS"
    for supported_ext in $all_extensions; do
        if [ "$ext" = "$supported_ext" ]; then
            debug "      MATCH: Extension '%s' is supported" "$ext"
            return 0
        fi
    done

    debug "      SKIP: Extension '%s' not supported" "$ext"
    return 1
}

# Debug function to show URL filtering
debug_url_filter() {
    debug "URL FILTER: %s -> %s" "$1" "$2"
}

# Find matching folders recursively - COMPLETELY REWRITTEN
find_matching_folders() {
    current_url="$1"
    current_depth="$2"
    current_display_path="$3"

    # Stop if max depth reached
    if [ "$current_depth" -gt "$MAX_SEARCH_DEPTH" ]; then
        return 0
    fi

    # log "Searching: $current_display_path (depth: $current_depth)"
    # log "  URL: $current_url"

    # Fix URL protocol if needed
    current_url=$(echo "$current_url" | sed 's|^http:/\([^/]\)|http://\1|')

    # Ensure URL ends with a slash for consistency
    current_url="${current_url%/}/"

    # Remove any timestamp patterns from URL
    current_url=$(echo "$current_url" | sed 's/\[[0-9:]\+\]//g')

    # Normalize URL by removing duplicate slashes
    current_url=$(echo "$current_url" | sed 's|//*/|/|g' | sed 's|^\(https\?:\)\(/\)\+|\1//|')

    # Get directory listing
    href_paths=$(get_href_paths "$current_url")
    if [ -z "$href_paths" ]; then
        # log "  No links found in directory"
        return 0
    fi

    # Save to temp file to avoid subshell issues
    temp_links="$TEMP_DIR/links_$$_$current_depth"
    mkdir -p "$TEMP_DIR" 2>/dev/null
    printf '%s\n' "$href_paths" > "$temp_links"

    # Extract base domain for filtering
    base_domain=$(echo "$BASE_URL" | sed 's|^\(https\?://[^/]*\).*|\1|')

    # Process each link
    while IFS= read -r link_path || [ -n "$link_path" ]; do
        [ -z "$link_path" ] && continue

        # Skip h5ai internal paths
        case "$link_path" in
            */_h5ai/*)
                debug "    Skipping h5ai internal path: $link_path"
                continue
                ;;
        esac

        # Remove any timestamp patterns from link_path
        link_path=$(echo "$link_path" | sed 's/\[[0-9:]\+\]//g')

        # Skip external URLs that don't belong to our domain
        if echo "$link_path" | grep -q '^https\?://'; then
            if echo "$link_path" | grep -q "^$base_domain"; then
                # This is a subdirectory of our base URL
                decoded_path=$(url_decode "$link_path")
                folder_name=$(basename "$decoded_path")
                full_folder_url="$link_path"
                if ! echo "$full_folder_url" | grep -q '/$'; then
                    full_folder_url="${full_folder_url}/"
                fi

                # Fix URL protocol if needed
                full_folder_url=$(echo "$full_folder_url" | sed 's|^http:/\([^/]\)|http://\1|')

                # Normalize URL by removing duplicate slashes
                full_folder_url=$(echo "$full_folder_url" | sed 's|//*/|/|g' | sed 's|^\(https\?:\)\(/\)\+|\1//|')

                # Skip if URL is the same as current URL (prevents infinite loops)
                if [ "$full_folder_url" = "$current_url" ]; then
                    debug "    Skipping already processed URL: $full_folder_url"
                    continue
                fi

                display_path="${full_folder_url#$BASE_URL}"

                debug "    Found directory: $folder_name"

                if matches_keywords "$folder_name"; then
                    log "  -> MATCH: $folder_name"
                    printf '%s|%s|%s\n' "$full_folder_url" "$display_path" "$folder_name" >> "$TEMP_DIR/matches"
                fi
                find_matching_folders "$full_folder_url" $((current_depth + 1)) "$display_path"
            else
                debug "    Skipping external URL: $link_path"
            fi
            continue
        fi

        # Skip navigation links
        case "$link_path" in
            .|..|./|../)
                continue
                ;;
        esac

        # Decode the path for display
        decoded_path=$(url_decode "$link_path")
        folder_name=$(basename "${decoded_path%/}")

        # Build proper URL - handle both relative and absolute paths correctly
        if echo "$link_path" | grep -q '^/'; then
            # Absolute path - combine with base domain
            full_folder_url="$base_domain${link_path}/"
        else
            # Relative path
            full_folder_url="${current_url%/}/${link_path}/"
        fi

        # Ensure URL ends with a slash
        full_folder_url="${full_folder_url%/}/"

        # Fix URL protocol if needed
        full_folder_url=$(echo "$full_folder_url" | sed 's|^http:/\([^/]\)|http://\1|')

        # Normalize URL by removing duplicate slashes
        full_folder_url=$(echo "$full_folder_url" | sed 's|//*/|/|g' | sed 's|^\(https\?:\)\(/\)\+|\1//|')

        # Skip if URL is the same as current URL (prevents infinite loops)
        if [ "$full_folder_url" = "$current_url" ]; then
            debug "    Skipping already processed URL: $full_folder_url"
            continue
        fi

        # Create display path
        display_path="$current_display_path/$folder_name"

        debug "    Found directory: $folder_name"
        debug "    Full URL: $full_folder_url"

        # Check if folder matches keywords
        if matches_keywords "$folder_name"; then
            log "  -> MATCH: $folder_name"
            debug "  DEBUG: Storing in matches - folder_name='$folder_name', display_path='$display_path'"
            # Store only the base folder name, not the full path
            printf '%s|%s|%s\n' "$full_folder_url" "$display_path" "$folder_name" >> "$TEMP_DIR/matches"
        fi

        # Recurse into directory
        find_matching_folders "$full_folder_url" $((current_depth + 1)) "$display_path"

    done < "$temp_links"

    # Clean up temp file
    rm -f "$temp_links"
}


# Count files in a directory that match our criteria
count_directory_files() {
    remote_url="$1"
    count=0

    href_paths=$(get_href_paths "$remote_url")
    [ -z "$href_paths" ] && printf '0\n' && return

    printf '%s\n' "$href_paths" | while IFS= read -r link_path; do
        [ -z "$link_path" ] && continue

        decoded_path=$(url_decode "$link_path")

        # Skip h5ai paths and directories
        case "$decoded_path" in
            */_h5ai/*)
                debug "    Skipping h5ai file: $decoded_path"
                continue
                ;;
            */)
                continue
                ;;
        esac

        if is_supported_extension "$decoded_path"; then
            count=$((count + 1))
        fi
    done

    printf '%s\n' "$count"
}

# Get remote file size using HTTP HEAD request
get_remote_file_size() {
    file_url="$1"

    # Use curl to get Content-Length header
    # Increased timeout to be more reliable for large file servers
    size=$(curl --silent --head --location --max-redirs 3 --connect-timeout 15 --max-time 60 "$file_url" 2>/dev/null | \
           grep -i "^Content-Length:" | \
           sed 's/^[^:]*: *//' | \
           tr -d '\r' | \
           head -1)

    # Return 0 if we can't determine size (allows download to proceed)
    if [ -z "$size" ] || ! echo "$size" | grep -q '^[0-9]\+$'; then
        printf '0\n'
        return 1
    fi

    printf '%s\n' "$size"
    return 0
}

# Scan and analyze files for download
scan_and_analyze_files() {
    log "Scanning and analyzing files for download..."

    # Reset counters
    MEDIA_FILES_COUNT=0
    POSTER_FILES_COUNT=0
    SUBTITLE_FILES_COUNT=0
    MEDIA_TOTAL_SIZE=0
    POSTER_TOTAL_SIZE=0
    SUBTITLE_TOTAL_SIZE=0
    MEDIA_SKIPPED_COUNT=0
    POSTER_SKIPPED_COUNT=0
    SUBTITLE_SKIPPED_COUNT=0
    MEDIA_FILTERED_COUNT=0
    POSTER_FILTERED_COUNT=0
    SUBTITLE_FILTERED_COUNT=0

    DOWNLOAD_QUEUE_FILE="$TEMP_DIR/download_queue_$$.txt"
    debug "=== SCAN PHASE START ==="
    debug "  Download queue file: $DOWNLOAD_QUEUE_FILE"

    # --- FIX --- Initialize the processed URLs tracking file to prevent duplicate scanning.
    # This file will be used by scan_directory_files to avoid re-scanning.
    PROCESSED_URLS_TRACKER="$TEMP_DIR/processed_urls.txt"
    > "$PROCESSED_URLS_TRACKER"
    debug "  Initialized processed URL tracker: $PROCESSED_URLS_TRACKER"

    # Process each selected folder
    while IFS='|' read -r folder_url folder_path folder_name || [ -n "$folder_url" ]; do
        log "  Scanning folder: $folder_name"
        scan_directory_files "$folder_url" "$DOWNLOAD_DESTINATION" "$folder_name"
    done < "$TEMP_DIR/matches"

    # Calculate total files to download
    TOTAL_FILES_TO_DOWNLOAD=$((MEDIA_FILES_COUNT + POSTER_FILES_COUNT + SUBTITLE_FILES_COUNT))

    debug "=== SCAN PHASE COMPLETE ==="
    debug "  Total files in download queue: $(wc -l < "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo '0')"
    debug "  Media files: $MEDIA_FILES_COUNT (skipped: $MEDIA_SKIPPED_COUNT, filtered: $MEDIA_FILTERED_COUNT)"
    debug "  Poster files: $POSTER_FILES_COUNT (skipped: $POSTER_SKIPPED_COUNT, filtered: $POSTER_FILTERED_COUNT)"
    debug "  Subtitle files: $SUBTITLE_FILES_COUNT (skipped: $SUBTITLE_SKIPPED_COUNT, filtered: $SUBTITLE_FILTERED_COUNT)"

    # Log filtered files summary
    total_filtered=$((MEDIA_FILTERED_COUNT + POSTER_FILTERED_COUNT + SUBTITLE_FILTERED_COUNT))
    if [ "$total_filtered" -gt 0 ]; then
        log "Scan completed. Found $TOTAL_FILES_TO_DOWNLOAD files to download (filtered out $total_filtered files)."
        debug "SCAN SUMMARY: $TOTAL_FILES_TO_DOWNLOAD files to download, $total_filtered files filtered"
    else
        log "Scan completed. Found $TOTAL_FILES_TO_DOWNLOAD files to download."
        debug "SCAN SUMMARY: $TOTAL_FILES_TO_DOWNLOAD files to download, no files filtered"
    fi
}

# Scan files in a directory recursively
scan_directory_files() {
    remote_url="$1"
    local_base="$2"
    folder_name="$3"

    # --- FIX: Prevent re-scanning of the same directory ---
    # This is the core fix. Before processing, we check if this URL has already been scanned.
    PROCESSED_URLS_TRACKER="$TEMP_DIR/processed_urls.txt"
    # Use grep with -F (fixed string) and -x (whole line match) for accuracy and safety.
    if grep -q -x -F "$remote_url" "$PROCESSED_URLS_TRACKER" 2>/dev/null; then
        debug "    SKIP: Directory already scanned, skipping to prevent duplicates: $remote_url"
        return 0
    fi
    # If not scanned, add it to the tracker immediately before proceeding.
    printf '%s\n' "$remote_url" >> "$PROCESSED_URLS_TRACKER"
    # --- END FIX ---

    log "    Scanning: $folder_name"

    href_paths=$(get_href_paths "$remote_url")
    if [ -z "$href_paths" ]; then
        log "    No files found in directory"
        return 0
    fi

    # Decode folder name for local directory path
    folder_name_decoded=$(url_decode "$folder_name")
    local_dir="$local_base/$folder_name_decoded"

    # Get base domain for absolute paths
    base_domain=$(echo "$BASE_URL" | sed 's|^\(https\?://[^/]*\).*|\1|')

    # Create a processed files tracker to prevent duplicates within the same directory scan
    PROCESSED_FILES_TRACKER="$TEMP_DIR/processed_files_$(echo "$remote_url" | md5sum | cut -d' ' -f1).txt"
    > "$PROCESSED_FILES_TRACKER"

    # Process files and subdirectories
    temp_dirs="$TEMP_DIR/scan_dirs_$$_$(date +%s%N)"
    temp_files="$TEMP_DIR/files_$$_$(date +%s%N)"

    printf '%s\n' "$href_paths" | while IFS= read -r link_path; do
        [ -z "$link_path" ] && continue

        decoded_path=$(url_decode "$link_path")

        # Check if this is a directory
        is_directory=0
        case "$decoded_path" in
            */) is_directory=1 ;;
        esac

        # Skip external URLs that don't match our domain
        case "$link_path" in
            http://*|https://*)
                if ! echo "$link_path" | grep -q "^$base_domain"; then
                    continue
                fi
                ;;
        esac

        # Process directories separately
        if [ "$is_directory" -eq 1 ]; then
            case "$link_path" in
                .|..|./|../|*/_h5ai/*) continue ;;
            esac
            case "$decoded_path" in
                */.|*/..|*/_h5ai/*|.|..) continue ;;
            esac

            subdir_name=$(basename "${decoded_path%/}")

            if [ -z "$subdir_name" ] || [ -z "$(echo "$subdir_name" | tr -d '[:space:]')" ]; then
                continue
            fi

            case "$link_path" in
                http://*|https://*) subdir_url="$link_path" ;;
                /*) subdir_url="$base_domain${link_path%/}/" ;;
                *) subdir_url="${remote_url%/}/${link_path%/}/" ;;
            esac
            subdir_url=$(echo "$subdir_url" | sed 's|//*/|/|g' | sed 's|^\(https\?:\)\(/\)\+|\1//|')

            if [ "$subdir_url" = "$remote_url" ] || [ "${subdir_url%/}" = "${remote_url%/}" ]; then
                continue
            fi
            if [ "$subdir_name" = "$folder_name_decoded" ] || [ "$subdir_name" = "$folder_name" ]; then
                continue
            fi

            printf "%s|%s|%s\n" "$subdir_url" "$local_base" "$subdir_name" >> "$temp_dirs"
            continue
        fi

        # Process files
        if is_supported_extension "$decoded_path"; then
            filename=$(basename "$decoded_path")

            case "$link_path" in
                http://*|https://*) file_url="$link_path" ;;
                /*) file_url="$base_domain$link_path" ;;
                *) file_url="${remote_url%/}/$link_path" ;;
            esac

            local_path="$local_dir/$filename"
            file_type=$(get_file_type "$filename")
            remote_size=$(get_remote_file_size "$file_url")

            if should_exclude_file "$filename" "$remote_size"; then
                debug "      EXCLUDED: $filename ($(format_bytes "$remote_size")) - filtered out"
                case "$file_type" in
                    "media") MEDIA_FILTERED_COUNT=$((MEDIA_FILTERED_COUNT + 1)) ;;
                    "poster") POSTER_FILTERED_COUNT=$((POSTER_FILTERED_COUNT + 1)) ;;
                    "subtitle") SUBTITLE_FILTERED_COUNT=$((SUBTITLE_FILTERED_COUNT + 1)) ;;
                esac
                continue
            fi

            debug "      Checking local path: $local_path"
            will_skip=0
            if [ -f "$local_path" ] && [ "$FORCE_OVERWRITE" -eq 0 ]; then
                local_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')
                debug "      File exists locally, size: $local_size bytes"
                if [ "$remote_size" -gt 0 ] && [ "$local_size" -eq "$remote_size" ]; then
                    debug "      File sizes match, will skip"
                    will_skip=1
                fi
            else
                debug "      File does not exist locally or overwrite is forced: $local_path"
            fi

            file_key="$file_url"
            if grep -q -x -F "$file_key" "$PROCESSED_FILES_TRACKER" 2>/dev/null; then
                debug "      DUPLICATE: File already processed in this scan, skipping: $filename"
                continue
            fi
            echo "$file_key" >> "$PROCESSED_FILES_TRACKER"

            printf "FILE|%s|%s|%d|%s|%s|%s\n" "$file_type" "$will_skip" "$remote_size" "$file_url" "$local_path" "$filename" >> "$temp_files"
        fi
    done

    if [ -f "$temp_files" ]; then
        while IFS='|' read -r record_type file_type will_skip remote_size file_url local_path filename || [ -n "$record_type" ]; do
            [ "$record_type" != "FILE" ] && continue
            case "$file_type" in
                "media")
                    if [ "$will_skip" -eq 1 ]; then MEDIA_SKIPPED_COUNT=$((MEDIA_SKIPPED_COUNT + 1)); else
                        MEDIA_FILES_COUNT=$((MEDIA_FILES_COUNT + 1))
                        MEDIA_TOTAL_SIZE=$((MEDIA_TOTAL_SIZE + remote_size))
                        printf "DOWNLOAD|%s|%s|%s|%s|%d\n" "$file_url" "$local_path" "$filename" "$file_type" "$remote_size" >> "$DOWNLOAD_QUEUE_FILE"
                    fi ;;
                "poster")
                    if [ "$will_skip" -eq 1 ]; then POSTER_SKIPPED_COUNT=$((POSTER_SKIPPED_COUNT + 1)); else
                        POSTER_FILES_COUNT=$((POSTER_FILES_COUNT + 1))
                        POSTER_TOTAL_SIZE=$((POSTER_TOTAL_SIZE + remote_size))
                        printf "DOWNLOAD|%s|%s|%s|%s|%d\n" "$file_url" "$local_path" "$filename" "$file_type" "$remote_size" >> "$DOWNLOAD_QUEUE_FILE"
                    fi ;;
                "subtitle")
                    if [ "$will_skip" -eq 1 ]; then SUBTITLE_SKIPPED_COUNT=$((SUBTITLE_SKIPPED_COUNT + 1)); else
                        SUBTITLE_FILES_COUNT=$((SUBTITLE_FILES_COUNT + 1))
                        SUBTITLE_TOTAL_SIZE=$((SUBTITLE_TOTAL_SIZE + remote_size))
                        printf "DOWNLOAD|%s|%s|%s|%s|%d\n" "$file_url" "$local_path" "$filename" "$file_type" "$remote_size" >> "$DOWNLOAD_QUEUE_FILE"
                    fi ;;
            esac
        done < "$temp_files"
        rm -f "$temp_files"
    fi

    if [ -f "$temp_dirs" ]; then
        while IFS='|' read -r subdir_url subdir_local_base subdir_name || [ -n "$subdir_url" ]; do
            [ -z "$subdir_url" ] && continue
            # --- FIX --- The old, ineffective check here is removed. The check at the top of the function handles this logic correctly now.
            scan_directory_files "$subdir_url" "$subdir_local_base" "$subdir_name"
        done < "$temp_dirs"
        rm -f "$temp_dirs"
    fi
}

# Show download summary
show_download_summary() {
    printf "\n"
    printf "========================================\n"
    printf "      DOWNLOAD SUMMARY\n"
    printf "========================================\n"

    # Check for duplicate entries in download queue
    if [ -f "$DOWNLOAD_QUEUE_FILE" ]; then
        total_lines=$(wc -l < "$DOWNLOAD_QUEUE_FILE" 2>/dev/null || echo '0')
        unique_lines=$(cut -d'|' -f2 "$DOWNLOAD_QUEUE_FILE" | sort -u | wc -l 2>/dev/null || echo '0')

        if [ "$total_lines" -ne "$unique_lines" ]; then
            debug "DUPLICATE WARNING: Found duplicate entries in download queue!"
            debug "  Total entries: $total_lines"
            debug "  Unique entries: $unique_lines"
            debug "  Duplicates: $((total_lines - unique_lines))"
        else
            debug "QUEUE VERIFICATION: No duplicate entries found in download queue"
            debug "  Total entries: $total_lines"
        fi
    fi

    # Calculate total sizes
    total_download_size=$((MEDIA_TOTAL_SIZE + POSTER_TOTAL_SIZE + SUBTITLE_TOTAL_SIZE))
    total_skipped=$((MEDIA_SKIPPED_COUNT + POSTER_SKIPPED_COUNT + SUBTITLE_SKIPPED_COUNT))

    # Show files to download by type
    printf "Files to download:\n"
    if [ "$MEDIA_FILES_COUNT" -gt 0 ]; then
        media_size=$(format_bytes "$MEDIA_TOTAL_SIZE")
        printf "  Media files:    %3d (%s)\n" "$MEDIA_FILES_COUNT" "$media_size"
    fi

    if [ "$POSTER_FILES_COUNT" -gt 0 ]; then
        poster_size=$(format_bytes "$POSTER_TOTAL_SIZE")
        printf "  Image files:    %3d (%s)\n" "$POSTER_FILES_COUNT" "$poster_size"
    fi

    if [ "$SUBTITLE_FILES_COUNT" -gt 0 ]; then
        subtitle_size=$(format_bytes "$SUBTITLE_TOTAL_SIZE")
        printf "  Subtitle files: %3d (%s)\n" "$SUBTITLE_FILES_COUNT" "$subtitle_size"
    fi

    # Show files to skip by type
    if [ "$total_skipped" -gt 0 ]; then
        printf "\nFiles to skip (already exist):\n"
        if [ "$MEDIA_SKIPPED_COUNT" -gt 0 ]; then
            printf "  Media files:    %3d\n" "$MEDIA_SKIPPED_COUNT"
        fi
        if [ "$POSTER_SKIPPED_COUNT" -gt 0 ]; then
            printf "  Image files:    %3d\n" "$POSTER_SKIPPED_COUNT"
        fi
        if [ "$SUBTITLE_SKIPPED_COUNT" -gt 0 ]; then
            printf "  Subtitle files: %3d\n" "$SUBTITLE_SKIPPED_COUNT"
        fi
    fi

    # Show filtered files by type
    total_filtered=$((MEDIA_FILTERED_COUNT + POSTER_FILTERED_COUNT + SUBTITLE_FILTERED_COUNT))
    if [ "$total_filtered" -gt 0 ]; then
        printf "\n"
        log "Files filtered out (excluded by filters):"
        if [ "$MEDIA_FILTERED_COUNT" -gt 0 ]; then
            log "  Media files:    %3d" "$MEDIA_FILTERED_COUNT"
        fi
        if [ "$POSTER_FILTERED_COUNT" -gt 0 ]; then
            log "  Image files:    %3d" "$POSTER_FILTERED_COUNT"
        fi
        if [ "$SUBTITLE_FILTERED_COUNT" -gt 0 ]; then
            log "  Subtitle files: %3d" "$SUBTITLE_FILTERED_COUNT"
        fi

        # Show active filters
        printf "\n"
        log "Active filters:"
        [ "$MIN_FILE_SIZE" -gt 0 ] && log "  Min size: %s" "$(format_bytes "$MIN_FILE_SIZE")"
        [ "$MAX_FILE_SIZE" -gt 0 ] && log "  Max size: %s" "$(format_bytes "$MAX_FILE_SIZE")"
        [ -n "$EXCLUDE_EXTENSIONS" ] && log "  Exclude extensions: %s" "$EXCLUDE_EXTENSIONS"
        [ -n "$EXCLUDE_KEYWORDS" ] && log "  Exclude keywords: %s" "$EXCLUDE_KEYWORDS"
        [ -n "$EXCLUDE_REGEX" ] && log "  Exclude regex: %s" "$EXCLUDE_REGEX"

        # Also log to debug for more detailed tracking
        debug "FILTER SUMMARY: Total filtered files: $total_filtered"
        debug "FILTER SUMMARY: Media filtered: $MEDIA_FILTERED_COUNT, Poster filtered: $POSTER_FILTERED_COUNT, Subtitle filtered: $SUBTITLE_FILTERED_COUNT"
    fi

    # Show totals
    printf "\nTotal files to download: %d\n" "$TOTAL_FILES_TO_DOWNLOAD"
    if [ "$total_skipped" -gt 0 ]; then
        printf "Total files to skip:   %d\n" "$total_skipped"
    fi

    if [ "$total_download_size" -gt 0 ]; then
        total_size_formatted=$(format_bytes "$total_download_size")
        printf "Total download size:   %s\n" "$total_size_formatted"

        # Estimate download time (assuming 1MB/s as conservative estimate)
        if [ "$total_download_size" -gt 1048576 ]; then
            estimate_seconds=$((total_download_size / 1048576))
            if [ "$estimate_seconds" -gt 3600 ]; then
                estimate_hours=$((estimate_seconds / 3600))
                estimate_minutes=$(((estimate_seconds % 3600) / 60))
                printf "Estimated time:        ~%d hours %d minutes (at 1MB/s)\n" "$estimate_hours" "$estimate_minutes"
            elif [ "$estimate_seconds" -gt 60 ]; then
                estimate_minutes=$((estimate_seconds / 60))
                estimate_seconds=$((estimate_seconds % 60))
                printf "Estimated time:        ~%d minutes %d seconds (at 1MB/s)\n" "$estimate_minutes" "$estimate_seconds"
            else
                printf "Estimated time:        ~%d seconds (at 1MB/s)\n" "$estimate_seconds"
            fi
        fi
    fi

    printf "========================================\n"
}

# Show download progress
show_download_progress() {
    current_file="$1"
    file_size="$2"
    file_type="$3"

    if [ "$SHOW_PROGRESS" -eq 0 ] || [ "$QUIET" -eq 1 ]; then
        return 0
    fi

    # Calculate progress percentage
    if [ "$TOTAL_FILES_TO_DOWNLOAD" -gt 0 ]; then
        percentage=$((CURRENT_FILE_NUMBER * 100 / TOTAL_FILES_TO_DOWNLOAD))
    else
        percentage=0
    fi

    # Calculate elapsed time and speed
    if [ "$START_TIME" -gt 0 ]; then
        current_time=$(date +%s)
        elapsed_seconds=$((current_time - START_TIME))

        if [ "$elapsed_seconds" -gt 0 ]; then
            if [ "$DOWNLOADED_BYTES" -gt 0 ]; then
                speed_bytes_per_second=$((DOWNLOADED_BYTES / elapsed_seconds))
                speed_formatted=$(format_bytes "$speed_bytes_per_second")
                speed_display="$speed_formatted/s"
            else
                speed_display="calculating..."
            fi

            # Estimate remaining time
            if [ "$CURRENT_FILE_NUMBER" -gt 0 ] && [ "$elapsed_seconds" -gt 0 ]; then
                avg_time_per_file=$((elapsed_seconds / CURRENT_FILE_NUMBER))
                remaining_files=$((TOTAL_FILES_TO_DOWNLOAD - CURRENT_FILE_NUMBER))
                remaining_seconds=$((remaining_files * avg_time_per_file))

                if [ "$remaining_seconds" -gt 3600 ]; then
                    remaining_hours=$((remaining_seconds / 3600))
                    remaining_minutes=$(((remaining_seconds % 3600) / 60))
                    remaining_time="~${remaining_hours}h ${remaining_minutes}m"
                elif [ "$remaining_seconds" -gt 60 ]; then
                    remaining_minutes=$((remaining_seconds / 60))
                    remaining_seconds=$((remaining_seconds % 60))
                    remaining_time="~${remaining_minutes}m ${remaining_seconds}s"
                else
                    remaining_time="~${remaining_seconds}s"
                fi
            else
                remaining_time="calculating..."
            fi
        else
            speed_display="starting..."
            remaining_time="starting..."
        fi
    else
        speed_display="starting..."
        remaining_time="starting..."
    fi

    # Format file size
    file_size_formatted=$(format_bytes "$file_size")

    # Clear line and show progress
    printf "\r\033[K"  # Clear line
    printf "[%s] %d/%d (%d%%) | %s | %s/s | ETA: %s" \
           "$(date '+%H:%M:%S')" \
           "$CURRENT_FILE_NUMBER" \
           "$TOTAL_FILES_TO_DOWNLOAD" \
           "$percentage" \
           "$file_size_formatted" \
           "$speed_display" \
           "$remaining_time"

    # Show progress bar
    bar_width=30
    filled=$((percentage * bar_width / 100))
    empty=$((bar_width - filled))
    printf " ["
    i=0
    while [ "$i" -lt "$filled" ]; do
        printf "="
        i=$((i + 1))
    done
    while [ "$i" -lt "$bar_width" ]; do
        printf " "
        i=$((i + 1))
    done
    printf "]"

    # Flush output
    printf "\n"
}

# Complete download progress (show final line)
complete_download_progress() {
    if [ "$SHOW_PROGRESS" -eq 0 ] || [ "$QUIET" -eq 1 ]; then
        return 0
    fi

    printf "\r\033[K"  # Clear line
    printf "\n"

    # Check if download was interrupted
    if [ "$INTERRUPTED" -eq 1 ]; then
        printf "⏸ Download interrupted by user! %d files downloaded, %s\n" \
               "$DOWNLOADED_FILES" \
               "$(format_bytes "$DOWNLOADED_BYTES")"
    else
        printf "✓ Download completed! %d files, %s\n" \
               "$DOWNLOADED_FILES" \
               "$(format_bytes "$DOWNLOADED_BYTES")"
    fi
}

# Download a single file with progress
download_file() {
    file_url="$1"
    local_path="$2"
    filename="$3"
    file_size="$4"
    file_type="$5"

    # Check if we should continue (not interrupted)
    should_continue || return 1

    # Track current download for interruption handling
    CURRENT_DOWNLOAD_URL="$file_url"
    CURRENT_DOWNLOAD_FILE="$filename"

    local_dir=$(dirname "$local_path")
    mkdir -p "$local_dir" || return 1

    # Get remote file size for accurate comparison
    remote_size=$(get_remote_file_size "$file_url")
    [ "$file_size" -eq 0 ] && file_size="$remote_size"

    debug "=== DOWNLOAD START: $filename ==="
    debug "  File URL: $file_url"
    debug "  Local path: $local_path"
    debug "  Expected size: $file_size bytes"
    debug "  Remote size: $remote_size bytes"
    debug "  Resume enabled: $RESUME"
    debug "  Force overwrite: $FORCE_OVERWRITE"

    # Enhanced file existence and size checking
    will_resume=0
    if [ -f "$local_path" ] && [ "$FORCE_OVERWRITE" -eq 0 ]; then
        # Get local file size
        local_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')
        debug "  Local file exists, size: $local_size bytes"

        if [ "$remote_size" -gt 0 ]; then
            if [ "$local_size" -eq "$remote_size" ]; then
                # File exists and sizes match - skip download
                log "  ✓ $filename ($(format_bytes "$local_size") - already exists)"
                debug "  SKIP: File complete, no download needed"
                SKIPPED_FILES=$((SKIPPED_FILES + 1))
                return 0
            elif [ "$local_size" -lt "$remote_size" ] && [ "$RESUME" -eq 1 ]; then
                # File exists but is smaller - resume download
                remaining_bytes=$((remote_size - local_size))
                percent_complete=$((local_size * 100 / remote_size))
                log "  ↻ $filename (resuming at ${percent_complete}% - $(format_bytes "$local_size")/$(format_bytes "$remote_size"))"
                debug "  RESUME: Partial file found, downloading remaining $remaining_bytes bytes"
                will_resume=1
            elif [ "$local_size" -lt "$remote_size" ] && [ "$RESUME" -eq 0 ]; then
                # File exists but is smaller and resume is disabled - redownload
                log "  ↻ $filename ($(format_bytes "$local_size") → $(format_bytes "$remote_size") - incomplete, restarting)"
                debug "  RESTART: Partial file found but resume disabled"
            elif [ "$local_size" -gt "$remote_size" ]; then
                # Local file is larger than expected - redownload
                log "  ↻ $filename ($(format_bytes "$local_size") → $(format_bytes "$remote_size") - larger than expected, restarting)"
                debug "  RESTART: Local file larger than remote ($local_size > $remote_size)"
            fi
        else
            # Could not determine remote size - check if we should resume based on file existence
            if [ "$RESUME" -eq 1 ] && [ "$local_size" -gt 0 ]; then
                # Check if file is likely complete by testing if we can read from it properly
                # and if it hasn't been modified recently (to avoid corrupted files)
                if [ "$local_size" -gt 1048576 ]; then  # File is larger than 1MB
                    log "  ↻ $filename (remote size unknown, attempting resume from $(format_bytes "$local_size"))"
                    debug "  RESUME: Remote size unknown, will attempt resume"
                    will_resume=1
                else
                    log "  ? $filename (small file, size unknown - redownloading)"
                    debug "  RESTART: Small file with unknown size, will download fresh"
                    # For small files, it's safer to restart than to risk corruption
                fi
            else
                log "  ? $filename (size unknown - redownloading)"
                debug "  RESTART: Size unknown, will download fresh"
            fi
        fi
    elif [ -f "$local_path" ] && [ "$FORCE_OVERWRITE" -eq 1 ]; then
        # File exists but force overwrite is enabled
        log "  ↻ $filename (force overwrite)"
        debug "  RESTART: Force overwrite enabled"
    else
        # File doesn't exist - fresh download
        debug "  NEW: File doesn't exist, fresh download"
    fi

    # Show progress for this file
    CURRENT_FILE_NUMBER=$((CURRENT_FILE_NUMBER + 1))
    show_download_progress "$filename" "$file_size" "$file_type"

    # Show download info only in debug mode
    debug "  Downloading: $filename"
    debug "    URL: $file_url"
    debug "    Local: $local_path"
    debug "    Resume enabled: $RESUME, Will resume: $will_resume"

    # Build curl options with enhanced resume support
    # Removed max-time limit to prevent timeouts on large files - we have our own interruption handling
    curl_opts="--silent --location --retry 3 --connect-timeout 30"

    if [ "$will_resume" -eq 1 ] && [ "$RESUME" -eq 1 ]; then
        # Use specific resume position instead of automatic detection
        local_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')
        curl_opts="$curl_opts --continue-at $local_size"
        debug "    Resuming from byte position: $local_size"
        log "    RESUME: Continuing from $(format_bytes "$local_size")"

        # Backup current file in case resume fails
        if [ "$local_size" -gt 0 ]; then
            cp "$local_path" "${local_path}.resume_backup" 2>/dev/null || true
            debug "    Created backup: ${local_path}.resume_backup"
        fi
    elif [ "$RESUME" -eq 1 ]; then
        # General resume flag (fallback)
        # But first check if file might already be complete
        current_local_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')
        if [ -f "$local_path" ] && [ "$current_local_size" -gt 0 ]; then
            # For automatic resume, test if the file is likely complete by trying to read it
            if [ "$current_local_size" -gt 1048576 ]; then  # > 1MB
                # Try to verify file integrity by checking if we can read the end of the file
                if tail -c 1024 "$local_path" >/dev/null 2>&1; then
                    debug "    File appears readable, attempting automatic resume"
                    curl_opts="$curl_opts --continue-at -"
                    debug "    Using automatic resume detection"
                    log "    RESUME: Automatic detection"
                else
                    debug "    File appears corrupted, will restart download"
                    log "    RESTART: File appears corrupted"
                    # Don't use resume for corrupted files - start fresh
                fi
            else
                # For small files, automatic resume is more reliable
                curl_opts="$curl_opts --continue-at -"
                debug "    Using automatic resume detection for small file"
                log "    RESUME: Automatic detection"
            fi
        else
            curl_opts="$curl_opts --continue-at -"
            debug "    Using automatic resume detection"
            log "    RESUME: Automatic detection"
        fi
    fi

    # Track initial file size for progress calculation
    initial_size=0
    if [ "$will_resume" -eq 1 ]; then
        initial_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')
    fi

    # Check interruption before starting download
    should_continue || return 1

    # Start download with background monitoring
    log "  ↓ $filename ($(format_bytes "$file_size") - downloading...)"

    # Run curl in background to monitor for interruptions
    debug "    Executing: curl $curl_opts -o \"$local_path\" \"$file_url\""
    curl $curl_opts -o "$local_path" "$file_url" &
    curl_pid=$!

    # Monitor curl progress and check for interruptions
    while kill -0 "$curl_pid" 2>/dev/null; do
        # Check if user interrupted
        if ! should_continue; then
            # Kill the curl process gracefully
            kill -TERM "$curl_pid" 2>/dev/null || true
            wait "$curl_pid" 2>/dev/null || true
            echo ""
            log "  ⏸ $filename (download interrupted - can be resumed)"
            return 1
        fi

        # Check progress every 2 seconds
        sleep 2

        # Show progress if file is large enough
        if [ "$file_size" -gt 1048576 ]; then  # > 1MB
            current_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')
            if [ "$current_size" -gt "$initial_size" ]; then
                # Calculate total progress of the entire file, not just the remaining portion
                progress=$(( current_size * 100 / ($file_size + 1) ))
                printf "\r  ↓ %s (%d%% - %s/%s)" "$filename" "$progress" "$(format_bytes "$current_size")" "$(format_bytes "$file_size")"
            fi
        fi
    done

    # Wait for curl to complete and check exit status
    wait "$curl_pid"
    curl_exit_code=$?

    # Clear progress line if shown
    [ "$file_size" -gt 1048576 ] && printf "\r"

    # Verify resume worked correctly
    if [ "$will_resume" -eq 1 ] && [ "$initial_size" -gt 0 ]; then
        final_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')
        if [ "$final_size" -lt "$initial_size" ]; then
            debug "  WARNING: Resume may have failed - final size ($final_size) < initial size ($initial_size)"
            log "  ⚠ Resume warning: File size decreased from $(format_bytes "$initial_size") to $(format_bytes "$final_size")"
            # Try to restore from backup if it exists
            if [ -f "${local_path}.resume_backup" ]; then
                log "  ↻ Restoring from backup due to resume failure"
                mv "${local_path}.resume_backup" "$local_path" 2>/dev/null || true
            fi
        else
            debug "  Resume verification: Initial=$initial_size, Final=$final_size, Downloaded=$((final_size - initial_size))"
            # Remove backup if resume succeeded
            rm -f "${local_path}.resume_backup" 2>/dev/null || true
        fi
    fi

    if [ "$curl_exit_code" -eq 0 ]; then
        # Get final file size
        final_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')

        debug "=== DOWNLOAD COMPLETE: $filename ==="
        debug "  Initial size: $initial_size bytes"
        debug "  Final size: $final_size bytes"
        debug "  Expected size: $file_size bytes"
        debug "  Remote size: $remote_size bytes"

        # Verify download completion
        download_complete=1
        if [ "$remote_size" -gt 0 ]; then
            if [ "$final_size" -eq "$remote_size" ]; then
                debug "  SUCCESS: File size matches remote ($final_size = $remote_size)"
            elif [ "$final_size" -lt "$remote_size" ]; then
                debug "  ERROR: File still incomplete ($final_size < $remote_size)"
                log "  ✗ $filename (download incomplete: $(format_bytes "$final_size")/$(format_bytes "$remote_size"))"
                download_complete=0
            elif [ "$final_size" -gt "$remote_size" ]; then
                debug "  WARNING: File larger than expected ($final_size > $remote_size)"
                log "  ⚠ $filename (file larger than expected: $(format_bytes "$final_size") vs $(format_bytes "$remote_size"))"
                # Don't treat this as an error, just a warning
            fi
        else
            debug "  SUCCESS: Download completed (remote size unknown)"
        fi

        # If download is incomplete, return failure so it can be retried
        if [ "$download_complete" -eq 0 ]; then
            return 1
        fi

        # Calculate downloaded bytes (for resumed downloads, only count the new portion)
        if [ "$will_resume" -eq 1 ] && [ "$initial_size" -gt 0 ]; then
            downloaded_this_time=$((final_size - initial_size))
            if [ "$downloaded_this_time" -gt 0 ]; then
                DOWNLOADED_BYTES=$((DOWNLOADED_BYTES + downloaded_this_time))
                debug "  Downloaded this session: $(format_bytes "$downloaded_this_time")"
            else
                # Fallback: use file_size if calculation failed
                if [ "$file_size" -gt 0 ]; then
                    DOWNLOADED_BYTES=$((DOWNLOADED_BYTES + file_size))
                    debug "  Using expected size for progress: $(format_bytes "$file_size")"
                fi
            fi
        else
            # Fresh download or full restart
            if [ "$file_size" -gt 0 ]; then
                DOWNLOADED_BYTES=$((DOWNLOADED_BYTES + file_size))
                debug "  Using expected size for progress: $(format_bytes "$file_size")"
            else
                # If we don't know the expected size, use the actual downloaded size
                DOWNLOADED_BYTES=$((DOWNLOADED_BYTES + final_size))
                debug "  Using actual size for progress: $(format_bytes "$final_size")"
            fi
        fi

        # Clear current download tracking to prevent re-download
        CURRENT_DOWNLOAD_URL=""
        CURRENT_DOWNLOAD_FILE=""

        DOWNLOADED_FILES=$((DOWNLOADED_FILES + 1))
        log "  ✓ $filename ($(format_bytes "$final_size"))"
        return 0
    else
        error "  ✗ Failed: $filename"
        debug "    URL: $file_url"

        # Try to get HTTP status code for better error reporting
        http_code=$(curl --silent --location --head --write-out "%{http_code}" --output /dev/null "$file_url" 2>/dev/null || echo "Unknown")
        debug "    HTTP Status: $http_code"

        # Check if the server supports range requests (important for resume)
        if [ "$will_resume" -eq 1 ] && [ "$http_code" = "416" ]; then
            debug "    Server does not support range requests or file is complete"
        fi

        return 1
    fi
}

# Download files from a directory recursively
download_directory_files() {
    remote_url="$1"
    local_base="$2"
    folder_name="$3"

    # Check for interruption before processing directory
    should_continue || return 1

    # Track current directory for interruption handling
    CURRENT_BASE_URL="$remote_url"
    CURRENT_FOLDER_NAME="$folder_name"

    log "Processing: $folder_name"
    debug "  DEBUG: Received folder_name='$folder_name'"
    debug "  DEBUG: Received local_base='$local_base'"
    debug "  Fetching directory listing from: $remote_url"

    href_paths=$(get_href_paths "$remote_url")
    if [ -z "$href_paths" ]; then
        log "  No files found in directory"
        return 0
    fi

    # Debug: show what we found
    debug "  Found $(printf '%s\n' "$href_paths" | wc -l) items in directory"

    # Decode folder name for local directory creation
    folder_name_decoded=$(url_decode "$folder_name")

    # Create local directory - use the folder name directly without accumulating paths
    local_dir="$local_base/$folder_name_decoded"
    mkdir -p "$local_dir"
    debug "  Created local directory: $local_dir"

    # Get base domain for absolute paths
    base_domain=$(echo "$BASE_URL" | sed 's|^\(https\?://[^/]*\).*|\1|')

    # Process files and subdirectories
    temp_file="$TEMP_DIR/download_$$_$(date +%s)"
    temp_dirs="$TEMP_DIR/dirs_$$_$(date +%s)"
    found_files=0

    printf '%s\n' "$href_paths" | while IFS= read -r link_path; do
        [ -z "$link_path" ] && continue

        decoded_path=$(url_decode "$link_path")

        # Check if this is a directory
        is_directory=0
        case "$decoded_path" in
            */) is_directory=1 ;;
        esac

        # Skip external URLs that don't match our domain
        case "$link_path" in
            http://*|https://*)
                if ! echo "$link_path" | grep -q "^$base_domain"; then
                    continue
                fi
                ;;
        esac

        # Process directories separately
        if [ "$is_directory" -eq 1 ]; then
            # Skip navigation directories and current directory
            case "$link_path" in
                .|..|./|../|*/_h5ai/*)
                    continue
                    ;;
            esac

            # Also skip based on decoded path
            case "$decoded_path" in
                */.|*/..|*/_h5ai/*|.|..)
                    continue
                    ;;
            esac

            subdir_name=$(basename "${decoded_path%/}")

            # Skip if subdirectory name is empty or just whitespace
            if [ -z "$subdir_name" ] || [ -z "$(echo "$subdir_name" | tr -d '[:space:]')" ]; then
                debug "    Skipping empty subdirectory name"
                continue
            fi

            # Build subdirectory URL first to check if it's the current directory
            case "$link_path" in
                http://*|https://*)
                    subdir_url="$link_path"
                    ;;
                /*)
                    subdir_url="$base_domain${link_path%/}/"
                    ;;
                *)
                    subdir_url="${remote_url%/}/${link_path%/}/"
                    ;;
            esac

            # Normalize URL
            subdir_url=$(echo "$subdir_url" | sed 's|//*/|/|g' | sed 's|^\(https\?:\)\(/\)\+|\1//|')

            # Skip if subdirectory URL is the same as current URL (this catches self-referencing directories)
            if [ "$subdir_url" = "$remote_url" ] || [ "${subdir_url%/}" = "${remote_url%/}" ]; then
                debug "    Skipping self-referencing directory: $subdir_name"
                continue
            fi

            # Skip if subdirectory has the same name as current directory (additional safety check)
            # Compare decoded names to handle URL encoding differences
            if [ "$subdir_name" = "$folder_name_decoded" ] || [ "$subdir_name" = "$folder_name" ]; then
                debug "    Skipping subdirectory with same name as parent: $subdir_name"
                continue
            fi

            debug "    Found subdirectory: $subdir_name"
            debug "    Subdirectory URL: $subdir_url"
            debug "    DEBUG: Storing subdirectory name: '$subdir_name'"
            printf "%s|%s\n" "$subdir_url" "$subdir_name" >> "$temp_dirs"
            continue
        fi

        # Debug: show each file we're checking
        [ "$QUIET" -eq 0 ] && printf "    Checking: %s\n" "$decoded_path"

        if is_supported_extension "$decoded_path"; then
            filename=$(basename "$decoded_path")

            # Handle different types of paths - simplified approach
            case "$link_path" in
                http://*|https://*)
                    # Full URL
                    file_url="$link_path"
                    ;;
                /*)
                    # Absolute path - use as is (h5ai handles the encoding)
                    file_url="$base_domain$link_path"
                    ;;
                *)
                    # Relative path
                    file_url="${remote_url%/}/$link_path"
                    ;;
            esac

            local_path="$local_dir/$filename"

            found_files=$((found_files + 1))
            printf "DOWNLOAD|%s|%s|%s\n" "$file_url" "$local_path" "$filename" >> "$temp_file"

            if [ "$DRY_RUN" -eq 1 ]; then
                printf "  Would download: %s\n" "$filename"
            else
                debug "  Found file to download: %s\n" "$filename"
            fi
        fi
    done

    # Process downloads if we found any files
    if [ -f "$temp_file" ]; then
        file_count=$(wc -l < "$temp_file")
        log "  Found $file_count files to download in this directory"
        TOTAL_FILES=$((TOTAL_FILES + file_count))

        if [ "$DRY_RUN" -eq 0 ]; then
            # Download files sequentially for better error handling
            while IFS='|' read -r action file_url local_path filename || [ -n "$action" ]; do
                [ "$action" != "DOWNLOAD" ] && continue

                # Check for interruption before each download
                if ! should_continue; then
                    log "  ⏸ Processing interrupted by user"
                    break
                fi

                # Download file (not in background)
                download_file "$file_url" "$local_path" "$filename"
            done < "$temp_file"
        fi

        rm -f "$temp_file"
    else
        log "  No supported files found in this directory"
    fi

    # Process subdirectories recursively
    if [ -f "$temp_dirs" ]; then
        subdir_count=$(wc -l < "$temp_dirs")
        log "  Found $subdir_count subdirectories to process"

        while IFS='|' read -r subdir_url subdir_name || [ -n "$subdir_url" ]; do
            [ -z "$subdir_url" ] && continue

            # Check for interruption before processing subdirectory
            if ! should_continue; then
                log "  ⏸ Directory processing interrupted by user"
                break
            fi

            debug "  Recursing into subdirectory: $subdir_name"
            debug "  DEBUG: About to call download_directory_files with folder_name='$subdir_name'"
            # Recursively download from subdirectory - use original local_base to avoid nested directories
            download_directory_files "$subdir_url" "$local_base" "$subdir_name"
        done < "$temp_dirs"

        rm -f "$temp_dirs"
    fi
}

# Parse command line arguments
parse_arguments() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -d|--destination)
                [ -z "$2" ] && die "Option $1 requires an argument"
                DOWNLOAD_DESTINATION="$2"
                shift 2
                ;;
            -D|--depth)
                [ -z "$2" ] && die "Option $1 requires an argument"
                MAX_SEARCH_DEPTH="$2"
                shift 2
                ;;
            -t|--threads)
                [ -z "$2" ] && die "Option $1 requires an argument"
                MAX_THREADS="$2"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN=1
                shift
                ;;
            -r|--resume)
                # Check if this is a session resume (no BASE_URL provided yet)
                if [ $# -eq 1 ] || ([ "$2" = "-d" ] && [ $# -le 3 ]) || ([ "$2" = "-t" ] && [ $# -le 3 ]) || ([ "$2" = "--max-size" ] && [ $# -le 3 ]); then
                    SESSION_RESUME=1
                else
                    RESUME=1
                fi
                shift
                ;;
            -f|--force-overwrite)
                FORCE_OVERWRITE=1
                shift
                ;;
            -q|--quiet)
                QUIET=1
                shift
                ;;
            --debug)
                DEBUG=1
                shift
                ;;
            --min-size)
                [ -z "$2" ] && die "Option $1 requires an argument"
                MIN_FILE_SIZE=$(parse_size "$2")
                shift 2
                ;;
            --max-size)
                [ -z "$2" ] && die "Option $1 requires an argument"
                MAX_FILE_SIZE=$(parse_size "$2")
                shift 2
                ;;
            --exclude-ext)
                [ -z "$2" ] && die "Option $1 requires an argument"
                EXCLUDE_EXTENSIONS="$2"
                shift 2
                ;;
            --exclude-keywords)
                [ -z "$2" ] && die "Option $1 requires an argument"
                EXCLUDE_KEYWORDS="$2"
                shift 2
                ;;
            --exclude-regex)
                [ -z "$2" ] && die "Option $1 requires an argument"
                EXCLUDE_REGEX="$2"
                shift 2
                ;;
            -c|--config)
                [ -z "$2" ] && die "Option $1 requires an argument"
                CONFIG_FILE="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -v|--version)
                show_version
                exit 0
                ;;
            -*)
                die "Unknown option: $1"
                ;;
            *)
                if [ -z "$BASE_URL" ]; then
                    BASE_URL="$1"
                elif [ -z "$SEARCH_KEYWORDS" ]; then
                    SEARCH_KEYWORDS="$1"
                else
                    SEARCH_KEYWORDS="$SEARCH_KEYWORDS $1"
                fi
                shift
                ;;
        esac
    done

    # Check if we're resuming from a saved state (session resume, not individual file resume)
    if [ "$SESSION_RESUME" -eq 1 ]; then
        if [ -f "$STATE_FILE" ] || [ -f "$RESUME_STATE_FILE" ]; then
            # Resume mode - load state first, then validate
            log "Checking for saved session state..."
            load_session_state

            # Use restored values for BASE_URL and SEARCH_KEYWORDS if available
            # (These will be available if we saved CURRENT_BASE_URL)
            if [ -n "$CURRENT_BASE_URL" ]; then
                BASE_URL="$CURRENT_BASE_URL"
                log "Restored BASE_URL from saved state"
            elif [ -n "$BASE_URL" ]; then
                log "Using original BASE_URL from saved state"
            fi

            # For resume mode, we don't need SEARCH_KEYWORDS since we're continuing
            # from a specific directory context
        else
            # Resume requested but no state file found
            die "No saved session state found. Cannot resume.\n       Expected state file: $RESUME_STATE_FILE\n       Tip: Use resume only after interrupting a running session with Ctrl+C."
        fi
    else
        # Normal mode - validate required arguments
        [ -z "$BASE_URL" ] && die "BASE_URL is required. Use -h for help."
        [ -z "$SEARCH_KEYWORDS" ] && die "SEARCH_KEYWORDS are required. Use -h for help."
    fi

    # Ensure BASE_URL ends with /
    case "$BASE_URL" in
        */) ;;
        *) BASE_URL="$BASE_URL/" ;;
    esac

    # Validate numeric arguments
    case "$MAX_SEARCH_DEPTH" in
        ''|*[!0-9]*) die "MAX_SEARCH_DEPTH must be a positive integer" ;;
    esac
    case "$MAX_THREADS" in
        ''|*[!0-9]*) die "MAX_THREADS must be a positive integer" ;;
    esac

    # Validate threads count
    [ "$MAX_THREADS" -lt 1 ] && MAX_THREADS=1
    [ "$MAX_THREADS" -gt 10 ] && MAX_THREADS=10
}

# Main execution function
main() {
    # Set up signal handlers for graceful interruption
    trap handle_interrupt INT
    trap handle_terminate TERM
    trap cleanup EXIT

    # Check dependencies and load config
    check_dependencies
    load_config

    # Parse arguments (this may override config values)
    parse_arguments "$@"

    # Create temporary directory (clean up old temp directories first)
    for old_temp_dir in /tmp/${SCRIPT_NAME}_*; do
        if [ -d "$old_temp_dir" ] && [ "$old_temp_dir" != "$TEMP_DIR" ]; then
            debug "Cleaning up old temporary directory: $old_temp_dir"
            rm -rf "$old_temp_dir" 2>/dev/null || true
        fi
    done

    mkdir -p "$TEMP_DIR" || die "Cannot create temporary directory"

    log "$SCRIPT_NAME v$VERSION starting..."
    [ "$DRY_RUN" -eq 1 ] && log "DRY RUN MODE - No files will be downloaded"

    log "Base URL: $BASE_URL"
    log "Keywords: $SEARCH_KEYWORDS"
    log "Destination: $DOWNLOAD_DESTINATION"
    log "Max depth: $MAX_SEARCH_DEPTH"
    log "Threads: $MAX_THREADS"

    # Check if we're resuming from a saved session (state already loaded during validation)
    if [ "$SESSION_RESUME" -eq 1 ] && ([ -f "$STATE_FILE" ] || [ -f "$RESUME_STATE_FILE" ]); then
        log "Resuming interrupted session..."

        # Check if we have download queue to resume from
        if [ -f "$DOWNLOAD_QUEUE_FILE" ] && [ -s "$DOWNLOAD_QUEUE_FILE" ]; then
            log "Found download queue, resuming from queue..."

            # Re-scan to get file counts and summary if needed
            if [ "$TOTAL_FILES_TO_DOWNLOAD" -eq 0 ]; then
                log "Re-scanning files to get accurate counts..."
                scan_and_analyze_files
            fi

        elif [ -n "$CURRENT_BASE_URL" ] && [ -n "$CURRENT_FOLDER_NAME" ]; then
            # Create a matches file with the current directory context
            printf '%s|%s|%s\n' "$CURRENT_BASE_URL" "$CURRENT_FOLDER_NAME" "$CURRENT_FOLDER_NAME" > "$TEMP_DIR/matches"
            log "Resuming from: $CURRENT_FOLDER_NAME"
            log "Continuing download process..."

        else
            # Try to reconstruct from saved state if we have download queue info
            if [ "$TOTAL_FILES_TO_DOWNLOAD" -gt 0 ]; then
                log "Resuming from saved download progress..."
                # We'll recreate the download queue by scanning the original matches
                if [ -n "$BASE_URL" ] && [ -n "$SEARCH_KEYWORDS" ]; then
                    log "Re-scanning for folders to reconstruct download queue..."
                    find_matching_folders "$BASE_URL" 0 ""

                    if [ ! -f "$TEMP_DIR/matches" ] || [ ! -s "$TEMP_DIR/matches" ]; then
                        error "Could not reconstruct download context. Please start a new session."
                        exit 1
                    fi

                    # Scan and analyze files again
                    scan_and_analyze_files
                else
                    error "Insufficient information to resume. Please start a new session."
                    exit 1
                fi
            else
                error "Incomplete session state. Cannot resume properly."
                exit 1
            fi
        fi

    else
        # Normal mode - find matching folders
        log "Searching for matching folders..."
        find_matching_folders "$BASE_URL" 0 ""

        # Debug: show all matches found
        if [ -f "$TEMP_DIR/matches" ]; then
            debug "DEBUG: All matches found:"
            while IFS='|' read -r url path name; do
                debug "  URL: $url"
                debug "  Path: $path"
                debug "  Name: $name"
            done < "$TEMP_DIR/matches"
        fi

        # Check if we found any matches
        if [ ! -f "$TEMP_DIR/matches" ] || [ ! -s "$TEMP_DIR/matches" ]; then
            log "No folders found matching keywords: $SEARCH_KEYWORDS"
            exit 0
        fi
    fi

    # Display matches and handle selection (skip if resuming)
    if [ "$SESSION_RESUME" -eq 1 ] && ([ -f "$STATE_FILE" ] || [ -f "$RESUME_STATE_FILE" ]); then
        # Resume mode - skip selection, use the single match we created
        log "Resuming from interrupted session..."
        count=1
        selected_indices="1"
    else
        # Normal mode - display matches and get user selection
        log "Found matching folders:"
        count=0
        selected_indices=""
        while IFS='|' read -r folder_url folder_path folder_name || [ -n "$folder_url" ]; do
            count=$((count + 1))
            printf "  %d. %s\n" "$count" "$folder_name"
            debug "     URL: $folder_url"
        done < "$TEMP_DIR/matches"

        # Folder selection logic
        if [ "$DRY_RUN" -eq 0 ]; then
        printf "\nEnter folders to download (comma-separated numbers, 'a' for all): "
        read -r response
        case "$response" in
            [Aa]*) # Select all
                selected_indices=$(seq -s, 1 $count)
                ;;
            *) # Process individual selections
                selected_indices=$(echo "$response" | tr ',' '\n' | \
                    grep -o '[0-9]\+' | \
                    sort -nu | \
                    awk -v max="$count" '$1 > 0 && $1 <= max' | \
                    tr '\n' ',')
                ;;
        esac

        [ -z "$selected_indices" ] && { log "No valid selections made. Exiting."; exit 0; }
    else
            selected_indices=$(seq -s, 1 $count)
        fi
    fi  # End of normal mode selection logic

    # Filter matches based on selection
    filtered_matches="$TEMP_DIR/filtered_matches"
    awk -F'|' -v indices="$selected_indices" '
    BEGIN {
        split(indices, arr, /,/)
        for (i in arr) selections[arr[i]] = 1
        count = 0
    }
    {
        count++
        if (count in selections) print
    }' "$TEMP_DIR/matches" > "$filtered_matches"

    mv "$filtered_matches" "$TEMP_DIR/matches"

    # Create download directory
    mkdir -p "$DOWNLOAD_DESTINATION" || die "Cannot create download directory: $DOWNLOAD_DESTINATION"

    # NEW: Pre-scan and analyze files
    if [ "$DRY_RUN" -eq 0 ]; then
        scan_and_analyze_files
        show_download_summary

        # Ask for confirmation before downloading
        if [ "$TOTAL_FILES_TO_DOWNLOAD" -gt 0 ]; then
            printf "\nProceed with download? [y/N]: "
            read -r confirm
            case "$confirm" in
                [Yy]*) ;;
                *) log "Download cancelled by user."; exit 0 ;;
            esac
        else
            log "No new files to download. All files already exist with same size."
            exit 0
        fi
    fi

    # Initialize download tracking
    START_TIME=$(date +%s)
    CURRENT_FILE_NUMBER=0
    DOWNLOADED_BYTES=0
    DOWNLOADED_FILES=0
    SKIPPED_FILES=0

    # NEW: Process download queue if not dry run
    if [ "$DRY_RUN" -eq 0 ] && [ -f "$DOWNLOAD_QUEUE_FILE" ]; then
        log "Starting download of $TOTAL_FILES_TO_DOWNLOAD files..."
        log "Source: $BASE_URL"

        # Show clean file list
        printf "\n"
        printf "Files to download:\n"
        printf "────────────────────────────────────────\n"
        file_count=0
        while IFS='|' read -r action file_url local_path filename file_type file_size || [ -n "$action" ]; do
            [ "$action" != "DOWNLOAD" ] && continue
            file_count=$((file_count + 1))
            size_formatted=$(format_bytes "$file_size")
            printf "%2d. %s (%s)\n" "$file_count" "$filename" "$size_formatted"
        done < "$DOWNLOAD_QUEUE_FILE"
        printf "────────────────────────────────────────\n"
        printf "\n"

        # Process download queue - use a copy to avoid file pointer issues
        DOWNLOAD_QUEUE_COPY="$TEMP_DIR/download_queue_copy_$$.txt"
        cp "$DOWNLOAD_QUEUE_FILE" "$DOWNLOAD_QUEUE_COPY"

        debug "=== STARTING DOWNLOAD QUEUE PROCESSING ==="
        debug "  Queue file: $DOWNLOAD_QUEUE_COPY"
        debug "  Total files in queue: $(wc -l < "$DOWNLOAD_QUEUE_COPY" 2>/dev/null || echo '0')"

        # Initialize queue progress tracking
        QUEUE_PROGRESS_FILE="$TEMP_DIR/queue_progress_$$.txt"
        START_QUEUE_POSITION=1

        # Load previous progress if resuming
        if [ -f "$RESUME_STATE_FILE" ]; then
            # Try to load the last completed queue position
            if grep -q "^LAST_COMPLETED_QUEUE_POSITION=" "$RESUME_STATE_FILE" 2>/dev/null; then
                LAST_COMPLETED_POSITION=$(grep "^LAST_COMPLETED_QUEUE_POSITION=" "$RESUME_STATE_FILE" | cut -d'=' -f2)
                if [ -n "$LAST_COMPLETED_POSITION" ] && [ "$LAST_COMPLETED_POSITION" -gt 0 ]; then
                    START_QUEUE_POSITION=$((LAST_COMPLETED_POSITION + 1))
                    log "Resuming from queue position $START_QUEUE_POSITION (previously completed item #$LAST_COMPLETED_POSITION)"
                    debug "  RESUME: Starting from queue item #$START_QUEUE_POSITION"
                fi
            fi
        fi

        processed_count=0
        while IFS='|' read -r action file_url local_path filename file_type file_size || [ -n "$action" ]; do
            [ "$action" != "DOWNLOAD" ] && continue

            processed_count=$((processed_count + 1))

            # Skip completed items if resuming
            if [ "$processed_count" -lt "$START_QUEUE_POSITION" ]; then
                debug "=== SKIPPING COMPLETED QUEUE ITEM #$processed_count ==="
                debug "  Filename: $filename (already completed in previous session)"
                continue
            fi

            debug "=== PROCESSING QUEUE ITEM #$processed_count ==="
            debug "  Filename: $filename"
            debug "  File URL: $file_url"
            debug "  Local path: $local_path"
            debug "  File type: $file_type"
            debug "  File size: $file_size"

            # Create directory if needed
            local_dir=$(dirname "$local_path")
            mkdir -p "$local_dir"

            debug "Processing: $filename ($(format_bytes "$file_size"))"

            # Download file with progress tracking and retry logic
            max_retries=3
            retry_count=0
            download_success=0

            while [ "$retry_count" -lt "$max_retries" ] && [ "$download_success" -eq 0 ]; do
                if [ "$retry_count" -gt 0 ]; then
                    log "  ↻ Retrying $filename (attempt $((retry_count + 1))/$max_retries)"
                    # Small delay before retry
                    sleep 2
                fi

                # Download file with progress tracking
                if download_file "$file_url" "$local_path" "$filename" "$file_size" "$file_type"; then
                    download_success=1
                    debug "  DOWNLOAD SUCCESS: $filename completed successfully"
                else
                    retry_count=$((retry_count + 1))
                    debug "  DOWNLOAD FAILED: $filename failed (attempt $retry_count/$max_retries)"

                    # Check if we should continue processing
                    if ! should_continue; then
                        debug "  INTERRUPTED: Stopping download retries"
                        break
                    fi
                fi
            done

            if [ "$download_success" -eq 0 ]; then
                error "  ✗ Failed to download $filename after $max_retries attempts"
                # Continue to next file instead of stopping the entire process
            fi

            # Save queue progress after successful completion
            if [ "$download_success" -eq 1 ]; then
                echo "LAST_COMPLETED_QUEUE_POSITION=$processed_count" > "$QUEUE_PROGRESS_FILE"
                debug "  SAVED: Completed queue position #$processed_count"

                # Also update the main resume state file
                if [ -f "$STATE_FILE" ]; then
                    if grep -q "^LAST_COMPLETED_QUEUE_POSITION=" "$STATE_FILE" 2>/dev/null; then
                        # Update existing line
                        sed -i.bak "s/^LAST_COMPLETED_QUEUE_POSITION=.*/LAST_COMPLETED_QUEUE_POSITION=$processed_count/" "$STATE_FILE"
                    else
                        # Add new line
                        echo "LAST_COMPLETED_QUEUE_POSITION=$processed_count" >> "$STATE_FILE"
                    fi
                    # Copy to fixed resume state file
                    cp "$STATE_FILE" "$RESUME_STATE_FILE"
                fi
            fi

            debug "=== COMPLETED QUEUE ITEM #$processed_count ==="
        done < "$DOWNLOAD_QUEUE_COPY"

        debug "=== DOWNLOAD QUEUE PROCESSING COMPLETE ==="
        debug "  Processed $processed_count files"

        # Clean up the copy and progress files
        rm -f "$DOWNLOAD_QUEUE_COPY"
        rm -f "$QUEUE_PROGRESS_FILE"

        # Show final progress
        complete_download_progress
    elif [ "$DRY_RUN" -eq 1 ]; then
        # Original behavior for dry run
        log "Processing selected folders..."
        while IFS='|' read -r folder_url folder_path folder_name || [ -n "$folder_url" ]; do
            log "Processing folder: $folder_name"
            debug "  URL: $folder_url"
            debug "  Path: $folder_path"
            debug "  DEBUG: Original folder_name='$folder_name'"
            # Use only the base folder name, not the full path
            base_folder_name=$(basename "$folder_name")
            debug "  DEBUG: base_folder_name='$base_folder_name'"
            download_directory_files "$folder_url" "$DOWNLOAD_DESTINATION" "$base_folder_name"
        done < "$TEMP_DIR/matches"
    fi

    # Summary
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Dry run completed. Found $TOTAL_FILES files that would be downloaded."
    else
        total_skipped=$((MEDIA_SKIPPED_COUNT + POSTER_SKIPPED_COUNT + SUBTITLE_SKIPPED_COUNT))
        if [ "$total_skipped" -gt 0 ]; then
            log "Download completed. Downloaded $DOWNLOADED_FILES out of $TOTAL_FILES_TO_DOWNLOAD files. Skipped $total_skipped files (already exist with same size)."
        else
            log "Download completed. Downloaded $DOWNLOADED_FILES out of $TOTAL_FILES_TO_DOWNLOAD files."
        fi
        log "Files saved to: $DOWNLOAD_DESTINATION"
    fi
}

# Run main function with all arguments
main "$@"
