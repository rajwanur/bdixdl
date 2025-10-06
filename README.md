# BDIX Downloader (bdixdl)

![Shell Script](https://img.shields.io/badge/Shell-Script-blue.svg)
![Version](https://img.shields.io/badge/version-1.1.0-green.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)
![POSIX](https://img.shields.io/badge/POSIX--compatible-brightgreen.svg)

A powerful POSIX-compliant shell script for downloading media files from **h5ai** HTTP directory listings with advanced search, filtering, resume capabilities, and comprehensive progress tracking.

## Features

### Core Functionality
- **Smart Search**: Find folders containing specific keywords in their names
- **Recursive Directory Traversal**: Search nested directories up to configurable depth
- **Multi-format Support**: Download videos, images, and subtitles
  - **Video**: mp4, mkv, avi, wmv, mov, flv, webm, m4v
  - **Images**: jpg, jpeg, png, gif, bmp
  - **Subtitles**: srt, sub, ass, vtt
- **Concurrent Downloads**: Multi-threaded downloading for improved performance
- **Enhanced Resume Capability**: Intelligent resume with partial download detection
- **Advanced File Filtering**: Exclude files by size, extension, keywords, or regex patterns
- **Dry Run Mode**: Preview what would be downloaded without actual downloading
- **Configurable**: Extensive configuration options via command line or config file
- **Interactive Selection**: Choose which matching folders to download after search
- **Pre-scan Analysis**: Comprehensive analysis of all files before downloading
- **Detailed Download Summary**: Shows file counts, sizes, and estimated download time by type
- **Real-time Progress Tracking**: Live progress display with speed, ETA, and visual progress bar
- **Smart File Management**: Automatically skips existing files with matching sizes
- **User Confirmation**: Interactive confirmation before starting downloads
- **File Type Categorization**: Separate tracking and reporting for media, images, and subtitles
- **Progress Configuration**: Configurable progress display (can be disabled for cleaner output)

### 🆕 Enhanced Resume Functionality
- **Intelligent Partial Detection**: Automatically detects partially downloaded files
- **Byte-Accurate Resume**: Resumes from exact byte position where download stopped
- **Progress Preservation**: Shows resume progress with percentage completion
- **Bandwidth Efficient**: Only downloads missing portions, not entire files
- **Error Recovery**: Handles network interruptions and server issues gracefully
- **Verification System**: Verifies download completion and file integrity

### 🆕 Advanced Filtering System
- **Size-Based Filtering**: Exclude files by minimum/maximum size (supports K, M, G, T units)
- **Extension Filtering**: Exclude specific file extensions (comma-separated)
- **Keyword Filtering**: Exclude files containing specific keywords in filename
- **Regex Pattern Filtering**: Advanced pattern matching for complex exclusion rules
- **Multiple Filter Combinations**: Combine different filter types for precise control
- **Detailed Reporting**: Shows filtered files and active filters in summary

### 🆕 Enhanced Interruption Handling
- **Graceful Ctrl+C Handling**: Immediate response to user interruption with proper cleanup
- **Download State Tracking**: Real-time tracking of current download and directory context
- **Progress Preservation**: Saves complete session state for easy resumption
- **Clean Shutdown**: Proper termination of background processes and temporary files
- **Comprehensive Summary**: Detailed interruption report with progress statistics
- **Smart Resume Integration**: Seamless integration with existing resume functionality
- **User-Friendly Messages**: Colored output and clear instructions for resuming

## Prerequisites

The script requires the following common command-line tools:

```bash
curl wget grep sed mkdir rm
```

These are typically available on most Unix-like systems (Linux, macOS, BSD, etc.).

## Installation

1. **Clone the repository**:
   ```bash
   git clone https://github.com/rajwanur/bdixdl.git
   cd bdixdl
   ```

2. **Make the script executable**:
   ```bash
   chmod +x down.sh
   ```

3. **Optional**: Create a configuration file:
   ```bash
   mkdir -p ~/.config
   cat > ~/.config/bdixdl.conf << EOF
   DOWNLOAD_DESTINATION=/path/to/your/downloads
   MAX_SEARCH_DEPTH=5
   MAX_THREADS=3
   RESUME=1
   QUIET=0
   SHOW_PROGRESS=1
   # Filtering options
   MIN_FILE_SIZE=104857600     # 100MB minimum
   MAX_FILE_SIZE=21474836480    # 20GB maximum
   EXCLUDE_EXTENSIONS=avi,wmv,flv
   EXCLUDE_KEYWORDS=sample,trailer,bonus
   EOF
   ```

## Usage

### Syntax

```bash
./down.sh [OPTIONS] BASE_URL KEYWORDS...
```

### Basic Usage

```bash
# Search for and download folders containing "movie 2023"
./down.sh https://ftp.yourserever.net/media/ "movie 2023"

# Download folders with multiple keywords
./down.sh https://yourserever.com/files/ "documentary nature wildlife"
```

### Advanced Usage

```bash
# Enhanced resume with progress tracking
./down.sh -r --debug https://media.yourserever.com/ "4k movies"

# Size-based filtering - exclude files larger than 2GB
./down.sh --max-size 2G https://yourserever.com/media/ "movies"

# Multiple filters - exclude small files and specific extensions
./down.sh --min-size 100M --exclude-ext avi,wmv,flv https://yourserever.com/media/ "videos"

# Keyword filtering - exclude samples and trailers
./down.sh --exclude-keywords "sample,trailer,bonus" https://yourserever.com/media/ "movies"

# Advanced regex filtering
./down.sh --exclude-regex ".*[Ss]ample.*|.*[Tt]railer.*" https://yourserever.com/media/ "videos"

# Dry run to see what would be downloaded (including filtered files)
./down.sh -n --max-size 1G --exclude-ext avi https://ftp.yourserever.net/media/ "action movies"

# Custom download destination and search depth
./down.sh -d ~/Downloads -D 3 https://media.yourserever.com/ "tv series"

# Multi-threaded downloading with resume and filtering
./down.sh -t 5 -r --max-size 5G --exclude-keywords "sample,trailer" https://cdn.yourserever.com/ "4k movies"

# Quiet mode for automated scripts with custom config
./down.sh -q -c ~/.config/bdixdl.conf https://files.yourserever.net/ "backup"

# Graceful interruption and resume workflow
./down.sh -r -t 5 https://media.yourserever.com/ "4k movies"
# Press Ctrl+C during download to gracefully stop
# Resume the interrupted session:
./down.sh --resume
```

## Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `-d, --destination DIR` | Download destination directory | `/mnt/main_pool/data/downloads/test` |
| `-D, --depth NUM` | Maximum search depth | `5` |
| `-t, --threads NUM` | Concurrent download threads | `3` |
| `-n, --dry-run` | Show what would be downloaded without downloading | Disabled |
| `-r, --resume` | Resume interrupted downloads (auto-detects partial files) | Disabled |
| `-f, --force-overwrite` | Force overwrite existing files | Disabled |
| `--min-size SIZE` | Exclude files smaller than SIZE (e.g., 100M, 2G, 500K) | No limit |
| `--max-size SIZE` | Exclude files larger than SIZE (e.g., 10G, 500M, 1T) | No limit |
| `--exclude-ext EXTS` | Exclude files with these extensions (comma-separated) | None |
| `--exclude-keywords WORDS` | Exclude files containing these keywords (comma-separated) | None |
| `--exclude-regex PATTERN` | Exclude files matching this regex pattern | None |
| `--debug` | Show debug information (verbose logging) | Disabled |
| `-q, --quiet` | Suppress non-error output | Disabled |
| `-c, --config FILE` | Use custom config file | `$HOME/.config/bdixdl.conf` |
| `-h, --help` | Show help message | - |
| `-v, --version` | Show version information | - |

### Size Format Examples

```bash
--min-size 100M     # 100 Megabytes
--max-size 2G       # 2 Gigabytes
--min-size 500K     # 500 Kilobytes
--max-size 1T       # 1 Terabyte
--max-size 1048576  # Exact bytes
```

### Filtering Examples

```bash
# Filter by file size
./down.sh --min-size 50M --max-size 2G https://yourserever.com/media/ "movies"

# Filter by extensions
./down.sh --exclude-ext "avi,wmv,flv,mov" https://yourserever.com/media/ "videos"

# Filter by keywords
./down.sh --exclude-keywords "sample,trailer,bonus,behind-the-scenes" https://yourserever.com/media/ "movies"

# Complex regex filtering
./down.sh --exclude-regex ".*[Ss]ample.*|.*[Tt]railer.*|.*[Bb]onus.*" https://yourserever.com/media/ "videos"

# Combine multiple filters
./down.sh --min-size 100M --max-size 5G --exclude-ext "avi,wmv" --exclude-keywords "sample,trailer" https://yourserever.com/media/ "movies"
```

## Configuration File

Create a configuration file at `~/.config/bdixdl.conf` (or specify custom path with `-c`):

```bash
# Download destination directory
DOWNLOAD_DESTINATION=/home/user/downloads

# Maximum search depth for folder discovery
MAX_SEARCH_DEPTH=5

# Number of concurrent download threads
MAX_THREADS=3

# Enable resume downloads by default
RESUME=1

# Suppress non-error output
QUIET=0

# Show detailed progress display (1=enabled, 0=disabled)
SHOW_PROGRESS=1

# === ADVANCED FILTERING OPTIONS ===

# Size-based filtering (in bytes)
MIN_FILE_SIZE=104857600     # 100MB minimum file size
MAX_FILE_SIZE=21474836480    # 20GB maximum file size

# Extension-based filtering (comma-separated, lowercase)
EXCLUDE_EXTENSIONS=avi,wmv,flv,mov

# Keyword-based filtering (comma-separated, case-insensitive)
EXCLUDE_KEYWORDS=sample,trailer,bonus,behind the scenes

# Regex pattern filtering (advanced)
EXCLUDE_REGEX=.*[Ss]ample.*|.*[Tt]railer.*|.*[Bb]onus.*
```

## Workflow

1. **Search Phase**: The script recursively searches the h5ai server for folders matching your keywords
2. **Selection Phase**: Interactive selection of which folders to download (skip in dry-run mode)
3. **Pre-scan Analysis**: Comprehensive analysis of all files in selected folders
   - Checks existing files and sizes
   - Applies filtering rules to exclude unwanted files
   - Categorizes files by type (media, images, subtitles)
   - Builds download queue with all file information
4. **Summary Display**: Shows detailed download summary including:
   - File counts and sizes by type
   - Files to skip (already exist)
   - 🆕 Files filtered out (excluded by filters)
   - Active filters being applied
   - Total download size and estimated time
5. **User Confirmation**: Interactive confirmation before starting downloads
6. **Download Phase**: Downloads files with real-time progress tracking
   - 🆕 Intelligent resume for partial downloads
   - Shows current file, progress percentage, speed, and ETA
   - Visual progress bar
   - File-by-file progress updates
   - 🆕 Graceful interruption handling with Ctrl+C support
   - 🆕 Session state preservation for easy resumption

## Enhanced Resume Functionality

The script now includes sophisticated resume capabilities that handle interrupted downloads intelligently:

### How Resume Works
1. **Detection**: Automatically detects partial downloads by comparing local vs remote file sizes
2. **Analysis**: Determines if a file is complete, partial, or corrupted
3. **Decision**: Decides whether to skip, resume, or restart based on file state and settings
4. **Execution**: Resumes from exact byte position or restarts as needed
5. **Verification**: Confirms download completion and file integrity

### Resume Behavior
- **Complete Files**: Skipped with message "already exists"
- **Partial Files**: Resume from last byte position (shows percentage complete)
- **Corrupted Files**: Restart download (shows "larger than expected" message)
- **Size Unknown**: Attempts resume if local file exists
- **Force Overwrite**: Always restarts regardless of file state

### Example Resume Output
```
[12:25:55]   ↻ Movie.mkv (resuming at 75% - 2.5GB/3.5GB)
[DEBUG]   RESUME: Partial file found, downloading remaining 1.0GB bytes
[DEBUG]   Resuming from byte position: 2684354560
```

## Filtering System

The comprehensive filtering system allows precise control over which files are downloaded:

### Filter Types

#### Size-Based Filtering
```bash
--min-size 100M    # Exclude files smaller than 100MB
--max-size 5G      # Exclude files larger than 5GB
```

#### Extension Filtering
```bash
--exclude-ext "avi,wmv,flv"    # Exclude these file extensions
--exclude-ext "mov,mp4"        # Exclude these video formats
```

#### Keyword Filtering
```bash
--exclude-keywords "sample,trailer"    # Exclude files with these keywords
--exclude-keywords "bonus,extra"       # Case-insensitive keyword matching
```

#### Regex Pattern Filtering
```bash
--exclude-regex ".*[Ss]ample.*"                    # Files containing "sample" (any case)
--exclude-regex ".*[0-9]{4}.*"                     # Files with 4-digit numbers
--exclude-regex ".*\.(avi|wmv|flv)$"               # Alternative to extension filtering
```

### Filter Priority and Combination
1. All filters are applied **AND** (file must pass ALL filters to be included)
2. Filters are applied during the scan phase before download queue creation
3. Filtered files are excluded from download queue entirely
4. Multiple filters of the same type are combined with **OR** logic

### Filter Reporting
```
Files filtered out (excluded by filters):
  Media files:    15
  Image files:     3
  Subtitle files:  2

Active filters:
  Min size: 100.0 MB
  Max size: 5.0 GB
  Exclude extensions: avi,wmv,flv
  Exclude keywords: sample,trailer
```

## Enhanced Interruption Handling

The script now includes sophisticated interruption handling that provides a smooth user experience when downloads need to be stopped.

### How Interruption Works
1. **Signal Detection**: Instantly detects Ctrl+C (SIGINT) and termination signals (SIGTERM)
2. **Graceful Stop**: Safely stops the current download process without corruption
3. **State Preservation**: Saves complete session state including current progress
4. **Process Cleanup**: Properly terminates background processes and temporary files
5. **Progress Summary**: Shows detailed statistics of what was accomplished
6. **Resume Guidance**: Provides clear instructions for resuming the session

### Interruption Features

#### Real-time Download Monitoring
- Continuous monitoring of download progress during file transfers
- Background process management for interruption detection
- Progress display for large files during interruption
- Safe termination of ongoing downloads without file corruption

#### Session State Management
- Persistent state file storage with complete download context
- Tracking of current download URL, filename, and directory
- Preservation of download statistics and progress counters
- Integration with existing resume functionality

#### User-Friendly Interface
- Colored interruption messages for better visibility
- Clear indication of interruption reason and status
- Detailed summary with files processed, skipped, and downloaded data
- Step-by-step instructions for resuming interrupted sessions

### Example Interruption Output
```
*** Interruption detected (Ctrl+C) ***
Gracefully stopping downloads and saving progress...

=== Download Session Interrupted ===
Reason: SIGINT
Files processed: 5/15
Files skipped: 2
Data downloaded: 2.5 GB
Average speed: 5.2 MB/s
Current download was: Movie4K.mkv
This file can be resumed with --resume flag

To resume this session, run:
  ./down.sh --resume [other-options]

State saved to: /tmp/bdixdl_state_12345
```

### Interruption Behavior
- **Immediate Response**: Ctrl+C is instantly recognized and processed
- **Current File**: Completes current download to a safe state or marks for resume
- **Queue Processing**: Stops processing remaining files in the queue
- **Directory Traversal**: Halts further directory scanning and processing
- **Progress Tracking**: Preserves all progress statistics and counters
- **State File**: Creates persistent state file for seamless resumption

### Resume After Interruption
```bash
# Resume interrupted session with saved state
./down.sh --resume

# Resume with additional options
./down.sh --resume --debug --max-size 10G

# Resume with different destination (if needed)
./down.sh --resume -d ~/new-downloads
```

### Best Practices
- **Single Ctrl+C**: Press Ctrl+C once for graceful interruption
- **Wait for Completion**: Allow the script to finish cleanup and save state
- **Check Summary**: Review the interruption summary for progress details
- **Use Resume**: Leverage the --resume flag to continue efficiently
- **State File**: The state file is automatically cleaned up on successful completion

## How It Works

### Discovery
- Parses **h5ai** HTML directory listings to find folder structure
- Handles various **h5ai** implementations and URL formats
- Supports both relative and absolute URLs
- Filters out **h5ai** internal paths and navigation links

### Pre-scan Analysis
- Recursively scans all selected folders before downloading
- Applies all filtering rules to exclude unwanted files
- Checks for existing files and compares sizes to avoid duplicates
- Categorizes files by type (media, images, subtitles)
- Builds comprehensive download queue with metadata
- Calculates total download size and estimates time

### Smart Filtering
- Only downloads files with supported extensions
- Automatically skips existing files with matching sizes
- Detects incomplete downloads and offers intelligent resume/restart
- Validates file extensions before download attempts
- Applies user-defined filters during scan phase
- Provides detailed file type and filtering statistics

### Enhanced Resume System
- Intelligent detection of partial vs complete downloads
- Byte-accurate resume from exact interruption point
- Progress preservation across script restarts
- Bandwidth-efficient partial downloads
- Verification of download completion and integrity
- Detailed logging of resume decisions and actions

### Progress Tracking
- Real-time progress display with file-by-file updates
- Shows current download speed and remaining time (ETA)
- Visual progress bar with percentage completion
- Separate tracking for each file type category
- Configurable progress display (can be disabled)
- Enhanced logging for debugging and monitoring

### Management
- Supports concurrent downloads with configurable thread count
- Implements intelligent resume functionality for interrupted transfers
- Provides detailed progress logging and error reporting
- Creates local directory structure matching remote organization
- User confirmation before starting downloads
- Comprehensive filtering system for selective downloading

## Troubleshooting

### Common Issues

**No folders found matching keywords**
- Check if the BASE_URL is accessible in a web browser
- Verify the **h5ai** directory listing is working
- Try broader keywords or reduce search depth
- Use `--debug` flag to see detailed search progress

**Download failures**
- Ensure you have write permissions in the destination directory
- Check network connectivity to the target server
- Verify the server supports HTTP range requests for resume functionality
- Try with `--force-overwrite` if files are corrupted

**Resume not working**
- Check if server supports HTTP range requests (try `curl -I <file-url>`)
- Use `--debug` flag to see resume decision process
- Verify local file is actually partial (smaller than remote)
- Some servers may not support resume for certain file types

**Files being filtered unexpectedly**
- Check active filters in the download summary
- Use `--debug` to see which filters are excluding files
- Verify filter syntax (especially regex patterns)
- Check for case sensitivity in keyword filters

**Interruption not working properly**
- Press Ctrl+C only once and wait for graceful shutdown
- Check the interruption summary for state file location
- Verify the state file was created successfully
- Use `--debug` to see detailed interruption process

**Resume after interruption not working**
- Ensure state file exists (location shown in interruption summary)
- Check that you're using the same command-line options
- Verify the download destination hasn't changed
- Use `--debug` to see resume decision process

**State file missing or corrupted**
- State files are automatically cleaned up on successful completion
- If session was completed normally, no resume is needed
- Start a new session if state file is not found
- Check for multiple state files if script was interrupted multiple times

**Permission denied errors**
- Make sure the script is executable: `chmod +x down.sh`
- Check write permissions in the download directory
- Verify you have network access to the target server
- Ensure destination directory exists or can be created
- Check write permissions for state file location (typically /tmp)

### Debug Mode

For detailed debugging information, use the `--debug` flag:
```bash
./down.sh --debug -r https://yourserever.com/media/ "keywords"
```

Debug output shows:
- Search progress and folder discovery
- Filter decisions and excluded files
- Resume analysis and decisions
- File-by-file download progress
- Network error details

### Resume Troubleshooting

**Files restarting instead of resuming:**
- Check debug output for resume decisions
- Verify server supports HTTP range requests
- Ensure local file is smaller than remote file
- Check if `--resume` flag is enabled

**Files not completing after resume:**
- May indicate server timeout or connection issues
- Try with increased timeout or single-threaded downloads
- Check if server has download limits or restrictions
- Use `--force-overwrite` to restart corrupted downloads

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

### Guidelines

1. **POSIX Compliance**: Maintain compatibility across Unix-like systems
2. **Error Handling**: Implement robust error handling for all operations
3. **Testing**: Test thoroughly across different h5ai server configurations
4. **Documentation**: Update documentation for new features or changes
5. **Filter Testing**: Test filtering combinations with various file types and sizes

### Development Workflow

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- **h5ai**: For the excellent HTTP directory indexer that this script works with
- **POSIX Standard**: For providing a consistent shell scripting environment
- **Curl & Wget**: For robust HTTP client functionality
- **BDIX Community**: For inspiration and feedback on features

## Support

If you encounter any issues or have questions:

1. Check the [Troubleshooting](#troubleshooting) section
2. Search existing [Issues](https://github.com/rajwanur/bdixdl/issues)
3. Create a new issue with detailed information including:
   - Exact command used
   - Debug output (`--debug` flag)
   - Server type and configuration
   - Expected vs actual behavior

## Version History

### v1.1.0 (Latest)
- **Enhanced Resume Functionality**: Intelligent partial download detection and byte-accurate resume
- **Advanced Filtering System**: Size, extension, keyword, and regex filtering
- **🆕 Enhanced Interruption Handling**: Graceful Ctrl+C handling with state preservation
- **🆕 Real-time Download Monitoring**: Background process monitoring with progress display
- **🆕 Session State Management**: Persistent state file for seamless resumption
- **🆕 User-Friendly Interface**: Colored interruption messages and comprehensive summaries
- **Improved Debug Logging**: Comprehensive logging for troubleshooting
- **Fixed Duplicate Download Issues**: Resolved files being processed multiple times
- **Enhanced Queue Processing**: Better handling of download queue and file tracking
- **Improved Error Handling**: Better network error detection and recovery
- **Updated Documentation**: Comprehensive documentation for new features

### v1.0.0
- Initial release
- Complete rewrite with improved h5ai compatibility
- Added support for multiple h5ai implementations
- Enhanced error handling and logging
- Improved URL normalization and path handling
- Added interactive folder selection
- Better support for different server configurations

### Enhanced Features (Added in v1.0.0+)
- **Pre-scan Analysis**: Comprehensive file analysis before downloading
- **Detailed Download Summary**: Professional summary with file counts, sizes, and time estimates
- **Real-time Progress Tracking**: Live progress display with speed, ETA, and visual progress bar
- **Smart File Management**: Automatic skipping of existing files with matching sizes
- **User Confirmation**: Interactive confirmation before starting downloads
- **File Type Categorization**: Separate tracking for media, images, and subtitles
- **Progress Configuration**: Configurable progress display (SHOW_PROGRESS option)
- **Enhanced Workflow**: Improved 6-step workflow with pre-scan and confirmation phases
- **Better Error Reporting**: Enhanced HTTP status code reporting and error details
- **Memory Efficiency**: Improved temporary file management for large operations

---

**Made with ❤️ for the BDIX community**
