#!/bin/sh

# bdixdl - POSIX-compliant H5AI media downloader
# Downloads media files from h5ai HTTP directory listings with advanced features

VERSION="1.0.0"
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
RESUME=0
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
DOWNLOAD_QUEUE_FILE=""
CURRENT_FILE_NUMBER=0
TOTAL_FILES_TO_DOWNLOAD=0
START_TIME=0
DOWNLOADED_BYTES=0
SHOW_PROGRESS=1  # 1=show detailed progress, 0=simple progress

# --- Utility Functions ---

log() {
    [ "$QUIET" -eq 0 ] && printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$*"
}

error() {
    printf "[ERROR] %s\n" "$*" >&2
}

die() {
    error "$*"
    cleanup
    exit 1
}

cleanup() {
    [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
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
    -r, --resume           Resume interrupted downloads
    -f, --force-overwrite  Force overwrite existing files (skip if same size by default)
    -q, --quiet            Suppress non-error output
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

EXAMPLES:
    $SCRIPT_NAME https://ftp.yourserever.net/media/ "movie 2023"
    $SCRIPT_NAME -n -t 5 https://yourserever.com/files/ "documentary nature"
    $SCRIPT_NAME --dry-run --depth 3 http://192.168.1.1/media/ "series season"

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
            SHOW_PROGRESS) SHOW_PROGRESS="$value" ;;
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
    log "  Received HTML content: $content_size bytes"

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
    log "  Found $link_count total links"

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
    [ "$QUIET" -eq 0 ] && printf "      Extension check: '%s' -> '%s'\n" "$filename" "$ext"

    all_extensions="$MEDIA_EXTENSIONS $POSTER_EXTENSIONS $SUBTITLE_EXTENSIONS"
    for supported_ext in $all_extensions; do
        if [ "$ext" = "$supported_ext" ]; then
            [ "$QUIET" -eq 0 ] && printf "      MATCH: Extension '%s' is supported\n" "$ext"
            return 0
        fi
    done

    [ "$QUIET" -eq 0 ] && printf "      SKIP: Extension '%s' not supported\n" "$ext"
    return 1
}

