//------------------------------------------------------------------------------
// wc_arm64: a simplistic wc clone in ARM64 assembly. Usage:
//
// $ wc_arm64 file1 /path/file2 file3
//
// When not given any command-line arguments, reads from stdin.
// Always prints the all three counters: line, word, byte.
//
// Kay Lack, ported from Eli Bendersky's work.
// See https://github.com/eliben/wcx64 for the original x86-64 version.
// This code is in the public domain.
//------------------------------------------------------------------------------


//------------- CONSTANTS --------------//
.set READ_SYSCALL, 3             // Syscall number for read
.set WRITE_SYSCALL, 4            // Syscall number for write
.set OPENAT_SYSCALL, 463         // Syscall number for openat
.set CLOSE_SYSCALL, 6            // Syscall number for close
.set EXIT_SYSCALL, 1             // Syscall number for exit
.set STDIN_FD, 0                 // File descriptor for stdin
.set STDOUT_FD, 1                // File descriptor for stdout

.set O_RDONLY, 0x0
.set OPEN_NO_MODE,   0666
.set AT_FDCWD, -2
.set READBUFLEN, 16384
.set ITOABUFLEN, 12
.set NEWLINE, '\n'
.set CR, '\r'
.set TAB, '\t'
.set SPACE, ' '

//---------------- MACROS ----------------//

