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

#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "cheats.h"
#include "util.h"
#include "fatfs/ff.h"

// Preprocessing cheats, includes a proper header and pre-formats some payloads.
bool predecode_cheats(uint32_t *codes, unsigned cnt) {
  for (unsigned i = 0; i < cnt; i++) {
    t_cheat_predec h = {
      .opcode = ((codes[2*i] >> 28) & 0xF) * 2,    // Opcode scaled by 2
      .value = codes[2*i+1],
      .address = codes[2*i] & 0xFFFFFFF,
    };
    h.blen = (h.opcode == 4 * 2) ? 16 :
             (h.opcode == 5 * 2) ? (h.value + 1) * 8 :
             8;

    // Overwrite buffer with the new format
    memcpy(&codes[2*i], &h, sizeof(h));

    if (h.opcode == 4 * 2)
      i++;                    // Extra addr + value for opc4
    else if (h.opcode == 5 * 2) {
      // Extra buffer. We perform some endianess conversion here.
      for (unsigned j = 0; j < h.value; j++) {
        i++;
        uint32_t addr = codes[2*i];
        uint16_t valu = codes[2*i+1];
        codes[2*i] = __builtin_bswap32(addr);
        codes[2*i+1] = __builtin_bswap16(valu);
      }
    }
  }
  return true;
}

bool parse_hex(const char *s, uint32_t *val, unsigned nibcnt) {
  unsigned r = 0;
  for (unsigned i = 0; i < nibcnt; i++) {
    if (!s[i])
      return false;    // String ended prematurely

    if (s[i] >= '0' && s[i] <= '9')
      r = (r << 4) | (s[i] - '0');
    else if (s[i] >= 'a' && s[i] <= 'f')
      r = (r << 4) | (s[i] - 'a' + 10);
    else if (s[i] >= 'A' && s[i] <= 'F')
      r = (r << 4) | (s[i] - 'A' + 10);
    else
      return false;
  }
  *val = r;
  return true;
}

// Parses RAW codes into a uint32 buffer
int parse_cheat_codes(const char *s, uint32_t *codes) {
  // Codes are in the format:
  // 0123ABCD+67EF 125634AB+78CD ....
  // We parse them assuming that the separators are space or plus. We admit multiple separators.
  unsigned cnt = 0;

  while (*s == ' ' || *s == '+') s++;      // Skip initial spaces

  while (*s) {
    uint32_t addr, val;
    if (!parse_hex(s, &addr, 8))
      return -1;

    s += 8;  // Consume the hex32
    while (*s == ' ' || *s == '+') s++;      // Skip separators
    if (!*s)
      return -1;   // The code is truncated, abort.

    if (!parse_hex(s, &val, 4))
      return -1;
    s += 4;  // Consume the hex16

    // A full code (addr+val) has been parsed, just write it raw into the buffer.
    *codes++ = addr;
    *codes++ = val;
    cnt++;

    while (*s == ' ' || *s == '+') s++;      // Skip trailing separators
  }
  return cnt;
}


// Reads a cheat file into a temp buffer (usually in SDRAM) and returns the size in bytes
// Returns -1 if the file is not found or the cheats cannot be loaded.
int open_read_cheats(uint8_t *buffer, unsigned buffsize, const char *fn) {
  FIL fd;
  FRESULT res = f_open(&fd, fn, FA_READ);
  if (res != FR_OK)
    return -1;

  bool parse_name = true;
  unsigned bcount = 0;
  char tmp[1024 + 4];

  t_cheathdr_ext chdr;
  uint32_t *bufhd = (uint32_t*)buffer;
  *bufhd = 0;
  unsigned bufsz = 4;

  // Parse the file line by line, using a temp buffer.
  do {
    if (bcount <= 512) {
      UINT rdbytes;
      if (FR_OK != f_read(&fd, &tmp[bcount], 512, &rdbytes))
        return -1;
      bcount += rdbytes;
      tmp[bcount] = 0;
    }

    // Attempt to parse the next line.
    char *p = strchr(tmp, '\n');
    if (!p) 
      p = strchr(tmp, '\0');
    if (!p)
      break;       // Some path is way too long!

    *p = 0;        // Add the string end char.

    // Skip leading characters.
    char *s = tmp;
    while (*s == ' ' || *s == '\t')
      s++;

    // Skip empty lines!
    if (*s != 0) {
      if (bufsz + 1024 > buffsize)
        return -1;

      // Fill entry, string or cheat codes.
      if (parse_name) {
        // Fill title and header.
        strcpy(chdr.title, s);
        chdr.h.slen = (strlen(chdr.title) + 1 + 3) & ~3U;  // Word aligned!
        chdr.h.enabled = 0;
        chdr.h.codelen = 0;
      } else {
        // Parse the cheat codes (in hex), and generate the respective code.
        uint32_t codes[74];  // Enough codes for a 1024 byte cheat line.
        memset(codes, 0, sizeof(codes));
        int numcodes = parse_cheat_codes(tmp, codes);
        if (numcodes < 0)
          return -1;
        // Process the raw codes and format them into t_cheat_predec (predecoded opcode)
        if (!predecode_cheats(codes, numcodes))
          return -1;
        // Each code takes 8 bytes
        chdr.h.codelen = 8 * (numcodes + 1);

        { // Copy the data to the actual buffer.
          unsigned pheadl = sizeof(t_cheathdr) + chdr.h.slen;
          memcpy32(&buffer[bufsz], &chdr, pheadl);
          memcpy32(&buffer[bufsz + pheadl], codes, chdr.h.codelen);

          bufsz += pheadl + chdr.h.codelen;
          (*bufhd)++;
        }
      }

      parse_name = !parse_name;
    }

    // Consume bytes
    unsigned cnt = strlen(tmp) + 1;
    memmove(&tmp[0], &tmp[cnt], bcount - cnt);
    bcount -= cnt;
  } while (bcount);

  f_close(&fd);
  return bufsz;
}


