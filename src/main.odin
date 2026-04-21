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

IGNORED_DIRECTORIES :: [?]string{"vendor", "target"}
IGNORED_SUFFIXES :: [?]string {
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
	// assets
	".ttf",
	".png",
}
IGNORED_FILENAMES :: [?]string{"package-lock.json"}

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

Error_Og :: union {
	os.Error,
	mem.Allocator_Error,
	Http_Request_Error,
}

Error :: struct {
	valid: bool,
	loc:   runtime.Source_Code_Location,
	msg:   string,
	og:    Error_Og,
}

error_new :: proc(og: Error_Og, msg := "", loc := #caller_location) -> (err: Error) {
	err.valid = true
	err.loc = loc
	err.msg = msg
	err.og = og
	return
}

error_string :: proc(err: ^Error, allocator: mem.Allocator) -> string {
	// NOTE: this function allocates duplicate memory for some strings
	sb: strings.Builder
	strings.builder_init(&sb, allocator)

	strings.write_string(&sb, "Error at ")
	strings.write_string(&sb, fmt.aprintf("%s: ", err.loc, allocator = allocator))

	if len(err.msg) > 0 {
		strings.write_string(&sb, err.msg)
		strings.write_string(&sb, " ")
	}

	strings.write_string(&sb, fmt.aprintf("%s", err.og, allocator = allocator))
	return string(sb.buf[:])
}

error_print :: proc(err: ^Error, allocator: mem.Allocator) {
	s := error_string(err, allocator)
	fmt.println(s)
}

error_print_new :: proc(
	allocator: mem.Allocator,
	og: Error_Og,
	msg := "",
	loc := #caller_location,
) {
	e := error_new(og, msg, loc)
	error_print(&e, allocator)
}

generate_readme_prompt :: proc(
	github_owner, github_repo, authors_note: string,
	program_allocator, temp_allocator: mem.Allocator,
) -> (
	prompt: string,
	err: Error,
) {
	defer free_all(temp_allocator)

	// create the temp dir
	tmp_path, tderr := os.make_directory_temp(
		"/tmp",
		fmt.aprintf("%s-%s", github_owner, github_repo, allocator = temp_allocator),
		program_allocator,
	)
	if tderr != nil {
		err = error_new(tderr)
		return
	}
	defer {
		if err := os.remove_all(tmp_path); err != nil {
			fmt.println("unable to remove temp directory: ", err)
		}
	}

	{ 	// clone the repo
		print(.Loading, "Cloning repository")

		git_url := fmt.aprintf(
			"https://github.com/%s/%s.git",
			github_owner,
			github_repo,
			allocator = temp_allocator,
		)
		process_desc := os.Process_Desc {
			working_dir = tmp_path,
			command     = {"git", "clone", "--depth", "1", git_url, "."},
		}
		process_state, _, stderr, perr := os.process_exec(process_desc, temp_allocator)
		if perr != nil {
			err = error_new(perr)
			return
		}
		if !process_state.success {
			msg := fmt.aprintf(
				"process exited without success: %s",
				string(stderr),
				allocator = program_allocator,
			)
			err = error_new(nil, msg)
			return
		}

		print(.Success, "Cloned repository\n", clear_line = true)
	}

	// read repo
	print(.Loading, "Reading files and buildig prompt")

	read_dir :: proc(
		path: string,
		files: ^[dynamic]Readme_File,
		program_allocator, temp_allocator: mem.Allocator,
	) -> (
		err: Error,
	) {
		fis, rderr := os.read_directory_by_path(path, 0, temp_allocator)
		if rderr != nil {
			err = error_new(rderr)
			return
		}

		fis_loop: for fi in fis {
			#partial switch fi.type {
			case .Directory:
				if strings.has_prefix(fi.name, ".") {
					continue fis_loop
				}
				for d in IGNORED_DIRECTORIES {
					if fi.name == d {
						continue fis_loop
					}
				}
				read_dir(fi.fullpath, files, program_allocator, temp_allocator)
			case .Regular:
				for suffix in IGNORED_SUFFIXES {
					if strings.has_suffix(fi.name, suffix) {
						continue fis_loop
					}
				}
				for name in IGNORED_FILENAMES {
					if fi.name == name {
						continue fis_loop
					}
				}

				file_data, fderr := os.read_entire_file_from_path(fi.fullpath, program_allocator)
				if fderr != nil {
					msg := fmt.aprintf(
						"unable to read file: %s",
						fi.fullpath,
						allocator = program_allocator,
					)
					err = error_new(fderr, msg)
					return
				}

				file_path, aerr := strings.clone(fi.fullpath, program_allocator)
				if aerr != nil {
					err = error_new(aerr)
					return
				}

				append(files, Readme_File{path = file_path, data = file_data})
			}
		}

		return
	}

	files := make([dynamic]Readme_File, allocator = program_allocator)
	if err = read_dir(tmp_path, &files, program_allocator, temp_allocator); err.valid {
		return
	}

	for file, i in files {
		files[i].path = file.path[len(tmp_path):]
	}

	prompt = build_readme_prompt(github_repo, authors_note, files[:], program_allocator)
	return
}