# Debug function to show URL filtering
debug_url_filter() {
    [ "$QUIET" -eq 0 ] && printf "URL FILTER: %s -> %s\n" "$1" "$2"
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
                log "    Skipping h5ai internal path: $link_path"
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
                    log "    Skipping already processed URL: $full_folder_url"
                    continue
                fi

                display_path="${full_folder_url#$BASE_URL}"

                log "    Found directory: $folder_name"

                if matches_keywords "$folder_name"; then
                    log "  -> MATCH: $folder_name"
                    printf '%s|%s|%s\n' "$full_folder_url" "$display_path" "$folder_name" >> "$TEMP_DIR/matches"
                fi
                find_matching_folders "$full_folder_url" $((current_depth + 1)) "$display_path"
            else
                log "    Skipping external URL: $link_path"
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
            log "    Skipping already processed URL: $full_folder_url"
            continue
        fi

        # Create display path
        display_path="$current_display_path/$folder_name"

        log "    Found directory: $folder_name"
        log "    Full URL: $full_folder_url"

        # Check if folder matches keywords
        if matches_keywords "$folder_name"; then
            log "  -> MATCH: $folder_name"
            log "  DEBUG: Storing in matches - folder_name='$folder_name', display_path='$display_path'"
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
                log "    Skipping h5ai file: $decoded_path"
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
    size=$(curl --silent --head --location --max-redirs 3 --connect-timeout 10 --max-time 30 "$file_url" 2>/dev/null | \
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

    DOWNLOAD_QUEUE_FILE="$TEMP_DIR/download_queue_$$.txt"

    # Initialize processed URLs tracking file to prevent duplicate processing
    > "$TEMP_DIR/processed_urls"

    # Process each selected folder
    while IFS='|' read -r folder_url folder_path folder_name || [ -n "$folder_url" ]; do
        log "  Scanning folder: $folder_name"
        scan_directory_files "$folder_url" "$DOWNLOAD_DESTINATION" "$folder_name"
    done < "$TEMP_DIR/matches"

    # Calculate total files to download
    TOTAL_FILES_TO_DOWNLOAD=$((MEDIA_FILES_COUNT + POSTER_FILES_COUNT + SUBTITLE_FILES_COUNT))

    log "Scan completed. Found $TOTAL_FILES_TO_DOWNLOAD files to download."
}

# Scan files in a directory recursively
scan_directory_files() {
    remote_url="$1"
    local_base="$2"
    folder_name="$3"

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

    # Process files and subdirectories
    temp_dirs="$TEMP_DIR/scan_dirs_$$_$(date +%s)"

    # Create a temporary file to store file processing results
    temp_files="$TEMP_DIR/files_$$_$(date +%s)"

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
                continue
            fi

            # Build subdirectory URL
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

            # Skip if subdirectory URL is the same as current URL
            if [ "$subdir_url" = "$remote_url" ] || [ "${subdir_url%/}" = "${remote_url%/}" ]; then
                continue
            fi

            # Skip if subdirectory has the same name as current directory
            if [ "$subdir_name" = "$folder_name_decoded" ] || [ "$subdir_name" = "$folder_name" ]; then
                continue
            fi

            printf "%s|%s|%s\n" "$subdir_url" "$local_base" "$subdir_name" >> "$temp_dirs"
            continue
        fi

        # Process files
        if is_supported_extension "$decoded_path"; then
            filename=$(basename "$decoded_path")

            # Build file URL
            case "$link_path" in
                http://*|https://*)
                    file_url="$link_path"
                    ;;
                /*)
                    file_url="$base_domain$link_path"
                    ;;
                *)
                    file_url="${remote_url%/}/$link_path"
                    ;;
            esac

            local_path="$local_dir/$filename"

            # Get file type
            file_type=$(get_file_type "$filename")

            # Get remote file size
            remote_size=$(get_remote_file_size "$file_url")

            # Debug: show the local path being checked
            [ "$QUIET" -eq 0 ] && log "      Checking local path: $local_path"

            # Check if local file exists
            will_skip=0
            if [ -f "$local_path" ] && [ "$FORCE_OVERWRITE" -eq 0 ]; then
                local_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')
                [ "$QUIET" -eq 0 ] && log "      File exists locally, size: $local_size bytes"
                if [ "$remote_size" -gt 0 ] && [ "$local_size" -eq "$remote_size" ]; then
                    [ "$QUIET" -eq 0 ] && log "      File sizes match, will skip"
                    will_skip=1
                else
                    [ "$QUIET" -eq 0 ] && log "      File sizes differ, will download"
                fi
            else
                # Debug: show that file doesn't exist locally
                [ "$QUIET" -eq 0 ] && log "      File does not exist locally: $local_path"
            fi

            # Output file processing result to temp file instead of updating counters directly
            printf "FILE|%s|%s|%d|%s|%s|%s\n" "$file_type" "$will_skip" "$remote_size" "$file_url" "$local_path" "$filename" >> "$temp_files"
        fi
    done

    # Process the file results and update counters
    if [ -f "$temp_files" ]; then
        while IFS='|' read -r record_type file_type will_skip remote_size file_url local_path filename || [ -n "$record_type" ]; do
            [ "$record_type" != "FILE" ] && continue

            # Update counters based on file type and skip status
            case "$file_type" in
                "media")
                    if [ "$will_skip" -eq 1 ]; then
                        MEDIA_SKIPPED_COUNT=$((MEDIA_SKIPPED_COUNT + 1))
                    else
                        MEDIA_FILES_COUNT=$((MEDIA_FILES_COUNT + 1))
                        MEDIA_TOTAL_SIZE=$((MEDIA_TOTAL_SIZE + remote_size))
                        # Add to download queue if not skipping
                        printf "DOWNLOAD|%s|%s|%s|%s|%d\n" "$file_url" "$local_path" "$filename" "$file_type" "$remote_size" >> "$DOWNLOAD_QUEUE_FILE"
                    fi
                    ;;
                "poster")
                    if [ "$will_skip" -eq 1 ]; then
                        POSTER_SKIPPED_COUNT=$((POSTER_SKIPPED_COUNT + 1))
                    else
                        POSTER_FILES_COUNT=$((POSTER_FILES_COUNT + 1))
                        POSTER_TOTAL_SIZE=$((POSTER_TOTAL_SIZE + remote_size))
                        # Add to download queue if not skipping
                        printf "DOWNLOAD|%s|%s|%s|%s|%d\n" "$file_url" "$local_path" "$filename" "$file_type" "$remote_size" >> "$DOWNLOAD_QUEUE_FILE"
                    fi
                    ;;
                "subtitle")
                    if [ "$will_skip" -eq 1 ]; then
                        SUBTITLE_SKIPPED_COUNT=$((SUBTITLE_SKIPPED_COUNT + 1))
                    else
                        SUBTITLE_FILES_COUNT=$((SUBTITLE_FILES_COUNT + 1))
                        SUBTITLE_TOTAL_SIZE=$((SUBTITLE_TOTAL_SIZE + remote_size))
                        # Add to download queue if not skipping
                        printf "DOWNLOAD|%s|%s|%s|%s|%d\n" "$file_url" "$local_path" "$filename" "$file_type" "$remote_size" >> "$DOWNLOAD_QUEUE_FILE"
                    fi
                    ;;
            esac
        done < "$temp_files"
        rm -f "$temp_files"
    fi

    # Process subdirectories recursively - FIX: Use unique temp file for each level
    if [ -f "$temp_dirs" ]; then
        # Create a unique temp file for this level to avoid duplicate processing
        level_dirs="$TEMP_DIR/level_dirs_$$_$(date +%N)"
        cp "$temp_dirs" "$level_dirs"
        rm -f "$temp_dirs"

        while IFS='|' read -r subdir_url subdir_local_base subdir_name || [ -n "$subdir_url" ]; do
            [ -z "$subdir_url" ] && continue
            # Check if we've already processed this URL to avoid duplicates
            if ! grep -q "^$subdir_url|" "$TEMP_DIR/processed_urls" 2>/dev/null; then
                echo "$subdir_url|$subdir_local_base|$subdir_name" >> "$TEMP_DIR/processed_urls"
                scan_directory_files "$subdir_url" "$subdir_local_base" "$subdir_name"
            fi
        done < "$level_dirs"
        rm -f "$level_dirs"
    fi
}

# Show download summary
show_download_summary() {
    printf "\n"
    printf "========================================\n"
    printf "      DOWNLOAD SUMMARY\n"
    printf "========================================\n"

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
    printf "[%s] Progress: %d/%d (%d%%) | %s (%s) | Speed: %s | ETA: %s" \
           "$(date '+%H:%M:%S')" \
           "$CURRENT_FILE_NUMBER" \
           "$TOTAL_FILES_TO_DOWNLOAD" \
           "$percentage" \
           "$current_file" \
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
    printf "[%s] Download completed! | Downloaded: %d files | Total size: %s\n" \
           "$(date '+%H:%M:%S')" \
           "$DOWNLOADED_FILES" \
           "$(format_bytes "$DOWNLOADED_BYTES")"
}

# Download a single file with progress
download_file() {
    file_url="$1"
    local_path="$2"
    filename="$3"
    file_size="$4"
    file_type="$5"

    local_dir=$(dirname "$local_path")
    mkdir -p "$local_dir" || return 1

    # Check if file exists and we should verify size
    if [ -f "$local_path" ] && [ "$FORCE_OVERWRITE" -eq 0 ]; then
        # Get local file size
        local_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')

        # Get remote file size
        remote_size=$(get_remote_file_size "$file_url")

        if [ "$remote_size" -gt 0 ] && [ "$local_size" -eq "$remote_size" ]; then
            # File exists and sizes match - skip download
            log "  Skipping: $filename (already exists, same size: $local_size bytes)"
            SKIPPED_FILES=$((SKIPPED_FILES + 1))
            return 0
        elif [ "$remote_size" -gt 0 ] && [ "$local_size" -ne "$remote_size" ]; then
            # File exists but sizes differ - download will overwrite
            log "  Replacing: $filename (exists but size differs: local $local_size vs remote $remote_size bytes)"
        else
            # Could not determine remote size - proceed with download
            log "  Redownloading: $filename (exists but remote size unknown)"
        fi
    elif [ -f "$local_path" ] && [ "$FORCE_OVERWRITE" -eq 1 ]; then
        # File exists but force overwrite is enabled
        log "  Overwriting: $filename (force overwrite enabled)"
    fi

    # Show progress for this file
    CURRENT_FILE_NUMBER=$((CURRENT_FILE_NUMBER + 1))
    show_download_progress "$filename" "$file_size" "$file_type"

    if [ "$QUIET" -eq 0 ]; then
        printf "  Downloading: %s\n" "$filename"
        printf "  URL: %s\n" "$file_url"
        printf "  Local path: %s\n" "$local_path"
    fi

    curl_opts="--silent --location --retry 3 --connect-timeout 30 --max-time 300"
    [ "$RESUME" -eq 1 ] && curl_opts="$curl_opts --continue-at -"

    if curl $curl_opts -o "$local_path" "$file_url"; then
        # Update downloaded bytes counter
        if [ "$file_size" -gt 0 ]; then
            DOWNLOADED_BYTES=$((DOWNLOADED_BYTES + file_size))
        else
            # If we don't know the size, get it from the downloaded file
            downloaded_size=$(wc -c < "$local_path" 2>/dev/null || printf '0')
            DOWNLOADED_BYTES=$((DOWNLOADED_BYTES + downloaded_size))
        fi

        DOWNLOADED_FILES=$((DOWNLOADED_FILES + 1))
        return 0
    else
        error "Failed to download: $filename"
        error "URL: $file_url"

        # Try to get HTTP status code for better error reporting
        http_code=$(curl --silent --location --head --write-out "%{http_code}" --output /dev/null "$file_url" 2>/dev/null || echo "Unknown")
        error "HTTP Status: $http_code"

        return 1
    fi
}

# Download files from a directory recursively
download_directory_files() {
    remote_url="$1"
    local_base="$2"
    folder_name="$3"

    log "Processing: $folder_name"
    log "  DEBUG: Received folder_name='$folder_name'"
    log "  DEBUG: Received local_base='$local_base'"
    log "  Fetching directory listing from: $remote_url"

    href_paths=$(get_href_paths "$remote_url")
    if [ -z "$href_paths" ]; then
        log "  No files found in directory"
        return 0
    fi

    # Debug: show what we found
    log "  Found $(printf '%s\n' "$href_paths" | wc -l) items in directory"

    # Decode folder name for local directory creation
    folder_name_decoded=$(url_decode "$folder_name")

    # Create local directory - use the folder name directly without accumulating paths
    local_dir="$local_base/$folder_name_decoded"
    mkdir -p "$local_dir"
    log "  Created local directory: $local_dir"

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
                log "    Skipping empty subdirectory name"
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
                log "    Skipping self-referencing directory: $subdir_name"
                continue
            fi

            # Skip if subdirectory has the same name as current directory (additional safety check)
            # Compare decoded names to handle URL encoding differences
            if [ "$subdir_name" = "$folder_name_decoded" ] || [ "$subdir_name" = "$folder_name" ]; then
                log "    Skipping subdirectory with same name as parent: $subdir_name"
                continue
            fi

            log "    Found subdirectory: $subdir_name"
            log "    Subdirectory URL: $subdir_url"
            log "    DEBUG: Storing subdirectory name: '$subdir_name'"
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
                printf "  Found file to download: %s\n" "$filename"
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

            log "  Recursing into subdirectory: $subdir_name"
            log "  DEBUG: About to call download_directory_files with folder_name='$subdir_name'"
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
                RESUME=1
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

    # Validate required arguments
    [ -z "$BASE_URL" ] && die "BASE_URL is required. Use -h for help."
    [ -z "$SEARCH_KEYWORDS" ] && die "SEARCH_KEYWORDS are required. Use -h for help."

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
    # Set up signal handlers
    trap cleanup EXIT INT TERM

    # Check dependencies and load config
    check_dependencies
    load_config

    # Parse arguments (this may override config values)
    parse_arguments "$@"

    # Create temporary directory
    mkdir -p "$TEMP_DIR" || die "Cannot create temporary directory"

    log "$SCRIPT_NAME v$VERSION starting..."
    [ "$DRY_RUN" -eq 1 ] && log "DRY RUN MODE - No files will be downloaded"

    log "Base URL: $BASE_URL"
    log "Keywords: $SEARCH_KEYWORDS"
    log "Destination: $DOWNLOAD_DESTINATION"
    log "Max depth: $MAX_SEARCH_DEPTH"
    log "Threads: $MAX_THREADS"

    # Find matching folders
    log "Searching for matching folders..."
    find_matching_folders "$BASE_URL" 0 ""

    # Debug: show all matches found
    if [ -f "$TEMP_DIR/matches" ]; then
        log "DEBUG: All matches found:"
        while IFS='|' read -r url path name; do
            log "  URL: $url"
            log "  Path: $path"
            log "  Name: $name"
        done < "$TEMP_DIR/matches"
    fi

    # Check if we found any matches
    if [ ! -f "$TEMP_DIR/matches" ] || [ ! -s "$TEMP_DIR/matches" ]; then
        log "No folders found matching keywords: $SEARCH_KEYWORDS"
        exit 0
    fi

    # Display matches with clean formatting
    log "Found matching folders:"
    count=0
    selected_indices=""
    while IFS='|' read -r folder_url folder_path folder_name || [ -n "$folder_url" ]; do
        count=$((count + 1))
        printf "  %d. %s\n" "$count" "$folder_name"
        log "     URL: $folder_url"
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

        # Process download queue
        while IFS='|' read -r action file_url local_path filename file_type file_size || [ -n "$action" ]; do
            [ "$action" != "DOWNLOAD" ] && continue

            # Create directory if needed
            local_dir=$(dirname "$local_path")
            mkdir -p "$local_dir"

            # Debug output to verify parameters
            log "DEBUG: Processing download - URL: $file_url, Local: $local_path, Filename: $filename, Type: $file_type, Size: $file_size"

            # Download file with progress tracking
            download_file "$file_url" "$local_path" "$filename" "$file_size" "$file_type"
        done < "$DOWNLOAD_QUEUE_FILE"

        # Show final progress
        complete_download_progress
    elif [ "$DRY_RUN" -eq 1 ]; then
        # Original behavior for dry run
        log "Processing selected folders..."
        while IFS='|' read -r folder_url folder_path folder_name || [ -n "$folder_url" ]; do
            log "Processing folder: $folder_name"
            log "  URL: $folder_url"
            log "  Path: $folder_path"
            log "  DEBUG: Original folder_name='$folder_name'"
            # Use only the base folder name, not the full path
            base_folder_name=$(basename "$folder_name")
            log "  DEBUG: base_folder_name='$base_folder_name'"
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
