#include <linux/auxvec.h>
#include <linux/mman.h>
#include <sys/syscall.h>

#define O_RDONLY 00000000
#define O_CLOEXEC 02000000
#define AT_EMPTY_PATH 0x1000
#define SEEK_SET 0
#define PT_NULL 0
#define PT_LOAD 1
#define PT_INTERP 3

#define PAGE_SIZE 4096

.globl _zapps_start, _start
_zapps_start:
    mov %rsp, %rbp
/* RBP: saved RSP */

/* step 1: find AUXV */
    pop %rcx /* argc */
    lea 8(%rsp,%rcx,8), %rsp /* argv array */
envp_loop:
    pop %rax
    test %rax, %rax
    jz auxv_found
    jmp envp_loop

auxv_found:
    mov %rsp, %rbx
    mov %rbp, %rsp
/* RBX: base address of AUXV */

/* step 2: find path of executable from getauxval(AT_EXECFN), then
   construct the loader path on stack */
    sub $ld_path_len, %rsp
    mov %rsp, %rdi
    lea ld_path(%rip), %rsi
    mov $ld_path_len, %ecx
    call memcpy

    mov $AT_EXECFN, %eax
    call getauxval

    mov %rax,%rdi
    call strlen

/* find the last / in the path */
    push %rax
    mov $'/, %al
    std
    repne scasb
    add $2, %cx
    pop %rax

    sub %rcx, %rsp
    mov %rsp, %rdi
    mov %rax, %rsi
    call memcpy

/* step 3: open & map the loader */
    mov $SYS_open, %eax
    mov %rsp, %rdi
    mov $(O_RDONLY|O_CLOEXEC), %esi
    syscall
    test %rax, %rax
    jl fail
    mov %rax, %r15
    mov %rbp, %rsp

    sub $64, %rsp /* sizeof(Elf64_Ehdr) */
    mov $SYS_read, %eax
    mov %r15, %rdi
    mov %rsp, %rsi
    mov $64, %edx /* sizeof(Elf64_Ehdr) */
    syscall
    test %rax, %rdx
    jl fail

    mov 24(%rsp), %r13 /* offsetof(Elf64_Ehdr, e_entry) */
    mov 32(%rsp), %rsi /* offsetof(Elf64_Ehdr, e_phoff) */
    mov 56(%rsp), %r12w /* offsetof(Elf64_Ehdr, e_phnum) */
    mov %rbp, %rsp

    mov $SYS_lseek, %eax
    mov $SEEK_SET, %edx
    syscall
    test %rax, %rax
    jl fail

    xor %r14d, %r14d

/* find the map range and reserve the entire area to get a base address */
phdr_loop1:
    sub $56, %rsp /* sizeof(Elf64_Phdr) */
    mov $SYS_read, %eax
    mov %r15, %rdi
    mov %rsp, %rsi
    mov $56, %edx /* sizeof(Elf64_Phdr) */
    syscall
    test %rax, %rdx
    jl fail

    cmpl $PT_LOAD, 0(%rsp) /* offsetof(Elf64_Phdr, p_type) */
    jne phdr_loop1_next

    mov 16(%rsp), %rdi /* offsetof(Elf64_Phdr, p_vaddr) */
    add 40(%rsp), %rdi /* offsetof(Elf64_Phdr, p_memsz) */
    cmp %rdi, %r14
    ja phdr_loop1_next
    mov %rdi, %r14

phdr_loop1_next:
    mov %rbp, %rsp
    dec %r12w
    jnz phdr_loop1

    mov $SYS_mmap, %eax
    xor %edi, %edi
    mov %r14, %rsi
    mov $PROT_NONE, %rdx
    mov $(MAP_PRIVATE|MAP_ANONYMOUS), %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    syscall
    test %rax, %rax
    jl fail
    mov %rax, %r14