generate_blogpost_prompt :: proc(
	github_owner, github_repo, authors_note: string,
	github_access_token: string,
	openai_api_key: string,
	program_allocator, temp_allocator: mem.Allocator,
) -> (
	llm_prompt: string,
	err: Error,
) {
	defer free_all(temp_allocator)

	// fetch github data

	commits: []Commit

	{ 	// get all commits
		print(.Loading, "Fetching commits")
		defer printf(.Success, "Fetched %d commits\n", len(commits), clear_line = true)

		req := create_github_request(temp_allocator, github_access_token)
		url := fmt.aprintf(
			"%s/repos/%s/%s/commits",
			GITHUB_API_URL,
			github_owner,
			github_repo,
			allocator = temp_allocator,
		)

		if rerr := http_request(req, url, temp_allocator, program_allocator, &commits);
		   rerr != nil {
			err = error_new(rerr)
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
		if rerr := http_request(req, url, temp_allocator, program_allocator, &details);
		   rerr != nil {
			err = error_new(rerr)
			return
		}

		files_str: strings.Builder
		strings.builder_init(&files_str, allocator = temp_allocator)

		file_loop: for file, i in details.files {
			for dir in IGNORED_DIRECTORIES {
				if strings.contains(
					file.filename,
					fmt.aprintf("%s/", dir, allocator = temp_allocator),
				) {
					continue file_loop
				}
			}


			skip_patch: bool
			for suffix in IGNORED_SUFFIXES {
				if strings.has_suffix(file.filename, suffix) {
					skip_patch = true
					break
				}
			}
			if !skip_patch {
				for filename in IGNORED_FILENAMES {
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

	llm_prompt = build_blog_prompt(
		github_repo,
		string(commits_str.buf[:]),
		authors_note,
		program_allocator,
	)

	return
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

	choice, cherr := read_choice("What do you want to create?", {"Blogpost", "Readme"})
	if cherr != nil {
		fmt.println("unable to read from stdin: ", cherr)
		return
	}
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

	fmt.println(DIVIDER)

	err: Error
	llm_prompt: string

	switch choice {
	case "Readme":
		llm_prompt, err = generate_readme_prompt(
			github_owner,
			github_repo,
			authors_note,
			program_allocator,
			temp_allocator,
		)
	case "Blogpost":
		llm_prompt, err = generate_blogpost_prompt(
			github_owner,
			github_repo,
			authors_note,
			github_access_token,
			openai_api_key,
			program_allocator,
			temp_allocator,
		)
	}

	if err.valid {
		fmt.println(error_string(&err, program_allocator))
		return
	}

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


	exe_path := os.args[0]
	// NOTE: temp_allocator is empty, we can ignore the error
	out_filename := fmt.aprintf(
		"%s-%s.md",
		github_repo,
		strings.to_lower(choice, temp_allocator),
		allocator = temp_allocator,
	)
	out_path, _ := filepath.join({exe_path, "../out", out_filename}, temp_allocator)

	out_path_ok, operr := read_confirmation(
		fmt.aprintf(
			"Do you want to save the output to: %s?",
			out_path,
			allocator = temp_allocator,
		),
	)
	if operr != nil {
		error_print_new(program_allocator, operr)
		return
	}
	if !out_path_ok {
		err: os.Error
		out_path, _, err = read_prompt("Output file path: ", 100, temp_allocator)
		if err != nil {
			error_print_new(program_allocator, err)
			return
		}
	}

	out_file, oerr := os.create(out_path)
	if oerr != nil {
		error_print_new(program_allocator, oerr)
		return
	}

	for o in llm_response.output {
		for content in o.content {
			if content.type == "output_text" {
				if _, err := os.write(out_file, transmute([]byte)content.text); err != nil {
					error_print_new(program_allocator, err)
					return
				}
			}
		}
	}

	printf(.Success, "%s generated\n", choice)
	fmt.printfln("Saved LLM output to: %s", out_path)
}
