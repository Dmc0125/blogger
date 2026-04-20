#+vet explicit-allocators
package main

import "base:runtime"
import "core:bytes"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"

import http "../vendor/odin-http"
import http_client "../vendor/odin-http/client"

PROGRAM_MEMORY: [100 * mem.Megabyte]byte

GITHUB_API_URL :: "https://api.github.com"
OPEN_AI_API_URL :: "https://api.openai.com"

FILE_TEMPL :: `        %s:
            - status: %s
            - changes +%d/-%d
            - patch: %s
`
COMMIT_TEMPL :: `%s:
    - author: %s
    - message: %s
    - changes: +%d/-%d
    - files:
        %s
`
PROMPT_TEMPL :: `You are a technical blog writer. You will be given technical project data (commit history) and based on that you will write a blog post about building this project.

Patch format explanation:
- Added files show the full file content
- Modified files show only changed lines
- Lines starting with - were removed
- Lines starting with + were added
- L<number>: indicates the line number where the change occurs
- Separate L markers within one file mean changes in different parts of the file

Write the blog post with somewhat following structure (you can modifiy the structure however you want if it fits the blog post more):

## Introduction
- What is this project?
- What problem does it solve?

## Tech Stack
- What languages/frameworks/libraries were used and why?

## The Build Process
- Walk through the development chronologically
- Group related commits into phases (e.g. "Setting up the project", "Core logic", "Polish")
- For each phase, explain what was done and why
- Do not reference the commits directly, like "first commit was...", incorporate it naturally

## Interesting Code
- Pick 2-3 interesting snippets from the patches and explain them
- Use code blocks with the correct language

## Challenges
- What was tricky? (look for commits that revert, refactor, or fix things)

## Final Architecture
- How is the codebase structured?
- How do the pieces fit together?

Write as if you're explaining to a fellow developer over coffee. Don't be overly formal. Don't use phrases like "In conclusion" or "It's worth noting". Don't use filler. Be direct. Use the author's note if it was provided to inform the blog post's narrative. Incorporate them naturally — don't just quote them verbatim. Write the blog in first person, as if you are describing your project.

Do NOT:
- Make up information that isn't in the commit data
- Guess at motivation unless it's obvious from the commits
- Use generic filler like "This was a great learning experience"
- Explain basic programming concepts
- Write an introduction that starts with "In today's world..."
- Use phrases like "it's not x, it's y"`

build_prompt :: proc(
	project_name, commits, authors_note: string,
	allocator: mem.Allocator,
) -> string {
	sb: strings.Builder
	strings.builder_init(&sb, allocator)

	strings.write_string(&sb, PROMPT_TEMPL)
	strings.write_string(&sb, "\nProject name: ")
	strings.write_string(&sb, project_name)
	strings.write_string(&sb, "\n")

	if len(authors_note) > 0 {
		strings.write_string(&sb, "\nAuthor's note: ")
		strings.write_string(&sb, authors_note)
		strings.write_string(&sb, "\n")
	}

	strings.write_string(&sb, "\nCommits:\n")
	strings.write_string(&sb, commits)

	return string(sb.buf[:])
}

create_arena :: proc(backing_allocator: mem.Allocator, size: int) -> (allocator: mem.Allocator) {
	arena := new(mem.Arena, backing_allocator)
	data := make([]byte, len = size, allocator = backing_allocator)
	mem.arena_init(arena, data)
	allocator = mem.arena_allocator(arena)
	return
}

create_github_request :: proc(
	allocator: mem.Allocator,
	access_token: string,
) -> ^http_client.Request {
	req := new(http_client.Request, allocator)
	http_client.request_init(req, .Get, allocator)
	http.headers_set(
		&req.headers,
		"Authorization",
		fmt.aprintf("Bearer %s", access_token, allocator = allocator),
	)
	http.headers_set(&req.headers, "Accept", "application/vnd.github+json")
	http.headers_set(&req.headers, "X-GitHub-Api-Version", "2026-03-10")
	return req
}

