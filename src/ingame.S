/*
 * Copyright (C) 2025 David Guillen Fandos <david@davidgf.net>
 *
 * This program is free software: you can redistribute it and/or
 * modify it under the terms of the GNU General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	 See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see
 * <http://www.gnu.org/licenses/>.
 */

#include "ingame.h"

// In-game menu routines (ie. for IRQ patching or similar).
// Shows a small in-game menu, detected by pressing a key combo at VBlank IRQ.
// The menu stores state into SDRAM and allows users to perform certain
// operations and return to game.

// This payload is linked at IWRAM/EWRAM, where it is supposed to run.
// On entering, the asm spills some parts of IWRAM, EWRAM and VRAM into SDRAM
// and loads the menu into IWRAM/EWRAM. This way we can perform SD accesses
// as well as other tricky operations without worrying about memory mapping.

// Suggested structure (in SDRAM):
//  In-game payload, spill area, font blob, cheat DB
//
// The spill area layout is:
//
//   I/O regs + CPU regs  (partial reg dump only)
//   Palette RAM (1KB)
//   VRAM (first 80KB)
//   IWRAM (first 16KB)
//   EWRAM (first 62KB)
//
// Payload size can be read from its header


#define SD_MUTEX_OFFSET             (3*4)        // Keep in sync with directsave.h

#define def_function(fnname)           \
  .globl fnname;                       \
  .type fnname, function;              \
  fnname

#include "gba_regs.h"

// This is ARM code, placed in SDRAM (at the end of it usually). It is
// used to initialize and handle IRQs, and launch the menu from IWRAM.
// It requires some patching to complete it before copying into SDRAM.
.section    .ingame_menu_start, "ax"
.align 4
.arm

.globl ingame_menu_lang
.globl scratch_base
.globl scratch_size
.globl menu_anim_speed
.globl has_rtc_support
.globl ingame_menu_palette
.globl font_base_addr
.globl savefile_backups
.globl cheat_base_addr
.globl spill_addr
.globl savefile_pattern
.globl savestate_pattern

