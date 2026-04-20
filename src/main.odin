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

create_arena :: proc(backing_allocator: mem.Allocator, size: int) -> (allocator: mem.Allocator) {
	arena := new(mem.Arena, backing_allocator)
	data := make([]byte, len = size, allocator = backing_allocator)
	mem.arena_init(arena, data)
	allocator = mem.arena_allocator(arena)
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

	// TODO: handle response status not ok

	if log {
		fmt.println("Headers: ", res.headers)
		fmt.println("Body: ", body)
	}

	#partial switch b in body {
	case http_client.Body_Plain:
		json.unmarshal_string(b, data, allocator = data_allocator) or_return
	case:
		assert(false, "unimplemented")
	}

	return nil
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
	openai_api_key, oaik_exists := env["OPEN_AI_API_KEY"]
	if !oaik_exists {
		fmt.println("missing open ai API KEY")
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

	print(.Loading, "Building LLM prompt")

	llm_prompt := build_prompt(
		github_repo,
		string(commits_str.buf[:]),
		authors_note,
		program_allocator,
	)
	free_all(temp_allocator)

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

	printf(.Success, "Prompt built %s(size: %s)\n", RESET, prompt_size, clear_line = true)

	// LLM

	{ 	// token count
		print(.Loading, "Fetching token count")
		defer free_all(temp_allocator)

		req, err := create_open_ai_request(temp_allocator, openai_api_key, llm_prompt)
		if err != nil {
			fmt.println("unable to create open ai request: ", err)
			return
		}

		url := fmt.aprintf(
			"%s/responses/input_tokens",
			OPEN_AI_API_URL,
			allocator = temp_allocator,
		)

		Input_Tokens_Reponse :: struct {
			input_tokens: int,
		}
		response: Input_Tokens_Reponse
		if err := http_request(req, url, temp_allocator, program_allocator, &response);
		   err != nil {
			fmt.println("unable to fetch count if input tokens: ", err)
			return
		}

		printf(.Success, "Token count: %d\n", response.input_tokens, clear_line = true)
	}

	should_continue, cerr := read_confirmation("Do you want to continue?")
	if cerr != nil {
		fmt.println("unable to read from stdin: ", cerr)
		return
	}

	if !should_continue {
		return
	}

	fmt.println(DIVIDER)

	Response_Output_Content :: struct {
		type: string,
		text: string,
	}

	Response_Output :: struct {
		type:    string,
		id:      string,
		status:  string,
		role:    string,
		content: []Response_Output_Content,
	}

	Create_Response_Response :: struct {
		output: []Response_Output,
		usage:  struct {
			input_tokens:  int,
			output_tokens: int,
		},
	}

	llm_response: Create_Response_Response
	{ 	// send prompt
		print(.Loading, "Sending prompt")
		defer {
			printf(
				.Success,
				"LLM response received (output tokens: %d)\n",
				llm_response.usage.output_tokens,
				clear_line = true,
			)
			free_all(temp_allocator)
		}

		req, err := create_open_ai_request(temp_allocator, openai_api_key, llm_prompt)
		if err != nil {
			fmt.println("unable to create open ai request: ", err)
			return
		}

		url := fmt.aprintf("%s/responses", OPEN_AI_API_URL, allocator = temp_allocator)

		if err := http_request(req, url, temp_allocator, program_allocator, &llm_response);
		   err != nil {
			fmt.println("unable to fetch LLM response: ", err)
			return
		}
	}

	print(.Loading, "Saving LLM output")

	exe_path := os.args[0]
	// NOTE: temp_allocator is empty, we can ignore the error
	out_path, _ := filepath.join(
		{exe_path, "../out", fmt.aprintf("%s.md", github_repo, allocator = temp_allocator)},
		temp_allocator,
	)

	out_file, oerr := os.create(out_path)
	if oerr != nil {
		fmt.println("unable to create out file: ", oerr)
		return
	}

	for o in llm_response.output {
		for content in o.content {
			if content.type == "output_text" {
				if _, err := os.write(out_file, transmute([]byte)content.text); err != nil {
					fmt.println("unable to write llm output: ", err)
					return
				}
			}
		}
	}

	printf(.Success, "Saved LLM output to %s\n", out_path, clear_line = true)
}
