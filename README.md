# blogger

A terminal tool that generates README prompts or blog post prompts from a GitHub repository, then sends them to OpenAI and saves the resulting Markdown.

## About

`blogger` is a small CLI utility for people who would rather not manually write project writeups.

It supports two workflows:

- **README generation**: clone a GitHub repo, read its source files, and build a structured prompt for generating a `README.md`
- **Blog post generation**: fetch commit history and commit diffs from GitHub, compress the patch data, and build a prompt for generating a technical blog post about how the project was built

After building the prompt, the tool asks OpenAI for a token count, asks for confirmation, submits the request, and writes the generated Markdown to a file.

This project exists solely to automate the annoying part of writing project documentation and project blog posts.

## Features

- Interactive terminal UI
- Generate either:
  - a **README**
  - a **blog post**
- Clones a repository locally for README prompt generation
- Fetches GitHub commit history and commit details for blog post generation
- Filters out common generated/binary/vendor files from prompt input
- Minifies Git patches before sending them to the LLM
- Shows input token count before sending the full request
- Saves output as Markdown
- Writes logs to a temporary log file and reports its location on errors

## Tech Stack

- **Odin**
- GitHub REST API
- OpenAI Responses API
- [`vendor/odin-http`](../vendor/odin-http) for HTTP requests

## Getting Started

### Prerequisites

You need:

- [Odin](https://odin-lang.org/)
- `git` available in your shell
- a GitHub access token
- an OpenAI API key
- a POSIX-like terminal environment

### Build

From the project root:

```bash
odin build src -out:blogger
```

### Run

```bash
./blogger
```

On first run, the program asks for:

- `Github access token`
- `Open ai API key`

It stores them in:

```text
<user config dir>/blogger/config.txt
```

The config file format is:

```text
github_access_token=...
openai_api_key=...
```

## Usage

When you start the program, it interactively asks for:

1. what to create: `Blogpost` or `Readme`
2. GitHub repo owner
3. GitHub repository name
4. optional author note

### README flow

For `Readme`, the tool:

- creates a temporary directory
- clones `https://github.com/<owner>/<repo>.git`
- recursively reads repository files
- ignores hidden directories and selected file types
- builds a README-writing prompt
- sends the prompt to OpenAI
- saves the generated Markdown

### Blog post flow

For `Blogpost`, the tool:

- fetches repository commits from GitHub
- fetches details for each commit
- extracts file-level changes
- minifies patches into a smaller, line-numbered format
- builds a blog-writing prompt
- sends the prompt to OpenAI
- saves the generated Markdown

### Output

By default, the tool proposes saving output to:

```text
../out/<repo>-readme.md
```

or

```text
../out/<repo>-blogpost.md
```

relative to the executable path.

You can decline that path and enter a custom output path.

## Ignored Files and Directories

The tool intentionally skips some content when building prompts.

### Ignored directories

- `vendor`
- `target`

### Ignored suffixes

- `.lock`
- `.lockb`
- `.sum`
- `.bin`
- `.wasm`
- `.dll`
- `.so`
- `.exe`
- `.ttf`
- `.png`

### Ignored filenames

- `package-lock.json`

## Notes on Behavior

- The OpenAI model is hardcoded in the request builder as `gpt-5.4`
- The program uses raw terminal input for prompts and menu navigation
- Hidden directories are skipped during README repo scanning
- Errors print a structured message and include the path to the saved log file

## Testing

There are tests for `minify_patch`, covering cases like:

- added files
- removed files
- single and multiple hunks
- consecutive changes
- additions and deletions affecting line numbering

Run tests with Odin’s test runner for the `src` package.