/* R14: base address of ld.so */
cp:

    mov $SYS_lseek, %eax
    mov %r15, %rdi
    xor %esi, %esi
    mov $SEEK_SET, %edx
    syscall
    test %rax, %rax
    jl fail

    sub $64, %rsp /* sizeof(Elf64_Ehdr) */
    mov $SYS_read, %eax
    mov %r15, %rdi
    mov %rsp, %rsi
    mov $64, %edx /* sizeof(Elf64_Ehdr) */
    syscall
    test %rax, %rdx
    jl fail

    mov 32(%rsp), %rsi /* offsetof(Elf64_Ehdr, e_phoff) */
    mov 56(%rsp), %r12w /* offsetof(Elf64_Ehdr, e_phnum) */
    mov %rbp, %rsp

    mov $SYS_lseek, %eax
    mov $SEEK_SET, %edx
    syscall
    test %rax, %rax
    jl fail

/* Now do the actual mappings */
phdr_loop2:
    sub $56, %rsp /* sizeof(Elf64_Phdr) */
    mov $SYS_read, %eax
    mov %r15, %rdi
    mov %rsp, %rsi
    mov $56, %edx /* sizeof(Elf64_Phdr) */
    syscall
    test %rax, %rdx
    jl fail

    cmpl $PT_LOAD, 0(%rsp) /* offsetof(Elf64_Phdr, p_type) */
    jne phdr_loop2_next

    mov $SYS_mmap, %eax
    mov %r15, %r8
    mov $MAP_PRIVATE, %r10d
    mov 4(%rsp), %rcx /* offsetof(Elf64_Phdr, p_flags) */
    mov 8(%rsp), %r9 /* offsetof(Elf64_Phdr, p_offset) */
    mov 16(%rsp), %rdi /* offsetof(Elf64_Phdr, p_vaddr) */
    mov 32(%rsp), %rsi /* offsetof(Elf64_Phdr, p_filesz) */
    mov 40(%rsp), %r11 /* offsetof(Elf64_Phdr, p_memsz) */

    /* reorder orotection bits because why are the order different?! */
    xor %edx, %edx
    bt $2, %rcx
    setc %dl
    bt $1, %rcx
    jnc reorder_a
    bts $1, %rdx
reorder_a:
    bt $0, %rcx
    jnc reorder_b
    bts $2, %rdx
reorder_b:

    mov %rdi, %rcx
    /* round vaddr down to page boundary */
    and $-PAGE_SIZE, %rdi
    /* add the additional size to the map size and fix offset */
    sub %rdi, %rcx
    add %rcx, %rsi
    add %rcx, %r11
    sub %rcx, %r9

    add %r14, %rdi
    or $MAP_FIXED, %r10d
    push %r11
    syscall
    pop %r11
    test %rax, %rax
    jl fail

    cmp %rsi, %r11
    jbe phdr_loop2_next

    mov %rsi, %rcx
    add $(PAGE_SIZE - 1), %rcx
    and $-PAGE_SIZE, %rcx
    sub %rsi, %rcx

bp:
    add %rsi, %rdi
    xor %al, %al
    call memset

    /* align size to page boundary and see if there are additional pages for BSS */
    add $(PAGE_SIZE - 1), %rsi
    add $(PAGE_SIZE - 1), %r11
    and $-PAGE_SIZE, %rsi
    and $-PAGE_SIZE, %r11

    cmp %rsi, %r11
    jbe phdr_loop2_next

    /* map anon to fill the ranges */
    mov $SYS_mmap, %eax
    add %rsi, %rdi
    sub %rsi, %r11
    mov %r11, %rsi
    mov $(MAP_PRIVATE|MAP_ANONYMOUS), %r10d
    mov $-1, %r8
    xor %r9d, %r9d
    push %r11
    syscall
    pop %r11
    test %rax, %rax
    jl fail

phdr_loop2_next:
    mov %rbp, %rsp
    dec %r12w
    jnz phdr_loop2

    mov $SYS_close, %eax
    mov %r15, %rdi
    syscall