// Push a register onto the stack
// Note that this is the least efficient way to use the stack in ARM64.
// But also the simplest :)
.macro push reg
  str \reg, [sp, #-16]!
.endm

// Pop a register from the stack as above
.macro pop reg
  ldr \reg, [sp], #16
.endm

// Load the address of a label into a register
.macro load_addr reg, label
    adrp \reg, \label@PAGE
    add \reg, \reg, \label@PAGEOFF
.endm

//---------------- DATA ----------------//
    .data

newline_str:
    .asciz "\n"

fourspace_str:
    .asciz "    "

total_str:
    .asciz "total"

buf_for_read:
    // leave space for terminating 0
    .space READBUFLEN + 1, 0x0

    // The itoa buffer here is large enough to hold just 11 digits (plus one
    // byte for the terminating null). For the wc counters this is enough
    // because it lets us represent 10-digit numbers (up to 10 GB)
    // with spaces in between.
    // Note: this is an artificial limitation for simplicity in printing out the
    // counters; this size can be easily increased.

buf_for_itoa:
    .space ITOABUFLEN, 0x0
    .set   endbuf_for_itoa, buf_for_itoa + ITOABUFLEN - 1


//---------------- "MAIN" CODE ----------------//
    .global _main
    .text
    .align 4

_main:
    // To start, X0 is argc and X1 is the address where we can find
    // quads of addresses pointing to the items in argv.

    mov X19, X0                  // Store argc in X19
    mov X20, X1                  // Store address to argv in X20

    // If there are no argv, go to .L_no_argv for reading from stdin.
    cmp X0, #1
    b.le .L_no_argv

    mov X25, #0
    mov X26, #0
    mov X27, #0

    // In a loop, argv[n] for 1 <= n < argc; X21 holds n.
    mov X21, #1

.L_argv_loop:
    // Throughout the loop, register assignments:
    // X22: argv[n]. Also gets into X1 for passing into the openat() syscall
    // X21: argv counter n
    // X19: argc
    // X25, X26, X27: total numbers counted in all files
    ldr X1, [X20, X21, lsl #3]   // argv[n] is in (X20 + X21 * 8)
                                 // lsl #3 means shift left by 3 bits,
                                 // i.e., multiply by 8
    mov X22, X1

    // Call openat(AT_FDCWD, argv[n], O_RDONLY, OPEN_NO_MODE)
    mov X0, #AT_FDCWD
    mov X2, #O_RDONLY
    mov X3, #OPEN_NO_MODE
    mov X16, #OPENAT_SYSCALL
    svc #0x80

    // Ignore files that can't be opened
    cmp X0, #0
    b.lt .L_next_argv
    push X0                      // save fd on the stack

    bl count_in_file             // Call count_in_file

    // Add the counters returned from count_in_file to the totals and pass
    // them to print_counters.
    add X25, X25, X0
    add X26, X26, X1
    add X27, X27, X2
    mov X3, X22                  // filename to print_counters
    bl print_counters

    // Call close(fd)
    mov X8, CLOSE_SYSCALL
    pop X0                       // restore fd from the stack
    svc #0x80

.L_next_argv:
    add X21, X21, #1
    cmp X21, X19
    b.lt .L_argv_loop

    // Done with all argv. Now print out the totals.
    mov X0, X25
    mov X1, X26
    mov X2, X27
    load_addr X3, total_str
    bl print_counters

    b .L_wcarm64_exit

.L_no_argv:
    // Read from stdin, which is file descriptor 0.
    mov X0, STDIN_FD
    bl count_in_file

    // Print the counters without a name string
    mov X3, #0
    bl print_counters

.L_wcarm64_exit:
    // exit(0)
    mov X0, #0
    mov X16, EXIT_SYSCALL
    svc #0x80

//---------------- FUNCTIONS ----------------//

// Function count_in_file
// Counts chars, words and lines for a single file.
//
// Arguments:
// X0     file descriptor representing an open file.
//
// Returns:
// X0     line count
// X1     word count
// X2     char count
count_in_file:
    // Register usage within the function:
    //
    // X9: holds the fd
    // X10: char counter
    // X11: word counter
    // X12: line counter
    // X13: address of the read buffer
    // X14: loop index for going over a read buffer
    // W3: next byte read from the buffer
    // X4: state indicator, with the states defined below.
    // The word counter is incremented when we switch from
    // IN_WHITESPACE to IN_WORD.

    .set IN_WORD, 1
    .set IN_WHITESPACE, 2

    mov X9, X0
    mov X10, 0
    mov X11, 0
    mov X12, 0
    load_addr X13, buf_for_read
    mov X4, #IN_WHITESPACE

.L_read_buf:
    // Call read(fd, buf_for_read, READBUFLEN)
    mov X0, X9
    mov X1, X13
    mov X2, READBUFLEN
    mov X16, READ_SYSCALL
    svc #0x80

    // From here on, X0 holds the number of bytes actually read from the
    // file (the return value of read())
    add X10, X10, X0             // Update the char counter

    cbz X0, .L_done_with_file    // No bytes read?

    mov X14, #0
.L_next_byte_in_buf:
    ldrb W3, [X13, X14]          // Read the byte

    // See what we've got and jump to the appropriate label.
    cmp W3, #NEWLINE
    b.eq .L_seen_newline
    cmp W3, #CR
    b.eq .L_seen_whitespace_not_newline
    cmp W3, #SPACE
    b.eq .L_seen_whitespace_not_newline
    cmp W3, #TAB
    b.eq .L_seen_whitespace_not_newline

    // If we're in a word already, nothing else to do.
    cmp X4, #IN_WORD
    b.eq .L_done_with_this_byte
    // else, transition from IN_WHITESPACE to IN_WORD: increment the word counter.
    add X11, X11, 1
    mov X4, #IN_WORD
    b .L_done_with_this_byte

.L_seen_newline:
    // Increment the line counter and fall through.
    add X12, X12, 1

.L_seen_whitespace_not_newline:
    cmp X4, #IN_WORD
    b.eq .L_end_current_word
    // Otherwise, still in whitespace.
    b .L_done_with_this_byte

.L_end_current_word:
    mov X4, #IN_WHITESPACE

.L_done_with_this_byte:
    // Advance read pointer and check if we haven't finished with the read
    // buffer yet.
    add X14, X14, 1
    cmp X0, X14
    b.gt .L_next_byte_in_buf

    // Done Done going over this buffer. We need to read another buffer
    // if rax == READBUFLEN.
    cmp X0, READBUFLEN
    b.eq .L_read_buf

.L_done_with_file:
    # Done with this file. The char count is already in r9.
    # Put the word and line counts in their return locations.
    mov X0, X12
    mov X1, X11
    mov X2, X10

    ret

// Function print_cstring
// Print a null-terminated string to stdout.
//
// Arguments:
// X0     address of string
//
// Returns: void
print_cstring:
    // Find the terminating null
    mov X1, X0
.L_find_null:
    ldrb W2, [X1]
    cbz W2, .L_end_find_null
    add X1, X1, 1
    b .L_find_null

.L_end_find_null:
    // X1 points to the terminating null. so X1-X0 is the length
    sub X2, X1, X0
    // Now that we have the length, we can call sys_write
    // sys_write(unsigned fd, char* buf, size_t count)
    mov X16, WRITE_SYSCALL
    // Populate address of string into X1 first, because the later
    // assignment of fd clobbers X0.
    mov X1, X0
    mov X0, STDOUT_FD
    svc #0x80
    ret

// Function print_counters
// Print three counters with an optional name to stdout.
//
// Arguments:
// X0, X1, X2:   the counters
// X3:           address of the name C-string. If 0, no name is printed.
//
// Returns: void
print_counters:
    push X30                     // save return address
    push X19                     // save registers for restoring later
    push X20
    push X2                      // push arguments to stack so we can
    push X1                      // iterate over them in a loop
    push X0

    // X3 can be clobbered by callees, so save it in X20
    mov X20, X3

    // X19 is the counter pointer, running over 0, 16, 32
    // counter N is at (sp + X19)
    mov X19, 0

.L_print_next_counter:
    // Fill the itoa buffer with spaces.
    load_addr X0, buf_for_itoa
    mov X1, #SPACE
    mov X2, #ITOABUFLEN
    bl memset

    // Convert the next counter and then call print_cstring with the
    // beginning of the itoa buffer - because we want space-prefixed
    // output.
    ldr X0, [sp, X19]    // sp + X19
    load_addr X1, endbuf_for_itoa
    bl itoa
    load_addr X0, buf_for_itoa
    bl print_cstring
    add X19, X19, #16
    cmp X19, #48
    b.lt .L_print_next_counter

    // If name address is not 0, print out the given null-terminated string
    // as well.
    cbz X20, .L_print_counters_done
    load_addr X0, fourspace_str
    bl print_cstring
    mov X0, X20
    bl print_cstring

.L_print_counters_done:
    load_addr X0, newline_str
    bl print_cstring
    pop X0
    pop X1
    pop X2
    pop X20
    pop X19
    pop X30
    ret

// Function memset
// Fill memory with some byte
//
// Arguments:
// X0:    pointer to memory
// X1:    fill byte (in the low 8 bits)
// X2:    how many bytes to fill
//
// Returns: void
memset:
    mov X3, 0
.L_next_byte:
    strb W1, [X0, X3]
    add X3, X3, 1
    cmp X3, X2
    blt .L_next_byte
    ret

// Function itoa
// Convert an integer to a null-terminated string in memory.
// Assumes that there is enough space allocated in the target
// buffer for the representation of the integer. Since the number itself
// is accepted in the register, its value is bounded.
//
// Arguments:
// X0:    the integer
// X1:    address of the *last* byte in the target buffer. bytes will be filled
//        starting with this address and proceeding lower until the number
//        runs out.
//
// Returns:
// X0:    address of the first byte in the target string that
//        contains valid information.
itoa:
    strb WZR, [X1]               // Write the terminating null and advance

    // If the input number is negative, we mark it by placing 1 into X9
    // and negate it. In the end we check if X9 is 1 and add a '-' in front.
    mov X9, 0
    cmp X0, 0
    b.ge .L_input_positive
    neg X0, X0
    mov X9, 1

.L_input_positive:
    mov X2, 10

.L_next_digit:
    udiv X4, X0, X2
    msub X3, X4, X2, X0
    mov X0, X4
    sub X1, X1, #1
    add X3, X3, '0'
    strb W3, [X1]
    cbz X0, .L_itoa_done
    b .L_next_digit

.L_itoa_done:
    cbz X9, .L_itoa_positive
    sub X1, X1, 1
    mov W3, '-'
    strb W3, [X1]

.L_itoa_positive:
    mov X0, X1
    ret