.globl ingame_menu
ingame_menu:
  sub r5, pc, $8      // R5 contains the address for "ingame_menu" (base addr)

  // Writes address 0x03007ffc (actually mirror 0x03fffffc) with the ingame
  // menu address (following routine). Resumes ROM startup execution.
  adr r0, ingame_menu_entrypoint_nocheats
  mov r1, $0x04000000
  str r0, [r1, #-4]

  mov r0, $0x5     // R/W mode
  bl set_cpld_mode

  // Update binary start addr (in ROM) so we can copy if whenever needed.
  str r5, sob_addr
  ldr r0, bin_size
  add r0, r0, r5   // Spill to the end of the binary (in SDRAM space)
  str r0, spill_addr

  mov r0, $0x1             // Read only mode
  bl set_cpld_mode

2:
  ldr r0, [pc, #0x4]
  bx r0

  nop
  nop                     // To be patched with the game entry point branch

// Informational data for the loader (read-only).
ingame_payload_size:
  .word (__BINARY_SIZE__ + MIN_SCRATCH_SPACE)    // How much space the payload needs

// SD card driver params.
drv_issdhc:
  .word 0x0
drv_rca:
  .word 0x0

// To be filled by the loader with relevant data.
ingame_menu_hotkey:    .word 0x0    // Filled with the key combo mask
ingame_menu_lang:      .word 0x0    // Filled with the language code
ingame_ds_base_addr:   .word 0x0    // Base addr of the DirectSave payload (or NULL)
font_base_addr:        .word 0x0    // Filled with the font data address
cheat_base_addr:       .word 0x0    // Filled with the cheat database entry address
scratch_base:          .word 0x0    // Buffer reserved for scratch space.
scratch_size:          .word 0x0
has_rtc_support:       .word 0x0    // Filled with a boolean to allow tweaking RTC values
menu_anim_speed:       .word 0x0    // Menu animation speed
ingame_menu_palette:   .fill 4,2,0  // Filled with background, foreground and select colors
savefile_backups:      .word 0x0    // Fill the number of backups to preserve.

savefile_pattern:      .fill 256, 1, 0          // File name pattern (NULL terminated)
savestate_pattern:     .fill 256, 1, 0          // File name pattern (NULL terminated)

// Necessary handlers for the SC driver
def_function(sc_issdhc):
  ldr r0, drv_issdhc
  bx lr

def_function(sc_rca):
  ldr r0, drv_rca
  bx lr

// Misc fw routines:
set_cpld_mode:  // (r0: mode)
  mov r1, $0x0A000000
  ldr r2, =$0xA55A
  strh r2, [r1, #-2]
  strh r2, [r1, #-2]
  strh r0, [r1, #-2]
  strh r0, [r1, #-2]
  bx lr

// After running the menu code, some .data/.bss variables might have changed.
// This copies them back into the SD-RAM memory, so they are preserved across
// calls (menu entry and exit). We could just copy all data, but that's faster.
save_data_iwram:
  ldr r0, =__DATAS_START__
  ldr r1, =__DATAS_END__
  sub r1, r1, r0
  ldr r2, =__EWRAM_SIZE__    // Assume IWRAM starts right after EWRAM (ie. offset)
  add r2, r0, r2
  sub r2, r2, $0x03000000
  ldr r3, sob_addr
  add r2, r2, r3

1:
  ldr r3, [r0], #4
  str r3, [r2], #4
  subs r1, #4
  bne 1b

  bx lr

// r0: source buffer
// r1: dest buffer
// r2: number of 32byte blocks to copy
do_spill_data:
  ldmia r0!, {r4-r11}
  stmia r1!, {r4-r11}
  subs r2, $1
  bne do_spill_data
  bx lr

// r0: dest buffer
// r1: source buffer
// r2: number of 32byte blocks to copy
restore_spill_data:
  ldmia r1!, {r4-r11}
  stmia r0!, {r4-r11}
  subs r2, $1
  bne restore_spill_data
  bx lr

.balign 8
ingame_menu_entrypoint_nocheats:

  // Entry point, called from BIOS.
  // r0 is known to be 0x04000000 right after the BIOS IRQ handler
  ldrb r1, [r0, #REG_IF]     // Just read the LSB byte
  tst r1, $0x1               // Check for V-Blank interrupt
  ldreq pc, [r0, #-12]       // No V-blank IRQ, resume executing the user's IRQ handler

  ldr r2, (ingame_menu_hotkey + 2)    // Read mask from constant pool (rotate by 16)
  ldr r1, [r0, #REG_P1]      // It's actually a 16 bit reg really
  cmp r2, r1, lsl #16        // Compare the lowest 16 bits only!
  ldrne pc, [r0, #-12]       // Key combo mismatch, resume executing the user's IRQ handler
  b ingame_menu_entry

ingame_menu_entrypoint_cheats:

  // Same as below, but processes cheats on every v-blank as well
  ldrb r1, [r0, #REG_IF]     // Just read the LSB byte
  tst r1, $0x1               // Check for V-Blank interrupt
  ldreq pc, [r0, #-12]       // No V-blank IRQ, resume executing the user's IRQ handler

  // Process cheat code, this is V-Blank!
  push {r5-r6, lr}
  bl cheat_process_arm
  pop {r5-r6, lr}

  mov r0, $0x04000000
  ldr r2, (ingame_menu_hotkey + 2)    // Read mask from constant pool (rotate by 16)
  ldr r1, [r0, #REG_P1]      // It's actually a 16 bit reg really
  cmp r2, r1, lsl #16        // Compare the lowest 16 bits only!
  ldrne pc, [r0, #-12]       // Key combo mismatch, resume executing the user's IRQ handler

  // Enter menu mode!
ingame_menu_entry:

  // Enable writing to SDRAM, since we store/spill data here!
  mov r0, $0x5
  mov r1, $0x0A000000; ldr r2, =$0xA55A
  strh r2, [r1, #-2]; strh r2, [r1, #-2]
  strh r0, [r1, #-2]; strh r0, [r1, #-2]

  // Save relevant I/O regs: timer, DMA, display... and disable them!
  // Uses ~160KiB of space. The menu must have that much space after.
  ldr r1, spill_addr
  mov r3, $0

  // Backup and disable timers (8 bytes)
  ldr r0, =(0x04000000 + REG_TM0CNT)
  ldrh r2, [r0]; strh r2, [r1], #2; strh r3, [r0]
  add r0, r0, $(REG_TM1CNT - REG_TM0CNT)
  ldrh r2, [r0]; strh r2, [r1], #2; strh r3, [r0]
  add r0, r0, $(REG_TM2CNT - REG_TM1CNT)
  ldrh r2, [r0]; strh r2, [r1], #2; strh r3, [r0]
  add r0, r0, $(REG_TM3CNT - REG_TM2CNT)
  ldrh r2, [r0]; strh r2, [r1], #2; strh r3, [r0]

  // Backup and disable DMA (only control bits) (8 bytes)
  mov r0, $0x04000000
  ldrh r2, [r0, #REG_DMA0CNT_H]; strh r2, [r1], #2
  strh r3, [r0, #REG_DMA0CNT_H]
  ldrh r2, [r0, #REG_DMA1CNT_H]; strh r2, [r1], #2
  strh r3, [r0, #REG_DMA1CNT_H]
  ldrh r2, [r0, #REG_DMA2CNT_H]; strh r2, [r1], #2
  strh r3, [r0, #REG_DMA2CNT_H]
  ldrh r2, [r0, #REG_DMA3CNT_H]; strh r2, [r1], #2
  strh r3, [r0, #REG_DMA3CNT_H]

  // Backup LCD regs
  ldrh r2, [r0, #REG_DISPCNT];  strh r2, [r1], #2
  ldrh r2, [r0, #REG_DISPSTAT]; strh r2, [r1], #2
  ldrh r2, [r0, #REG_BG0CNT];   strh r2, [r1], #2
  ldrh r2, [r0, #REG_BG1CNT];   strh r2, [r1], #2
  ldrh r2, [r0, #REG_BG2CNT];   strh r2, [r1], #2
  ldrh r2, [r0, #REG_BG3CNT];   strh r2, [r1], #2
  ldrh r2, [r0, #REG_BLDCNT];   strh r2, [r1], #2
  ldrh r2, [r0, #REG_BLDALPHA]; strh r2, [r1], #2

  // Backup and stop key audio regs
  ldr r2, [r0, #REG_SOUNDCNT_L]; str r2, [r1], #4
  str r3, [r0, #REG_SOUNDCNT_L]

  // TODO save more registers that we might have missed?

  // Spill all regs (r0-r3, r12 and lr are pushed on the stack by the BIOS) (64 bytes)
  ldr r0, [sp,  #0]; str r0, [r1], #4    // r0
  ldr r0, [sp,  #4]; str r0, [r1], #4    // r1
  ldr r0, [sp,  #8]; str r0, [r1], #4    // r2
  ldr r0, [sp, #12]; str r0, [r1], #4    // r3
  stmia r1!, {r4-r11}                    // r4-r11
  ldr r0, [sp, #16]; str r0, [r1], #4    // r12
                     str sp, [r1], #4    // r13  (this is IRQ SP)
  ldr r0, [sp, #20]; str r0, [r1], #4    // r14  (this is IRQ LR, points to the IRQ'ed PC)
                     str lr, [r1], #4    // r14 return address for the BIOS handler.

  // Store also the rest of the CPU state.
  #define save_moderegs(mode)           \
    /* Change mode */                   \
    mov r0, $(0xC0 | (mode));           \
    msr cpsr_c, r0;                     \
    /* Load and write them */           \
    mov r4, sp;                         \
    mov r5, lr;                         \
    mrs r6, spsr;                       \
    stmia r1!, {r4, r5, r6};

  mrs r2, cpsr                           // CPSR IRQ mode.
  stmia r1!, {r2}

  save_moderegs(0x12)                    // IRQ mode
  save_moderegs(0x11)                    // FIQ mode.
  save_moderegs(0x13)                    // supervisor mode.
  save_moderegs(0x17)                    // abort mode.
  save_moderegs(0x1B)                    // undefined mode.

  msr cpsr, r2                           // Restore original mode/cpsr

  // Copy Palette and VRAM to the spill area (OAM is preserved since unused)
  mov r0, $0x05000000
  mov r2, $(1024 / 8 / 4)
  bl do_spill_data

  mov r0, $0x06000000
  mov r2, $(VRAM_SPILL_SIZE / 8 / 4)  // Swapping two frames worth of data
  bl do_spill_data

  // Swap the first 16KiB IWRAM (partial menu and stack)
  mov r0, $0x03000000
  mov r2, $(IWRAM_SPILL_SIZE / 8 / 4)
  bl do_spill_data

  // Swap the first NKiB EWRAM (menu data and code)
  mov r0, $0x02000000
  mov r2, $(EWRAM_SPILL_SIZE / 8 / 4)
  bl do_spill_data

  // Proceed to copy the menu payload into IWRAM and EWRAM.
  ldr r0, sob_addr
  mov r1, $0x02000000
  ldr r2, =__EWRAM_SIZE__
1:
  ldmia r0!, {r4-r11}
  stmia r1!, {r4-r11}
  subs r2, $(8*4)
  bgt 1b

  ldr r0, sob_addr
  ldr r3, =__EWRAM_SIZE__    // Assume IWRAM starts right after EWRAM (ie. offset)
  add r0, r0, r3
  mov r1, $0x03000000
  ldr r2, =__IWRAM_SIZE__
1:
  ldmia r0!, {r4-r11}
  stmia r1!, {r4-r11}
  subs r2, $(8*4)
  bgt 1b

  // Setup stack (add some clearance) at the bottom of the first 16KB
  ldr sp, =0x03003E00

  // Determine if there's an DirSav payload, and whether it holds the mutex
  ldr r0, ingame_ds_base_addr
  tst r0, r0       // If it's null, no worries.
  ldrne r0, [r0, #SD_MUTEX_OFFSET]
  tstne r0, r0     // Check if it's non-zero (mutex is held)

  // Jump to C code, but in IWRAM copy
  adr r0, use_cheats_irq                    // Pass the ROM space address!
  ldreq r1, =ingame_menu_loop               // If dsaddr is null, or mutex is zero
  ldrne r1, =ingame_menu_blocked            // Otherwise, display warning menu
  mov lr, pc
  bx r1

  mov r0, $0x5     // Ensure we remain in R/W mode
  bl set_cpld_mode

  // Save volatile data from IWRAM back to SD-RAM.
  bl save_data_iwram

  // Start restoring the saved state.
  ldr r1, spill_addr
  add r1, $(8 + 8 + 16 + 2+2 + 64 + 64)   // Skip register save to RAM buffers.

  // Restore palette
  mov r0, $0x05000000
  mov r2, $(1024 / 8 / 4)
  bl restore_spill_data

  // Restore VRAM
  mov r0, $0x06000000
  mov r2, $(VRAM_SPILL_SIZE / 8 / 4)  // Swapping two frames worth of data
  bl restore_spill_data

  // Restore IWRAM and EWRAM
  mov r0, $0x03000000
  mov r2, $(IWRAM_SPILL_SIZE / 8 / 4)
  bl restore_spill_data
  mov r0, $0x02000000
  mov r2, $(EWRAM_SPILL_SIZE / 8 / 4)
  bl restore_spill_data

  // Repatch the IRQ handler just in case we activated/deactivated cheats!
  ldr r1, use_cheats_irq
  cmp r1, $0
  adrne r0, ingame_menu_entrypoint_cheats
  adreq r0, ingame_menu_entrypoint_nocheats
  mov r1, $0x04000000
  str r0, [r1, #-4]

  // Make the SDRAM read-only again!
  mov r0, $0x1       // SD-RAM, Readonly mode
  bl set_cpld_mode

  // Restore timer control regs (to r11-r14)
  ldr r1, spill_addr
  ldrh r11, [r1], #2
  ldrh r12, [r1], #2
  ldrh r13, [r1], #2
  ldrh r14, [r1], #2
  // And DMA as well
  ldrh r6, [r1], #2
  ldrh r7, [r1], #2
  ldrh r8, [r1], #2
  ldrh r9, [r1], #2

  // Restore LCD regs
  mov r2, $0x04000000
  ldrh r3, [r1], #2; strh r3, [r2, #REG_DISPCNT];
  ldrh r3, [r1], #2; strh r3, [r2, #REG_DISPSTAT];
  ldrh r3, [r1], #2; strh r3, [r2, #REG_BG0CNT];
  ldrh r3, [r1], #2; strh r3, [r2, #REG_BG1CNT];
  ldrh r3, [r1], #2; strh r3, [r2, #REG_BG2CNT];
  ldrh r3, [r1], #2; strh r3, [r2, #REG_BG3CNT];
  ldrh r3, [r1], #2; strh r3, [r2, #REG_BLDCNT];
  ldrh r3, [r1], #2; strh r3, [r2, #REG_BLDALPHA];
  // Sound regs
  ldr r3, [r1], #4; str r3, [r2, #REG_SOUNDCNT_L];

  // TODO: Need to handle flags in some way? Timers and DMA should be disabled, what about other IRQs?

  // Restore SPSR and R13/R14 registers
  #define reload_regs(mode, off)          \
    /* Change mode */                     \
    mov r0, $(0xC0 | (mode));             \
    msr cpsr_c, r0;                       \
    /* Load the regs */                   \
    ldr sp, [r1, #(64 + 4 + off*12 + 0)]; \
    ldr lr, [r1, #(64 + 4 + off*12 + 4)]; \
    ldr r3, [r1, #(64 + 4 + off*12 + 8)]; \
    msr spsr, r3;

  reload_regs(0x12, 0);              // SPSR IRQ mode
  reload_regs(0x11, 1);              // SPSR FIQ mode
  reload_regs(0x13, 2);              // SPSR supervisor mode
  reload_regs(0x17, 3);              // SPSR abort mode
  reload_regs(0x1B, 4);              // SPSR undefined mode

  ldr r3, [r1, #(64 + 0)]            // CPSR (IRQ mode)
  msr cpsr, r3                       // Load CPSR, changes to IRQ mode too.


  // Wait for v-blank, try to be precise to help with timing breakages
  ldr r3, =(0x04000000 + REG_TM0CNT)
1:
  ldrh r0, [r2, #REG_VCOUNT]
  cmp r0, $159
  bne 1b
1:
  ldrh r0, [r2, #REG_VCOUNT]
  cmp r0, $160
  bne 1b

  // Resume timers (re-enable them if they were enabled essentially)
  strh r11, [r3, #0]
  strh r12, [r3, #(REG_TM1CNT-REG_TM0CNT)]
  strh r13, [r3, #(REG_TM2CNT-REG_TM0CNT)]
  strh r14, [r3, #(REG_TM3CNT-REG_TM0CNT)]
  // Re-enable DMA as well
  strh r6, [r2, #REG_DMA0CNT_H]
  strh r7, [r2, #REG_DMA1CNT_H]
  strh r8, [r2, #REG_DMA2CNT_H]
  strh r9, [r2, #REG_DMA3CNT_H]

  // Restore regs before calling out the user IRQ
  ldr sp, [r1, #(4*13)]  // Restore the stack before we actually overwrite it

  ldr r8, [r1, #(4*12)]  // Load r0-r3 and r12/r14 into r4-r9
  ldr r9, [r1, #(4*14)]
  ldr lr, [r1, #(4*15)]  // BIOS handler ret addr

  ldmia r1!, {r4-r7}
  stmia sp, {r4-r9}      // Overwrite the BIOS stack (r0-r3, r12, r14}

  ldmia r1!, {r4-r11}    // Load save registers (r4-r11)

  // Go ahead and fallback to the user IRQ handler.
  ldr pc, [r2, #-12]

// Some constants that, for some reason, don't wanna go into the pool
bin_size:
  .word __BINARY_SIZE__         // Binary size for the ingame menu payload.
sob_addr:
  .word 0          // Updated with the actual ROM addr where the menu lives
spill_addr:
  .word 0          // Updated with the end-of-binary address address to spill
use_cheats_irq:
  .word 0          // Whether we should be using the slower cheats IRQ hook

// Constant pool goes here.
.balign 4
.pool

.balign 4
cheat_table:
  .fill 64, 4, 0       // 64 pointers, up to 63 active cheats.

// Cheat execution machinery, processes cheat codes (pre-decoded) and executes them.

// There's a 64 entry table with pointers to each cheat's code table.
// The end token is a null pointer.
// We load each pointer to r0 and call the chet execution loop.
// r5: contains the pointer to the cheat table base.
.balign 4
cheat_process_arm:
  adr r5, cheat_table
  adr r0, (cheat_process_thumb + 1)
  bx r0

.thumb
cheat_process_thumb:
  push {lr}
  mov r6, $0

1:
  ldr r0, [r5, r6]     // Load cheat code pointer
  cmp r0, $0           // Abort if NULL pointer is found (last cheat)
  beq 2f
  add r6, $4           // Advance pointer
  bl cheat_exec
  b 1b

2:
  pop {r0}
  bx r0

#include "cheat_exec.S"

.arm
.balign 4

// Place here all routines that are not really used within the boot section
// (they are used by the C code in cases where assembly is needed).

// Reset routines
def_function(reset_game):
  mov r0, $0x1       // SD-RAM, Readonly mode
  bl set_cpld_mode
  b clear_and_reset

def_function(reset_fw):
  mov r0, $0x0       // FW mapped, read-only mode
  bl set_cpld_mode
  b clear_and_reset

// Clears a buffer (4 byte aligned) in blocks of 256 bytes
def_function(fast_mem_clr_256):
  push {r4-r11}
  mov r4, r1; mov r5, r1; mov  r6, r1; mov  r7, r1;
  mov r8, r1; mov r9, r1; mov r10, r1; mov r11, r1;
1:
  stmia r0!, {r4-r11}; stmia r0!, {r4-r11}
  stmia r0!, {r4-r11}; stmia r0!, {r4-r11}
  stmia r0!, {r4-r11}; stmia r0!, {r4-r11}
  stmia r0!, {r4-r11}; stmia r0!, {r4-r11}
  subs r2, $256
  bhi 1b

  pop {r4-r11}
  bx lr

// Copies a buffer (4 byte aligned) in blocks of 256 bytes
def_function(fast_mem_cpy_256):
  push {r4-r11}
1:
  ldmia r1!, {r4-r11}; stmia r0!, {r4-r11}
  ldmia r1!, {r4-r11}; stmia r0!, {r4-r11}
  ldmia r1!, {r4-r11}; stmia r0!, {r4-r11}
  ldmia r1!, {r4-r11}; stmia r0!, {r4-r11}
  ldmia r1!, {r4-r11}; stmia r0!, {r4-r11}
  ldmia r1!, {r4-r11}; stmia r0!, {r4-r11}
  ldmia r1!, {r4-r11}; stmia r0!, {r4-r11}
  ldmia r1!, {r4-r11}; stmia r0!, {r4-r11}
  subs r2, $256
  bhi 1b

  pop {r4-r11}
  bx lr

def_function(get_cheat_table):
  adr r0, cheat_table
  bic r0, $0xFF000000      // Assuming calling from IW/EWRAM, clear top bits
  ldr r3, sob_addr
  add r0, r0, r3
  bx lr

def_function(clear_and_reset):
  // Setup a proper system and SVC mode stack, not sure if the game could have borked it.
  mov r0, #0xD3
  msr cpsr_cf, r0
  ldr sp, =0x03007FE0    // Default BIOS mode stack value

  mov r0, #0x9F
  msr cpsr_cf, r0        // Restore system mode.
  ldr sp, =0x03007f00    // Default BIOS value

  // Copy this subroutine into IWRAM end (last 512 bytes are not wiped)
  adr r0, 1f
  ldr r1, =0x03007f00
  mov r2, $((clear_and_reset_end - 1f) / 4)
  swi 0x0C0000           // Copy the following code into IWRAM

  ldr r1, =0x03007f00    // Continue from there.
  bx r1

1:
  // Clear memory first (all memories, save the last 256 bytes of IWRAM)
  mov r0, $0xFF
  swi 0x010000

  // Go ahead and reset to ROM (bypass BIOS)
  mov r0, $0x04000000
  mov r1, $0
  strb r1, [r0, #-6]
  swi 0
clear_and_reset_end:


