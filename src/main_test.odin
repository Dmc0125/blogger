package main

import "core:log"
import "core:testing"

@(test)
test_minify_added_file :: proc(t: ^testing.T) {
	// added file: strip + signs, just show lines
	patch := `@@ -0,0 +1,5 @@
+package main
+
+import "core:fmt"
+
+main :: proc() {}`

	expected := `package main

import "core:fmt"

main :: proc() {}`

	result := minify_patch(patch, "added", context.allocator)
	testing.expect_value(t, result, expected)
	delete(result, context.allocator)
}

@(test)
test_minify_deleted_file :: proc(t: ^testing.T) {
	// deleted file: strip - signs, just show lines
	patch := `@@ -1,3 +0,0 @@
-package main
-
-old_proc :: proc() {}`

	expected := ""

	result := minify_patch(patch, "removed", context.allocator)
	delete(result, context.allocator)
}


@(test)
test_minify_modified_single_hunk :: proc(t: ^testing.T) {
	// start=10, 2 context lines, change at line 12
	patch := `@@ -10,7 +10,7 @@ func main() {
     fmt.Println("hi")
     fmt.Println("hello")
-    doOldThing()
+    doNewThing()
     return nil
     fmt.Println("bye")`

	expected := `L12:
-    doOldThing()
+    doNewThing()`

	result := minify_patch(patch, "modified", context.allocator)
	if !testing.expect_value(t, result, expected) {
		log.info(transmute([]byte)result)
	}
	delete(result, context.allocator)
}

@(test)
test_minify_modified_change_at_hunk_start :: proc(t: ^testing.T) {
	// no context before change, line number = hunk start
	patch := `@@ -5,4 +5,4 @@ package main
-    old()
+    new()
     context1
     context2`

	expected := `L5:
-    old()
+    new()`

	result := minify_patch(patch, "modified", context.allocator)
	testing.expect_value(t, result, expected)
	delete(result, context.allocator)
}

@(test)
test_minify_modified_multiple_hunks :: proc(t: ^testing.T) {
	// two hunks, each with 1 context line before change
	patch := `@@ -10,5 +10,5 @@ func main() {
     context
-    oldThing()
+    newThing()
     context
@@ -150,5 +150,6 @@ func other() {
     context
+    addedThing()
     context`

	expected := `L11:
-    oldThing()
+    newThing()
L151:
+    addedThing()`

	result := minify_patch(patch, "modified", context.allocator)
	testing.expect_value(t, result, expected)
	delete(result, context.allocator)
}

@(test)
test_minify_modified_consecutive_changes :: proc(t: ^testing.T) {
	// multiple changed lines with no context gap = no separator
	patch := `@@ -20,6 +20,6 @@ main :: proc() {
     context
-    a := 1
-    b := 2
+    a := 10
+    b := 20
     context`

	expected := `L21:
-    a := 1
-    b := 2
+    a := 10
+    b := 20`

	result := minify_patch(patch, "modified", context.allocator)
	testing.expect_value(t, result, expected)
	delete(result, context.allocator)
}

@(test)
test_minify_modified_gap_within_hunk :: proc(t: ^testing.T) {
	// two change groups separated by context lines inside one hunk
	// second group: line 7 + skip 1 deletion + 1 addition + 3 context = line 11
	// but using old file numbering: 7(change) + 1(newA) skipped + 3 context = 10
	// old line: start=5, 2 ctx, change at 7, then 3 ctx (8,9,10), change at 11
	patch := `@@ -5,12 +5,12 @@ package main
     unchanged1
     unchanged2
-    oldA()
+    newA()
     unchanged3
     unchanged4
     unchanged5
-    oldB()
+    newB()
     unchanged6`

	expected := `L7:
-    oldA()
+    newA()
L11:
-    oldB()
+    newB()`

	result := minify_patch(patch, "modified", context.allocator)
	testing.expect_value(t, result, expected)
	delete(result, context.allocator)
}

@(test)
test_minify_modified_only_additions :: proc(t: ^testing.T) {
	// only + lines, no deletions
	patch := `@@ -10,3 +10,6 @@ main :: proc() {
     existing_line
+    new_line_1()
+    new_line_2()
+    new_line_3()
     existing_line`

	expected := `L11:
+    new_line_1()
+    new_line_2()
+    new_line_3()`

	result := minify_patch(patch, "modified", context.allocator)
	testing.expect_value(t, result, expected)
	delete(result, context.allocator)
}

@(test)
test_minify_modified_only_deletions :: proc(t: ^testing.T) {
	patch := `@@ -10,6 +10,3 @@ main :: proc() {
     existing_line
-    removed_1()
-    removed_2()
-    removed_3()
     existing_line`

	expected := `L11:
-    removed_1()
-    removed_2()
-    removed_3()`

	result := minify_patch(patch, "modified", context.allocator)
	testing.expect_value(t, result, expected)
	delete(result, context.allocator)
}

@(test)
test_minify_empty_patch :: proc(t: ^testing.T) {
	result := minify_patch("", "modified", context.allocator)
	testing.expect_value(t, result, "")
	delete(result, context.allocator)
}

@(test)
test_minify_modified_addition_between_deletions :: proc(t: ^testing.T) {
	// + lines don't advance old file line counter
	patch := `@@ -10,4 +10,5 @@ main :: proc() {
-    a()
+    b()
+    c()
-    d()
     context`

	expected := `L10:
-    a()
+    b()
+    c()
-    d()`

	result := minify_patch(patch, "modified", context.allocator)
	testing.expect_value(t, result, expected)
	delete(result, context.allocator)
}

@(test)
test_minify_modified_plus_lines_dont_increment_line_counter :: proc(t: ^testing.T) {
	// verify that + lines between context don't affect line numbering
	// old file: line 10 context, line 11 deleted
	// the + lines in between don't exist in old file
	patch := `@@ -10,5 +10,7 @@ main :: proc() {
     context_a
+    inserted_1()
+    inserted_2()
     context_b
-    old()
+    new()
     context_c`

	expected := `L11:
+    inserted_1()
+    inserted_2()
L12:
-    old()
+    new()`

	result := minify_patch(patch, "modified", context.allocator)
	testing.expect_value(t, result, expected)
	delete(result, context.allocator)
}