create_open_ai_request :: proc(
	allocator: mem.Allocator,
	api_key, prompt: string,
) -> (
	req: ^http_client.Request,
	err: json.Marshal_Error,
) {
	req = new(http_client.Request, allocator)
	http_client.request_init(req, .Post, allocator)
	http.headers_set(&req.headers, "content-type", "application/json")
	http.headers_set(
		&req.headers,
		"authorization",
		fmt.aprintf("Bearer %s", api_key, allocator = allocator),
	)

	MODEL :: "gpt-5.1"
	Data :: struct {
		model: string,
		input: string,
	}

	data_json := json.marshal(Data{model = MODEL, input = prompt}, allocator = allocator) or_return
	bytes.buffer_init(&req.body, data_json)

	return
}

Http_Request_Error :: union #shared_nil {
	http_client.Error,
	http_client.Body_Error,
	json.Unmarshal_Error,
}

http_request :: proc(
	request: ^http_client.Request,
	url: string,
	http_allocator, data_allocator: mem.Allocator,
	data: ^$T,
	log := false,
) -> Http_Request_Error {
	res := http_client.request(request, url, http_allocator) or_return
	body, _ := http_client.response_body(&res, allocator = http_allocator) or_return

	if log {
		fmt.println(body)
	}

	#partial switch b in body {
	case http_client.Body_Plain:
		json.unmarshal_string(b, data, allocator = data_allocator) or_return
	case:
		assert(false, "unimplemented")
	}

	return nil
}

Commit :: struct {
	sha:     string,
	commit:  struct {
		author:  struct {
			name: string,
		},
		message: string,
	},
	parents: []struct {
		sha: string,
	},
}

Commit_File :: struct {
	sha:       string,
	filename:  string,
	status:    string,
	additions: i32,
	deletions: i32,
	changes:   i32,
	raw_url:   string,
	patch:     string,
}

Commit_Details :: struct {
	commit: struct {
		author:  struct {
			name:  string,
			email: string,
			date:  string,
		},
		message: string,
	},
	stats:  struct {
		total:     i32,
		additions: i32,
		deletions: i32,
	},
	files:  []Commit_File,
}

minify_patch :: proc(patch, status: string, allocator: mem.Allocator) -> string {
	if patch == "" || status == "removed" {
		return ""
	}

	patch_lines := strings.split_lines(patch, allocator)
	defer delete(patch_lines, allocator)

	switch status {
	case "added":
		// NOTE: ignore the first line, that's hunk header
		patch_lines_without_header := patch_lines[1:]

		out: strings.Builder
		strings.builder_init(&out, allocator)

		for line, i in patch_lines_without_header {
			strings.write_string(&out, line[1:])
			if i != len(patch_lines_without_header) - 1 {
				strings.write_byte(&out, '\n')
			}
		}
		return string(out.buf[:])
	case "modified", "renamed":
		out: strings.Builder
		strings.builder_init(&out, allocator)

		change_line_start: int
		first_change_line: bool

		for line, i in patch_lines {
			switch {
			case strings.has_prefix(line, "@@"):
				// hunk header
				ok: bool
				n: int
				if change_line_start, _ = strconv.parse_int(line[4:], 10, &n); n == 0 {
					assert(
						false,
						fmt.aprintf(
							"unable to parse int: \"%s\"",
							line[4:],
							allocator = allocator,
						),
					)
				}
				first_change_line = true
			case line[0] == '-', line[0] == '+':
				if first_change_line {
					line_num := fmt.aprintf("L%d:\n", change_line_start, allocator = allocator)
					defer delete(line_num, allocator)
					strings.write_string(&out, line_num)
					first_change_line = false
				}

				if line[0] == '-' {
					change_line_start += 1
				}

				strings.write_string(&out, line)
				strings.write_byte(&out, '\n')
			case:
				// context line
				change_line_start += 1
				first_change_line = true
			}
		}

		out_without_nl := make([]byte, len = len(out.buf) - 1, allocator = allocator)
		copy(out_without_nl, out.buf[:len(out.buf) - 1])
		strings.builder_destroy(&out)

		return string(out_without_nl)
	}

	assert(false, fmt.aprintf("invalid status: %s", status, allocator = allocator))
	return ""
}

RESET :: "\x1b[0m"
CLR_GRAY :: "\x1b[38;2;150;150;150m"
CLR_SUCCESS :: "\x1b[38;2;17;180;72m"
DIVIDER :: "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

