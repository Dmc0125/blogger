#+vet explicit-allocators
package main

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"

import http "../vendor/odin-http"
import http_client "../vendor/odin-http/client"

PROGRAM_MEMORY: [100 * mem.Megabyte]byte

GITHUB_API_URL :: "https://api.github.com"

FILE_TEMPL :: `
        %s:
            - changes +%d / -%d
            - patch: %s
`

COMMIT_TEMPL :: `
%s:
    - author: %s
    - message: %s
    - changes: +%d / -%d
    - files:
        %s
`

PROMPT_TEMPL :: `You are a technical blog writer. You will be given technical project data (commit history) and based on that you will write a blog post about building this project.

Project name: %s

Commits:
%s

Writing instructions:

Write in first person. Include:
- Project description
- Key technical decisions
- Challenges and how they were solved
- Final architecture overview

You can also include code blocks if there is any interesting stuff and explain them
`

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

	// read cli args

	if len(os.args) < 3 {
		fmt.println("need to provide github owner and repo")
		return
	}

	github_owner := os.args[1]
	github_repo := os.args[2]

	commits: []Commit

	{ 	// get all commits
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

		for file, i in details.files {
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
			ignore_directories :: [?]string{"vendor", "target"}

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

			if !skip_patch {
				for dir in ignore_directories {
					if strings.contains(
						file.raw_url,
						fmt.aprintf("/%s/", dir, allocator = temp_allocator),
					) {
						skip_patch = true
						break
					}
				}
			}

			patch: string
			if !skip_patch {
				patch = file.patch
			}

			str := fmt.aprintf(
				FILE_TEMPL,
				file.filename,
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

	prompt := fmt.aprintf(
		PROMPT_TEMPL,
		github_repo,
		string(commits_str.buf[:]),
		allocator = program_allocator,
	)
	free_all(temp_allocator)

	out_file := os.args[3]
	prompt_file, err := os.create(out_file)
	if err != nil {
		fmt.println("unable to create prompt file: ", err)
		return
	}
	if _, err := os.write(prompt_file, transmute([]byte)prompt); err != nil {
		fmt.println("unable to write to prompt file: ", err)
		return
	}
}
