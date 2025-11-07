# WHEN TO USE THIS TOOL

- Use when you need to read the contents of a specific file.
- Helpful for examining source code, configuration files, or log files.
- Perfect for looking at text-based file formats.

# HOW TO USE

- Provide the `file_path` (relative to the current working directory).
- Optionally specify `start_line` to begin reading from a specific line (default: 1).
- Optionally specify `end_line` to stop reading (default: end of file).

# FEATURES

- Displays file contents with line numbers for easy reference.
- Reads from any specified line range in a file.
- Detects file extension for appropriate display formatting.
- Includes LSP diagnostics appended to the output.
- Swap-safe: never opens files as buffers just to read. If the file is already loaded in this Neovim, it reads from that buffer (including unsaved edits). Otherwise, it reads from disk directly (no swap prompt).

# LIMITATIONS

- Cannot open files that do not exist or are inaccessible.
- Only reads text files; binary files or images cannot be displayed.

- Use when you need to read the contents of a specific file.
- Helpful for examining source code, configuration files, or log files.
- Perfect for looking at text-based file formats.

# HOW TO USE

- Provide the absolute path to the file you want to read.
- Optionally specify an offset to start reading from a specific line.
- Optionally specify a limit to control how many lines are read.

# FEATURES

- Displays file contents with line numbers for easy reference.
- Can read from any position in a file using the offset parameter.
- Handles large files by limiting the number of lines read.

# LIMITATIONS

- Maximum file size is 250KB.
- Default reading limit is 2000 lines.
- Cannot display binary files or images.
- Images can be identified but not displayed.