read_prompt :: proc(
	prompt: string,
	max_len: int,
	allocator: mem.Allocator,
	password := false,
) -> (
	result: string,
	buf: []byte,
	err: os.Error,
) {
	fmt.printf("%s%s\x1b[0m", CLR_GRAY, prompt)

	old_termios: posix.termios
	posix.tcgetattr(posix.STDIN_FILENO, &old_termios)

	raw := old_termios
	raw.c_lflag -= {.ECHO, .ICANON}
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)

	defer posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &old_termios)

	buf = make([]byte, len = max_len, allocator = allocator)
	idx := 0

	chars: for {
		ch: [1]u8
		n, rerr := os.read(os.stdin, ch[:])
		if rerr != nil {
			err = rerr
			return
		}
		if n != 1 {
			break
		}

		{
			ch := ch[0]

			switch ch {
			case '\n', '\r':
				// user done
				break chars
			case '\b', 127:
				// backspace
				if idx > 0 {
					idx -= 1
					fmt.print("\b \b")
				}
			case:
				if idx < max_len {
					buf[idx] = ch
					idx += 1

					if password {
						fmt.print("•")
					} else {
						fmt.printf("%c", ch)
					}
				}
			}
		}
	}

	fmt.println()
	result = string(buf[:idx])
	return
}

Print_Status :: enum {
	Loading,
	Success,
}

@(rodata)
print_preset := [Print_Status]struct {
	em:  rune,
	clr: string,
} {
	.Loading = {'◌', CLR_GRAY},
	.Success = {'✔', CLR_SUCCESS},
}

print :: proc(status: Print_Status, msg: string, clear_line := false) {
	if clear_line {
		fmt.print("\r\x1b[2K")
	}

	p := print_preset[status]
	fmt.printf("%s%c %s\x1b[0m", p.clr, p.em, msg)
}

printf :: proc(status: Print_Status, msg: string, args: ..any, clear_line := false) {
	if clear_line {
		fmt.print("\r\x1b[2K")
	}

	p := print_preset[status]
	fmt.printf("%s%c ", p.clr, p.em)
	fmt.printf(msg, ..args)
	fmt.print("\x1b[0m")
}

