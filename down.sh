#!/bin/sh

# bdixdl - POSIX-compliant H5AI media downloader
# Downloads media files from h5ai HTTP directory listings with advanced features

VERSION="2.0.0"
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
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
# Use a more portable temporary directory location
TEMP_DIR="${TMPDIR:-/tmp}/${SCRIPT_NAME}_$$"
MATCHING_FOLDERS=""
TOTAL_FILES=0
DOWNLOADED_FILES=0

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

EXAMPLES:
    $SCRIPT_NAME https://ftp.isp.net/media/ "movie 2023"
    $SCRIPT_NAME -n -t 5 https://server.com/files/ "documentary nature"
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
        esac
    done < "$CONFIG_FILE"
}

# Simple URL decoder for common percent-encoding
url_decode() {
    printf '%s' "$1" | sed 's/+/ /g; s/%20/ /g; s/%21/!/g; s/%22/"/g; s/%23/#/g; s/%24/$/g; s/%25/%/g; s/%26/\&/g; s/%27/'"'"'/g; s/%28/(/g; s/%29/)/g; s/%2A/*/g; s/%2B/+/g; s/%2C/,/g; s/%2D/-/g; s/%2E/./g; s/%2F/\//g; s/%5B/[/g; s/%5D/]/g; s/%C2%BD/½/g'
}

# Get href paths from HTML, excluding navigation links
get_href_paths() {
    url="$1"
    log "  Fetching URL: $url"
    
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
    
    # More flexible pattern matching for different h5ai implementations
    # First try the standard h5ai pattern
    cat "$html_content" | \
    tr -d '\n' | \
    grep -Eo '<li[^>]*class="[^"]*folder[^"]*"[^>]*>.*?<a[^>]*href="[^"]*"' | \
    grep -o 'href="[^"]*"' | \
    sed 's/href="//;s/"//' | \
    grep -v '^[.]\{1,2\}/' | \
    grep -v '^#' | \
    grep -v '^[?]' | \
    grep -v '\[[0-9:]\+\]' | \
    sed 's|/$||' | \
    sort -u > "$TEMP_DIR/links_$$.txt"
    
    # Debug output for first method
    link_count=$(wc -l < "$TEMP_DIR/links_$$.txt")
    log "  Standard pattern found $link_count links"
    
    # If no results, try a more general approach to find all links
    if [ ! -s "$TEMP_DIR/links_$$.txt" ]; then
        log "  Trying alternative HTML parsing method"
        cat "$html_content" | \
        tr -d '\n' | \
        grep -o '<a[^>]*href="[^"]*"[^>]*>' | \
        grep -o 'href="[^"]*"' | \
        sed 's/href="//;s/"//' | \
        grep -v '^[.]\{1,2\}/' | \
        grep -v '^#' | \
        grep -v '^[?]' | \
        grep -v '\[[0-9:]\+\]' | \
        grep -E '/$|[^.]+$|\.[^/.]+/$' | \
        sed 's|/$||' | \
        sort -u > "$TEMP_DIR/links_$$.txt"
        
        # Debug output for alternative method
        link_count=$(wc -l < "$TEMP_DIR/links_$$.txt")
        log "  Alternative pattern found $link_count links"
    fi
    
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

    log "Searching: $current_display_path (depth: $current_depth)"
    log "  URL: $current_url"

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
        log "  No links found in directory"
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

# Download a single file with progress
download_file() {
    file_url="$1"
    local_path="$2"
    filename="$3"

    local_dir=$(dirname "$local_path")
    mkdir -p "$local_dir" || return 1

    if [ "$QUIET" -eq 0 ]; then
        printf "  Downloading: %s\n" "$filename"
        printf "  URL: %s\n" "$file_url"
        printf "  Local path: %s\n" "$local_path"
    fi

    # Use curl instead of wget for better error handling
    curl_opts="--silent --location --retry 3 --connect-timeout 30 --max-time 300"
    [ "$RESUME" -eq 1 ] && curl_opts="$curl_opts --continue-at -"

    if curl $curl_opts -o "$local_path" "$file_url"; then
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

# Download files from a directory
download_directory_files() {
    remote_url="$1"
    local_base="$2"
    folder_name="$3"

    log "Processing: $folder_name"
    log "  Fetching directory listing from: $remote_url"

    href_paths=$(get_href_paths "$remote_url")
    if [ -z "$href_paths" ]; then
        log "  No files found in directory"
        return 0
    fi

    # Debug: show what we found
    log "  Found $(printf '%s\n' "$href_paths" | wc -l) items in directory"

    # Create local directory using just the folder basename
    folder_basename=$(basename "$folder_name")
    local_dir="$local_base/$folder_basename"
    mkdir -p "$local_dir"
    log "  Created local directory: $local_dir"

    # Get base domain for absolute paths
    base_domain=$(echo "$BASE_URL" | sed 's|^\(https\?://[^/]*\).*|\1|')

    # Process files
    temp_file="$TEMP_DIR/download_$$"
    found_files=0

    printf '%s\n' "$href_paths" | while IFS= read -r link_path; do
        [ -z "$link_path" ] && continue

        decoded_path=$(url_decode "$link_path")

        # Skip directories
        case "$decoded_path" in
            */) continue ;;
        esac

        # Skip external URLs that don't match our domain
        case "$link_path" in
            http://*|https://*)
                if ! echo "$link_path" | grep -q "^$base_domain"; then
                    continue
                fi
                ;;
        esac

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
        log "  Found $file_count files to download"
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

    # Process selected folders
    log "Processing selected folders..."
    while IFS='|' read -r folder_url folder_path folder_name || [ -n "$folder_url" ]; do
        log "Processing folder: $folder_name"
        log "  URL: $folder_url"
        log "  Path: $folder_path"
        download_directory_files "$folder_url" "$DOWNLOAD_DESTINATION" "$folder_name"
    done < "$TEMP_DIR/matches"

    # Summary
    if [ "$DRY_RUN" -eq 1 ]; then
        log "Dry run completed. Found $TOTAL_FILES files that would be downloaded."
    else
        log "Download completed. Downloaded $DOWNLOADED_FILES out of $TOTAL_FILES files."
        log "Files saved to: $DOWNLOAD_DESTINATION"
    fi
}

# Run main function with all arguments
main "$@"
