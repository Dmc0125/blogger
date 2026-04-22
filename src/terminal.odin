package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:sys/posix"

RESET :: "\x1b[0m"
CLR_GRAY :: "\x1b[38;2;150;150;150m"
CLR_DARK_GRAY :: "\x1b[38;2;110;110;110m"
CLR_SUCCESS :: "\x1b[38;2;17;180;72m"
DIVIDER :: "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

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
	.Success = {'✓', CLR_SUCCESS},
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

term_enable_raw_mode :: proc() -> (old_termios: posix.termios) {
	posix.tcgetattr(posix.STDIN_FILENO, &old_termios)

	raw := old_termios
	raw.c_lflag -= {.ECHO, .ICANON}
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &raw)

	return
}

term_restore :: proc(old_termios: posix.termios) {
	ot := old_termios
	posix.tcsetattr(posix.STDIN_FILENO, .TCSANOW, &ot)
}

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

	old_termios := term_enable_raw_mode()
	defer term_restore(old_termios)

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

read_confirmation :: proc(prompt: string) -> (result: bool, err: os.Error) {
	fmt.printf("%s%s (press anything for yes/ n for no) \x1b[0m", CLR_GRAY, prompt)

	old_termios := term_enable_raw_mode()
	defer {
		term_restore(old_termios)
		fmt.println()
	}

	chars: for {
		ch: [1]u8
		n := os.read(os.stdin, ch[:]) or_return
		if n != 1 {
			fmt.print("no")
			return
		}

		switch ch[0] {
		case 'n':
			fmt.print("no")
			return
		case:
			fmt.print("yes")
			result = true
			return
		}
	}
}

read_choice :: proc(prompt: string, choices: []string) -> (chosen: string, err: os.Error) {
	fmt.printf("%s%s %s(j down / k up / enter submit) \x1b[0m\n", CLR_GRAY, prompt, CLR_DARK_GRAY)

	old_termios := term_enable_raw_mode()
	defer term_restore(old_termios)

	selected := -1

	for {
		for c, i in choices {
			if i == selected {
				fmt.printfln("● %s", c)
			} else {
				fmt.printfln("○ %s", c)
			}
		}

		ch: [1]u8
		n := os.read(os.stdin, ch[:]) or_return
		if n != 1 {
			return
		}

		switch ch[0] {
		case 'j':
			if selected < len(choices) - 1 {
				selected += 1
			} else {
				selected = 0
			}
		case 'k':
			if selected > 0 {
				selected -= 1
			} else {
				selected = len(choices) - 1
			}
		case 10:
			if selected >= 0 && selected < len(choices) {
				chosen = choices[selected]
				return
			}
		}

		fmt.print("\x1b[2A") // move up 2 lines
		fmt.print("\x1b[0J") // erase from cursor to end of screen
	}
}
