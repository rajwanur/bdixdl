# BDIX Downloader (bdixdl) Project

## Project Overview

BDIX Downloader (`bdixdl`) is a POSIX-compliant shell script for downloading media files from h5ai HTTP directory listings. It's designed to search for specific folders containing media files and download them from web servers that use the h5ai directory indexer.

The script version is currently 2.0.0 and is implemented as a single shell script (`down.sh`) that follows POSIX standards for maximum compatibility.

## Key Features

- **Media file downloading**: Supports downloading video (mp4, mkv, avi, wmv, mov, flv, webm, m4v), image (jpg, jpeg, png, gif, bmp), and subtitle (srt, sub, ass, vtt) files
- **Keyword-based searching**: Finds folders that match specified keywords in their names
- **Recursive directory traversal**: Searches nested directories up to a specified depth
- **Configurable options**: Supports custom download destination, search depth, and concurrent download threads
- **Dry-run mode**: Preview what would be downloaded without actually downloading
- **Resume capability**: Resumes interrupted downloads
- **Config file support**: Load settings from a configuration file
- **Interactive folder selection**: Select which matching folders to download after the search

## Building and Running

### Running the script
The script is executed directly:
```bash
./down.sh [OPTIONS] BASE_URL KEYWORDS...
```

### Dependencies
The script requires the following common command-line tools:
- `curl` - For downloading files and fetching web content
- `wget` - Alternative download utility
- `grep`, `sed` - Text processing
- `mkdir`, `rm` - File system operations

### Basic Usage Examples
```bash
# Search for and download from folders with "movie 2023" in the name
./down.sh https://ftp.isp.net/media/ "movie 2023"

# Dry run with 5 concurrent threads and max depth of 3
./down.sh -n -t 5 --depth 3 http://192.168.1.1/media/ "series season"

# Use custom download destination
./down.sh -d /home/user/downloads https://server.com/files/ "documentary"
```

### Options
- `-d, --destination DIR`: Set download destination directory (default: `/mnt/main_pool/data/downloads/test`)
- `-D, --depth NUM`: Set maximum search depth (default: 5)
- `-t, --threads NUM`: Set concurrent download threads (default: 3)
- `-n, --dry-run`: Show what would be downloaded without downloading
- `-r, --resume`: Resume interrupted downloads
- `-q, --quiet`: Suppress non-error output
- `-c, --config FILE`: Use custom config file (default: `$HOME/.config/bdixdl.conf`)
- `-h, --help`: Show help message
- `-v, --version`: Show version information

### Configuration File
The script supports a configuration file using KEY=VALUE format:
```bash
DOWNLOAD_DESTINATION=/path/to/downloads
MAX_SEARCH_DEPTH=5
MAX_THREADS=3
RESUME=1
QUIET=0
```

## Architecture and Code Structure

The script is structured as a single POSIX-compliant shell script with:

- **Global configuration variables**: Version, default paths, supported file extensions
- **Utility functions**: Logging, error handling, cleanup, URL decoding
- **Core functionality**: Directory traversal, file discovery, download processing
- **Argument parsing**: Command-line option handling
- **Main execution logic**: Orchestrates the search and download process

The script handles various edge cases including URL normalization, proper path handling, and robust error handling for network operations.

## Development Conventions

- POSIX compliance for maximum portability across Unix-like systems
- Use of temporary directories for intermediate processing
- Proper signal handling for cleanup on script termination
- Comprehensive logging with timestamps
- URL validation and normalization to handle different server configurations
- Support for both absolute and relative URLs in h5ai directory listings

## Project Files

- `down.sh`: The main POSIX-compliant script for the BDIX downloader
- `QWEN.md`: This documentation file
- `.git/`: Git version control directory
- `.qodo/`: Project management directory (likely for task management)