main :: proc() {
	context = runtime.default_context()

	program_arena: mem.Arena
	mem.arena_init(&program_arena, PROGRAM_MEMORY[:])
	program_allocator := mem.arena_allocator(&program_arena)

	temp_allocator := create_arena(program_allocator, 10 * mem.Megabyte)

	env := make(map[string]string, allocator = program_allocator)

	{ 	// read .env
		wd, wd_err := os.get_working_directory(program_allocator)
		if wd_err != nil {
			fmt.println("unable to get working directory: ", wd_err)
			return
		}

		defer free_all(temp_allocator)

		dotenv_path, dotenv_err := filepath.join([]string{wd, ".env"}, temp_allocator)
		if dotenv_err != nil {
			fmt.println("unable to join dotenv path: ", dotenv_err)
			return
		}

		dotenv_file_data, ferr := os.read_entire_file_from_path(dotenv_path, temp_allocator)
		if ferr != nil {
			fmt.println("unable to read .env: ", ferr)
			return
		}

		start: int
		key: string
		for b, i in dotenv_file_data {
			switch {
			case b == '=':
				if start < i {
					key = strings.clone(string(dotenv_file_data[start:i]), program_allocator)
				}
				start = i + 1
			// save keyval if byte == '\n' or if it's the last byte and key is set
			case b == '\n', i == len(dotenv_file_data) - 1 && key != "":
				if start < i {
					val := strings.clone(string(dotenv_file_data[start:i]), program_allocator)
					start = i + 1
					if key != "" {
						env[key] = val
						key = ""
					}
				}
			}
		}
	}

	github_access_token, gat_exists := env["GITHUB_ACCESS_TOKEN"]
	if !gat_exists {
		fmt.println("missing github access token")
		return
	}

	// read user input

	github_owner, _, goerr := read_prompt("Github repo owner: ", 100, program_allocator)
	if goerr != nil {
		fmt.println("unable to read from stdin: ", goerr)
		return
	}
	github_repo, _, grerr := read_prompt("Github repository name: ", 100, program_allocator)
	if grerr != nil {
		fmt.println("unable to read from stdin: ", grerr)
		return
	}
	authors_note, _, anerr := read_prompt(
		"Author's note (can be left empty):\n",
		1024,
		program_allocator,
	)
	if anerr != nil {
		fmt.println("unable to read from stdin: ", anerr)
		return
	}

	// fetch github data

	fmt.println(DIVIDER)

	commits: []Commit

	{ 	// get all commits
		print(.Loading, "Fetching commits")
		defer printf(.Success, "Fetched %d commits\n", len(commits), clear_line = true)

		defer free_all(temp_allocator)

		req := create_github_request(temp_allocator, github_access_token)
		url := fmt.aprintf(
			"%s/repos/%s/%s/commits",
			GITHUB_API_URL,
			github_owner,
			github_repo,
			allocator = temp_allocator,
		)

		if err := http_request(req, url, temp_allocator, program_allocator, &commits); err != nil {
			fmt.println("unable to fetch commits: ", err)
			return
		}
	}

	commits_str: strings.Builder
	strings.builder_init(&commits_str, allocator = program_allocator)

	#reverse for commit, i in commits {
		printf(
			.Loading,
			"Fetching commit details (%d/%d)",
			len(commits) - 1 - i,
			len(commits),
			clear_line = true,
		)

		defer free_all(temp_allocator)

		req := create_github_request(temp_allocator, github_access_token)
		url := fmt.aprintf(
			"%s/repos/%s/%s/commits/%s",
			GITHUB_API_URL,
			github_owner,
			github_repo,
			commit.sha,
			allocator = temp_allocator,
		)

		details: Commit_Details
		if err := http_request(req, url, temp_allocator, program_allocator, &details); err != nil {
			fmt.printfln("unable to fetch commit details for %s: %s", commit.sha, err)
			return
		}

		files_str: strings.Builder
		strings.builder_init(&files_str, allocator = temp_allocator)

		file_loop: for file, i in details.files {
			ignore_directories :: [?]string{"vendor", "target"}
			for dir in ignore_directories {
				if strings.contains(
					file.filename,
					fmt.aprintf("%s/", dir, allocator = temp_allocator),
				) {
					continue file_loop
				}
			}


			ignore_suffixes :: [?]string {
				// lock files
				".lock",
				".lockb",
				".sum",
				// binaries
				".bin",
				".wasm",
				".dll",
				".so",
				".exe",
			}
			ignore_filenames :: [?]string{"package-lock.json"}
			skip_patch: bool

			for suffix in ignore_suffixes {
				if strings.has_suffix(file.filename, suffix) {
					skip_patch = true
					break
				}
			}

			if !skip_patch {
				for filename in ignore_filenames {
					if filename == file.filename {
						skip_patch = true
						break
					}
				}
			}

			patch: string
			if !skip_patch {
				patch = minify_patch(file.patch, file.status, temp_allocator)
			}

			str := fmt.aprintf(
				FILE_TEMPL,
				file.filename,
				file.status,
				file.additions,
				file.deletions,
				patch,
				allocator = temp_allocator,
			)
			strings.write_string(&files_str, str)
		}

		strings.write_string(
			&commits_str,
			fmt.aprintf(
				COMMIT_TEMPL,
				details.commit.author.date,
				details.commit.author.name,
				commit.commit.message,
				details.stats.additions,
				details.stats.deletions,
				string(files_str.buf[:]),
				allocator = temp_allocator,
			),
		)
	}

	printf(.Success, "Fetched details for all commits (%d)\n", len(commits), clear_line = true)

	// build prompt

	print(.Loading, "Building LLM prompt\n")

	llm_prompt := build_prompt(
		github_repo,
		string(commits_str.buf[:]),
		authors_note,
		program_allocator,
	)
	free_all(temp_allocator)

	fmt.print("\x1b[3A") // move up 3 lines
	fmt.print("\x1b[0J") // erase from cursor to end of screen

	prompt_size: string
	{
		b := len(llm_prompt)
		switch {
		case b < mem.Kilobyte:
			// bytes
			prompt_size = fmt.aprintf("%db", b, allocator = temp_allocator)
		case b < mem.Megabyte:
			// kilobytes
			prompt_size = fmt.aprintf("%.3fkb", f32(b) / 1024.0, allocator = temp_allocator)
		case b < mem.Gigabyte:
			// megabytes
			prompt_size = fmt.aprintf(
				"%.3fmb",
				f32(b) / 1024.0 / 1024.0,
				allocator = temp_allocator,
			)
		}
	}

	printf(.Success, "Prompt built %s(Prompt size: %s)\n", RESET, prompt_size)
	free_all(temp_allocator)

	// LLM

	{ 	// token count
		// req := create_open_ai_request(temp_allocator)


	}

}
