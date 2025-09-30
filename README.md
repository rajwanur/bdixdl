# BDIX Downloader (bdixdl)

![Shell Script](https://img.shields.io/badge/Shell-Script-blue.svg)
![Version](https://img.shields.io/badge/version-1.0.0-green.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)
![POSIX](https://img.shields.io/badge/POSIX--compatible-brightgreen.svg)

A powerful POSIX-compliant shell script for downloading media files from **h5ai** HTTP directory listings with advanced search and filtering capabilities.

## Features

- **Smart Search**: Find folders containing specific keywords in their names
- **Recursive Directory Traversal**: Search nested directories up to configurable depth
- **Multi-format Support**: Download videos, images, and subtitles
  - **Video**: mp4, mkv, avi, wmv, mov, flv, webm, m4v
  - **Images**: jpg, jpeg, png, gif, bmp
  - **Subtitles**: srt, sub, ass, vtt
- **Concurrent Downloads**: Multi-threaded downloading for improved performance
- **Resume Capability**: Resume interrupted downloads seamlessly
- **Dry Run Mode**: Preview what would be downloaded without actual downloading
- **Configurable**: Extensive configuration options via command line or config file
- **Interactive Selection**: Choose which matching folders to download after search

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
   EOF
   ```

## Usage

### Syntax

```bash
./down.sh [OPTIONS] BASE_URL KEYWORDS...
```

###
#### Usage
```bash
# Search for and download folders containing "movie 2023"
./down.sh https://ftp.yourserever.net/media/ "movie 2023"

# Download folders with multiple keywords
./down.sh https://yourserever.com/files/ "documentary nature wildlife"
```

#### Usage
```bash
# Dry run to see what would be downloaded
./down.sh -n https://ftp.yourserever.net/media/ "action movies"

# Custom download destination and search depth
./down.sh -d ~/Downloads -D 3 https://media.yourserever.com/ "tv series"

# Multi-threaded downloading with resume capability
./down.sh -t 5 -r https://cdn.yourserever.com/ "4k movies"

# Quiet mode for automated scripts
./down.sh -q -c ~/.config/bdixdl.conf https://files.yourserever.net/ "backup"
```

### Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `-d, --destination DIR` | Download destination directory | `/mnt/main_pool/data/downloads/test` |
| `-D, --depth NUM` | Maximum search depth | `5` |
| `-t, --threads NUM` | Concurrent download threads | `3` |
| `-n, --dry-run` | Show what would be downloaded without downloading | Disabled |
| `-r, --resume` | Resume interrupted downloads | Disabled |
| `-f, --force-overwrite` | Force overwrite existing files | Disabled |
| `-q, --quiet` | Suppress non-error output | Disabled |
| `-c, --config FILE` | Use custom config file | `$HOME/.config/bdixdl.conf` |
| `-h, --help` | Show help message | - |
| `-v, --version` | Show version information | - |

### File

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
```

## Workflow

1. **Search Phase**: The script recursively searches the h5ai server for folders matching your keywords
2. **Selection Phase**: Interactive selection of which folders to download (skip in dry-run mode)
3. **Download Phase**: Downloads all supported media files from selected folders

## How It Works

### Discovery
- Parses **h5ai** HTML directory listings to find folder structure
- Handles various **h5ai** implementations and URL formats
- Supports both relative and absolute URLs
- Filters out **h5ai** internal paths and navigation links

### Filtering
- Only downloads files with supported extensions
- Skips existing files with matching sizes (unless force overwrite is enabled)
- Validates file extensions before download attempts

### Management
- Supports concurrent downloads with configurable thread count
- Implements resume functionality for interrupted transfers
- Provides detailed progress logging and error reporting
- Creates local directory structure matching remote organization

## Troubleshooting

### Issues

**No folders found matching keywords**
- Check if the BASE_URL is accessible in a web browser
- Verify the **h5ai** directory listing is working
- Try broader keywords or reduce search depth

**Download failures**
- Ensure you have write permissions in the destination directory
- Check network connectivity to the target server
- Verify the server supports HTTP range requests for resume functionality

**Permission denied errors**
- Make sure the script is executable: `chmod +x down.sh`
- Check write permissions in the download directory
- Verify you have network access to the target server

### Mode

For detailed debugging information, run without quiet mode:
```bash
./down.sh https://example.com/media/ "keywords"
```

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

### Guidelines

1. **POSIX Compliance**: Maintain compatibility across Unix-like systems
2. **Error Handling**: Implement robust error handling for all operations
3. **Testing**: Test thoroughly across different h5ai server configurations
4. **Documentation**: Update documentation for new features or changes

### Changes

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

## Support

If you encounter any issues or have questions:

1. Check the [Troubleshooting](#-troubleshooting) section
2. Search existing [Issues](https://github.com/rajwanur/bdixdl/issues)
3. Create a new issue with detailed information about your problem

## Version History

### 1.0.0
- Initial release
- Complete rewrite with improved h5ai compatibility
- Added support for multiple h5ai implementations
- Enhanced error handling and logging
- Improved URL normalization and path handling
- Added interactive folder selection
- Better support for different server configurations

---

**Made with ❤️ for the BDIX community**