/* step 4: patch AUXV getauxval(AT_BASE) = R14 */
    mov $AT_BASE, %eax
    call getauxval
    mov %r14, (%rdx)

/* step 5: patch AUXV getauxval(AT_ENTRY) = &_start */
    mov $AT_ENTRY, %eax
    call getauxval
    lea _start(%rip), %rax
    mov %rax, (%rdx)

/* step 8: glibc asserts for PT_INTERP, patch our PHDR */
    mov $AT_PHDR, %eax
    call getauxval
    mov %rax, %r15

phdr_loop3:
    cmpl $PT_NULL, 0(%r15) /* offsetof(Elf64_Phdr, p_type) */
    jne phdr_loop3_next

    mov $SYS_mprotect, %eax
    mov %r15, %rdi
    and $-PAGE_SIZE, %rdi
    mov $PAGE_SIZE, %esi
    mov $(PROT_READ|PROT_WRITE|PROT_EXEC), %edx
    syscall
    test %rax, %rax
    jl fail

    movl $PT_INTERP, 0(%r15)
    jmp phdr_loop3_done

phdr_loop3_next:
    add $56, %r15 /* sizeof(Elf64_Phdr) */
    jmp phdr_loop3

phdr_loop3_done:
    mov %r13, %rax /* offsetof(Elf64_Ehdr, e_entry) */
    add %r14, %rax

/* step 7: clean registers in case some libc might assume 0 initialized */
    xor %ebx, %ebx
    xor %ecx, %ecx
    xor %edx, %edx
    xor %ebp, %ebp
    xor %ebp, %ebp
    xor %esi, %esi
    xor %edi, %edi
    xor %r8d, %r8d
    xor %r9d, %r9d
    xor %r10d, %r10d
    xor %r11d, %r11d
    xor %r12d, %r12d
    xor %r13d, %r13d
    xor %r14d, %r14d
    xor %r15d, %r15d

/* step 8: jmp into ld.so entry point */
    cld
    /* jmp *%rax */
    push %rax
    xor %eax, %eax
    ret

/* Function getauxval
 * arg:
 *   RAX: the aux type
 * return:
 *   RAX: the value of aux
 *   RDX: address of value
 */
getauxval:
    push %rcx
    xor %ecx, %ecx
getauxval_loop:
    mov (%rbx,%rcx,8), %rdx
    cmp %rdx, %rax
    jz getauxval_found
    test %rdx, %rdx
    jz fail
    add $2, %rcx
    jmp getauxval_loop
getauxval_found:
    lea 8(%rbx,%rcx,8), %rdx
    mov (%rdx), %rax
    pop %rcx
    ret

/* Function strlen
 * arg:
 *   RDI: pointer to start of string
 * return:
 *   RCX: string length
 *   RDI: pointer to end of string
 */
strlen:
    push %rax
    xor %ecx, %ecx
    xor %eax, %eax
    not %rcx
    cld
    repnz scasb
    not %rcx
    dec %rcx
    dec %rdi
    pop %rax
    ret

fail:
    cli

/* Function memcpy
 * arg:
 *   RDI: pointer to start of destination
 *   RSI: pointer to start of source
 *   RCX: length
 * return:
 *   RDI: pointer to end of destination
 *   RSI: pointer to end of source
 */
memcpy:
    push %rcx
    cld
    rep movsb
    pop %rcx
    ret

/* Function memset
 * arg:
 *   AL: value to set
 *   RDI: pointer to start of memory
 *   RCX: length
 * return:
 *   RDI: pointer to end of memory
 */
memset:
    push %rcx
    cld
    rep stosb
    pop %rcx
    ret

ld_path:
    .ascii "ld-linux-x86-64.so.2"
empty_str:
    .asciz ""
ld_path_len = . - ld_path

.section .note.GNU-stack,"",%progbits
