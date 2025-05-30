// SPDX-License-Identifier: CC0-1.0
//
// SPDX-FileContributor: Antonio Niño Díaz, 2022
// SPDX-FileContributor: David Guillen Fandos, 2024

    .section    .gba_ewram_crt0, "ax"
    .global     entrypoint
    .cpu        arm7tdmi

    .arm

entrypoint:
    // Ensure we run at the right address (due to mirroring)
    ldr pc, [pc, #-4]
    .word 1f

1:
    // Disable interrupts
    mov     r0, #0x4000000
    mov     r1, #0
    str     r1, [r0, #0x208] // IME

    // Setup IRQ mode stack
    mov     r0, #0x12
    msr     cpsr, r0
    ldr     sp, =__STACK_IRQ_END__

    // Setup system mode stack
    mov     r0, #0x1F
    msr     cpsr, r0
    ldr     sp, =__STACK_USR_END__

    // Clear IWRAM
    ldr     r0, =#0x3000000
    ldr     r1, =#(32 * 1024)
    bl      mem_zero

    // Copy data section from EWRAM to IWRAM
    ldr     r0, =__DATA_LMA__
    ldr     r1, =__DATA_START__
    ldr     r2, =__DATA_SIZE__
    bl      mem_copy

    // Copy IWRAM data from ROM EWRAM to IWRAM
    ldr     r0, =__IWRAM_LMA__
    ldr     r1, =__IWRAM_START__
    ldr     r2, =__IWRAM_SIZE__
    bl      mem_copy

    // Global constructors
    // bl      __libc_init_array

    // Call main()
    mov     r0, #0 // int argc
    mov     r1, #0 // char *argv[]
    bl      main

    // Global destructors
    // bl      __libc_fini_array

    // If main() returns, reboot the GBA using SoftReset
    swi     #0x00

// r0 = Base address
// r1 = Size
mem_zero:
    tst     r1, r1
    beq     2f // Return if size is 0

    mov     r2, #0
1:
    stmia   r0!, {r2}
    subs    r1, #4
    bne     1b

2:
    bx      lr

// r0 = Source address
// r1 = Destination address
// r2 = Size
mem_copy:
    tst     r2, r2
    beq     2f // Return if size is 0

1:
    ldmia   r0!, {r3}
    stmia   r1!, {r3}
    subs    r2, #4
    bne     1b

2:
    bx      lr

    .align
    .pool
    .end
